package main

import lp "../../src/listpack"
import "../../src/rdb"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

checks: int
failures: int

check :: proc(cond: bool, what: string, loc := #caller_location) -> bool {
	checks += 1
	if !cond {
		failures += 1
		if failures <= 50 {
			fmt.eprintfln("FAIL %s (%s:%d)", what, loc.file_path, loc.line)
		}
	}
	return cond
}

Rng :: struct {
	x: u64,
}

rng_make :: proc(seed: u64) -> Rng {
	x := seed * 0x9E3779B97F4A7C15 + 1
	if x == 0 {
		x = 1
	}
	return Rng{x}
}

rng_next :: proc(r: ^Rng) -> u64 {
	x := r.x
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	r.x = x
	return x
}

WORDS := [?]string{"the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "redis", "jetty", "listpack", "quicklist", "\n", "0123456789"}

gen :: proc(pattern: string, seed: u64, length: int) -> []u8 {
	r := rng_make(seed)
	out: [dynamic]u8
	switch pattern {
	case "rand":
		for len(out) < length {
			append(&out, u8(rng_next(&r) >> 56))
		}
	case "text":
		for len(out) < length {
			append(&out, ..transmute([]u8)WORDS[rng_next(&r) % len(WORDS)])
			append(&out, ' ')
		}
	case "run":
		for len(out) < length {
			append(&out, 'a')
		}
	case "period":
		p := 1 + int(rng_next(&r) % 300)
		base := make([]u8, p)
		defer delete(base)
		for i in 0 ..< p {
			base[i] = u8(rng_next(&r) >> 56)
		}
		for len(out) < length {
			append(&out, ..base)
		}
	case "mixed":
		for len(out) < length {
			if len(out) < 16 || rng_next(&r) % 3 == 0 {
				n := 1 + int(rng_next(&r) % 64)
				for _ in 0 ..< n {
					append(&out, u8(rng_next(&r) >> 56))
				}
			} else {
				off := 1 + int(rng_next(&r) % u64(min(len(out), 8200)))
				n := 3 + int(rng_next(&r) % 300)
				start := len(out) - off
				for i in 0 ..< n {
					append(&out, out[start + i])
				}
			}
		}
	}
	return out[:length]
}

test_crc64 :: proc() {
	v1 := "123456789"
	check(rdb.crc64(0, transmute([]u8)v1) == 0xe9c6d914c4b8d9ca, "crc64 of 123456789")
	check(rdb.crc64_bitwise(0, transmute([]u8)v1) == 0xe9c6d914c4b8d9ca, "bitwise crc64 of 123456789")
	li := "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.\x00"
	check(rdb.crc64(0, transmute([]u8)li) == 0xc7794709e69683b3, "crc64 of lorem ipsum")
	data := gen("rand", 99, 10000)
	defer delete(data)
	whole := rdb.crc64(0, data)
	for split in ([]int{1, 7, 8, 9, 63, 4096, 9999}) {
		part := rdb.crc64(rdb.crc64(0, data[:split]), data[split:])
		check(part == whole, "chained crc64 equals one shot")
	}
	for off in 0 ..< 8 {
		check(rdb.crc64(0, data[off:off + 100]) == rdb.crc64_bitwise(0, data[off:off + 100]), "table crc64 equals bitwise at every alignment")
	}
}

test_lzf_vectors :: proc(path: string) -> int {
	content, err := os.read_entire_file(path, context.allocator)
	if !check(err == nil, "read lzf vectors") {
		return 0
	}
	defer delete(content)
	n := 0
	lines := strings.split_lines(string(content))
	defer delete(lines)
	for line in lines {
		if len(line) == 0 {
			continue
		}
		f := strings.fields(line)
		defer delete(f)
		if !check(len(f) == 6, "vector line has six fields") {
			continue
		}
		seed, _ := strconv.parse_u64(f[1])
		length, _ := strconv.parse_int(f[2])
		enclen, _ := strconv.parse_int(f[3])
		crc, _ := strconv.parse_u64(f[5], 16)
		value := gen(f[0], seed, length)
		defer delete(value)
		w: rdb.Writer
		rdb.writer_init_mem(&w, true, true)
		rdb.put_u8(&w, 0)
		rdb.put_string(&w, value)
		rdb.put_u8(&w, 12)
		rdb.put_u8(&w, 0)
		b := rdb.writer_bytes(&w)
		check(len(b) - 3 == enclen, fmt.tprintf("encoded length of %s %d %d is %d, reference %d", f[0], seed, length, len(b) - 3, enclen))
		check(rdb.crc64(0, b) == crc, fmt.tprintf("payload crc64 of %s %d %d matches the reference", f[0], seed, length))
		is_lzf := b[1] == 0xC3
		check(is_lzf == (f[4] == "lzf"), "compression decision matches the reference")
		r: rdb.Reader
		rdb.reader_init_mem(&r, b[1:len(b) - 2], false)
		got, gok := rdb.get_string(&r, 0)
		check(gok && string(got) == string(value), "decoded string equals the input")
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
		n += 1
	}
	return n
}

test_lzf_roundtrip :: proc() {
	patterns := [?]string{"rand", "text", "run", "period", "mixed"}
	for p in patterns {
		for length in ([]int{3, 4, 5, 16, 31, 32, 33, 34, 63, 64, 65, 264, 265, 266, 1000, 8191, 8192, 8193, 70000}) {
			v := gen(p, u64(length) * 31 + 5, length)
			defer delete(v)
			out := make([]u8, length + 64)
			n := rdb.lzf_compress(v, out)
			if n > 0 {
				back := make([]u8, length)
				m := rdb.lzf_decompress(out[:n], back)
				check(m == length && string(back) == string(v), fmt.tprintf("lzf round trip %s %d", p, length))
				short := make([]u8, length - 1)
				check(rdb.lzf_decompress(out[:n], short) == 0, "lzf decompress refuses a short output buffer")
				delete(short)
				delete(back)
			} else {
				check(p == "rand" || length < 4, fmt.tprintf("lzf compresses %s %d", p, length))
			}
			delete(out)
		}
	}
	bad := [?]u8{0x40, 0x00}
	o: [16]u8
	check(rdb.lzf_decompress(bad[:], o[:]) == 0, "lzf rejects a back reference before the start")
	trunc := [?]u8{0x05, 'a', 'b'}
	check(rdb.lzf_decompress(trunc[:], o[:]) == 0, "lzf rejects a truncated literal run")
}

test_lengths :: proc() {
	vals := [?]u64{0, 1, 63, 64, 16383, 16384, 0xFFFFFFFF, 0x100000000, max(u64)}
	sizes := [?]int{1, 1, 1, 2, 2, 5, 5, 9, 9}
	for v, i in vals {
		w: rdb.Writer
		rdb.writer_init_mem(&w, true, true)
		rdb.put_len(&w, v)
		b := rdb.writer_bytes(&w)
		check(len(b) == sizes[i], fmt.tprintf("length %d uses %d bytes", v, sizes[i]))
		r: rdb.Reader
		rdb.reader_init_mem(&r, b, false)
		check(rdb.get_len(&r) == v || v == max(u64), fmt.tprintf("length %d round trips", v))
		rdb.writer_destroy(&w)
	}
	ints := [?]i64{0, -1, 127, -128, 128, -129, 32767, -32768, 32768, -32769, 2147483647, -2147483648, 2147483648, -2147483649, max(i64), min(i64)}
	enc := [?]int{2, 2, 2, 2, 3, 3, 3, 3, 5, 5, 5, 5, 0, 0, 0, 0}
	for v, i in ints {
		w: rdb.Writer
		rdb.writer_init_mem(&w, true, true)
		rdb.put_ll_string(&w, v)
		b := rdb.writer_bytes(&w)
		if enc[i] > 0 {
			check(len(b) == enc[i] && b[0] >> 6 == 3, fmt.tprintf("integer %d uses the %d byte encoding", v, enc[i]))
		} else {
			check(b[0] >> 6 != 3, fmt.tprintf("integer %d is written as a string", v))
		}
		r: rdb.Reader
		rdb.reader_init_mem(&r, b, false)
		s, ok := rdb.get_string(&r, 0)
		buf: [24]u8
		k := rdb.ll2string(buf[:], v)
		check(ok && string(s) == string(buf[:k]), fmt.tprintf("integer %d round trips", v))
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
	}
	strs := [?]string{"", "0", "-0", "007", "12345678901", "123456789012", "+1", " 1", "9223372036854775808"}
	for s in strs {
		w: rdb.Writer
		rdb.writer_init_mem(&w, true, true)
		rdb.put_string(&w, transmute([]u8)s)
		r: rdb.Reader
		rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
		got, ok := rdb.get_string(&r, 0)
		check(ok && string(got) == s, fmt.tprintf("string %q round trips", s))
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
	}
}

test_ziplist :: proc() {
	zl := [?]u8{0x10, 0, 0, 0, 0x0d, 0, 0, 0, 2, 0, 0x00, 0x01, 'a', 0x03, 0xF2, 0xFF}
	it := rdb.ziplist_iter(zl[:])
	e: rdb.Zl_Entry
	n := 0
	check(rdb.ziplist_check_header(zl[:]), "ziplist header is valid")
	for rdb.ziplist_next(&it, &e) {
		if n == 0 {
			check(!e.is_int && string(e.str) == "a", "first ziplist entry is the string a")
		} else {
			check(e.is_int && e.ival == 1, "second ziplist entry is the immediate integer 1")
		}
		n += 1
	}
	check(n == 2 && !it.failed, "ziplist walk sees two entries")
	conv, ok := rdb.ziplist_to_listpack(zl[:], false)
	check(ok && lp.lp_length(conv) == 2, "ziplist converts to a two entry listpack")
	if ok {
		lp.lp_free(conv)
	}
	paired, pairs_ok := rdb.ziplist_to_listpack(zl[:], true)
	check(pairs_ok, "ziplist with two entries is a valid pair list")
	if pairs_ok {
		lp.lp_free(paired)
	}
}

main :: proc() {
	path := "test/rdb/lzf_vectors.txt"
	if len(os.args) > 1 {
		path = os.args[1]
	}
	test_crc64()
	nvec := test_lzf_vectors(path)
	test_lzf_roundtrip()
	test_lengths()
	test_ziplist()
	fmt.printfln("rdb unit: %d checks, %d failures, %d reference lzf vectors", checks, failures, nvec)
	if failures > 0 {
		os.exit(1)
	}
}

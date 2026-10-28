package hll_harness

import hll "../../src/hll"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"

checks_run: int
checks_failed: int

check :: proc(cond: bool, what: string, loc := #caller_location) {
	checks_run += 1
	if !cond {
		checks_failed += 1
		fmt.eprintfln("FAIL %s (%s:%d)", what, loc.file_path, loc.line)
	}
}

run :: proc(l: ^Local, args: ..string) -> string {
	parts := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		parts[i] = transmute([]u8)a
	}
	out := make([dynamic]u8, context.temp_allocator)
	exec(l, parts, &out)
	return string(out[:])
}

run_int :: proc(l: ^Local, args: ..string) -> i64 {
	v, _ := reply_int(transmute([]u8)run(l, ..args))
	return v
}

Vector :: struct {
	input:  string,
	redis:  u64,
	seed0:  u64,
}

test_murmur :: proc() {
	vectors := []Vector {
		{"", 0xd8dfea6585bc9732, 0x0000000000000000},
		{"a", 0x53d2470a9b43b1a7, 0x071717d2d36b6b11},
		{"ab", 0x0eaed676437142cf, 0x62be85b2fe53d1f8},
		{"abc", 0x77ec90aeb374e502, 0x9cc9c33498a95efb},
		{"abcd", 0xb079ee3d44202b3e, 0xec1044c45cc5097a},
		{"abcde", 0x52a7daa2324a0e8e, 0x1182974836d6dbb7},
		{"abcdef", 0x3a4f3a74f538b54f, 0xb78e3425fc996779},
		{"abcdefg", 0x22fe613bb08c9602, 0x241aa52b0a62005d},
		{"abcdefgh", 0xf3a65df559914567, 0xafdb0257ff41aa98},
		{"abcdefghi", 0x834fba4d9152daf7, 0xc9b9d84356146ac2},
		{"abcdefghij", 0xce00afbfdbd6efc4, 0xa33f0dbf245bcb51},
		{"abcdefghijk", 0x0f85070a21c57729, 0xfeff07a18c726536},
		{"abcdefghijkl", 0x197f9775ba8c25df, 0xa24066d5378b01bb},
		{"abcdefghijklm", 0x28904e1bbb8963c5, 0xe126e825baaba665},
		{"abcdefghijklmn", 0x4311344e4c269641, 0x9da2538e559887e9},
		{"abcdefghijklmno", 0x10350863b35a3059, 0xfdaac8a629dcd46a},
		{"abcdefghijklmnop", 0xd006e2f88c34e470, 0xd41a085973d213ba},
		{"abcdefghijklmnopq", 0x876ed29fb39e50af, 0x0f996a806d240427},
		{"hello", 0x0f656f01eecfe400, 0x1e68d17c457bf117},
		{"foo", 0xe64609b8b0141cb4, 0xcdde38358fd25b01},
		{"The quick brown fox jumps over the lazy dog", 0x51606c5c5b561ace, 0x5589ca33042a861b},
	}
	for v in vectors {
		b := transmute([]u8)v.input
		check(hll.murmurhash64a(b, hll.HLL_HASH_SEED) == v.redis, fmt.tprintf("murmur redis seed %q", v.input))
		check(hll.murmurhash64a(b, 0) == v.seed0, fmt.tprintf("murmur seed 0 %q", v.input))
		i1, c1 := hll.hll_pat_len(b)
		i2, c2 := hll.hll_pat_len_from_hash(v.redis)
		check(i1 == i2 && c1 == c2, fmt.tprintf("pattern length agrees with hash for %q", v.input))
	}
	bin: [256]u8
	for i in 0 ..< 256 {
		bin[i] = u8(255 - i)
	}
	check(hll.murmurhash64a(bin[:], hll.HLL_HASH_SEED) == 0xa73a48e45943ec87, "murmur 256 binary bytes")
	e := [8]u8{0x39, 0x30, 0, 0, 0, 0, 0, 0}
	check(hll.murmurhash64a(e[:], hll.HLL_HASH_SEED) == 0x6528b165c2b37e2e, "murmur little endian u64 12345")
}

test_pat_len :: proc() {
	i, c := hll.hll_pat_len_from_hash(0)
	check(i == 0 && c == 51, "hash 0 gives register 0 count 51")
	i, c = hll.hll_pat_len_from_hash(1 << 14)
	check(i == 0 && c == 1, "bit 14 set gives count 1")
	i, c = hll.hll_pat_len_from_hash(0x3fff | (1 << 20))
	check(i == 16383 && c == 7, "register 16383 count 7")
	i, c = hll.hll_pat_len_from_hash(max(u64))
	check(i == 16383 && c == 1, "all ones hash")
	i, c = hll.hll_pat_len_from_hash(u64(1) << 63)
	check(i == 0 && c == 50, "only top bit set gives count 50")
}

test_new_sparse :: proc() {
	b := hll.hll_new_sparse()
	defer hll.hll_free(b)
	want := []u8{'H', 'Y', 'L', 'L', 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0x7f, 0xff}
	check(string(b) == string(want), "empty sparse layout")
	check(hll.hll_is_valid(b), "empty sparse is valid")
	check(hll.hll_encoding_name(b) == "sparse", "empty sparse encoding name")
	d, ok := hll.hll_decode_sparse_for_debug(b, context.temp_allocator)
	check(ok && d == "Z:16384", "empty sparse decode")
	invalid := false
	check(hll.hll_count(b, &invalid) == 0 && !invalid, "empty count is zero")
	check(hll.HLL_DENSE_SIZE == 12304, "dense size")
}

test_dense_packing :: proc() {
	regs := make([]u8, hll.HLL_DENSE_SIZE - hll.HLL_HDR_SIZE)
	defer delete(regs)
	hll.dense_put(regs, 0, 63)
	check(regs[0] == 0x3f && regs[1] == 0, "register 0 occupies low six bits of byte 0")
	hll.dense_put(regs, 1, 63)
	check(regs[0] == 0xff && regs[1] == 0x0f, "register 1 spans bytes 0 and 1")
	hll.dense_put(regs, 2, 63)
	check(regs[1] == 0xff && regs[2] == 0x03, "register 2 spans bytes 1 and 2")
	hll.dense_put(regs, 3, 63)
	check(regs[2] == 0xff && regs[3] == 0, "register 3 occupies high six bits of byte 2")
	for i in 0 ..< 4 {
		hll.dense_put(regs, i, 0)
	}
	hll.dense_put(regs, 1, 33)
	check(regs[0] == 0x40 && regs[1] == 0x08, "register 1 value 33 bit layout")
	check(hll.dense_get(regs, 0) == 0 && hll.dense_get(regs, 1) == 33 && hll.dense_get(regs, 2) == 0, "neighbours untouched")

	rng: u64 = 1
	want: [hll.HLL_REGISTERS]u8
	for round in 0 ..< 3 {
		for i in 0 ..< hll.HLL_REGISTERS {
			want[i] = u8(hll.splitmix64(&rng) & 63)
			hll.dense_put(regs, i, want[i])
		}
		bad := 0
		for i in 0 ..< hll.HLL_REGISTERS {
			if hll.dense_get(regs, i) != want[i] {
				bad += 1
			}
		}
		check(bad == 0, fmt.tprintf("dense random round trip %d", round))
	}
	for i in 0 ..< hll.HLL_REGISTERS {
		hll.dense_put(regs, i, 63)
	}
	bad := 0
	for i := 0; i < hll.HLL_REGISTERS; i += 7 {
		hll.dense_put(regs, i, 0)
		if i > 0 && hll.dense_get(regs, i - 1) != 63 {
			bad += 1
		}
		if i + 1 < hll.HLL_REGISTERS && hll.dense_get(regs, i + 1) != 63 {
			bad += 1
		}
		hll.dense_put(regs, i, 63)
	}
	check(bad == 0, "clearing a register leaves neighbours intact")
	hll.dense_put(regs, 16383, 21)
	check(hll.dense_get(regs, 16383) == 21 && hll.dense_get(regs, 16382) == 63, "last register")
	check(!hll.dense_set(regs, 16383, 20), "dense set ignores smaller value")
	check(hll.dense_set(regs, 16383, 22) && hll.dense_get(regs, 16383) == 22, "dense set stores larger value")
}

sparse_payload :: proc(b: []u8) -> string {
	return string(b[hll.HLL_HDR_SIZE:])
}

decode :: proc(b: []u8) -> string {
	d, _ := hll.hll_decode_sparse_for_debug(b, context.temp_allocator)
	return d
}

sset :: proc(b: ^[]u8, index: int, count: u8, max_bytes := hll.HLL_SPARSE_MAX_BYTES_DEFAULT) -> bool {
	changed, _ := hll.sparse_set(b, index, count, max_bytes, context.allocator)
	return changed
}

test_sparse_ops :: proc() {
	b := hll.hll_new_sparse()
	sset(&b, 1000, 2)
	sset(&b, 1020, 3)
	sset(&b, 1021, 3)
	check(sparse_payload(b) == "\x43\xe7\x84\x12\x89\x7c\x01", "documented example bytes")
	check(decode(b) == "Z:1000 v:2,1 z:19 v:3,2 Z:15362", "documented example decode")
	check(b[15] == 0x80, "sparse update invalidates cache")
	hll.hll_free(b)

	b = hll.hll_new_sparse()
	sset(&b, 64, 1)
	check(sparse_payload(b) == "\x3f\x80\x7f\xbe", "run of 64 uses ZERO")
	check(decode(b) == "z:64 v:1,1 Z:16319", "run of 64 decode")
	hll.hll_free(b)

	b = hll.hll_new_sparse()
	sset(&b, 65, 1)
	check(sparse_payload(b) == "\x40\x40\x80\x7f\xbd", "run of 65 uses XZERO")
	check(decode(b) == "Z:65 v:1,1 Z:16318", "run of 65 decode")
	hll.hll_free(b)

	b = hll.hll_new_sparse()
	sset(&b, 0, 32)
	sset(&b, 16383, 1)
	check(decode(b) == "v:32,1 Z:16382 v:1,1", "first and last registers")
	check(sparse_payload(b) == "\xfc\x7f\xfd\x80", "first and last register bytes")
	hll.hll_free(b)

	b = hll.hll_new_sparse()
	for i in 10 ..< 14 {
		sset(&b, i, 5)
	}
	check(decode(b) == "z:10 v:5,4 Z:16370", "adjacent equal values merge")
	sset(&b, 14, 5)
	check(decode(b) == "z:10 v:5,4 v:5,1 Z:16369", "merge capped at run length four")
	sset(&b, 11, 7)
	check(decode(b) == "z:10 v:5,1 v:7,1 v:5,3 Z:16369", "VAL split and remerge")
	check(!sset(&b, 11, 3), "smaller value leaves register")
	check(!sset(&b, 12, 5), "equal value leaves register")
	sset(&b, 12, 6)
	check(decode(b) == "z:10 v:5,1 v:7,1 v:6,1 v:5,2 Z:16369", "split in middle of VAL run")
	hll.hll_free(b)

	b = hll.hll_new_sparse()
	sset(&b, 5, 1)
	sset(&b, 7, 1)
	check(decode(b) == "z:5 v:1,1 z:1 v:1,1 Z:16376", "single ZERO between values")
	sset(&b, 6, 1)
	check(decode(b) == "z:5 v:1,3 Z:16376", "ZERO of one replaced then merged")
	hll.hll_free(b)

	rng: u64 = 77
	for round in 0 ..< 50 {
		sp := hll.hll_new_sparse()
		dn := make([]u8, hll.HLL_DENSE_SIZE)
		copy(dn, sp[:hll.HLL_HDR_SIZE])
		dn[4] = hll.HLL_DENSE
		n := int(hll.splitmix64(&rng) % 400)
		for _ in 0 ..< n {
			idx := int(hll.splitmix64(&rng) % hll.HLL_REGISTERS)
			if round % 3 == 0 {
				idx = int(hll.splitmix64(&rng) % 200)
			}
			val := u8(hll.splitmix64(&rng) % 32) + 1
			sset(&sp, idx, val, 1 << 20)
			hll.dense_set(dn[hll.HLL_HDR_SIZE:], idx, val)
		}
		check(sp[4] == hll.HLL_SPARSE, "random sparse stays sparse with large limit")
		a: [hll.HLL_REGISTERS]u8
		c: [hll.HLL_REGISTERS]u8
		check(hll.hll_get_registers(sp, &a) == .None, "sparse registers decode")
		hll.hll_get_registers(dn, &c)
		check(a == c, fmt.tprintf("sparse and dense registers agree round %d", round))
		check(hll.hll_estimate(sp, nil) == hll.hll_estimate(dn, nil), "sparse and dense estimates agree")
		r, _ := hll.hll_get_register(sp, 100)
		check(r == c[100], "single register lookup on sparse")
		parsed := 0
		for tok in strings.split(decode(sp), " ", context.temp_allocator) {
			if len(tok) < 3 {
				continue
			}
			rest := tok[2:]
			if tok[0] == 'v' {
				comma := strings.index_byte(rest, ',')
				run_len := 0
				for ch in rest[comma + 1:] {
					run_len = run_len * 10 + int(ch - '0')
				}
				parsed += run_len
			} else {
				run_len := 0
				for ch in rest {
					run_len = run_len * 10 + int(ch - '0')
				}
				parsed += run_len
			}
		}
		check(parsed == hll.HLL_REGISTERS, "decode runs cover all registers")
		conv, err := hll.hll_to_dense(&sp)
		check(conv && err == .None && len(sp) == hll.HLL_DENSE_SIZE, "sparse to dense converts")
		check(string(sp[hll.HLL_HDR_SIZE:]) == string(dn[hll.HLL_HDR_SIZE:]), "converted dense bytes equal direct dense bytes")
		check(sp[4] == hll.HLL_DENSE && sp[15] == 0x80 || n == 0, "conversion keeps header")
		hll.hll_free(sp)
		delete(dn)
	}
}

test_promotion :: proc() {
	b := hll.hll_new_sparse()
	check(sset(&b, 5, 32) && b[4] == hll.HLL_SPARSE, "value 32 stays sparse")
	check(sset(&b, 6, 33) && b[4] == hll.HLL_DENSE, "value 33 promotes")
	check(len(b) == hll.HLL_DENSE_SIZE, "promoted length")
	check(hll.dense_get(b[hll.HLL_HDR_SIZE:], 5) == 32 && hll.dense_get(b[hll.HLL_HDR_SIZE:], 6) == 33, "promoted registers")
	check(string(b[:4]) == "HYLL" && b[15] == 0x80, "promotion keeps header")
	hll.hll_free(b)

	b = hll.hll_new_sparse()
	lengths := make([dynamic]int, context.temp_allocator)
	for k in 1 ..= 5 {
		sset(&b, k * 100, 3, 30)
		append(&lengths, len(b) if b[4] == hll.HLL_SPARSE else -1)
	}
	check(lengths[0] == 21 && lengths[1] == 24 && lengths[2] == 27 && lengths[3] == 30, "sparse grows three bytes per split")
	check(lengths[4] == -1 && len(b) == hll.HLL_DENSE_SIZE, "exceeding the limit promotes")
	for k in 1 ..= 5 {
		check(hll.dense_get(b[hll.HLL_HDR_SIZE:], k * 100) == 3, "registers survive promotion")
	}
	hll.hll_free(b)

	b = hll.hll_new_sparse()
	for k in 1 ..= 4 {
		sset(&b, k * 100, 3, 30)
	}
	check(sset(&b, 100, 9, 20) && b[4] == hll.HLL_SPARSE && len(b) == 30, "in place update allowed above limit")
	check(sset(&b, 600, 1, 20) && b[4] == hll.HLL_DENSE, "growth above limit promotes")
	hll.hll_free(b)

	b = hll.hll_new_sparse()
	ok_count := 0
	for k in 0 ..< 40 {
		changed, err := hll.hll_add(&b, transmute([]u8)fmt.tprintf("x%d", k), 3000)
		if changed && err == .None {
			ok_count += 1
		}
	}
	check(ok_count > 30 && b[4] == hll.HLL_SPARSE, "hll_add keeps small sets sparse")
	hll.hll_free(b)
}

test_estimator :: proc() {
	check(math.is_inf(hll.hll_sigma(1), 1), "sigma(1) is infinite")
	check(hll.hll_sigma(0) == 0, "sigma(0) is zero")
	check(hll.hll_tau(0) == 0 && hll.hll_tau(1) == 0, "tau at the ends")
	l := local_make()
	defer local_destroy(&l)
	run(&l, "PFADD", "h", "a", "b", "c")
	check(run_int(&l, "PFCOUNT", "h") == 3, "count of a b c")
	run(&l, "PFADD", "h5", "1", "2", "3", "4", "5")
	check(run_int(&l, "PFCOUNT", "h5") == 5, "count 1..5")
	run(&l, "PFADD", "h5", "6", "7", "8", "8", "9", "10")
	check(run_int(&l, "PFCOUNT", "h5") == 10, "count 1..10")
	regs: [hll.HLL_REGISTERS]u8
	check(hll.hll_estimate_raw(&regs) == 0, "raw empty estimate")
	for i in 0 ..< hll.HLL_REGISTERS {
		regs[i] = 63
	}
	check(hll.hll_estimate_raw(&regs) == 1 << 63, "degenerate all-63 estimate mirrors llroundl overflow")
	check(hll.llround_to_u64(2.5) == 3 && hll.llround_to_u64(2.4999999999999996) == 2 && hll.llround_to_u64(0.5) == 1, "round half away from zero")
}

test_validate :: proc() {
	check(hll.HLL_ERR_WRONGTYPE == "WRONGTYPE Key is not a valid HyperLogLog string value.", "wrongtype text")
	check(hll.HLL_ERR_INVALIDOBJ == "INVALIDOBJ Corrupted HLL object detected", "invalidobj text")
	ok, msg := hll.hll_validate(transmute([]u8)string("HYLL"))
	check(!ok && msg == hll.HLL_ERR_WRONGTYPE, "short value rejected")
	b := hll.hll_new_sparse()
	defer hll.hll_free(b)
	ok, msg = hll.hll_validate(b)
	check(ok && msg == "", "fresh value accepted")
	b[0] = 'h'
	check(!hll.hll_is_valid(b), "bad magic rejected")
	b[0] = 'H'
	b[4] = 2
	check(!hll.hll_is_valid(b), "unknown encoding rejected")
	b[4] = hll.HLL_DENSE
	check(!hll.hll_is_valid(b), "dense with wrong length rejected")
	b[4] = hll.HLL_SPARSE
	d := make([]u8, hll.HLL_DENSE_SIZE)
	defer delete(d)
	copy(d, "HYLL")
	check(hll.hll_is_valid(d), "dense of exact length accepted")
	check(hll.hll_encoding_name(d) == "dense", "dense encoding name")
	_, dok := hll.hll_decode_sparse_for_debug(d)
	check(!dok, "decode refuses dense")
	check(hll.hll_error_message(.Wrong_Type) == hll.HLL_ERR_WRONGTYPE && hll.hll_error_message(.Corrupted) == hll.HLL_ERR_INVALIDOBJ, "error messages")
}

test_corruption :: proc() {
	b := hll.hll_new_sparse()
	hll.hll_add(&b, transmute([]u8)string("a"))
	tail := make([]u8, len(b) + 5)
	copy(tail, b)
	copy(tail[len(b):], "hello")
	hll.hll_free(b)
	invalid := false
	tail[15] |= 0x80
	hll.hll_count(tail, &invalid)
	check(invalid, "trailing garbage detected by count")
	_, uerr := hll.hll_count_union({tail})
	check(uerr == .Corrupted, "trailing garbage detected by union")
	dst: []u8
	check(hll.hll_merge(&dst, false, {tail}) == .Corrupted && dst == nil, "trailing garbage detected by merge")
	_, terr := hll.hll_to_dense(&tail)
	check(terr == .Corrupted, "trailing garbage detected by conversion")
	delete(tail)

	big := make([dynamic]u8)
	defer delete(big)
	crafted_header(&big, 1, true)
	for _ in 0 ..< 131072 + 1000 {
		append(&big, 0x7f, 0xff)
	}
	append(&big, 0xff)
	invalid = false
	hll.hll_count(big[:], &invalid)
	check(invalid, "XZERO overflow detected by count")
	_, uerr = hll.hll_count_union({big[:], big[:]})
	check(uerr == .Corrupted, "XZERO overflow detected by union")
	regs: [hll.HLL_REGISTERS]u8
	check(hll.hll_get_registers(big[:], &regs) == .Corrupted, "XZERO overflow detected by register decode")

	zero := make([dynamic]u8)
	defer delete(zero)
	crafted_header(&zero, 1, true)
	for _ in 0 ..< 300 {
		append(&zero, 0x3f)
	}
	append(&zero, 0xff)
	invalid = false
	hll.hll_count(zero[:], &invalid)
	check(invalid, "ZERO overflow detected by count")

	trunc := make([dynamic]u8)
	defer delete(trunc)
	crafted_header(&trunc, 1, true)
	append(&trunc, 0x80, 0x3f, 0x3f, 0x3f, 0x3d, 0x7f)
	invalid = false
	n := hll.hll_count(trunc[:], &invalid)
	check(!invalid && n == 1, "truncated final XZERO reads a zero byte like the sds terminator")
}

test_raw_heap_allocator :: proc() {
	a := hll.hll_raw_heap_allocator()
	b := hll.hll_new_sparse(a)
	for k in 0 ..< 5000 {
		hll.hll_add(&b, transmute([]u8)fmt.tprintf("raw%d", k), 3000, a)
	}
	check(b[4] == hll.HLL_DENSE && len(b) == hll.HLL_DENSE_SIZE, "raw heap allocator survives growth and promotion")
	c := hll.hll_new_sparse(a)
	check(hll.hll_merge(&c, true, {b}, 3000, a) == .None && c[4] == hll.HLL_DENSE, "merge with raw heap allocator")
	invalid := false
	check(hll.hll_count(c, &invalid) == hll.hll_count(b, &invalid) && !invalid, "merged count equals source")
	hll.hll_free(b, a)
	hll.hll_free(c, a)
}

run_selftest_only :: proc() -> bool {
	start := time.now()
	ok, msg := hll.hll_selftest(u64(time.now()._nsec))
	fmt.printfln("PFSELFTEST %s in %v", "OK" if ok else msg, time.since(start))
	return ok
}

run_unit :: proc() -> bool {
	tests := []struct {
		name: string,
		fn:   proc(),
	} {
		{"murmurhash64a", test_murmur},
		{"pattern length", test_pat_len},
		{"empty sparse", test_new_sparse},
		{"dense packing", test_dense_packing},
		{"sparse opcodes", test_sparse_ops},
		{"promotion", test_promotion},
		{"estimator", test_estimator},
		{"validation", test_validate},
		{"corruption", test_corruption},
		{"raw heap allocator", test_raw_heap_allocator},
	}
	for t in tests {
		before := checks_failed
		start := time.now()
		t.fn()
		free_all(context.temp_allocator)
		fmt.printfln("%-26s %s (%v)", t.name, "ok" if checks_failed == before else "FAIL", time.since(start))
	}
	selftest_ok := run_selftest_only()
	fmt.printfln("%d checks, %d failed", checks_run, checks_failed)
	return checks_failed == 0 && selftest_ok
}

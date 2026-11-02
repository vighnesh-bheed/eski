package persistence

import "core:math"
import "core:sys/linux"
import "core:testing"
import "../../src/rdb"

bytes_of :: proc(w: ^rdb.Writer) -> []u8 {
	return rdb.writer_bytes(w)
}

expect_bytes :: proc(t: ^testing.T, got: []u8, want: []u8, loc := #caller_location) -> bool {
	if len(got) != len(want) {
		testing.expectf(t, false, "length %d, want %d: %v vs %v", len(got), len(want), got, want, loc = loc)
		return false
	}
	for i in 0 ..< len(got) {
		if got[i] != want[i] {
			testing.expectf(t, false, "byte %d is %x, want %x: %v vs %v", i, got[i], want[i], got, want, loc = loc)
			return false
		}
	}
	return true
}

Len_Case :: struct {
	value: u64,
	bytes: []u8,
}

@(test)
length_encoding_boundaries :: proc(t: ^testing.T) {
	cases := []Len_Case {
		{0, {0x00}},
		{1, {0x01}},
		{63, {0x3F}},
		{64, {0x40, 0x40}},
		{255, {0x40, 0xFF}},
		{16383, {0x7F, 0xFF}},
		{16384, {0x80, 0x00, 0x00, 0x40, 0x00}},
		{0xFFFFFFFF, {0x80, 0xFF, 0xFF, 0xFF, 0xFF}},
		{0x100000000, {0x81, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00}},
		{max(u64) - 1, {0x81, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE}},
	}
	for c in cases {
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		rdb.put_len(&w, c.value)
		expect_bytes(t, bytes_of(&w), c.bytes)
		r: rdb.Reader
		rdb.reader_init_mem(&r, bytes_of(&w), false)
		v, encoded, good := rdb.get_len_enc(&r)
		testing.expect(t, good && !encoded && v == c.value)
		testing.expect_value(t, rdb.reader_offset(&r), i64(len(c.bytes)))
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
	}
}

@(test)
length_encoding_rejections :: proc(t: ^testing.T) {
	dir := test_dir()
	defer cleanup_dir(dir)
	path := join_path(dir, "stream.bin")
	for b in 0x82 ..= 0xBF {
		data := []u8{u8(b), 0, 0, 0, 0, 0, 0, 0, 0}
		r: rdb.Reader
		rdb.reader_init_mem(&r, data, false)
		v := rdb.get_len(&r)
		testing.expect_value(t, v, 0)
		testing.expect_value(t, r.status, rdb.Status.Corrupt)
		if b == 0x9B {
			testing.expect_value(t, rdb.reader_reason(&r), "Unknown length encoding 155 while reading a length")
		}
		rdb.reader_destroy(&r)
		testing.expect(t, write_file(path, data))
		fd, err := linux.open(cstr(path), {})
		testing.expect_value(t, err, linux.Errno.NONE)
		rdb.reader_init_file(&r, fd, false)
		testing.expect_value(t, rdb.get_len(&r), 0)
		testing.expect_value(t, r.status, rdb.Status.Corrupt)
		if b == 0x82 {
			testing.expect_value(t, rdb.reader_reason(&r), "Unknown length encoding 130 while reading a length")
		}
		rdb.reader_destroy(&r)
		linux.close(fd)
	}
	unknown_string := []u8{0x82, 'a'}
	r0: rdb.Reader
	rdb.reader_init_mem(&r0, unknown_string, false)
	_, sgood := rdb.get_string(&r0, 0)
	testing.expect(t, !sgood && r0.status == .Corrupt)
	rdb.reader_destroy(&r0)
	truncated := [][]u8{{}, {0x40}, {0x80, 1, 2}, {0x81, 1, 2, 3, 4, 5, 6, 7}}
	for data in truncated {
		r: rdb.Reader
		rdb.reader_init_mem(&r, data, false)
		testing.expect_value(t, rdb.get_len(&r), 0)
		testing.expect_value(t, r.status, rdb.Status.Short_Read)
		rdb.reader_destroy(&r)
	}
	encoded := []u8{0xC0}
	r: rdb.Reader
	rdb.reader_init_mem(&r, encoded, false)
	v, is_enc, good := rdb.get_len_enc(&r)
	testing.expect(t, good && is_enc && v == rdb.ENC_INT8)
	rdb.reader_destroy(&r)
}

Str_Case :: struct {
	text:  string,
	bytes: []u8,
}

@(test)
integer_string_encoding :: proc(t: ^testing.T) {
	cases := []Str_Case {
		{"0", {0xC0, 0x00}},
		{"-1", {0xC0, 0xFF}},
		{"127", {0xC0, 0x7F}},
		{"-128", {0xC0, 0x80}},
		{"128", {0xC1, 0x80, 0x00}},
		{"-129", {0xC1, 0x7F, 0xFF}},
		{"32767", {0xC1, 0xFF, 0x7F}},
		{"-32768", {0xC1, 0x00, 0x80}},
		{"32768", {0xC2, 0x00, 0x80, 0x00, 0x00}},
		{"-32769", {0xC2, 0xFF, 0x7F, 0xFF, 0xFF}},
		{"2147483647", {0xC2, 0xFF, 0xFF, 0xFF, 0x7F}},
		{"-2147483648", {0xC2, 0x00, 0x00, 0x00, 0x80}},
		{"12345", {0xC1, 0x39, 0x30}},
		{"2000000000", {0xC2, 0x00, 0x94, 0x35, 0x77}},
		{"2147483648", {0x0A, '2', '1', '4', '7', '4', '8', '3', '6', '4', '8'}},
		{"-2147483649", {0x0B, '-', '2', '1', '4', '7', '4', '8', '3', '6', '4', '9'}},
		{"9223372036854775807", {0x13, '9', '2', '2', '3', '3', '7', '2', '0', '3', '6', '8', '5', '4', '7', '7', '5', '8', '0', '7'}},
		{"007", {0x03, '0', '0', '7'}},
		{"+1", {0x02, '+', '1'}},
		{"-0", {0x02, '-', '0'}},
		{" 1", {0x02, ' ', '1'}},
		{"1 ", {0x02, '1', ' '}},
		{"1.0", {0x03, '1', '.', '0'}},
		{"-", {0x01, '-'}},
		{"", {0x00}},
	}
	for c in cases {
		w: rdb.Writer
		rdb.writer_init_mem(&w, true, false)
		rdb.put_string(&w, transmute([]u8)c.text)
		expect_bytes(t, bytes_of(&w), c.bytes)
		r: rdb.Reader
		rdb.reader_init_mem(&r, bytes_of(&w), false)
		out, ival, kind, good := rdb.get_string_kind(&r, 0)
		testing.expect(t, good)
		testing.expect_value(t, string(out), c.text)
		if c.bytes[0] >= 0xC0 {
			testing.expect_value(t, kind, rdb.String_Kind.Int)
			parsed, _ := rdb.string2ll(transmute([]u8)c.text)
			testing.expect_value(t, ival, parsed)
		} else {
			testing.expect_value(t, kind, rdb.String_Kind.Raw)
		}
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
	}
}

@(test)
ll_string_encoding :: proc(t: ^testing.T) {
	values := []i64{0, 1, -1, 127, -128, 128, 32767, -32768, 65536, i64(max(i32)), i64(min(i32)), i64(max(i32)) + 1, i64(min(i32)) - 1, max(i64), min(i64)}
	for v in values {
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		rdb.put_ll_string(&w, v)
		r: rdb.Reader
		rdb.reader_init_mem(&r, bytes_of(&w), false)
		out, _, kind, good := rdb.get_string_kind(&r, 0)
		testing.expect(t, good)
		parsed, pgood := rdb.string2ll(out)
		testing.expect(t, pgood && parsed == v)
		fits := v >= i64(min(i32)) && v <= i64(max(i32))
		testing.expect_value(t, kind, rdb.String_Kind.Int if fits else rdb.String_Kind.Raw)
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
	}
	buf: [20]u8
	testing.expect_value(t, rdb.ll2string(buf[:], min(i64)), 20)
	testing.expect_value(t, string(buf[:20]), "-9223372036854775808")
	small: [3]u8
	testing.expect_value(t, rdb.ll2string(small[:], 1234), 0)
	enc: [5]u8
	testing.expect_value(t, rdb.encode_integer(i64(max(i32)) + 1, &enc), 0)
	testing.expect_value(t, rdb.encode_integer(-5, &enc), 2)
}

@(test)
string2ll_canonical :: proc(t: ^testing.T) {
	good_cases := []string{"0", "1", "-1", "9223372036854775807", "-9223372036854775808", "10"}
	for s in good_cases {
		_, ok := rdb.string2ll(transmute([]u8)s)
		testing.expectf(t, ok, "%q should parse", s)
	}
	bad_cases := []string{"", "-", "00", "01", "-0", "+1", " 1", "1 ", "9223372036854775808", "-9223372036854775809", "1a", "99999999999999999999"}
	for s in bad_cases {
		_, ok := rdb.string2ll(transmute([]u8)s)
		testing.expectf(t, !ok, "%q should not parse", s)
	}
}

@(test)
raw_string_boundaries :: proc(t: ^testing.T) {
	sizes := []int{1, 2, 63, 64, 16383, 16384, 70000}
	for n in sizes {
		data := make([]u8, n)
		defer delete(data)
		for i in 0 ..< n {
			data[i] = u8('a' + (i * 7 + i / 3) % 26)
		}
		data[0] = 'x'
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		rdb.put_string(&w, data)
		out := bytes_of(&w)
		header := 1 if n < 64 else 2 if n < 16384 else 5
		testing.expect_value(t, len(out), header + n)
		r: rdb.Reader
		rdb.reader_init_mem(&r, out, false)
		got, good := rdb.get_string(&r, 0)
		testing.expect(t, good)
		testing.expect(t, string(got) == string(data))
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
	}
}

@(test)
lzf_compression_decisions :: proc(t: ^testing.T) {
	twenty := "aaaaaaaaaaaaaaaaaaaa"
	w: rdb.Writer
	rdb.writer_init_mem(&w, true, false)
	rdb.put_string(&w, transmute([]u8)twenty)
	testing.expect_value(t, len(bytes_of(&w)), 21)
	testing.expect_value(t, bytes_of(&w)[0], u8(20))
	rdb.writer_destroy(&w)

	hundred: [100]u8
	for &b in hundred {
		b = 'a'
	}
	rdb.writer_init_mem(&w, true, false)
	rdb.put_string(&w, hundred[:])
	expect_bytes(t, bytes_of(&w), {0xc3, 0x09, 0x40, 0x64, 0x01, 0x61, 0x61, 0xe0, 0x57, 0x00, 0x01, 0x61, 0x61})
	r: rdb.Reader
	rdb.reader_init_mem(&r, bytes_of(&w), false)
	out, _, kind, good := rdb.get_string_kind(&r, 0)
	testing.expect(t, good && kind == .Lzf && string(out) == string(hundred[:]))
	rdb.reader_destroy(&r)
	rdb.writer_destroy(&w)

	rdb.writer_init_mem(&w, false, false)
	rdb.put_string(&w, hundred[:])
	testing.expect_value(t, len(bytes_of(&w)), 102)
	rdb.writer_destroy(&w)

	noisy: [64]u8
	state: u32 = 12345
	for &b in noisy {
		state = state * 1103515245 + 12345
		b = u8(state >> 16)
	}
	rdb.writer_init_mem(&w, true, false)
	rdb.put_string(&w, noisy[:])
	testing.expect_value(t, len(bytes_of(&w)), 66)
	rdb.writer_destroy(&w)

	probe: [40]u8
	room: [64]u8
	compressed, kept := 0, 0
	seed: u32 = 99
	for attempt in 0 ..< 4000 {
		n := 21 + attempt % 19
		for i in 0 ..< n {
			seed = seed * 1103515245 + 12345
			probe[i] = 'a' if (seed >> 16) % 3 != 0 else u8('a' + (seed >> 20) % 26)
		}
		fits := rdb.lzf_compress(probe[:n], room[:n - 4]) > 0
		rdb.writer_init_mem(&w, true, false)
		rdb.put_string(&w, probe[:n])
		if fits {
			compressed += 1
			testing.expect_value(t, bytes_of(&w)[0], u8(0xC3))
		} else {
			kept += 1
			testing.expect_value(t, len(bytes_of(&w)), n + 1)
		}
		rdb.writer_destroy(&w)
	}
	testing.expect(t, compressed > 0 && kept > 0)

	twentyone := "aaaaaaaaaaaaaaaaaaaaa"
	rdb.writer_init_mem(&w, true, false)
	rdb.put_string(&w, transmute([]u8)twentyone)
	testing.expect_value(t, bytes_of(&w)[0], u8(0xC3))
	rdb.reader_init_mem(&r, bytes_of(&w), false)
	out, _, kind, good = rdb.get_string_kind(&r, 0)
	testing.expect(t, good && kind == .Lzf && string(out) == twentyone)
	rdb.reader_destroy(&r)
	rdb.writer_destroy(&w)
}

@(test)
string_encoding_rejections :: proc(t: ^testing.T) {
	Reject :: struct {
		data:   []u8,
		status: rdb.Status,
		reason: string,
	}
	cases := []Reject {
		{{0xC4}, .Corrupt, "Unknown RDB string encoding type 4"},
		{{0xFF}, .Corrupt, "Unknown RDB string encoding type 63"},
		{{0xC3, 0x05, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00}, .Corrupt, "Invalid LZF compressed string"},
		{{0xC3, 0x00, 0x05}, .Corrupt, "Invalid LZF compressed string"},
		{{0xC3, 0x02, 0x81, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02}, .Corrupt, "Invalid LZF compressed string"},
		{{0xC3, 0x40, 0x10, 0x44, 0x00, 0x01, 0x02}, .Short_Read, "Unexpected EOF reading RDB file"},
		{{0x81, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 'a'}, .Short_Read, "Unexpected EOF reading RDB file"},
		{{0xC3, 0x09, 0x40, 0x65, 0x01, 0x61, 0x61, 0xe0, 0x57, 0x00, 0x01, 0x61, 0x61}, .Corrupt, "Invalid LZF compressed string"},
		{{0xC3, 0x09, 0x40, 0x64, 0x01, 0x61}, .Short_Read, "Unexpected EOF reading RDB file"},
		{{0x05, 'a', 'b'}, .Short_Read, "Unexpected EOF reading RDB file"},
		{{0xC0}, .Short_Read, "Unexpected EOF reading RDB file"},
		{{0xC1, 0x01}, .Short_Read, "Unexpected EOF reading RDB file"},
		{{0xC2, 0x01, 0x02, 0x03}, .Short_Read, "Unexpected EOF reading RDB file"},
	}
	for c in cases {
		r: rdb.Reader
		rdb.reader_init_mem(&r, c.data, false)
		_, good := rdb.get_string(&r, 0)
		testing.expect(t, !good)
		testing.expect_value(t, r.status, c.status)
		testing.expect_value(t, rdb.reader_reason(&r), c.reason)
		rdb.reader_destroy(&r)
	}
	for data in ([][]u8{{0xC3, 0x00, 0x00}, {0xC3, 0x01, 0x00, 0x00}, {0xC3, 0x02, 0x00, 0x00, 0x61}}) {
		empty: rdb.Reader
		rdb.reader_init_mem(&empty, data, false)
		value, good := rdb.get_string(&empty, 0)
		testing.expect(t, good && len(value) == 0)
		testing.expect_value(t, empty.status, rdb.Status.Ok)
		rdb.reader_destroy(&empty)
	}
	r: rdb.Reader
	rdb.reader_init_mem(&r, {0xC4}, false)
	rdb.get_string(&r, 0)
	rdb.corrupt(&r, "second error")
	testing.expect_value(t, rdb.reader_reason(&r), "Unknown RDB string encoding type 4")
	rdb.corrupt_append(&r, "!")
	testing.expect_value(t, rdb.reader_reason(&r), "Unknown RDB string encoding type 4!")
	rdb.reader_destroy(&r)
}

@(test)
binary_doubles :: proc(t: ^testing.T) {
	values := []f64{0, 1.5, -2, 1e300, -1e-300, 4.9e-324, math.inf_f64(1), math.inf_f64(-1), 1.0 / 3.0}
	for v in values {
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		rdb.put_double_bin(&w, v)
		out := bytes_of(&w)
		testing.expect_value(t, len(out), 8)
		bits := transmute(u64)v
		for i in 0 ..< 8 {
			testing.expect_value(t, out[i], u8(bits >> (8 * uint(i))))
		}
		r: rdb.Reader
		rdb.reader_init_mem(&r, out, false)
		got, good := rdb.get_double_bin(&r)
		testing.expect(t, good && transmute(u64)got == bits)
		rdb.reader_destroy(&r)
		rdb.writer_destroy(&w)
	}
	one_and_half := transmute([8]u8)u64(0x3FF8000000000000)
	expect_bytes(t, one_and_half[:], {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF8, 0x3F})
	nan := math.nan_f64()
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	rdb.put_double_bin(&w, nan)
	r: rdb.Reader
	rdb.reader_init_mem(&r, bytes_of(&w), false)
	got, good := rdb.get_double_bin(&r)
	testing.expect(t, good && math.is_nan(got))
	rdb.reader_destroy(&r)
	rdb.writer_destroy(&w)
	rdb.reader_init_mem(&r, {1, 2, 3}, false)
	_, good = rdb.get_double_bin(&r)
	testing.expect(t, !good && r.status == .Short_Read)
	rdb.reader_destroy(&r)
}

@(test)
text_doubles :: proc(t: ^testing.T) {
	Text :: struct {
		data:  []u8,
		value: f64,
	}
	cases := []Text {
		{{3, '1', '.', '5'}, 1.5},
		{{2, '-', '2'}, -2},
		{{6, '1', 'e', '+', '3', '0', '0'}, 1e300},
		{{1, '0'}, 0},
		{{19, '0', '.', '3', '3', '3', '3', '3', '3', '3', '3', '3', '3', '3', '3', '3', '3', '3', '3', '3'}, 0.3333333333333333},
		{{254}, math.inf_f64(1)},
		{{255}, math.inf_f64(-1)},
		{{3, 'i', 'n', 'f'}, math.inf_f64(1)},
		{{4, '-', 'i', 'n', 'f'}, math.inf_f64(-1)},
	}
	for c in cases {
		r: rdb.Reader
		rdb.reader_init_mem(&r, c.data, false)
		v, good := rdb.get_double_str(&r)
		testing.expect(t, good)
		testing.expectf(t, v == c.value, "%v != %v", v, c.value)
		rdb.reader_destroy(&r)
	}
	r: rdb.Reader
	rdb.reader_init_mem(&r, {253}, false)
	v, good := rdb.get_double_str(&r)
	testing.expect(t, good && math.is_nan(v))
	rdb.reader_destroy(&r)
	rdb.reader_init_mem(&r, {3, 'a', 'b', 'c'}, false)
	_, good = rdb.get_double_str(&r)
	testing.expect(t, !good && r.status == .Corrupt)
	rdb.reader_destroy(&r)
	rdb.reader_init_mem(&r, {5, '1', '.'}, false)
	_, good = rdb.get_double_str(&r)
	testing.expect(t, !good && r.status == .Short_Read)
	rdb.reader_destroy(&r)
	_, ok := rdb.parse_double(transmute([]u8)string("0x10"))
	testing.expect(t, !ok)
	_, ok = rdb.parse_double(transmute([]u8)string("1_000"))
	testing.expect(t, !ok)
	_, ok = rdb.parse_double(nil)
	testing.expect(t, !ok)
	d, dok := rdb.parse_double(transmute([]u8)string("-1.25e-2"))
	testing.expect(t, dok && d == -0.0125)
}

@(test)
header_and_aux_framing :: proc(t: ^testing.T) {
	w: rdb.Writer
	rdb.writer_init_mem(&w, true, true)
	rdb.put_header(&w, 1793089332, 2006144, false)
	want := []u8 {
		'R', 'E', 'D', 'I', 'S', '0', '0', '1', '2',
		0xfa, 0x09, 'r', 'e', 'd', 'i', 's', '-', 'v', 'e', 'r', 0x06, '7', '.', '4', '.', '1', '1',
		0xfa, 0x0a, 'r', 'e', 'd', 'i', 's', '-', 'b', 'i', 't', 's', 0xc0, 0x40,
		0xfa, 0x05, 'c', 't', 'i', 'm', 'e', 0xc2, 0x34, 0x5f, 0xe0, 0x6a,
		0xfa, 0x08, 'u', 's', 'e', 'd', '-', 'm', 'e', 'm', 0xc2, 0x80, 0x9c, 0x1e, 0x00,
		0xfa, 0x08, 'a', 'o', 'f', '-', 'b', 'a', 's', 'e', 0xc0, 0x00,
	}
	expect_bytes(t, bytes_of(&w), want)
	rdb.writer_destroy(&w)
	rdb.writer_init_mem(&w, true, true)
	rdb.put_header(&w, 3000000000, 1 << 40, true)
	out := bytes_of(&w)
	r: rdb.Reader
	rdb.reader_init_mem(&r, out, false)
	rdb.take(&r, 9)
	keys := []string{"redis-ver", "redis-bits", "ctime", "used-mem", "aof-base"}
	vals := []string{"7.4.11", "64", "3000000000", "1099511627776", "1"}
	for k, i in keys {
		testing.expect_value(t, rdb.get_type(&r), rdb.OPCODE_AUX)
		key, _ := rdb.get_string(&r, 0)
		testing.expect_value(t, string(key), k)
		val, _ := rdb.get_string(&r, 1)
		testing.expect_value(t, string(val), vals[i])
	}
	testing.expect_value(t, rdb.reader_offset(&r), i64(len(out)))
	rdb.reader_destroy(&r)
	rdb.writer_destroy(&w)
	rdb.writer_init_mem(&w, false, false)
	rdb.put_aux(&w, "custom", transmute([]u8)string("12"))
	rdb.put_aux_int(&w, "n", -5)
	expect_bytes(t, bytes_of(&w), {0xfa, 0x06, 'c', 'u', 's', 't', 'o', 'm', 0xc0, 0x0c, 0xfa, 0x01, 'n', 0xc0, 0xfb})
	rdb.writer_destroy(&w)
}

@(test)
trailer_with_and_without_checksum :: proc(t: ^testing.T) {
	body := "REDIS0012\xfe\x00\xfb\x01\x00\x00\x01k\x01v"
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, true)
	rdb.put_raw(&w, transmute([]u8)body)
	rdb.put_trailer(&w)
	out := bytes_of(&w)
	testing.expect_value(t, len(out), len(body) + 9)
	testing.expect_value(t, out[len(body)], u8(rdb.OPCODE_EOF))
	crc := rdb.crc64(0, out[:len(body) + 1])
	stored: u64
	for i in 0 ..< 8 {
		stored |= u64(out[len(body) + 1 + i]) << (8 * uint(i))
	}
	testing.expect_value(t, stored, crc)
	testing.expect_value(t, rdb.writer_checksum(&w), 0)
	r: rdb.Reader
	rdb.reader_init_mem(&r, out, true)
	rdb.take(&r, len(body) + 1)
	testing.expect_value(t, rdb.reader_checksum(&r), crc)
	rdb.reader_destroy(&r)
	rdb.writer_destroy(&w)

	rdb.writer_init_mem(&w, false, false)
	rdb.put_raw(&w, transmute([]u8)body)
	rdb.put_trailer(&w)
	out = bytes_of(&w)
	for i in 0 ..< 8 {
		testing.expect_value(t, out[len(body) + 1 + i], u8(0))
	}
	rdb.writer_destroy(&w)
}

@(test)
dump_payload_frame_layout :: proc(t: ^testing.T) {
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	rdb.put_type(&w, rdb.TYPE_STRING)
	rdb.put_string(&w, transmute([]u8)string("hello"))
	rdb.put_u8(&w, u8(rdb.RDB_VERSION))
	rdb.put_u8(&w, 0)
	crc := rdb.crc64(0, bytes_of(&w))
	rdb.put_ms(&w, i64(crc))
	expect_bytes(t, bytes_of(&w), {0x00, 0x05, 'h', 'e', 'l', 'l', 'o', 0x0c, 0x00, 0xa8, 0x04, 0xeb, 0xb6, 0x9f, 0x1e, 0xbe, 0x43})
	rdb.writer_destroy(&w)
	rdb.writer_init_mem(&w, false, false)
	rdb.put_type(&w, rdb.TYPE_STRING)
	rdb.put_string(&w, transmute([]u8)string("42"))
	rdb.put_u8(&w, u8(rdb.RDB_VERSION))
	rdb.put_u8(&w, 0)
	rdb.put_ms(&w, i64(rdb.crc64(0, bytes_of(&w))))
	expect_bytes(t, bytes_of(&w), {0x00, 0xc0, 0x2a, 0x0c, 0x00, 0x4a, 0x8d, 0x68, 0x3a, 0x7c, 0x49, 0xd1, 0x19})
	rdb.writer_destroy(&w)
	testing.expect(t, rdb.is_object_type(0) && rdb.is_object_type(7) && rdb.is_object_type(9) && rdb.is_object_type(25))
	testing.expect(t, !rdb.is_object_type(8) && !rdb.is_object_type(26) && !rdb.is_object_type(-1) && !rdb.is_object_type(250))
	name: [9]u8
	id := u64(0)
	charset := rdb.MODULE_NAME_CHARSET
	for c in "ReJSON-RL" {
		for i in 0 ..< len(charset) {
			if charset[i] == u8(c) {
				id = id << 6 | u64(i)
			}
		}
	}
	id = id << 10 | 3
	testing.expect_value(t, rdb.module_name_by_id(id, &name), "ReJSON-RL")
}

@(test)
file_writer_and_reader_round_trip :: proc(t: ^testing.T) {
	dir := test_dir()
	defer cleanup_dir(dir)
	path := join_path(dir, "stream.bin")
	cpath := cstr(path)
	fd, err := linux.open(cpath, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	testing.expect_value(t, err, linux.Errno.NONE)
	w: rdb.Writer
	rdb.writer_init_file(&w, fd, true, true)
	w.sync_every = 1 << 20
	big := make([]u8, 300 << 10)
	defer delete(big)
	state: u32 = 7
	for &b in big {
		state = state * 1664525 + 1013904223
		b = u8(state >> 24)
	}
	for i in 0 ..< 2000 {
		rdb.put_ll_string(&w, i64(i))
		rdb.put_string(&w, big[:i * 97 % 3000])
	}
	rdb.put_string(&w, big)
	rdb.put_string(&w, big[:WRITER_SMALL])
	rdb.put_trailer(&w)
	testing.expect(t, rdb.writer_flush(&w))
	written := rdb.writer_processed(&w)
	testing.expect_value(t, rdb.writer_checksum(&w), 0)
	rdb.writer_destroy(&w)
	linux.close(fd)
	data, ok := read_file(path)
	testing.expect(t, ok)
	defer delete(data)
	testing.expect_value(t, i64(len(data)), written)
	ticks := 0
	rfd, rerr := linux.open(cpath, {})
	testing.expect_value(t, rerr, linux.Errno.NONE)
	r: rdb.Reader
	rdb.reader_init_file(&r, rfd, true)
	r.user = &ticks
	r.progress = proc "contextless" (rr: ^rdb.Reader) {
		(^int)(rr.user)^ += 1
	}
	r.tick_every = 64 << 10
	r.next_tick = r.tick_every
	for i in 0 ..< 2000 {
		n, _, kind, good := rdb.get_string_kind(&r, 1)
		testing.expect(t, good && kind == .Int)
		v, _ := rdb.string2ll(n)
		testing.expect_value(t, v, i64(i))
		s, sgood := rdb.get_string(&r, 0)
		testing.expect(t, sgood && len(s) == i * 97 % 3000)
		if len(s) > 0 {
			testing.expect(t, s[len(s) - 1] == big[len(s) - 1])
		}
	}
	s, sgood := rdb.get_string(&r, 2)
	testing.expect(t, sgood && len(s) == len(big) && string(s) == string(big))
	s, sgood = rdb.get_string(&r, 3)
	testing.expect(t, sgood && len(s) == WRITER_SMALL)
	testing.expect_value(t, rdb.get_type(&r), rdb.OPCODE_EOF)
	crc := rdb.reader_checksum(&r)
	tail, tgood := rdb.take(&r, 8)
	testing.expect(t, tgood)
	stored: u64
	for i in 0 ..< 8 {
		stored |= u64(tail[i]) << (8 * uint(i))
	}
	testing.expect_value(t, stored, crc)
	testing.expect_value(t, rdb.reader_offset(&r), written)
	testing.expect(t, ticks > 0)
	_, good := rdb.get_u8(&r)
	testing.expect(t, !good && r.status == .Short_Read)
	rdb.reader_destroy(&r)
	linux.close(rfd)

	rfd, rerr = linux.open(cpath, {})
	rdb.reader_init_file(&r, rfd, false)
	r.limit = 100
	_, good = rdb.take(&r, 100)
	testing.expect(t, good)
	_, good = rdb.get_u8(&r)
	testing.expect(t, !good)
	rdb.reader_destroy(&r)
	linux.close(rfd)
}

WRITER_SMALL :: 1000

@(test)
writer_reports_write_errors :: proc(t: ^testing.T) {
	fd, err := linux.open("/dev/full", {.WRONLY})
	if err != .NONE {
		return
	}
	defer linux.close(fd)
	w: rdb.Writer
	rdb.writer_init_file(&w, fd, false, true)
	rdb.put_string(&w, transmute([]u8)string("hello"))
	testing.expect(t, !rdb.writer_flush(&w))
	testing.expect(t, w.failed)
	testing.expect_value(t, w.errno, linux.Errno.ENOSPC)
	big := make([]u8, 512 << 10)
	defer delete(big)
	rdb.put_raw(&w, big)
	testing.expect(t, w.failed)
	rdb.writer_destroy(&w)
}

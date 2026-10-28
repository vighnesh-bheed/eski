package aofwork

import "base:runtime"
import "core:math"
import "core:strings"
import "core:testing"
import j "../../src"

manifest_text_of :: proc(m: ^j.Aof_Manifest) -> string {
	b: [dynamic]u8
	b.allocator = context.temp_allocator
	j.aof_manifest_text(m, &b)
	return string(b[:])
}

@(test)
manifest_parse_and_write_round_trip :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	text := "file appendonly.aof.1.base.rdb seq 1 type b\nfile appendonly.aof.1.incr.aof seq 1 type i\n"
	m: j.Aof_Manifest
	ok, reason := j.aof_manifest_parse(transmute([]u8)text, &m)
	defer j.aof_manifest_free(&m)
	testing.expect(t, ok, reason)
	testing.expect(t, m.has_base)
	testing.expect_value(t, string(m.base.name[:]), "appendonly.aof.1.base.rdb")
	testing.expect_value(t, m.base_seq, 1)
	testing.expect_value(t, m.incr_seq, 1)
	testing.expect_value(t, len(m.incr), 1)
	testing.expect_value(t, manifest_text_of(&m), text)
	testing.expect_value(t, len(manifest_text_of(&m)), 88)

	with_history := "file appendonly.aof.3.base.aof seq 3 type b\nfile appendonly.aof.2.base.rdb seq 2 type h\nfile appendonly.aof.2.incr.aof seq 2 type h\nfile appendonly.aof.3.incr.aof seq 3 type i\nfile appendonly.aof.4.incr.aof seq 4 type i\n"
	h: j.Aof_Manifest
	ok, reason = j.aof_manifest_parse(transmute([]u8)with_history, &h)
	defer j.aof_manifest_free(&h)
	testing.expect(t, ok, reason)
	testing.expect_value(t, len(h.history), 2)
	testing.expect_value(t, h.history[0].kind, j.Aof_File_Kind.History)
	testing.expect_value(t, h.incr_seq, 4)
	testing.expect_value(t, manifest_text_of(&h), with_history)

	d := j.aof_manifest_dup(&h)
	testing.expect_value(t, manifest_text_of(&d), with_history)
	j.aof_manifest_free(&d)
}

@(test)
manifest_grammar_variants :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	loose := "# comment line\r\n\n  type i   seq 2  file appendonly.aof.2.incr.aof\r\nfile \"spaced name.aof\" seq 5 type b\n"
	m: j.Aof_Manifest
	ok, reason := j.aof_manifest_parse(transmute([]u8)loose, &m)
	testing.expect(t, ok, reason)
	testing.expect_value(t, string(m.base.name[:]), "spaced name.aof")
	testing.expect_value(t, m.base_seq, 5)
	testing.expect_value(t, string(m.incr[0].name[:]), "appendonly.aof.2.incr.aof")
	testing.expect_value(t, manifest_text_of(&m), "file \"spaced name.aof\" seq 5 type b\nfile appendonly.aof.2.incr.aof seq 2 type i\n")
	j.aof_manifest_free(&m)

	escaped := "file \"a\\x41\\n\" seq 1 type b\n"
	ok, reason = j.aof_manifest_parse(transmute([]u8)escaped, &m)
	testing.expect(t, ok, reason)
	testing.expect_value(t, string(m.base.name[:]), "aA\n")
	testing.expect_value(t, manifest_text_of(&m), "file \"aA\\n\" seq 1 type b\n")
	j.aof_manifest_free(&m)

	Bad :: struct {
		text:   string,
		reason: string,
	}
	bads := []Bad {
		{"file a seq 1 type b\nfile b seq 2 type b\n", "Found duplicate base file information"},
		{"file a seq 2 type i\nfile b seq 2 type i\n", "Found a non-monotonic sequence number"},
		{"file a seq 1 type x\n", "Unknown AOF file type"},
		{"file a seq 1\n", "Invalid AOF manifest file format"},
		{"file a seq zero type b\n", "Invalid AOF file sequence number"},
		{"file a/b seq 1 type b\n", "Invalid AOF file name"},
		{"file \"open seq 1 type b\n", "Invalid AOF manifest file format"},
		{"# nothing\n", "Found an empty AOF manifest"},
		{"file h seq 1 type h\n", "Found an empty AOF manifest"},
	}
	for bad in bads {
		ok, reason = j.aof_manifest_parse(transmute([]u8)bad.text, &m)
		testing.expectf(t, !ok, "accepted %q", bad.text)
		testing.expect_value(t, reason, bad.reason)
		j.aof_manifest_free(&m)
	}
	long := strings.concatenate({"file ", strings.repeat("x", 1100, context.temp_allocator), " seq 1 type b\n"}, context.temp_allocator)
	ok, reason = j.aof_manifest_parse(transmute([]u8)long, &m)
	testing.expect(t, !ok)
	testing.expect_value(t, reason, "The AOF manifest file contains too long line")
	j.aof_manifest_free(&m)
}

@(test)
file_names_follow_layout :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	b: [dynamic]u8
	defer delete(b)
	j.aof_name(&b, 7, "base.aof")
	testing.expect_value(t, string(b[:]), "appendonly.aof.7.base.aof")
	j.aof_name(&b, 12, "incr.aof")
	testing.expect_value(t, string(b[:]), "appendonly.aof.12.incr.aof")
	j.aof_name(&b, 1, "base.rdb")
	testing.expect_value(t, string(b[:]), "appendonly.aof.1.base.rdb")
	j.aof_manifest_name(&b)
	testing.expect_value(t, string(b[:]), "appendonly.aof.manifest")
	j.aof_temp_incr_name(&b)
	testing.expect_value(t, string(b[:]), "temp-appendonly.aof.incr")
	j.aof_path(&b, "x.aof")
	testing.expect_value(t, string(b[:]), "appendonlydir/x.aof")
	tmp: [64]u8
	testing.expect_value(t, j.aof_temp_base_name(tmp[:], 4242, true), "temp-rewriteaof-bg-4242.aof")
	testing.expect_value(t, j.aof_temp_base_name(tmp[:], 4242, false), "temp-rewriteaof-4242.aof")
	cbuf: [128]u8
	testing.expect_value(t, string(j.aof_cpath("f", cbuf[:])), "appendonlydir/f")
}

@(test)
record_framing_helpers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	b: [dynamic]u8
	defer delete(b)
	j.aof_select_into(&b, 12)
	j.aof_put_header(&b, 3)
	j.aof_put_str(&b, "SET")
	j.aof_put_arg(&b, transmute([]u8)string("k"))
	j.aof_put_int(&b, -42)
	testing.expect_value(t, string(b[:]), "*2\r\n$6\r\nSELECT\r\n$2\r\n12\r\n*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\n-42\r\n")
	sbuf: [64]u8
	Case :: struct {
		v:    f64,
		want: string,
	}
	cases := []Case {
		{1.5, "1.5"},
		{-2, "-2"},
		{0, "0"},
		{1e300, "1e+300"},
		{0.3333333333333333, "0.3333333333333333"},
		{57.666666666666664, "57.666666666666664"},
		{3479099956230698, "3479099956230698"},
		{1e21, "1e+21"},
		{1e-7, "1e-7"},
		{0.000001, "0.000001"},
		{-1.25e-10, "-1.25e-10"},
	}
	for cs in cases {
		testing.expect_value(t, string(j.aof_format_score(&sbuf, cs.v)), cs.want)
	}
	inf := math.inf_f64(1)
	testing.expect_value(t, string(j.aof_format_score(&sbuf, inf)), "inf")
	testing.expect_value(t, string(j.aof_format_score(&sbuf, -inf)), "-inf")
}

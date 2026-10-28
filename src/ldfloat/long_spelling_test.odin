package ldfloat

import "core:testing"

Built :: struct {
	head:    string,
	fill:    string,
	count:   int,
	tail:    string,
	text:    string,
	outcome: Outcome,
}

build_spelling :: proc(dst: []u8, head, fill: string, count: int, tail: string) -> string {
	n := copy(dst, head)
	for _ in 0 ..< count {
		n += copy(dst[n:], fill)
	}
	n += copy(dst[n:], tail)
	return string(dst[:n])
}

@(test)
long_spellings_observed_on_redis :: proc(t: ^testing.T) {
	cases := [?]Built{
		{"", "0", 5000, "1", "1", .Text},
		{"", "0", 5118, "1", "1", .Text},
		{"", "0", 5119, "1", "", .Not_Float},
		{"0.", "0", 4900, "1", "0", .Text},
		{"0.", "0", 5000, "1", "", .Not_Float},
		{"1.", "0", 5000, "1", "1", .Text},
		{"-", "0", 5000, "1.5", "-1.5", .Text},
		{"1", "0", 4931, "", reply_1e4931, .Text},
		{"1", "0", 4932, "", reply_1e4932, .Text},
		{"1", "0", 4933, "", "", .Not_Float},
		{"1", "0", 4000, ".5", reply_1e4000, .Text},
		{"", "1234567890", 400, "", reply_built_123_400, .Text},
		{"", "9", 4932, "", reply_1e4932, .Text},
		{"", "9", 4933, "", "", .Not_Float},
		{"0x", "f", 1000, "", reply_built_0x_f_1000, .Text},
		{"0x", "f", 4095, "", reply_built_0x_f_4095, .Text},
		{"0x", "f", 4096, "", "", .Not_Float},
		{"0x", "0", 5000, "1", "1", .Text},
		{"0x1.", "0", 5000, "1p0", "1", .Text},
		{"0x1.", "0", 5000, "1p-16445", "0", .Text},
		{"0x", "0", 5000, "1p-16445", "0", .Text},
		{"0x1p", "0", 5, "", "1", .Text},
		{"1e", "0", 5, "", "1", .Text},
		{"1e", "0", 5100, "", "1", .Text},
		{"0.", "0", 4900, "1e4900", "0.1", .Text},
		{"1.5e-", "0", 3, "1", "0.15", .Text},
	}
	spelling: [MAX_LONG_DOUBLE_CHARS + 64]u8
	for c in cases {
		incr := build_spelling(spelling[:], c.head, c.fill, c.count, c.tail)
		check_reply(t, Reply{incr, c.text, c.outcome})
	}
}

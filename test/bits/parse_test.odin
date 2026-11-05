package bits_test

import "core:testing"
import bm "../../src/bitmap"

b :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

@(test)
error_strings_are_exact :: proc(t: ^testing.T) {
	want := [bm.Error]string {
		.None               = "",
		.Bit_Value          = "bit is not an integer or out of range",
		.Bit_Offset         = "bit offset is not an integer or out of range",
		.Not_Integer        = "value is not an integer or out of range",
		.Bit_Argument       = "The bit argument must be 1 or 0.",
		.Bitop_Not_Arity    = "BITOP NOT must be called with a single source key.",
		.Bitfield_Type      = "Invalid bitfield type. Use something like i16 u8. Note that u64 is not supported but i64 is.",
		.Overflow_Type      = "Invalid OVERFLOW type specified",
		.Syntax             = "syntax error",
		.Bitfield_Read_Only = "BITFIELD_RO only supports the GET subcommand",
		.Out_Of_Memory      = "out of memory",
	}
	for e in bm.Error {
		testing.expect_value(t, bm.error_message(e), want[e])
		testing.expect_value(t, bm.ERROR_MESSAGES[e], want[e])
	}
	testing.expect_value(t, bm.error_message(bm.Error(250)), "")
	testing.expect_value(t, bm.ERR_BIT_VALUE, want[.Bit_Value])
	testing.expect_value(t, bm.ERR_BIT_OFFSET, want[.Bit_Offset])
	testing.expect_value(t, bm.ERR_NOT_INTEGER, want[.Not_Integer])
	testing.expect_value(t, bm.ERR_BIT_ARGUMENT, want[.Bit_Argument])
	testing.expect_value(t, bm.ERR_BITOP_NOT, want[.Bitop_Not_Arity])
	testing.expect_value(t, bm.ERR_BITFIELD_TYPE, want[.Bitfield_Type])
	testing.expect_value(t, bm.ERR_OVERFLOW_TYPE, want[.Overflow_Type])
	testing.expect_value(t, bm.ERR_SYNTAX, want[.Syntax])
	testing.expect_value(t, bm.ERR_BITFIELD_RO, want[.Bitfield_Read_Only])
	testing.expect_value(t, bm.ERR_OUT_OF_MEMORY, want[.Out_Of_Memory])
}

@(test)
strict_integer_parsing :: proc(t: ^testing.T) {
	Good :: struct {
		text:  string,
		value: i64,
	}
	good := []Good {
		{"0", 0},
		{"1", 1},
		{"-1", -1},
		{"9223372036854775807", max(i64)},
		{"-9223372036854775808", min(i64)},
		{"4294967296", 4294967296},
		{"10", 10},
	}
	for g in good {
		v, ok := bm.parse_ll(b(g.text))
		testing.expectf(t, ok && v == g.value, "%q -> %v %v", g.text, v, ok)
		w, err := bm.parse_integer(b(g.text))
		testing.expect_value(t, err, bm.Error.None)
		testing.expect_value(t, w, g.value)
	}
	bad := []string {
		"",
		"-",
		"-0",
		"00",
		"01",
		"+5",
		" 1",
		"1 ",
		"1\x00",
		"1.5",
		"0x10",
		"#3",
		"a",
		"9223372036854775808",
		"-9223372036854775809",
		"18446744073709551616",
		"99999999999999999999",
		"123456789012345678901",
		"--1",
		"1-",
	}
	for s in bad {
		_, ok := bm.parse_ll(b(s))
		testing.expectf(t, !ok, "%q should be rejected", s)
		_, err := bm.parse_integer(b(s))
		testing.expect_value(t, err, bm.Error.Not_Integer)
	}
}

@(test)
keyword_parsing :: proc(t: ^testing.T) {
	testing.expect(t, string(bm.c_string(b("bit\x00junk"))) == "bit")
	testing.expect(t, string(bm.c_string(b("plain"))) == "plain")
	testing.expect(t, len(bm.c_string(b("\x00x"))) == 0)
	testing.expect(t, bm.equal_fold(b("BiT"), "bit"))
	testing.expect(t, bm.equal_fold(b("byte"), "BYTE"))
	testing.expect(t, !bm.equal_fold(b("bits"), "bit"))
	testing.expect(t, !bm.equal_fold(b("bi"), "bit"))
	testing.expect(t, !bm.equal_fold(b("b\x00t"), "bit"))
	testing.expect(t, bm.equal_fold(nil, ""))
	Unit_Case :: struct {
		text: string,
		unit: bm.Unit,
		err:  bm.Error,
	}
	units := []Unit_Case {
		{"BIT", .Bit, .None},
		{"bit", .Bit, .None},
		{"bIt", .Bit, .None},
		{"Byte", .Byte, .None},
		{"bit\x00junk", .Bit, .None},
		{"byte\x00x", .Byte, .None},
		{"", .Byte, .Syntax},
		{"BITS", .Byte, .Syntax},
		{"bytes", .Byte, .Syntax},
		{"hello", .Byte, .Syntax},
	}
	for c in units {
		u, err := bm.parse_unit(b(c.text))
		testing.expectf(t, err == c.err && (err != .None || u == c.unit), "%q -> %v %v", c.text, u, err)
	}
	Op_Case :: struct {
		text: string,
		op:   bm.Bitop,
		err:  bm.Error,
	}
	ops := []Op_Case {
		{"and", .And, .None},
		{"AND", .And, .None},
		{"aNd", .And, .None},
		{"Or", .Or, .None},
		{"xOR", .Xor, .None},
		{"NOt", .Not, .None},
		{"not\x00x", .Not, .None},
		{"", .And, .Syntax},
		{"an", .And, .Syntax},
		{"FOO", .And, .Syntax},
		{"nand", .And, .Syntax},
	}
	for c in ops {
		op, err := bm.parse_bitop(b(c.text))
		testing.expectf(t, err == c.err && (err != .None || op == c.op), "%q -> %v %v", c.text, op, err)
	}
	testing.expect_value(t, bm.check_bitop_arity(.Not, 1), bm.Error.None)
	testing.expect_value(t, bm.check_bitop_arity(.Not, 2), bm.Error.Bitop_Not_Arity)
	testing.expect_value(t, bm.check_bitop_arity(.And, 1), bm.Error.None)
	testing.expect_value(t, bm.check_bitop_arity(.Xor, 7), bm.Error.None)
	Overflow_Case :: struct {
		text: string,
		mode: bm.Overflow,
		err:  bm.Error,
	}
	modes := []Overflow_Case {
		{"WRAP", .Wrap, .None},
		{"sat", .Sat, .None},
		{"fAiL", .Fail, .None},
		{"fail\x00x", .Fail, .None},
		{"", .Wrap, .Overflow_Type},
		{"BAD", .Wrap, .Overflow_Type},
		{"saturate", .Wrap, .Overflow_Type},
	}
	for c in modes {
		m, err := bm.parse_overflow(b(c.text))
		testing.expectf(t, err == c.err && (err != .None || m == c.mode), "%q -> %v %v", c.text, m, err)
	}
	Type_Case :: struct {
		text:   string,
		signed: bool,
		bits:   int,
		err:    bm.Error,
	}
	types := []Type_Case {
		{"i1", true, 1, .None},
		{"i64", true, 64, .None},
		{"u1", false, 1, .None},
		{"u63", false, 63, .None},
		{"u8\x00junk", false, 8, .None},
		{"u64", false, 0, .Bitfield_Type},
		{"i65", true, 0, .Bitfield_Type},
		{"i0", true, 0, .Bitfield_Type},
		{"u0", false, 0, .Bitfield_Type},
		{"I8", true, 0, .Bitfield_Type},
		{"U8", false, 0, .Bitfield_Type},
		{"x8", false, 0, .Bitfield_Type},
		{"i", true, 0, .Bitfield_Type},
		{"", false, 0, .Bitfield_Type},
		{"i08", true, 0, .Bitfield_Type},
		{"i-8", true, 0, .Bitfield_Type},
		{"i+8", true, 0, .Bitfield_Type},
		{"i 8", true, 0, .Bitfield_Type},
		{"i8 ", true, 0, .Bitfield_Type},
	}
	for c in types {
		signed, bits, err := bm.parse_bitfield_type(b(c.text))
		testing.expectf(t, err == c.err && (err != .None || (signed == c.signed && bits == c.bits)), "%q -> %v %v %v", c.text, signed, bits, err)
	}
}

@(test)
offset_and_bit_value_parsing :: proc(t: ^testing.T) {
	Offset_Case :: struct {
		text: string,
		hash: bool,
		bits: int,
		want: u64,
		err:  bm.Error,
	}
	cases := []Offset_Case {
		{"0", false, 0, 0, .None},
		{"4294967295", false, 0, 4294967295, .None},
		{"4294967296", false, 0, 0, .Bit_Offset},
		{"-1", false, 0, 0, .Bit_Offset},
		{"-0", false, 0, 0, .Bit_Offset},
		{"00", false, 0, 0, .Bit_Offset},
		{"+5", false, 0, 0, .Bit_Offset},
		{" 1", false, 0, 0, .Bit_Offset},
		{"1 ", false, 0, 0, .Bit_Offset},
		{"1\x00", false, 0, 0, .Bit_Offset},
		{"1.5", false, 0, 0, .Bit_Offset},
		{"0x10", false, 0, 0, .Bit_Offset},
		{"", false, 0, 0, .Bit_Offset},
		{"#3", false, 8, 0, .Bit_Offset},
		{"#3", true, 8, 24, .None},
		{"3", true, 8, 3, .None},
		{"#", true, 8, 0, .Bit_Offset},
		{"##1", true, 8, 0, .Bit_Offset},
		{"#-1", true, 8, 0, .Bit_Offset},
		{"9223372036854775807", false, 0, 0, .Bit_Offset},
		{"-9223372036854775808", false, 0, 0, .Bit_Offset},
		{"18446744073709551616", false, 0, 0, .Bit_Offset},
		{"#2305843009213693953", true, 8, 8, .None},
		{"#1152921504606846977", true, 16, 16, .None},
		{"#4611686018427387904", true, 2, 0, .Bit_Offset},
		{"#536870911", true, 8, 4294967288, .None},
		{"#536870912", true, 8, 0, .Bit_Offset},
	}
	for c in cases {
		got, err := bm.parse_bit_offset(b(c.text), c.hash, c.bits)
		testing.expectf(t, err == c.err && got == c.want, "%q hash=%v bits=%d -> %v %v", c.text, c.hash, c.bits, got, err)
	}
	Value_Case :: struct {
		text: string,
		on:   bool,
		err:  bm.Error,
	}
	values := []Value_Case {
		{"0", false, .None},
		{"1", true, .None},
		{"2", false, .Bit_Value},
		{"-1", false, .Bit_Value},
		{"01", false, .Bit_Value},
		{"+1", false, .Bit_Value},
		{"-0", false, .Bit_Value},
		{"1 ", false, .Bit_Value},
		{"1\x00", false, .Bit_Value},
		{"", false, .Bit_Value},
		{"true", false, .Bit_Value},
		{"9223372036854775808", false, .Bit_Value},
	}
	for c in values {
		on, err := bm.parse_bit_value(b(c.text))
		testing.expectf(t, err == c.err && on == c.on, "%q -> %v %v", c.text, on, err)
	}
}

args_of :: proc(words: ..string) -> [][]u8 {
	out := make([][]u8, len(words), context.temp_allocator)
	for w, i in words {
		out[i] = transmute([]u8)w
	}
	return out
}

@(test)
range_argument_parsing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Count_Case :: struct {
		args: [][]u8,
		want: bm.Bitcount_Args,
		err:  bm.Error,
	}
	counts := []Count_Case {
		{args_of(), {}, .None},
		{args_of("0"), {}, .Syntax},
		{args_of("0", "1"), {0, 1, .Byte, true}, .None},
		{args_of("-5", "-1", "bit"), {-5, -1, .Bit, true}, .None},
		{args_of("0", "1", "bit\x00junk"), {0, 1, .Bit, true}, .None},
		{args_of("0", "1", "BITS"), {}, .Syntax},
		{args_of("0", "1", ""), {}, .Syntax},
		{args_of("0", "1", "bit", "extra"), {}, .Syntax},
		{args_of("a", "1"), {}, .Not_Integer},
		{args_of("1", "a"), {}, .Not_Integer},
		{args_of("a", "b", "BITS"), {}, .Not_Integer},
		{args_of("-0", "1"), {}, .Not_Integer},
		{args_of("9223372036854775808", "1"), {}, .Not_Integer},
	}
	for c in counts {
		got, err := bm.parse_bitcount_args(c.args)
		testing.expect_value(t, err, c.err)
		if c.err == .None {
			testing.expect_value(t, got, c.want)
		}
	}
	Pos_Case :: struct {
		args: [][]u8,
		want: bm.Bitpos_Args,
		err:  bm.Error,
	}
	positions := []Pos_Case {
		{args_of("1"), {0, -1, .Byte, true, false, false}, .None},
		{args_of("0", "3"), {3, -1, .Byte, false, true, false}, .None},
		{args_of("0", "3", "-2"), {3, -2, .Byte, false, true, true}, .None},
		{args_of("1", "3", "9", "BIT"), {3, 9, .Bit, true, true, true}, .None},
		{args_of("1", "0", "1", "byte\x00x"), {0, 1, .Byte, true, true, true}, .None},
		{args_of("2"), {}, .Bit_Argument},
		{args_of("-1"), {}, .Bit_Argument},
		{args_of("a"), {}, .Not_Integer},
		{args_of(""), {}, .Not_Integer},
		{args_of("01"), {}, .Not_Integer},
		{args_of("1", "a"), {}, .Not_Integer},
		{args_of("1", "0", "a"), {}, .Not_Integer},
		{args_of("1", "0", "1", "BITS"), {}, .Syntax},
		{args_of("1", "0", "1", "bit", "x"), {}, .Syntax},
		{args_of("1", "0", "a", "BITS"), {}, .Syntax},
		{args_of("1", "a", "1", "BITS"), {}, .Not_Integer},
		{args_of("2", "0", "1", "BITS"), {}, .Bit_Argument},
		{args_of("a", "0", "1", "2", "3"), {}, .Not_Integer},
		{args_of("1", "0", "1", "2", "3", "4"), {}, .Syntax},
		{args_of("0", "1", "hello", "hello2"), {}, .Syntax},
		{args_of("0", "a", "b"), {}, .Not_Integer},
	}
	for c in positions {
		got, err := bm.parse_bitpos_args(c.args)
		if err != c.err || (c.err == .None && got != c.want) {
			testing.expectf(t, false, "%v -> %v %v, want %v %v", c.args, got, err, c.want, c.err)
		}
	}
}

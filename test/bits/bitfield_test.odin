package bits_test

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import bm "../../src/bitmap"

field_limits :: proc(bits: int, signed: bool) -> (lo, hi: i64) {
	if signed {
		if bits == 64 {
			return min(i64), max(i64)
		}
		hi = i64((u64(1) << u64(bits - 1)) - 1)
		return -hi - 1, hi
	}
	return 0, i64((u64(1) << u64(bits)) - 1)
}

interesting_value :: proc(bits: int, signed: bool) -> i64 {
	lo, hi := field_limits(bits, signed)
	switch rand.int_max(12) {
	case 0:
		return 0
	case 1:
		return 1
	case 2:
		return -1
	case 3:
		return hi
	case 4:
		return lo
	case 5:
		return hi + 1 if hi < max(i64) else hi
	case 6:
		return lo - 1 if lo > min(i64) else lo
	case 7:
		return min(i64)
	case 8:
		return max(i64)
	case 9:
		return min(i64) + i64(rand.int_max(1000))
	case 10:
		return i64(rand.uint64())
	}
	span := u64(hi - lo) if hi - lo > 0 else max(u64)
	return lo + i64(rand.uint64() % (span + 1 if span < max(u64) else span))
}

@(test)
field_get_set_every_width :: proc(t: ^testing.T) {
	buf := make([]u8, 40)
	model := make([]u8, 40)
	defer delete(buf)
	defer delete(model)
	for signed in ([]bool{false, true}) {
		top := 64 if signed else 63
		for bits in 1 ..= top {
			for _ in 0 ..< 60 {
				n := 1 + rand.int_max(len(buf))
				view := buf[:n]
				mirror := model[:n]
				fill_random(view)
				copy(mirror, view)
				offset := u64(rand.int_max(n * 8 + 16))
				got := bm.get_unsigned_bitfield(view, offset, u64(bits))
				want := ref_get_field(mirror, offset, bits, false)
				testing.expect_value(t, got, u64(want))
				sgot := bm.get_signed_bitfield(view, offset, u64(bits))
				testing.expect_value(t, sgot, ref_get_field(mirror, offset, bits, true))
				op := bm.Field_Command{offset = offset, bits = u8(bits), signed = signed}
				testing.expect_value(t, bm.bitfield_get(view, op), ref_get_field(mirror, offset, bits, signed))
				if offset + u64(bits) <= u64(n) * 8 {
					value := rand.uint64()
					if signed {
						bm.set_signed_bitfield(view, offset, u64(bits), i64(value))
					} else {
						bm.set_unsigned_bitfield(view, offset, u64(bits), value)
					}
					ref_set_field(mirror, offset, bits, value)
					testing.expect(t, string(view) == string(mirror))
				}
			}
		}
	}
}

@(test)
field_access_beyond_end_reads_zero :: proc(t: ^testing.T) {
	data := []u8{0xff, 0xff, 0xff}
	testing.expect_value(t, bm.get_unsigned_bitfield(data, 20, 8), 0xf0)
	testing.expect_value(t, bm.get_unsigned_bitfield(data, 24, 8), 0)
	testing.expect_value(t, bm.get_signed_bitfield(data, 16, 16), i64(-256))
	testing.expect_value(t, bm.get_unsigned_bitfield(nil, 0, 63), 0)
	testing.expect_value(t, bm.get_signed_bitfield(data, 0, 64), i64(-1 << 40))
	partial := []u8{0, 0, 0}
	bm.set_unsigned_bitfield(partial, 20, 8, 0xff)
	testing.expect_value(t, partial[2], 0x0f)
}

Field_Case :: struct {
	text:   string,
	opcode: bm.Bitfield_Opcode,
	bits:   int,
	signed: bool,
	offset: u64,
	arg:    i64,
	mode:   bm.Overflow,
}

@(test)
field_programs_match_reference :: proc(t: ^testing.T) {
	prog: bm.Bitfield_Program
	defer bm.bitfield_program_destroy(&prog)
	cases := make([dynamic]Field_Case)
	defer delete(cases)
	words := make([dynamic]string)
	defer delete(words)
	args := make([dynamic][]u8)
	defer delete(args)
	buf: []u8
	capacity := 0
	defer bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	model := make([dynamic]u8)
	defer delete(model)
	for _ in 0 ..< 3000 {
		clear(&cases)
		clear(&args)
		for w in words {
			delete(w)
		}
		clear(&words)
		mode := bm.Overflow.Wrap
		ops := 1 + rand.int_max(6)
		for _ in 0 ..< ops {
			if rand.int_max(4) == 0 {
				mode = bm.Overflow(rand.int_max(3))
				names := [3]string{"wRaP", "SAT", "fail"}
				append(&words, strings.clone("OVERFLOW"), strings.clone(names[mode]))
			}
			signed := rand.int_max(2) == 0
			bits := 1 + rand.int_max(64 if signed else 63)
			opcode := bm.Bitfield_Opcode(rand.int_max(3))
			index := u64(rand.int_max(400))
			hashed := rand.int_max(3) == 0
			offset := index * u64(bits) if hashed else index
			arg := interesting_value(bits, signed)
			type_text := fmt.aprintf("%s%d", "i" if signed else "u", bits)
			offset_text := fmt.aprintf("#%d", index) if hashed else fmt.aprintf("%d", index)
			names := [3]string{"get", "SET", "IncrBy"}
			append(&words, strings.clone(names[opcode]), type_text, offset_text)
			if opcode != .Get {
				append(&words, fmt.aprintf("%d", arg))
			}
			append(&cases, Field_Case{opcode = opcode, bits = bits, signed = signed, offset = offset, arg = arg, mode = mode})
		}
		for w in words {
			append(&args, transmute([]u8)w)
		}
		err := bm.bitfield_parse(&prog, args[:])
		testing.expect_value(t, err, bm.Error.None)
		if err != .None {
			continue
		}
		testing.expect_value(t, len(prog.ops), len(cases))
		if rand.int_max(10) == 0 {
			bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
			clear(&model)
		}
		changes, xerr := bm.bitfield_execute(&buf, &prog, bm.RAW_HEAP_ALLOCATOR, &capacity)
		testing.expect_value(t, xerr, bm.Error.None)
		highest: u64
		writes := false
		for c in cases {
			if c.opcode != .Get {
				writes = true
				highest = max(highest, c.offset + u64(c.bits) - 1)
			}
		}
		model_before := len(model)
		if writes {
			for u64(len(model)) <= highest / 8 {
				append(&model, 0)
			}
		}
		grown := len(model) > model_before
		testing.expect_value(t, prog.readonly, !writes)
		want_changes := 0
		for c, k in cases {
			old := ref_get_field(model[:], c.offset, c.bits, c.signed)
			reply := prog.replies[k]
			if c.opcode == .Get {
				testing.expect_value(t, reply.null, false)
				testing.expect_value(t, reply.value, old)
				continue
			}
			outcome := ref_field_op(old, c.opcode, c.arg, c.bits, c.signed, c.mode)
			if reply.null != outcome.null || (!outcome.null && reply.value != outcome.reply) {
				testing.expectf(t, false, "op %v %s%d @%d arg %d mode %v old %d: got %v want %v", c.opcode, "i" if c.signed else "u", c.bits, c.offset, c.arg, c.mode, old, reply, outcome)
			}
			if !outcome.null {
				mask := (u64(1) << u64(c.bits)) - 1 if c.bits < 64 else max(u64)
				if grown || (u64(old) ~ u64(outcome.stored)) & mask != 0 {
					want_changes += 1
				}
				ref_set_field(model[:], c.offset, c.bits, u64(outcome.stored))
			}
		}
		testing.expect_value(t, changes, want_changes)
		testing.expect(t, string(buf) == string(model[:]))
	}
	for w in words {
		delete(w)
	}
}

@(test)
overflow_rules_at_field_limits :: proc(t: ^testing.T) {
	Signed_Case :: struct {
		value, incr: i64,
		bits:        u64,
		mode:        bm.Overflow,
		bound:       bm.Field_Bound,
		stored:      i64,
		ok:          bool,
	}
	signed_cases := []Signed_Case{
		{min(i64), 0, 8, .Sat, .Above, 127, true},
		{-9223372036854775681, 0, 8, .Sat, .Above, 127, true},
		{-9223372036854775680, 0, 8, .Sat, .Below, -128, true},
		{min(i64), 0, 63, .Sat, .Above, 4611686018427387903, true},
		{min(i64), 0, 1, .Sat, .Above, 0, true},
		{-9223372036854775807, 0, 1, .Sat, .Below, -1, true},
		{127, 1, 8, .Wrap, .Above, -128, true},
		{-5, -3, 64, .Fail, .Within, -8, true},
		{max(i64), 1, 64, .Sat, .Above, max(i64), true},
		{max(i64), 1, 64, .Fail, .Above, max(i64), false},
		{min(i64), -1, 64, .Wrap, .Below, max(i64), true},
	}
	for c in signed_cases {
		testing.expect_value(t, bm.signed_bound(c.value, c.incr, c.bits), c.bound)
		stored, ok := bm.signed_settle(c.value, c.incr, c.bits, c.mode)
		testing.expect_value(t, ok, c.ok)
		if ok {
			testing.expect_value(t, stored, c.stored)
		}
	}
	Unsigned_Case :: struct {
		value:  u64,
		incr:   i64,
		bits:   u64,
		mode:   bm.Overflow,
		bound:  bm.Field_Bound,
		stored: u64,
		ok:     bool,
	}
	unsigned_cases := []Unsigned_Case{
		{max(u64), 0, 8, .Sat, .Above, 255, true},
		{0, -1, 63, .Sat, .Below, 0, true},
		{9223372036854775807, min(i64), 63, .Wrap, .Below, 9223372036854775807, true},
		{9223372036854775807, -9223372036854775807, 63, .Fail, .Within, 0, true},
		{250, 10, 8, .Wrap, .Above, 4, true},
		{250, 10, 8, .Fail, .Above, 0, false},
	}
	for c in unsigned_cases {
		testing.expect_value(t, bm.unsigned_bound(c.value, c.incr, c.bits), c.bound)
		stored, ok := bm.unsigned_settle(c.value, c.incr, c.bits, c.mode)
		testing.expect_value(t, ok, c.ok)
		if ok {
			testing.expect_value(t, stored, c.stored)
		}
	}
	testing.expect_value(t, bm.unsigned_wrap(3, -5, 4), 14)
	testing.expect_value(t, bm.signed_wrap(min(i64), 0, 1), 0)
	testing.expect_value(t, bm.signed_wrap(100, 100, 8), -56)
	testing.expect_value(t, bm.signed_wrap(max(i64), 1, 64), min(i64))
}

parse_words :: proc(prog: ^bm.Bitfield_Program, text: string, read_only := false, limit := bm.PROTO_MAX_BULK_LEN) -> bm.Error {
	fields := strings.split(text, " ")
	defer delete(fields)
	args := make([][]u8, len(fields))
	defer delete(args)
	for f, i in fields {
		args[i] = transmute([]u8)f
	}
	if text == "" {
		return bm.bitfield_parse(prog, nil, read_only, limit)
	}
	return bm.bitfield_parse(prog, args, read_only, limit)
}

@(test)
bitfield_parse_errors_and_order :: proc(t: ^testing.T) {
	prog: bm.Bitfield_Program
	defer bm.bitfield_program_destroy(&prog)
	Expect :: struct {
		text: string,
		ro:   bool,
		err:  bm.Error,
	}
	cases := []Expect {
		{"", false, .None},
		{"FOO", false, .Syntax},
		{"GET u8", false, .Syntax},
		{"SET u8 0", false, .Syntax},
		{"INCRBY u8 0", false, .Syntax},
		{"OVERFLOW", false, .Syntax},
		{"GET u8 0 OVERFLOW", false, .Syntax},
		{"OVERFLOW BAD GET u8 0", true, .Overflow_Type},
		{"OVERFLOW  GET u8 0", false, .Overflow_Type},
		{"GET u64 0", false, .Bitfield_Type},
		{"GET i65 0", false, .Bitfield_Type},
		{"GET i0 0", false, .Bitfield_Type},
		{"GET x8 0", false, .Bitfield_Type},
		{"GET I8 0", false, .Bitfield_Type},
		{"GET U8 0", false, .Bitfield_Type},
		{"GET i08 0", false, .Bitfield_Type},
		{"GET i-8 0", false, .Bitfield_Type},
		{"GET i+8 0", false, .Bitfield_Type},
		{"GET i 0", false, .Bitfield_Type},
		{"GET u8 a", false, .Bit_Offset},
		{"GET u8 -1", false, .Bit_Offset},
		{"GET u8 #-1", false, .Bit_Offset},
		{"GET u8 #", false, .Bit_Offset},
		{"GET u8 ##1", false, .Bit_Offset},
		{"GET u8 4294967296", false, .Bit_Offset},
		{"GET u8 #536870912", false, .Bit_Offset},
		{"GET u8 #536870911", false, .None},
		{"GET i64 4294967295", false, .None},
		{"GET i2 #4611686018427387904", false, .Bit_Offset},
		{"GET i8 #2305843009213693953", false, .None},
		{"SET u8 0 a", true, .Not_Integer},
		{"INCRBY i8 0 x", false, .Not_Integer},
		{"SET i64 0 9223372036854775808", false, .Not_Integer},
		{"SET u8 0 01", false, .Not_Integer},
		{"SET u8 0 -0", false, .Not_Integer},
		{"SET u8 0 1 SET u8 x 1", true, .Bit_Offset},
		{"SET u8 0 1", true, .Bitfield_Read_Only},
		{"OVERFLOW FAIL INCRBY u2 0 100", true, .Bitfield_Read_Only},
		{"OVERFLOW sat GET u8 0", true, .None},
		{"SET u8 4294967288 1", false, .None},
		{"SET u8 4294967289 1", false, .None},
		{"SET i64 4294967295 1", false, .None},
		{"INCRBY u8 4294967295 1", false, .None},
		{"SET u8 4294967296 1", false, .Bit_Offset},
		{"SET u1 4294967295 1", false, .None},
	}
	for c in cases {
		err := parse_words(&prog, c.text, c.ro)
		if err != c.err {
			testing.expectf(t, false, "%q ro=%v: got %v want %v", c.text, c.ro, err, c.err)
		}
	}
	testing.expect_value(t, parse_words(&prog, "GET i8 #2305843009213693953"), bm.Error.None)
	testing.expect_value(t, prog.ops[0].offset, 8)
	testing.expect_value(t, parse_words(&prog, "SET u8 120 1", false, 16), bm.Error.None)
	testing.expect_value(t, parse_words(&prog, "SET u8 121 1", false, 16), bm.Error.None)
	testing.expect_value(t, prog.last_written_bit, 128)
	testing.expect_value(t, parse_words(&prog, "SET u8 128 1", false, 16), bm.Error.Bit_Offset)
	testing.expect_value(t, parse_words(&prog, "GET u8 127", false, 16), bm.Error.None)
	testing.expect_value(t, parse_words(&prog, "GET u8 128", false, 16), bm.Error.Bit_Offset)
	testing.expect_value(t, parse_words(&prog, "SET u8 3 7 INCRBY i16 #2 -1 GET u4 0"), bm.Error.None)
	testing.expect_value(t, prog.readonly, false)
	testing.expect_value(t, prog.last_written_bit, 47)
	testing.expect_value(t, len(prog.ops), 3)
	testing.expect_value(t, prog.ops[1].offset, 32)
	testing.expect_value(t, prog.ops[1].signed, true)
	testing.expect_value(t, prog.ops[1].value, -1)
	testing.expect_value(t, prog.ops[2].opcode, bm.Bitfield_Opcode.Get)
	with_nul := [][]u8{transmute([]u8)string("get\x00x"), transmute([]u8)string("u8\x00junk"), transmute([]u8)string("0")}
	testing.expect_value(t, bm.bitfield_parse(&prog, with_nul), bm.Error.None)
	testing.expect_value(t, prog.ops[0].bits, 8)
	bad_nul := [][]u8{transmute([]u8)string("get"), transmute([]u8)string("u8"), transmute([]u8)string("1\x00")}
	testing.expect_value(t, bm.bitfield_parse(&prog, bad_nul), bm.Error.Bit_Offset)
	fail_nul := [][]u8{transmute([]u8)string("overflow"), transmute([]u8)string("fail\x00x"), transmute([]u8)string("incrby"), transmute([]u8)string("u2"), transmute([]u8)string("0"), transmute([]u8)string("100")}
	testing.expect_value(t, bm.bitfield_parse(&prog, fail_nul), bm.Error.None)
	testing.expect_value(t, prog.ops[0].overflow, bm.Overflow.Fail)
}

@(test)
bitfield_failed_writes_still_grow :: proc(t: ^testing.T) {
	prog: bm.Bitfield_Program
	defer bm.bitfield_program_destroy(&prog)
	buf: []u8
	capacity := 0
	defer bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	testing.expect_value(t, parse_words(&prog, "OVERFLOW FAIL SET u8 0 256"), bm.Error.None)
	changes, err := bm.bitfield_execute(&buf, &prog, bm.RAW_HEAP_ALLOCATOR, &capacity)
	testing.expect_value(t, err, bm.Error.None)
	testing.expect_value(t, changes, 0)
	testing.expect_value(t, len(buf), 1)
	testing.expect_value(t, prog.replies[0].null, true)
	testing.expect_value(t, parse_words(&prog, "GET u8 0 GET i64 100"), bm.Error.None)
	testing.expect_value(t, prog.readonly, true)
	empty: []u8
	changes, err = bm.bitfield_execute(&empty, &prog)
	testing.expect_value(t, changes, 0)
	testing.expect(t, empty == nil)
	testing.expect_value(t, len(prog.replies), 2)
}

@(test)
bitfield_writes_may_extend_past_the_limit :: proc(t: ^testing.T) {
	prog: bm.Bitfield_Program
	defer bm.bitfield_program_destroy(&prog)
	buf: []u8
	capacity := 0
	defer bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	run :: proc(t: ^testing.T, prog: ^bm.Bitfield_Program, buf: ^[]u8, capacity: ^int, text: string) -> i64 {
		testing.expect_value(t, parse_words(prog, text, false, 16), bm.Error.None)
		_, err := bm.bitfield_execute(buf, prog, bm.RAW_HEAP_ALLOCATOR, capacity)
		testing.expect_value(t, err, bm.Error.None)
		return prog.replies[0].value
	}
	testing.expect_value(t, run(t, &prog, &buf, &capacity, "SET i64 127 1"), 0)
	testing.expect_value(t, len(buf), 24)
	testing.expect_value(t, run(t, &prog, &buf, &capacity, "SET u8 121 3"), 0)
	testing.expect_value(t, run(t, &prog, &buf, &capacity, "GET i64 127"), -4611686018427387903)
	testing.expect_value(t, run(t, &prog, &buf, &capacity, "INCRBY u8 121 1"), 4)
	testing.expect_value(t, len(buf), 24)
	testing.expect_value(t, parse_words(&prog, "SET u8 128 1", false, 16), bm.Error.Bit_Offset)
}

@(test)
bitfield_counts_only_changed_fields :: proc(t: ^testing.T) {
	prog: bm.Bitfield_Program
	defer bm.bitfield_program_destroy(&prog)
	buf: []u8
	capacity := 0
	defer bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	Change_Case :: struct {
		text:    string,
		changes: int,
		length:  int,
	}
	cases := []Change_Case {
		{"GET u8 0 GET i64 100", 0, 0},
		{"OVERFLOW FAIL SET u8 100 300", 0, 14},
		{"SET u8 0 0", 0, 14},
		{"INCRBY u8 0 0", 0, 14},
		{"OVERFLOW FAIL INCRBY u8 0 255", 1, 14},
		{"SET u8 0 255", 0, 14},
		{"OVERFLOW SAT INCRBY u8 0 9", 0, 14},
		{"OVERFLOW FAIL INCRBY u8 0 1", 0, 14},
		{"INCRBY u8 0 256", 0, 14},
		{"INCRBY u8 0 1", 1, 14},
		{"SET i8 8 -1 SET i8 8 -1 SET u8 8 255", 1, 14},
		{"SET i4 16 -8 SET u4 16 8 INCRBY u4 16 16", 1, 14},
		{"OVERFLOW SAT SET i8 24 -9223372036854775808", 1, 14},
		{"OVERFLOW SAT SET i8 24 1000", 0, 14},
		{"SET u8 0 7 SET u8 8 7 GET u8 0", 2, 14},
		{"SET u8 112 0", 1, 15},
		{"SET u8 112 0", 0, 15},
		{"SET u8 112 0 SET u8 0 7", 0, 15},
		{"OVERFLOW FAIL SET u8 200 300", 0, 26},
		{"OVERFLOW FAIL INCRBY u8 0 255 INCRBY u8 8 0", 0, 26},
	}
	for c in cases {
		testing.expect_value(t, parse_words(&prog, c.text), bm.Error.None)
		changes, err := bm.bitfield_execute(&buf, &prog, bm.RAW_HEAP_ALLOCATOR, &capacity)
		testing.expect_value(t, err, bm.Error.None)
		if changes != c.changes || len(buf) != c.length {
			testing.expectf(t, false, "%q: changes %d len %d, want %d %d", c.text, changes, len(buf), c.changes, c.length)
		}
	}
}

dirty_step :: proc(t: ^testing.T, prog: ^bm.Bitfield_Program, buf: ^[]u8, capacity: ^int, text: string, counted: bool) {
	testing.expect_value(t, parse_words(prog, text), bm.Error.None)
	changes, err := bm.bitfield_execute(buf, prog, bm.RAW_HEAP_ALLOCATOR, capacity)
	testing.expect_value(t, err, bm.Error.None)
	if (changes > 0) != counted {
		testing.expectf(t, false, "%q: changes %d, want counted=%v", text, changes, counted)
	}
}

@(test)
bitfield_change_counting_sequence :: proc(t: ^testing.T) {
	prog: bm.Bitfield_Program
	defer bm.bitfield_program_destroy(&prog)
	buf: []u8
	capacity := 0
	defer bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	dirty_step(t, &prog, &buf, &capacity, "SET i5 0 0", true)
	testing.expect_value(t, len(buf), 1)
	dirty_step(t, &prog, &buf, &capacity, "SET i5 0 0", false)
	dirty_step(t, &prog, &buf, &capacity, "SET i5 0 1", true)
	dirty_step(t, &prog, &buf, &capacity, "SET i5 0 1", false)
	dirty_step(t, &prog, &buf, &capacity, "INCRBY i5 0 0", false)
	dirty_step(t, &prog, &buf, &capacity, "INCRBY i5 0 32", false)
	testing.expect_value(t, prog.replies[0].value, 1)
	dirty_step(t, &prog, &buf, &capacity, "OVERFLOW FAIL INCRBY i5 0 100", false)
	testing.expect_value(t, prog.replies[0].null, true)
	dirty_step(t, &prog, &buf, &capacity, "SET i5 90 0", true)
	testing.expect_value(t, len(buf), 12)
	dirty_step(t, &prog, &buf, &capacity, "SET i5 90 0", false)
	bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	dirty_step(t, &prog, &buf, &capacity, "OVERFLOW FAIL SET u8 100 300", false)
	testing.expect_value(t, len(buf), 14)
	bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	dirty_step(t, &prog, &buf, &capacity, "OVERFLOW FAIL INCRBY u8 0 255", true)
	testing.expect_value(t, prog.replies[0].value, 255)
}

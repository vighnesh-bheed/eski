package streams_test

import decimal "../../src/decimal"
import st "../../src/streamtype"
import "core:strings"
import "core:testing"

MAXU :: max(u64)

Id_Case :: struct {
	arg:       string,
	ok:        bool,
	id:        st.ID,
	seq_given: bool,
}

@(test)
id_parsing_for_xadd :: proc(t: ^testing.T) {
	long_one := strings.concatenate({strings.repeat("0", 126, context.temp_allocator), "1"}, context.temp_allocator)
	too_long := strings.concatenate({strings.repeat("0", 127, context.temp_allocator), "1"}, context.temp_allocator)
	cases := []Id_Case {
		{"1-1", true, {1, 1}, true},
		{"5", true, {5, 0}, true},
		{"5-*", true, {5, 0}, false},
		{"0-*", true, {0, 0}, false},
		{" 7", true, {7, 0}, true},
		{"\t7-1", true, {7, 1}, true},
		{"+7", true, {7, 0}, true},
		{"007", true, {7, 0}, true},
		{"7-007", true, {7, 7}, true},
		{"5\x00junk", true, {5, 0}, true},
		{"6-1\x00-2", true, {6, 1}, true},
		{"0--05", true, {0, MAXU - 4}, true},
		{"18446744073709551615-18446744073709551615", true, {MAXU, MAXU}, true},
		{long_one, true, {1, 0}, true},
		{too_long, false, {}, false},
		{"-", false, {}, false},
		{"+", false, {}, false},
		{"abc", false, {}, false},
		{"1-2-3", false, {}, false},
		{"1-", false, {}, false},
		{"-1", false, {}, false},
		{"1--1", false, {}, false},
		{"-0", false, {}, false},
		{"1.5", false, {}, false},
		{"0x10", false, {}, false},
		{"", false, {}, false},
		{"18446744073709551616", false, {}, false},
		{"1-18446744073709551616", false, {}, false},
		{"-18446744073709551615", false, {}, false},
		{"7 ", false, {}, false},
		{"*-1", false, {}, false},
		{"1-**", false, {}, false},
		{"1-+", false, {}, false},
		{"(1", false, {}, false},
		{"-05", false, {}, false},
	}
	for c in cases {
		id, mode, ok := st.parse_xadd_id(bytes_of(c.arg))
		seq_given := mode == .Explicit
		testing.expectf(t, ok == c.ok, "parse %q ok=%v want %v", c.arg, ok, c.ok)
		if ok && c.ok {
			testing.expectf(t, id == c.id, "parse %q id=%v want %v", c.arg, id, c.id)
			testing.expectf(t, seq_given == c.seq_given, "parse %q seq_given=%v", c.arg, seq_given)
		}
	}
}

@(test)
id_parsing_ranges :: proc(t: ^testing.T) {
	id, ok := st.parse_exact_id(bytes_of("-"))
	testing.expect(t, !ok)
	id, ok = st.parse_exact_id(bytes_of("12-3"))
	testing.expect(t, ok && id == st.ID{12, 3})
	full, fok := st.parse_id_or_sentinel(bytes_of("-"), 0)
	testing.expect(t, fok && full == st.ID_MIN)
	full, fok = st.parse_id_or_sentinel(bytes_of("+"), 0)
	testing.expect(t, fok && full == st.ID_MAX)
	full, fok = st.parse_id_or_sentinel(bytes_of("9"), MAXU)
	testing.expect(t, fok && full == st.ID{9, MAXU})
	excl, ex, eok := st.parse_range_bound(bytes_of("(5"), 0)
	testing.expect(t, eok && ex && excl == st.ID{5, 0})
	excl, ex, eok = st.parse_range_bound(bytes_of("(5"), MAXU)
	testing.expect(t, eok && ex && excl == st.ID{5, MAXU})
	_, _, eok = st.parse_range_bound(bytes_of("("), 0)
	testing.expect(t, !eok)
	_, _, eok = st.parse_range_bound(bytes_of("(-"), 0)
	testing.expect(t, !eok)
	_, _, eok = st.parse_range_bound(bytes_of("(+"), 0)
	testing.expect(t, !eok)
	_, _, eok = st.parse_range_bound(bytes_of("((5"), 0)
	testing.expect(t, !eok)
	plain, px, pok := st.parse_range_bound(bytes_of("-"), 0)
	testing.expect(t, pok && !px && plain == st.ID_MIN)
}

@(test)
id_arithmetic_and_format :: proc(t: ^testing.T) {
	a := st.ID{1, MAXU}
	testing.expect(t, st.incr_id(&a) && a == st.ID{2, 0})
	b := st.ID_MAX
	testing.expect(t, !st.incr_id(&b) && b == st.ID_MIN)
	c := st.ID{2, 0}
	testing.expect(t, st.decr_id(&c) && c == st.ID{1, MAXU})
	d := st.ID_MIN
	testing.expect(t, !st.decr_id(&d) && d == st.ID_MAX)
	testing.expect(t, st.next_id(st.ID{5, 9}, 7) == st.ID{7, 0})
	testing.expect(t, st.next_id(st.ID{5, 9}, 5) == st.ID{5, 10})
	testing.expect(t, st.next_id(st.ID{5, 9}, 3) == st.ID{5, 10})
	testing.expect(t, st.next_id(st.ID{MAXU, 2}, 3) == st.ID{MAXU, 3})
	buf: [st.ID_TEXT_MAX]u8
	testing.expect_value(t, string(st.format_id(&buf, st.ID_MAX)), "18446744073709551615-18446744073709551615")
	testing.expect_value(t, string(st.format_id(&buf, st.ID{0, 0})), "0-0")
	testing.expect_value(t, string(st.format_id(&buf, st.ID{1793090057517, 3})), "1793090057517-3")
	key: [16]u8
	st.encode_id(&key, st.ID{0x0102030405060708, 0x1112131415161718})
	testing.expect(t, key == [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18})
	testing.expect(t, st.decode_id(key[:]) == st.ID{0x0102030405060708, 0x1112131415161718})
	testing.expect(t, st.compare_id(st.ID{1, 2}, st.ID{1, 3}) < 0)
	testing.expect(t, st.compare_id(st.ID{2, 0}, st.ID{1, MAXU}) > 0)
	testing.expect(t, st.compare_id(st.ID{4, 4}, st.ID{4, 4}) == 0)
	num: [20]u8
	n := st.format_u64(&num[0], 0)
	testing.expect_value(t, string(num[:n]), "0")
	n = st.format_u64(&num[0], MAXU)
	testing.expect_value(t, string(num[:n]), "18446744073709551615")
}

@(test)
id_generation_rules :: proc(t: ^testing.T) {
	s := st.create()
	defer st.destroy(s)
	fv := args_of("f", "v")
	id, res := st.append_entry(s, fv, .Generated, {}, 1000)
	testing.expect(t, res == .Ok && id == st.ID{1000, 0})
	id, res = st.append_entry(s, fv, .Generated, {}, 999)
	testing.expect(t, res == .Ok && id == st.ID{1000, 1})
	partial := st.ID{1000, 0}
	id, res = st.append_entry(s, fv, .Generated_Seq, partial, 0)
	testing.expect(t, res == .Ok && id == st.ID{1000, 2})
	partial = st.ID{999, 0}
	_, res = st.append_entry(s, fv, .Generated_Seq, partial, 0)
	testing.expect(t, res == .Id_Not_Greater)
	partial = st.ID{2000, 0}
	id, res = st.append_entry(s, fv, .Generated_Seq, partial, 0)
	testing.expect(t, res == .Ok && id == st.ID{2000, 0})
	explicit := st.ID{2000, 0}
	_, res = st.append_entry(s, fv, .Explicit, explicit, 0)
	testing.expect(t, res == .Id_Not_Greater)
	explicit = st.ID{MAXU, MAXU}
	id, res = st.append_entry(s, fv, .Explicit, explicit, 0)
	testing.expect(t, res == .Ok && id == st.ID_MAX)
	args: st.Xadd_Spec
	_, err := st.xadd_apply(s, &args, fv, 0)
	testing.expect(t, err == .Id_Exhausted)
	args.id = st.ID{1, 0}
	args.id_mode = .Generated_Seq
	_, err = st.xadd_apply(s, &args, fv, 0)
	testing.expect(t, err == .Id_Exhausted)
	testing.expect_value(t, st.length(s), 5)
	testing.expect_value(t, s.added, 5)
	testing.expect(t, s.head == st.ID{1000, 0})
	e := st.create()
	defer st.destroy(e)
	zero := st.ID{0, 0}
	id, res = st.append_entry(e, fv, .Generated_Seq, zero, 0)
	testing.expect(t, res == .Ok && id == st.ID{0, 1})
	seqmax := st.ID{3, MAXU}
	id, res = st.append_entry(e, fv, .Explicit, seqmax, 0)
	testing.expect(t, res == .Ok && id == seqmax)
	again := st.ID{3, 0}
	_, res = st.append_entry(e, fv, .Generated_Seq, again, 0)
	testing.expect(t, res == .Id_Not_Greater)
}

@(test)
string_to_unsigned :: proc(t: ^testing.T) {
	Case :: struct {
		s:  string,
		ok: bool,
		v:  u64,
	}
	cases := []Case {
		{"0", true, 0},
		{"18446744073709551615", true, MAXU},
		{"18446744073709551616", false, 0},
		{"-5", false, 0},
		{"-05", true, MAXU - 4},
		{" 12", true, 12},
		{"\n\v\f\r 3", true, 3},
		{"+0", true, 0},
		{"12 ", false, 0},
		{"", false, 0},
		{" ", false, 0},
		{"-", false, 0},
		{"-18446744073709551615", true, 1},
		{"-18446744073709551616", false, 0},
	}
	for c in cases {
		v, ok := decimal.parse_u64_loose(bytes_of(c.s))
		testing.expectf(t, ok == c.ok && (!ok || v == c.v), "parse_u64_loose %q => %v %v", c.s, v, ok)
	}
	pv, pok := st.parse_ll(bytes_of("-9223372036854775808"))
	testing.expect(t, pok && pv == min(i64))
	_, pok = st.parse_ll(bytes_of("9223372036854775808"))
	testing.expect(t, !pok)
	_, pok = st.parse_ll(bytes_of("-0"))
	testing.expect(t, !pok)
	_, pok = st.parse_ll(bytes_of("01"))
	testing.expect(t, !pok)
	_, pok = st.parse_ll(bytes_of("+1"))
	testing.expect(t, !pok)
}

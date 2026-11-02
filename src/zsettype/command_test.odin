package zsettype

import "core:testing"
import lp "../listpack"
import rdb "../rdb"

drain_maintenance :: proc(t: ^testing.T) {
	for i := 0; i < 8192 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

@(test)
argument_contracts :: proc(t: ^testing.T) {
	for text in ([9]string{"", "-0", "+0", "01", "+1", " 1", "1 ", "9223372036854775808", "-9223372036854775809"}) {
		_, good := parse_long(transmute([]u8)text)
		testing.expect(t, !good)
	}
	for text in ([4]string{"0", "-1", "9223372036854775807", "-9223372036854775808"}) {
		_, good := parse_long(transmute([]u8)text)
		testing.expect(t, good)
	}
	testing.expect(t, keyword([]u8{'n', 'X', 0, 'a'}, "nx"))
	testing.expect(t, !eq_nocase([]u8{'n', 'X', 0, 'a'}, "nx"))
	zadd := [][]u8{[]u8{'z'}, []u8{'k'}, []u8{'n', 'x'}, []u8{'x', 'x'}, []u8{'1'}, []u8{'m'}}
	_, err := parse_zadd(zadd, false)
	testing.expect(t, err == .Xx_Nx)
	zadd[3] = []u8{'g', 't'}
	_, err = parse_zadd(zadd, false)
	testing.expect(t, err == .Gt_Lt_Nx)
	zadd[2] = []u8{'c', 'h'}
	a, zadd_err := parse_zadd(zadd, false)
	testing.expect(t, zadd_err == .None && a.ch && a.elements == 1 && a.scoreidx == 4 && .Gt in a.flags)
	zr := [][]u8{[]u8{'z'}, []u8{'k'}, []u8{'0'}, []u8{'1'}, []u8{'l', 'i', 'm', 'i', 't'}, []u8{'0'}, []u8{'2'}}
	_, err = parse_zrange(zr, 1, false, .Auto, .Auto)
	testing.expect(t, err == .Limit_Rank)
	append_dummy := [][]u8{[]u8{'z'}, []u8{'k'}, []u8{'1'}, []u8{'5'}, []u8{'b', 'y', 's', 'c', 'o', 'r', 'e'}, []u8{'l', 'i', 'm', 'i', 't'}, []u8{'-','1'}, []u8{'-','1'}}
	args, range_err := parse_zrange(append_dummy, 1, false, .Auto, .Auto)
	testing.expect(t, range_err == .None && args.kind == .Score && args.offset == -1 && args.limit == -1)
}

@(test)
range_model :: proc(t: ^testing.T) {
	set_seed(2209)
	for use_sl in ([2]bool{false, true}) {
		for lex in ([2]bool{false, true}) {
			z := create_listpack()
			if use_sl {
				convert_to_skiplist(z, 0)
			}
			for i in 0 ..< 40 {
				key := [2]u8{u8(i), 0}
				_, _, _ = add(z, lex ? 1 : f64(i / 3), key[:], {})
			}
			for exclusive in ([2]bool{false, true}) {
				r := Range_Spec{3, 7, exclusive, exclusive}
				lr := Lex_Spec{[]u8{10, 0}, []u8{20, 0}, .Value, .Value, exclusive, exclusive}
				items: [dynamic]Item
				if lex {
					lex_range(z, &lr, 0, -1, false, true, &items)
				} else {
					score_range(z, &r, 0, -1, false, &items)
				}
				expected := lex ? (exclusive ? 9 : 11) : (exclusive ? 9 : 15)
				testing.expect(t, len(items) == expected)
				if use_sl {
					for i in 0 ..< expected {
						n := lex ? sl_nth_in_lex_range(z.sl, &lr, i) : sl_nth_in_range(z.sl, &r, i)
						reverse_n := lex ? sl_nth_in_lex_range(z.sl, &lr, i - expected) : sl_nth_in_range(z.sl, &r, i - expected)
						testing.expect(t, n != nil && n == reverse_n)
						buf: [lp.DECIMAL_BUFFER_BYTES]u8
						testing.expect(t, member_eq(node_member(n), item_bytes(&items[i], &buf)))
					}
				}
				delete(items)
			}
			r := Range_Spec{3, 7, true, false}
			lr := Lex_Spec{[]u8{10, 0}, []u8{20, 0}, .Value, .Value, true, false}
			removed := lex ? remrange_by_lex(z, &lr) : remrange_by_score(z, &r)
			testing.expect(t, removed == (lex ? 10 : 12))
			testing.expect(t, length(z) == 40 - removed)
			destroy(z)
		}
	}
	drain_maintenance(t)
}

@(test)
algebra_model :: proc(t: ^testing.T) {
	set_seed(983)
	a, b := create_skiplist(0), create_listpack()
	for i in 0 ..< 50 {
		key := [2]u8{u8(i), 0}
		if i % 2 == 0 {
			_, _, _ = add(a, f64(i), key[:], {})
		}
		if i % 3 == 0 {
			_, _, _ = add(b, -f64(i), key[:], {})
		}
	}
	for op in ([3]Setop{.Union, .Inter, .Diff}) {
		for agg in ([3]Aggregate{.Sum, .Min, .Max}) {
			sources := [3]Source{source_make(a, 2), source_make(b, 3), source_make(a, -1)}
			dst, card, maxlen, totlen := setop_compute(sources[:], op, agg, false, 0)
			count := 0
			for i in 0 ..< 50 {
				key := [2]u8{u8(i), 0}
				expected_found := op == .Union ? i % 2 == 0 || i % 3 == 0 : op == .Inter ? i % 6 == 0 : false
				v, found := score(dst, key[:])
				testing.expect(t, found == expected_found)
				if !expected_found {
					continue
				}
				count += 1
				expected := i % 2 == 0 ? 2 * f64(i) : -3 * f64(i)
				if i % 6 == 0 {
					aggregate_into(&expected, -3 * f64(i), agg)
				}
				if i % 2 == 0 {
					aggregate_into(&expected, -f64(i), agg)
				}
				testing.expect(t, v == expected)
			}
			testing.expect(t, card == 0 && length(dst) == count && maxlen == (count > 0 ? 2 : 0) && totlen == 2 * count)
			destroy(dst)
		}
	}
	_, count, _, _ := setop_compute([]Source{source_make(a), source_make(b)}, .Inter, .Sum, true, 3)
	testing.expect(t, count == 3)
	_, _, _ = add(a, F64_INF, []u8{'x'}, {})
	_, _, _ = add(b, F64_NEG_INF, []u8{'x'}, {})
	dst, _, _, _ := setop_compute([]Source{source_make(a), source_make(b)}, .Union, .Sum, false, 0)
	value, found := score(dst, []u8{'x'})
	testing.expect(t, found && value == 0)
	destroy(a)
	destroy(b)
	value, found = score(dst, []u8{'x'})
	testing.expect(t, found && value == 0)
	destroy(dst)
	drain_maintenance(t)
}

@(test)
scan_random_contracts :: proc(t: ^testing.T) {
	set_seed(409)
	for use_sl in ([2]bool{false, true}) {
		z := create_listpack()
		if use_sl {
			convert_to_skiplist(z, 0)
		}
		for i in 0 ..< 70 {
			key := [2]u8{u8(i), 0}
			_, _, _ = add(z, f64(i) / 10, key[:], {})
		}
		items: [dynamic]Item
		random_unique(z, 40, &items)
		testing.expect(t, len(items) == 40)
		seen: [70]bool
		for &item in items {
			buf: [21]u8
			key := item_bytes(&item, &buf)
			testing.expect(t, len(key) == 2 && !seen[key[0]] && item.score == f64(key[0]) / 10 && !item.g17)
			seen[key[0]] = true
		}
		clear(&items)
		random_with_repeats(z, 200, &items)
		testing.expect(t, len(items) == 200)
		for &item in items {
			buf: [21]u8
			key := item_bytes(&item, &buf)
			testing.expect(t, item.score == f64(key[0]) / 10 && !item.g17)
		}
		clear(&items)
		seen = {}
		cursor: u64
		for steps := 0; steps < 4096; steps += 1 {
			clear(&items)
			cursor = scan(z, cursor, 3, &items)
			testing.expect(t, len(items) % 2 == 0)
			for i := 0; i < len(items); i += 2 {
				buf: [G17_MAX]u8
				key := scan_value_bytes(&items[i], &buf)
				testing.expect(t, !seen[key[0]])
				seen[key[0]] = true
				text := scan_value_bytes(&items[i + 1], &buf)
				value, good := parse_score(text)
				testing.expect(t, good && value == f64(key[0]) / 10)
				testing.expect(t, items[i + 1].g17 == use_sl)
			}
			if cursor == 0 {
				break
			}
		}
		for present in seen {
			testing.expect(t, present)
		}
		delete(items)
		destroy(z)
	}
	drain_maintenance(t)
}

@(test)
codec_roundtrip_and_truncation :: proc(t: ^testing.T) {
	set_seed(191)
	for use_sl in ([2]bool{false, true}) {
		z := create_listpack()
		if use_sl {
			convert_to_skiplist(z, 0)
		}
		for i in 0 ..< 16 {
			key := [3]u8{u8(i), 0, 255}
			_, _, _ = add(z, f64(i) / 10, key[:], {})
		}
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		rdb_save(&w, z)
		bytes := rdb.writer_bytes(&w)
		for deep in ([2]bool{false, true}) {
			r: rdb.Reader
			rdb.reader_init_mem(&r, bytes, false)
			copy_z := rdb_load(&r, int(rdb_type(z)), deep)
			testing.expect(t, copy_z != nil && r.status == .Ok && length(copy_z) == 16)
			for i in 0 ..< 16 {
				key := [3]u8{u8(i), 0, 255}
				value, found := score(copy_z, key[:])
				testing.expect(t, found && value == f64(i) / 10)
			}
			destroy(copy_z)
			rdb.reader_destroy(&r)
			for n in 0 ..< len(bytes) {
				rdb.reader_init_mem(&r, bytes[:n], false)
				copy_z = rdb_load(&r, int(rdb_type(z)), deep)
				testing.expect(t, copy_z == nil && r.status != .Ok)
				destroy(copy_z)
				rdb.reader_destroy(&r)
			}
		}
		rdb.writer_destroy(&w)
		destroy(z)
	}
	drain_maintenance(t)
}

@(test)
setop_output_contracts :: proc(t: ^testing.T) {
	a, b := create_listpack(), create_listpack()
	_, _, _ = add(a, 4, []u8{'a'}, {})
	_, _, _ = add(a, 8, []u8{'b', 'b'}, {})
	_, _, _ = add(b, 7, []u8{'a'}, {})
	for op in ([3]Setop{.Union, .Inter, .Diff}) {
		for cardonly in ([2]bool{false, true}) {
			for limit in ([4]int{0, 1, 2, 99}) {
				sources := [2]Source{source_make(a, 3), source_make(b, 5)}
				dst, card, maxlen, totlen := setop_compute(sources[:], op, .Sum, cardonly, limit)
				if op == .Inter && cardonly {
					testing.expect(t, dst == nil && card == 1 && maxlen == 0 && totlen == 0)
				} else {
					testing.expect(t, dst != nil && dst.encoding == .Skiplist && card == 0)
					if op == .Diff {
						v, found := score(dst, []u8{'b', 'b'})
						testing.expect(t, found && v == 8 && length(dst) == 1 && maxlen == 2 && totlen == 2)
					} else if op == .Union {
						testing.expect(t, length(dst) == 2 && maxlen == 2 && totlen == 3)
					} else {
						testing.expect(t, length(dst) == 1 && maxlen == 1 && totlen == 1)
					}
					destroy(dst)
				}
			}
		}
	}
	destroy(a)
	destroy(b)
	drain_maintenance(t)
}

@(test)
range_parser_compatibility :: proc(t: ^testing.T) {
	endpoints := []struct {
		text: string,
		bits: u64,
		exclusive, ok: bool,
	}{
		{"", 0x0000000000000000, false, true},
		{"\x28", 0x0000000000000000, true, true},
		{"\x20", 0x0000000000000000, false, false},
		{"\x20\x20", 0x0000000000000000, false, false},
		{"\x09", 0x0000000000000000, false, false},
		{"\x20\x35", 0x4014000000000000, false, true},
		{"\x09\x35", 0x4014000000000000, false, true},
		{"\x31\x65\x34\x30\x30", 0x7ff0000000000000, false, true},
		{"\x2d\x31\x65\x34\x30\x30", 0xfff0000000000000, false, true},
		{"\x31\x65\x2d\x34\x30\x30", 0x0000000000000000, false, true},
		{"\x6e\x61\x6e", 0x0000000000000000, false, false},
		{"\x2d\x6e\x61\x6e", 0x0000000000000000, false, false},
		{"\x31\x00\x78", 0x3ff0000000000000, false, true},
		{"\x28\x31\x00\x78", 0x3ff0000000000000, true, true},
		{"\x28\x20\x35", 0x4014000000000000, true, true},
		{"\x28\x20\x09", 0x0000000000000000, true, false},
		{"\x31\x78", 0x0000000000000000, false, false},
		{"\x31\x65", 0x0000000000000000, false, false},
		{"\x28\x29", 0x0000000000000000, true, false},
		{"\x28\x2b\x69\x6e\x66", 0x7ff0000000000000, true, true},
		{"\x28\x6e\x61\x6e", 0x0000000000000000, true, false},
		{"\x69\x6e\x66\x00\x74\x61\x69\x6c", 0x7ff0000000000000, false, true},
		{"\x00\x74\x61\x69\x6c", 0x0000000000000000, false, true},
	}
	for c in endpoints {
		v, ex, ok := parse_range_item(transmute([]u8)c.text)
		testing.expect(t, transmute(u64)v == c.bits && ex == c.exclusive && ok == c.ok)
	}
	ranges := []struct {
		min, max: string,
		ok: bool,
		minbits, maxbits: u64,
		minex, maxex: bool,
	}{
		{"", "\x28", true, 0x0000000000000000, 0x0000000000000000, false, true},
		{"\x20\x20", "\x31", false, 0x0000000000000000, 0x0000000000000000, false, false},
		{"\x20\x35", "\x31\x65\x34\x30\x30", true, 0x4014000000000000, 0x7ff0000000000000, false, false},
		{"\x6e\x61\x6e", "\x31", false, 0x0000000000000000, 0x0000000000000000, false, false},
		{"\x31\x00\x78", "\x32", true, 0x3ff0000000000000, 0x4000000000000000, false, false},
	}
	for c in ranges {
		r, ok := parse_range(transmute([]u8)c.min, transmute([]u8)c.max)
		testing.expect(t, ok == c.ok && transmute(u64)r.min == c.minbits && transmute(u64)r.max == c.maxbits && r.minex == c.minex && r.maxex == c.maxex)
	}
	for text in ([5]string{"", " 5", "1e400", "1e-400", "1\x00x"}) {
		_, ok := parse_score(transmute([]u8)text)
		testing.expect(t, !ok)
	}
}

@(test)
random_count_bounds :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		value: i64,
		withscores, accepted: bool,
	}{
		{"4611686018427387903", 4611686018427387903, true, true},
		{"-4611686018427387903", -4611686018427387903, true, true},
		{"4611686018427387904", 0, true, false},
		{"-4611686018427387904", 0, true, false},
		{"9223372036854770000", 0, true, false},
		{"-9223372036854770000", 0, true, false},
		{"9223372036854775807", 0, true, false},
		{"-9223372036854775807", 0, true, false},
		{"-9223372036854775808", 0, true, false},
		{"9223372036854775807", 9223372036854775807, false, true},
		{"-9223372036854775807", -9223372036854775807, false, true},
		{"-9223372036854775808", 0, false, false},
		{"0", 0, true, true},
	}
	for c in cases {
		args := [4][]u8{[]u8{'z'}, []u8{'k'}, transmute([]u8)c.text, []u8{'W', 'I', 'T', 'H', 'S', 'C', 'O', 'R', 'E', 'S'}}
		argc := c.withscores ? 4 : 3
		count, withscores, err := parse_zrandmember(args[:argc])
		testing.expect(t, (err == .None) == c.accepted)
		if c.accepted {
			testing.expect(t, count == c.value && withscores == c.withscores)
		} else {
			testing.expect(t, count == 0 && !withscores)
			expected_error := c.text == "-9223372036854775808" ? Error.Randmember_Range : Error.Out_Of_Range
			testing.expect(t, err == expected_error)
		}
	}
}

@(test)
command_argument_error_compatibility :: proc(t: ^testing.T) {
	_, err := parse_zadd([][]u8{[]u8{'z'}, []u8{'k'}, []u8{'n', 'x'}, []u8{'a'}}, true)
	testing.expect(t, err == .Syntax)
	_, err = parse_zadd([][]u8{[]u8{'z'}, []u8{'k'}, []u8{'i', 'n', 'c', 'r'}, []u8{'i', 'n', 'c', 'r'}}, true)
	testing.expect(t, err == .Syntax)
	range_args := [7][]u8{[]u8{'z'}, []u8{'k'}, []u8{'0'}, []u8{'-', '1'}, []u8{'l', 'i', 'm', 'i', 't'}, []u8{'0'}, []u8{'-', '1'}}
	a, range_err := parse_zrange(range_args[:], 1, false, .Auto, .Auto)
	testing.expect(t, range_err == .None && a.kind == .Rank && a.start == 0 && a.end == -1)
	_, range_err = parse_zrange([][]u8{[]u8{'z'}, []u8{'k'}, []u8{'0'}, []u8{'1'}, []u8{'r', 'e', 'v'}, []u8{'r', 'e', 'v'}}, 1, false, .Auto, .Auto)
	testing.expect(t, range_err == .Syntax)
	for invalid in ([2]string{"a", "1.5"}) {
		_, pop_err := parse_zpop_count([][]u8{[]u8{'z'}, []u8{'k'}, transmute([]u8)invalid})
		testing.expect(t, pop_err == .Must_Be_Positive)
	}
	_, pop_err := parse_zpop_count([][]u8{[]u8{'z'}, []u8{'k'}, []u8{'1'}, []u8{'2'}})
	testing.expect(t, pop_err == .Syntax)
	_, mpop_err := parse_zmpop([][]u8{[]u8{'z'}, []u8{'a'}, []u8{'k'}, []u8{'m', 'i', 'n'}}, 1)
	testing.expect(t, mpop_err == .Numkeys)
}

@(test)
zrange_key_index :: proc(t: ^testing.T) {
	cases := []struct {
		argv: []string,
		key_index: int,
		store: bool,
		kind_in: Range_Kind,
		dir_in: Direction,
		kind: Range_Kind,
		reverse, withscores: bool,
		start, end, offset, limit: i64,
		min, max: f64,
	}{
		{[]string{"ZRANGE", "z", "0", "-1"}, 1, false, .Auto, .Auto, .Rank, false, false, 0, -1, 0, -1, 0, 0},
		{[]string{"ZRANGE", "z", "0", "-1", "WITHSCORES"}, 1, false, .Auto, .Auto, .Rank, false, true, 0, -1, 0, -1, 0, 0},
		{[]string{"ZRANGE", "z", "0", "-1", "REV"}, 1, false, .Auto, .Auto, .Rank, true, false, 0, -1, 0, -1, 0, 0},
		{[]string{"ZRANGE", "z", "-inf", "+inf", "BYSCORE", "LIMIT", "1", "2", "WITHSCORES"}, 1, false, .Auto, .Auto, .Score, false, true, 0, 0, 1, 2, F64_NEG_INF, F64_INF},
		{[]string{"ZRANGESTORE", "dst", "src", "0", "-1"}, 2, true, .Auto, .Auto, .Rank, false, false, 0, -1, 0, -1, 0, 0},
		{[]string{"ZRANGESTORE", "dst", "src", "-inf", "+inf", "BYSCORE"}, 2, true, .Auto, .Auto, .Score, false, false, 0, 0, 0, -1, F64_NEG_INF, F64_INF},
		{[]string{"ZRANGEBYSCORE", "z", "-inf", "+inf", "WITHSCORES"}, 1, false, .Score, .Forward, .Score, false, true, 0, 0, 0, -1, F64_NEG_INF, F64_INF},
		{[]string{"ZREVRANGE", "z", "0", "-1", "WITHSCORES"}, 1, false, .Rank, .Reverse, .Rank, true, true, 0, -1, 0, -1, 0, 0},
	}
	for c in cases {
		argv: [16][]u8
		for text, i in c.argv {
			argv[i] = transmute([]u8)text
		}
		a, err := parse_zrange(argv[:len(c.argv)], c.key_index, c.store, c.kind_in, c.dir_in)
		testing.expect(t, err == .None && a.kind == c.kind && a.reverse == c.reverse && a.withscores == c.withscores)
		testing.expect(t, a.start == c.start && a.end == c.end && a.offset == c.offset && a.limit == c.limit)
		testing.expect(t, transmute(u64)a.srange.min == transmute(u64)c.min && transmute(u64)a.srange.max == transmute(u64)c.max)
	}
}

@(test)
pop_sentinel_and_random_full_order :: proc(t: ^testing.T) {
	args := [4][]u8{[]u8{'z'}, []u8{'k'}, []u8{'1'}, []u8{'e', 'x', 't', 'r', 'a'}}
	count, err := parse_zpop_count(args[:2])
	testing.expect(t, err == .None && count == -1)
	for c in ([]struct { text: string, count: i64, err: Error }{
		{"0", 0, .None},
		{"1", 1, .None},
		{"-1", 0, .Must_Be_Positive},
		{"x", 0, .Must_Be_Positive},
		{"9223372036854775807", max(i64), .None},
	}) {
		args[2] = transmute([]u8)c.text
		actual, actual_err := parse_zpop_count(args[:3])
		testing.expect(t, actual == c.count && actual_err == c.err)
	}
	_, err = parse_zpop_count(args[:])
	testing.expect(t, err == .Syntax)
	set_seed(391)
	for use_sl in ([2]bool{false, true}) {
		z := create_listpack()
		if use_sl {
			convert_to_skiplist(z, 0)
		}
		for i in 0 ..< 3 {
			key := [1]u8{u8('a' + i)}
			_, _, _ = add(z, f64(i + 1), key[:], {})
		}
		for n in ([6]int{0, 1, 2, 3, 4, 6}) {
			items := make([dynamic]Item)
			append(&items, Item{score = 99})
			random_unique(z, n, &items)
			testing.expect(t, len(items) == min(n, 3) + 1 && items[0].score == 99)
			seen: [3]bool
			previous: f64
			for &item, i in items[1:] {
				buf: [21]u8
				key := item_bytes(&item, &buf)
				testing.expect(t, len(key) == 1 && key[0] >= 'a' && key[0] <= 'c')
				index := int(key[0] - 'a')
				testing.expect(t, !seen[index] && item.score == f64(index + 1) && !item.g17)
				seen[index] = true
				if n >= 3 {
					testing.expect(t, item.score == f64(3 - i))
				} else if i > 0 {
					testing.expect(t, previous < item.score)
				}
				previous = item.score
			}
			delete(items)
		}
		destroy(z)
	}
	weights := [1]f64{1}
	_, options_err := parse_setop_options([][]u8{[]u8{'l', 'i', 'm', 'i', 't'}, []u8{'x'}}, 0, 1, .Inter, false, true, weights[:])
	testing.expect(t, options_err == .Limit_Negative)
	drain_maintenance(t)
}

@(test)
mpop_count_errors :: proc(t: ^testing.T) {
	for text in ([9]string{"x", "0", "-1", "+1", "01", "1.0", "9223372036854775808", "-9223372036854775809", "1"}) {
		for blocking in ([2]bool{false, true}) {
			args := [7][]u8{[]u8{'z'}, []u8{'0'}, []u8{'1'}, []u8{'k'}, []u8{'m', 'i', 'n'}, []u8{'c', 'o', 'u', 'n', 't'}, transmute([]u8)text}
			argv := args[:]
			idx := 2
			if !blocking {
				args[1] = []u8{'z', 'm', 'p', 'o', 'p'}
				argv = args[1:]
				idx = 1
			}
			a, err := parse_zmpop(argv, idx)
			if text == "1" {
				testing.expect(t, err == .None && a.numkeys == 1 && a.count == 1 && !a.max_end)
			} else {
				testing.expect(t, err == .Count_Positive)
			}
		}
	}
}

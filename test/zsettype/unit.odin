package zsettype_harness

import lp "../../src/listpack"
import zt "../../src/zsettype"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

b :: #force_inline proc(s: string) -> []u8 {
	return transmute([]u8)s
}

bits_of :: #force_inline proc(v: f64) -> u64 {
	return transmute(u64)v
}

unit_strtod :: proc() {
	Case :: struct {
		s:    string,
		ok:   bool,
		bits: u64,
	}
	cases := [?]Case {
		{"0", true, 0},
		{"-0", true, 0x8000_0000_0000_0000},
		{"1", true, bits_of(1)},
		{"-1.5", true, bits_of(-1.5)},
		{"0.1", true, bits_of(0.1)},
		{"inf", true, bits_of(zt.F64_INF)},
		{"+inf", true, bits_of(zt.F64_INF)},
		{"-INFINITY", true, bits_of(zt.F64_NEG_INF)},
		{"Infinity", true, bits_of(zt.F64_INF)},
		{"infinit", false, 0},
		{"nan", false, 0},
		{"-nan", false, 0},
		{"nan(12)", false, 0},
		{"", false, 0},
		{" 1", false, 0},
		{"1 ", false, 0},
		{"1e400", false, 0},
		{"-1e400", false, 0},
		{"1e-400", false, 0},
		{"0e-400", true, 0},
		{"4.9e-324", true, 1},
		{"2.4703282292062327e-324", false, 0},
		{"2.4703282292062328e-324", true, 1},
		{"1.7976931348623157e308", true, 0x7FEF_FFFF_FFFF_FFFF},
		{"1.7976931348623158e308", true, 0x7FEF_FFFF_FFFF_FFFF},
		{"1.7976931348623159e308", false, 0},
		{"2.2250738585072011e-308", true, 0x000F_FFFF_FFFF_FFFF},
		{"0x1p3", true, bits_of(8)},
		{"0X1.8P1", true, bits_of(3)},
		{"0x.8", true, bits_of(0.5)},
		{"0x10", true, bits_of(16)},
		{"0x", false, 0},
		{"0x1p", false, 0},
		{"0x1p-1074", true, 1},
		{"0x1p-1075", false, 0},
		{"0x1.8p-1075", true, 1},
		{".5", true, bits_of(0.5)},
		{"5.", true, bits_of(5)},
		{".", false, 0},
		{"+", false, 0},
		{"1e", false, 0},
		{"1e+", false, 0},
		{"9007199254740993", true, bits_of(9007199254740992)},
		{"9007199254740995", true, bits_of(9007199254740996)},
		{"0.30000000000000004", true, bits_of(0.30000000000000004)},
		{"123456789012345678901234567890", true, bits_of(123456789012345678901234567890.0)},
		{"1000000000000000000000000000000000000000000000000000000000000000000000000000000000001e-82", true, bits_of(100)},
		{"7.2057594037927933e+16", true, bits_of(72057594037927936)},
	}
	for c in cases {
		v, ok := zt.parse_score(b(c.s))
		check(ok == c.ok, fmt.tprintf("parse_score %q ok=%v", c.s, ok))
		if ok && c.ok {
			check(bits_of(v) == c.bits, fmt.tprintf("parse_score %q bits %x want %x", c.s, bits_of(v), c.bits))
		}
	}
	r, rok := zt.parse_range(b(""), b("("))
	check(rok && r.min == 0 && r.max == 0 && r.maxex && !r.minex, "empty range items parse as zero")
	_, rok = zt.parse_range(b("  "), b("1"))
	check(!rok, "whitespace only range item is invalid")
	r, rok = zt.parse_range(b(" 5"), b("1e400"))
	check(rok && r.min == 5 && r.max == zt.F64_INF, "range items accept leading space and overflow")
	_, rok = zt.parse_range(b("nan"), b("1"))
	check(!rok, "range rejects nan")
	r, rok = zt.parse_range(b("1\x00x"), b("2"))
	check(rok && r.min == 1, "range stops at a nul byte")
	rng := Rng{s = 99}
	for _ in 0 ..< 200000 {
		v := random_double(&rng)
		s := d2s(v)
		p, ok := zt.parse_score(b(s))
		check(ok && bits_of(p) == bits_of(v) || (v == 0 && p == 0), fmt.tprintf("d2string round trip %x %s", bits_of(v), s))
		s17 := g17(v)
		p2, ok2 := zt.parse_score(b(s17))
		check(ok2 && (bits_of(p2) == bits_of(v) || (v == 0 && p2 == 0)), fmt.tprintf("g17 round trip %x %s", bits_of(v), s17))
		ov, ook := strconv.parse_f64(s17)
		check(ook && bits_of(ov) == bits_of(p2), fmt.tprintf("g17 agrees with strconv %s", s17))
	}
	g17_cases := [?][2]string{{"0.1", "0.10000000000000001"}, {"1.1", "1.1000000000000001"}, {"0.500003814697265625", "0.50000381469726562"}, {"1000000000000000.25", "1000000000000000.2"}, {"1000000000000000.75", "1000000000000000.8"}, {"1e17", "1e+17"}, {"1e16", "10000000000000000"}, {"0.0001", "0.0001"}, {"0.000001", "9.9999999999999995e-07"}, {"5e-324", "4.9406564584124654e-324"}, {"-0", "-0"}, {"inf", "inf"}, {"-inf", "-inf"}, {"2.675", "2.6749999999999998"}, {"123456789012345678", "1.2345678901234568e+17"}}
	for c in g17_cases {
		v, _ := zt.parse_score(b(c[0]))
		check(g17(v) == c[1], fmt.tprintf("g17 %s -> %s want %s", c[0], g17(v), c[1]))
	}
}

Ref :: struct {
	member: string,
	score:  f64,
}

ref_less :: proc(a, b: Ref) -> bool {
	if a.score != b.score {
		return a.score < b.score
	}
	return zt.member_cmp(transmute([]u8)a.member, transmute([]u8)b.member) < 0
}

check_against :: proc(z: zt.Zset, ref: ^[dynamic]Ref, what: string) {
	slice.sort_by(ref[:], ref_less)
	check(zt.length(z) == len(ref), fmt.tprintf("%s length %d vs %d", what, zt.length(z), len(ref)))
	it := zt.iter_make(z, false)
	item: zt.Item
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	i := 0
	for zt.iter_next(&it, &item) {
		if i < len(ref) {
			check(string(zt.item_bytes(&item, &buf)) == ref[i].member && item.score == ref[i].score, fmt.tprintf("%s element %d", what, i))
		}
		i += 1
	}
	if z.encoding == .Skiplist {
		sl := z.sl
		check(sl.count == sl.length, fmt.tprintf("%s dict count", what))
		rank := 0
		prev: ^zt.Node = nil
		for n := zt.sl_first(sl); n != nil; n = zt.sl_next(n) {
			rank += 1
			check(n.backward == prev, fmt.tprintf("%s backward link", what))
			check(zt.sl_get_rank(sl, n.score, zt.node_member(n)) == u64(rank), fmt.tprintf("%s rank", what))
			check(zt.sl_get_by_rank(sl, u64(rank)) == n, fmt.tprintf("%s by rank", what))
			check(zt.dict_find(sl, zt.node_member(n), n.hash) == n, fmt.tprintf("%s dict find", what))
			prev = n
		}
		check(sl.tail == prev, fmt.tprintf("%s tail", what))
	}
	if z.encoding == .Listpack {
		v := zt.listpack_bytes(z)
		check(lp.lp_validate_integrity(raw_data(v), u64(len(v)), true, nil, nil), fmt.tprintf("%s listpack valid", what))
	}
}

unit_structure :: proc() {
	rng := Rng{s = 7}
	for enc in 0 ..< 2 {
		zt.zset_max_listpack_entries = 128 if enc == 0 else 0
		z := zt.type_create(0, 0)
		ref := make([dynamic]Ref)
		defer delete(ref)
		for step in 0 ..< 6000 {
			m := tp("m", rng_below(&rng, 300))
			op := rng_below(&rng, 10)
			if op < 6 {
				s := f64(rng_below(&rng, 50)) / 4
				_, _, ok := zt.add(z, s, b(m), {})
				check(ok, "add")
				found := false
				for &r in ref {
					if r.member == m {
						r.score = s
						found = true
					}
				}
				if !found {
					append(&ref, Ref{strings.clone(m), s})
				}
			} else if op < 9 {
				d := zt.del(z, b(m))
				idx := -1
				for r, i in ref {
					if r.member == m {
						idx = i
					}
				}
				check(d == (idx >= 0), "del result")
				if idx >= 0 {
					delete(ref[idx].member)
					unordered_remove(&ref, idx)
				}
			} else if zt.length(z) > 0 {
				it := zt.peek(z, rng_below(&rng, 2) == 0)
				buf: [lp.DECIMAL_BUFFER_BYTES]u8
				mm := strings.clone(string(zt.item_bytes(&it, &buf)), context.temp_allocator)
				zt.del(z, b(mm))
				for r, i in ref {
					if r.member == mm {
						delete(ref[i].member)
						unordered_remove(&ref, i)
						break
					}
				}
			}
			if step % 500 == 0 {
				check_against(z, &ref, fmt.tprintf("structure enc %d step %d", enc, step))
			}
			free_all(context.temp_allocator)
		}
		check_against(z, &ref, "structure final")
		r := zt.Range_Spec{min = 2, max = 6, minex = true}
		want := 0
		for x in ref {
			if x.score > 2 && x.score <= 6 {
				want += 1
			}
		}
		check(zt.count_in_range(z, &r) == want, "count in range")
		items := make([dynamic]zt.Item)
		zt.score_range(z, &r, 3, 5, false, &items)
		check(len(items) == min(5, max(0, want - 3)), "score range limit")
		delete(items)
		for x in ref {
			delete(x.member)
		}
		zt.destroy(z)
	}
	zt.zset_max_listpack_entries = 128
}

unit_scan :: proc() {
	zt.zset_max_listpack_entries = 0
	z := zt.type_create(0, 0)
	for i in 0 ..< 500 {
		zt.add(z, f64(i), b(tp("s", i)), {})
	}
	seen := make(map[string]bool)
	defer delete(seen)
	items := make([dynamic]zt.Item)
	defer delete(items)
	cursor: u64 = 0
	steps := 0
	for {
		clear(&items)
		cursor = zt.scan(z, cursor, 7, &items)
		for i := 0; i < len(items); i += 2 {
			seen[strings.clone(string(items[i].str), context.temp_allocator)] = true
		}
		steps += 1
		if steps == 20 {
			for i in 500 ..< 3000 {
				zt.add(z, f64(i), b(tp("s", i)), {})
			}
		}
		if steps == 60 {
			for i in 1000 ..< 3000 {
				zt.del(z, b(tp("s", i)))
			}
		}
		if cursor == 0 {
			break
		}
	}
	missing := 0
	for i in 0 ..< 500 {
		if tp("s", i) not_in seen {
			missing += 1
		}
	}
	check(missing == 0, fmt.tprintf("zscan guarantee across resizes, %d missing", missing))
	zt.destroy(z)
	zt.zset_max_listpack_entries = 128
	free_all(context.temp_allocator)
}

unit_listpack_bytes :: proc() {
	z := zt.create_listpack()
	zt.add(z, 1, b("a"), {})
	zt.add(z, 1.5, b("b"), {})
	zt.add(z, -2, b("10"), {})
	v := zt.listpack_bytes(z)
	want := []u8{25, 0, 0, 0, 6, 0, 0x0a, 1, 0xdf, 0xfe, 2, 0x81, 'a', 2, 1, 1, 0x81, 'b', 2, 0x83, '1', '.', '5', 4, 0xff}
	check(len(v) == len(want), fmt.tprintf("listpack length %d", len(v)))
	if len(v) == len(want) {
		check(string(v) == string(want), fmt.tprintf("listpack bytes %x", v))
	}
	zt.destroy(z)
}

unit_set_sources :: proc() {
	members := [?][]u8{b("a"), b("b"), b("c"), b("10")}
	set := zt.create_from_members(members[:])
	defer zt.destroy(set)
	zs := zt.create_listpack()
	defer zt.destroy(zs)
	zt.add(zs, 1, b("b"), {})
	zt.add(zs, 2, b("c"), {})
	zt.add(zs, 3, b("d"), {})
	srcs := [?]zt.Source{zt.source_make(set, 2), zt.source_make(zs, 3)}
	dst, _, _, _ := zt.setop_compute(srcs[:], .Union, .Sum, false, 0)
	want := [?]Ref{{"10", 2}, {"a", 2}, {"b", 5}, {"d", 9}, {"c", 8}}
	ref := make([dynamic]Ref)
	defer delete(ref)
	append(&ref, ..want[:])
	check_against(dst, &ref, "union with a set source")
	zt.destroy(dst)
	srcs2 := [?]zt.Source{zt.source_make(set, 2), zt.source_make(zs, 3)}
	dst2, _, _, _ := zt.setop_compute(srcs2[:], .Inter, .Max, false, 0)
	ref2 := make([dynamic]Ref)
	defer delete(ref2)
	append(&ref2, Ref{"b", 3}, Ref{"c", 6})
	check_against(dst2, &ref2, "inter with a set source")
	zt.destroy(dst2)
	same := zt.source_make(set)
	srcs3 := [?]zt.Source{zt.source_make(set), same}
	dst3, _, _, _ := zt.setop_compute(srcs3[:], .Diff, .Sum, false, 0)
	check(zt.length(dst3) == 0, "diff of a source with itself is empty")
	zt.destroy(dst3)
}

run_unit :: proc() -> bool {
	unit_resize()
	unit_strtod()
	unit_structure()
	unit_scan()
	unit_listpack_bytes()
	unit_set_sources()
	fmt.printfln("zsettype unit: %d checks, %d failures", checks, failures)
	return failures == 0
}

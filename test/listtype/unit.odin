package listtype_harness

import lp "../../src/listpack"
import lt "../../src/listtype"
import "core:fmt"
import "core:strings"

b :: #force_inline proc(s: string) -> []u8 {
	return transmute([]u8)s
}

vstr :: proc(v: lt.Value) -> string {
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	return strings.clone(string(lt.value_bytes(v, &buf)), context.temp_allocator)
}

contents :: proc(l: lt.List) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	it := lt.iterator(l, 0, .Tail)
	e: lt.List_Entry
	for lt.iter_next(&it, &e) {
		append(&out, vstr(lt.entry_value(&it, &e)))
	}
	return out
}

contents_reverse :: proc(l: lt.List) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	it := lt.iterator(l, -1, .Head)
	e: lt.List_Entry
	for lt.iter_next(&it, &e) {
		inject_at(&out, 0, vstr(lt.entry_value(&it, &e)))
	}
	return out
}

same :: proc(a: []string, m: []string) -> bool {
	if len(a) != len(m) {
		return false
	}
	for x, i in a {
		if x != m[i] {
			return false
		}
	}
	return true
}

invariants :: proc(l: lt.List, what: string) -> bool {
	ok := true
	if l.encoding == .Quicklist {
		ql := l.ql
		count, nodes := 0, 0
		var_prev: ^lt.Node
		for n := ql.head; n != nil; n = n.next {
			nodes += 1
			count += n.count
			ok &= n.prev == var_prev
			if n.plain {
				ok &= n.count == 1
			} else {
				ok &= n.sz == lp.lp_bytes(n.entry)
				ok &= n.count == int(lp.lp_length(n.entry))
				ok &= n.count > 0
				ok &= lp.lp_validate_integrity(n.entry, u64(n.sz), true, nil, nil)
			}
			var_prev = n
		}
		ok &= ql.tail == var_prev
		ok &= count == ql.count && nodes == ql.len
	} else {
		ok &= lp.lp_validate_integrity(l.lp, u64(lp.lp_bytes(l.lp)), true, nil, nil)
	}
	ok &= lt.memory_usage(l) == lt.memory_recount(l)
	return check(ok, fmt.tprintf("invariants hold after %s", what))
}

unit_basic :: proc() {
	saved := lt.list_max_listpack_size
	defer lt.list_max_listpack_size = saved
	lt.list_max_listpack_size = -2
	l := lt.create()
	defer lt.destroy(l)
	check(lt.length(l) == 0 && l.encoding == .Listpack, "new list is an empty listpack")
	for v in ([?]string{"a", "1", "-5", "9223372036854775807", ""}) {
		lt.push(l, b(v), .Tail)
	}
	lt.push(l, b("head"), .Head)
	check(same(contents(l)[:], {"head", "a", "1", "-5", "9223372036854775807", ""}), "push order")
	v, ok := lt.index(l, 2)
	check(ok && v.is_int && v.ival == 1, "integers stored as integers")
	v, ok = lt.index(l, -1)
	check(ok && !v.is_int && len(v.str) == 0, "empty string tail")
	_, ok = lt.index(l, 6)
	check(!ok, "index past end")
	_, ok = lt.index(l, min(int))
	check(!ok, "minimum index")
	check(lt.linsert(l, true, b("1"), b("after1")), "linsert after")
	check(!lt.linsert(l, false, b("nope"), b("x")), "linsert missing pivot")
	check(lt.lset(l, 0, b("H")) && !lt.lset(l, 100, b("x")), "lset")
	check(lt.lrem(l, 0, b("-5")) == 1, "lrem integer by string")
	positions := make([dynamic]int, context.temp_allocator)
	check(lt.lpos(l, b("a"), 1, -1, 0, &positions) == 1, "lpos")
	lt.ltrim(l, 1, -2)
	check(same(contents(l)[:], {"a", "1", "after1", "9223372036854775807"}), "ltrim")
	invariants(l, "basic")
}

unit_conversion_limits :: proc() {
	saved := lt.list_max_listpack_size
	defer lt.list_max_listpack_size = saved
	lt.list_max_listpack_size = 3
	l := lt.create()
	defer lt.destroy(l)
	for v in ([?]string{"a", "b", "c"}) {
		lt.widen_if_needed(l, 1, 1)
		lt.push(l, b(v), .Tail)
	}
	check(l.encoding == .Listpack, "three entries stay listpack at fill 3")
	lt.widen_if_needed(l, 1, 1)
	lt.push(l, b("d"), .Tail)
	check(l.encoding == .Quicklist, "fourth entry converts")
	lt.pop_discard(l, .Tail)
	lt.narrow_if_possible(l)
	check(l.encoding == .Quicklist, "three entries above half the limit stay quicklist")
	lt.pop_discard(l, .Tail)
	lt.narrow_if_possible(l)
	check(l.encoding == .Quicklist, "two entries above half of three stay quicklist")
	lt.pop_discard(l, .Tail)
	lt.narrow_if_possible(l)
	check(l.encoding == .Listpack, "one entry converts back")
	invariants(l, "conversion")
	lt.list_max_listpack_size = -2
	big := lt.create()
	defer lt.destroy(big)
	lt.widen_if_needed(big, 9000, 1)
	lt.push(big, b(strings.repeat("x", 9000, context.temp_allocator)), .Tail)
	check(big.encoding == .Quicklist && big.ql.head.plain, "large element becomes a plain node")
	invariants(big, "plain node")
}

Ref_List :: [dynamic]string

unit_random :: proc(seed: u64, ops: int) {
	r := Rng{s = seed}
	fills := [?]int{-2, -1, 1, 2, 3, 4, 8, -5}
	saved_fill := lt.list_max_listpack_size
	saved_thr := lt.plain_node_threshold
	defer {
		lt.list_max_listpack_size = saved_fill
		lt.plain_node_threshold = saved_thr
	}
	l := lt.create()
	ref := make(Ref_List)
	defer delete(ref)
	defer lt.destroy(l)
	pool := [?]string{"a", "b", "c", "1", "22", "-7", ""}
	thresholds := [?]int{0, 0, 0, 10, 100}
	positions := make([dynamic]int)
	defer delete(positions)
	for i in 0 ..< ops {
		if i % 500 == 0 {
			lt.list_max_listpack_size = fills[rng_below(&r, len(fills))]
			lt.plain_node_threshold = thresholds[rng_below(&r, len(thresholds))]
		}
		v: string
		switch rng_below(&r, 4) {
		case 0:
			v = strings.repeat("v", rng_below(&r, 300), context.temp_allocator)
		case 1:
			v = strings.repeat("w", 8000 + rng_below(&r, 2000), context.temp_allocator)
		case:
			v = pool[rng_below(&r, len(pool))]
		}
		v = strings.clone(v)
		n := len(ref)
		what := ""
		switch rng_below(&r, 11) {
		case 0, 1:
			where_ := lt.Where.Head if rng_chance(&r, 50) else lt.Where.Tail
			reps := 1 + rng_below(&r, 12)
			lt.widen_if_needed(l, len(v) * reps, reps)
			for _ in 0 ..< reps {
				lt.push(l, b(v), where_)
				if where_ == .Head {
					inject_at(&ref, 0, v)
				} else {
					append(&ref, v)
				}
			}
			what = "push"
		case 2:
			if n > 0 {
				where_ := lt.Where.Head if rng_chance(&r, 50) else lt.Where.Tail
				pv, ok := lt.peek(l, where_)
				want := ref[0] if where_ == .Head else ref[n - 1]
				check(ok && vstr(pv) == want, "peek matches")
				lt.pop_discard(l, where_)
				if where_ == .Head {
					ordered_remove(&ref, 0)
				} else {
					pop(&ref)
				}
				lt.narrow_if_possible(l)
			}
			what = "pop"
		case 3:
			idx := rng_below(&r, n + 4) - 2 - n / 2
			ok := lt.lset(l, idx, b(v))
			ri := idx if idx >= 0 else n + idx
			want := ri >= 0 && ri < n
			check(ok == want, "lset range")
			if want {
				ref[ri] = v
			}
			what = "lset"
		case 4:
			pivot := pool[rng_below(&r, len(pool))]
			after := rng_chance(&r, 50)
			ok := lt.linsert(l, after, b(pivot), b(v))
			found := -1
			for x, k in ref {
				if x == pivot {
					found = k
					break
				}
			}
			check(ok == (found >= 0), "linsert found")
			if found >= 0 {
				inject_at(&ref, found + 1 if after else found, v)
			}
			what = "linsert"
		case 5:
			target := pool[rng_below(&r, len(pool))]
			cnt := rng_below(&r, 5) - 2
			removed := lt.lrem(l, cnt, b(target))
			want := 0
			if cnt >= 0 {
				for k := 0; k < len(ref); {
					if ref[k] == target && (cnt == 0 || want < cnt) {
						ordered_remove(&ref, k)
						want += 1
					} else {
						k += 1
					}
				}
			} else {
				for k := len(ref) - 1; k >= 0; k -= 1 {
					if ref[k] == target && want < -cnt {
						ordered_remove(&ref, k)
						want += 1
					}
				}
			}
			check(removed == want, "lrem count")
			lt.narrow_if_possible(l)
			what = "lrem"
		case 6:
			s := rng_below(&r, 8) - 3
			e := rng_below(&r, 40) - 4
			lt.ltrim(l, s, e)
			ss, ee, ok := lt.range_normalize(n, s, e)
			if ok {
				nr := make(Ref_List)
				for k in ss ..= ee {
					append(&nr, ref[k])
				}
				delete(ref)
				ref = nr
			} else {
				clear(&ref)
			}
			lt.narrow_if_possible(l)
			what = "ltrim"
		case 7:
			target := pool[rng_below(&r, len(pool))]
			clear(&positions)
			lt.lpos(l, b(target), 1, 0, 0, &positions)
			want := 0
			okp := true
			for x, k in ref {
				if x == target {
					okp &= want < len(positions) && positions[want] == k
					want += 1
				}
			}
			check(okp && want == len(positions), "lpos all matches")
			what = "lpos"
		case 8:
			if n > 0 {
				cnt := 1 + rng_below(&r, 3)
				where_ := lt.Where.Head if rng_chance(&r, 50) else lt.Where.Tail
				start, rangelen := lt.pop_range_bounds(l, where_, cnt)
				lt.delete_range(l, start, rangelen)
				for _ in 0 ..< rangelen {
					if where_ == .Head {
						ordered_remove(&ref, 0)
					} else {
						pop(&ref)
					}
				}
				lt.narrow_if_possible(l)
			}
			what = "delete range"
		case 9:
			d := lt.dup(l)
			check(same(contents(d)[:], ref[:]), "dup contents")
			invariants(d, "dup")
			lt.destroy(d)
			what = "dup"
		case:
			if n > 0 {
				idx := rng_below(&r, n * 2) - n
				got, ok := lt.index(l, idx)
				ri := idx if idx >= 0 else n + idx
				check(ok && vstr(got) == ref[ri], "index")
			}
			what = "index"
		}
		if lt.length(l) == 0 {
			lt.destroy(l)
			l = lt.create()
		}
		if !check(lt.length(l) == len(ref), fmt.tprintf("length after %s", what)) {
			return
		}
		if !check(same(contents(l)[:], ref[:]), fmt.tprintf("contents after %s", what)) {
			return
		}
		if i % 7 == 0 && !check(same(contents_reverse(l)[:], ref[:]), fmt.tprintf("reverse contents after %s", what)) {
			return
		}
		if !invariants(l, what) {
			return
		}
		free_all(context.temp_allocator)
	}
}

unit_args :: proc() {
	a, err := lt.parse_lpos_args({b("RANK"), b("-2"), b("COUNT"), b("0"), b("MAXLEN"), b("5")})
	check(err == .None && a.rank == -2 && a.count == 0 && a.maxlen == 5, "lpos args")
	_, err = lt.parse_lpos_args({b("RANK"), b("0")})
	check(err == .Rank_Zero, "rank zero")
	_, err = lt.parse_lpos_args({b("RANK"), b("-9223372036854775808")})
	check(err == .Long_Range, "rank min")
	_, err = lt.parse_lpos_args({b("COUNT"), b("x")})
	check(err == .Count_Negative, "count message for non integers")
	_, err = lt.parse_lpos_args({b("RANK")})
	check(err == .Syntax, "rank without value")
	_, perr := lt.parse_pop_count(b("abc"))
	check(perr == .Must_Be_Positive, "pop count message")
	m, merr := lt.parse_mpop_args({b("lmpop"), b("2"), b("a"), b("b"), b("left"), b("count"), b("3")}, 1)
	check(merr == .None && m.numkeys == 2 && m.where_ == .Head && m.count == 3, "mpop args")
	_, merr = lt.parse_mpop_args({b("lmpop"), b("9223372036854775807"), b("a"), b("left")}, 1)
	check(merr == .Syntax, "mpop huge numkeys")
	sz, ok := lt.parse_memory(b("4kb"))
	check(ok && sz == 4096, "memory units")
	check(lt.parse_packed_threshold(b("5gb")) == .Packed_Threshold, "packed threshold limit")
	check(lt.parse_packed_threshold(b("0")) == .None && lt.plain_node_threshold == 0, "packed threshold reset")
	check(crc64(b("123456789")) == 0xe9c6d914c4b8d9ca, "crc64 jones check value")
}

run_unit :: proc() -> bool {
	unit_basic()
	unit_conversion_limits()
	unit_args()
	for seed in ([?]u64{1, 2, 3, 42, 1337}) {
		unit_random(seed, 3000)
	}
	free_all(context.temp_allocator)
	fmt.printfln("listtype unit: %d checks, %d failures", checks, failures)
	return failures == 0
}

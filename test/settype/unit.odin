package settype_harness

import lp "../../src/listpack"
import st "../../src/settype"
import "core:fmt"
import "core:slice"
import "core:strings"

unit_rng: Rng = {
	s = 0xC0FFEE,
}

u_below :: proc(n: int) -> int {
	return rng_below(&unit_rng, n)
}

bytes_hex :: proc(b: []u8) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for x in b {
		fmt.sbprintf(&sb, "%02x", x)
	}
	return strings.to_string(sb)
}

unit_intset_layout :: proc() {
	is := st.intset_new()
	added: bool
	for v in ([?]i64{5, -7, 100, 5}) {
		is, added = st.intset_add(is, v)
	}
	check(bytes_hex(st.intset_bytes(is)) == "0200000003000000f9ff05006400", "intset int16 layout")
	is, added = st.intset_add(is, 32768)
	check(added && st.intset_encoding(is) == 4, "intset upgrades to int32 on append")
	check(bytes_hex(st.intset_bytes(is)) == "0400000004000000f9ffffff050000006400000000800000", "intset int32 layout")
	is, added = st.intset_add(is, -5000000000)
	check(added && st.intset_encoding(is) == 8 && st.intset_get(is, 0) == -5000000000, "intset upgrades to int64 with prepend")
	is, added = st.intset_remove(is, -5000000000)
	check(added && st.intset_encoding(is) == 8 && st.intset_len(is) == 4, "intset never downgrades")
	is, added = st.intset_remove(is, 1 << 40)
	check(!added, "intset remove of a missing wide value")
	check(st.intset_find(is, 100) && !st.intset_find(is, 101) && !st.intset_find(is, 1 << 50), "intset find")
	lp.lp_mem_free(is)
	empty := st.intset_new()
	empty, added = st.intset_remove(empty, 3)
	check(!added && st.intset_len(empty) == 0, "intset remove from empty")
	lp.lp_mem_free(empty)
}

unit_intset_fuzz :: proc() {
	is := st.intset_new()
	ref := make([dynamic]i64, context.temp_allocator)
	for _ in 0 ..< 20000 {
		v: i64
		switch u_below(4) {
		case 0:
			v = i64(u_below(200)) - 100
		case 1:
			v = i64(u_below(200000)) - 100000
		case 2:
			v = i64(rng_next(&unit_rng))
		case 3:
			v = i64(u_below(5_000_000_000)) - 2_500_000_000
		}
		pos, found := slice.binary_search(ref[:], v)
		if u_below(3) == 0 {
			ok: bool
			is, ok = st.intset_remove(is, v)
			check(ok == found, "intset remove agrees with the reference")
			if found {
				ordered_remove(&ref, pos)
			}
		} else {
			ok: bool
			is, ok = st.intset_add(is, v)
			check(ok == !found, "intset add agrees with the reference")
			if !found {
				inject_at(&ref, pos, v)
			}
		}
	}
	check(st.intset_len(is) == len(ref), "intset length")
	same := true
	for v, i in ref {
		if st.intset_get(is, i) != v {
			same = false
		}
	}
	check(same, "intset contents sorted like the reference")
	lp.lp_mem_free(is)
}

unit_table :: proc() {
	t := st.table_make(0)
	ref := make(map[string]bool, 16, context.temp_allocator)
	for i in 0 ..< 30000 {
		k := fmt.tprintf("k%d", u_below(3000))
		if i % 7 == 0 {
			k = ""
		}
		if u_below(3) == 0 {
			ok := st.table_delete(t, transmute([]u8)k)
			check(ok == (k in ref), "table delete agrees")
			delete_key(&ref, k)
		} else {
			ok := st.table_add(t, transmute([]u8)k)
			check(ok == (k not_in ref), "table add agrees")
			ref[strings.clone(k, context.temp_allocator)] = true
		}
	}
	check(t.count == len(ref), "table count")
	for k in ref {
		check(st.table_contains(t, transmute([]u8)k), "table contains every member")
	}
	st.table_free(t)
}

unit_scan_guarantee :: proc() {
	for round in 0 ..< 40 {
		s := st.create_table(0)
		for i in 0 ..< 100 + round * 37 {
			st.add(s, transmute([]u8)fmt.tprintf("%d", i))
		}
		seen := make(map[string]bool, 16, context.temp_allocator)
		out := make([dynamic]st.Value, context.temp_allocator)
		cursor: u64 = 0
		iter := 0
		for {
			clear(&out)
			cursor = st.scan(s, cursor, 1 + u_below(12), &out)
			for v in out {
				seen[strings.clone(string(v.str), context.temp_allocator)] = true
			}
			iter += 1
			if iter == 3 {
				for i in 100 ..< 100 + round * 37 {
					st.remove(s, transmute([]u8)fmt.tprintf("%d", i))
				}
			}
			if iter == 6 {
				for i in 5000 ..< 5000 + round * 50 {
					st.add(s, transmute([]u8)fmt.tprintf("%d", i))
				}
			}
			if cursor == 0 {
				break
			}
		}
		missing := 0
		for i in 0 ..< 100 {
			if fmt.tprintf("%d", i) not_in seen {
				missing += 1
			}
		}
		check(missing == 0, "scan reports every member present for the whole scan")
		st.destroy(s)
	}
}

members_sorted :: proc(s: st.Set) -> []string {
	out := set_members(s)
	slice.sort(out[:])
	return out[:]
}

unit_encodings :: proc() {
	st.set_max_intset_entries = 4
	st.set_max_listpack_entries = 3
	st.set_max_listpack_value = 5
	defer {
		st.set_max_intset_entries = st.SET_MAX_INTSET_ENTRIES_DEFAULT
		st.set_max_listpack_entries = st.SET_MAX_LISTPACK_ENTRIES_DEFAULT
		st.set_max_listpack_value = st.SET_MAX_LISTPACK_VALUE_DEFAULT
	}
	s := st.create(transmute([]u8)string("1"), 1)
	check(s.encoding == .Intset, "integer first member creates an intset")
	for v in ([?]string{"1", "2", "3", "4"}) {
		st.add(s, transmute([]u8)v)
	}
	check(s.encoding == .Intset && st.size(s) == 4, "intset holds the configured entries")
	st.add(s, transmute([]u8)string("5"))
	check(s.encoding == .Hashtable, "intset beyond its limit becomes a hashtable")
	st.destroy(s)
	s = st.create(transmute([]u8)string("1"), 1)
	st.add(s, transmute([]u8)string("1"))
	st.add(s, transmute([]u8)string("abc"))
	check(s.encoding == .Listpack && st.size(s) == 2, "string added to a small intset converts to listpack")
	st.add(s, transmute([]u8)string("abcdef"))
	check(s.encoding == .Hashtable, "long string converts the listpack")
	st.destroy(s)
	s = st.create(transmute([]u8)string("x"), 5)
	check(s.encoding == .Hashtable, "size hint above the listpack limit creates a hashtable")
	st.destroy(s)
	s = st.create(transmute([]u8)string("1"), 1)
	st.add(s, transmute([]u8)string("123456"))
	st.add(s, transmute([]u8)string("a"))
	check(s.encoding == .Hashtable, "wide integers in the intset rule out the listpack")
	st.destroy(s)
	s = st.create_listpack()
	st.add_aux(s, st.Value{ival = 7, is_int = true})
	st.add_aux(s, st.Value{str = transmute([]u8)string("8")})
	st.maybe_convert_to_intset(s)
	check(s.encoding == .Intset && st.size(s) == 2, "integer only listpack converts to intset")
	d := st.dup(s)
	check(d.encoding == .Intset && string(st.raw_bytes(d)) == string(st.raw_bytes(s)), "dup keeps the intset bytes")
	st.destroy(d)
	st.destroy(s)
}

random_set :: proc(kind: int) -> st.Set {
	n := u_below(60)
	s: st.Set
	switch kind {
	case 0:
		s = st.create_intset()
	case 1:
		s = st.create_listpack()
	case:
		s = st.create_table(0)
	}
	for _ in 0 ..< n {
		v := fmt.tprintf("%d", u_below(80)) if kind != 1 || u_below(2) == 0 else fmt.tprintf("s%d", u_below(80))
		st.add(s, transmute([]u8)v)
	}
	return s
}

unit_algebra :: proc() {
	saved := st.set_max_listpack_entries
	st.set_max_listpack_entries = 1000
	defer st.set_max_listpack_entries = saved
	for _ in 0 ..< 400 {
		n := 1 + u_below(4)
		sets := make([]st.Set, n, context.temp_allocator)
		refs := make([]map[string]bool, n, context.temp_allocator)
		for i in 0 ..< n {
			if u_below(6) == 0 {
				continue
			}
			sets[i] = random_set(u_below(3))
			refs[i] = make(map[string]bool, 16, context.temp_allocator)
			for m in set_members(sets[i]) {
				refs[i][m] = true
			}
		}
		uref := make(map[string]bool, 16, context.temp_allocator)
		for r in refs {
			for m in r {
				uref[m] = true
			}
		}
		dref := make(map[string]bool, 16, context.temp_allocator)
		if sets[0] != nil {
			outer: for m in refs[0] {
				for j in 1 ..< n {
					if sets[j] != nil && m in refs[j] {
						continue outer
					}
				}
				dref[m] = true
			}
		}
		copy_sets := make([]st.Set, n, context.temp_allocator)
		copy(copy_sets, sets)
		u := st.union_diff(copy_sets, .Union)
		check(st.size(u) == len(uref), "union cardinality")
		for m in set_members(u) {
			check(m in uref, "union member")
		}
		st.destroy(u)
		copy(copy_sets, sets)
		d := st.union_diff(copy_sets, .Diff)
		check(st.size(d) == len(dref), "diff cardinality")
		for m in set_members(d) {
			check(m in dref, "diff member")
		}
		st.destroy(d)
		has_nil := false
		for s in sets {
			has_nil ||= s == nil
		}
		if !has_nil {
			iref := 0
			for m in refs[0] {
				inall := true
				for j in 1 ..< n {
					inall &&= m in refs[j]
				}
				if inall {
					iref += 1
				}
			}
			copy(copy_sets, sets)
			check(st.inter_card(copy_sets, 0) == iref, "intersection cardinality")
			copy(copy_sets, sets)
			x := st.inter_store(copy_sets)
			check(st.size(x) == iref, "intersection store cardinality")
			st.destroy(x)
		}
		for s in sets {
			if s != nil {
				st.destroy(s)
			}
		}
	}
}

unit_random :: proc() {
	for kind in 0 ..< 3 {
		for _ in 0 ..< 200 {
			s := random_set(kind)
			n := st.size(s)
			if n < 2 {
				st.destroy(s)
				continue
			}
			before := members_sorted(s)
			count := 1 + u_below(n - 1)
			out := make([dynamic]st.Value, context.temp_allocator)
			st.random_unique(s, count, &out)
			seen := make(map[string]bool, 16, context.temp_allocator)
			buf: [lp.LP_INTBUF_SIZE]u8
			for v in out {
				seen[strings.clone(string(st.value_bytes(v, &buf)), context.temp_allocator)] = true
			}
			check(len(out) == count && len(seen) == count, "random unique count")
			popped: st.Popped
			newset := st.spop_count(s, count, &popped)
			if newset != nil {
				st.destroy(s)
				s = newset
			}
			check(st.popped_len(&popped) == count && st.size(s) == n - count, "spop count sizes")
			all := make([dynamic]string, context.temp_allocator)
			for i in 0 ..< st.popped_len(&popped) {
				append(&all, strings.clone(string(st.value_bytes(st.popped_get(&popped, i), &buf)), context.temp_allocator))
			}
			for m in set_members(s) {
				append(&all, m)
			}
			slice.sort(all[:])
			check(slice.equal(all[:], before), "spop partitions the set")
			st.popped_destroy(&popped)
			st.destroy(s)
		}
	}
}

run_unit :: proc() -> bool {
	unit_resize()
	unit_intset_layout()
	unit_intset_fuzz()
	unit_table()
	unit_scan_guarantee()
	unit_encodings()
	unit_algebra()
	unit_random()
	free_all(context.temp_allocator)
	fmt.printfln("settype unit: %d checks, %d failures", checks, failures)
	return failures == 0
}

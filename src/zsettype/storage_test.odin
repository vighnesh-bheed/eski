package zsettype

import "core:testing"
import lp "../listpack"

Member_Model :: struct {
	live:  bool,
	score: f64,
	key:   [9]u8,
	len:   int,
}

validate_against_model :: proc(t: ^testing.T, z: Zset, model: []Member_Model) {
	order: [dynamic]int
	defer delete(order)
	for &m, i in model {
		value, found := score(z, m.key[:m.len])
		testing.expect(t, found == m.live)
		if m.live {
			testing.expect(t, value == m.score)
			append(&order, i)
		}
	}
	for i in 1 ..< len(order) {
		j := i
		for j > 0 {
			a, b := model[order[j - 1]], model[order[j]]
			if a.score < b.score || a.score == b.score && member_cmp(a.key[:a.len], b.key[:b.len]) < 0 {
				break
			}
			order[j - 1], order[j] = order[j], order[j - 1]
			j -= 1
		}
	}
	testing.expect(t, length(z) == len(order))
	for reverse in ([2]bool{false, true}) {
		it := iter_make(z, reverse)
		item: Item
		for index in 0 ..< len(order) {
			i := index
			if reverse {
				i = len(order) - index - 1
			}
			m := model[order[i]]
			testing.expect(t, iter_next(&it, &item))
			buf: [lp.LP_INTBUF_SIZE]u8
			testing.expect(t, member_eq(item_bytes(&item, &buf), m.key[:m.len]))
			testing.expect(t, item.score == m.score)
			r, v, found := rank(z, m.key[:m.len], reverse)
			testing.expect(t, found && r == index && v == m.score)
		}
		testing.expect(t, !iter_next(&it, &item))
		testing.expect(t, !iter_next(&it, &item))
	}
	if z.encoding == .Listpack {
		testing.expect(t, lp.lp_validate_integrity(z.lp, u64(lp.lp_bytes(z.lp)), true, nil, nil))
		testing.expect(t, memory_usage(z) == mem_usable_size(z) + lp.lp_malloc_size(z.lp))
		return
	}
	sl := z.sl
	testing.expect(t, dict_count(sl) == len(order))
	testing.expect(t, sl.length == len(order))
	node_bytes := 0
	previous: ^Node
	for id, i in order {
		m := model[id]
		n := sl_get_by_rank(sl, u64(i + 1))
		testing.expect(t, n != nil)
		if n == nil {
			return
		}
		testing.expect(t, member_eq(node_member(n), m.key[:m.len]))
		testing.expect(t, n.backward == previous)
		testing.expect(t, n.score == m.score)
		testing.expect(t, dict_find(sl, m.key[:m.len], n.hash) == n)
		testing.expect(t, sl_get_rank(sl, m.score, m.key[:m.len]) == u64(i + 1))
		testing.expect(t, n.nlevel >= 1 && n.nlevel <= MAX_LEVEL)
		node_bytes += mem_usable_size(n)
		previous = n
	}
	testing.expect(t, sl.tail == previous)
	testing.expect(t, sl_get_by_rank(sl, 0) == sl.header)
	testing.expect(t, sl_get_by_rank(sl, u64(len(order) + 1)) == nil)
	for level in 0 ..< sl.level {
		n := sl.header
		position: u64
		for n != nil {
			next := fwd(n, level)
			if next == nil {
				testing.expect(t, position + node_levels(n)[level].span == u64(len(order)))
				break
			}
			position += node_levels(n)[level].span
			testing.expect(t, position == sl_get_rank(sl, next.score, node_member(next)))
			n = next
		}
	}
	count := 0
	for bank in 0 ..< 2 {
		slots, cap := dict_bank(sl, bank)
		bank_count := 0
		for i in 0 ..< cap {
			if node_live(slots[i]) {
				bank_count += 1
				n := slots[i]
				testing.expect(t, hash_member(node_member(n)) == n.hash)
				testing.expect(t, dict_find(sl, node_member(n), n.hash) == n)
			}
		}
		count += bank_count
		if bank == 0 {
			testing.expect(t, bank_count == sl.count - (sl.resize != nil ? sl.resize.old_count : 0))
		} else if sl.resize != nil {
			testing.expect(t, bank_count == sl.resize.old_count)
		}
	}
	testing.expect(t, count == len(order))
	testing.expect(t, node_bytes == sl.bytes)
	exact := mem_usable_size(z) + mem_usable_size(sl) + mem_usable_size(sl.header) + node_bytes + slots_memory(sl.slots, sl.cap)
	if sl.resize != nil {
		exact += mem_usable_size(sl.resize) + slots_memory(sl.resize.old_slots, sl.resize.old_cap)
	}
	testing.expect(t, memory_usage(z) == exact)
}

member_model_init :: proc(model: []Member_Model) {
	for &m, i in model {
		m.len = 9
		m.key = {u8(i), 0, 255, u8(i >> 8), 128, 1, 13, 10, 0}
	}
	if len(model) > 0 {
		model[0].len = 0
	}
}

lcg_next :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return state^
}

@(test)
ordered_mutations :: proc(t: ^testing.T) {
	set_seed(4907)
	for use_sl in ([2]bool{false, true}) {
		z := create_listpack()
		if use_sl {
			destroy(z)
			z = create_skiplist(0)
		}
		model: [257]Member_Model
		member_model_init(model[:])
		state: u64 = 4813
		for step in 0 ..< 2200 {
			i := int(lcg_next(&state) >> 32) % len(model)
			m := &model[i]
			if step % 5 == 0 {
				testing.expect(t, del(z, m.key[:m.len]) == m.live)
				m.live = false
			} else {
				v := f64(int(lcg_next(&state) >> 32) % 31 - 15)
				if step % 83 == 0 {
					v = F64_INF
				} else if step % 89 == 0 {
					v = F64_NEG_INF
				}
				o, s, ok := add(z, v, m.key[:m.len], {})
				testing.expect(t, ok && s == v)
				if !m.live {
					testing.expect(t, o == {.Added})
				} else if m.score != v {
					testing.expect(t, o == {.Updated})
				} else {
					testing.expect(t, o == {})
				}
				m.live = true
				m.score = v
			}
			if step % 17 == 0 || step >= 2180 {
				validate_against_model(t, z, model[:])
			}
		}
		copy_z := dup(z)
		validate_against_model(t, copy_z, model[:])
		for &m in model {
			if m.live {
				testing.expect(t, del(z, m.key[:m.len]))
			}
		}
		testing.expect(t, length(z) == 0)
		destroy(z)
		validate_against_model(t, copy_z, model[:])
		destroy(copy_z)
	}
	for i := 0; i < 4096 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

@(test)
flags_and_aliases :: proc(t: ^testing.T) {
	for use_sl in ([2]bool{false, true}) {
		for bits in 0 ..< 32 {
			flags := transmute(Zadd_Flags)u8(bits)
			for present in ([2]bool{false, true}) {
				for incoming in ([5]f64{-4, 0, 4, F64_INF, F64_NEG_INF}) {
					z := create_listpack()
					if use_sl {
						convert_to_skiplist(z, 1)
					}
					key := []u8{'k', 0, 255}
					if present {
						_, _, _ = add(z, 4, key, {})
					}
					expected := incoming
					nop := present && .Nx in flags || !present && .Xx in flags
					if present && .Incr in flags {
						expected += 4
					}
					if present && (.Gt in flags && expected <= 4 || .Lt in flags && expected >= 4) {
						nop = true
					}
					o, _, ok := add(z, incoming, key, flags)
					testing.expect(t, ok)
					v, found := score(z, key)
					if nop {
						testing.expect(t, o == {.Nop})
						testing.expect(t, found == present)
						if present {
							testing.expect(t, v == 4)
						}
					} else {
						testing.expect(t, found && v == expected)
					}
					destroy(z)
				}
			}
		}
		z := create_listpack()
		if use_sl {
			convert_to_skiplist(z, 1)
		}
		_, _, _ = add(z, F64_INF, []u8{'a'}, {})
		o, _, ok := add(z, F64_NEG_INF, []u8{'a'}, {.Incr})
		testing.expect(t, !ok && o == {.Nan})
		v, _ := score(z, []u8{'a'})
		testing.expect(t, v == F64_INF)
		o, _, ok = add(z, F64_NAN, []u8{'b'}, {})
		testing.expect(t, !ok && o == {.Nan} && length(z) == 1)
		item := peek(z, false)
		buf: [lp.LP_INTBUF_SIZE]u8
		alias := item_bytes(&item, &buf)
		o, _, ok = add(z, 17, alias, {})
		testing.expect(t, ok && o == {.Updated})
		v, _ = score(z, []u8{'a'})
		testing.expect(t, v == 17)
		copy_z := dup(z)
		destroy(z)
		copy_value, found := score(copy_z, []u8{'a'})
		testing.expect(t, found && copy_value == 17)
		destroy(copy_z)
	}
	for i := 0; i < 4096 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

@(test)
encoding_boundaries :: proc(t: ^testing.T) {
	saved_entries, saved_value := zset_max_listpack_entries, zset_max_listpack_value
	defer {
		zset_max_listpack_entries = saved_entries
		zset_max_listpack_value = saved_value
	}
	for entries in ([3]int{0, 1, 128}) {
		zset_max_listpack_entries = entries
		for mlen in ([3]int{0, 64, 65}) {
			z := type_create(entries, mlen)
			expected_lp := mlen <= 64
			testing.expect(t, (z.encoding == .Listpack) == expected_lp)
			destroy(z)
		}
		z := create_listpack()
		key: [65]u8
		for i in 0 ..< entries + 1 {
			key[0] = u8(i)
			_, _, _ = add(z, f64(i), key[:64], {})
			testing.expect(t, (z.encoding == .Listpack) == (i < entries))
		}
		testing.expect(t, z.encoding == .Skiplist)
		destroy(z)
	}
	zset_max_listpack_entries = 128
	z := create_listpack()
	key: [65]u8
	_, _, _ = add(z, 1, key[:64], {})
	testing.expect(t, z.encoding == .Listpack)
	_, _, _ = add(z, 2, key[:], {})
	testing.expect(t, z.encoding == .Skiplist)
	testing.expect(t, del(z, key[:]))
	testing.expect(t, z.encoding == .Skiplist)
	convert_to_listpack(z)
	testing.expect(t, z.encoding == .Listpack && length(z) == 1)
	convert_to_skiplist(z, 1)
	testing.expect(t, z.encoding == .Skiplist && length(z) == 1)
	destroy(z)
	for i := 0; i < 4096 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

@(test)
ranges_and_cursor_pairs :: proc(t: ^testing.T) {
	for use_sl in ([2]bool{false, true}) {
		z := create_listpack()
		if use_sl {
			convert_to_skiplist(z, 16)
		}
		for i in 0 ..< 16 {
			key := [1]u8{u8('a' + i)}
			_, _, _ = add(z, f64(i), key[:], {})
		}
		items: [dynamic]Item
		rank_range(z, -4, -1, false, &items)
		testing.expect(t, len(items) == 4 && items[0].score == 12 && items[3].score == 15)
		clear(&items)
		r := Range_Spec{min = 3, max = 8, minex = true}
		score_range(z, &r, 1, 2, true, &items)
		testing.expect(t, len(items) == 2 && items[0].score == 7 && items[1].score == 6)
		testing.expect(t, count_in_range(z, &r) == 5)
		delete(items)
		testing.expect(t, remrange_by_score(z, &r) == 5)
		testing.expect(t, remrange_by_rank(z, -2, -1) == 2)
		testing.expect(t, length(z) == 9)
		for length(z) > 0 {
			pop(z, length(z) % 2 == 0)
		}
		destroy(z)
		z = create_listpack()
		if use_sl {
			convert_to_skiplist(z, 16)
		}
		for i in 0 ..< 16 {
			key := [1]u8{u8('a' + i)}
			_, _, _ = add(z, 0, key[:], {})
		}
		lr := Lex_Spec{min = []u8{'d'}, max = []u8{'h'}, minex = true}
		testing.expect(t, lex_count(z, &lr) == 4)
		testing.expect(t, remrange_by_lex(z, &lr) == 4)
		testing.expect(t, length(z) == 12)
		if !use_sl {
			p := lp.lp_first(z.lp)
			s := lp.lp_next(z.lp, p)
			for p != nil {
				zzl_next(z.lp, &p, &s)
			}
			testing.expect(t, p == nil && s == nil)
			s = lp.lp_last(z.lp)
			p = lp.lp_prev(z.lp, s)
			for p != nil {
				zzl_prev(z.lp, &p, &s)
			}
			testing.expect(t, p == nil && s == nil)
		}
		destroy(z)
	}
	for i := 0; i < 4096 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

Scan_Counts :: struct {
	seen: [257]int,
}

count_scanned_member :: proc(user: rawptr, n: ^Node) {
	state := cast(^Scan_Counts)user
	key := node_member(n)
	index := 0
	if len(key) > 0 {
		index = int(key[0]) + int(key[3]) * 256
	}
	state.seen[index] += 1
}

@(test)
active_migration :: proc(t: ^testing.T) {
	set_seed(3117)
	z := create_skiplist(256)
	model: [257]Member_Model
	member_model_init(model[:])
	for &m, i in model[:192] {
		_, _, _ = add(z, f64(i % 11), m.key[:m.len], {})
		m.live = true
		m.score = f64(i % 11)
	}
	validate_against_model(t, z, model[:])
	base_cap := z.sl.cap
	dict_resize(z.sl, base_cap * 2)
	testing.expect(t, z.sl.resize != nil)
	testing.expect(t, z.sl.resize.old_count == 192 && z.sl.count == 192)
	testing.expect(t, z.sl.resize.owner == nil && z.sl.resize.reg == nil && z.sl.resize.epoch == 0)
	reg: Context
	reg.owner = rawptr(&model)
	maintenance_bind(z, &reg)
	testing.expect(t, reg.resize_count == 1 && z.sl.resize.owner == z && z.sl.resize.reg == &reg)
	validate_against_model(t, z, model[:])
	for i in 0 ..< 25 {
		r := z.sl.resize
		old_count, cursor := r.old_count, r.cursor
		m := &model[i]
		_, _, _ = add(z, f64(100 + i), m.key[:m.len], {})
		m.score = f64(100 + i)
		if z.sl.resize == r {
			testing.expect(t, old_count - r.old_count <= RESIZE_WRITE_MOVES)
			testing.expect(t, r.cursor - cursor <= RESIZE_WRITE_SCANS)
		}
		validate_against_model(t, z, model[:])
	}
	seen: Scan_Counts
	cursor: u64
	steps := 0
	for {
		cursor = dict_scan_bucket(z.sl, cursor, count_scanned_member, &seen)
		steps += 1
		if cursor == 0 || steps > 2048 {
			break
		}
	}
	testing.expect(t, cursor == 0)
	for m, i in model {
		testing.expect(t, seen.seen[i] == (m.live ? 1 : 0))
	}
	for i := 0; i < 2048 && z.sl.resize != nil; i += 1 {
		_, work := maintenance_step(&reg, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
		testing.expect(t, work.scanned <= RESIZE_WRITE_SCANS && work.moved <= RESIZE_WRITE_MOVES)
	}
	testing.expect(t, z.sl.resize == nil && reg.resize_count == 0)
	validate_against_model(t, z, model[:])
	dict_resize(z.sl, base_cap)
	maintenance_bind(z, &reg)
	testing.expect(t, reg.resize_count == 1)
	maintenance_cancel(z)
	testing.expect(t, reg.resize_count == 0 && z.sl.resize != nil)
	validate_against_model(t, z, model[:])
	destroy(z)
	for i := 0; i < 4096 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

@(test)
numeric_storage_and_hints :: proc(t: ^testing.T) {
	saved_entries, saved_value := zset_max_listpack_entries, zset_max_listpack_value
	defer {
		zset_max_listpack_entries = saved_entries
		zset_max_listpack_value = saved_value
	}
	for use_sl in ([2]bool{false, true}) {
		z := create_listpack()
		if use_sl {
			convert_to_skiplist(z, 0)
		}
		negative_zero := f64(0h8000_0000_0000_0000)
		o, result, ok := add(z, negative_zero, []u8{'0'}, {})
		testing.expect(t, ok && o == {.Added} && transmute(u64)result == 0x8000_0000_0000_0000)
		v, _ := score(z, []u8{'0'})
		expected_bits := use_sl ? u64(0x8000_0000_0000_0000) : 0
		testing.expect(t, transmute(u64)v == expected_bits)
		o, result, ok = add(z, 0, []u8{'0'}, {})
		testing.expect(t, ok && o == {} && transmute(u64)result == 0)
		v, _ = score(z, []u8{'0'})
		testing.expect(t, transmute(u64)v == expected_bits)
		for number, i in ([7]f64{1e-10, 0.1, 1e20, 9007199254740992, F64_INF, F64_NEG_INF, 5e-324}) {
			key := [2]u8{'n', u8(i)}
			_, _, _ = add(z, number, key[:], {})
			stored, found := score(z, key[:])
			testing.expect(t, found && stored == number)
		}
		if use_sl {
			x := sl_first(z.sl)
			for x != nil {
				for offset in 0 ..< z.sl.length {
					a := sl_get_by_rank_from(x, 0, u64(offset))
					b := x
					for _ in 0 ..< offset {
						if b == nil {
							break
						}
						b = sl_next(b)
					}
					testing.expect(t, a == b)
				}
				x = sl_next(x)
			}
		}
		destroy(z)
	}
	zset_max_listpack_entries = 2
	zset_max_listpack_value = 3
	z := create_listpack()
	_, _, _ = add(z, 1, []u8{'a', 'b', 'c'}, {})
	maybe_convert(z, 2)
	testing.expect(t, z.encoding == .Listpack)
	maybe_convert(z, 3)
	testing.expect(t, z.encoding == .Skiplist)
	convert_to_listpack_if_needed(z, 4, 3)
	testing.expect(t, z.encoding == .Skiplist)
	convert_to_listpack_if_needed(z, 3, 3)
	testing.expect(t, z.encoding == .Listpack)
	destroy(z)
	for i := 0; i < 4096 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

@(test)
direct_storage_membership :: proc(t: ^testing.T) {
	set_seed(7719)
	sl := sl_create(0)
	keys := [4][3]u8{{'a', 0, 255}, {'b', 0, 255}, {'c', 0, 255}, {'d', 0, 255}}
	nodes: [4]^Node
	for &key, i in keys {
		nodes[i] = sl_insert(sl, f64(i), key[:], hash_member(key[:]))
		testing.expect(t, sl.length == i + 1 && dict_count(sl) == i + 1)
		testing.expect(t, dict_find(sl, key[:], hash_member(key[:])) == nodes[i])
	}
	for &key, i in keys {
		sl_remove(sl, nodes[i])
		testing.expect(t, sl.length == 3 - i && dict_count(sl) == 3 - i)
		testing.expect(t, dict_find(sl, key[:], hash_member(key[:])) == nil)
	}
	sl_free(sl)
	z := create_listpack()
	r, value, found := rank(z, []u8{'x'}, false)
	testing.expect(t, !found && r == -1 && value == 0)
	convert_to_skiplist(z, 0)
	r, value, found = rank(z, []u8{'x'}, true)
	testing.expect(t, !found && r == -1 && value == 0)
	destroy(z)
	for i := 0; i < 4096 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

@(test)
empty_reuse_and_member_selector :: proc(t: ^testing.T) {
	set_seed(6131)
	z := create_skiplist(0)
	seen: Scan_Counts
	testing.expect(t, dict_scan_bucket(z.sl, 123, count_scanned_member, &seen) == 0)
	for i in 0 ..< 8 {
		_, _, ok := add(z, f64(i), []u8{'a'}, {})
		testing.expect(t, ok && length(z) == 1)
		testing.expect(t, del(z, []u8{'a'}))
		testing.expect(t, length(z) == 0 && z.sl.count == 0)
		testing.expect(t, dict_scan_bucket(z.sl, 123, count_scanned_member, &seen) == 0)
		it := iter_make(z, false)
		item: Item
		testing.expect(t, !iter_next(&it, &item))
		testing.expect(t, !iter_next(&it, &item))
	}
	destroy(z)
	z = create_listpack()
	_, _, _ = add(z, 11, []u8{'1'}, {})
	item := item_from_lp(lp.lp_first(z.lp))
	testing.expect(t, item.is_int && item.ival == 1 && item.score == 0 && !item.g17)
	item = peek(z, false)
	testing.expect(t, item.is_int && item.ival == 1 && item.score == 11)
	it := iter_make(z, false)
	testing.expect(t, iter_next(&it, &item) && item.score == 11)
	testing.expect(t, !iter_next(&it, &item))
	testing.expect(t, !iter_next(&it, &item))
	destroy(z)
	for i := 0; i < 4096 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

@(test)
nil_member_storage :: proc(t: ^testing.T) {
	set_seed(4001)
	empty: []u8
	testing.expect(t, hash_member(empty) == hash_member(EMPTY_MEMBER[:0]))
	for use_sl in ([2]bool{false, true}) {
		z := create_listpack()
		if use_sl {
			convert_to_skiplist(z, 0)
		}
		o, result, ok := add(z, 12.5, empty, {})
		testing.expect(t, ok && o == {.Added} && result == 12.5)
		value, found := score(z, empty)
		testing.expect(t, found && value == 12.5 && length(z) == 1)
		value, found = score(z, EMPTY_MEMBER[:0])
		testing.expect(t, found && value == 12.5)
		r, rank_score, ranked := rank(z, empty, false)
		testing.expect(t, ranked && r == 0 && rank_score == 12.5)
		copy_z := dup(z)
		destroy(z)
		value, found = score(copy_z, empty)
		testing.expect(t, found && value == 12.5 && length(copy_z) == 1)
		item := peek(copy_z, false)
		buf: [lp.LP_INTBUF_SIZE]u8
		testing.expect(t, len(item_bytes(&item, &buf)) == 0 && item.score == 12.5)
		testing.expect(t, del(copy_z, empty) && length(copy_z) == 0)
		testing.expect(t, !del(copy_z, empty))
		_, _, ok = add(copy_z, -2, empty, {})
		testing.expect(t, ok && length(copy_z) == 1)
		destroy(copy_z)
	}
	sl := sl_create(0)
	n := sl_insert(sl, 4, empty, hash_member(empty))
	testing.expect(t, sl.length == 1 && sl.count == 1)
	testing.expect(t, dict_find(sl, empty, hash_member(empty)) == n)
	sl_remove(sl, n)
	testing.expect(t, sl.length == 0 && sl.count == 0)
	sl_free(sl)
	for i := 0; i < 4096 && maintenance_pending(); i += 1 {
		maintenance_release()
	}
	testing.expect(t, !maintenance_pending())
}

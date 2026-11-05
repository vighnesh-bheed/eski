package zsettype

import lp "../listpack"

ZSET_MAX_LISTPACK_ENTRIES_DEFAULT :: 128

ZSET_MAX_LISTPACK_VALUE_DEFAULT :: 64

zset_max_listpack_entries: int = ZSET_MAX_LISTPACK_ENTRIES_DEFAULT

zset_max_listpack_value: int = ZSET_MAX_LISTPACK_VALUE_DEFAULT

Encoding :: enum u8 {
	Listpack,
	Skiplist,
}

Zset_Object :: struct {
	lp:       [^]u8,
	sl:       ^Skiplist,
	acct:     int,
	encoding: Encoding,
}

Zset :: ^Zset_Object

Zadd_Flag :: enum u8 {
	Incr,
	Nx,
	Xx,
	Gt,
	Lt,
}

Zadd_Flags :: bit_set[Zadd_Flag;u8]

Zadd_Out :: enum u8 {
	Nop,
	Nan,
	Added,
	Updated,
}

Zadd_Outs :: bit_set[Zadd_Out;u8]

Iter :: struct {
	z:       Zset,
	eptr:    [^]u8,
	sptr:    [^]u8,
	node:    ^Node,
	reverse: bool,
	started: bool,
}

create_listpack :: proc "contextless" () -> Zset {
	z := cast(Zset)mem_alloc_zero(size_of(Zset_Object))
	z.encoding = .Listpack
	z.lp = lp.lp_new(0)
	return z
}

create_skiplist :: proc "contextless" (expected: int) -> Zset {
	z := cast(Zset)mem_alloc_zero(size_of(Zset_Object))
	z.encoding = .Skiplist
	z.sl = sl_create(expected)
	return z
}

type_create :: proc "contextless" (size_hint: int, val_len_hint: int) -> Zset {
	if size_hint <= zset_max_listpack_entries && val_len_hint <= zset_max_listpack_value {
		return create_listpack()
	}
	return create_skiplist(size_hint)
}

destroy :: proc "contextless" (z: Zset) {
	if z == nil {
		return
	}
	maintenance_cancel(z)
	if z.encoding == .Listpack {
		lp.lp_free(z.lp)
	} else {
		sl_free(z.sl)
	}
	mem_free(z)
}

length :: proc(z: Zset) -> int {
	if z.encoding == .Listpack {
		return zzl_length(z.lp)
	}
	return z.sl.length
}

memory_usage :: proc "contextless" (z: Zset) -> int {
	if z == nil {
		return 0
	}
	n := mem_usable_size(z)
	if z.encoding == .Listpack {
		return n + lp.lp_malloc_size(z.lp)
	}
	return n + sl_memory(z.sl)
}

encoding_name :: proc "contextless" (z: Zset) -> string {
	if z.encoding == .Listpack {
		return "listpack"
	}
	return "skiplist"
}

listpack_bytes :: proc "contextless" (z: Zset) -> []u8 {
	if z.encoding == .Listpack {
		return lp.lp_view(z.lp)
	}
	return nil
}

convert_to_skiplist :: proc(z: Zset, expected: int) {
	if z.encoding == .Skiplist {
		return
	}
	sl := sl_create(max(expected, zzl_length(z.lp)))
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	for p := lp.lp_first(z.lp); p != nil; {
		s := lp.lp_next(z.lp, p)
		member := zzl_member(p, &buf)
		_ = sl_insert(sl, zzl_score(s), member, hash_member(member))
		p = lp.lp_next(z.lp, s)
	}
	lp.lp_free(z.lp)
	z.lp = nil
	z.sl = sl
	z.encoding = .Skiplist
}

convert_to_listpack :: proc(z: Zset) {
	if z.encoding == .Listpack {
		return
	}
	pack := lp.lp_new(0)
	for n := sl_first(z.sl); n != nil; n = sl_next(n) {
		pack = zzl_insert_at(pack, nil, node_member(n), n.score)
	}
	maintenance_cancel(z)
	sl_free(z.sl)
	z.sl = nil
	z.lp = pack
	z.encoding = .Listpack
}

score :: proc(z: Zset, member: []u8) -> (f64, bool) {
	if z.encoding == .Listpack {
		_, value, found := zzl_find(z.lp, member)
		return value, found
	}
	n := dict_find(z.sl, member, hash_member(member))
	if n == nil {
		return 0, false
	}
	return n.score, true
}

add :: proc(z: Zset, score_in: f64, member: []u8, flags: Zadd_Flags) -> (out: Zadd_Outs, newscore: f64, ok: bool) {
	if is_nan(score_in) {
		return {.Nan}, 0, false
	}
	oldscore, found := score(z, member)
	if found && .Nx in flags || !found && .Xx in flags {
		return {.Nop}, 0, true
	}
	value := score_in
	if found && .Incr in flags {
		value += oldscore
		if is_nan(value) {
			return {.Nan}, 0, false
		}
	}
	if found && (.Gt in flags && value <= oldscore || .Lt in flags && value >= oldscore) {
		return {.Nop}, 0, true
	}
	if found && oldscore == value {
		return {}, value, true
	}
	if z.encoding == .Listpack {
		if found {
			stable := mem_alloc(len(member))
			copy(stable[:len(member)], member)
			p, _, _ := zzl_find(z.lp, member)
			z.lp = zzl_delete(z.lp, p)
			z.lp = zzl_insert(z.lp, stable[:len(member)], value)
			mem_free(stable)
		} else if zzl_length(z.lp) + 1 > zset_max_listpack_entries || len(member) > zset_max_listpack_value || !lp.lp_safe_to_add(z.lp, len(member) + 32) {
			stable := mem_alloc(len(member))
			copy(stable[:len(member)], member)
			convert_to_skiplist(z, zzl_length(z.lp) + 1)
			_ = sl_insert(z.sl, value, stable[:len(member)], hash_member(stable[:len(member)]))
			mem_free(stable)
		} else {
			z.lp = zzl_insert(z.lp, member, value)
		}
	} else {
		if found {
			n := dict_find(z.sl, member, hash_member(member))
			sl_update_score(z.sl, n, value)
		} else {
			_ = sl_insert(z.sl, value, member, hash_member(member))
		}
	}
	if found {
		return {.Updated}, value, true
	}
	return {.Added}, value, true
}

del :: proc(z: Zset, member: []u8) -> bool {
	if z.encoding == .Listpack {
		p, _, found := zzl_find(z.lp, member)
		if !found {
			return false
		}
		z.lp = zzl_delete(z.lp, p)
		return true
	}
	n := dict_find(z.sl, member, hash_member(member))
	if n == nil {
		return false
	}
	sl_remove(z.sl, n)
	return true
}

rank :: proc(z: Zset, member: []u8, reverse: bool) -> (r: int, s: f64, found: bool) {
	if z.encoding == .Listpack {
		i := 0
		for p := lp.lp_first(z.lp); p != nil; {
			sp := lp.lp_next(z.lp, p)
			if zzl_compare(p, member) == 0 {
				if reverse {
					i = zzl_length(z.lp) - i - 1
				}
				return i, zzl_score(sp), true
			}
			i += 1
			p = lp.lp_next(z.lp, sp)
		}
		return -1, 0, false
	}
	n := dict_find(z.sl, member, hash_member(member))
	if n == nil {
		return -1, 0, false
	}
	i := int(sl_get_rank(z.sl, n.score, node_member(n))) - 1
	if reverse {
		i = z.sl.length - i - 1
	}
	return i, n.score, true
}

dup :: proc(z: Zset) -> Zset {
	if z.encoding == .Listpack {
		d := cast(Zset)mem_alloc_zero(size_of(Zset_Object))
		d.encoding = .Listpack
		d.lp = lp.lp_dup(z.lp)
		return d
	}
	d := create_skiplist(z.sl.length)
	for n := sl_first(z.sl); n != nil; n = sl_next(n) {
		_ = sl_insert(d.sl, n.score, node_member(n), n.hash)
	}
	return d
}

iter_make :: proc(z: Zset, reverse: bool) -> (it: Iter) {
	it.z = z
	it.reverse = reverse
	return
}

iter_next :: proc(it: ^Iter, out: ^Item) -> bool {
	if it.z.encoding == .Listpack {
		if !it.started {
			it.started = true
			if it.reverse {
				it.sptr = lp.lp_last(it.z.lp)
				if it.sptr != nil {
					it.eptr = lp.lp_prev(it.z.lp, it.sptr)
				}
			} else {
				it.eptr = lp.lp_first(it.z.lp)
				if it.eptr != nil {
					it.sptr = lp.lp_next(it.z.lp, it.eptr)
				}
			}
		} else if it.reverse {
			zzl_prev(it.z.lp, &it.eptr, &it.sptr)
		} else {
			zzl_next(it.z.lp, &it.eptr, &it.sptr)
		}
		if it.eptr == nil {
			return false
		}
		out^ = item_from_lp(it.eptr)
		out.score = zzl_score(it.sptr)
		return true
	}
	if !it.started {
		it.started = true
		if it.reverse {
			it.node = it.z.sl.tail
		} else {
			it.node = sl_first(it.z.sl)
		}
	} else if it.node != nil {
		if it.reverse {
			it.node = it.node.backward
		} else {
			it.node = sl_next(it.node)
		}
	}
	if it.node == nil {
		return false
	}
	out^ = item_from_node(it.node)
	return true
}

rank_range :: proc(z: Zset, start_in, end_in: i64, reverse: bool, out: ^[dynamic]Item) {
	n := i64(length(z))
	start, end := start_in, end_in
	if start < 0 {
		start += n
	}
	if end < 0 {
		end += n
	}
	start = max(start, 0)
	end = min(end, n - 1)
	if start > end {
		return
	}
	it := iter_make(z, reverse)
	item: Item
	for i: i64 = 0; i <= end && iter_next(&it, &item); i += 1 {
		if i >= start {
			append(out, item)
		}
	}
}

score_range :: proc(z: Zset, r: ^Range_Spec, offset_in, limit: i64, reverse: bool, out: ^[dynamic]Item) {
	if offset_in < 0 || limit == 0 || range_empty(r) {
		return
	}
	offset := offset_in
	left := limit
	it := iter_make(z, reverse)
	item: Item
	for iter_next(&it, &item) {
		if !value_gte_min(item.score, r) || !value_lte_max(item.score, r) {
			continue
		}
		if offset > 0 {
			offset -= 1
			continue
		}
		append(out, item)
		if left > 0 {
			left -= 1
			if left == 0 {
				break
			}
		}
	}
}

lex_in_range :: proc(z: Zset, r: ^Lex_Spec) -> bool {
	if z.encoding == .Listpack {
		return zzl_is_in_lex_range(z.lp, r)
	}
	return sl_is_in_lex_range(z.sl, r)
}

@(private = "file")
lex_reverse_start :: proc(z: Zset, r: ^Lex_Spec, it: ^Iter, item: ^Item) -> bool {
	if z.encoding == .Listpack {
		buf: [lp.DECIMAL_BUFFER_BYTES]u8
		for iter_next(it, item) {
			if lex_lte_max(item_bytes(item, &buf), r) {
				return lex_gte_min(item_bytes(item, &buf), r)
			}
		}
		return false
	}
	start: ^Node
	for n := sl_first(z.sl); n != nil && lex_lte_max(node_member(n), r); n = sl_next(n) {
		start = n
	}
	if start == nil {
		return false
	}
	it.started = true
	it.node = start
	item^ = item_from_node(start)
	return true
}

@(private = "file")
lex_forward_start :: proc(z: Zset, r: ^Lex_Spec, it: ^Iter, item: ^Item) -> bool {
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	for iter_next(it, item) {
		if lex_gte_min(item_bytes(item, &buf), r) {
			return z.encoding != .Listpack || lex_lte_max(item_bytes(item, &buf), r)
		}
	}
	return false
}

lex_range :: proc(z: Zset, r: ^Lex_Spec, offset_in, limit: i64, reverse: bool, with_scores: bool, out: ^[dynamic]Item) {
	if offset_in < 0 || limit == 0 || !lex_in_range(z, r) {
		return
	}
	it := iter_make(z, reverse)
	item: Item
	found := lex_reverse_start(z, r, &it, &item) if reverse else lex_forward_start(z, r, &it, &item)
	if !found {
		return
	}
	for skip := offset_in; skip > 0; skip -= 1 {
		if !iter_next(&it, &item) {
			return
		}
	}
	left := limit
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	for {
		member := item_bytes(&item, &buf)
		inside := lex_gte_min(member, r) if reverse else lex_lte_max(member, r)
		if !inside {
			break
		}
		append(out, item)
		if left > 0 {
			left -= 1
			if left == 0 {
				break
			}
		}
		if !iter_next(&it, &item) {
			break
		}
	}
}

count_in_range :: proc(z: Zset, r: ^Range_Spec) -> int {
	it := iter_make(z, false)
	item: Item
	count := 0
	for iter_next(&it, &item) {
		if value_gte_min(item.score, r) && value_lte_max(item.score, r) {
			count += 1
		}
	}
	return count
}

lex_count :: proc(z: Zset, r: ^Lex_Spec) -> int {
	if !lex_in_range(z, r) {
		return 0
	}
	it := iter_make(z, false)
	item: Item
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	found := false
	for iter_next(&it, &item) {
		if lex_gte_min(item_bytes(&item, &buf), r) {
			found = true
			break
		}
	}
	count := 0
	for found && lex_lte_max(item_bytes(&item, &buf), r) {
		count += 1
		found = iter_next(&it, &item)
	}
	return count
}

remrange_by_rank :: proc(z: Zset, start_in, end_in: i64) -> int {
	n := i64(length(z))
	start, end := start_in, end_in
	if start < 0 {
		start += n
	}
	if end < 0 {
		end += n
	}
	start = max(start, 0)
	end = min(end, n - 1)
	if start > end {
		return 0
	}
	if z.encoding == .Listpack {
		pack, deleted := zzl_delete_range_by_rank(z.lp, int(start + 1), int(end + 1))
		z.lp = pack
		return deleted
	}
	return sl_delete_range_by_rank(z.sl, u64(start + 1), u64(end + 1))
}

remrange_by_score :: proc(z: Zset, r: ^Range_Spec) -> int {
	if z.encoding == .Listpack {
		pack, deleted := zzl_delete_range_by_score(z.lp, r)
		z.lp = pack
		return deleted
	}
	return sl_delete_range_by_score(z.sl, r)
}

remrange_by_lex :: proc(z: Zset, r: ^Lex_Spec) -> int {
	if z.encoding == .Listpack {
		pack, deleted := zzl_delete_range_by_lex(z.lp, r)
		z.lp = pack
		return deleted
	}
	return sl_delete_range_by_lex(z.sl, r)
}

peek :: proc(z: Zset, max_end: bool) -> Item {
	if length(z) == 0 {
		return {}
	}
	if z.encoding == .Listpack {
		p := lp.lp_first(z.lp)
		if max_end {
			p = lp.lp_prev(z.lp, lp.lp_last(z.lp))
		}
		item := item_from_lp(p)
		item.score = zzl_score(lp.lp_next(z.lp, p))
		return item
	}
	n := sl_first(z.sl)
	if max_end {
		n = z.sl.tail
	}
	return item_from_node(n)
}

pop :: proc(z: Zset, max_end: bool) {
	if length(z) == 0 {
		return
	}
	if z.encoding == .Listpack {
		p := lp.lp_first(z.lp)
		if max_end {
			p = lp.lp_prev(z.lp, lp.lp_last(z.lp))
		}
		z.lp = zzl_delete(z.lp, p)
		return
	}
	n := sl_first(z.sl)
	if max_end {
		n = z.sl.tail
	}
	sl_remove(z.sl, n)
}

maybe_convert :: proc(z: Zset, size_hint: int) {
	if z.encoding == .Listpack && size_hint > zset_max_listpack_entries {
		convert_to_skiplist(z, size_hint)
	}
}

convert_to_listpack_if_needed :: proc(z: Zset, maxelelen: int, totelelen: int) {
	if z.encoding == .Skiplist && z.sl.length <= zset_max_listpack_entries && maxelelen <= zset_max_listpack_value && lp.lp_safe_to_add(nil, totelelen) {
		convert_to_listpack(z)
	}
}

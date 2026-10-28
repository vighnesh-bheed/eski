package zsettype

import lp "../listpack"

Item :: struct {
	str:    []u8,
	ival:   i64,
	score:  f64,
	is_int: bool,
	g17:    bool,
}

item_from_lp :: proc "contextless" (p: [^]u8) -> Item {
	it: Item
	if p == nil {
		return it
	}
	e := lp.lp_get_entry(p)
	if e.sval == nil {
		it.is_int = true
		it.ival = e.lval
	} else {
		it.str = e.sval[:int(e.slen)]
	}
	return it
}

item_from_node :: proc "contextless" (n: ^Node) -> Item {
	if n == nil {
		return {}
	}
	return Item{str = node_member(n), score = n.score}
}

item_bytes :: proc "contextless" (it: ^Item, buf: ^[lp.LP_INTBUF_SIZE]u8) -> []u8 {
	if it.is_int {
		n := lp.ll2string(raw_data(buf[:]), it.ival)
		return buf[:n]
	}
	return it.str
}

zzl_score :: proc "contextless" (sptr: [^]u8) -> f64 {
	e := lp.lp_get_entry(sptr)
	if e.sval == nil {
		return f64(e.lval)
	}
	return score_from_lp_string(e.sval[:int(e.slen)])
}

zzl_member :: proc "contextless" (eptr: [^]u8, buf: ^[lp.LP_INTBUF_SIZE]u8) -> []u8 {
	return lp.lp_get_bytes(eptr, buf)
}

zzl_compare :: proc "contextless" (eptr: [^]u8, s: []u8) -> int {
	buf: [lp.LP_INTBUF_SIZE]u8
	return member_cmp(zzl_member(eptr, &buf), s)
}

zzl_length :: proc(zl: [^]u8) -> int {
	return int(lp.lp_length(zl) / 2)
}

zzl_next :: proc(zl: [^]u8, eptr, sptr: ^[^]u8) {
	if eptr^ == nil || sptr^ == nil {
		eptr^ = nil
		sptr^ = nil
		return
	}
	eptr^ = lp.lp_next(zl, sptr^)
	if eptr^ == nil {
		sptr^ = nil
	} else {
		sptr^ = lp.lp_next(zl, eptr^)
	}
}

zzl_prev :: proc(zl: [^]u8, eptr, sptr: ^[^]u8) {
	if eptr^ == nil || sptr^ == nil {
		eptr^ = nil
		sptr^ = nil
		return
	}
	sptr^ = lp.lp_prev(zl, eptr^)
	if sptr^ == nil {
		eptr^ = nil
	} else {
		eptr^ = lp.lp_prev(zl, sptr^)
	}
}

zzl_is_in_range :: proc(zl: [^]u8, r: ^Range_Spec) -> bool {
	if range_empty(r) || zzl_length(zl) == 0 {
		return false
	}
	return value_gte_min(zzl_score(lp.lp_last(zl)), r) && value_lte_max(zzl_score(lp.lp_next(zl, lp.lp_first(zl))), r)
}

zzl_first_in_range :: proc(zl: [^]u8, r: ^Range_Spec) -> [^]u8 {
	if !zzl_is_in_range(zl, r) {
		return nil
	}
	for p := lp.lp_first(zl); p != nil; {
		s := lp.lp_next(zl, p)
		v := zzl_score(s)
		if value_gte_min(v, r) {
			if value_lte_max(v, r) {
				return p
			}
			return nil
		}
		p = lp.lp_next(zl, s)
	}
	return nil
}

zzl_last_in_range :: proc(zl: [^]u8, r: ^Range_Spec) -> [^]u8 {
	if !zzl_is_in_range(zl, r) {
		return nil
	}
	for s := lp.lp_last(zl); s != nil; {
		p := lp.lp_prev(zl, s)
		v := zzl_score(s)
		if value_lte_max(v, r) {
			if value_gte_min(v, r) {
				return p
			}
			return nil
		}
		s = lp.lp_prev(zl, p)
	}
	return nil
}

zzl_lex_gte_min :: proc "contextless" (p: [^]u8, r: ^Lex_Spec) -> bool {
	buf: [lp.LP_INTBUF_SIZE]u8
	return lex_gte_min(zzl_member(p, &buf), r)
}

zzl_lex_lte_max :: proc "contextless" (p: [^]u8, r: ^Lex_Spec) -> bool {
	buf: [lp.LP_INTBUF_SIZE]u8
	return lex_lte_max(zzl_member(p, &buf), r)
}

zzl_is_in_lex_range :: proc(zl: [^]u8, r: ^Lex_Spec) -> bool {
	if lex_range_empty(r) || zzl_length(zl) == 0 {
		return false
	}
	return zzl_lex_gte_min(lp.lp_prev(zl, lp.lp_last(zl)), r) && zzl_lex_lte_max(lp.lp_first(zl), r)
}

zzl_first_in_lex_range :: proc(zl: [^]u8, r: ^Lex_Spec) -> [^]u8 {
	if !zzl_is_in_lex_range(zl, r) {
		return nil
	}
	for p := lp.lp_first(zl); p != nil; {
		if zzl_lex_gte_min(p, r) {
			if zzl_lex_lte_max(p, r) {
				return p
			}
			return nil
		}
		p = lp.lp_next(zl, lp.lp_next(zl, p))
	}
	return nil
}

zzl_last_in_lex_range :: proc(zl: [^]u8, r: ^Lex_Spec) -> [^]u8 {
	if !zzl_is_in_lex_range(zl, r) {
		return nil
	}
	for s := lp.lp_last(zl); s != nil; {
		p := lp.lp_prev(zl, s)
		if zzl_lex_lte_max(p, r) {
			if zzl_lex_gte_min(p, r) {
				return p
			}
			return nil
		}
		s = lp.lp_prev(zl, p)
	}
	return nil
}

zzl_find :: proc(zl: [^]u8, member: []u8) -> (eptr: [^]u8, score: f64, found: bool) {
	p := lp.lp_find(zl, lp.lp_first(zl), member, 1)
	if p == nil {
		return nil, 0, false
	}
	return p, zzl_score(lp.lp_next(zl, p)), true
}

zzl_delete :: proc(zl: [^]u8, eptr: [^]u8) -> [^]u8 {
	p := eptr
	return lp.lp_delete_range_with_entry(zl, &p, 2)
}

zzl_insert_at :: proc(zl: [^]u8, eptr: [^]u8, member: []u8, score: f64) -> [^]u8 {
	buf: [D2STRING_MAX]u8
	value: lp.Entry
	if integer, exact := double2ll(score); exact {
		value = lp.entry_from_int(integer)
	} else {
		n := d2string(buf[:], score)
		value = lp.entry_from_bytes(buf[:n])
	}
	entries := [2]lp.Entry{lp.entry_from_bytes(member), value}
	if eptr == nil {
		return lp.lp_batch_append(zl, entries[:])
	}
	return lp.lp_batch_insert(zl, eptr, lp.LP_BEFORE, entries[:], nil)
}

zzl_insert :: proc(zl: [^]u8, member: []u8, score: f64) -> [^]u8 {
	for p := lp.lp_first(zl); p != nil; {
		s := lp.lp_next(zl, p)
		v := zzl_score(s)
		if v > score || v == score && zzl_compare(p, member) > 0 {
			return zzl_insert_at(zl, p, member, score)
		}
		p = lp.lp_next(zl, s)
	}
	return zzl_insert_at(zl, nil, member, score)
}

zzl_delete_range_by_score :: proc(zl: [^]u8, r: ^Range_Spec) -> (out: [^]u8, deleted: int) {
	out = zl
	p := zzl_first_in_range(out, r)
	for p != nil && value_lte_max(zzl_score(lp.lp_next(out, p)), r) {
		out = lp.lp_delete_range_with_entry(out, &p, 2)
		deleted += 1
	}
	return
}

zzl_delete_range_by_lex :: proc(zl: [^]u8, r: ^Lex_Spec) -> (out: [^]u8, deleted: int) {
	out = zl
	p := zzl_first_in_lex_range(out, r)
	for p != nil && zzl_lex_lte_max(p, r) {
		out = lp.lp_delete_range_with_entry(out, &p, 2)
		deleted += 1
	}
	return
}

zzl_delete_range_by_rank :: proc(zl: [^]u8, start, end: int) -> (out: [^]u8, deleted: int) {
	n := zzl_length(zl)
	if start < 1 || end < start || start > n {
		return zl, 0
	}
	deleted = min(end, n) - start + 1
	return lp.lp_delete_range(zl, i64(start - 1) * 2, u64(deleted) * 2), deleted
}

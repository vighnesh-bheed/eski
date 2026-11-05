package hashtype

import lp "../listpack"

convert_to_ex :: proc(h: Hash) {
	ensure_meta(h)
	if h.encoding != .Listpack {
		return
	}
	count := length(h)
	if !lp.lp_safe_to_add(h.lp, count * lp.lp_integer_entry_size(0)) {
		convert(h)
		return
	}
	packed := lp.lp_new(0)
	it := iterator(h)
	for next(&it) {
		entries := [3]lp.Element{value_to_entry(current_field(&it)), value_to_entry(current_value(&it)), lp.entry_from_int(0)}
		packed = lp.lp_append_entries(packed, entries[:])
	}
	lp.lp_free(h.lp)
	h.lp = packed
	h.encoding = .Listpack_Ex
}

lpex_locate :: proc(h: Hash, field: []u8) -> (field_at, value_at: [^]u8, mark: i64, ok: bool) {
	field_at = lp_find_field(h.lp, field, 2)
	if field_at == nil {
		return
	}
	value_at = pack_next(field_at)
	if value_at == nil {
		return
	}
	t := pack_next(value_at)
	if t == nil {
		return
	}
	mark = value_from_lp(t).ival
	ok = true
	return
}

lpex_min_expire :: proc(zl: [^]u8) -> u64 {
	field := pack_first(zl)
	if field == nil {
		return DEADLINE_UNSET
	}
	value := pack_next(field)
	if value == nil {
		return DEADLINE_UNSET
	}
	t := pack_next(value)
	if t == nil {
		return DEADLINE_UNSET
	}
	deadline := value_from_lp(t).ival
	if deadline <= 0 {
		return DEADLINE_UNSET
	}
	return u64(deadline)
}

fields_with_expire :: proc(h: Hash) -> bool {
	if h.encoding == .Hashtable {
		return h.table.vol_len > 0
	}
	return h.encoding == .Listpack_Ex && lpex_min_expire(h.lp) != DEADLINE_UNSET
}

earliest_deadline :: proc(h: Hash) -> u64 {
	if h.encoding == .Hashtable {
		return vol_min(h.table)
	}
	if h.encoding == .Listpack_Ex {
		return lpex_min_expire(h.lp)
	}
	return DEADLINE_UNSET
}

dump_min_expire :: proc "contextless" (h: Hash) -> u64 {
	booked := DEADLINE_UNSET
	switch h.encoding {
	case .Hashtable:
		booked = vol_min(h.table)
	case .Listpack_Ex:
		booked = registered_expire(h)
	case .Listpack:
	}
	return 0 if booked == DEADLINE_UNSET else booked
}

pack_mark :: #force_inline proc "contextless" (deadline: u64) -> i64 {
	return 0 if deadline == DEADLINE_UNSET else i64(deadline)
}

pack_slot_for :: proc(zl: [^]u8, mark: i64) -> [^]u8 {
	if mark <= 0 {
		return nil
	}
	for at := pack_first(zl); at != nil; at = pack_next(pack_next(pack_next(at))) {
		held := value_from_lp(pack_next(pack_next(at))).ival
		if held == 0 || mark <= held {
			return at
		}
	}
	return nil
}

lpex_add_new :: proc(h: Hash, field, value: []u8, expire_at: u64) {
	mark := pack_mark(expire_at)
	tuple := [3]lp.Element{lp.entry_from_bytes(field), lp.entry_from_bytes(value), lp.entry_from_int(mark)}
	if slot := pack_slot_for(h.lp, mark); slot != nil {
		h.lp = lp.lp_splice_entries(h.lp, tuple[:], slot, lp.Placement.Before, nil)
	} else {
		h.lp = lp.lp_append_entries(h.lp, tuple[:])
	}
}

pack_retime :: proc(h: Hash, field_at: [^]u8, deadline: u64) {
	spelled: [2][lp.DECIMAL_BUFFER_BYTES]u8
	field := value_bytes(value_from_lp(field_at), &spelled[0])
	value := value_bytes(value_from_lp(pack_next(field_at)), &spelled[1])
	lpex_replace_value(h, field_at, field, value, deadline)
}

lpex_replace_value :: proc(h: Hash, fptr: [^]u8, field, value: []u8, expire_at: u64) {
	storage := mem_alloc(max(len(field) + len(value), 1))
	defer mem_free(storage)
	f := storage[:len(field)]
	v := storage[len(field):len(field) + len(value)]
	copy(f, field)
	copy(v, value)
	p := fptr
	h.lp = lp.lp_delete_range_with_entry(h.lp, &p, 3)
	lpex_add_new(h, f, v, expire_at)
}

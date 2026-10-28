package hashtype

import lp "../listpack"

convert_to_ex :: proc(h: Hash) {
	ensure_meta(h)
	if h.encoding != .Listpack {
		return
	}
	count := length(h)
	if !lp.lp_safe_to_add(h.lp, count * lp.lp_entry_size_integer(0)) {
		convert(h)
		return
	}
	packed := lp.lp_new(0)
	it := iterator(h)
	for next(&it) {
		entries := [3]lp.Entry{value_to_entry(current_field(&it)), value_to_entry(current_value(&it)), lp.entry_from_int(0)}
		packed = lp.lp_batch_append(packed, entries[:])
	}
	lp.lp_free(h.lp)
	h.lp = packed
	h.encoding = .Listpack_Ex
}

lpex_locate :: proc(h: Hash, field: []u8) -> (fptr, vptr: [^]u8, ttl: i64, ok: bool) {
	fptr = lp_find_field(h.lp, field, 2)
	if fptr == nil {
		return
	}
	vptr = pack_next(fptr)
	if vptr == nil {
		return
	}
	t := pack_next(vptr)
	if t == nil {
		return
	}
	ttl = value_from_lp(t).ival
	ok = true
	return
}

lpex_min_expire :: proc(zl: [^]u8) -> u64 {
	field := pack_first(zl)
	if field == nil {
		return EB_EXPIRE_TIME_INVALID
	}
	value := pack_next(field)
	if value == nil {
		return EB_EXPIRE_TIME_INVALID
	}
	t := pack_next(value)
	if t == nil {
		return EB_EXPIRE_TIME_INVALID
	}
	deadline := value_from_lp(t).ival
	if deadline <= 0 {
		return EB_EXPIRE_TIME_INVALID
	}
	return u64(deadline)
}

fields_with_expire :: proc(h: Hash) -> bool {
	if h.encoding == .Hashtable {
		return h.table.vol_len > 0
	}
	return h.encoding == .Listpack_Ex && lpex_min_expire(h.lp) != EB_EXPIRE_TIME_INVALID
}

min_expire :: proc(h: Hash, accurate: bool) -> u64 {
	if !accurate {
		return registered_expire(h)
	}
	switch h.encoding {
	case .Hashtable:
		return vol_min(h.table)
	case .Listpack_Ex:
		return lpex_min_expire(h.lp)
	case .Listpack:
		return EB_EXPIRE_TIME_INVALID
	}
	unreachable()
}

dump_min_expire :: proc "contextless" (h: Hash) -> u64 {
	if h.encoding == .Hashtable {
		return vol_min(h.table)
	}
	deadline := EB_EXPIRE_TIME_INVALID
	if h.encoding == .Listpack_Ex {
		deadline = registered_expire(h)
	}
	if deadline == EB_EXPIRE_TIME_INVALID {
		return 0
	}
	return deadline
}

lpex_dry_run :: proc(zl: [^]u8, now: u64) -> int {
	n := 0
	f := pack_first(zl)
	for f != nil {
		v := pack_next(f)
		if v == nil {
			break
		}
		t := pack_next(v)
		if t == nil {
			break
		}
		deadline := value_from_lp(t).ival
		if deadline == 0 || u64(deadline) >= now {
			break
		}
		n += 1
		f = pack_next(t)
	}
	return n
}

lpex_add_internal :: proc(h: Hash, ent: ^[3]lp.Entry) {
	total := 0
	for entry in ent^ {
		if entry.sval != nil {
			total += int(entry.slen)
		}
	}
	storage := mem_alloc(max(total, 1))
	defer mem_free(storage)
	owned := ent^
	position := 0
	for entry, i in ent^ {
		if entry.sval != nil {
			n := int(entry.slen)
			dst := storage[position:position + n]
			copy(dst, entry.sval[:n])
			owned[i] = lp.entry_from_bytes(dst)
			position += n
		}
	}
	deadline := owned[2].lval
	f := pack_first(h.lp)
	insert_at: [^]u8
	if deadline > 0 {
		for f != nil {
			v := pack_next(f)
			t := pack_next(v)
			old := value_from_lp(t).ival
			if old == 0 || deadline <= old {
				insert_at = f
				break
			}
			f = pack_next(t)
		}
	}
	if insert_at == nil {
		h.lp = lp.lp_batch_append(h.lp, owned[:])
	} else {
		h.lp = lp.lp_batch_insert(h.lp, insert_at, lp.LP_BEFORE, owned[:], nil)
	}
}

lpex_add_new :: proc(h: Hash, field, value: []u8, expire_at: u64) {
	entries := [3]lp.Entry{lp.entry_from_bytes(field), lp.entry_from_bytes(value), lp.entry_from_int(i64(expire_at))}
	lpex_add_internal(h, &entries)
}

lpex_update_expiry :: proc(h: Hash, field: []u8, fptr, vptr: [^]u8, expire_at: u64) {
	fbuf, vbuf: [lp.LP_INTBUF_SIZE]u8
	old_field := value_bytes(value_from_lp(fptr), &fbuf)
	old_value := value_bytes(value_from_lp(vptr), &vbuf)
	storage := mem_alloc(max(len(old_field) + len(old_value), 1))
	defer mem_free(storage)
	f := storage[:len(old_field)]
	v := storage[len(old_field):len(old_field) + len(old_value)]
	copy(f, old_field)
	copy(v, old_value)
	p := fptr
	h.lp = lp.lp_delete_range_with_entry(h.lp, &p, 3)
	lpex_add_new(h, f, v, expire_at)
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

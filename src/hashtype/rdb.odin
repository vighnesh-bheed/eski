package hashtype

import lp "../listpack"
import rdb "../rdb"

RDB_HASH_INITIAL_RESERVE_MAX :: 4096

rdb_type :: proc "contextless" (h: Hash) -> u8 {
	switch h.encoding {
	case .Listpack:
		return rdb.TYPE_HASH_LISTPACK
	case .Listpack_Ex:
		return rdb.TYPE_HASH_LISTPACK_EX
	case .Hashtable:
		if h.table.vol_len > 0 {
			return rdb.TYPE_HASH_TABLE_EX
		}
		return rdb.TYPE_HASH
	}
	unreachable()
}

rdb_save :: proc "contextless" (w: ^rdb.Writer, h: Hash) {
	type := rdb_type(h)
	minimum := DEADLINE_UNSET
	if type == rdb.TYPE_HASH_TABLE_EX || type == rdb.TYPE_HASH_LISTPACK_EX {
		minimum = dump_min_expire(h)
		rdb.put_ms(w, i64(minimum))
	}
	if h.encoding != .Hashtable {
		rdb.put_string(w, lp.lp_view(h.lp))
		return
	}
	rdb.put_len(w, u64(h.table.count))
	it := iterator(h)
	for next(&it) {
		if type == rdb.TYPE_HASH_TABLE_EX {
			expiry := current_expire(&it)
			delta := u64(0)
			if expiry != DEADLINE_UNSET {
				delta = expiry - minimum + 1
			}
			rdb.put_len(w, delta)
		}
		rdb.put_string(w, current_field(&it).str)
		rdb.put_string(w, current_value(&it).str)
	}
}

rdb_fail :: proc(r: ^rdb.Reader, h: Hash, msg: string) -> Hash {
	destroy(h)
	if len(msg) > 0 {
		rdb.corrupt(r, msg)
	}
	return nil
}

Row_Layout :: struct {
	stride:     int,
	headroom:   int,
	kind:       int,
	base:       u64,
	pack_limit: u64,
}

row_fits_pack :: proc(h: Hash, field, value: []u8, headroom: int) -> bool {
	return max(len(field), len(value)) <= hash_max_listpack_value && lp.lp_safe_to_add(h.lp, len(field) + len(value) + headroom)
}

spill_if_needed :: proc(r: ^rdb.Reader, h: Hash, field, value: []u8, layout: Row_Layout, reserve: int) -> bool {
	if h.encoding == .Hashtable || row_fits_pack(h, field, value, layout.headroom) {
		return true
	}
	if !rdb.lp_validate_dups(lp.lp_view(h.lp), true, layout.stride) {
		rdb.corrupt(r, "Duplicate hash fields detected")
		return false
	}
	convert(h, reserve)
	return true
}

pack_row :: proc(h: Hash, field, value: []u8, deadline: u64, stride: int) {
	if stride == 3 {
		lpex_add_new(h, field, value, deadline)
		return
	}
	pair := [2]lp.Element{lp.entry_from_bytes(field), lp.entry_from_bytes(value)}
	h.lp = lp.lp_append_entries(h.lp, pair[:])
}

admit_row :: proc(r: ^rdb.Reader, h: Hash, field, value: []u8, deadline: u64, layout: Row_Layout, reserve: int, deep: bool, seen: ^rdb.Dup_Set) -> bool {
	if !spill_if_needed(r, h, field, value, layout, reserve) {
		return false
	}
	if h.encoding != .Hashtable {
		if deep && !rdb.dup_add(seen, field) {
			rdb.corrupt(r, "Hash with dup elements")
			return false
		}
		pack_row(h, field, value, deadline, layout.stride)
		return true
	}
	blob := table_add_new(h.table, field, value)
	if blob == nil {
		rdb.corrupt(r, "Duplicate hash fields detected")
		return false
	}
	vol_set(h.table, blob, deadline)
	return true
}

load_rows :: proc(r: ^rdb.Reader, count: u64, layout: Row_Layout, deep: bool) -> Hash {
	if !rdb.ok(r) {
		return nil
	}
	if count == 0 {
		r.status = .Empty_Key
		return nil
	}
	reserve := int(min(count, u64(RDB_HASH_INITIAL_RESERVE_MAX)))
	h := create()
	if layout.stride == 3 {
		convert_to_ex(h)
	}
	if count > layout.pack_limit {
		convert(h, reserve)
	}
	seen: rdb.Dup_Set
	defer rdb.dup_destroy(&seen)
	for _ in 0 ..< count {
		deadline := DEADLINE_UNSET
		if layout.stride == 3 {
			got: bool
			deadline, got = read_row_deadline(r, layout)
			if !got {
				break
			}
		}
		field, field_read := rdb.get_string(r, 0)
		if !field_read {
			break
		}
		value, value_read := rdb.get_string(r, 1)
		if !value_read || !admit_row(r, h, field, value, deadline, layout, reserve, deep, &seen) {
			break
		}
	}
	if !rdb.ok(r) {
		destroy(h)
		return nil
	}
	return h
}

rdb_load_plain :: proc(r: ^rdb.Reader, deep: bool) -> Hash {
	layout := Row_Layout{stride = 2, headroom = 32, kind = rdb.TYPE_HASH, pack_limit = u64(hash_max_listpack_entries)}
	return load_rows(r, rdb.get_len(r), layout, deep)
}

rdb_repack_loaded :: proc(h: Hash) -> bool {
	if length(h) > hash_max_listpack_entries {
		if !rdb.lp_validate_dups(lp.lp_view(h.lp), true, pack_stride(h)) {
			return false
		}
		convert(h)
	}
	return true
}

rdb_load_blob :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> Hash {
	ex := rdbtype == rdb.TYPE_HASH_LISTPACK_EX || rdbtype == rdb.TYPE_HASH_LISTPACK_EX_RC
	if rdbtype == rdb.TYPE_HASH_LISTPACK_EX {
		_, ok := rdb.get_ms(r)
		if !ok {
			return nil
		}
	}
	blob, ok := rdb.get_string(r, 0)
	if !ok {
		return nil
	}
	width := 2
	if ex {
		width = 3
	}
	if !rdb.lp_validate_dups(blob, deep, width) {
		msg := "Hash listpack integrity check failed."
		if ex {
			msg = "Hash field-expiry listpack integrity check failed."
		}
		rdb.corrupt(r, msg)
		return nil
	}
	h := create()
	lp.lp_free(h.lp)
	h.lp = rdb.lp_copy(blob)
	if ex {
		h.encoding = .Listpack_Ex
		ensure_meta(h)
	}
	if length(h) == 0 {
		destroy(h)
		r.status = .Empty_Key
		return nil
	}
	if !rdb_repack_loaded(h) {
		msg := "Hash listpack integrity check failed."
		if ex {
			msg = "Hash field-expiry listpack integrity check failed."
		}
		return rdb_fail(r, h, msg)
	}
	return h
}

rdb_load_ziplist :: proc(r: ^rdb.Reader) -> Hash {
	blob, ok := rdb.get_string(r, 0)
	if !ok {
		return nil
	}
	packed, valid := rdb.ziplist_to_listpack(blob, true)
	if !valid {
		rdb.corrupt(r, "Hash ziplist integrity check failed.")
		return nil
	}
	if !rdb.lp_validate_dups(lp.lp_view(packed), true, 2) {
		lp.lp_free(packed)
		rdb.corrupt(r, "Hash ziplist integrity check failed.")
		return nil
	}
	h := create()
	lp.lp_free(h.lp)
	h.lp = packed
	if length(h) == 0 {
		destroy(h)
		r.status = .Empty_Key
		return nil
	}
	if !rdb_repack_loaded(h) {
		return rdb_fail(r, h, "Hash ziplist integrity check failed.")
	}
	return h
}

rdb_load_zipmap :: proc(r: ^rdb.Reader) -> Hash {
	blob, ok := rdb.get_string(r, 0)
	if !ok {
		return nil
	}
	if !rdb.zipmap_validate(blob) {
		rdb.corrupt(r, "Hash zipmap integrity check failed.")
		return nil
	}
	h := create()
	it := rdb.Zipmap_Iter{zm = blob, p = 1}
	f, v: []u8
	for rdb.zipmap_next(&it, &f, &v) {
		if set(h, f, v) {
			return rdb_fail(r, h, "Duplicate hash fields detected")
		}
	}
	if length(h) == 0 {
		destroy(h)
		r.status = .Empty_Key
		return nil
	}
	return h
}

rdb_load :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> Hash {
	switch rdbtype {
	case rdb.TYPE_HASH:
		return rdb_load_plain(r, deep)
	case rdb.TYPE_HASH_TABLE_EX, rdb.TYPE_HASH_TABLE_EX_RC:
		return rdb_load_meta(r, rdbtype, deep)
	case rdb.TYPE_HASH_LISTPACK, rdb.TYPE_HASH_LISTPACK_EX, rdb.TYPE_HASH_LISTPACK_EX_RC:
		return rdb_load_blob(r, rdbtype, deep)
	case rdb.TYPE_HASH_ZIPLIST:
		return rdb_load_ziplist(r)
	case rdb.TYPE_HASH_ZIPMAP:
		return rdb_load_zipmap(r)
	case:
		rdb.corrupt(r, "Unsupported hash type")
		return nil
	}
}

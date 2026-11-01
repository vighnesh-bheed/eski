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
	minimum := NO_FIELD_DEADLINE
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
			if expiry != NO_FIELD_DEADLINE {
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

rdb_load_plain :: proc(r: ^rdb.Reader, deep: bool) -> Hash {
	count := rdb.get_len(r)
	if count == rdb.LENERR {
		return nil
	}
	if count == 0 {
		r.status = .Empty_Key
		return nil
	}
	h := create()
	reserve := int(min(count, u64(RDB_HASH_INITIAL_RESERVE_MAX)))
	if count > u64(hash_max_listpack_entries) {
		convert(h, reserve)
	}
	duplicates: rdb.Dup_Set
	defer rdb.dup_destroy(&duplicates)
	for _ in 0 ..< count {
		field, fok := rdb.get_string(r, 0)
		if !fok {
			return rdb_fail(r, h, "")
		}
		value, vok := rdb.get_string(r, 1)
		if !vok {
			return rdb_fail(r, h, "")
		}
		if h.encoding != .Hashtable && (len(field) > hash_max_listpack_value || len(value) > hash_max_listpack_value || !lp.lp_safe_to_add(h.lp, len(field) + len(value) + 32)) {
			if !rdb.lp_validate_dups(lp.lp_view(h.lp), true, 2) {
				return rdb_fail(r, h, "Duplicate hash fields detected")
			}
			convert(h, reserve)
		}
		if h.encoding == .Hashtable {
			if table_set(h.table, field, value) {
				return rdb_fail(r, h, "Duplicate hash fields detected")
			}
		} else {
			if deep && !rdb.dup_add(&duplicates, field) {
				return rdb_fail(r, h, "Hash with dup elements")
			}
			entries := [2]lp.Entry{lp.entry_from_bytes(field), lp.entry_from_bytes(value)}
			h.lp = lp.lp_batch_append(h.lp, entries[:])
		}
	}
	return h
}

rdb_repack_loaded :: proc(h: Hash) -> bool {
	convert_needed := length(h) > hash_max_listpack_entries
	it := iterator(h)
	for next(&it) {
		if value_len(current_field(&it)) > hash_max_listpack_value || value_len(current_value(&it)) > hash_max_listpack_value {
			convert_needed = true
			break
		}
	}
	if convert_needed {
		if !rdb.lp_validate_dups(lp.lp_view(h.lp), true, tuple_len(h)) {
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
			msg = "Hash listpackex integrity check failed."
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
			msg = "Hash listpackex integrity check failed."
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

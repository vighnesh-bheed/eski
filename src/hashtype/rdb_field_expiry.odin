package hashtype

import rdb "../rdb"

read_row_deadline :: proc(r: ^rdb.Reader, layout: Row_Layout) -> (deadline: u64, ok: bool) {
	encoded := rdb.get_len(r)
	if !rdb.ok(r) {
		return
	}
	if encoded == 0 {
		return DEADLINE_UNSET, true
	}
	absolute := u128(encoded)
	if layout.kind == rdb.TYPE_HASH_TABLE_EX {
		absolute = u128(layout.base) + absolute - 1
	}
	if absolute > u128(FIELD_DEADLINE_MAX) {
		rdb.corrupt(r, "has an invalid field expiry: deadline out of range ", u64(min(absolute, u128(max(u64)))), true)
		return
	}
	return u64(absolute), true
}

read_table_ex_header :: proc(r: ^rdb.Reader) -> (base: u64, ok: bool) {
	header, got := rdb.get_ms(r)
	if !got {
		r.status = .Ok
		rdb.corrupt(r, "has an invalid field expiry: the minimum deadline is truncated")
		return
	}
	return u64(header), true
}

rdb_load_meta :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> Hash {
	layout := Row_Layout{stride = 3, headroom = 48, kind = rdbtype, pack_limit = u64(max(hash_max_listpack_entries, 0))}
	if rdbtype == rdb.TYPE_HASH_TABLE_EX {
		base, got := read_table_ex_header(r)
		if !got {
			return nil
		}
		layout.base = base
	}
	return load_rows(r, rdb.get_len(r), layout, deep)
}

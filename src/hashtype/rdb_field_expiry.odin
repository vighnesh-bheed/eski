package hashtype

import lp "../listpack"
import rdb "../rdb"

rdb_load_meta :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> Hash {
	minimum := u64(0)
	if rdbtype == rdb.TYPE_HASH_TABLE_EX {
		header, ok := rdb.get_ms(r)
		if !ok {
			r.status = .Ok
			rdb.corrupt(r, "has an invalid field expiry: the minimum deadline is truncated")
			return nil
		}
		minimum = u64(header)
		if minimum > NO_FIELD_DEADLINE {
			rdb.corrupt(r, "has an invalid field expiry: the minimum deadline is out of range")
			return nil
		}
	}
	count := rdb.get_len(r)
	if !rdb.ok(r) {
		return nil
	}
	if count == 0 {
		r.status = .Empty_Key
		return nil
	}
	h := create()
	convert_to_ex(h)
	reserve := int(min(count, u64(RDB_HASH_INITIAL_RESERVE_MAX)))
	if count > u64(max(hash_max_listpack_entries, 0)) {
		convert(h, reserve)
	}
	duplicates: rdb.Dup_Set
	defer rdb.dup_destroy(&duplicates)
	for _ in 0 ..< count {
		encoded := rdb.get_len(r)
		if !rdb.ok(r) {
			return rdb_fail(r, h, "")
		}
		deadline := encoded
		if rdbtype == rdb.TYPE_HASH_TABLE_EX && encoded != 0 {
			absolute := u128(minimum) + u128(encoded) - 1
			if absolute > u128(FIELD_DEADLINE_MAX) {
				rdb.corrupt(r, "has an invalid field expiry: deadline out of range ", u64(min(absolute, u128(max(u64)))), true)
				return rdb_fail(r, h, "")
			}
			deadline = u64(absolute)
		}
		if deadline > FIELD_DEADLINE_MAX {
			rdb.corrupt(r, "has an invalid field expiry: deadline out of range ", deadline, true)
			return rdb_fail(r, h, "")
		}
		field, field_ok := rdb.get_string(r, 0)
		if !field_ok {
			return rdb_fail(r, h, "")
		}
		value, value_ok := rdb.get_string(r, 1)
		if !value_ok {
			return rdb_fail(r, h, "")
		}
		if h.encoding != .Hashtable && (len(field) > hash_max_listpack_value || len(value) > hash_max_listpack_value || !lp.lp_safe_to_add(h.lp, len(field) + len(value) + 48)) {
			if !rdb.lp_validate_dups(lp.lp_view(h.lp), true, 3) {
				return rdb_fail(r, h, "Duplicate hash fields detected")
			}
			convert(h, reserve)
		}
		if h.encoding == .Hashtable {
			b := table_add_new(h.table, field, value)
			if b == nil {
				return rdb_fail(r, h, "Duplicate hash fields detected")
			}
			if deadline != 0 {
				vol_set(h.table, b, deadline)
			}
		} else {
			if deep && !rdb.dup_add(&duplicates, field) {
				return rdb_fail(r, h, "Hash with dup elements")
			}
			lpex_add_new(h, field, value, deadline)
		}
	}
	return h
}

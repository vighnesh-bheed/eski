package settype

import rdb "../rdb"
import lp "../listpack"

rdb_type :: proc "contextless" (s: Set) -> u8 {
	switch s.encoding {
	case .Intset:
		return rdb.TYPE_SET_INTSET
	case .Listpack:
		return rdb.TYPE_SET_LISTPACK
	case .Hashtable:
		return rdb.TYPE_SET
	}
	return rdb.TYPE_SET
}

rdb_save :: proc "contextless" (w: ^rdb.Writer, s: Set) {
	if s.encoding != .Hashtable {
		rdb.put_string(w, raw_bytes(s))
		return
	}
	rdb.put_len(w, u64(s.table.count))
	for bank in 0 ..< 2 {
		slots, capacity := table_bank(s.table, bank)
		for index in 0 ..< capacity {
			if blob_live(slots[index].blob) {
				rdb.put_string(w, blob_bytes(slots[index].blob))
			}
		}
	}
}

intset_validate :: proc "contextless" (blob: []u8, deep: bool) -> bool {
	if len(blob) < INTSET_HDR_SIZE {
		return false
	}
	p := raw_data(blob)
	width := intset_encoding(p)
	if width != 2 && width != 4 && width != 8 {
		return false
	}
	count := intset_len(p)
	if count == 0 {
		return false
	}
	if count > (len(blob) - INTSET_HDR_SIZE) / int(width) || INTSET_HDR_SIZE + count * int(width) != len(blob) {
		return false
	}
	if deep {
		for index in 1 ..< count {
			if intset_get(p, index - 1) >= intset_get(p, index) {
				return false
			}
		}
	}
	return true
}

rdb_load :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> Set {
	if rdbtype == rdb.TYPE_SET_INTSET || rdbtype == rdb.TYPE_SET_LISTPACK {
		blob, good := rdb.get_string(r, 0)
		if !good {
			return nil
		}
		valid := false
		if rdbtype == rdb.TYPE_SET_INTSET {
			valid = intset_validate(blob, deep)
		} else {
			valid = rdb.lp_validate_dups(blob, deep, 1)
		}
		if !valid {
			rdb.corrupt(r, "Intset integrity check failed." if rdbtype == rdb.TYPE_SET_INTSET else "Set listpack integrity check failed.")
			return nil
		}
		s := object_new(.Intset if rdbtype == rdb.TYPE_SET_INTSET else .Listpack)
		s.data = lp.lp_malloc(len(blob))
		resize_require(s.data != nil)
		copy(s.data[:len(blob)], blob)
		if size(s) == 0 {
			destroy(s)
			r.status = .Empty_Key
			return nil
		}
		maybe_convert(s, size(s))
		return s
	}
	if rdbtype != rdb.TYPE_SET {
		rdb.corrupt(r, "Invalid set type")
		return nil
	}
	count := rdb.get_len(r)
	if !rdb.ok(r) {
		return nil
	}
	if count == 0 {
		r.status = .Empty_Key
		return nil
	}
	if count > u64(max(int)) || count > u64(TABLE_MAX_CAPACITY / 2) {
		rdb.corrupt(r, "Invalid set length")
		return nil
	}
	s: Set
	for _ in 0 ..< int(count) {
		member, good := rdb.get_string(r, 0)
		if !good {
			destroy(s)
			return nil
		}
		if s == nil {
			if count <= u64(intset_max_entries()) && lp.lp_string_to_int64(member, nil) {
				s = create_intset()
			} else if int(count) <= set_max_listpack_entries {
				s = create_listpack()
			} else {
				s = create_table(min(int(count), 128))
			}
		}
		inserted := add(s, member)
		if !inserted {
			destroy(s)
			rdb.corrupt(r, "Duplicate set members detected")
			return nil
		}
	}
	return s
}

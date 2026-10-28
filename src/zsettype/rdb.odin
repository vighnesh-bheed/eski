package zsettype

import rdb "../rdb"
import lp "../listpack"

rdb_type :: proc "contextless" (z: Zset) -> u8 {
	return z.encoding == .Listpack ? rdb.TYPE_ZSET_LISTPACK : rdb.TYPE_ZSET_2
}

rdb_save :: proc "contextless" (w: ^rdb.Writer, z: Zset) {
	if z.encoding == .Listpack {
		rdb.put_string(w, lp.lp_view(z.lp))
		return
	}
	rdb.put_len(w, u64(z.sl.length))
	for n := z.sl.tail; n != nil; n = n.backward {
		rdb.put_string(w, node_member(n))
		rdb.put_double_bin(w, n.score)
	}
}

rdb_load :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> Zset {
	if rdbtype == rdb.TYPE_ZSET_LISTPACK || rdbtype == rdb.TYPE_ZSET_ZIPLIST {
		blob, good := rdb.get_string(r, 0)
		if !good {
			return nil
		}
		pack: [^]u8
		reason := "Zset listpack integrity check failed."
		if rdbtype == rdb.TYPE_ZSET_ZIPLIST {
			reason = "Zset ziplist integrity check failed."
			pack, good = rdb.ziplist_to_listpack(blob, true)
			if good {
				good = rdb.lp_validate_dups(lp.lp_view(pack), true, 2)
			}
		} else {
			good = rdb.lp_validate_dups(blob, deep, 2)
			if good {
				pack = rdb.lp_copy(blob)
			}
		}
		if !good {
			lp.lp_free(pack)
			rdb.corrupt(r, reason)
			return nil
		}
		z := create_listpack()
		lp.lp_free(z.lp)
		z.lp = pack
		if zzl_length(pack) == 0 {
			r.status = .Empty_Key
			destroy(z)
			return nil
		}
		if zzl_length(pack) > zset_max_listpack_entries {
			seen := create_skiplist(zzl_length(pack))
			buf: [lp.LP_INTBUF_SIZE]u8
			valid := true
			for p := lp.lp_first(pack); p != nil; {
				sp := lp.lp_next(pack, p)
				member := zzl_member(p, &buf)
				value := zzl_score(sp)
				_, duplicate := score(seen, member)
				if is_nan(value) || duplicate {
					valid = false
					break
				}
				_, _, _ = add(seen, value, member, {})
				p = sp == nil ? nil : lp.lp_next(pack, sp)
			}
			destroy(seen)
			if !valid {
				destroy(z)
				rdb.corrupt(r, reason)
				return nil
			}
			convert_to_skiplist(z, zzl_length(pack))
		}
		return z
	}
	if rdbtype != rdb.TYPE_ZSET && rdbtype != rdb.TYPE_ZSET_2 {
		rdb.corrupt(r, "Unknown sorted set encoding")
		return nil
	}
	count := rdb.get_len(r)
	if count == rdb.LENERR {
		return nil
	}
	if count == 0 {
		r.status = .Empty_Key
		return nil
	}
	if count > u64(max(int) / size_of(^Node) / 4) {
		rdb.corrupt(r, "Invalid sorted set length")
		return nil
	}
	z := create_skiplist(int(count))
	maxlen, totlen := 0, 0
	for _ in 0 ..< count {
		member, good := rdb.get_string(r, 0)
		if !good {
			destroy(z)
			return nil
		}
		owned := mem_alloc(len(member))
		copy(owned[:len(member)], member)
		value: f64
		if rdbtype == rdb.TYPE_ZSET_2 {
			value, good = rdb.get_double_bin(r)
		} else {
			value, good = rdb.get_double_str(r)
		}
		if !good || is_nan(value) {
			mem_free(owned)
			destroy(z)
			if good {
				rdb.corrupt(r, "Zset with NAN score detected")
			}
			return nil
		}
		_, duplicate := score(z, owned[:len(member)])
		if duplicate {
			mem_free(owned)
			destroy(z)
			rdb.corrupt(r, "Duplicate zset fields detected")
			return nil
		}
		_, _, _ = add(z, value, owned[:len(member)], {})
		mem_free(owned)
		maxlen = max(maxlen, len(member))
		totlen += len(member)
	}
	convert_to_listpack_if_needed(z, maxlen, totlen)
	return z
}

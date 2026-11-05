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

packed_reason :: proc "contextless" (rdbtype: int) -> string {
	if rdbtype == rdb.TYPE_ZSET_ZIPLIST {
		return "Zset ziplist integrity check failed."
	}
	return "Zset listpack integrity check failed."
}

import_pack :: proc(blob: []u8, rdbtype: int, deep: bool) -> (pack: [^]u8, sound: bool) {
	if rdbtype == rdb.TYPE_ZSET_ZIPLIST {
		pack, sound = rdb.ziplist_to_listpack(blob, true)
		return pack, sound && rdb.lp_validate_dups(lp.lp_view(pack), true, 2)
	}
	if !rdb.lp_validate_dups(blob, deep, 2) {
		return nil, false
	}
	return rdb.lp_copy(blob), true
}

pack_members_sound :: proc(pack: [^]u8) -> bool {
	seen: rdb.Dup_Set
	defer rdb.dup_destroy(&seen)
	spelled: [lp.DECIMAL_BUFFER_BYTES]u8
	member := lp.lp_first(pack)
	for member != nil {
		weight := lp.lp_next(pack, member)
		if is_nan(zzl_score(weight)) || !rdb.dup_add(&seen, zzl_member(member, &spelled)) {
			return false
		}
		member = lp.lp_next(pack, weight)
	}
	return true
}

rdb_load_packed :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> Zset {
	blob, got := rdb.get_string(r, 0)
	if !got {
		return nil
	}
	pack, sound := import_pack(blob, rdbtype, deep)
	if !sound {
		lp.lp_free(pack)
		rdb.corrupt(r, packed_reason(rdbtype))
		return nil
	}
	members := zzl_length(pack)
	if members == 0 {
		lp.lp_free(pack)
		r.status = .Empty_Key
		return nil
	}
	z := cast(Zset)mem_alloc_zero(size_of(Zset_Object))
	z.encoding = .Listpack
	z.lp = pack
	if members <= zset_max_listpack_entries {
		return z
	}
	if !pack_members_sound(pack) {
		destroy(z)
		rdb.corrupt(r, packed_reason(rdbtype))
		return nil
	}
	convert_to_skiplist(z, members)
	return z
}

rdb_load_pairs :: proc(r: ^rdb.Reader, binary_scores: bool) -> Zset {
	count := rdb.get_len(r)
	switch {
	case !rdb.ok(r):
		return nil
	case count == 0:
		r.status = .Empty_Key
		return nil
	case count > u64(max(int) / size_of(^Node) / 4):
		rdb.corrupt(r, "Invalid sorted set length")
		return nil
	}
	z := create_skiplist(int(min(count, u64(4096))))
	widest, total := 0, 0
	for _ in 0 ..< count {
		member, got := rdb.get_string(r, 0)
		if !got {
			break
		}
		weight: f64
		if binary_scores {
			weight, got = rdb.get_double_bin(r)
		} else {
			weight, got = rdb.get_double_str(r)
		}
		if !got {
			break
		}
		if is_nan(weight) {
			rdb.corrupt(r, "Zset with NAN score detected")
			break
		}
		if _, taken := score(z, member); taken {
			rdb.corrupt(r, "Duplicate zset fields detected")
			break
		}
		_, _, _ = add(z, weight, member, {})
		widest = max(widest, len(member))
		total += len(member)
	}
	if !rdb.ok(r) {
		destroy(z)
		return nil
	}
	convert_to_listpack_if_needed(z, widest, total)
	return z
}

rdb_load :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> Zset {
	switch rdbtype {
	case rdb.TYPE_ZSET_LISTPACK, rdb.TYPE_ZSET_ZIPLIST:
		return rdb_load_packed(r, rdbtype, deep)
	case rdb.TYPE_ZSET, rdb.TYPE_ZSET_2:
		return rdb_load_pairs(r, rdbtype == rdb.TYPE_ZSET_2)
	}
	rdb.corrupt(r, "Unknown sorted set encoding")
	return nil
}

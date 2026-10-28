package listtype

import lp "../listpack"
import "../rdb"

rdb_type :: proc "contextless" (l: List) -> u8 {
	return rdb.TYPE_LIST_QUICKLIST_2
}

rdb_save :: proc "contextless" (w: ^rdb.Writer, l: List) {
	if l.encoding == .Listpack {
		rdb.put_len(w, 1)
		rdb.put_len(w, rdb.QUICKLIST_NODE_CONTAINER_PACKED)
		rdb.put_string(w, lp.lp_view(l.lp))
		return
	}
	rdb.put_len(w, u64(l.ql.len))
	for n := l.ql.head; n != nil; n = n.next {
		container := u64(rdb.QUICKLIST_NODE_CONTAINER_PACKED)
		if n.plain {
			container = rdb.QUICKLIST_NODE_CONTAINER_PLAIN
		}
		rdb.put_len(w, container)
		rdb.put_string(w, n.entry[:n.sz])
	}
}

rdb_fail :: proc(r: ^rdb.Reader, l: List, msg: string) -> List {
	destroy(l)
	if rdb.ok(r) && len(msg) > 0 {
		rdb.corrupt(r, msg)
	}
	return nil
}

rdb_load :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> List {
	if rdbtype != rdb.TYPE_LIST && rdbtype != rdb.TYPE_LIST_QUICKLIST && rdbtype != rdb.TYPE_LIST_QUICKLIST_2 && rdbtype != rdb.TYPE_LIST_ZIPLIST {
		return nil
	}
	l := create_quicklist()
	if rdbtype == rdb.TYPE_LIST_ZIPLIST {
		blob, ok := rdb.get_string(r, 0)
		if !ok {
			return rdb_fail(r, l, "")
		}
		if !rdb.ziplist_check_header(blob) {
			return rdb_fail(r, l, "List ziplist integrity check failed.")
		}
		it := rdb.ziplist_iter(blob)
		e: rdb.Zl_Entry
		buf: [24]u8
		for rdb.ziplist_next(&it, &e) {
			push(l, rdb.zl_entry_bytes(&e, &buf), .Tail)
		}
		if it.failed {
			return rdb_fail(r, l, "List ziplist integrity check failed.")
		}
	} else {
		n := rdb.get_len(r)
		if !rdb.ok(r) {
			return rdb_fail(r, l, "")
		}
		for i: u64 = 0; i < n; i += 1 {
			container := u64(rdb.QUICKLIST_NODE_CONTAINER_PACKED)
			if rdbtype == rdb.TYPE_LIST_QUICKLIST_2 {
				container = rdb.get_len(r)
				if !rdb.ok(r) {
					return rdb_fail(r, l, "")
				}
				if container != rdb.QUICKLIST_NODE_CONTAINER_PLAIN && container != rdb.QUICKLIST_NODE_CONTAINER_PACKED {
					return rdb_fail(r, l, "Quicklist integrity check failed.")
				}
			}
			blob, ok := rdb.get_string(r, 0)
			if !ok {
				return rdb_fail(r, l, "")
			}
			if rdbtype == rdb.TYPE_LIST {
				push(l, blob, .Tail)
				continue
			}
			if len(blob) == 0 {
				rdb.short_read(r)
				return rdb_fail(r, l, "")
			}
			if rdbtype == rdb.TYPE_LIST_QUICKLIST {
				pack, valid := rdb.ziplist_to_listpack(blob, false)
				if !valid {
					return rdb_fail(r, l, "Ziplist integrity check failed.")
				}
				append_listpack(l.ql, lp.lp_shrink_to_fit(pack))
			} else if container == rdb.QUICKLIST_NODE_CONTAINER_PLAIN {
				node := node_create_container(l.ql, true, blob)
				insert_node(l.ql, l.ql.tail, node, true)
			} else {
				if !lp.lp_validate_integrity(raw_data(blob), u64(len(blob)), deep, nil, nil) {
					return rdb_fail(r, l, "Listpack integrity check failed.")
				}
				append_listpack(l.ql, rdb.lp_copy(blob))
			}
		}
		try_conversion(l, .Auto)
	}
	if length(l) == 0 {
		destroy(l)
		r.status = .Empty_Key
		return nil
	}
	return l
}

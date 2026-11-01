package main

import zt "zsettype"

@(private)
bzpop_generic :: proc(c: ^Conn, keys: [][]u8, timeout: []u8, max_end: bool, count: i64, nested: bool) {
	pst.dirty_explicit = true
	deadline, ok := block_parse_timeout(c, timeout)
	if !ok {
		return
	}
	for key in keys {
		e, z, wrong := zset_lookup(key, false)
		if wrong {
			reply_wrongtype(c)
			return
		}
		if z != nil && zt.length(z) > 0 {
			_ = zpop_serve(c, key, e, z, max_end, true, count, nested)
			return
		}
	}
	if deny_blocking {
		reply_null_array(c)
		return
	}
	block_for_keys(c, .Zset, keys, deadline)
}

cmd_bzpopmin :: proc(c: ^Conn, argv: [][]u8) {
	last := len(argv) - 1
	bzpop_generic(c, argv[1:last], argv[last], false, -1, false)
}

cmd_bzpopmax :: proc(c: ^Conn, argv: [][]u8) {
	last := len(argv) - 1
	bzpop_generic(c, argv[1:last], argv[last], true, -1, false)
}

cmd_bzmpop :: proc(c: ^Conn, argv: [][]u8) {
	a, err := zt.parse_zmpop(argv, 2)
	if err != .None {
		reply_zset_error(c, err)
		return
	}
	bzpop_generic(c, argv[3:3 + a.numkeys], argv[1], a.max_end, a.count, true)
}

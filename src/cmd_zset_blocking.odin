package main

import zt "zsettype"

@(private = "file")
zset_block_pop :: proc(c: ^Conn, keys: [][]u8, timeout: []u8, order: Zpop_Order) {
	pst.dirty_explicit = true
	deadline, valid := block_parse_timeout(c, timeout)
	if !valid {
		return
	}
	key, e, z, probe := zpop_find_ready(keys)
	switch probe {
	case .Wrong:
		reply_wrongtype(c)
	case .Ready:
		zpop_emit(c, key, e, z, order)
	case .Empty:
		if deny_blocking {
			reply_null_array(c)
		} else {
			block_for_keys(c, .Zset, keys, deadline)
		}
	}
}

@(private = "file")
zset_block_pop_edge :: proc(c: ^Conn, argv: [][]u8, top: bool) {
	timeout_at := len(argv) - 1
	zset_block_pop(c, argv[1:timeout_at], argv[timeout_at], Zpop_Order{shape = .Keyed_Pair, top = top})
}

cmd_bzpopmin :: proc(c: ^Conn, argv: [][]u8) {
	zset_block_pop_edge(c, argv, false)
}

cmd_bzpopmax :: proc(c: ^Conn, argv: [][]u8) {
	zset_block_pop_edge(c, argv, true)
}

cmd_bzmpop :: proc(c: ^Conn, argv: [][]u8) {
	spec, refused := zt.parse_zmpop(argv, 2)
	if refused != .None {
		reply_zset_error(c, refused)
		return
	}
	zset_block_pop(c, argv[3:][:spec.numkeys], argv[1], Zpop_Order{shape = .Keyed_Run, top = spec.max_end, count = spec.count})
}

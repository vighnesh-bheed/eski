package main

import lt "listtype"

@(private)
blocking_pop_generic :: proc(c: ^Conn, keys: [][]u8, where_: lt.Where, timeout: []u8, count: int) {
	deadline, ok := block_parse_timeout(c, timeout)
	if !ok {
		return
	}
	for key in keys {
		e, l, wrong := list_lookup(key, false)
		if wrong {
			reply_wrongtype(c)
			return
		}
		if l != nil && lt.length(l) > 0 {
			list_pop_with_key(c, key, e, l, where_, count)
			return
		}
	}
	if deny_blocking {
		reply_null_array(c)
		return
	}
	block_for_keys(c, .List, keys, deadline)
}

cmd_blpop :: proc(c: ^Conn, argv: [][]u8) {
	last := len(argv) - 1
	blocking_pop_generic(c, argv[1:last], .Head, argv[last], -1)
}

cmd_brpop :: proc(c: ^Conn, argv: [][]u8) {
	last := len(argv) - 1
	blocking_pop_generic(c, argv[1:last], .Tail, argv[last], -1)
}

cmd_blmpop :: proc(c: ^Conn, argv: [][]u8) {
	a, err := lt.parse_mpop_args(argv, 2)
	if err != .None {
		reply_list_error(c, err)
		return
	}
	blocking_pop_generic(c, argv[3:3 + a.numkeys], a.where_, argv[1], a.count)
}

@(private)
blmove_generic :: proc(c: ^Conn, argv: [][]u8, wherefrom: lt.Where, whereto: lt.Where, timeout: []u8) {
	deadline, ok := block_parse_timeout(c, timeout)
	if !ok {
		return
	}
	_, src, wrong := list_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if src != nil && lt.length(src) > 0 {
		lmove_generic(c, argv, wherefrom, whereto)
		return
	}
	if deny_blocking {
		reply_null(c)
		return
	}
	block_for_keys(c, .List, argv[1:2], deadline)
}

cmd_blmove :: proc(c: ^Conn, argv: [][]u8) {
	from, err := lt.parse_direction(argv[3])
	if err != .None {
		reply_list_error(c, err)
		return
	}
	to, e2 := lt.parse_direction(argv[4])
	if e2 != .None {
		reply_list_error(c, e2)
		return
	}
	blmove_generic(c, argv, from, to, argv[5])
}

cmd_brpoplpush :: proc(c: ^Conn, argv: [][]u8) {
	blmove_generic(c, argv, .Tail, .Head, argv[3])
}

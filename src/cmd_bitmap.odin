package main

import bm "bitmap"

@(private = "file")
bitop_srcs: [dynamic][]u8

@(private = "file")
bitop_short: [dynamic]u8

@(private = "file")
BITOP_SHORT_MAX :: 16

@(private = "file")
bitfield_prog: bm.Bitfield_Program

@(private = "file")
bitmap_commands := [?]Command {
	{"setbit", cmd_setbit, 4},
	{"getbit", cmd_getbit, 3},
	{"bitcount", cmd_bitcount, -2},
	{"bitpos", cmd_bitpos, -3},
	{"bitop", cmd_bitop, -4},
	{"bitfield", cmd_bitfield, -2},
	{"bitfield_ro", cmd_bitfield_ro, -2},
}

@(cold)
reply_bitmap_error :: #force_no_inline proc(c: ^Conn, err: bm.Error) {
	reply_error_parts(c, "ERR ", bm.error_message(err))
}

@(private = "file")
BITMAP_STORE_LIMIT :: i64(max(u32)) - 2 * bm.GREEDY_GROWTH_LIMIT

@(private = "file")
bitmap_bulk_limit :: #force_inline proc() -> i64 {
	limit := string_max_len()
	if limit <= 0 {
		return bm.PROTO_MAX_BULK_LEN
	}
	return min(limit, BITMAP_STORE_LIMIT)
}

@(private = "file")
bitmap_lookup_read :: #force_inline proc(key: []u8) -> (e: ^Entry, wrong: bool) {
	e = db_find_read(key)
	if e != nil && entry_type(e) != .String {
		return e, true
	}
	return e, false
}

@(private = "file")
bitmap_lookup_write :: proc(key: []u8) -> (e: ^Entry, created: bool, wrong: bool) {
	e = db_find(key)
	if e != nil {
		return e, false, entry_type(e) != .String
	}
	e, created = db_upsert(key)
	return e, created, false
}

@(private = "file")
bitmap_unchanged :: #force_inline proc() {
	pst.dirty_explicit = true
}

@(private = "file")
bitmap_write_failed :: proc(c: ^Conn, key: []u8, created: bool, err: bm.Error) {
	if created {
		db_remove(key)
	}
	reply_bitmap_error(c, err)
}

cmd_setbit :: proc(c: ^Conn, argv: [][]u8) {
	limit := bitmap_bulk_limit()
	offset, err := bm.parse_bit_offset(argv[2], false, 0, limit)
	if err != .None {
		reply_bitmap_error(c, err)
		return
	}
	on: bool
	on, err = bm.parse_bit_value(argv[3])
	if err != .None {
		reply_bitmap_error(c, err)
		return
	}
	key := argv[1]
	e, created, wrong := bitmap_lookup_write(key)
	if wrong {
		reply_wrongtype(c)
		return
	}
	entry_heap_open(e, false)
	buf := e.val
	before := len(buf)
	capacity := int(e.cap)
	old: bool
	old, err = bm.setbit(&buf, i64(offset), on, bm.RAW_HEAP_ALLOCATOR, &capacity, limit)
	e.val = buf
	e.cap = u32(capacity)
	entry_heap_close(e)
	if err != .None {
		bitmap_write_failed(c, key, created, err)
		return
	}
	if created || len(buf) > before || old != on {
		signal_key(key)
		notify(.String, "setbit", key)
	} else {
		bitmap_unchanged()
	}
	reply_int(c, i64(old))
}

cmd_getbit :: proc(c: ^Conn, argv: [][]u8) {
	offset, err := bm.parse_bit_offset(argv[2], false, 0, bitmap_bulk_limit())
	if err != .None {
		reply_bitmap_error(c, err)
		return
	}
	e, wrong := bitmap_lookup_read(argv[1])
	if wrong {
		reply_wrongtype(c)
		return
	}
	if e == nil {
		reply_int(c, 0)
		return
	}
	reply_int(c, i64(bm.getbit(e.val, i64(offset))))
}

cmd_bitcount :: proc(c: ^Conn, argv: [][]u8) {
	args, err := bm.parse_bitcount_args(argv[2:])
	if err != .None {
		reply_bitmap_error(c, err)
		return
	}
	e, wrong := bitmap_lookup_read(argv[1])
	if wrong {
		reply_wrongtype(c)
		return
	}
	if e == nil {
		reply_int(c, 0)
		return
	}
	reply_int(c, bm.bitcount_args(e.val, args))
}

cmd_bitpos :: proc(c: ^Conn, argv: [][]u8) {
	args, err := bm.parse_bitpos_args(argv[2:])
	if err != .None {
		reply_bitmap_error(c, err)
		return
	}
	e, wrong := bitmap_lookup_read(argv[1])
	if wrong {
		reply_wrongtype(c)
		return
	}
	if e == nil {
		reply_int(c, bm.bitpos_args(nil, false, args))
		return
	}
	reply_int(c, bm.bitpos_args(e.val, true, args))
}

cmd_bitop :: proc(c: ^Conn, argv: [][]u8) {
	op, err := bm.parse_bitop(argv[1])
	if err != .None {
		reply_bitmap_error(c, err)
		return
	}
	sources := argv[3:]
	err = bm.check_bitop_arity(op, len(sources))
	if err != .None {
		reply_bitmap_error(c, err)
		return
	}
	clear(&bitop_srcs)
	clear(&bitop_short)
	reserve(&bitop_short, len(sources) * BITOP_SHORT_MAX)
	for key in sources {
		e, wrong := bitmap_lookup_read(key)
		if wrong {
			clear(&bitop_srcs)
			reply_wrongtype(c)
			return
		}
		switch {
		case e == nil:
			append(&bitop_srcs, nil)
		case len(e.val) <= BITOP_SHORT_MAX:
			at := len(bitop_short)
			append(&bitop_short, ..e.val)
			append(&bitop_srcs, bitop_short[at:])
		case:
			append(&bitop_srcs, e.val)
		}
	}
	out: []u8
	length: int
	length, err = bm.bitop(op, bitop_srcs[:], &out, bm.RAW_HEAP_ALLOCATOR)
	clear(&bitop_srcs)
	if err != .None {
		reply_bitmap_error(c, err)
		return
	}
	dest := argv[2]
	if length == 0 {
		removed, _ := db_remove(dest)
		if removed {
			signal_key(dest)
			notify(.Generic, "del", dest)
		} else {
			bitmap_unchanged()
		}
		reply_int(c, 0)
		return
	}
	e, _ := db_upsert(dest)
	entry_heap_adopt(e, out, length)
	entry_set_expire(e, 0)
	signal_key(dest)
	notify(.String, "set", dest)
	reply_int(c, i64(length))
}

@(private = "file")
reply_bitfield :: proc(c: ^Conn, prog: ^bm.Bitfield_Program) {
	reply_array(c, len(prog.replies))
	for r in prog.replies {
		if r.null {
			reply_null(c)
		} else {
			reply_int(c, r.value)
		}
	}
}

@(private = "file")
bitfield_generic :: proc(c: ^Conn, argv: [][]u8, read_only_command: bool) {
	pst.dirty_explicit = true
	limit := bitmap_bulk_limit()
	err := bm.bitfield_parse(&bitfield_prog, argv[2:], read_only_command, limit)
	if err != .None {
		reply_bitmap_error(c, err)
		return
	}
	key := argv[1]
	if bitfield_prog.readonly {
		e, wrong := bitmap_lookup_read(key)
		if wrong {
			reply_wrongtype(c)
			return
		}
		view: []u8
		if e != nil {
			view = e.val
		}
		_, err = bm.bitfield_execute(&view, &bitfield_prog)
		if err != .None {
			reply_bitmap_error(c, err)
			return
		}
		if !read_only_command {
			bitmap_unchanged()
		}
		reply_bitfield(c, &bitfield_prog)
		return
	}
	e, created, wrong := bitmap_lookup_write(key)
	if wrong {
		reply_wrongtype(c)
		return
	}
	entry_heap_open(e, false)
	buf := e.val
	capacity := int(e.cap)
	changes: int
	changes, err = bm.bitfield_execute(&buf, &bitfield_prog, bm.RAW_HEAP_ALLOCATOR, &capacity)
	e.val = buf
	e.cap = u32(capacity)
	entry_heap_close(e)
	if err != .None {
		bitmap_write_failed(c, key, created, err)
		return
	}
	pst.dirty += i64(changes)
	if changes > 0 {
		signal_key(key)
		notify(.String, "setbit", key)
	} else {
		bitmap_unchanged()
	}
	reply_bitfield(c, &bitfield_prog)
}

cmd_bitfield :: proc(c: ^Conn, argv: [][]u8) {
	bitfield_generic(c, argv, false)
}

cmd_bitfield_ro :: proc(c: ^Conn, argv: [][]u8) {
	bitfield_generic(c, argv, true)
}

@(init)
register_bitmap_commands :: proc "contextless" () {
	register_commands(bitmap_commands[:])
}

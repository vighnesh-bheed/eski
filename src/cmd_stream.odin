package main

import "base:intrinsics"
import st "streamtype"

@(private)
stream_ids: [dynamic]st.ID

@(private)
stream_ids2: [dynamic]st.ID

@(private)
stream_groups: [dynamic]^st.CG

@(private = "file")
stream_reads: [dynamic]st.Stream

@(private = "file")
stream_errbuf: [dynamic]u8

stream_object_release :: proc "contextless" (obj: rawptr) -> int {
	s := st.Stream(obj)
	if s == nil {
		return 0
	}
	n := s.acct
	st.destroy(s)
	return n
}

stream_object_acct :: proc "contextless" (obj: rawptr) -> int {
	s := st.Stream(obj)
	if s == nil {
		return 0
	}
	return s.acct
}

stream_memory :: proc "contextless" (obj: rawptr) -> int {
	if obj == nil {
		return 0
	}
	return st.memory_usage(st.Stream(obj))
}

@(private)
stream_sync :: #force_inline proc "contextless" (db: ^Db, s: st.Stream) {
	n := st.memory_usage(s)
	object_account(db, n - s.acct)
	s.acct = n
}

@(private)
stream_lookup :: #force_inline proc(key: []u8, read: bool) -> (e: ^Entry, s: st.Stream, wrong: bool) {
	e = db_find(key)
	if read {
		if e == nil {
			srv.stat_misses += 1
			notify(.Key_Miss, "keymiss", key)
			return
		}
		srv.stat_hits += 1
	}
	if e == nil {
		return
	}
	if entry_type(e) != .Stream {
		wrong = true
		return
	}
	s = st.Stream(entry_object(e, .Stream))
	return
}

@(private)
stream_create :: proc(key: []u8) -> (e: ^Entry, s: st.Stream) {
	e, _ = db_upsert(key)
	s = st.create()
	s.acct = st.memory_usage(s)
	entry_object_attach(e, s, .Stream, .Stream, s.acct)
	return
}

stream_copy_dup :: proc(src: ^Entry) -> (obj: rawptr, extra: u64, ok: bool) {
	if entry_type(src) != .Stream {
		return nil, 0, false
	}
	s := st.dup(st.Stream(entry_object(src, .Stream)))
	return s, 0, true
}

stream_copy_attach :: proc(dst: ^Entry, obj: rawptr) {
	s := st.Stream(obj)
	s.acct = st.memory_usage(s)
	entry_object_attach(dst, s, .Stream, .Stream, s.acct)
}

@(private)
reply_stream_error :: proc(c: ^Conn, err: st.Error) {
	msg := st.error_message(err)
	if st.error_has_prefix(err) {
		reply_error(c, msg)
	} else {
		reply_error_parts(c, "ERR ", msg)
	}
}

@(private)
reply_error_fmt :: proc(c: ^Conn, parts: ..[]u8) {
	clear(&stream_errbuf)
	for p in parts {
		for b in p {
			append(&stream_errbuf, (b == '\r' || b == '\n') ? ' ' : b)
		}
	}
	reply_error_bytes(c, stream_errbuf[:])
}

@(private)
defer_mark :: #force_inline proc "contextless" (c: ^Conn) -> int {
	return c.wlen
}

@(private)
defer_len :: proc(c: ^Conn, mark: int, prefix: u8, n: int) #no_bounds_check {
	before := c.wlen
	if prefix == '%' {
		reply_map(c, n)
	} else {
		reply_array(c, n)
	}
	hlen := c.wlen - before
	if hlen <= 0 || mark < 0 || mark > before {
		return
	}
	body := before - mark
	if body == 0 {
		return
	}
	header: [32]u8
	if hlen > len(header) {
		return
	}
	intrinsics.mem_copy_non_overlapping(&header[0], &c.wbuf[before], hlen)
	intrinsics.mem_copy(&c.wbuf[mark + hlen], &c.wbuf[mark], body)
	intrinsics.mem_copy_non_overlapping(&c.wbuf[mark], &header[0], hlen)
}

@(private)
reply_stream_id :: proc(c: ^Conn, id: st.ID) {
	buf: [st.ID_STR_LEN]u8
	reply_bulk(c, st.format_id(&buf, id))
}

@(private)
stream_reply_range :: proc(c: ^Conn, s: st.Stream, start: ^st.ID, end: ^st.ID, count: int, rev: bool, raw: bool, cg: ^st.CG = nil, consumer: ^st.Consumer = nil, noack := false) -> int {
	mark := 0
	if !raw {
		mark = defer_mark(c)
	}
	si: st.Iterator
	st.iterator_start(&si, s, start, end, rev)
	emitted := 0
	id: st.ID
	numfields: i64
	now := srv.now_ms
	for (count <= 0 || emitted < count) && st.iterator_get_id(&si, &id, &numfields) {
		reply_array(c, 2)
		reply_stream_id(c, id)
		reply_array(c, int(numfields) * 2)
		for _ in 0 ..< numfields {
			field, value := st.iterator_get_field(&si)
			reply_bulk(c, field)
			reply_bulk(c, value)
		}
		if cg != nil {
			st.group_deliver(s, cg, consumer, id, noack, now)
		}
		emitted += 1
	}
	st.iterator_stop(&si)
	if !raw {
		defer_len(c, mark, '*', emitted)
	}
	return emitted
}

cmd_xadd :: proc(c: ^Conn, argv: [][]u8) {
	args, idpos, err := st.parse_add_trim_args(argv, true)
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	key := argv[1]
	e, s, wrong := stream_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	created := false
	if s == nil {
		if args.no_mkstream {
			pst.dirty_explicit = true
			reply_null(c)
			return
		}
		e, s = stream_create(key)
		created = true
	}
	id, aerr := st.xadd_apply(s, &args, argv[idpos + 1:], u64(srv.now_ms))
	if aerr != .None {
		if created {
			db_remove(key)
		}
		reply_stream_error(c, aerr)
		return
	}
	reply_stream_id(c, id)
	signal_key(key)
	notify(.Stream, "xadd", key)
	if args.trim_strategy != .None {
		if st.trim(s, &args) > 0 {
			notify(.Stream, "xtrim", key)
		}
	}
	stream_sync(e.db, s)
	block_signal_key(e.db, key, .Stream)
}

@(private = "file")
xrange_generic :: proc(c: ^Conn, argv: [][]u8, rev: bool) {
	start, end, count, err := st.parse_range_args(argv, rev)
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	_, s, wrong := stream_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_array(c, 0)
		return
	}
	if count == 0 {
		reply_null_array(c)
		return
	}
	limit := 0
	if count > 0 {
		limit = int(min(count, i64(max(int))))
	}
	stream_reply_range(c, s, &start, &end, limit, rev, false)
}

cmd_xrange :: proc(c: ^Conn, argv: [][]u8) {
	xrange_generic(c, argv, false)
}

cmd_xrevrange :: proc(c: ^Conn, argv: [][]u8) {
	xrange_generic(c, argv, true)
}

cmd_xlen :: proc(c: ^Conn, argv: [][]u8) {
	_, s, wrong := stream_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_int(c, i64(st.length(s)))
}

cmd_xdel :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	key := argv[1]
	e, s, wrong := stream_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		pst.dirty_explicit = true
		reply_int(c, 0)
		return
	}
	clear(&stream_ids)
	for a in argv[2:] {
		id, ok := st.parse_strict_id(a)
		if !ok {
			reply_stream_error(c, .Invalid_ID)
			return
		}
		append(&stream_ids, id)
	}
	deleted := st.xdel_apply(s, stream_ids[:])
	pst.dirty += i64(deleted)
	stream_sync(e.db, s)
	if deleted > 0 {
		signal_key(key)
		notify(.Stream, "xdel", key)
	} else {
		pst.dirty_explicit = true
	}
	reply_int(c, i64(deleted))
}

cmd_xtrim :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	args, _, err := st.parse_add_trim_args(argv, false)
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	key := argv[1]
	e, s, wrong := stream_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		pst.dirty_explicit = true
		reply_int(c, 0)
		return
	}
	removed := st.trim(s, &args)
	pst.dirty += removed
	stream_sync(e.db, s)
	if removed > 0 {
		signal_key(key)
		notify(.Stream, "xtrim", key)
	} else {
		pst.dirty_explicit = true
	}
	reply_int(c, removed)
}

cmd_xsetid :: proc(c: ^Conn, argv: [][]u8) {
	a, err := st.parse_xsetid_args(argv)
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	key := argv[1]
	e, s, wrong := stream_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_stream_error(c, .No_Such_Key)
		return
	}
	if aerr := st.xsetid_apply(s, &a); aerr != .None {
		reply_stream_error(c, aerr)
		return
	}
	stream_sync(e.db, s)
	signal_key(key)
	notify(.Stream, "xsetid", key)
	reply_ok(c)
}

@(private = "file")
xinfo_help := [?]string {
	"XINFO <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"CONSUMERS <key> <groupname>",
	"    Show consumers of <groupname>.",
	"GROUPS <key>",
	"    Show the stream consumer groups.",
	"STREAM <key> [FULL [COUNT <count>]",
	"    Show information about the stream.",
	"HELP",
	"    Print this help.",
}

@(private = "file")
reply_edge_entry :: proc(c: ^Conn, s: st.Stream, last: bool) {
	if s.length == 0 || stream_reply_range(c, s, nil, nil, 1, last, true) == 0 {
		reply_null(c)
	}
}

@(private)
xinfo_stream :: proc(c: ^Conn, argv: [][]u8, s: st.Stream) {
	full, count, err := st.parse_xinfo_stream_opts(argv[3:])
	if err == .Subcommand_Syntax {
		reply_subcommand_syntax_error(c, argv[1], "XINFO")
		return
	}
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	reply_map(c, full ? 9 : 10)
	reply_bulk_str(c, "length")
	reply_int(c, i64(s.length))
	reply_bulk_str(c, "radix-tree-keys")
	reply_int(c, i64(st.node_count(s)))
	reply_bulk_str(c, "radix-tree-nodes")
	reply_int(c, i64(st.rax_nodes(s)))
	reply_bulk_str(c, "last-generated-id")
	reply_stream_id(c, s.last_id)
	reply_bulk_str(c, "max-deleted-entry-id")
	reply_stream_id(c, s.max_deleted_entry_id)
	reply_bulk_str(c, "entries-added")
	reply_int(c, i64(s.entries_added))
	reply_bulk_str(c, "recorded-first-entry-id")
	reply_stream_id(c, s.first_id)
	if !full {
		reply_bulk_str(c, "groups")
		reply_int(c, i64(st.group_count(s)))
		reply_bulk_str(c, "first-entry")
		reply_edge_entry(c, s, false)
		reply_bulk_str(c, "last-entry")
		reply_edge_entry(c, s, true)
		return
	}
	reply_bulk_str(c, "entries")
	limit := 0
	if count > 0 {
		limit = int(min(count, i64(max(int))))
	}
	stream_reply_range(c, s, nil, nil, limit, false, false)
	reply_bulk_str(c, "groups")
	xinfo_full_groups(c, s, count)
}

cmd_xinfo :: proc(c: ^Conn, argv: [][]u8) {
	sub := argv[1]
	n := len(argv)
	switch {
	case eq_nocase(sub, "help"):
		if n != 2 {
			reply_wrong_args(c, "xinfo|help")
			return
		}
		reply_array(c, len(xinfo_help))
		for line in xinfo_help {
			reply_simple(c, line)
		}
		return
	case eq_nocase(sub, "stream"):
		if n < 3 {
			reply_wrong_args(c, "xinfo|stream")
			return
		}
	case eq_nocase(sub, "groups"):
		if n != 3 {
			reply_wrong_args(c, "xinfo|groups")
			return
		}
	case eq_nocase(sub, "consumers"):
		if n != 4 {
			reply_wrong_args(c, "xinfo|consumers")
			return
		}
	case:
		reply_unknown_subcommand(c, sub, "XINFO")
		return
	}
	_, s, wrong := stream_lookup(argv[2], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_stream_error(c, .No_Such_Key)
		return
	}
	switch {
	case eq_nocase(sub, "stream"):
		xinfo_stream(c, argv, s)
	case eq_nocase(sub, "groups"):
		xinfo_groups(c, s)
	case:
		xinfo_consumers(c, argv, s)
	}
}

cmd_xread :: proc(c: ^Conn, argv: [][]u8) {
	a, err := st.parse_xread_args(argv, srv.now_ms, false)
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	nkeys := a.streams_count
	reexec := block_in_reexecution() && c.bstate != nil && len(c.bstate.stream_ids) == nkeys
	clear(&stream_ids)
	resize(&stream_ids, nkeys)
	clear(&stream_reads)
	resize(&stream_reads, nkeys)
	for i in 0 ..< nkeys {
		key := argv[a.streams_arg + i]
		arg := argv[a.streams_arg + nkeys + i]
		_, s, wrong := stream_lookup(key, true)
		if wrong {
			reply_wrongtype(c)
			return
		}
		stream_reads[i] = s
		id: st.ID
		switch {
		case st.is_byte(arg, '$'):
			if reexec {
				pair := c.bstate.stream_ids[i]
				id = st.ID{pair[0], pair[1]}
			} else if s != nil {
				id = s.last_id
			}
		case st.is_byte(arg, '+'):
			if s != nil && s.length > 0 {
				id = st.last_valid_id(s)
				st.decr_id(&id)
			}
		case st.is_byte(arg, '>'):
			reply_stream_error(c, .Gt_Id)
			return
		case:
			ok: bool
			id, ok = st.parse_strict_id(arg)
			if !ok {
				reply_stream_error(c, .Invalid_ID)
				return
			}
		}
		stream_ids[i] = id
	}
	served := 0
	for i in 0 ..< nkeys {
		_, s, _ := stream_lookup(argv[a.streams_arg + i], true)
		stream_reads[i] = s
		if s != nil && s.length > 0 && st.compare_id(st.last_valid_id(s), stream_ids[i]) > 0 {
			served += 1
		} else {
			stream_reads[i] = nil
		}
	}
	if served > 0 {
		if c.resp == RESP2 {
			reply_array(c, served)
		} else {
			reply_map(c, served)
		}
		for i in 0 ..< nkeys {
			s := stream_reads[i]
			if s == nil {
				continue
			}
			if c.resp == RESP2 {
				reply_array(c, 2)
			}
			reply_bulk(c, argv[a.streams_arg + i])
			start := stream_ids[i]
			st.incr_id(&start)
			stream_reply_range(c, s, &start, nil, int(a.count), false, false)
		}
		return
	}
	if a.timeout != -1 && !deny_blocking {
		if c.bstate == nil {
			c.bstate = new(Block_State)
		}
		if !reexec {
			clear(&c.bstate.stream_ids)
			for id in stream_ids {
				append(&c.bstate.stream_ids, [2]u64{id.ms, id.seq})
			}
		}
		block_for_keys(c, .Stream, argv[a.streams_arg:a.streams_arg + nkeys], a.timeout, false)
		return
	}
	reply_null_array(c)
}

@(private = "file")
stream_commands := [?]Command {
	{"xadd", cmd_xadd, -5},
	{"xrange", cmd_xrange, -4},
	{"xrevrange", cmd_xrevrange, -4},
	{"xlen", cmd_xlen, 2},
	{"xdel", cmd_xdel, -3},
	{"xtrim", cmd_xtrim, -4},
	{"xsetid", cmd_xsetid, -3},
	{"xinfo", cmd_xinfo, -2},
	{"xread", cmd_xread, -4},
	{"xreadgroup", cmd_xreadgroup, -7},
	{"xgroup", cmd_xgroup, -2},
	{"xack", cmd_xack, -4},
	{"xpending", cmd_xpending, -3},
	{"xclaim", cmd_xclaim, -6},
	{"xautoclaim", cmd_xautoclaim, -6},
}

@(init)
register_stream_commands :: proc "contextless" () {
	register_commands(stream_commands[:])
}

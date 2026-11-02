package main

import "base:intrinsics"
import st "streamtype"

@(private)
stream_ids: [dynamic]st.ID

@(private)
stream_ids2: [dynamic]st.ID

@(private)
stream_groups: [dynamic]^st.Group

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
	buf: [st.ID_TEXT_MAX]u8
	reply_bulk(c, st.format_id(&buf, id))
}

Stream_Delivery :: struct {
	group:    ^st.Group,
	consumer: ^st.Member,
	noack:    bool,
}

@(private)
stream_emit_entries :: proc(c: ^Conn, s: st.Stream, from: ^st.ID, to: ^st.ID, limit: int, backwards: bool, delivery: ^Stream_Delivery = nil) -> (sent: int) {
	walk: st.Cursor
	st.cursor_open(&walk, s, from, to, backwards)
	defer st.cursor_close(&walk)
	stamp := srv.now_ms
	for limit <= 0 || sent < limit {
		id, pairs, more := st.cursor_next(&walk)
		if !more {
			break
		}
		reply_array(c, 2)
		reply_stream_id(c, id)
		reply_array(c, int(pairs) * 2)
		for _ in 0 ..< pairs {
			field, value := st.cursor_field(&walk)
			reply_bulk(c, field)
			reply_bulk(c, value)
		}
		if delivery != nil {
			st.group_deliver(s, delivery.group, delivery.consumer, id, delivery.noack, stamp)
		}
		sent += 1
	}
	return
}

@(private)
stream_reply_entries :: proc(c: ^Conn, s: st.Stream, from: ^st.ID, to: ^st.ID, limit: int, backwards: bool, delivery: ^Stream_Delivery = nil) -> int {
	mark := defer_mark(c)
	sent := stream_emit_entries(c, s, from, to, limit, backwards, delivery)
	defer_len(c, mark, '*', sent)
	return sent
}

@(private)
stream_emit_entry_at :: proc(c: ^Conn, s: st.Stream, id: st.ID) -> bool {
	at := id
	return stream_emit_entries(c, s, &at, &at, 1, false) == 1
}

cmd_xadd :: proc(c: ^Conn, argv: [][]u8) {
	spec, err := st.parse_xadd(argv)
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
		if spec.nomkstream {
			pst.dirty_explicit = true
			reply_null(c)
			return
		}
		e, s = stream_create(key)
		created = true
	}
	id, aerr := st.xadd_apply(s, &spec, argv[spec.fields_at:], u64(srv.now_ms))
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
	if spec.trim.rule != .Off {
		if st.trim(s, &spec.trim) > 0 {
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
	stream_reply_entries(c, s, &start, &end, limit, rev)
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
		id, ok := st.parse_exact_id(a)
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
	limits, err := st.parse_xtrim(argv)
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
	removed := st.trim(s, &limits)
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
	if s.live == 0 || stream_emit_entries(c, s, nil, nil, 1, last) == 0 {
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
	reply_int(c, i64(s.live))
	reply_bulk_str(c, "radix-tree-keys")
	reply_int(c, i64(st.node_count(s)))
	reply_bulk_str(c, "radix-tree-nodes")
	reply_int(c, i64(st.rax_nodes(s)))
	reply_bulk_str(c, "last-generated-id")
	reply_stream_id(c, s.top)
	reply_bulk_str(c, "max-deleted-entry-id")
	reply_stream_id(c, s.tomb)
	reply_bulk_str(c, "entries-added")
	reply_int(c, i64(s.added))
	reply_bulk_str(c, "recorded-first-entry-id")
	reply_stream_id(c, s.head)
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
	stream_reply_entries(c, s, nil, nil, limit, false)
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

@(private = "file")
xread_starting_points :: proc(c: ^Conn, keys: [][]u8, marks: [][]u8, replay: bool) -> bool {
	clear(&stream_ids)
	for key, n in keys {
		_, s, wrong := stream_lookup(key, true)
		if wrong {
			reply_wrongtype(c)
			return false
		}
		mark := marks[n]
		at: st.ID
		switch {
		case st.is_byte(mark, '$') && replay:
			saved := c.bstate.stream_ids[n]
			at = st.ID{saved[0], saved[1]}
		case st.is_byte(mark, '$'):
			if s != nil {
				at = s.top
			}
		case st.is_byte(mark, '+'):
			if s != nil && s.live > 0 {
				at = st.last_valid_id(s)
				st.decr_id(&at)
			}
		case st.is_byte(mark, '>'):
			reply_stream_error(c, .Gt_Id)
			return false
		case:
			explicit, valid := st.parse_exact_id(mark)
			if !valid {
				reply_stream_error(c, .Invalid_ID)
				return false
			}
			at = explicit
		}
		append(&stream_ids, at)
	}
	return true
}

@(private = "file")
xread_collect_ready :: proc(keys: [][]u8) -> (ready: int) {
	clear(&stream_reads)
	for key, n in keys {
		_, s, _ := stream_lookup(key, true)
		if s != nil && (s.live == 0 || st.compare_id(st.last_valid_id(s), stream_ids[n]) <= 0) {
			s = nil
		}
		if s != nil {
			ready += 1
		}
		append(&stream_reads, s)
	}
	return
}

@(private = "file")
xread_reply_ready :: proc(c: ^Conn, keys: [][]u8, ready: int, limit: int) {
	flat := c.resp == RESP2
	if flat {
		reply_array(c, ready)
	} else {
		reply_map(c, ready)
	}
	for s, n in stream_reads {
		if s == nil {
			continue
		}
		if flat {
			reply_array(c, 2)
		}
		reply_bulk(c, keys[n])
		after := stream_ids[n]
		st.incr_id(&after)
		stream_reply_entries(c, s, &after, nil, limit, false)
	}
}

@(private = "file")
xread_park :: proc(c: ^Conn, keys: [][]u8, timeout: i64, replay: bool) {
	if c.bstate == nil {
		c.bstate = new(Block_State)
	}
	if !replay {
		clear(&c.bstate.stream_ids)
		for at in stream_ids {
			append(&c.bstate.stream_ids, [2]u64{at.ms, at.seq})
		}
	}
	block_for_keys(c, .Stream, keys, timeout, false)
}

cmd_xread :: proc(c: ^Conn, argv: [][]u8) {
	spec, refused := st.parse_xread_args(argv, srv.now_ms, false)
	if refused != .None {
		reply_stream_error(c, refused)
		return
	}
	keys := argv[spec.keys_at:][:spec.key_count]
	marks := argv[spec.keys_at + spec.key_count:][:spec.key_count]
	replay := block_in_reexecution() && c.bstate != nil && len(c.bstate.stream_ids) == spec.key_count
	if !xread_starting_points(c, keys, marks, replay) {
		return
	}
	if ready := xread_collect_ready(keys); ready > 0 {
		xread_reply_ready(c, keys, ready, int(spec.count))
	} else if spec.timeout != -1 && !deny_blocking {
		xread_park(c, keys, spec.timeout, replay)
	} else {
		reply_null_array(c)
	}
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

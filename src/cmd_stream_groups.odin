package main

import rx "rax"
import st "streamtype"

@(private = "file")
group_errbuf: [dynamic]u8

@(private = "file")
group_steps: [dynamic]st.Autoclaim_Step

@(private = "file")
group_consumers: [dynamic]^st.Consumer

@(private = "file")
group_history: [dynamic]bool

@(private = "file")
group_entries: [dynamic]^Entry

@(private = "file")
group_streams: [dynamic]st.Stream

@(private = "file")
group_changes :: proc "contextless" (n: int) {
	pst.dirty_explicit = true
	pst.dirty += i64(n)
}

@(private = "file")
reply_nogroup :: proc(c: ^Conn, form: st.Nogroup_Form, key: []u8, group: []u8) {
	clear(&group_errbuf)
	st.append_nogroup_error(&group_errbuf, form, key, group)
	reply_error_fmt(c, group_errbuf[:])
}

@(private = "file")
reply_entries_read :: proc(c: ^Conn, cg: ^st.CG) {
	if cg.entries_read == st.SCG_INVALID_ENTRIES_READ {
		reply_null(c)
	} else {
		reply_int(c, cg.entries_read)
	}
}

@(private = "file")
reply_lag :: proc(c: ^Conn, s: st.Stream, cg: ^st.CG) {
	lag, valid := st.cg_lag(s, cg)
	if valid {
		reply_int(c, lag)
	} else {
		reply_null(c)
	}
}

@(private = "file")
pel_limit :: #force_inline proc "contextless" (r: ^rx.Rax, count: i64) -> int {
	n := int(r.numele)
	if count > 0 && count < i64(n) {
		return int(count)
	}
	return n
}

@(private = "file")
consumer_create_noted :: proc(s: st.Stream, cg: ^st.CG, name: []u8, key: []u8) -> (consumer: ^st.Consumer, created: bool) {
	consumer, created = st.lookup_or_create_consumer(s, cg, name, srv.now_ms)
	if created {
		notify(.Stream, "xgroup-createconsumer", key)
	}
	return
}

xinfo_groups :: proc(c: ^Conn, s: st.Stream) {
	reply_array(c, int(st.group_count(s)))
	if s.cgroups == nil {
		return
	}
	it: rx.Iterator
	rx.start(&it, s.cgroups)
	rx.seek(&it, "^")
	for rx.next(&it) {
		cg := (^st.CG)(it.data)
		reply_map(c, 6)
		reply_bulk_str(c, "name")
		reply_bulk(c, rx.key(&it))
		reply_bulk_str(c, "consumers")
		reply_int(c, i64(cg.consumers.numele))
		reply_bulk_str(c, "pending")
		reply_int(c, i64(cg.pel.numele))
		reply_bulk_str(c, "last-delivered-id")
		reply_stream_id(c, cg.last_id)
		reply_bulk_str(c, "entries-read")
		reply_entries_read(c, cg)
		reply_bulk_str(c, "lag")
		reply_lag(c, s, cg)
	}
	rx.stop(&it)
}

xinfo_consumers :: proc(c: ^Conn, argv: [][]u8, s: st.Stream) {
	cg := st.lookup_cg(s, argv[3])
	if cg == nil {
		reply_nogroup(c, .For_Key_Name, argv[2], argv[3])
		return
	}
	now := srv.now_ms
	reply_array(c, int(cg.consumers.numele))
	it: rx.Iterator
	rx.start(&it, cg.consumers)
	rx.seek(&it, "^")
	for rx.next(&it) {
		consumer := (^st.Consumer)(it.data)
		reply_map(c, 4)
		reply_bulk_str(c, "name")
		reply_bulk(c, consumer.name)
		reply_bulk_str(c, "pending")
		reply_int(c, i64(consumer.pel.numele))
		reply_bulk_str(c, "idle")
		reply_int(c, now - consumer.seen_time)
		reply_bulk_str(c, "inactive")
		if consumer.active_time == -1 {
			reply_int(c, -1)
		} else {
			reply_int(c, now - consumer.active_time)
		}
	}
	rx.stop(&it)
}

xinfo_full_groups :: proc(c: ^Conn, s: st.Stream, count: i64) {
	reply_array(c, int(st.group_count(s)))
	if s.cgroups == nil {
		return
	}
	gi: rx.Iterator
	rx.start(&gi, s.cgroups)
	rx.seek(&gi, "^")
	for rx.next(&gi) {
		cg := (^st.CG)(gi.data)
		reply_map(c, 7)
		reply_bulk_str(c, "name")
		reply_bulk(c, rx.key(&gi))
		reply_bulk_str(c, "last-delivered-id")
		reply_stream_id(c, cg.last_id)
		reply_bulk_str(c, "entries-read")
		reply_entries_read(c, cg)
		reply_bulk_str(c, "lag")
		reply_lag(c, s, cg)
		reply_bulk_str(c, "pel-count")
		reply_int(c, i64(cg.pel.numele))
		reply_bulk_str(c, "pending")
		limit := pel_limit(cg.pel, count)
		reply_array(c, limit)
		pi: rx.Iterator
		rx.start(&pi, cg.pel)
		rx.seek(&pi, "^")
		for n := 0; n < limit && rx.next(&pi); n += 1 {
			nack := (^st.NACK)(pi.data)
			reply_array(c, 4)
			reply_stream_id(c, st.decode_id(rx.key(&pi)))
			reply_bulk(c, nack.consumer.name)
			reply_int(c, nack.delivery_time)
			reply_int(c, i64(nack.delivery_count))
		}
		rx.stop(&pi)
		reply_bulk_str(c, "consumers")
		reply_array(c, int(cg.consumers.numele))
		ci: rx.Iterator
		rx.start(&ci, cg.consumers)
		rx.seek(&ci, "^")
		for rx.next(&ci) {
			consumer := (^st.Consumer)(ci.data)
			reply_map(c, 5)
			reply_bulk_str(c, "name")
			reply_bulk(c, consumer.name)
			reply_bulk_str(c, "seen-time")
			reply_int(c, consumer.seen_time)
			reply_bulk_str(c, "active-time")
			reply_int(c, consumer.active_time)
			reply_bulk_str(c, "pel-count")
			reply_int(c, i64(consumer.pel.numele))
			reply_bulk_str(c, "pending")
			climit := pel_limit(consumer.pel, count)
			reply_array(c, climit)
			ki: rx.Iterator
			rx.start(&ki, consumer.pel)
			rx.seek(&ki, "^")
			for n := 0; n < climit && rx.next(&ki); n += 1 {
				nack := (^st.NACK)(ki.data)
				reply_array(c, 3)
				reply_stream_id(c, st.decode_id(rx.key(&ki)))
				reply_int(c, nack.delivery_time)
				reply_int(c, i64(nack.delivery_count))
			}
			rx.stop(&ki)
		}
		rx.stop(&ci)
	}
	rx.stop(&gi)
}

@(private = "file")
reply_group_history :: proc(c: ^Conn, s: st.Stream, consumer: ^st.Consumer, after: st.ID, count: int) {
	mark := defer_mark(c)
	emitted := 0
	from := after
	if st.incr_id(&from) {
		now := srv.now_ms
		start: [16]u8
		st.encode_id(&start, from)
		it: rx.Iterator
		rx.start(&it, consumer.pel)
		rx.seek(&it, ">=", start[:])
		for (count <= 0 || emitted < count) && rx.next(&it) {
			id := st.decode_id(rx.key(&it))
			if stream_reply_range(c, s, &id, &id, 1, false, true) == 0 {
				reply_array(c, 2)
				reply_stream_id(c, id)
				reply_null_array(c)
			} else {
				st.pel_touch(consumer, id, now)
			}
			emitted += 1
		}
		rx.stop(&it)
	}
	defer_len(c, mark, '*', emitted)
}

cmd_xreadgroup :: proc(c: ^Conn, argv: [][]u8) {
	a, err := st.parse_xread_args(argv, srv.now_ms, true)
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	nkeys := a.streams_count
	group := argv[a.group_arg]
	cname := argv[a.group_arg + 1]
	clear(&stream_ids)
	resize(&stream_ids, nkeys)
	clear(&stream_groups)
	resize(&stream_groups, nkeys)
	clear(&group_history)
	resize(&group_history, nkeys)
	clear(&group_entries)
	resize(&group_entries, nkeys)
	clear(&group_streams)
	resize(&group_streams, nkeys)
	for i in 0 ..< nkeys {
		key := argv[a.streams_arg + i]
		arg := argv[a.streams_arg + nkeys + i]
		e, s, wrong := stream_lookup(key, true)
		if wrong {
			reply_wrongtype(c)
			return
		}
		group_entries[i] = e
		group_streams[i] = s
		cg := st.lookup_cg(s, group)
		if cg == nil {
			reply_nogroup(c, .Xreadgroup, key, group)
			return
		}
		stream_groups[i] = cg
		switch {
		case st.is_byte(arg, '>'):
			group_history[i] = false
		case st.is_byte(arg, '$'):
			reply_stream_error(c, .Dollar_Group)
			return
		case st.is_byte(arg, '+'):
			reply_stream_error(c, .Plus_Group)
			return
		case:
			id, ok := st.parse_strict_id(arg)
			if !ok {
				reply_stream_error(c, .Invalid_ID)
				return
			}
			stream_ids[i] = id
			group_history[i] = true
		}
	}
	changes := 0
	clear(&group_consumers)
	resize(&group_consumers, nkeys)
	for i in 0 ..< nkeys {
		key := argv[a.streams_arg + i]
		e := group_entries[i]
		s := group_streams[i]
		consumer, created := consumer_create_noted(s, stream_groups[i], cname, key)
		if created {
			changes += 1
			stream_sync(e.db, s)
			signal_key(key)
		}
		consumer.seen_time = srv.now_ms
		group_consumers[i] = consumer
	}
	mark := defer_mark(c)
	served := 0
	for i in 0 ..< nkeys {
		key := argv[a.streams_arg + i]
		e := group_entries[i]
		s := group_streams[i]
		cg := stream_groups[i]
		consumer := group_consumers[i]
		if group_history[i] {
			if c.resp == RESP2 {
				reply_array(c, 2)
			}
			reply_bulk(c, key)
			reply_group_history(c, s, consumer, stream_ids[i], int(a.count))
			served += 1
			continue
		}
		if s.length == 0 || st.compare_id(st.last_valid_id(s), cg.last_id) <= 0 {
			continue
		}
		if c.resp == RESP2 {
			reply_array(c, 2)
		}
		reply_bulk(c, key)
		start := cg.last_id
		st.incr_id(&start)
		stream_reply_range(c, s, &start, nil, int(a.count), false, false, cg, consumer, a.noack)
		stream_sync(e.db, s)
		signal_key(key)
		changes += 1
		served += 1
	}
	if changes > 0 {
		group_changes(changes)
	} else {
		pst.dirty_explicit = true
	}
	if served > 0 {
		defer_len(c, mark, c.resp == RESP2 ? '*' : '%', served)
		return
	}
	if a.timeout != -1 && !deny_blocking {
		if c.bstate == nil {
			c.bstate = new(Block_State)
		}
		clear(&c.bstate.stream_ids)
		block_for_keys(c, .Stream, argv[a.streams_arg:a.streams_arg + nkeys], a.timeout, true)
		return
	}
	reply_null_array(c)
}

@(private = "file")
Xgroup_Op :: enum u8 {
	Help,
	Create,
	Setid,
	Destroy,
	Createconsumer,
	Delconsumer,
}

@(private = "file")
xgroup_op :: proc(c: ^Conn, argv: [][]u8) -> (op: Xgroup_Op, ok: bool) {
	sub := argv[1]
	n := len(argv)
	switch {
	case eq_nocase(sub, "help"):
		if n != 2 {
			reply_wrong_args(c, "xgroup|help")
			return
		}
		return .Help, true
	case eq_nocase(sub, "create"):
		if n < 5 {
			reply_wrong_args(c, "xgroup|create")
			return
		}
		return .Create, true
	case eq_nocase(sub, "setid"):
		if n < 5 {
			reply_wrong_args(c, "xgroup|setid")
			return
		}
		return .Setid, true
	case eq_nocase(sub, "destroy"):
		if n != 4 {
			reply_wrong_args(c, "xgroup|destroy")
			return
		}
		return .Destroy, true
	case eq_nocase(sub, "createconsumer"):
		if n != 5 {
			reply_wrong_args(c, "xgroup|createconsumer")
			return
		}
		return .Createconsumer, true
	case eq_nocase(sub, "delconsumer"):
		if n != 5 {
			reply_wrong_args(c, "xgroup|delconsumer")
			return
		}
		return .Delconsumer, true
	}
	reply_unknown_subcommand(c, sub, "XGROUP")
	return
}

cmd_xgroup :: proc(c: ^Conn, argv: [][]u8) {
	op, ok := xgroup_op(c, argv)
	if !ok {
		return
	}
	if op == .Help {
		reply_array(c, len(st.XGROUP_HELP))
		for line in st.XGROUP_HELP {
			reply_simple(c, line)
		}
		return
	}
	pst.dirty_explicit = true
	mkstream := false
	entries_read: i64 = st.SCG_INVALID_ENTRIES_READ
	if op == .Create || op == .Setid {
		if op == .Create && len(argv) > st.XGROUP_CREATE_MAX_ARGS {
			reply_subcommand_syntax_error(c, argv[1], "XGROUP")
			return
		}
		m, er, perr := st.parse_xgroup_opts(argv)
		if perr == .Subcommand_Syntax {
			reply_subcommand_syntax_error(c, argv[1], "XGROUP")
			return
		}
		if perr != .None {
			reply_stream_error(c, perr)
			return
		}
		mkstream = m
		entries_read = er
	}
	key := argv[2]
	group := argv[3]
	e, s, wrong := stream_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	id: st.ID
	dollar := false
	if op == .Create || op == .Setid {
		if st.is_byte(argv[4], '$') {
			dollar = true
		} else {
			parsed: st.ID
			good: bool
			if op == .Setid {
				parsed, _, good = st.parse_id(argv[4], 0, false, false)
			} else {
				parsed, good = st.parse_strict_id(argv[4])
			}
			if !good {
				reply_stream_error(c, .Invalid_ID)
				return
			}
			id = parsed
		}
	}
	if s == nil {
		if op != .Create || !mkstream {
			reply_stream_error(c, .Xgroup_No_Key)
			return
		}
		e, s = stream_create(key)
	}
	if dollar {
		id = s.last_id
	}
	switch op {
	case .Create:
		if st.create_cg(s, group, id, entries_read) == nil {
			stream_sync(e.db, s)
			reply_stream_error(c, .Busygroup)
			return
		}
		stream_sync(e.db, s)
		reply_ok(c)
		signal_key(key)
		notify(.Stream, "xgroup-create", key)
		group_changes(1)
	case .Setid:
		cg := st.lookup_cg(s, group)
		if cg == nil {
			reply_nogroup(c, .For_Key_Name, key, group)
			return
		}
		st.group_set_id(cg, id, entries_read)
		reply_ok(c)
		signal_key(key)
		notify(.Stream, "xgroup-setid", key)
		block_signal_key(e.db, key, .Stream)
		group_changes(1)
	case .Destroy:
		if st.destroy_cg(s, group) {
			stream_sync(e.db, s)
			reply_int(c, 1)
			signal_key(key)
			notify(.Stream, "xgroup-destroy", key)
			block_signal_key(e.db, key, .Stream)
			group_changes(1)
		} else {
			reply_int(c, 0)
		}
	case .Createconsumer:
		cg := st.lookup_cg(s, group)
		if cg == nil {
			reply_nogroup(c, .For_Key_Name, key, group)
			return
		}
		_, created := consumer_create_noted(s, cg, argv[4], key)
		if created {
			stream_sync(e.db, s)
			reply_int(c, 1)
			signal_key(key)
			group_changes(1)
		} else {
			reply_int(c, 0)
		}
	case .Delconsumer:
		cg := st.lookup_cg(s, group)
		if cg == nil {
			reply_nogroup(c, .For_Key_Name, key, group)
			return
		}
		consumer := st.lookup_consumer(cg, argv[4])
		if consumer == nil {
			reply_int(c, 0)
			return
		}
		dropped := st.del_consumer(s, cg, consumer)
		stream_sync(e.db, s)
		reply_int(c, i64(dropped))
		signal_key(key)
		notify(.Stream, "xgroup-delconsumer", key)
		group_changes(1)
	case .Help:
	}
}

cmd_xack :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	key := argv[1]
	e, s, wrong := stream_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	cg := st.lookup_cg(s, argv[2])
	if cg == nil {
		reply_int(c, 0)
		return
	}
	clear(&stream_ids)
	for arg in argv[3:] {
		id, ok := st.parse_strict_id(arg)
		if !ok {
			reply_stream_error(c, .Invalid_ID)
			return
		}
		append(&stream_ids, id)
	}
	acked := 0
	for id in stream_ids {
		if st.ack(s, cg, id) {
			acked += 1
		}
	}
	if acked > 0 {
		stream_sync(e.db, s)
		signal_key(key)
		group_changes(acked)
	}
	reply_int(c, i64(acked))
}

cmd_xpending :: proc(c: ^Conn, argv: [][]u8) {
	a, err := st.parse_xpending_args(argv)
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	key := argv[1]
	group := argv[2]
	_, s, wrong := stream_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	cg := st.lookup_cg(s, group)
	if cg == nil {
		reply_nogroup(c, .Key_Or_Group, key, group)
		return
	}
	if a.justinfo {
		xpending_summary(c, cg)
		return
	}
	if a.count <= 0 {
		reply_array(c, 0)
		return
	}
	source := cg.pel
	if a.consumer_idx > 0 {
		consumer := st.lookup_consumer(cg, argv[a.consumer_idx])
		if consumer == nil {
			reply_array(c, 0)
			return
		}
		source = consumer.pel
	}
	now := srv.now_ms
	mark := defer_mark(c)
	emitted: i64
	if st.compare_id(a.start, a.end) <= 0 {
		start: [16]u8
		st.encode_id(&start, a.start)
		it: rx.Iterator
		rx.start(&it, source)
		rx.seek(&it, ">=", start[:])
		for emitted < a.count && rx.next(&it) {
			id := st.decode_id(rx.key(&it))
			if st.compare_id(id, a.end) > 0 {
				break
			}
			nack := (^st.NACK)(it.data)
			idle := now - nack.delivery_time
			if a.minidle > 0 && idle < a.minidle {
				continue
			}
			reply_array(c, 4)
			reply_stream_id(c, id)
			reply_bulk(c, nack.consumer.name)
			reply_int(c, idle)
			reply_int(c, i64(nack.delivery_count))
			emitted += 1
		}
		rx.stop(&it)
	}
	defer_len(c, mark, '*', int(emitted))
}

@(private = "file")
xpending_summary :: proc(c: ^Conn, cg: ^st.CG) {
	reply_array(c, 4)
	reply_int(c, i64(cg.pel.numele))
	first, last, any := st.pel_first_last(cg.pel)
	if !any {
		reply_null(c)
		reply_null(c)
		reply_null_array(c)
		return
	}
	reply_stream_id(c, first)
	reply_stream_id(c, last)
	mark := defer_mark(c)
	listed := 0
	it: rx.Iterator
	rx.start(&it, cg.consumers)
	rx.seek(&it, "^")
	for rx.next(&it) {
		consumer := (^st.Consumer)(it.data)
		if consumer.pel.numele == 0 {
			continue
		}
		reply_array(c, 2)
		reply_bulk(c, consumer.name)
		reply_bulk_int(c, i64(consumer.pel.numele))
		listed += 1
	}
	rx.stop(&it)
	defer_len(c, mark, '*', listed)
}

@(private = "file")
reply_claimed_entry :: proc(c: ^Conn, s: st.Stream, id: st.ID, justid: bool) {
	if justid {
		reply_stream_id(c, id)
		return
	}
	at := id
	if stream_reply_range(c, s, &at, &at, 1, false, true) == 0 {
		reply_array(c, 2)
		reply_stream_id(c, id)
		reply_null_array(c)
	}
}

cmd_xclaim :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	now := srv.now_ms
	clear(&stream_ids)
	a, bad, err := st.parse_xclaim_args(argv, now, &stream_ids)
	if err == .Claim_Option {
		clear(&group_errbuf)
		st.append_claim_option_error(&group_errbuf, argv[bad])
		reply_error_fmt(c, group_errbuf[:])
		return
	}
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	key := argv[1]
	group := argv[2]
	e, s, wrong := stream_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	cg := st.lookup_cg(s, group)
	if cg == nil {
		reply_nogroup(c, .Key_Or_Group, key, group)
		return
	}
	changes := 0
	consumer, created := consumer_create_noted(s, cg, argv[3], key)
	if created {
		changes += 1
	}
	consumer.seen_time = now
	raised := st.group_raise_last_id(cg, a.last_id)
	mark := defer_mark(c)
	claimed := 0
	deleted := 0
	for id in stream_ids {
		switch st.claim_entry(s, cg, consumer, id, &a, now) {
		case .Claimed:
			reply_claimed_entry(c, s, id, a.justid)
			claimed += 1
		case .Deleted:
			deleted += 1
		case .Skipped:
		}
	}
	defer_len(c, mark, '*', claimed)
	changes += claimed + deleted
	if raised && claimed == 0 {
		changes += 1
	}
	if changes > 0 {
		stream_sync(e.db, s)
		signal_key(key)
		group_changes(changes)
	}
}

cmd_xautoclaim :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	a, err := st.parse_xautoclaim_args(argv)
	if err != .None {
		reply_stream_error(c, err)
		return
	}
	key := argv[1]
	group := argv[2]
	e, s, wrong := stream_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	cg := st.lookup_cg(s, group)
	if cg == nil {
		reply_nogroup(c, .Key_Or_Group, key, group)
		return
	}
	now := srv.now_ms
	changes := 0
	consumer, created := consumer_create_noted(s, cg, argv[3], key)
	if created {
		changes += 1
	}
	consumer.seen_time = now
	clear(&group_steps)
	next := st.autoclaim_scan(s, cg, consumer, &a, now, &group_steps)
	reply_array(c, 3)
	reply_stream_id(c, next)
	mark := defer_mark(c)
	claimed := 0
	for step in group_steps {
		if step.result == .Claimed {
			reply_claimed_entry(c, s, step.id, a.justid)
			claimed += 1
		}
	}
	defer_len(c, mark, '*', claimed)
	deleted := len(group_steps) - claimed
	reply_array(c, deleted)
	for step in group_steps {
		if step.result == .Deleted {
			reply_stream_id(c, step.id)
		}
	}
	changes += len(group_steps)
	if changes > 0 {
		stream_sync(e.db, s)
		signal_key(key)
		group_changes(changes)
	}
}

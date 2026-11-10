package main

import lb "label"

PS_REJECT_TAIL :: "': only (P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT / RESET are allowed in this context"

@(private = "file")
PS_FRAME_KEEP :: 1 << 20

ps_maps: [Ps_Kind]map[string]^Ps_Entry

ps_patterns: [dynamic]^Ps_Entry

@(private = "file")
ps_frame: [dynamic]u8

@(private = "file")
ps_verbs := [Ps_Kind][2]string {
	.Channel = {"subscribe", "unsubscribe"},
	.Pattern = {"psubscribe", "punsubscribe"},
	.Shard   = {"ssubscribe", "sunsubscribe"},
}

@(private = "file")
ps_message_verbs := [Ps_Kind]string {
	.Channel = "message",
	.Pattern = "pmessage",
	.Shard   = "smessage",
}

ps_count :: proc(c: ^Conn, kind: Ps_Kind) -> int {
	st := c.pubsub
	if st == nil {
		return 0
	}
	return len(st.lists[kind])
}

ps_total :: proc(c: ^Conn) -> int {
	return ps_count(c, .Channel) + ps_count(c, .Pattern)
}

ps_list_len :: proc(c: ^Conn, kind: Ps_Kind) -> int {
	return ps_count(c, kind)
}

@(private)
ps_notice_count :: proc(c: ^Conn, kind: Ps_Kind) -> int {
	if kind == .Shard {
		return ps_count(c, .Shard)
	}
	return ps_total(c)
}

@(private = "file")
ps_idle :: proc(c: ^Conn) -> bool {
	return ps_total(c) == 0 && ps_count(c, .Shard) == 0
}

@(private = "file")
ps_new_entry :: proc(kind: Ps_Kind, name: []u8) -> ^Ps_Entry {
	e := new(Ps_Entry)
	e.kind = kind
	if len(name) > 0 {
		e.name = make([]u8, len(name))
		copy(e.name, name)
	}
	ps_maps[kind][string(e.name)] = e
	if kind == .Pattern {
		append(&ps_patterns, e)
	}
	mem_registry_changed()
	return e
}

@(private = "file")
ps_free_entry :: proc(e: ^Ps_Entry) {
	delete_key(&ps_maps[e.kind], string(e.name))
	if e.kind == .Pattern {
		for p, i in ps_patterns {
			if p == e {
				ordered_remove(&ps_patterns, i)
				break
			}
		}
	}
	delete(e.subs)
	delete(e.name)
	free(e)
}

@(private = "file")
ps_detach :: proc(c: ^Conn, e: ^Ps_Entry) {
	ps_metadata_adjust(e, -1)
	for s, i in e.subs {
		if s == c {
			ordered_remove(&e.subs, i)
			break
		}
	}
	ps_metadata_adjust(e, 1)
	client_metadata_sync(c)
	if len(e.subs) == 0 {
		ps_free_entry(e)
	}
}

@(private = "file")
ps_holds :: proc(st: ^Ps_State, c: ^Conn, e: ^Ps_Entry) -> bool {
	mine := st.lists[e.kind][:]
	if len(e.subs) < len(mine) {
		for s in e.subs {
			if s == c {
				return true
			}
		}
		return false
	}
	for x in mine {
		if x == e {
			return true
		}
	}
	return false
}

ps_subscribe :: proc(c: ^Conn, kind: Ps_Kind, name: []u8) -> bool {
	st := ps_state(c)
	e := ps_maps[kind][string(name)]
	if e == nil {
		e = ps_new_entry(kind, name)
	} else if ps_holds(st, c, e) {
		return false
	}
	ps_metadata_adjust(e, -1)
	append(&e.subs, c)
	append(&st.lists[kind], e)
	ps_metadata_adjust(e, 1)
	client_metadata_sync(c)
	return true
}

ps_unsubscribe :: proc(c: ^Conn, kind: Ps_Kind, name: []u8) -> bool {
	st := c.pubsub
	if st == nil {
		return false
	}
	e := ps_maps[kind][string(name)]
	if e == nil {
		return false
	}
	list := &st.lists[kind]
	for x, i in list {
		if x == e {
			ordered_remove(list, i)
			ps_detach(c, e)
			return true
		}
	}
	return false
}

ps_unsubscribe_all :: proc(c: ^Conn, kind: Ps_Kind, notify: bool) -> int {
	st := c.pubsub
	n := 0
	if st != nil {
		n = len(st.lists[kind])
	}
	if n == 0 {
		if notify {
			ps_reply_notice(c, kind, false, nil, false, ps_notice_count(c, kind))
		}
		return 0
	}
	others := 0
	if kind != .Shard {
		others = ps_total(c) - n
	}
	list := &st.lists[kind]
	for i in 0 ..< n {
		e := list[i]
		if notify {
			ps_reply_notice(c, kind, false, e.name, true, others + n - i - 1)
		}
		ps_detach(c, e)
	}
	clear(list)
	return n
}

@(private = "file")
ps_put_int :: proc(b: ^[dynamic]u8, v: int) {
	digits: [20]u8
	i := len(digits)
	n := v
	if n < 0 {
		append(b, '-')
		n = -n
	}
	for {
		i -= 1
		digits[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 {
			break
		}
	}
	append(b, ..digits[i:])
}

@(private = "file")
ps_put_header :: proc(b: ^[dynamic]u8, n: int) {
	append(b, '*')
	ps_put_int(b, n)
	append(b, '\r', '\n')
}

@(private = "file")
ps_put_bulk :: proc(b: ^[dynamic]u8, s: []u8) {
	append(b, '$')
	ps_put_int(b, len(s))
	append(b, '\r', '\n')
	append(b, ..s)
	append(b, '\r', '\n')
}

@(private = "file")
ps_put_word :: proc(b: ^[dynamic]u8, s: string) {
	ps_put_bulk(b, transmute([]u8)s)
}

ps_reply_notice :: proc(c: ^Conn, kind: Ps_Kind, sub: bool, name: []u8, has_name: bool, count: int) {
	b := &ps_frame
	clear(b)
	ps_put_header(b, 3)
	ps_put_word(b, ps_verbs[kind][0] if sub else ps_verbs[kind][1])
	if has_name {
		ps_put_bulk(b, name)
	} else if c.resp >= RESP3 {
		append(b, '_', '\r', '\n')
	} else {
		append(b, '$', '-', '1', '\r', '\n')
	}
	append(b, ':')
	ps_put_int(b, count)
	append(b, '\r', '\n')
	mem_registry_changed()
	ps_emit(c, b[:])
}

@(private = "file")
ps_deliver :: proc(e: ^Ps_Entry, frame: []u8, msg: lb.Id) -> int {
	if labels_on {
		return ps_deliver_labelled(e, frame, msg)
	}
	for t in e.subs {
		ps_emit(t, frame)
	}
	return len(e.subs)
}

@(private = "file")
ps_deliver_labelled :: #force_no_inline proc(e: ^Ps_Entry, frame: []u8, msg: lb.Id) -> int {
	l, ok := access_label_of(msg)
	if !ok {
		return 0
	}
	counted := 0
	for t in e.subs {
		if !access_subscriber_sees(t, l) {
			continue
		}
		ps_emit(t, frame)
		if access_conn_session(t) == access.label {
			counted += 1
		}
	}
	return counted
}

@(private = "file")
ps_build :: proc(kind: Ps_Kind, pattern: []u8, channel: []u8, message: []u8) -> []u8 {
	b := &ps_frame
	clear(b)
	reserve(b, len(pattern) + len(channel) + len(message) + 64)
	if kind == .Pattern {
		ps_put_header(b, 4)
		ps_put_word(b, ps_message_verbs[kind])
		ps_put_bulk(b, pattern)
	} else {
		ps_put_header(b, 3)
		ps_put_word(b, ps_message_verbs[kind])
	}
	ps_put_bulk(b, channel)
	ps_put_bulk(b, message)
	return b[:]
}

ps_publish :: proc(channel: []u8, message: []u8, kind: Ps_Kind, msg: lb.Id = lb.BOTTOM_ID) -> int {
	receivers := 0
	if kind == .Shard {
		if e := ps_maps[.Shard][string(channel)]; e != nil {
			receivers += ps_deliver(e, ps_build(.Shard, nil, channel, message), msg)
		}
	} else if len(ps_maps[.Channel]) > 0 || len(ps_patterns) > 0 {
		if e := ps_maps[.Channel][string(channel)]; e != nil {
			receivers += ps_deliver(e, ps_build(.Channel, nil, channel, message), msg)
		}
		for p in ps_patterns {
			if glob_match(p.name, channel, false) {
				receivers += ps_deliver(p, ps_build(.Pattern, p.name, channel, message), msg)
			}
		}
	}
	if len(ps_doomed) > 0 {
		ps_close_doomed()
	}
	if cap(ps_frame) > PS_FRAME_KEEP {
		delete(ps_frame)
		ps_frame = nil
	}
	mem_registry_changed()
	return receivers
}

pubsub_publish :: proc(channel: []u8, message: []u8, msg: lb.Id = lb.BOTTOM_ID) -> int {
	return ps_publish(channel, message, .Channel, msg)
}

ps_entry_visible :: proc(e: ^Ps_Entry) -> int {
	if !labels_on || access.top {
		return len(e.subs)
	}
	n := 0
	for t in e.subs {
		if access_counts_subscriber(t) {
			n += 1
		}
	}
	return n
}

ps_allowed :: proc(cmd: ^Command) -> bool {
	if cmd == nil {
		return false
	}
	h := cmd.handler
	if h == cmd_subscribe || h == cmd_ssubscribe || h == cmd_psubscribe {
		return true
	}
	if h == cmd_unsubscribe || h == cmd_sunsubscribe || h == cmd_punsubscribe {
		return true
	}
	return h == cmd_ping || h == cmd_quit || h == cmd_reset
}

pubsub_rejects :: proc(c: ^Conn, cmd: ^Command) -> bool {
	return .Subscribed in c.ps && c.resp < RESP3 && !ps_allowed(cmd)
}

@(cold)
ps_reject :: #force_no_inline proc(c: ^Conn, cmd: ^Command, argv: [][]u8) {
	if cmd == nil {
		return
	}
	full, ok := resolve_subcommand(c, cmd, argv)
	if !ok {
		tx_flag(c)
		return
	}
	if cmd.handler == cmd_exec {
		tx_exec_abort(c, "Can't execute '", full, PS_REJECT_TAIL)
		return
	}
	tx_flag(c)
	reply_error_parts(c, "ERR Can't execute '", full, PS_REJECT_TAIL)
}

@(private)
ps_leave_if_idle :: proc(c: ^Conn) {
	if ps_idle(c) {
		ps_unmark(c)
	}
}

pubsub_registry_memory :: proc "contextless" () -> int {
	return cap(ps_frame)
}

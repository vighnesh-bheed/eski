package main

@(private = "file")
PS_MATCHED_KEEP :: 1 << 16

@(private = "file")
pubsub_help := [?]string {
	"PUBSUB <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"CHANNELS [<pattern>]",
	"    Return the currently active channels matching a <pattern> (default: '*').",
	"NUMPAT",
	"    Return number of subscriptions to patterns.",
	"NUMSUB [<channel> ...]",
	"    Return the number of subscribers for the specified channels, excluding",
	"    pattern subscriptions(default: no channels).",
	"SHARDCHANNELS [<pattern>]",
	"    Return the currently active shard level channels matching a <pattern> (default: '*').",
	"SHARDNUMSUB [<shardchannel> ...]",
	"    Return the number of subscribers for the specified shard level channel(s)",
	"HELP",
	"    Print this help.",
}

@(private = "file")
ps_matched: [dynamic]^Ps_Entry

@(private = "file")
ps_open_notices :: proc(c: ^Conn) -> (own: bool) {
	own = !ps_hooked && ps_exec != c
	ps_begin(c)
	return
}

@(private = "file")
ps_close_notices :: proc(c: ^Conn, own: bool) {
	if own {
		pubsub_after(c, nil, nil)
	}
}

@(private = "file")
subscribe_generic :: proc(c: ^Conn, argv: [][]u8, kind: Ps_Kind) {
	own := ps_open_notices(c)
	for name in argv[1:] {
		ps_subscribe(c, kind, name)
		ps_mark(c)
		ps_reply_notice(c, kind, true, name, true, ps_notice_count(c, kind))
	}
	ps_close_notices(c, own)
}

@(private = "file")
unsubscribe_generic :: proc(c: ^Conn, argv: [][]u8, kind: Ps_Kind) {
	own := ps_open_notices(c)
	if len(argv) < 2 {
		ps_unsubscribe_all(c, kind, true)
	} else {
		for name in argv[1:] {
			ps_unsubscribe(c, kind, name)
			ps_reply_notice(c, kind, false, name, true, ps_notice_count(c, kind))
		}
	}
	ps_leave_if_idle(c)
	ps_close_notices(c, own)
}

cmd_subscribe :: proc(c: ^Conn, argv: [][]u8) {
	subscribe_generic(c, argv, .Channel)
}

cmd_psubscribe :: proc(c: ^Conn, argv: [][]u8) {
	subscribe_generic(c, argv, .Pattern)
}

cmd_ssubscribe :: proc(c: ^Conn, argv: [][]u8) {
	subscribe_generic(c, argv, .Shard)
}

cmd_unsubscribe :: proc(c: ^Conn, argv: [][]u8) {
	unsubscribe_generic(c, argv, .Channel)
}

cmd_punsubscribe :: proc(c: ^Conn, argv: [][]u8) {
	unsubscribe_generic(c, argv, .Pattern)
}

cmd_sunsubscribe :: proc(c: ^Conn, argv: [][]u8) {
	unsubscribe_generic(c, argv, .Shard)
}

cmd_publish :: proc(c: ^Conn, argv: [][]u8) {
	reply_int(c, i64(ps_publish(argv[1], argv[2], .Channel)))
}

cmd_spublish :: proc(c: ^Conn, argv: [][]u8) {
	reply_int(c, i64(ps_publish(argv[1], argv[2], .Shard)))
}

reply_pubsub_pong :: proc(c: ^Conn, argv: [][]u8) {
	reply_array(c, 2)
	reply_bulk_str(c, "pong")
	if len(argv) > 1 {
		reply_bulk(c, argv[1])
	} else {
		reply_bulk_str(c, "")
	}
}

@(private = "file")
pubsub_channel_list :: proc(c: ^Conn, argv: [][]u8, kind: Ps_Kind) {
	clear(&ps_matched)
	filtered := len(argv) > 2
	for _, e in ps_maps[kind] {
		if filtered && !glob_match(argv[2], e.name, false) {
			continue
		}
		append(&ps_matched, e)
	}
	reply_array(c, len(ps_matched))
	for e in ps_matched {
		reply_bulk(c, e.name)
	}
	clear(&ps_matched)
	if cap(ps_matched) > PS_MATCHED_KEEP {
		delete(ps_matched)
		ps_matched = nil
	}
}

@(private = "file")
pubsub_numsub :: proc(c: ^Conn, argv: [][]u8, kind: Ps_Kind) {
	names := argv[2:]
	reply_array(c, 2 * len(names))
	for name in names {
		reply_bulk(c, name)
		e := ps_maps[kind][string(name)]
		reply_int(c, i64(len(e.subs)) if e != nil else 0)
	}
}

@(private = "file")
pubsub_help_reply :: proc(c: ^Conn) {
	reply_array(c, len(pubsub_help))
	for line in pubsub_help {
		reply_simple(c, line)
	}
}

cmd_pubsub :: proc(c: ^Conn, argv: [][]u8) {
	sub := argv[1]
	switch {
	case eq_nocase(sub, "channels"):
		c.last_cmd = "pubsub|channels"
		if len(argv) > 3 {
			reply_subcommand_syntax_error(c, sub, "PUBSUB")
			return
		}
		pubsub_channel_list(c, argv, .Channel)
	case eq_nocase(sub, "numsub"):
		c.last_cmd = "pubsub|numsub"
		pubsub_numsub(c, argv, .Channel)
	case eq_nocase(sub, "numpat"):
		c.last_cmd = "pubsub|numpat"
		if len(argv) != 2 {
			reply_wrong_args(c, "pubsub|numpat")
			return
		}
		reply_int(c, i64(len(ps_maps[.Pattern])))
	case eq_nocase(sub, "shardchannels"):
		c.last_cmd = "pubsub|shardchannels"
		if len(argv) > 3 {
			reply_subcommand_syntax_error(c, sub, "PUBSUB")
			return
		}
		pubsub_channel_list(c, argv, .Shard)
	case eq_nocase(sub, "shardnumsub"):
		c.last_cmd = "pubsub|shardnumsub"
		pubsub_numsub(c, argv, .Shard)
	case eq_nocase(sub, "help"):
		c.last_cmd = "pubsub|help"
		if len(argv) != 2 {
			reply_wrong_args(c, "pubsub|help")
			return
		}
		pubsub_help_reply(c)
	case:
		c.last_cmd = "NULL"
		reply_unknown_subcommand(c, sub, "PUBSUB")
	}
}

@(private = "file")
pubsub_commands := [?]Command {
	{"subscribe", cmd_subscribe, -2},
	{"unsubscribe", cmd_unsubscribe, -1},
	{"psubscribe", cmd_psubscribe, -2},
	{"punsubscribe", cmd_punsubscribe, -1},
	{"ssubscribe", cmd_ssubscribe, -2},
	{"sunsubscribe", cmd_sunsubscribe, -1},
	{"publish", cmd_publish, 3},
	{"spublish", cmd_spublish, 3},
	{"pubsub", cmd_pubsub, -2},
}

@(init)
register_pubsub_commands :: proc "contextless" () {
	register_commands(pubsub_commands[:])
}

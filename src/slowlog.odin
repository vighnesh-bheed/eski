package main

import "core:container/queue"

SLOWLOG_ENTRY_MAX_ARGC :: 32
SLOWLOG_ENTRY_MAX_STRING :: 128
SLOWLOG_REDACTED :: "(redacted)"

@(private = "file")
Slowlog_Entry :: struct {
	id:    i64,
	time:  i64,
	us:    i64,
	spans: [][2]int,
	buf:   []u8,
	peer:  []u8,
	name:  []u8,
}

@(private = "file")
slowlog: queue.Queue(^Slowlog_Entry)
@(private = "file")
slowlog_next_id: i64
@(private = "file")
slowlog_buf: [dynamic]u8
@(private = "file")
slowlog_spans: [dynamic][2]int
@(private = "file")
slowlog_redact: [SLOWLOG_ENTRY_MAX_ARGC]bool

@(private = "file")
slowlog_free :: proc(e: ^Slowlog_Entry) {
	delete(e.spans)
	delete(e.buf)
	free(e)
}

@(private = "file")
slowlog_mark :: proc(i: int) {
	if i >= 0 && i < SLOWLOG_ENTRY_MAX_ARGC {
		slowlog_redact[i] = true
	}
}

@(private = "file")
slowlog_mark_from :: proc(from: int, argc: int) {
	for j in from ..< argc {
		slowlog_mark(j)
	}
}

@(private = "file")
slowlog_mark_hello :: proc(argv: [][]u8) {
	argc := len(argv)
	if argc >= 2 {
		ver, ok := parse_i64(argv[1])
		if !ok || ver < 2 || ver > 3 {
			return
		}
	}
	for j := 2; j < argc; j += 1 {
		more := argc - 1 - j
		if eq_nocase(argv[j], "auth") && more >= 2 {
			slowlog_mark(j + 1)
			slowlog_mark(j + 2)
			j += 2
		} else if eq_nocase(argv[j], "setname") && more > 0 {
			if !valid_client_name(argv[j + 1]) {
				return
			}
			j += 1
		} else {
			return
		}
	}
}

@(private = "file")
slowlog_mark_migrate :: proc(argv: [][]u8) {
	argc := len(argv)
	for j := 6; j < argc; j += 1 {
		more := argc - 1 - j
		switch {
		case eq_nocase(argv[j], "copy"), eq_nocase(argv[j], "replace"):
		case eq_nocase(argv[j], "auth"):
			if more == 0 {
				return
			}
			j += 1
			slowlog_mark(j)
		case eq_nocase(argv[j], "auth2"):
			if more < 2 {
				return
			}
			slowlog_mark(j + 1)
			slowlog_mark(j + 2)
			j += 2
		case:
			return
		}
	}
}

@(private = "file")
slowlog_mark_config_set :: proc(argv: [][]u8) {
	argc := len(argv)
	if argc & 1 != 0 {
		return
	}
	for i := 2; i + 1 < argc; i += 2 {
		if cf := config_lookup(argv[i]); cf != nil && .Sensitive in cf.flags {
			slowlog_mark(i + 1)
		}
	}
}

@(private = "file")
slowlog_mark_redacted :: proc(st: ^Cmd_Stats, argv: [][]u8) {
	slowlog_redact = {}
	argc := len(argv)
	switch st.name {
	case "auth":
		if argc <= 3 {
			slowlog_mark_from(1, argc)
		}
	case "hello":
		slowlog_mark_hello(argv)
	case "migrate":
		slowlog_mark_migrate(argv)
	case "config|set":
		slowlog_mark_config_set(argv)
	case "acl|setuser", "acl|deluser":
		slowlog_mark_from(2, argc)
	case "acl|getuser":
		if argc == 3 {
			slowlog_mark(2)
		}
	}
}

slowlog_push :: proc(c: ^Conn, st: ^Cmd_Stats, argv: [][]u8, us: i64) {
	if us >= cfg.slowlog_log_slower_than {
		slowlog_mark_redacted(st, argv)
		clear(&slowlog_buf)
		clear(&slowlog_spans)
		argc := len(argv)
		n := min(argc, SLOWLOG_ENTRY_MAX_ARGC)
		for j in 0 ..< n {
			at := len(slowlog_buf)
			if n != argc && j == n - 1 {
				sb_str(&slowlog_buf, "... (")
				sb_int(&slowlog_buf, i64(argc - n + 1))
				sb_str(&slowlog_buf, " more arguments)")
			} else if slowlog_redact[j] {
				sb_str(&slowlog_buf, SLOWLOG_REDACTED)
			} else if len(argv[j]) > SLOWLOG_ENTRY_MAX_STRING {
				sb_bytes(&slowlog_buf, argv[j][:SLOWLOG_ENTRY_MAX_STRING])
				sb_str(&slowlog_buf, "... (")
				sb_int(&slowlog_buf, i64(len(argv[j]) - SLOWLOG_ENTRY_MAX_STRING))
				sb_str(&slowlog_buf, " more bytes)")
			} else {
				sb_bytes(&slowlog_buf, argv[j])
			}
			append(&slowlog_spans, [2]int{at, len(slowlog_buf) - at})
		}
		peer_at := len(slowlog_buf)
		sb_bytes(&slowlog_buf, c.addr[:c.addr_len])
		name_at := len(slowlog_buf)
		sb_bytes(&slowlog_buf, c.name)
		sec, _ := now_realtime()
		e := new(Slowlog_Entry)
		e.id = slowlog_next_id
		slowlog_next_id += 1
		e.time = sec
		e.us = us
		e.buf = make([]u8, len(slowlog_buf))
		copy(e.buf, slowlog_buf[:])
		e.spans = make([][2]int, len(slowlog_spans))
		copy(e.spans, slowlog_spans[:])
		e.peer = e.buf[peer_at:name_at]
		e.name = e.buf[name_at:]
		queue.push_back(&slowlog, e)
	}
	for i64(queue.len(slowlog)) > cfg.slowlog_max_len {
		slowlog_free(queue.pop_front(&slowlog))
	}
}

@(private = "file")
slowlog_reset :: proc() {
	for queue.len(slowlog) > 0 {
		slowlog_free(queue.pop_front(&slowlog))
	}
}

@(private = "file")
slowlog_help := [?]string {
	"SLOWLOG <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"GET [<count>]",
	"    Return top <count> entries from the slowlog (default: 10, -1 mean all).",
	"    Entries are made of:",
	"    id, timestamp, time in microseconds, arguments array, client IP and port,",
	"    client name",
	"LEN",
	"    Return the length of the slowlog.",
	"RESET",
	"    Reset the slowlog.",
	"HELP",
	"    Print this help.",
}

ERR_SLOWLOG_COUNT :: "ERR count should be greater than or equal to -1"

cmd_slowlog :: proc(c: ^Conn, argv: [][]u8) {
	if container_precheck(c, argv, "slowlog", "SLOWLOG") {
		return
	}
	sub := argv[1]
	argc := len(argv)
	switch {
	case argc == 2 && eq_nocase(sub, "help"):
		reply_array(c, len(slowlog_help))
		for line in slowlog_help {
			reply_simple(c, line)
		}
	case argc == 2 && eq_nocase(sub, "reset"):
		slowlog_reset()
		reply_ok(c)
	case argc == 2 && eq_nocase(sub, "len"):
		reply_int(c, i64(queue.len(slowlog)))
	case (argc == 2 || argc == 3) && eq_nocase(sub, "get"):
		count: i64 = 10
		total := i64(queue.len(slowlog))
		if argc == 3 {
			v, ok := parse_i64(argv[2])
			if !ok || v < -1 {
				reply_error(c, ERR_SLOWLOG_COUNT)
				return
			}
			count = total if v == -1 else v
		}
		count = min(count, total)
		reply_array(c, int(count))
		for k in 0 ..< int(count) {
			e := queue.get(&slowlog, int(total) - 1 - k)
			reply_array(c, 6)
			reply_int(c, e.id)
			reply_int(c, e.time)
			reply_int(c, e.us)
			reply_array(c, len(e.spans))
			for sp in e.spans {
				reply_bulk(c, e.buf[sp[0]:][:sp[1]])
			}
			reply_bulk(c, e.peer)
			reply_bulk(c, e.name)
		}
	case:
		reply_subcommand_syntax_error(c, sub, "SLOWLOG")
	}
}

@(private = "file")
slowlog_commands := [?]Command{{"slowlog", cmd_slowlog, -2}}

@(init)
register_slowlog_commands :: proc "contextless" () {
	register_commands(slowlog_commands[:])
}

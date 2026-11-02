package main

import "core:strconv"
import "core:sys/linux"
import "rdb"

read_rss :: proc() -> i64 {
	fd, err := linux.open("/proc/self/statm", {})
	if err != .NONE {
		return 0
	}
	defer linux.close(fd)
	buf: [256]u8
	n, rerr := linux.read(fd, buf[:])
	if rerr != .NONE || n <= 0 {
		return 0
	}
	i := 0
	for i < n && buf[i] != ' ' {
		i += 1
	}
	i += 1
	pages: i64 = 0
	for i < n && buf[i] >= '0' && buf[i] <= '9' {
		pages = pages * 10 + i64(buf[i] - '0')
		i += 1
	}
	return pages * 4096
}

cron_paused: bool

@(private = "file")
digit_run :: proc "contextless" (s: []u8) -> int {
	n := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' {
		n += 1
	}
	return n
}

@(private = "file")
decimal_float_token :: proc "contextless" (arg: []u8) -> []u8 {
	at := 0
	for at < len(arg) && (arg[at] == ' ' || (arg[at] >= '\t' && arg[at] <= '\r')) {
		at += 1
	}
	start := at
	if at < len(arg) && (arg[at] == '+' || arg[at] == '-') {
		at += 1
	}
	whole := digit_run(arg[at:])
	at += whole
	fraction := 0
	if at < len(arg) && arg[at] == '.' {
		fraction = digit_run(arg[at + 1:])
		if whole + fraction > 0 {
			at += 1 + fraction
		}
	}
	if whole + fraction == 0 {
		return nil
	}
	if at < len(arg) && (arg[at] == 'e' || arg[at] == 'E') {
		mark := at + 1
		if mark < len(arg) && (arg[mark] == '+' || arg[mark] == '-') {
			mark += 1
		}
		if exponent := digit_run(arg[mark:]); exponent > 0 {
			at = mark + exponent
		}
	}
	return arg[start:at]
}

debug_sleep :: proc(arg: []u8) {
	seconds, _ := strconv.parse_f64(string(decimal_float_token(arg)))
	micros := seconds * 1_000_000
	if micros < 1 || !(micros < 9.2e18) {
		return
	}
	sleep_microseconds(i64(micros))
	update_clock()
}

cmd_debug :: proc(c: ^Conn, argv: [][]u8) {
	if !debug_allowed(c) {
		reply_error(c, ERR_DEBUG_NOT_ALLOWED)
		return
	}
	if diagnostics_debug(c, argv) { return }
	if persist_debug(c, argv) {
		return
	}
	if eq_nocase(argv[1], "set-disable-deny-scripts") && len(argv) == 3 {
		lua_deny_scripts_disabled = c_atoi(argv[2]) != 0
		reply_ok(c)
		return
	}
	if eq_nocase(argv[1], "config-rewrite-force-all") && len(argv) == 2 {
		if config_file == "" {
			reply_error(c, "ERR CONFIG-REWRITE-FORCE-ALL failed: The server is running without a config file")
		} else if err := config_rewrite(config_file, true); err != .NONE {
			reply_error_parts(c, "ERR CONFIG-REWRITE-FORCE-ALL failed: ", errno_text(err))
		} else {
			reply_ok(c)
		}
		return
	}
	if eq_nocase(argv[1], "sleep") {
		if len(argv) != 3 {
			reply_subcommand_syntax_error(c, argv[1], "DEBUG")
			return
		}
		debug_sleep(argv[2])
		reply_ok(c)
		return
	}
	if eq_nocase(argv[1], "pause-cron") {
		if len(argv) != 3 {
			reply_subcommand_syntax_error(c, argv[1], "DEBUG")
			return
		}
		cron_paused = c_atoi(argv[2]) != 0
		reply_ok(c)
		return
	}
	if eq_nocase(argv[1], "protocol") {
		if len(argv) != 3 {
			reply_subcommand_syntax_error(c, argv[1], "DEBUG")
			return
		}
		reply_debug_protocol(c, argv[2])
		return
	}
	if eq_nocase(argv[1], "object") && len(argv) == 3 {
		e := db_find_raw_in(c.db, argv[2])
		if e == nil {
			reply_error(c, ERR_NO_KEY)
			return
		}
		addr := uintptr(e.vp)
		if h := entry_object(e, .Hash); h != nil {
			addr = uintptr(h)
		} else if s := entry_object(e, .Set); s != nil {
			addr = uintptr(s)
		} else if z := entry_object(e, .Zset); z != nil {
			addr = uintptr(z)
		} else if l := entry_object(e, .List); l != nil {
			addr = uintptr(l)
		} else if sm := entry_object(e, .Stream); sm != nil {
			addr = uintptr(sm)
		}
		size := debug_serialized_length(e, argv[2])
		idle := entry_idle_seconds(e)
		clear(&scratch)
		sb_str(&scratch, "Value at:0x")
		hexd := "0123456789abcdef"
		started := false
		for shift := 60; shift >= 0; shift -= 4 {
			d := (addr >> uint(shift)) & 15
			if d != 0 || started || shift == 0 {
				sb_byte(&scratch, hexd[d])
				started = true
			}
		}
		sb_str(&scratch, " refcount:")
		sb_int(&scratch, OBJ_SHARED_REFCOUNT if entry_shared_integer(e) else 1)
		sb_str(&scratch, " encoding:")
		sb_str(&scratch, entry_encoding(e))
		sb_str(&scratch, " serializedlength:")
		sb_int(&scratch, i64(size))
		sb_str(&scratch, " lru:")
		sb_int(&scratch, i64(entry_lru(e)))
		sb_str(&scratch, " lru_seconds_idle:")
		sb_int(&scratch, idle)
		list_debug_object_extra(&scratch, e)
		reply_simple(c, string(scratch[:]))
		return
	}
	if eq_nocase(argv[1], "set-active-expire") && len(argv) == 3 {
		active_expire_enabled = c_atoi(argv[2]) != 0
		reply_ok(c)
		return
	}
	if list_debug(c, argv) {
		return
	}
	if eq_nocase(argv[1], "htstats") && len(argv) >= 3 {
		id, ok := parse_i64(argv[2])
		if !ok {
			reply_error(c, ERR_NOT_INT)
			return
		}
		if id < 0 || id >= i64(len(dbs)) {
			reply_error(c, "ERR Out of range database")
			return
		}
		clear(&scratch)
		db_htstats(&scratch, int(id))
		reply_verbatim(c, scratch[:])
		return
	}
	if debug_more(c, argv) {
		return
	}
	reply_subcommand_syntax_error(c, argv[1], "DEBUG")
}

@(private = "file")
debug_serialized_length :: proc(e: ^Entry, key: []u8) -> int {
	w: rdb.Writer
	rdb.writer_init_mem(&w, pst.compression, false)
	persist_write_value(&w, key, persist_slot_value(e.db, e.kp, e.vp), false)
	out := rdb.writer_bytes(&w)
	n := len(out) - 1
	if len(out) > 0 && (out[0] == rdb.TYPE_HASH_LISTPACK_EX || out[0] == rdb.TYPE_HASH_TABLE_EX) {
		n -= 8
	}
	rdb.writer_destroy(&w)
	return n
}

cmd_time :: proc(c: ^Conn, argv: [][]u8) {
	sec, usec := now_realtime()
	if lua_active != nil {
		sec, usec = srv.now_us / 1_000_000, srv.now_us % 1_000_000
	}
	reply_array(c, 2)
	reply_bulk_int(c, sec)
	reply_bulk_int(c, usec)
}

cmd_dbsize :: proc(c: ^Conn, argv: [][]u8) {
	reply_int(c, i64(db_size()))
}

flush_generic :: proc(c: ^Conn, argv: [][]u8, all: bool) {
	if len(argv) > 2 || (len(argv) == 2 && !eq_nocase(argv[1], "async") && !eq_nocase(argv[1], "sync")) {
		reply_error(c, ERR_SYNTAX)
		return
	}
	lazy := cfg.lazyfree_lazy_user_flush
	if len(argv) == 2 {
		lazy = eq_nocase(argv[1], "async")
	}
	blocking := !lazy && c.fd >= 0 && c.kind == .Redis && .Multi not_in c.txf && !deny_blocking
	removed: i64 = 0
	if all {
		removed = persist_total_keys()
		watch_flush(nil)
		db_flush_all(lazy || blocking)
	} else {
		removed = i64(db_size_of(c.db))
		watch_flush(c.db)
		db_flush_in(c.db, lazy || blocking)
	}
	block_note_removed()
	tracking_flush()
	persist_flushed(all, removed)
	if blocking {
		lazyfree_block(c)
		return
	}
	reply_ok(c)
}

cmd_flushdb :: proc(c: ^Conn, argv: [][]u8) {
	flush_generic(c, argv, false)
}

cmd_flushall :: proc(c: ^Conn, argv: [][]u8) {
	flush_generic(c, argv, true)
}

cmd_swapdb :: proc(c: ^Conn, argv: [][]u8) {
	a, ok := parse_db_index(c, argv[1], "ERR invalid first DB index")
	if !ok {
		return
	}
	b, ok2 := parse_db_index(c, argv[2], "ERR invalid second DB index")
	if !ok2 {
		return
	}
	if !db_index_valid(a) || !db_index_valid(b) {
		reply_error(c, ERR_DB_RANGE)
		return
	}
	watch_swap(a, b)
	db_swap(a, b)
	block_scan_ready(&dbs[a])
	block_scan_ready(&dbs[b])
	block_note_removed()
	reply_ok(c)
}

FUNCTION_EMPTY_DUMP :: "\x0c\x00\x96\xedh\x80\xf5U<\x93"

@(private = "file")
function_help := [?]string {
	"FUNCTION <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"LOAD [REPLACE] <FUNCTION CODE>",
	"    Create a new library with the given library name and code.",
	"DELETE <LIBRARY NAME>",
	"    Delete the given library.",
	"LIST [LIBRARYNAME PATTERN] [WITHCODE]",
	"    Return general information on all the libraries:",
	"    * Library name",
	"    * The engine used to run the Library",
	"    * Functions list",
	"    * Library code (if WITHCODE is given)",
	"    It also possible to get only function that matches a pattern using LIBRARYNAME argument.",
	"STATS",
	"    Return information about the current function running:",
	"    * Function name",
	"    * Command used to run the function",
	"    * Duration in MS that the function is running",
	"    If no function is running, return nil",
	"    In addition, returns a list of available engines.",
	"KILL",
	"    Kill the current running function.",
	"FLUSH [ASYNC|SYNC]",
	"    Delete all the libraries.",
	"    When called without the optional mode argument, the behavior is determined by the",
	"    lazyfree-lazy-user-flush configuration directive. Valid modes are:",
	"    * ASYNC: Asynchronously flush the libraries.",
	"    * SYNC: Synchronously flush the libraries.",
	"DUMP",
	"    Return a serialized payload representing the current libraries, can be restored using FUNCTION RESTORE command",
	"RESTORE <PAYLOAD> [FLUSH|APPEND|REPLACE]",
	"    Restore the libraries represented by the given payload, it is possible to give a restore policy to",
	"    control how to handle existing libraries (default APPEND):",
	"    * FLUSH: delete all existing libraries.",
	"    * APPEND: appends the restored libraries to the existing libraries. On collision, abort.",
	"    * REPLACE: appends the restored libraries to the existing libraries, On collision, replace the old",
	"      libraries with the new libraries (notice that even on this option there is a chance of failure",
	"      in case of functions name collision with another library).",
	"HELP",
	"    Print this help.",
}

@(private = "file")
reply_error_arg :: proc(c: ^Conn, prefix: string, arg: []u8) {
	clear(&scratch)
	sb_str(&scratch, prefix)
	sb_bytes(&scratch, arg)
	sanitize_scratch()
	reply_error_bytes(c, scratch[:])
}

cmd_function :: proc(c: ^Conn, argv: [][]u8) {
	if eq_nocase(argv[1], "help") {
		if len(argv) != 2 {
			reply_wrong_args(c, "function|help")
			return
		}
		reply_array(c, len(function_help))
		for line in function_help {
			reply_simple(c, line)
		}
		return
	}
	lua_function_dispatch(c, argv)
}

@(private = "file")
server_commands := [?]Command {
	{"dbsize", cmd_dbsize, 1},
	{"flushdb", cmd_flushdb, -1},
	{"flushall", cmd_flushall, -1},
	{"swapdb", cmd_swapdb, 3},
	{"command", cmd_command, -1},
	{"config", cmd_config, -2},
	{"info", cmd_info, -1},
	{"debug", cmd_debug, -2},
	{"time", cmd_time, 1},
	{"memory", cmd_memory, -2},
	{"function", cmd_function, -2},
}

@(init)
register_server_commands :: proc "contextless" () {
	register_commands(server_commands[:])
}

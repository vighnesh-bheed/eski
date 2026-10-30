package main

import "core:slice"

Reply_Flag :: enum u8 {
	Off,
	Skip,
	Skip_Next,
	Held,
}

Client_Flag :: enum u8 {
	No_Evict,
	No_Touch,
	Monitor,
}

Client_Type :: enum u8 {
	Any,
	Normal,
	Master,
	Replica,
	Pubsub,
}

DEFAULT_USER :: "default"
ERR_AUTH_NOPASS :: "ERR AUTH <password> called without any password configured for the default user. Are you sure your configuration is correct?"
ERR_WRONGPASS :: "WRONGPASS invalid username-password pair or user is disabled."
ERR_CLIENT_NAME :: "ERR Client names cannot contain spaces, newlines or special characters."
ERR_CACHING :: "ERR CLIENT CACHING can be called only when the client is in tracking mode with OPTIN or OPTOUT mode enabled"

conn_scratch: [dynamic]^Conn

cmd_ping :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) > 2 {
		reply_wrong_args(c, "ping")
		return
	}
	if .Subscribed in c.ps && c.resp < RESP3 {
		reply_pubsub_pong(c, argv)
	} else if len(argv) == 2 {
		reply_bulk(c, argv[1])
	} else {
		reply_simple(c, "PONG")
	}
}

cmd_echo :: proc(c: ^Conn, argv: [][]u8) {
	reply_bulk(c, argv[1])
}

ERR_DB_RANGE :: "ERR DB index is out of range"
ERR_INT_RANGE :: "ERR value is out of range, value must between -2147483648 and 2147483647"

parse_db_index :: proc(c: ^Conn, arg: []u8, msg: string) -> (int, bool) {
	v, ok := parse_i64(arg)
	if !ok || v < i64(min(i32)) || v > i64(max(i32)) {
		if msg != "" {
			reply_error(c, msg)
		} else {
			reply_error(c, ERR_NOT_INT if !ok else ERR_INT_RANGE)
		}
		return 0, false
	}
	return int(v), true
}

db_index_valid :: #force_inline proc "contextless" (id: int) -> bool {
	return id >= 0 && id < len(dbs)
}

cmd_select :: proc(c: ^Conn, argv: [][]u8) {
	id, ok := parse_db_index(c, argv[1], "")
	if !ok {
		return
	}
	if !db_index_valid(id) {
		reply_error(c, ERR_DB_RANGE)
		return
	}
	c.db = &dbs[id]
	reply_ok(c)
}

cmd_quit :: proc(c: ^Conn, argv: [][]u8) {
	reply_ok(c)
	c.close_after = true
}

conn_reset :: proc(c: ^Conn) {
	if .Monitor in c.flags {
		monitor_remove(c)
	}
	tx_discard(c)
	pubsub_reset(c)
	set_conn_string(&c.name, nil)
	c.db = &dbs[0]
	c.resp = RESP2
	c.reply -= {.Off, .Skip_Next}
	c.flags = {}
	acl_conn_reset(c)
}

cmd_reset :: proc(c: ^Conn, argv: [][]u8) {
	conn_reset(c)
	reply_simple(c, "RESET")
}

cmd_auth :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) > 3 {
		reply_error(c, ERR_SYNTAX)
		return
	}
	username := transmute([]u8)string(DEFAULT_USER)
	password := argv[1]
	if len(argv) == 2 {
		if .Nopass in acl_default.flags {
			reply_error(c, ERR_AUTH_NOPASS)
			return
		}
	} else {
		username = argv[1]
		password = argv[2]
	}
	if !acl_authenticate(c, argv, username, password) {
		reply_error(c, ERR_WRONGPASS)
		return
	}
	reply_ok(c)
}

valid_client_name :: proc(name: []u8) -> bool {
	for b in name {
		if b < '!' || b > '~' {
			return false
		}
	}
	return true
}

set_conn_string :: proc(dst: ^[]u8, v: []u8) {
	mem_free(raw_data(dst^))
	dst^ = nil
	if len(v) > 0 {
		dst^ = transmute([]u8)clone_key(v)
	}
}

reply_error_quoted :: proc(c: ^Conn, prefix: string, arg: []u8, suffix: string) {
	clear(&scratch)
	sb_str(&scratch, prefix)
	sb_bytes(&scratch, arg)
	sb_str(&scratch, suffix)
	sanitize_scratch()
	reply_error_bytes(c, scratch[:])
}

reply_subcommand_syntax :: proc(c: ^Conn, argv: [][]u8) {
	sub := argv[1]
	reply_error_quoted(c, "ERR unknown subcommand or wrong number of arguments for '", sub[:min(len(sub), 128)], "'. Try CLIENT HELP.")
}

cmd_hello :: proc(c: ^Conn, argv: [][]u8) {
	ver: i64 = 0
	next := 1
	if len(argv) >= 2 {
		v, ok := parse_i64(argv[1])
		if !ok {
			reply_error(c, "ERR Protocol version is not an integer or out of range")
			return
		}
		if v < RESP2 || v > RESP3 {
			reply_error(c, "NOPROTO unsupported protocol version")
			return
		}
		ver = v
		next = 2
	}
	user: []u8
	pass: []u8
	name: []u8
	has_auth := false
	has_name := false
	for i := next; i < len(argv); i += 1 {
		more := len(argv) - i - 1
		a := argv[i]
		if eq_nocase(a, "auth") && more >= 2 {
			user = argv[i + 1]
			pass = argv[i + 2]
			has_auth = true
			i += 2
		} else if eq_nocase(a, "setname") && more >= 1 {
			name = argv[i + 1]
			if !valid_client_name(name) {
				reply_error(c, ERR_CLIENT_NAME)
				return
			}
			has_name = true
			i += 1
		} else {
			reply_error_quoted(c, "ERR Syntax error in HELLO option '", a, "'")
			return
		}
	}
	if has_auth && !acl_authenticate(c, argv, user, pass) {
		reply_error(c, ERR_WRONGPASS)
		return
	}
	if acl_auth_required(c) {
		reply_error(c, ERR_NOAUTH_HELLO)
		return
	}
	if has_name {
		set_conn_string(&c.name, name)
	}
	if ver != 0 {
		c.resp = u8(ver)
	}
	reply_map(c, 7)
	reply_bulk_str(c, "server")
	reply_bulk_str(c, "eski")
	reply_bulk_str(c, "version")
	reply_bulk_str(c, VERSION)
	reply_bulk_str(c, "proto")
	reply_int(c, i64(c.resp))
	reply_bulk_str(c, "id")
	reply_int(c, c.id)
	reply_bulk_str(c, "mode")
	reply_bulk_str(c, "standalone")
	reply_bulk_str(c, "role")
	reply_bulk_str(c, "master")
	reply_bulk_str(c, "modules")
	reply_array(c, 0)
}

conn_type :: proc(c: ^Conn) -> Client_Type {
	return .Pubsub if .Subscribed in c.ps else .Normal
}

parse_client_type :: proc(s: []u8) -> (Client_Type, bool) {
	switch {
	case eq_nocase(s, "normal"):
		return .Normal, true
	case eq_nocase(s, "master"):
		return .Master, true
	case eq_nocase(s, "replica"), eq_nocase(s, "slave"):
		return .Replica, true
	case eq_nocase(s, "pubsub"):
		return .Pubsub, true
	}
	return .Any, false
}

conn_age :: proc(c: ^Conn) -> i64 {
	return max(0, lua_connection_clock() / 1000 - c.ctime_ms / 1000)
}

client_info_line :: proc(b: ^[dynamic]u8, other: ^Conn, self: ^Conn, argv: [][]u8) {
	sb_str(b, "id=")
	sb_int(b, other.id)
	sb_str(b, " addr=")
	sb_bytes(b, other.addr[:other.addr_len])
	sb_str(b, " laddr=")
	sb_bytes(b, conn_laddr(other))
	sb_str(b, " fd=")
	sb_int(b, i64(other.fd))
	sb_str(b, " name=")
	sb_bytes(b, other.name)
	sb_str(b, " age=")
	sb_int(b, conn_age(other))
	sb_str(b, " idle=")
	sb_int(b, max(0, lua_connection_clock() / 1000 - other.atime_ms / 1000))
	sb_str(b, " flags=")
	nflags := len(b)
	if .Monitor in other.flags {
		sb_byte(b, 'O')
	}
	if .Subscribed in other.ps {
		sb_byte(b, 'P')
	}
	if .Multi in other.txf {
		sb_byte(b, 'x')
	}
	if other.held || other.blocked != .None {
		sb_byte(b, 'b')
	}
	tracking_client_flags(b, other)
	if .Dirty_Cas in other.txf {
		sb_byte(b, 'd')
	}
	if other.close_after {
		sb_byte(b, 'A' if len(acl_doomed) > 0 && acl_is_doomed(other) else 'c')
	}
	if .No_Evict in other.flags {
		sb_byte(b, 'e')
	}
	if .No_Touch in other.flags {
		sb_byte(b, 'T')
	}
	if len(b) == nflags {
		sb_byte(b, 'N')
	}
	sb_str(b, " db=")
	sb_int(b, i64(other.db.id))
	sb_str(b, " sub=")
	sb_int(b, i64(ps_list_len(other, .Channel)))
	sb_str(b, " psub=")
	sb_int(b, i64(ps_list_len(other, .Pattern)))
	sb_str(b, " ssub=")
	sb_int(b, i64(ps_list_len(other, .Shard)))
	tx_client_fields(b, other)
	sb_str(b, " qbuf=")
	sb_int(b, i64(other.rlen))
	sb_str(b, " qbuf-free=")
	sb_int(b, i64(other.rcap - other.rlen))
	argv_mem := 0
	if other == tx_exec_conn {
		argv_mem = tx_exec_argv_mem
	} else if other == self {
		for a in argv {
			argv_mem += len(a)
		}
	}
	multi_mem := tx_multi_mem(other)
	sb_str(b, " argv-mem=")
	sb_int(b, i64(argv_mem))
	sb_str(b, " multi-mem=")
	sb_int(b, i64(multi_mem))
	sb_str(b, " rbs=")
	sb_int(b, i64(other.rcap))
	sb_str(b, " rbp=")
	sb_int(b, i64(other.rpeak))
	sb_str(b, " obl=")
	sb_int(b, i64(other.wlen - other.wpos))
	grown := other.wcap > WBUF_INIT
	sb_str(b, " oll=")
	sb_int(b, 1 if grown else 0)
	sb_str(b, " omem=")
	sb_int(b, i64(other.wcap) if grown else 0)
	sb_str(b, " tot-mem=")
	sb_int(b, i64(size_of(Conn) + other.rcap + other.wcap + request_inline_memory(other) + len(other.name) + len(other.lib_name) + len(other.lib_ver) + multi_mem))
	sb_str(b, " events=")
	sb_str(b, "rw" if other.want_write else "r")
	sb_str(b, " cmd=")
	sb_str(b, "exec" if other == tx_exec_conn else other.last_cmd)
	sb_str(b, " user=")
	sb_str(b, acl_user_name(other))
	sb_str(b, " redir=")
	sb_int(b, tracking_redirect_of(other))
	sb_str(b, " resp=")
	sb_int(b, i64(other.resp))
	sb_str(b, " lib-name=")
	sb_bytes(b, other.lib_name)
	sb_str(b, " lib-ver=")
	sb_bytes(b, other.lib_ver)
	sb_byte(b, '\n')
}

sorted_conns :: proc() -> []^Conn {
	clear(&conn_scratch)
	for other in srv.conns {
		if other != nil {
			append(&conn_scratch, other)
		}
	}
	slice.sort_by(conn_scratch[:], proc(a, b: ^Conn) -> bool {
		return a.id < b.id
	})
	return conn_scratch[:]
}

client_getname :: proc(c: ^Conn, argv: [][]u8) {
	if len(c.name) == 0 {
		reply_null(c)
	} else {
		reply_bulk(c, c.name)
	}
}

client_help :: proc(c: ^Conn, argv: [][]u8) {
	reply_array(c, len(client_help_lines))
	for line in client_help_lines {
		reply_simple(c, line)
	}
}

client_id :: proc(c: ^Conn, argv: [][]u8) {
	reply_int(c, c.id)
}

client_info :: proc(c: ^Conn, argv: [][]u8) {
	clear(&scratch)
	client_info_line(&scratch, c, c, argv)
	reply_verbatim(c, scratch[:])
}

Client_Filter :: struct {
	addr:      []u8,
	laddr:     []u8,
	has_addr:  bool,
	has_laddr: bool,
	id:        i64,
	ctype:     Client_Type,
	skipme:    bool,
	max_age:   i64,
	user:      ^Acl_User,
}

parse_client_filter :: proc(c: ^Conn, argv: [][]u8, f: ^Client_Filter) -> bool {
	n := len(argv)
	for i := 2; i < n; i += 2 {
		a := argv[i]
		if i + 1 >= n {
			reply_error(c, ERR_SYNTAX)
			return false
		}
		v := argv[i + 1]
		switch {
		case eq_nocase(a, "id"):
			x, ok := parse_i64(v)
			if !ok || x < 1 {
				reply_error(c, "ERR client-id should be greater than 0")
				return false
			}
			f.id = x
		case eq_nocase(a, "type"):
			t, ok := parse_client_type(v)
			if !ok {
				reply_error_quoted(c, "ERR Unknown client type '", v, "'")
				return false
			}
			f.ctype = t
		case eq_nocase(a, "addr"):
			f.addr = v
			f.has_addr = true
		case eq_nocase(a, "laddr"):
			f.laddr = v
			f.has_laddr = true
		case eq_nocase(a, "user"):
			f.user = acl_user_find(v)
			if f.user == nil {
				reply_error_quoted(c, "ERR No such user '", v, "'")
				return false
			}
		case eq_nocase(a, "skipme"):
			if eq_nocase(v, "yes") {
				f.skipme = true
			} else if eq_nocase(v, "no") {
				f.skipme = false
			} else {
				reply_error(c, ERR_SYNTAX)
				return false
			}
		case eq_nocase(a, "maxage"):
			x, ok := parse_i64(v)
			if !ok {
				reply_error(c, "ERR maxage is not an integer or out of range")
				return false
			}
			if x <= 0 {
				reply_error(c, "ERR maxage should be greater than 0")
				return false
			}
			f.max_age = x
		case:
			reply_error(c, ERR_SYNTAX)
			return false
		}
	}
	return true
}

client_filter_match :: proc(f: ^Client_Filter, other: ^Conn, self: ^Conn) -> bool {
	if f.has_addr && !bytes_eq(other.addr[:other.addr_len], f.addr) {
		return false
	}
	if f.has_laddr && !bytes_eq(conn_laddr(other), f.laddr) {
		return false
	}
	if f.ctype != .Any && conn_type(other) != f.ctype {
		return false
	}
	if f.id != 0 && other.id != f.id {
		return false
	}
	if f.user != nil && other.user != f.user {
		return false
	}
	if other == self && f.skipme {
		return false
	}
	if f.max_age != 0 && conn_age(other) < f.max_age {
		return false
	}
	return true
}

client_list :: proc(c: ^Conn, argv: [][]u8) {
	n := len(argv)
	clear(&scratch)
	if n == 4 && eq_nocase(argv[2], "type") {
		t, ok := parse_client_type(argv[3])
		if !ok {
			reply_error_quoted(c, "ERR Unknown client type '", argv[3], "'")
			return
		}
		for other in sorted_conns() {
			if conn_type(other) == t {
				client_info_line(&scratch, other, c, argv)
			}
		}
	} else if n > 3 && eq_nocase(argv[2], "id") {
		for i in 3 ..< n {
			id, ok := parse_i64(argv[i])
			if !ok {
				reply_error(c, "ERR Invalid client ID")
				return
			}
			if other := conn_by_id(id); other != nil {
				client_info_line(&scratch, other, c, argv)
			}
		}
	} else {
		f := Client_Filter{}
		if !parse_client_filter(c, argv, &f) {
			return
		}
		for other in sorted_conns() {
			if client_filter_match(&f, other, c) {
				client_info_line(&scratch, other, c, argv)
			}
		}
	}
	reply_verbatim(c, scratch[:])
}

client_kill :: proc(c: ^Conn, argv: [][]u8) {
	f := Client_Filter {
		skipme = true,
	}
	if len(argv) == 3 {
		f.addr = argv[2]
		f.has_addr = true
		f.skipme = false
	} else if !parse_client_filter(c, argv, &f) {
		return
	}
	killed: i64 = 0
	close_self := false
	for i in 0 ..< len(srv.conns) {
		other := srv.conns[i]
		if other == nil || !client_filter_match(&f, other, c) {
			continue
		}
		if other == c {
			close_self = true
		} else {
			conn_kill(other)
		}
		killed += 1
	}
	if close_self {
		c.close_after = true
	}
	if len(argv) == 3 {
		if killed == 0 {
			reply_error(c, "ERR No such client")
		} else {
			reply_ok(c)
		}
	} else {
		reply_int(c, killed)
	}
}

parse_on_off :: proc(c: ^Conn, v: []u8) -> (on: bool, ok: bool) {
	if eq_nocase(v, "on") {
		return true, true
	}
	if eq_nocase(v, "off") {
		return false, true
	}
	reply_error(c, ERR_SYNTAX)
	return false, false
}

client_no_evict :: proc(c: ^Conn, argv: [][]u8) {
	on, ok := parse_on_off(c, argv[2])
	if !ok {
		return
	}
	if on {
		c.flags += {.No_Evict}
		c.ev_bucket = 0
	} else {
		c.flags -= {.No_Evict}
	}
	reply_ok(c)
}

client_no_touch :: proc(c: ^Conn, argv: [][]u8) {
	on, ok := parse_on_off(c, argv[2])
	if !ok {
		return
	}
	if on {
		c.flags += {.No_Touch}
	} else {
		c.flags -= {.No_Touch}
	}
	reply_ok(c)
}

client_pause :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) > 4 {
		reply_subcommand_syntax(c, argv)
		return
	}
	all := true
	if len(argv) == 4 {
		if eq_nocase(argv[3], "write") {
			all = false
		} else if !eq_nocase(argv[3], "all") {
			reply_error(c, "ERR CLIENT PAUSE mode must be WRITE or ALL")
			return
		}
	}
	t, ok := parse_i64(argv[2])
	if !ok {
		reply_error(c, "ERR timeout is not an integer or out of range")
		return
	}
	if t < 0 {
		reply_error(c, "ERR timeout is negative")
		return
	}
	end: i64 = 0
	if t > 0 {
		if t > I64_MAX - srv.now_ms {
			reply_error(c, "ERR timeout is out of range")
			return
		}
		end = srv.now_ms + t
	}
	pause_clients(end, all)
	reply_ok(c)
}

client_unpause :: proc(c: ^Conn, argv: [][]u8) {
	pause_clear()
	reply_ok(c)
}

client_reply :: proc(c: ^Conn, argv: [][]u8) {
	v := argv[2]
	switch {
	case eq_nocase(v, "on"):
		c.reply -= {.Off, .Skip}
		reply_ok(c)
	case eq_nocase(v, "off"):
		c.reply += {.Off}
	case eq_nocase(v, "skip"):
		if .Off not_in c.reply {
			c.reply += {.Skip_Next}
		}
	case:
		reply_error(c, ERR_SYNTAX)
	}
}

client_setinfo :: proc(c: ^Conn, argv: [][]u8) {
	attr := argv[2]
	dst: ^[]u8
	if eq_nocase(attr, "lib-name") {
		dst = &c.lib_name
	} else if eq_nocase(attr, "lib-ver") {
		dst = &c.lib_ver
	} else {
		reply_error_quoted(c, "ERR Unrecognized option '", attr, "'")
		return
	}
	if !valid_client_name(argv[3]) {
		reply_error_quoted(c, "ERR ", attr, " cannot contain spaces, newlines or special characters.")
		return
	}
	set_conn_string(dst, argv[3])
	reply_ok(c)
}

client_setname :: proc(c: ^Conn, argv: [][]u8) {
	if !valid_client_name(argv[2]) {
		reply_error(c, ERR_CLIENT_NAME)
		return
	}
	set_conn_string(&c.name, argv[2])
	reply_ok(c)
}

client_unblock :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) > 4 {
		reply_subcommand_syntax(c, argv)
		return
	}
	if len(argv) == 4 && !eq_nocase(argv[3], "timeout") && !eq_nocase(argv[3], "error") {
		reply_error(c, "ERR CLIENT UNBLOCK reason should be TIMEOUT or ERROR")
		return
	}
	id, ok := parse_i64(argv[2])
	if !ok {
		reply_error(c, ERR_NOT_INT)
		return
	}
	target := conn_by_id(id)
	if target == nil || target.blocked == .None || target.blocked == .Lazyfree {
		reply_int(c, 0)
		return
	}
	if len(argv) == 4 && eq_nocase(argv[3], "error") {
		block_unblock_error(target, ERR_UNBLOCKED)
	} else {
		block_unblock_timeout(target)
	}
	reply_int(c, 1)
}

Client_Subcommand :: struct {
	name:    string,
	full:    string,
	arity:   int,
	handler: Command_Proc,
}

@(private = "file")
client_subcommands := [?]Client_Subcommand {
	{"caching", "client|caching", 3, client_caching},
	{"getname", "client|getname", 2, client_getname},
	{"getredir", "client|getredir", 2, client_getredir},
	{"help", "client|help", 2, client_help},
	{"id", "client|id", 2, client_id},
	{"info", "client|info", 2, client_info},
	{"kill", "client|kill", -3, client_kill},
	{"list", "client|list", -2, client_list},
	{"no-evict", "client|no-evict", 3, client_no_evict},
	{"no-touch", "client|no-touch", 3, client_no_touch},
	{"pause", "client|pause", -3, client_pause},
	{"reply", "client|reply", 3, client_reply},
	{"setinfo", "client|setinfo", 4, client_setinfo},
	{"setname", "client|setname", 3, client_setname},
	{"unblock", "client|unblock", -3, client_unblock},
	{"unpause", "client|unpause", 2, client_unpause},
	{"tracking", "client|tracking", -3, client_tracking},
	{"trackinginfo", "client|trackinginfo", 2, client_trackinginfo},
}

arity_ok :: proc(arity: int, n: int) -> bool {
	return (arity > 0 && n == arity) || (arity < 0 && n >= -arity)
}

find_client_subcommand :: proc(sub: []u8) -> ^Client_Subcommand {
	for &s in client_subcommands {
		if eq_nocase(sub, s.name) {
			return &s
		}
	}
	return nil
}

cmd_client :: proc(c: ^Conn, argv: [][]u8) {
	s := find_client_subcommand(argv[1])
	if s == nil {
		c.last_cmd = "NULL"
		reply_unknown_subcommand(c, argv[1], "CLIENT")
		return
	}
	c.last_cmd = s.full
	if !arity_ok(s.arity, len(argv)) {
		reply_wrong_args(c, s.full)
		return
	}
	s.handler(c, argv)
}

pause_should_hold :: proc(c: ^Conn, argv: [][]u8) -> bool {
	if srv.now_ms >= srv.pause_end_ms {
		pause_clear()
		return false
	}
	if .Monitor in c.flags {
		return false
	}
	cmd := lookup_command(argv[0])
	if cmd == nil || !arity_ok(cmd.arity, len(argv)) || pubsub_rejects(c, cmd) {
		return false
	}
	full := cmd.name
	if cmd.name == "client" {
		s := find_client_subcommand(argv[1])
		if s == nil || !arity_ok(s.arity, len(argv)) {
			return false
		}
		full = s.full
	}
	if !srv.pause_all {
		if cmd.handler == cmd_exec && .Multi in c.txf {
			if !tx_may_replicate(c) {
				return false
			}
		} else if !is_write_command(cmd.name, argv) {
			return false
		}
	}
	c.last_cmd = full
	return true
}

is_write_command :: proc(name: string, argv: [][]u8) -> bool {
	switch name {
	case "append", "bitfield", "bitop", "blmove", "blmpop", "blpop", "brpop", "brpoplpush",
		"bzmpop", "bzpopmax", "bzpopmin", "copy", "decr", "decrby", "del", "eval",
		"evalsha", "expire", "expireat", "fcall", "flushall", "flushdb", "geoadd", "georadius",
		"georadiusbymember", "geosearchstore", "getdel", "getex", "getset", "hdel", "hexpire", "hexpireat",
		"hincrby", "hincrbyfloat", "hmset", "hpersist", "hpexpire", "hpexpireat", "hset", "hsetnx",
		"incr", "incrby", "incrbyfloat", "linsert", "lmove", "lmpop", "lpop", "lpush",
		"lpushx", "lrem", "lset", "ltrim", "migrate", "move", "mset", "msetnx",
		"persist", "pexpire", "pexpireat", "pfadd", "pfcount", "pfdebug", "pfmerge", "psetex",
		"publish", "rename", "renamenx", "restore", "restore-asking", "rpop", "rpoplpush", "rpush",
		"rpushx", "sadd", "sdiffstore", "set", "setbit", "setex", "setnx", "setrange",
		"sinterstore", "smove", "sort", "spop", "spublish", "srem", "sunionstore", "swapdb",
		"unlink", "xack", "xadd", "xautoclaim", "xclaim", "xdel", "xreadgroup", "xsetid",
		"xtrim", "zadd", "zdiffstore", "zincrby", "zinterstore", "zmpop", "zpopmax", "zpopmin",
		"zrangestore", "zrem", "zremrangebylex", "zremrangebyrank", "zremrangebyscore", "zunionstore":
		return true
	case "function":
		if len(argv) < 2 {
			return false
		}
		sub := argv[1]
		return eq_nocase(sub, "delete") || eq_nocase(sub, "flush") || eq_nocase(sub, "load") || eq_nocase(sub, "restore")
	case "script":
		if len(argv) < 2 {
			return false
		}
		sub := argv[1]
		return eq_nocase(sub, "flush") || eq_nocase(sub, "load")
	case "xgroup":
		if len(argv) < 2 {
			return false
		}
		sub := argv[1]
		return eq_nocase(sub, "create") || eq_nocase(sub, "createconsumer") || eq_nocase(sub, "delconsumer") || eq_nocase(sub, "destroy") || eq_nocase(sub, "setid")
	}
	return false
}

@(private = "file")
client_help_lines := [?]string {
	"CLIENT <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"CACHING (YES|NO)",
	"    Enable/disable tracking of the keys for next command in OPTIN/OPTOUT modes.",
	"GETREDIR",
	"    Return the client ID we are redirecting to when tracking is enabled.",
	"GETNAME",
	"    Return the name of the current connection.",
	"ID",
	"    Return the ID of the current connection.",
	"INFO",
	"    Return information about the current client connection.",
	"KILL <ip:port>",
	"    Kill connection made from <ip:port>.",
	"KILL <option> <value> [<option> <value> [...]]",
	"    Kill connections. Options are:",
	"    * ADDR (<ip:port>|<unixsocket>:0)",
	"      Kill connections made from the specified address",
	"    * LADDR (<ip:port>|<unixsocket>:0)",
	"      Kill connections made to specified local address",
	"    * TYPE (NORMAL|MASTER|REPLICA|PUBSUB)",
	"      Kill connections by type.",
	"    * USER <username>",
	"      Kill connections authenticated by <username>.",
	"    * SKIPME (YES|NO)",
	"      Skip killing current connection (default: yes).",
	"    * ID <client-id>",
	"      Kill connections by client id.",
	"    * MAXAGE <maxage>",
	"      Kill connections older than the specified age.",
	"LIST [options ...]",
	"    Return information about client connections. Options:",
	"    * TYPE (NORMAL|MASTER|REPLICA|PUBSUB)",
	"      Return clients of specified type.",
	"UNPAUSE",
	"    Stop the current client pause, resuming traffic.",
	"PAUSE <timeout> [WRITE|ALL]",
	"    Suspend all, or just write, clients for <timeout> milliseconds.",
	"REPLY (ON|OFF|SKIP)",
	"    Control the replies sent to the current connection.",
	"SETNAME <name>",
	"    Assign the name <name> to the current connection.",
	"SETINFO <option> <value>",
	"    Set client meta attr. Options are:",
	"    * LIB-NAME: the client lib name.",
	"    * LIB-VER: the client lib version.",
	"UNBLOCK <clientid> [TIMEOUT|ERROR]",
	"    Unblock the specified blocked client.",
	"TRACKING (ON|OFF) [REDIRECT <id>] [BCAST] [PREFIX <prefix> [...]]",
	"         [OPTIN] [OPTOUT] [NOLOOP]",
	"    Control server assisted client side caching.",
	"TRACKINGINFO",
	"    Report tracking status for the current connection.",
	"NO-EVICT (ON|OFF)",
	"    Protect current client connection from eviction.",
	"NO-TOUCH (ON|OFF)",
	"    Will not touch LRU/LFU stats when this mode is on.",
	"HELP",
	"    Print this help.",
}

@(private = "file")
connection_commands := [?]Command {
	{"ping", cmd_ping, -1},
	{"echo", cmd_echo, 2},
	{"select", cmd_select, 2},
	{"quit", cmd_quit, -1},
	{"hello", cmd_hello, -1},
	{"client", cmd_client, -2},
	{"auth", cmd_auth, -2},
	{"reset", cmd_reset, 1},
}

@(init)
register_connection_commands :: proc "contextless" () {
	register_commands(connection_commands[:])
}

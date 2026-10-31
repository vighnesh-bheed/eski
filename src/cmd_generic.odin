package main

@(private = "file")
ERR_WRONGTYPE_GENERIC :: "WRONGTYPE Operation against a key holding the wrong kind of value"

@(private = "file")
ERR_SAME_OBJECT :: "ERR source and destination objects are the same"

@(private = "file")
ERR_UNKNOWN_TYPE_OBJECT :: "ERR unknown type object"

@(private = "file")
ERR_LFU_NOT_SELECTED :: "ERR An LFU maxmemory policy is not selected, access frequency not tracked. Please note that when switching between policies at runtime LRU and LFU data will take some time to adjust."

@(private = "file")
ERR_LFU_SELECTED :: "ERR An LFU maxmemory policy is selected, idle time not tracked. Please note that when switching between policies at runtime LRU and LFU data will take some time to adjust."

OBJ_SHARED_REFCOUNT :: 2147483647

@(cold)
reply_invalid_expire :: #force_no_inline proc(c: ^Conn, name: string) {
	reply_error_parts(c, "ERR invalid expire time in '", name, "' command")
}

@(private = "file")
generic_cstr :: proc "contextless" (s: []u8) -> []u8 {
	for b, i in s {
		if b == 0 {
			return s[:i]
		}
	}
	return s
}

@(private = "file")
generic_reply_error_arg :: proc(c: ^Conn, prefix: string, arg: []u8) {
	clear(&scratch)
	sb_str(&scratch, prefix)
	sb_bytes(&scratch, generic_cstr(arg))
	for len(scratch) > 0 && (scratch[len(scratch) - 1] == '\r' || scratch[len(scratch) - 1] == '\n') {
		pop(&scratch)
	}
	sanitize_scratch()
	reply_error_bytes(c, scratch[:])
}

Expire_Unit :: enum u8 {
	Sec,
	Ms,
	Unix_Sec,
	Unix_Ms,
}

expire_to_abs_ms :: proc(v: i64, unit: Expire_Unit) -> (at: i64, ok: bool) {
	ms := v
	if unit == .Sec || unit == .Unix_Sec {
		if v > I64_MAX / 1000 || v < I64_MIN / 1000 {
			return 0, false
		}
		ms = v * 1000
	}
	if unit == .Sec || unit == .Ms {
		if ms > I64_MAX - srv.now_ms {
			return 0, false
		}
		ms += srv.now_ms
	}
	return ms, true
}

cmd_del :: proc(c: ^Conn, argv: [][]u8) {
	del_generic(c, argv, cfg.lazyfree_lazy_user_del)
}

cmd_unlink :: proc(c: ^Conn, argv: [][]u8) {
	del_generic(c, argv, true)
}

@(private = "file")
del_generic :: proc(c: ^Conn, argv: [][]u8, lazy: bool) {
	pst.dirty_explicit = true
	saved := lazy_set(lazy)
	defer lazy_mode = saved
	count: i64 = 0
	for i in 1 ..< len(argv) {
		found, expired := db_remove(argv[i])
		if found {
			if expired {
				srv.stat_expired += 1
				key_expired_event(argv[i], db_cur)
			} else {
				count += 1
				signal_key(argv[i])
				notify(.Generic, "del", argv[i])
			}
		}
	}
	pst.dirty += count
	reply_int(c, count)
}

cmd_exists :: proc(c: ^Conn, argv: [][]u8) {
	count: i64 = 0
	for i in 1 ..< len(argv) {
		if db_find_read_notouch(argv[i]) != nil {
			count += 1
		}
	}
	reply_int(c, count)
}

cmd_type :: proc(c: ^Conn, argv: [][]u8) {
	e := db_find_read_notouch(argv[1])
	if e == nil {
		reply_simple(c, "none")
		return
	}
	reply_simple(c, type_name(entry_type(e)))
}

@(private = "file")
expire_parse_flags :: proc(c: ^Conn, argv: [][]u8) -> (nx, xx, gt, lt: bool, ok: bool) {
	for i in 3 ..< len(argv) {
		a := argv[i]
		switch {
		case eq_nocase(a, "nx"):
			nx = true
		case eq_nocase(a, "xx"):
			xx = true
		case eq_nocase(a, "gt"):
			gt = true
		case eq_nocase(a, "lt"):
			lt = true
		case:
			generic_reply_error_arg(c, "ERR Unsupported option ", a)
			return
		}
	}
	if nx && (xx || gt || lt) {
		reply_error(c, "ERR NX and XX, GT or LT options at the same time are not compatible")
		return
	}
	if gt && lt {
		reply_error(c, "ERR GT and LT options at the same time are not compatible")
		return
	}
	ok = true
	return
}

expire_generic :: proc(c: ^Conn, argv: [][]u8, unit: Expire_Unit, name: string) {
	pst.dirty_explicit = true
	nx, xx, gt, lt, flags_ok := expire_parse_flags(c, argv)
	if !flags_ok {
		return
	}
	when_ms, ok := parse_i64(argv[2])
	if !ok {
		reply_error(c, ERR_NOT_INT)
		return
	}
	if unit == .Sec || unit == .Unix_Sec {
		if when_ms > I64_MAX / 1000 || when_ms < I64_MIN / 1000 {
			reply_invalid_expire(c, name)
			return
		}
		when_ms *= 1000
	}
	base: i64 = 0
	if unit == .Sec || unit == .Ms {
		base = srv.now_ms
	}
	if when_ms > I64_MAX - base {
		reply_invalid_expire(c, name)
		return
	}
	when_ms += base
	e := db_find(argv[1])
	if e == nil {
		reply_int(c, 0)
		return
	}
	current := e.expire_at if e.expire_at != 0 else -1
	if nx && current != -1 {
		reply_int(c, 0)
		return
	}
	if xx && current == -1 {
		reply_int(c, 0)
		return
	}
	if gt && (when_ms <= current || current == -1) {
		reply_int(c, 0)
		return
	}
	if lt && current != -1 && when_ms >= current {
		reply_int(c, 0)
		return
	}
	pst.dirty += 1
	if when_ms <= expire_now() {
		db_remove(argv[1])
		signal_key(argv[1])
		notify(.Generic, "del", argv[1])
		reply_int(c, 1)
		return
	}
	entry_set_expire(e, when_ms)
	reply_int(c, 1)
	signal_key(argv[1])
	notify(.Generic, "expire", argv[1])
}

cmd_expire :: proc(c: ^Conn, argv: [][]u8) {
	expire_generic(c, argv, .Sec, "expire")
}

cmd_pexpire :: proc(c: ^Conn, argv: [][]u8) {
	expire_generic(c, argv, .Ms, "pexpire")
}

cmd_expireat :: proc(c: ^Conn, argv: [][]u8) {
	expire_generic(c, argv, .Unix_Sec, "expireat")
}

cmd_pexpireat :: proc(c: ^Conn, argv: [][]u8) {
	expire_generic(c, argv, .Unix_Ms, "pexpireat")
}

ttl_generic :: proc(c: ^Conn, argv: [][]u8, ms: bool, absolute: bool) {
	e := db_find_read_notouch(argv[1])
	if e == nil {
		reply_int(c, -2)
		return
	}
	if e.expire_at == 0 {
		reply_int(c, -1)
		return
	}
	ttl := e.expire_at if absolute else e.expire_at - srv.now_ms
	if ttl < 0 {
		ttl = 0
	}
	if ms {
		reply_int(c, ttl)
	} else {
		reply_int(c, (ttl + 500) / 1000)
	}
}

cmd_ttl :: proc(c: ^Conn, argv: [][]u8) {
	ttl_generic(c, argv, false, false)
}

cmd_pttl :: proc(c: ^Conn, argv: [][]u8) {
	ttl_generic(c, argv, true, false)
}

cmd_expiretime :: proc(c: ^Conn, argv: [][]u8) {
	ttl_generic(c, argv, false, true)
}

cmd_pexpiretime :: proc(c: ^Conn, argv: [][]u8) {
	ttl_generic(c, argv, true, true)
}

cmd_persist :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	e := db_find(argv[1])
	if e == nil || e.expire_at == 0 {
		reply_int(c, 0)
		return
	}
	pst.dirty += 1
	entry_set_expire(e, 0)
	signal_key(argv[1])
	notify(.Generic, "persist", argv[1])
	reply_int(c, 1)
}

cmd_touch :: proc(c: ^Conn, argv: [][]u8) {
	count: i64 = 0
	for i in 1 ..< len(argv) {
		if db_find_read(argv[i]) != nil {
			count += 1
		}
	}
	reply_int(c, count)
}

@(private = "file")
rename_generic :: proc(c: ^Conn, argv: [][]u8, nx: bool) {
	pst.dirty_explicit = true
	same := bytes_eq(argv[1], argv[2])
	if db_find(argv[1]) == nil {
		reply_error(c, ERR_NO_KEY)
		return
	}
	if same {
		if nx {
			reply_int(c, 0)
		} else {
			reply_ok(c)
		}
		return
	}
	if db_find(argv[2]) != nil {
		if nx {
			reply_int(c, 0)
			return
		}
		db_remove(argv[2])
	}
	db_rename(argv[1], argv[2])
	pst.dirty += 1
	hash_rename(argv[2])
	block_note_removed()
	if e := db_find_notouch(argv[2]); e != nil {
		entry_access_init(e)
		block_signal_key(c.db, argv[2], entry_type(e))
	}
	signal_key(argv[1])
	signal_key(argv[2])
	notify(.Generic, "rename_from", argv[1])
	notify(.Generic, "rename_to", argv[2])
	if nx {
		reply_int(c, 1)
	} else {
		reply_ok(c)
	}
}

cmd_rename :: proc(c: ^Conn, argv: [][]u8) {
	rename_generic(c, argv, false)
}

cmd_renamenx :: proc(c: ^Conn, argv: [][]u8) {
	rename_generic(c, argv, true)
}

copy_object_dup :: proc(src: ^Entry) -> (obj: rawptr, extra: u64, ok: bool) {
	#partial switch entry_type(src) {
	case .Hash:
		return hash_copy_dup(src)
	case .Set:
		return set_copy_dup(src)
	case .List:
		return list_copy_dup(src)
	case .Zset:
		return zset_copy_dup(src)
	case .Stream:
		return stream_copy_dup(src)
	}
	return nil, 0, false
}

copy_object_attach :: proc(dst: ^Entry, key: []u8, kind: Obj_Type, obj: rawptr, extra: u64) {
	#partial switch kind {
	case .Hash:
		hash_copy_attach(dst, key, obj, extra)
	case .Set:
		set_copy_attach(dst, obj)
	case .List:
		list_copy_attach(dst, obj)
	case .Zset:
		zset_copy_attach(dst, key, obj, extra)
	case .Stream:
		stream_copy_attach(dst, obj)
	}
}

@(private = "file")
fresh_access_clock :: proc(db: ^Db, key: []u8) {
	saved := store_no_touch
	store_no_touch = true
	if e := db_find_in(db, key); e != nil {
		entry_access_init(e)
	}
	store_no_touch = saved
}

cmd_move :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	id, ok := parse_db_index(c, argv[2], "")
	if !ok {
		return
	}
	if !db_index_valid(id) {
		reply_error(c, ERR_DB_RANGE)
		return
	}
	dst := &dbs[id]
	if dst == c.db {
		reply_error(c, "ERR source and destination objects are the same")
		return
	}
	if !db_move(c.db, dst, argv[1]) {
		reply_int(c, 0)
		return
	}
	pst.dirty += 1
	fresh_access_clock(dst, argv[1])
	block_signal_existing(dst, argv[1])
	block_note_removed()
	signal_key_in(argv[1], c.db)
	signal_key_in(argv[1], dst)
	notify_in(.Generic, "move_from", argv[1], c.db)
	notify_in(.Generic, "move_to", argv[1], dst)
	reply_int(c, 1)
}

cmd_randomkey :: proc(c: ^Conn, argv: [][]u8) {
	k, ok := db_random_key()
	if !ok {
		reply_null(c)
		return
	}
	reply_bulk_str(c, k)
}

cmd_keys :: proc(c: ^Conn, argv: [][]u8) {
	pat := argv[1]
	all := len(pat) == 1 && pat[0] == '*'
	db_keys(pat, all)
	reply_array(c, len(key_scratch))
	for k in key_scratch {
		reply_bulk_str(c, k)
	}
	if cap(key_scratch) > 65536 {
		delete(key_scratch)
		key_scratch = make([dynamic]string, 0, 256)
	}
}

scan_parse_cursor :: proc(arg: []u8) -> (cursor: u64, ok: bool) #no_bounds_check {
	s := generic_cstr(arg)
	if v, is_ll := parse_i64(s); is_ll {
		if v < 0 {
			return 0, false
		}
		return u64(v), true
	}
	n := len(s)
	if n == 0 {
		return 0, false
	}
	i := 0
	for i < n && (s[i] == ' ' || (s[i] >= '\t' && s[i] <= '\r')) {
		i += 1
	}
	neg := false
	if i < n && (s[i] == '+' || s[i] == '-') {
		neg = s[i] == '-'
		i += 1
	}
	digits := 0
	v: u64 = 0
	for i < n && s[i] >= '0' && s[i] <= '9' {
		d := u64(s[i] - '0')
		if v > (max(u64) - d) / 10 {
			return 0, false
		}
		v = v * 10 + d
		digits += 1
		i += 1
	}
	if digits == 0 || i != n {
		return 0, false
	}
	if neg {
		v = 0 - v
	}
	return v, true
}

obj_type_by_name :: proc(name: []u8) -> (t: Obj_Type, ok: bool) {
	s := generic_cstr(name)
	for candidate in Obj_Type {
		if eq_nocase(s, type_name(candidate)) {
			return candidate, true
		}
	}
	return .String, false
}

cmd_scan :: proc(c: ^Conn, argv: [][]u8) #no_bounds_check {
	cursor, cursor_ok := scan_parse_cursor(argv[1])
	if !cursor_ok {
		reply_error(c, "ERR invalid cursor")
		return
	}
	pat: []u8
	use_pattern := false
	count: i64 = 10
	has_type := false
	want: Obj_Type
	known := false
	i := 2
	for i < len(argv) {
		j := len(argv) - i
		a := argv[i]
		if eq_nocase(a, "count") && j >= 2 {
			v, ok := parse_i64(argv[i + 1])
			if !ok {
				reply_error(c, ERR_NOT_INT)
				return
			}
			if v < 1 {
				reply_error(c, ERR_SYNTAX)
				return
			}
			count = v
			i += 2
		} else if eq_nocase(a, "match") && j >= 2 {
			pat = argv[i + 1]
			use_pattern = !(len(pat) == 1 && pat[0] == '*')
			i += 2
		} else if eq_nocase(a, "type") && j >= 2 {
			has_type = true
			want, known = obj_type_by_name(argv[i + 1])
			i += 2
		} else if eq_nocase(a, "novalues") {
			reply_error(c, "ERR NOVALUES option can only be used in HSCAN")
			return
		} else {
			reply_error(c, ERR_SYNTAX)
			return
		}
	}
	next := db_scan(cursor, count, pat, use_pattern, true)
	if has_type {
		kept := 0
		for k in key_scratch {
			e := db_find_read_notouch(transmute([]u8)k)
			if known && e != nil && entry_type(e) == want {
				key_scratch[kept] = k
				kept += 1
			}
		}
		resize(&key_scratch, kept)
	}
	reply_array(c, 2)
	reply_bulk_int(c, i64(next))
	reply_array(c, len(key_scratch))
	for k in key_scratch {
		reply_bulk_str(c, k)
	}
	db_scan_purge_expired(has_type)
}

@(private = "file")
object_help := [?]string {
	"OBJECT <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"ENCODING <key>",
	"    Return the kind of internal representation used in order to store the value",
	"    associated with a <key>.",
	"FREQ <key>",
	"    Return the access frequency index of the <key>. The returned integer is",
	"    proportional to the logarithm of the recent access frequency of the key.",
	"IDLETIME <key>",
	"    Return the idle time of the <key>, that is the approximated number of",
	"    seconds elapsed since the last access to the key.",
	"REFCOUNT <key>",
	"    Return the number of references of the value associated with the specified",
	"    <key>.",
	"HELP",
	"    Print this help.",
}

@(private = "file")
object_lookup :: proc(c: ^Conn, argv: [][]u8, name: string) -> ^Entry {
	if len(argv) != 3 {
		reply_wrong_args(c, name)
		return nil
	}
	e := db_find_read_notouch(argv[2])
	if e == nil {
		reply_null(c)
	}
	return e
}

cmd_object :: proc(c: ^Conn, argv: [][]u8) {
	sub := argv[1]
	switch {
	case eq_nocase(sub, "help"):
		if len(argv) != 2 {
			reply_wrong_args(c, "object|help")
			return
		}
		reply_array(c, len(object_help))
		for line in object_help {
			reply_simple(c, line)
		}
	case eq_nocase(sub, "encoding"):
		if e := object_lookup(c, argv, "object|encoding"); e != nil {
			reply_bulk_str(c, entry_encoding(e))
		}
	case eq_nocase(sub, "freq"):
		e := object_lookup(c, argv, "object|freq")
		if e == nil {
			return
		}
		if !lfu_policy {
			reply_error(c, ERR_LFU_NOT_SELECTED)
			return
		}
		reply_int(c, entry_lfu_value(e))
	case eq_nocase(sub, "idletime"):
		e := object_lookup(c, argv, "object|idletime")
		if e == nil {
			return
		}
		if lfu_policy {
			reply_error(c, ERR_LFU_SELECTED)
			return
		}
		reply_int(c, entry_idle_seconds(e))
	case eq_nocase(sub, "refcount"):
		if e := object_lookup(c, argv, "object|refcount"); e != nil {
			reply_int(c, OBJ_SHARED_REFCOUNT if entry_shared_integer(e) else 1)
		}
	case:
		reply_unknown_subcommand(c, sub, "OBJECT")
	}
}

@(private = "file")
wait_timeout_ok :: proc(c: ^Conn, arg: []u8) -> bool {
	v, ok := parse_i64(arg)
	if !ok {
		reply_error(c, "ERR timeout is not an integer or out of range")
		return false
	}
	if v < 0 {
		reply_error(c, "ERR timeout is negative")
		return false
	}
	if v > 0 && v > I64_MAX - srv.now_ms {
		reply_error(c, "ERR timeout is out of range")
		return false
	}
	return true
}

cmd_wait :: proc(c: ^Conn, argv: [][]u8) {
	if _, ok := parse_i64(argv[1]); !ok {
		reply_error(c, ERR_NOT_INT)
		return
	}
	if !wait_timeout_ok(c, argv[2]) {
		return
	}
	reply_int(c, 0)
}

cmd_waitaof :: proc(c: ^Conn, argv: [][]u8) {
	numlocal, ok := parse_i64(argv[1])
	if !ok {
		reply_error(c, ERR_NOT_INT)
		return
	}
	if numlocal < 0 || numlocal > 1 {
		reply_error(c, "ERR value is out of range, value must between 0 and 1")
		return
	}
	numreplicas, ok2 := parse_i64(argv[2])
	if !ok2 || numreplicas < 0 {
		reply_error(c, "ERR value is out of range, must be positive")
		return
	}
	if !wait_timeout_ok(c, argv[3]) {
		return
	}
	if numlocal != 0 && aof.state != .On {
		reply_error(c, "ERR WAITAOF cannot be used when numlocal is set but appendonly is disabled.")
		return
	}
	acked: i64 = 0
	if aof.state == .On {
		aof_fsync_sync()
		acked = 1
	}
	reply_array(c, 2)
	reply_int(c, acked)
	reply_int(c, 0)
}

@(private = "file")
generic_commands := [?]Command {
	{"del", cmd_del, -2},
	{"unlink", cmd_unlink, -2},
	{"exists", cmd_exists, -2},
	{"type", cmd_type, 2},
	{"expire", cmd_expire, -3},
	{"pexpire", cmd_pexpire, -3},
	{"expireat", cmd_expireat, -3},
	{"pexpireat", cmd_pexpireat, -3},
	{"expiretime", cmd_expiretime, 2},
	{"pexpiretime", cmd_pexpiretime, 2},
	{"ttl", cmd_ttl, 2},
	{"pttl", cmd_pttl, 2},
	{"persist", cmd_persist, 2},
	{"touch", cmd_touch, -2},
	{"rename", cmd_rename, 3},
	{"renamenx", cmd_renamenx, 3},
	{"copy", cmd_copy, -3},
	{"move", cmd_move, 3},
	{"randomkey", cmd_randomkey, 1},
	{"keys", cmd_keys, 2},
	{"scan", cmd_scan, -2},
	{"object", cmd_object, -2},
	{"sort", cmd_sort, -2},
	{"sort_ro", cmd_sort_ro, -2},
	{"wait", cmd_wait, 3},
	{"waitaof", cmd_waitaof, 4},
}

@(init)
register_generic_commands :: proc "contextless" () {
	register_commands(generic_commands[:])
}

package main

import "base:intrinsics"

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
Expire_Condition :: enum u8 {
	Nx,
	Xx,
	Gt,
	Lt,
}

@(private = "file")
Expire_Conditions :: bit_set[Expire_Condition;u8]

@(private = "file")
expire_condition_named :: proc(word: []u8) -> (cond: Expire_Condition, known: bool) {
	spellings := [Expire_Condition]string {
		.Nx = "nx",
		.Xx = "xx",
		.Gt = "gt",
		.Lt = "lt",
	}
	for spelling, candidate in spellings {
		if eq_nocase(word, spelling) {
			return candidate, true
		}
	}
	return
}

@(private = "file")
expire_parse_flags :: proc(c: ^Conn, options: [][]u8) -> (conds: Expire_Conditions, ok: bool) {
	for word in options {
		cond, known := expire_condition_named(word)
		if !known {
			generic_reply_error_arg(c, "ERR Unsupported option ", word)
			return
		}
		conds += {cond}
	}
	if .Nx in conds && conds != {.Nx} {
		reply_error(c, "ERR NX and XX, GT or LT options at the same time are not compatible")
		return
	}
	if .Gt in conds && .Lt in conds {
		reply_error(c, "ERR GT and LT options at the same time are not compatible")
		return
	}
	return conds, true
}

@(private = "file")
expire_conditions_met :: proc(conds: Expire_Conditions, current: i64, proposed: i64) -> bool {
	persistent := current == 0
	switch {
	case .Nx in conds && !persistent:
		return false
	case .Xx in conds && persistent:
		return false
	case .Gt in conds && (persistent || proposed <= current):
		return false
	case .Lt in conds && !persistent && proposed >= current:
		return false
	}
	return true
}

@(private = "file")
Expire_Deadline_Error :: enum u8 {
	None,
	Not_Integer,
	Out_Of_Range,
}

@(private = "file")
expire_deadline :: proc(arg: []u8, unit: Expire_Unit) -> (at: i64, err: Expire_Deadline_Error) {
	amount, numeric := parse_i64(arg)
	if !numeric {
		return 0, .Not_Integer
	}
	in_seconds := unit == .Sec || unit == .Unix_Sec
	relative := unit == .Sec || unit == .Ms
	scaled, scale_overflow := intrinsics.overflow_mul(amount, i64(1000) if in_seconds else 1)
	if scale_overflow {
		return 0, .Out_Of_Range
	}
	shifted, shift_overflow := intrinsics.overflow_add(scaled, srv.now_ms if relative else 0)
	if shift_overflow {
		return 0, .Out_Of_Range
	}
	return shifted, .None
}

@(private = "file")
expire_install :: proc(c: ^Conn, e: ^Entry, key: []u8, at: i64) {
	pst.dirty += 1
	entry_set_expire(e, at)
	reply_int(c, 1)
	signal_key(key)
	notify(.Generic, "expire", key)
}

@(private = "file")
expire_delete_elapsed :: proc(c: ^Conn, key: []u8) {
	pst.dirty += 1
	db_remove(key)
	signal_key(key)
	notify(.Generic, "del", key)
	reply_int(c, 1)
}

expire_generic :: proc(c: ^Conn, argv: [][]u8, unit: Expire_Unit, name: string) {
	pst.dirty_explicit = true
	key := argv[1]
	conds, conds_ok := expire_parse_flags(c, argv[3:])
	if !conds_ok {
		return
	}
	at, problem := expire_deadline(argv[2], unit)
	switch problem {
	case .Not_Integer:
		reply_error(c, ERR_NOT_INT)
		return
	case .Out_Of_Range:
		reply_invalid_expire(c, name)
		return
	case .None:
	}
	e := db_find(key)
	switch {
	case e == nil || !expire_conditions_met(conds, e.expire_at, at):
		reply_int(c, 0)
	case at > expire_now():
		expire_install(c, e, key, at)
	case:
		expire_delete_elapsed(c, key)
	}
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
rename_relocate :: proc(c: ^Conn, src, dst: []u8, overwrite: bool) {
	if overwrite {
		db_remove(dst)
	}
	if labels_on {
		label_vset_detach_key(cur_db(), src)
	}
	db_rename(src, dst)
	pst.dirty += 1
	hash_rename(dst)
	block_note_removed()
	moved := db_find_notouch(dst)
	if moved != nil {
		entry_access_init(moved)
		block_signal_key(cur_db(), dst, entry_type(moved))
	}
}

@(private = "file")
rename_announce :: proc(src, dst: []u8) {
	signal_key(src)
	signal_key(dst)
	notify(.Generic, "rename_from", src)
	notify(.Generic, "rename_to", dst)
}

@(private = "file")
rename_generic :: proc(c: ^Conn, argv: [][]u8, nx: bool) {
	pst.dirty_explicit = true
	src, dst := argv[1], argv[2]
	if db_find(src) == nil {
		reply_error(c, ERR_NO_KEY)
		return
	}
	moved := false
	if !bytes_eq(src, dst) {
		occupied := db_find(dst) != nil
		if !(nx && occupied) {
			rename_relocate(c, src, dst, occupied)
			rename_announce(src, dst)
			moved = true
		}
	}
	switch {
	case !nx:
		reply_ok(c)
	case moved:
		reply_int(c, 1)
	case:
		reply_int(c, 0)
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
	if labels_on {
		move_labelled(c, argv[1], id)
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

@(private = "file")
move_labelled :: proc(c: ^Conn, key: []u8, target: int) {
	src := cur_db()
	l := lookup_make(key)
	tp := label_part(target, access.id)
	if tp != nil && label_live_in(tp, &l) {
		reply_int(c, 0)
		return
	}
	if other, _, i := label_locate_other(target, key, &l, access.id, access.vis); i >= 0 {
		reply_error(c, label_in_use_text(ERR_LABEL_NAME_IN_USE, other.label))
		return
	}
	if !label_live_in(src, &l) {
		reply_int(c, 0)
		return
	}
	made, ok := label_part_make(target, access.id)
	if !ok {
		reply_error(c, ERR_LABEL_PARTITIONS)
		return
	}
	label_vset_detach_key(src, key)
	if !db_move(src, made, key) {
		reply_int(c, 0)
		return
	}
	pst.dirty += 1
	fresh_access_clock(made, key)
	block_signal_existing(made, key)
	block_note_removed()
	signal_key_in(key, src)
	signal_key_in(key, made)
	notify_in(.Generic, "move_from", key, src)
	notify_in(.Generic, "move_to", key, made)
	reply_int(c, 1)
}

cmd_randomkey :: proc(c: ^Conn, argv: [][]u8) {
	k: string
	ok: bool
	if labels_on {
		k, ok = label_random_key(c.db.id)
	} else {
		k, ok = db_random_key()
	}
	if !ok {
		reply_null(c)
		return
	}
	reply_bulk_str(c, k)
}

cmd_keys :: proc(c: ^Conn, argv: [][]u8) {
	pat := argv[1]
	all := len(pat) == 1 && pat[0] == '*'
	if labels_on {
		label_keys(c.db.id, pat, all)
	} else {
		db_keys(pat, all)
	}
	reply_array(c, len(key_scratch))
	for k in key_scratch {
		reply_bulk_str(c, k)
	}
	if cap(key_scratch) > 65536 {
		delete(key_scratch)
		key_scratch = make([dynamic]string, 0, 256)
	}
}

@(private = "file")
c_space :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == ' ' || (b >= '\t' && b <= '\r')
}

@(private = "file")
decimal_magnitude :: proc "contextless" (digits: []u8) -> (value: u64, ok: bool) {
	if len(digits) == 0 {
		return 0, false
	}
	for d in digits {
		if d < '0' || d > '9' {
			return 0, false
		}
		times_ten, wide := intrinsics.overflow_mul(value, 10)
		next, carry := intrinsics.overflow_add(times_ten, u64(d - '0'))
		if wide || carry {
			return 0, false
		}
		value = next
	}
	return value, true
}

scan_parse_cursor :: proc(arg: []u8) -> (cursor: u64, ok: bool) {
	text := generic_cstr(arg)
	lead := 0
	for lead < len(text) && c_space(text[lead]) {
		lead += 1
	}
	body := text[lead:]
	negative := false
	if len(body) > 0 && (body[0] == '-' || body[0] == '+') {
		negative = body[0] == '-'
		body = body[1:]
	}
	magnitude, digits_ok := decimal_magnitude(body)
	if !digits_ok {
		return 0, false
	}
	if !negative {
		return magnitude, true
	}
	if lead == 0 && body[0] != '0' && magnitude <= 1 << 63 {
		return 0, false
	}
	return 0 - magnitude, true
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

@(private = "file")
Scan_Request :: struct {
	count:       i64,
	pattern:     []u8,
	use_pattern: bool,
	typed:       bool,
	type_known:  bool,
	want:        Obj_Type,
}

@(private = "file")
scan_read_options :: proc(c: ^Conn, options: [][]u8, req: ^Scan_Request) -> bool {
	req.count = 10
	rest := options
	for len(rest) > 0 {
		word := generic_cstr(rest[0])
		paired := len(rest) >= 2
		switch {
		case paired && eq_nocase(word, "count"):
			n, numeric := parse_i64(rest[1])
			if !numeric {
				reply_error(c, ERR_NOT_INT)
				return false
			}
			if n <= 0 {
				reply_error(c, ERR_SYNTAX)
				return false
			}
			req.count = n
		case paired && eq_nocase(word, "match"):
			req.pattern = rest[1]
			req.use_pattern = !bytes_eq(req.pattern, transmute([]u8)string("*"))
		case paired && eq_nocase(word, "type"):
			req.typed = true
			req.want, req.type_known = obj_type_by_name(rest[1])
		case eq_nocase(word, "novalues"):
			reply_error(c, "ERR NOVALUES option can only be used in HSCAN")
			return false
		case:
			reply_error(c, ERR_SYNTAX)
			return false
		}
		rest = rest[2:]
	}
	return true
}

@(private = "file")
scan_filter_by_type :: proc(want: Obj_Type, known: bool) {
	survivors := 0
	for name in key_scratch {
		found := db_find_read_notouch(transmute([]u8)name)
		if found == nil || !known || entry_type(found) != want {
			continue
		}
		key_scratch[survivors] = name
		survivors += 1
	}
	resize(&key_scratch, survivors)
}

cmd_scan :: proc(c: ^Conn, argv: [][]u8) {
	cursor, valid := scan_parse_cursor(argv[1])
	if !valid {
		reply_error(c, "ERR invalid cursor")
		return
	}
	req: Scan_Request
	if !scan_read_options(c, argv[2:], &req) {
		return
	}
	next := label_scan(c.db.id, cursor, req.count, req.pattern, req.use_pattern) if labels_on else db_scan(cursor, req.count, req.pattern, req.use_pattern)
	if req.typed {
		scan_filter_by_type(req.want, req.type_known)
	}
	reply_array(c, 2)
	reply_bulk_int_u64(c, next)
	reply_array(c, len(key_scratch))
	for name in key_scratch {
		reply_bulk_str(c, name)
	}
	db_scan_purge_expired(req.typed)
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
		if !access_counts_hits {
			reply_error(c, ERR_LFU_NOT_SELECTED)
			return
		}
		reply_int(c, entry_tally(e))
	case eq_nocase(sub, "idletime"):
		e := object_lookup(c, argv, "object|idletime")
		if e == nil {
			return
		}
		if access_counts_hits {
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
	_, accepted := parse_timeout_deadline(c, arg)
	return accepted
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
	if numlocal != 0 && aof.state != .Enabled {
		reply_error(c, "ERR WAITAOF cannot be used when numlocal is set but appendonly is disabled.")
		return
	}
	acked: i64 = 0
	if aof.state == .Enabled {
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

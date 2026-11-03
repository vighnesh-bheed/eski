package main

import "base:runtime"
import "core:net"
import "core:sys/linux"
import "rdb"

ERR_BUSYKEY :: "BUSYKEY Target key name already exists."

ERR_BAD_DATA_FORMAT :: "ERR Bad data format"

ERR_DUMP_PAYLOAD :: "ERR DUMP payload version or checksum are wrong"

ERR_MIGRATE_CONNECT :: "IOERR error or timeout connecting to the client"

ERR_MIGRATE_WRITE :: "IOERR error or timeout writing to target instance"

ERR_MIGRATE_READ :: "IOERR error or timeout reading to target instance"

ERR_MIGRATE_KEYS :: "ERR When using MIGRATE KEYS option, the key argument must be set to the empty string"

ERR_RESTORE_TTL :: "ERR Invalid TTL value, must be >= 0"

ERR_RESTORE_IDLETIME :: "ERR Invalid IDLETIME value, must be >= 0"

ERR_RESTORE_FREQ :: "ERR Invalid FREQ value, must be >= 0 and <= 255"

MIGRATE_POOL_SIZE :: 64

MIGRATE_POOL_IDLE_SECONDS :: 10

MIGRATE_TIMEOUT_DEFAULT_MS :: 1000

DUMP_TRAILER_LEN :: 10

@(private = "file")
MIGRATE_READ_CHUNK :: 16 * 1024

@(private = "file")
MIGRATE_LINE_LIMIT :: 1024 * 1024

@(private = "file")
MIGRATE_KEEP_BYTES :: 1024 * 1024

@(private = "file")
MIGRATE_TARGET_PREFIX :: "ERR Target instance replied with error: "

Migrate_Socket :: struct {
	fd:         linux.Fd,
	selected:   i64,
	idle_since: i64,
	stamp:      u64,
	name:       [dynamic]u8,
}

migrate_cache: [dynamic]^Migrate_Socket

@(private = "file")
migrate_out: [dynamic]u8

@(private = "file")
migrate_in: [dynamic]u8

@(private = "file")
migrate_line: [dynamic]u8

@(private = "file")
migrate_head: [dynamic]u8

@(private = "file")
migrate_name: [dynamic]u8

@(private = "file")
migrate_keys: [dynamic][]u8

@(private = "file")
migrate_acks: [dynamic]bool

@(private = "file")
migrate_gone: [dynamic][]u8

@(private = "file")
migrate_in_pos: int

@(private = "file")
migrate_timed_out: bool

@(private = "file")
Restore_Options :: struct {
	replace:  bool,
	absolute: bool,
	idle:     i64,
	freq:     i64,
}

@(private = "file")
Migrate_Request :: struct {
	host:     []u8,
	port:     []u8,
	dbid:     i64,
	timeout:  i64,
	copy:     bool,
	replace:  bool,
	auth:     bool,
	user:     []u8,
	password: []u8,
	keys:     [][]u8,
}

@(private = "file")
Migrate_Addr :: struct {
	v6:   bool,
	ip4:  [4]u8,
	ip6:  [16]u8,
	port: u16,
}

@(private = "file")
Migrate_Failure :: enum u8 {
	None,
	Write,
	Read,
}

@(private = "file")
Migrate_Outcome :: struct {
	failure:    Migrate_Failure,
	retryable:  bool,
	head_error: bool,
	any_error:  bool,
	replies:    int,
	acked:      int,
}

restore_keyspace_event :: proc(db: ^Db, key: []u8) {
	signal_key_in(key, db)
	notify_in(.Generic, "restore", key, db)
}

dump_payload :: proc(w: ^rdb.Writer, key: []u8, v: Slot_Value) {
	start := w.len
	persist_write_value(w, key, v, false)
	rdb.put_u8(w, u8(rdb.RDB_VERSION & 0xff))
	rdb.put_u8(w, u8((rdb.RDB_VERSION >> 8) & 0xff))
	sum := rdb.crc64(0, w.buf[start:w.len])
	rdb.put_ms(w, i64(sum))
}

dump_verify :: proc "contextless" (p: []u8) -> bool {
	n := len(p)
	if n < DUMP_TRAILER_LEN {
		return false
	}
	version := int(p[n - DUMP_TRAILER_LEN]) | int(p[n - DUMP_TRAILER_LEN + 1]) << 8
	if version > rdb.RDB_VERSION {
		return false
	}
	if pst.skip_checksum {
		return true
	}
	stored: u64 = 0
	for i in 0 ..< 8 {
		stored |= u64(p[n - 8 + i]) << (8 * uint(i))
	}
	return rdb.crc64(0, p[:n - 8]) == stored
}

cmd_dump :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	e := db_find_read(key)
	if e == nil {
		reply_null(c)
		return
	}
	v := dump_value_of(e)
	w: rdb.Writer
	rdb.writer_init_mem(&w, pst.compression, false)
	defer rdb.writer_destroy(&w)
	dump_payload(&w, key, v)
	reply_bulk(c, rdb.writer_bytes(&w))
}

@(private = "file")
dump_value_of :: proc(e: ^Entry) -> Slot_Value {
	return persist_slot_value(e.db if e.db != nil else cur_db(), e.kp, e.vp)
}

@(private = "file")
restore_options :: proc(c: ^Conn, args: [][]u8) -> (opts: Restore_Options, ok: bool) {
	opts.idle = -1
	opts.freq = -1
	at := 0
	for at < len(args) {
		word := args[at]
		value_follows := at + 1 < len(args)
		if eq_nocase(word, "replace") {
			opts.replace = true
		} else if eq_nocase(word, "absttl") {
			opts.absolute = true
		} else if value_follows && opts.freq < 0 && eq_nocase(word, "idletime") {
			idle, is_int := parse_i64(args[at + 1])
			if !is_int {
				reply_error(c, ERR_NOT_INT)
				return
			}
			if idle < 0 {
				reply_error(c, ERR_RESTORE_IDLETIME)
				return
			}
			opts.idle = idle
			at += 1
		} else if value_follows && opts.idle < 0 && eq_nocase(word, "freq") {
			freq, is_int := parse_i64(args[at + 1])
			if !is_int {
				reply_error(c, ERR_NOT_INT)
				return
			}
			if freq < 0 || freq > 255 {
				reply_error(c, ERR_RESTORE_FREQ)
				return
			}
			opts.freq = freq
			at += 1
		} else {
			reply_error(c, ERR_SYNTAX)
			return
		}
		at += 1
	}
	ok = true
	return
}

@(private = "file")
restore_deep :: proc(c: ^Conn) -> bool {
	if !persist_deep_sanitize(true) {
		return false
	}
	if pst.sanitize == .Clients && c != nil && acl_skips_sanitize(c) {
		return false
	}
	return true
}

@(private = "file")
restore_decode :: proc(r: ^rdb.Reader, payload: []u8, deep: bool) -> (v: Loaded_Value, ok: bool) {
	rdb.reader_init_mem(r, payload, false)
	kind := rdb.get_type(r)
	if kind < 0 || !rdb.is_object_type(kind) {
		return
	}
	v = persist_load_object(r, kind, deep)
	if r.status != .Ok {
		if v.obj != nil {
			persist_free_loaded(v)
		}
		return {}, false
	}
	if v.type != .String && v.obj == nil {
		return {}, false
	}
	ok = true
	return
}

@(private = "file")
restore_deadline :: proc(ttl: i64, absolute: bool) -> (at: i64, lapsed: bool) {
	if ttl == 0 {
		return 0, false
	}
	now := expire_now()
	if absolute {
		return ttl, ttl <= now
	}
	if ttl > max(i64) - now {
		return 0, true
	}
	return now + ttl, false
}

cmd_restore :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	opts, parsed := restore_options(c, argv[4:])
	if !parsed {
		return
	}
	present := db_find(key) != nil
	if present && !opts.replace {
		reply_error(c, ERR_BUSYKEY)
		return
	}
	ttl, is_int := parse_i64(argv[2])
	if !is_int {
		reply_error(c, ERR_NOT_INT)
		return
	}
	if ttl < 0 {
		reply_error(c, ERR_RESTORE_TTL)
		return
	}
	payload := argv[3]
	if !dump_verify(payload) {
		reply_error(c, ERR_DUMP_PAYLOAD)
		return
	}
	deep := restore_deep(c)
	if deep {
		stat_dump_sanitizations += 1
	}
	r: rdb.Reader
	defer rdb.reader_destroy(&r)
	v, decoded := restore_decode(&r, payload, deep)
	if !decoded {
		reply_error(c, ERR_BAD_DATA_FORMAT)
		return
	}
	db := cur_db()
	removed := false
	if present {
		found, _ := db_remove(key)
		removed = found
	}
	at, lapsed := restore_deadline(ttl, opts.absolute)
	if lapsed {
		persist_free_loaded(v)
		if removed {
			signal_key_in(key, db)
			notify_in(.Generic, "del", key, db)
		} else {
			pst.dirty_explicit = true
		}
		reply_ok(c)
		return
	}
	e, _ := db_upsert_timed(key, min(at, MAX_EXPIRE_MS))
	persist_attach(e, key, v)
	if at != 0 {
		entry_set_expire(e, min(at, MAX_EXPIRE_MS))
	}
	hint: Access_Hint
	if opts.freq >= 0 {
		hint = Access_Hint{.Frequency, opts.freq}
	} else if opts.idle >= 0 {
		hint = Access_Hint{.Idle_Seconds, opts.idle}
	}
	persist_apply_access_hint(e, hint)
	#partial switch v.type {
	case .List, .Stream:
		block_signal_key(db, key, v.type)
	}
	restore_keyspace_event(db, key)
	reply_ok(c)
}

@(private = "file")
migrate_heap_ready :: proc() {
	heap := runtime.heap_allocator()
	if migrate_cache.allocator.procedure == nil {
		migrate_cache.allocator = heap
	}
	if migrate_out.allocator.procedure == nil {
		migrate_out.allocator = heap
	}
	if migrate_in.allocator.procedure == nil {
		migrate_in.allocator = heap
	}
	if migrate_line.allocator.procedure == nil {
		migrate_line.allocator = heap
	}
	if migrate_head.allocator.procedure == nil {
		migrate_head.allocator = heap
	}
	if migrate_name.allocator.procedure == nil {
		migrate_name.allocator = heap
	}
	if migrate_keys.allocator.procedure == nil {
		migrate_keys.allocator = heap
	}
	if migrate_acks.allocator.procedure == nil {
		migrate_acks.allocator = heap
	}
	if migrate_gone.allocator.procedure == nil {
		migrate_gone.allocator = heap
	}
}

@(private = "file")
migrate_clock_ms :: proc "contextless" () -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1000 + i64(ts.time_nsec) / 1_000_000
}

@(private = "file")
migrate_deadline :: proc "contextless" (timeout: i64) -> i64 {
	now := migrate_clock_ms()
	if timeout > max(i64) - now {
		return max(i64)
	}
	return now + timeout
}

@(private = "file")
migrate_clock_s :: proc "contextless" () -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec)
}

migrate_cached_count :: proc "contextless" () -> int {
	return len(migrate_cache)
}

@(private = "file")
migrate_close :: proc(cs: ^Migrate_Socket) {
	if cs.fd >= 0 {
		linux.close(cs.fd)
	}
	delete(cs.name)
	free(cs, runtime.heap_allocator())
}

@(private = "file")
migrate_close_at :: proc(i: int) {
	cs := migrate_cache[i]
	unordered_remove(&migrate_cache, i)
	migrate_close(cs)
}

@(private = "file")
migrate_forget :: proc(cs: ^Migrate_Socket) {
	for held, i in migrate_cache {
		if held == cs {
			migrate_close_at(i)
			return
		}
	}
	migrate_close(cs)
}

migrate_cron :: proc() {
	now := migrate_clock_s()
	for n := len(migrate_cache) - 1; n >= 0; n -= 1 {
		if now - migrate_cache[n].idle_since > MIGRATE_POOL_IDLE_SECONDS {
			migrate_close_at(n)
		}
	}
}

@(private = "file")
migrate_port_number :: proc "contextless" (s: []u8) -> (port: u16, ok: bool) {
	at := 0
	for at < len(s) && (s[at] == ' ' || (s[at] >= '\t' && s[at] <= '\r')) {
		at += 1
	}
	negative := false
	if at < len(s) && (s[at] == '+' || s[at] == '-') {
		negative = s[at] == '-'
		at += 1
	}
	value := 0
	for at < len(s) && s[at] >= '0' && s[at] <= '9' {
		value = value * 10 + int(s[at] - '0')
		if value > 65535 {
			return 0, false
		}
		at += 1
	}
	if negative && value != 0 {
		return 0, false
	}
	return u16(value), true
}

@(private = "file")
migrate_has_colon :: proc "contextless" (s: []u8) -> bool {
	for b in s {
		if b == ':' {
			return true
		}
	}
	return false
}

@(private = "file")
migrate_resolve :: proc(host: []u8, port: []u8) -> (addr: Migrate_Addr, ok: bool) {
	number, valid := migrate_port_number(port)
	if !valid || len(host) == 0 {
		return
	}
	addr.port = number
	text := string(host)
	if migrate_has_colon(host) {
		if ip6, is_ip6 := net.parse_ip6_address(text); is_ip6 {
			addr.v6 = true
			addr.ip6 = transmute([16]u8)ip6
			return addr, true
		}
		return
	}
	if ip4, is_ip4 := net.parse_ip4_address(text); is_ip4 {
		addr.ip4 = cast([4]u8)ip4
		return addr, true
	}
	if eq_nocase(host, "localhost") {
		addr.ip4 = {127, 0, 0, 1}
		return addr, true
	}
	if !net.validate_hostname(text) {
		return
	}
	arena: runtime.Arena
	defer runtime.arena_destroy(&arena)
	context.allocator = runtime.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	if ep4, err4 := net.resolve_ip4(text); err4 == nil {
		if ip4, is_ip4 := ep4.address.(net.IP4_Address); is_ip4 {
			addr.ip4 = cast([4]u8)ip4
			return addr, true
		}
	}
	if ep6, err6 := net.resolve_ip6(text); err6 == nil {
		if ip6, is_ip6 := ep6.address.(net.IP6_Address); is_ip6 {
			addr.v6 = true
			addr.ip6 = transmute([16]u8)ip6
			return addr, true
		}
	}
	return
}

@(private = "file")
migrate_wait :: proc(fd: linux.Fd, events: linux.Fd_Poll_Events, deadline: i64) -> bool {
	for {
		left := deadline - migrate_clock_ms()
		if left <= 0 {
			migrate_timed_out = true
			return false
		}
		fds := [1]linux.Poll_Fd{{fd = fd, events = events}}
		n, err := linux.poll(fds[:], i32(min(left, i64(max(i32)))))
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return false
		}
		if n > 0 {
			return true
		}
	}
}

@(private = "file")
migrate_connect :: proc(addr: Migrate_Addr, timeout: i64) -> (linux.Fd, bool) {
	family: linux.Address_Family = .INET6 if addr.v6 else .INET
	fd, err := linux.socket(family, .STREAM, {.NONBLOCK, .CLOEXEC}, .TCP)
	if err != .NONE {
		return -1, false
	}
	runtime_socket_mark(fd)
	status: linux.Errno
	if addr.v6 {
		sa := linux.Sock_Addr_In6 {
			sin6_family = .INET6,
			sin6_port   = u16be(addr.port),
			sin6_addr   = addr.ip6,
		}
		status = linux.connect(fd, &sa)
	} else {
		sa := linux.Sock_Addr_In {
			sin_family = .INET,
			sin_port   = u16be(addr.port),
			sin_addr   = addr.ip4,
		}
		status = linux.connect(fd, &sa)
	}
	if status == .EINPROGRESS || status == .EINTR {
		if !migrate_wait(fd, {.OUT}, migrate_deadline(timeout)) {
			linux.close(fd)
			return -1, false
		}
	} else if status != .NONE {
		linux.close(fd)
		return -1, false
	}
	nodelay: i32 = 1
	linux.setsockopt(fd, linux.SOL_TCP, linux.Socket_TCP_Option.NODELAY, &nodelay)
	return fd, true
}

@(private = "file")
migrate_pool_clock: u64

@(private = "file")
migrate_pool_touch :: proc(cs: ^Migrate_Socket) {
	migrate_pool_clock += 1
	cs.stamp = migrate_pool_clock
	cs.idle_since = migrate_clock_s()
}

@(private = "file")
migrate_pool_find :: proc(name: []u8) -> ^Migrate_Socket {
	for held in migrate_cache {
		if bytes_eq(held.name[:], name) {
			return held
		}
	}
	return nil
}

@(private = "file")
migrate_pool_evict :: proc() {
	victim := 0
	for held, n in migrate_cache {
		if held.stamp < migrate_cache[victim].stamp {
			victim = n
		}
	}
	migrate_close_at(victim)
}

@(private = "file")
migrate_pool_add :: proc(fd: linux.Fd, name: []u8) -> ^Migrate_Socket {
	if len(migrate_cache) >= MIGRATE_POOL_SIZE {
		migrate_pool_evict()
	}
	heap := runtime.heap_allocator()
	cs := new(Migrate_Socket, heap)
	cs.fd = fd
	cs.selected = -1
	cs.name = make([dynamic]u8, 0, len(name), heap)
	append(&cs.name, ..name)
	migrate_pool_touch(cs)
	append(&migrate_cache, cs)
	return cs
}

@(private = "file")
migrate_open :: proc(host: []u8, port: []u8, timeout: i64) -> (fd: linux.Fd, ok: bool) {
	addr := migrate_resolve(host, port) or_return
	return migrate_connect(addr, timeout)
}

@(private = "file")
migrate_pool_get :: proc(host: []u8, port: []u8, timeout: i64) -> (cs: ^Migrate_Socket, reused: bool) {
	clear(&migrate_name)
	for part in ([3][]u8{host, {':'}, port}) {
		append(&migrate_name, ..part)
	}
	if held := migrate_pool_find(migrate_name[:]); held != nil {
		migrate_pool_touch(held)
		return held, true
	}
	if fd, opened := migrate_open(host, port, timeout); opened {
		cs = migrate_pool_add(fd, migrate_name[:])
	}
	return
}

@(private = "file")
migrate_put_count :: proc(out: ^[dynamic]u8, mark: u8, n: int) {
	digits: [24]u8
	k := format_i64(raw_data(digits[:]), i64(n))
	append(out, mark)
	append(out, ..digits[:k])
	append(out, '\r', '\n')
}

@(private = "file")
migrate_put_cmd :: proc(out: ^[dynamic]u8, args: ..[]u8) {
	migrate_put_count(out, '*', len(args))
	for a in args {
		migrate_put_count(out, '$', len(a))
		append(out, ..a)
		append(out, '\r', '\n')
	}
}

@(private = "file")
migrate_write_all :: proc(fd: linux.Fd, data: []u8, timeout: i64) -> bool {
	deadline := migrate_deadline(timeout)
	rest := data
	for len(rest) > 0 {
		n, err := linux.send(fd, rest, {.NOSIGNAL})
		if err == .NONE && n > 0 {
			rest = rest[n:]
		} else if err == .EAGAIN {
			if !migrate_wait(fd, {.OUT}, deadline) {
				return false
			}
		} else if err != .EINTR {
			return false
		}
	}
	return true
}

@(private = "file")
migrate_read_line :: proc(fd: linux.Fd, timeout: i64) -> ([]u8, bool) {
	deadline := migrate_deadline(timeout)
	for {
		pending := migrate_in[migrate_in_pos:]
		for b, i in pending {
			if b == '\n' {
				line := pending[:i]
				migrate_in_pos += i + 1
				if len(line) > 0 && line[len(line) - 1] == '\r' {
					line = line[:len(line) - 1]
				}
				return line, true
			}
		}
		if len(pending) > MIGRATE_LINE_LIMIT {
			return nil, false
		}
		if migrate_in_pos > 0 && migrate_in_pos == len(migrate_in) {
			clear(&migrate_in)
			migrate_in_pos = 0
		}
		filled := len(migrate_in)
		non_zero_resize(&migrate_in, filled + MIGRATE_READ_CHUNK)
		n, err := linux.recv(fd, migrate_in[filled:], {})
		if err == .NONE && n > 0 {
			resize(&migrate_in, filled + n)
			continue
		}
		resize(&migrate_in, filled)
		if err == .EAGAIN {
			if !migrate_wait(fd, {.IN}, deadline) {
				return nil, false
			}
		} else if err != .EINTR {
			return nil, false
		}
	}
}

@(private = "file")
migrate_note_error :: proc(o: ^Migrate_Outcome, line: []u8) {
	if !o.any_error {
		clear(&migrate_line)
		append(&migrate_line, ..line[1:])
	}
	o.any_error = true
}

@(private = "file")
migrate_parse :: proc(c: ^Conn, argv: [][]u8) -> (req: Migrate_Request, ok: bool) {
	req.host = argv[1]
	req.port = argv[2]
	req.keys = argv[3:4]
	at := 6
	for at < len(argv) {
		word := argv[at]
		spare := len(argv) - at - 1
		if eq_nocase(word, "copy") {
			req.copy = true
		} else if eq_nocase(word, "replace") {
			req.replace = true
		} else if eq_nocase(word, "auth") && spare >= 1 {
			req.auth = true
			req.password = argv[at + 1]
			at += 1
		} else if eq_nocase(word, "auth2") && spare >= 2 {
			req.auth = true
			req.user = argv[at + 1]
			req.password = argv[at + 2]
			at += 2
		} else if eq_nocase(word, "keys") {
			if len(argv[3]) != 0 {
				reply_error(c, ERR_MIGRATE_KEYS)
				return
			}
			req.keys = argv[at + 1:]
			break
		} else {
			reply_error(c, ERR_SYNTAX)
			return
		}
		at += 1
	}
	timeout, timeout_ok := parse_i64(argv[5])
	dbid, dbid_ok := parse_i64(argv[4])
	if !timeout_ok || !dbid_ok {
		reply_error(c, ERR_NOT_INT)
		return
	}
	req.timeout = timeout if timeout > 0 else MIGRATE_TIMEOUT_DEFAULT_MS
	req.dbid = dbid
	ok = true
	return
}

@(private = "file")
migrate_collect :: proc(req: ^Migrate_Request) -> int {
	clear(&migrate_out)
	clear(&migrate_keys)
	w: rdb.Writer
	rdb.writer_init_mem(&w, pst.compression, false)
	defer rdb.writer_destroy(&w)
	now := expire_now()
	for key in req.keys {
		e := db_find_read(key)
		if e == nil {
			continue
		}
		ttl: i64 = 0
		if e.expire_at != 0 {
			ttl = max(e.expire_at - now, 1)
		}
		w.len = 0
		dump_payload(&w, key, dump_value_of(e))
		digits: [24]u8
		k := format_i64(raw_data(digits[:]), ttl)
		if req.replace {
			migrate_put_cmd(&migrate_out, transmute([]u8)string("RESTORE"), key, digits[:k], rdb.writer_bytes(&w), transmute([]u8)string("REPLACE"))
		} else {
			migrate_put_cmd(&migrate_out, transmute([]u8)string("RESTORE"), key, digits[:k], rdb.writer_bytes(&w))
		}
		append(&migrate_keys, key)
	}
	return len(migrate_keys)
}

@(private = "file")
migrate_preamble :: proc(cs: ^Migrate_Socket, req: ^Migrate_Request) -> (commands: int) {
	clear(&migrate_head)
	if req.auth && req.user != nil {
		migrate_put_cmd(&migrate_head, transmute([]u8)string("AUTH"), req.user, req.password)
		commands += 1
	} else if req.auth {
		migrate_put_cmd(&migrate_head, transmute([]u8)string("AUTH"), req.password)
		commands += 1
	}
	if cs.selected != req.dbid {
		digits: [24]u8
		width := format_i64(raw_data(digits[:]), req.dbid)
		migrate_put_cmd(&migrate_head, transmute([]u8)string("SELECT"), digits[:width])
		commands += 1
	}
	return
}

@(private = "file")
migrate_fail :: proc(o: ^Migrate_Outcome, failure: Migrate_Failure, may_retry: bool) {
	o.failure = failure
	o.retryable = may_retry && !migrate_timed_out
}

@(private = "file")
migrate_await :: proc(cs: ^Migrate_Socket, req: ^Migrate_Request, reused: bool, o: ^Migrate_Outcome) -> (refused: bool, ok: bool) {
	reply, got := migrate_read_line(cs.fd, req.timeout)
	if !got {
		migrate_fail(o, .Read, reused && o.replies == 0)
		return
	}
	o.replies += 1
	if len(reply) > 0 && reply[0] == '-' {
		migrate_note_error(o, reply)
		refused = true
	}
	return refused, true
}

@(private = "file")
migrate_transfer :: proc(cs: ^Migrate_Socket, req: ^Migrate_Request, reused: bool) -> (o: Migrate_Outcome) {
	preamble := migrate_preamble(cs, req)
	migrate_in_pos, migrate_timed_out = 0, false
	clear(&migrate_in)
	resize(&migrate_acks, len(migrate_keys))
	sent := migrate_write_all(cs.fd, migrate_head[:], req.timeout) && migrate_write_all(cs.fd, migrate_out[:], req.timeout)
	if !sent {
		migrate_fail(&o, .Write, reused)
		return
	}
	for _ in 0 ..< preamble {
		refused, got := migrate_await(cs, req, reused, &o)
		if !got {
			return
		}
		if refused {
			o.head_error = true
		}
	}
	for &ack in migrate_acks {
		refused, got := migrate_await(cs, req, reused, &o)
		if !got {
			return
		}
		ack = !refused
		o.acked += 1
	}
	return
}

@(private = "file")
migrate_trim :: proc(buf: ^[dynamic]u8) {
	if cap(buf) > MIGRATE_KEEP_BYTES {
		delete(buf^)
		buf^ = make([dynamic]u8, runtime.heap_allocator())
	}
}

@(private = "file")
reply_target_error :: proc(c: ^Conn, line: []u8) {
	reply_error_parts(c, MIGRATE_TARGET_PREFIX, string(line))
}

@(private = "file")
migrate_attempt :: proc(req: ^Migrate_Request) -> (o: Migrate_Outcome, cs: ^Migrate_Socket, connected: bool) {
	for round in 1 ..= 2 {
		reused: bool
		cs, reused = migrate_pool_get(req.host, req.port, req.timeout)
		if cs == nil {
			return
		}
		o = migrate_transfer(cs, req, reused)
		if o.failure == .None || !o.retryable || round == 2 {
			break
		}
		migrate_forget(cs)
	}
	connected = true
	return
}

@(private = "file")
migrate_drop_acked :: proc(c: ^Conn, acked: int) {
	clear(&migrate_gone)
	for key, n in migrate_keys[:acked] {
		if migrate_acks[n] {
			if found, _ := db_remove(key); found {
				append(&migrate_gone, key)
			}
		}
	}
	if len(migrate_gone) == 0 {
		return
	}
	db := cur_db()
	for key in migrate_gone {
		signal_key_in(key, db)
		notify_in(.Generic, "del", key, db)
	}
	pst.dirty += i64(len(migrate_gone))
	aof_migrate_deleted(c, migrate_gone[:])
}

@(private = "file")
migrate_settle :: proc(cs: ^Migrate_Socket, req: ^Migrate_Request, o: ^Migrate_Outcome) {
	if o.failure != .None {
		migrate_forget(cs)
		return
	}
	cs.selected = -1 if o.any_error else req.dbid
	migrate_pool_touch(cs)
}

@(private = "file")
migrate_answer :: proc(c: ^Conn, o: ^Migrate_Outcome) {
	switch {
	case o.any_error:
		reply_target_error(c, migrate_line[:])
	case o.failure == .None:
		pst.dirty_explicit = true
		reply_ok(c)
	case o.failure == .Write:
		reply_error(c, ERR_MIGRATE_WRITE)
	case:
		reply_error(c, ERR_MIGRATE_READ)
	}
}

@(private = "file")
migrate_run :: proc(c: ^Conn, req: ^Migrate_Request) {
	if present := migrate_collect(req); present == 0 {
		reply_simple(c, "NOKEY")
		pst.dirty_explicit = true
		return
	}
	o, cs, connected := migrate_attempt(req)
	if !connected {
		reply_error(c, ERR_MIGRATE_CONNECT)
		return
	}
	if !req.copy && !o.head_error {
		migrate_drop_acked(c, o.acked)
	}
	migrate_settle(cs, req, &o)
	migrate_trim(&migrate_out)
	migrate_trim(&migrate_in)
	migrate_answer(c, &o)
}

cmd_migrate :: proc(c: ^Conn, argv: [][]u8) {
	migrate_heap_ready()
	if req, parsed := migrate_parse(c, argv); parsed {
		migrate_run(c, &req)
	}
}

@(private = "file")
dump_commands := [?]Command {
	{"dump", cmd_dump, 2},
	{"restore", cmd_restore, -4},
	{"migrate", cmd_migrate, -6},
}

@(init)
register_dump_commands :: proc "contextless" () {
	register_commands(dump_commands[:])
}

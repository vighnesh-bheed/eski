package main

import "base:intrinsics"
import "base:runtime"
import "core:hash"
import "core:sys/linux"

Conn_Kind :: enum u8 {
	Redis,
	Memcached,
}

MC_KEY_MAX :: 250
MC_LINE_MAX :: 2048
MC_GET_LINE_MAX :: 16 << 20
MC_LAST_TOKEN_SCAN_TOKENS :: 23
MC_TOKEN_SLOTS :: 8
MC_RELATIVE_EXPIRY_LIMIT_SECONDS :: 60 * 60 * 24 * 30
MC_ITEM_FIXED_BYTES :: 59
MC_ITEM_FLAGS_BYTES :: 4
MC_ITEM_SIZE_DEFAULT :: 1024 * 1024
MC_ITEM_SIZE_MIN :: 1024
MC_ITEM_SIZE_MAX :: 512 * 1024 * 1024
MC_VLEN_MAX :: 2147483645
MC_SHORT_NUM :: 11
MC_LONG_NUM :: 22
MC_META_MIN_CAP :: 16
MC_CLIENT_FLAGS_SIZE :: 4

MC_ERR_FORMAT :: "CLIENT_ERROR bad command line format\r\n"
MC_ERR_GET_KEY :: "CLIENT_ERROR bad command line format\r\n\r\n"
MC_ERR_CHUNK :: "CLIENT_ERROR bad data chunk\r\n"
MC_ERR_TOO_LARGE :: "SERVER_ERROR object too large for cache\r\n"
MC_ERR_EXPTIME :: "CLIENT_ERROR invalid exptime argument\r\n"
MC_ERR_DELTA :: "CLIENT_ERROR invalid numeric delta argument\r\n"
MC_ERR_NON_NUMERIC :: "CLIENT_ERROR cannot increment or decrement non-numeric value\r\n"
MC_ERR_SHUTDOWN :: "SERVER_ERROR: shutdown not enabled\r\n"
MC_ERR_NO_MEMORY :: "SERVER_ERROR out of memory storing object\r\n"
MC_ERR_LINE :: "CLIENT_ERROR bad command line\r\n"
MC_ERR_SLAB_ID :: "CLIENT_ERROR Illegal slab id\r\n"
MC_ERR_DETAIL_USAGE :: "CLIENT_ERROR usage: stats detail on|off|dump\r\n"
MC_SLAB_CLASSES :: 64
MC_PREFIX_BUCKETS :: 256
MC_PREFIX_DELIMITER :: ':'
MC_VERSION_LINE :: "VERSION " + VERSION + "\r\n"

Mc_Meta :: struct {
	handle: u64,
	cas:    u64,
	flags:  u32,
	size:   u32,
}

Mc_Table :: struct {
	slots: [^]Mc_Meta,
	cap:   int,
	live:  int,
	bytes: int,
}

#assert(size_of(Mc_Meta) == 24)

Mc_Stats :: struct {
	cmd_get:         u64,
	cmd_set:         u64,
	cmd_flush:       u64,
	cmd_touch:       u64,
	get_hits:        u64,
	get_misses:      u64,
	get_expired:     u64,
	delete_misses:   u64,
	delete_hits:     u64,
	incr_misses:     u64,
	incr_hits:       u64,
	decr_misses:     u64,
	decr_hits:       u64,
	cas_misses:      u64,
	cas_hits:        u64,
	cas_badval:      u64,
	touch_hits:      u64,
	touch_misses:    u64,
	store_too_large: u64,
	store_no_memory: u64,
	total_items:     u64,
	total_conns:     u64,
	bytes_read:      u64,
	bytes_written:   u64,
}

Mc_Store :: enum u8 {
	Set,
	Add,
	Replace,
	Append,
	Prepend,
	Cas,
}

Mc_Get :: enum u8 {
	Get,
	Gets,
	Gat,
	Gats,
}

Mc_Line :: struct {
	tok:  [MC_TOKEN_SLOTS][]u8,
	ntok: int,
	last: []u8,
}

Mc_Deferred :: enum u8 {
	None,
	Format,
	Too_Large,
	No_Memory,
}

mc_port: int
mc_lfd: linux.Fd = -1
mc_item_size_max: int = MC_ITEM_SIZE_DEFAULT
mc_verbosity: u32
mc_cas_last: u64 = 1
mc_flush_at: i64
mc_writing: bool
mc_noreply: bool
mc_oom: bool
mc_stats: Mc_Stats
mc_tmp: [dynamic]u8
mc_detail_on: bool
mc_prefixes: [MC_PREFIX_BUCKETS]^Mc_Prefix

Mc_Prefix :: struct {
	next:   ^Mc_Prefix,
	prefix: []u8,
	get:    u64,
	hit:    u64,
	set:    u64,
	del:    u64,
}

mc_prefix_of :: proc(key: []u8) -> ^Mc_Prefix {
	if !mc_detail_on {
		return nil
	}
	cut := -1
	for b, i in key {
		if b == MC_PREFIX_DELIMITER {
			cut = i
			break
		}
	}
	if cut < 0 {
		return nil
	}
	name := key[:cut]
	bucket := hash.murmur32(name, 0) & (MC_PREFIX_BUCKETS - 1)
	for p := mc_prefixes[bucket]; p != nil; p = p.next {
		if bytes_eq(p.prefix, name) {
			return p
		}
	}
	p := new(Mc_Prefix)
	p.prefix = make([]u8, len(name))
	copy(p.prefix, name)
	p.next = mc_prefixes[bucket]
	mc_prefixes[bucket] = p
	return p
}

mc_prefix_reset :: proc() {
	for &head in mc_prefixes {
		for head != nil {
			next := head.next
			delete(head.prefix)
			free(head)
			head = next
		}
	}
}

@(private = "file")
mc_stats_detail_dump :: proc(b: ^[dynamic]u8) {
	for head in mc_prefixes {
		for p := head; p != nil; p = p.next {
			sb_str(b, "PREFIX ")
			sb_bytes(b, p.prefix)
			sb_str(b, " get ")
			sb_int(b, i64(p.get))
			sb_str(b, " hit ")
			sb_int(b, i64(p.hit))
			sb_str(b, " set ")
			sb_int(b, i64(p.set))
			sb_str(b, " del ")
			sb_int(b, i64(p.del))
			sb_str(b, "\r\n")
		}
	}
}

@(private = "file")
mc_stats_conn_line :: proc(b: ^[dynamic]u8, fd: linux.Fd, name: string, value: []u8) {
	sb_str(b, "STAT ")
	sb_int(b, i64(fd))
	sb_byte(b, ':')
	sb_str(b, name)
	sb_byte(b, ' ')
	sb_bytes(b, value)
	sb_str(b, "\r\n")
}

@(private = "file")
mc_stats_conn_addr :: proc(b: ^[dynamic]u8, fd: linux.Fd, name: string, text: []u8) {
	scheme := "tcp6:" if len(text) > 0 && text[0] == '[' else "tcp:"
	value := make([dynamic]u8, context.temp_allocator)
	sb_str(&value, scheme)
	sb_bytes(&value, text)
	mc_stats_conn_line(b, fd, name, value[:])
}

@(private = "file")
mc_stats_conn_seconds :: proc(b: ^[dynamic]u8, fd: linux.Fd, since_ms: i64) {
	value: [24]u8
	n := format_i64(&value[0], max(srv.now_ms - since_ms, 0) / 1000)
	mc_stats_conn_line(b, fd, "secs_since_last_cmd", value[:n])
}

@(private = "file")
mc_stats_conns :: proc(b: ^[dynamic]u8, self: ^Conn) {
	listener_done := mc_lfd < 0
	emit_listener :: proc(b: ^[dynamic]u8) {
		local: linux.Sock_Addr_Any
		text: [128]u8
		n := 0
		if linux.getsockname(mc_lfd, &local) == .NONE {
			n = transport_format(text[:], &local)
		}
		mc_stats_conn_addr(b, mc_lfd, "addr", text[:n])
		mc_stats_conn_line(b, mc_lfd, "state", transmute([]u8)string("conn_listening"))
		mc_stats_conn_seconds(b, mc_lfd, srv.start_ms)
	}
	for c, fd in srv.conns {
		if !listener_done && linux.Fd(fd) > mc_lfd {
			emit_listener(b)
			listener_done = true
		}
		if c == nil || c.kind != .Memcached {
			continue
		}
		state := "conn_read"
		switch {
		case c == self:
			state = "conn_parse_cmd"
		case c.need != 0:
			state = "conn_nread"
		case c.atime_ms == c.ctime_ms:
			state = "conn_new_cmd"
		}
		mc_stats_conn_addr(b, c.fd, "addr", c.addr[:c.addr_len])
		mc_stats_conn_addr(b, c.fd, "listen_addr", conn_laddr(c))
		mc_stats_conn_line(b, c.fd, "state", transmute([]u8)state)
		mc_stats_conn_seconds(b, c.fd, srv.now_ms if c == self else c.atime_ms)
	}
	if !listener_done {
		emit_listener(b)
	}
}

@(private = "file")
mc_parse_slab_number :: proc "contextless" (s: []u8) -> (u32, bool) {
	v, ok := mc_parse_digits(s, len(s))
	if !ok || v > u64(max(u32)) {
		return 0, false
	}
	return u32(v), true
}

@(private = "file")
mc_stats_cachedump :: proc(c: ^Conn, t: ^Mc_Line) -> bool {
	if t.ntok < 4 {
		mc_out(c, MC_ERR_LINE)
		return false
	}
	id, id_ok := mc_parse_slab_number(t.tok[2])
	_, limit_ok := mc_parse_slab_number(t.tok[3])
	if !id_ok || !limit_ok {
		mc_out(c, MC_ERR_FORMAT)
		return false
	}
	if id >= MC_SLAB_CLASSES {
		mc_out(c, MC_ERR_SLAB_ID)
		return false
	}
	return true
}

@(private = "file")
mc_stats_detail :: proc(c: ^Conn, t: ^Mc_Line, b: ^[dynamic]u8) -> bool {
	mode := string(t.tok[2]) if t.ntok >= 3 else ""
	switch mode {
	case "on", "off":
		mc_detail_on = mode == "on"
		mc_out(c, "OK\r\n")
		return false
	case "dump":
		mc_stats_detail_dump(b)
		return true
	}
	mc_out(c, MC_ERR_DETAIL_USAGE)
	return false
}

mc_parse_size :: proc "contextless" (s: []u8) -> (int, bool) {
	n := len(s)
	if n == 0 {
		return 0, false
	}
	mult: u64 = 1
	switch s[n - 1] {
	case 'k', 'K':
		mult = 1024
		n -= 1
	case 'm', 'M':
		mult = 1024 * 1024
		n -= 1
	}
	v, ok := mc_parse_digits(s[:n], 12)
	if !ok || v > u64(MC_ITEM_SIZE_MAX) / mult {
		return 0, false
	}
	v *= mult
	if v < MC_ITEM_SIZE_MIN || v > MC_ITEM_SIZE_MAX {
		return 0, false
	}
	return int(v), true
}

mc_listen :: proc() -> bool {
	if mc_port == 0 {
		return true
	}
	fd, ok := server_listen(mc_port)
	if !ok {
		return false
	}
	mc_lfd = fd
	return true
}

mc_conn_count :: proc() -> int {
	n := 0
	for c in srv.conns {
		if c != nil && c.kind == .Memcached {
			n += 1
		}
	}
	return n
}

mc_changed :: proc(db: ^Db, key: []u8, class: Notify_Class, event: string) {
	signal_key_in(key, db)
	notify_in(class, event, key, db)
	pst.dirty += 1
}

mc_cas_next :: #force_inline proc "contextless" () -> u64 {
	mc_cas_last += 1
	return mc_cas_last
}

mc_item_size :: #force_inline proc "contextless" (klen: int, vlen: int, flags: u32) -> int {
	return klen + vlen + MC_ITEM_FIXED_BYTES + (MC_ITEM_FLAGS_BYTES if flags != 0 else 0)
}

@(private = "file")
mc_hash :: #force_inline proc "contextless" (h: u64) -> u64 {
	z := h
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

@(private = "file")
mc_table_alloc :: proc "contextless" (t: ^Mc_Table, cap: int) {
	p := ([^]Mc_Meta)(runtime.heap_alloc(cap * size_of(Mc_Meta), true))
	if p == nil {
		store_fatal("out of memory")
	}
	t.slots = p
	t.cap = cap
	db_used_memory += cap * size_of(Mc_Meta)
}

@(private = "file")
mc_table_resize :: proc "contextless" (t: ^Mc_Table, cap: int) #no_bounds_check {
	old := t.slots
	old_cap := t.cap
	mc_table_alloc(t, cap)
	mask := u64(cap - 1)
	for i in 0 ..< old_cap {
		m := old[i]
		if m.handle == 0 {
			continue
		}
		j := mc_hash(m.handle) & mask
		for t.slots[j].handle != 0 {
			j = (j + 1) & mask
		}
		t.slots[j] = m
	}
	db_used_memory -= old_cap * size_of(Mc_Meta)
	mem_free(old)
}

@(private = "file")
mc_table_free :: proc "contextless" (db: ^Db) {
	t := db.mc
	db_used_memory -= t.cap * size_of(Mc_Meta) + size_of(Mc_Table)
	mem_free(t.slots)
	mem_free(t)
	db.mc = nil
}

@(private = "file")
mc_meta_find :: proc "contextless" (t: ^Mc_Table, handle: u64) -> int #no_bounds_check {
	mask := u64(t.cap - 1)
	i := mc_hash(handle) & mask
	for {
		h := t.slots[i].handle
		if h == handle {
			return int(i)
		}
		if h == 0 {
			return -1
		}
		i = (i + 1) & mask
	}
}

mc_meta_get :: proc "contextless" (db: ^Db, kp: ^Key_Handle) -> ^Mc_Meta #no_bounds_check {
	t := db.mc
	if t == nil {
		return nil
	}
	i := mc_meta_find(t, kp.bits & KEY_CMP_MASK)
	if i < 0 {
		return nil
	}
	return &t.slots[i]
}

mc_meta_set :: proc "contextless" (db: ^Db, kp: ^Key_Handle, cas: u64, flags: u32, size: int) #no_bounds_check {
	handle := kp.bits & KEY_CMP_MASK
	t := db.mc
	if t == nil {
		t = (^Mc_Table)(runtime.heap_alloc(size_of(Mc_Table), true))
		if t == nil {
			store_fatal("out of memory")
		}
		db_used_memory += size_of(Mc_Table)
		mc_table_alloc(t, MC_META_MIN_CAP)
		db.mc = t
	} else if (t.live + 1) * 8 > t.cap * 5 {
		mc_table_resize(t, t.cap * 2)
	}
	mask := u64(t.cap - 1)
	i := mc_hash(handle) & mask
	for {
		m := &t.slots[i]
		if m.handle == handle {
			t.bytes += size - int(m.size)
			m.cas = cas
			m.flags = flags
			m.size = u32(size)
			return
		}
		if m.handle == 0 {
			m^ = Mc_Meta{handle, cas, flags, u32(size)}
			t.live += 1
			t.bytes += size
			return
		}
		i = (i + 1) & mask
	}
}

mc_meta_drop :: proc "contextless" (db: ^Db, bits: u64) #no_bounds_check {
	t := db.mc
	idx := mc_meta_find(t, bits & KEY_CMP_MASK)
	if idx < 0 {
		return
	}
	t.bytes -= int(t.slots[idx].size)
	t.live -= 1
	if t.live == 0 {
		mc_table_free(db)
		return
	}
	mask := u64(t.cap - 1)
	i := u64(idx)
	j := i
	for {
		j = (j + 1) & mask
		h := t.slots[j].handle
		if h == 0 {
			break
		}
		home := mc_hash(h) & mask
		if (j - home) & mask >= (j - i) & mask {
			t.slots[i] = t.slots[j]
			i = j
		}
	}
	t.slots[i] = {}
	if t.cap > MC_META_MIN_CAP * 4 && t.live * 16 < t.cap {
		mc_table_resize(t, t.cap / 4)
	}
}

mc_meta_on_erase :: #force_inline proc "contextless" (db: ^Db, kp: ^Key_Handle) {
	if db.mc != nil {
		mc_meta_drop(db, kp.bits)
	}
}

mc_meta_on_write :: #force_inline proc "contextless" (db: ^Db, kp: ^Key_Handle) {
	if db.mc != nil && !mc_writing {
		mc_meta_drop(db, kp.bits)
	}
}

mc_meta_on_flush :: proc "contextless" (db: ^Db) {
	if db.mc != nil {
		mc_table_free(db)
	}
}

mc_isspace :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == ' ' || (b >= '\t' && b <= '\r')
}

mc_parse_digits :: proc "contextless" (s: []u8, max_len: int) -> (u64, bool) #no_bounds_check {
	n := len(s)
	if n == 0 || n > max_len {
		return 0, false
	}
	v: u64 = 0
	for i in 0 ..< n {
		d := u64(s[i]) - '0'
		if d > 9 || v > (max(u64) - d) / 10 {
			return 0, false
		}
		v = v * 10 + d
	}
	return v, true
}

mc_parse_exptime32 :: proc "contextless" (s: []u8) -> (i64, bool) {
	if len(s) == 0 || len(s) > MC_SHORT_NUM {
		return 0, false
	}
	neg := s[0] == '-'
	if neg && len(s) == 1 {
		return 0, true
	}
	v, ok := mc_parse_digits(s[1:] if neg else s, MC_SHORT_NUM)
	if !ok {
		return 0, false
	}
	if neg {
		if v > 2147483648 {
			return 0, false
		}
		return -i64(v), true
	}
	if v > 2147483647 {
		return 0, false
	}
	return i64(v), true
}

@(private = "file")
mc_scan_text_number :: proc "contextless" (text: []u8) -> (magnitude: u128, negative: bool, ok: bool) #no_bounds_check {
	at := 0
	for at < len(text) && mc_isspace(text[at]) {
		at += 1
	}
	if at < len(text) && (text[at] == '+' || text[at] == '-') {
		negative = text[at] == '-'
		at += 1
	}
	digits_from := at
	for at < len(text) && text[at] >= '0' && text[at] <= '9' {
		magnitude = magnitude * 10 + u128(text[at] - '0')
		if magnitude > u128(max(u64)) {
			return 0, false, false
		}
		at += 1
	}
	if at == digits_from {
		return 0, false, false
	}
	ok = at == len(text) || text[at] == 0 || mc_isspace(text[at])
	return
}

mc_text_unsigned :: proc "contextless" (text: []u8) -> (u64, bool) {
	magnitude, negative, ok := mc_scan_text_number(text)
	if !ok {
		return 0, false
	}
	signed := -i128(magnitude) if negative else i128(magnitude)
	wrapped := u64(signed & i128(max(u64)))
	if wrapped >= 1 << 63 && negative {
		return 0, false
	}
	return wrapped, true
}

mc_text_signed :: proc "contextless" (text: []u8) -> (i64, bool) {
	magnitude, negative, ok := mc_scan_text_number(text)
	signed := -i128(magnitude) if negative else i128(magnitude)
	if !ok || signed < i128(min(i64)) || signed > i128(max(i64)) {
		return 0, false
	}
	return i64(signed), true
}

mc_fmt_u64 :: proc "contextless" (dst: [^]u8, v: u64) -> int #no_bounds_check {
	tmp: [20]u8
	i := 20
	x := v
	for {
		i -= 1
		tmp[i] = u8('0' + x % 10)
		x /= 10
		if x == 0 {
			break
		}
	}
	n := 20 - i
	intrinsics.mem_copy_non_overlapping(dst, &tmp[i], n)
	return n
}

mc_out :: proc(c: ^Conn, s: string) #no_bounds_check {
	if mc_noreply {
		return
	}
	n := len(s)
	p := wb_reserve(c, n)
	intrinsics.mem_copy_non_overlapping(p, raw_data(s), n)
	c.wlen += n
	mc_stats.bytes_written += u64(n)
}

mc_out_bytes :: proc(c: ^Conn, s: []u8) {
	mc_out(c, string(s))
}

@(private = "file")
mc_drop :: proc(c: ^Conn) {
	c.wlen = c.wpos
	c.close_after = true
}

@(private = "file")
mc_discard_pending :: proc(c: ^Conn) {
	d := u64(c.wlen - c.wpos)
	mc_stats.bytes_written = mc_stats.bytes_written - d if mc_stats.bytes_written >= d else 0
	c.wlen = c.wpos
}

@(private = "file")
mc_emit_value :: proc(c: ^Conn, key: []u8, flags: u32, val: []u8, cas: u64, with_cas: bool) #no_bounds_check {
	klen := len(key)
	vlen := len(val)
	p := wb_reserve(c, klen + vlen + 72)
	head := "VALUE "
	intrinsics.mem_copy_non_overlapping(p, raw_data(head), len(head))
	o := len(head)
	if klen > 0 {
		intrinsics.mem_copy_non_overlapping(&p[o], raw_data(key), klen)
		o += klen
	}
	p[o] = ' '
	o += 1
	o += mc_fmt_u64(&p[o], u64(flags))
	p[o] = ' '
	o += 1
	o += mc_fmt_u64(&p[o], u64(vlen))
	if with_cas {
		p[o] = ' '
		o += 1
		o += mc_fmt_u64(&p[o], cas)
	}
	p[o] = '\r'
	p[o + 1] = '\n'
	o += 2
	if vlen > 0 {
		intrinsics.mem_copy_non_overlapping(&p[o], raw_data(val), vlen)
		o += vlen
	}
	p[o] = '\r'
	p[o + 1] = '\n'
	o += 2
	c.wlen += o
	mc_stats.bytes_written += u64(o)
}

@(private = "file")
mc_find_nl :: #force_inline proc "contextless" (b: []u8) -> int #no_bounds_check {
	for i in 0 ..< len(b) {
		if b[i] == '\n' {
			return i
		}
	}
	return -1
}

@(private = "file")
mc_is_get_line :: proc "contextless" (b: []u8) -> bool {
	if len(b) >= 4 && string(b[:4]) == "get " {
		return true
	}
	return len(b) >= 5 && string(b[:5]) == "gets "
}

@(private = "file")
mc_tokenize :: proc "contextless" (t: ^Mc_Line, line: []u8) #no_bounds_check {
	n := len(line)
	i := 0
	if n > 0 && line[0] == ' ' {
		t.tok[0] = line[:0]
		t.ntok = 1
		t.last = t.tok[0]
	}
	for i < n {
		for i < n && line[i] == ' ' {
			i += 1
		}
		if i >= n {
			break
		}
		s := i
		for i < n && line[i] != ' ' {
			i += 1
		}
		tk := line[s:i]
		if t.ntok < MC_TOKEN_SLOTS {
			t.tok[t.ntok] = tk
		}
		t.ntok += 1
		t.last = tk
	}
}

@(private = "file")
mc_take_noreply :: proc(t: ^Mc_Line, min_tokens: int) -> int {
	if t.ntok >= max(min_tokens, 2) && t.ntok <= MC_LAST_TOKEN_SCAN_TOKENS && string(t.last) == "noreply" {
		mc_noreply = true
		return t.ntok - 1
	}
	return t.ntok
}

@(private = "file")
mc_expire_at :: proc(exptime: i64) -> (at: i64, dead: bool) {
	if exptime < 0 {
		return 0, true
	}
	if exptime > MC_RELATIVE_EXPIRY_LIMIT_SECONDS {
		at = exptime * 1000
		if at <= srv.now_ms {
			return 0, true
		}
	} else if exptime > 0 {
		at = srv.now_ms + exptime * 1000
	}
	if mc_flush_at != 0 {
		if mc_flush_at <= srv.now_ms {
			mc_flush_at = 0
		} else if at == 0 || at > mc_flush_at {
			at = mc_flush_at
		}
	}
	return at, false
}

@(private = "file")
mc_delete :: proc(db: ^Db, key: []u8) -> bool {
	found, expired := db_remove_in(db, key)
	if expired {
		srv.stat_expired += 1
		key_expired_event(key, db)
	}
	if found && !expired {
		mc_changed(db, key, .Generic, "del")
		if aof.feed {
			aof_mc_command(aof_bytes("DEL"), key)
		}
		return true
	}
	return false
}

@(private = "file")
mc_store_dead :: proc(db: ^Db, key: []u8) {
	_, expired := db_remove_in(db, key)
	if expired {
		srv.stat_expired += 1
		key_expired_event(key, db)
	}
	mc_changed(db, key, .String, "set")
	notify_in(.Generic, "expire", key, db)
	key_expired_event(key, db)
}

@(private = "file")
mc_apply_ttl :: proc(db: ^Db, e: ^Entry, key: []u8, exptime: i64) {
	at, dead := mc_expire_at(exptime)
	if dead {
		mc_delete(db, key)
		return
	}
	before := e.expire_at
	entry_set_expire(e, at)
	if at != 0 {
		mc_changed(db, key, .Generic, "expire")
		if aof.feed {
			aof_mc_pexpireat(key, at)
		}
	} else if before != 0 {
		mc_changed(db, key, .Generic, "persist")
		if aof.feed {
			aof_mc_command(aof_bytes("PERSIST"), key)
		}
	}
}

@(private = "file")
mc_cap_all :: proc(db: ^Db, at: i64) #no_bounds_check {
	for k in 0 ..< 2 {
		if k == 1 && db.rehash_idx < 0 {
			break
		}
		t := &db.t[k]
		if t.live == 0 {
			continue
		}
		for g in 0 ..= t.gmask {
			full := group_full(group_load(t.ctrl, g))
			for full != 0 {
				i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
				full &= full - 1
				mp := &t.slots[i].meta
				exp := i64(mp.expire_at) if db.expires > 0 else 0
				if exp == 0 {
					db.expires += 1
					mp.expire_at = u64(at)
				} else if exp > at {
					mp.expire_at = u64(at)
				} else {
					continue
				}
				if aof.feed {
					aof_mc_pexpireat(key_bytes(&t.slots[i].key, &db.slab), at)
				}
			}
		}
	}
}

@(private = "file")
mc_flush :: proc(delay: i64) {
	db := &dbs[0]
	if delay > 0 {
		at: i64
		if delay > MC_RELATIVE_EXPIRY_LIMIT_SECONDS {
			at = delay * 1000
			if at <= srv.start_ms {
				return
			}
		} else {
			at = srv.now_ms + delay * 1000
		}
		if at > srv.now_ms {
			mc_flush_at = at
			mc_cap_all(db, at)
			pst.dirty += 1
			return
		}
	}
	mc_flush_at = 0
	removed := i64(db_size_of(db))
	watch_flush(db)
	db_flush_in(db)
	block_note_removed()
	tracking_flush()
	persist_flushed(false, removed)
	if aof.feed {
		aof_mc_command(aof_bytes("FLUSHDB"))
	}
}

@(private = "file")
mc_get_key :: proc(c: ^Conn, db: ^Db, key: []u8, mode: Mc_Get, exptime: i64) {
	touch := mode == .Gat || mode == .Gats
	expired_before := srv.stat_expired
	e := db_find_in(db, key)
	if touch {
		mc_stats.cmd_touch += 1
	} else {
		mc_stats.cmd_get += 1
	}
	prefix := mc_prefix_of(key)
	if prefix != nil {
		prefix.get += 1
	}
	if e == nil || !entry_is_string(e) {
		if touch {
			mc_stats.touch_misses += 1
		} else {
			mc_stats.get_misses += 1
			if srv.stat_expired != expired_before {
				mc_stats.get_expired += 1
			}
		}
		srv.stat_misses += 1
		notify_in(.Key_Miss, "keymiss", key, db)
		return
	}
	if touch {
		mc_stats.touch_hits += 1
	} else {
		mc_stats.get_hits += 1
	}
	if prefix != nil {
		prefix.hit += 1
	}
	srv.stat_hits += 1
	with_cas := mode == .Gets || mode == .Gats
	flags: u32 = 0
	cas: u64 = 0
	if m := mc_meta_get(db, e.kp); m != nil {
		flags = m.flags
		cas = m.cas
	} else if with_cas {
		cas = mc_cas_next()
		mc_meta_set(db, e.kp, cas, 0, 0)
	}
	mc_emit_value(c, key, flags, e.val, cas, with_cas)
	if touch {
		mc_apply_ttl(db, e, key, exptime)
	}
}

@(private = "file")
mc_cmd_get :: proc(c: ^Conn, rest: []u8, mode: Mc_Get, exptime: i64) #no_bounds_check {
	db := &dbs[0]
	n := len(rest)
	i := 0
	keys := 0
	for {
		for i < n && rest[i] == ' ' {
			i += 1
		}
		if i >= n {
			break
		}
		s := i
		for i < n && rest[i] != ' ' {
			i += 1
		}
		key := rest[s:i]
		keys += 1
		if len(key) > MC_KEY_MAX {
			mc_discard_pending(c)
			mc_out(c, MC_ERR_GET_KEY)
			return
		}
		mc_get_key(c, db, key, mode, exptime)
	}
	if keys == 0 {
		mc_out(c, MC_ERR_FORMAT)
		return
	}
	mc_out(c, "END\r\n")
}

@(private = "file")
mc_cmd_gat :: proc(c: ^Conn, t: ^Mc_Line, line: []u8, with_cas: bool) {
	if t.ntok < 3 {
		mc_out(c, MC_ERR_FORMAT)
		return
	}
	exptime, ok := mc_parse_exptime32(t.tok[1])
	if !ok {
		mc_out(c, MC_ERR_EXPTIME)
		return
	}
	off := int(uintptr(raw_data(t.tok[1])) - uintptr(raw_data(line))) + len(t.tok[1])
	mc_cmd_get(c, line[off:], .Gats if with_cas else .Gat, exptime)
}

mc_deferred_text :: proc "contextless" (d: Mc_Deferred) -> string {
	switch d {
	case .Format:
		return MC_ERR_FORMAT
	case .Too_Large:
		return MC_ERR_TOO_LARGE
	case .No_Memory:
		return MC_ERR_NO_MEMORY
	case .None:
	}
	return ""
}

@(private = "file")
mc_swallow :: proc(c: ^Conn, buf: []u8, used: int, n: int, reply: Mc_Deferred) -> int {
	d := Mc_Deferred.None if mc_noreply else reply
	avail := len(buf) - used
	if avail >= n {
		mc_out(c, mc_deferred_text(d))
		return used + n
	}
	c.need = -((n - avail) << 2 | int(d))
	return len(buf)
}

@(private = "file")
mc_swallow_step :: proc(c: ^Conn) {
	state := -c.need
	left := state >> 2
	n := min(left, c.rlen - c.rpos)
	c.rpos += n
	mc_stats.bytes_read += u64(n)
	left -= n
	if left > 0 {
		c.need = -(left << 2 | (state & 3))
		return
	}
	c.need = 0
	mc_noreply = false
	mc_out(c, mc_deferred_text(Mc_Deferred(state & 3)))
}

@(private = "file")
mc_write :: proc(db: ^Db, e: ^Entry, key: []u8, data: []u8, flags: u32, at: i64, id: u64) {
	mc_writing = true
	entry_assign(e, data)
	mc_writing = false
	entry_set_expire(e, at)
	mc_meta_set(db, e.kp, id, flags, mc_item_size(len(key), len(data), flags))
	mc_stats.total_items += 1
	mc_changed(db, key, .String, "set")
	if at != 0 {
		notify_in(.Generic, "expire", key, db)
	}
	if aof.feed {
		aof_mc_set(key, data, at, false)
	}
}

@(private = "file")
mc_concat :: proc(c: ^Conn, db: ^Db, op: Mc_Store, key: []u8, data: []u8, id: u64) {
	e := db_find_in(db, key)
	if e == nil || !entry_is_string(e) {
		mc_out(c, "NOT_STORED\r\n")
		return
	}
	flags: u32 = 0
	if m := mc_meta_get(db, e.kp); m != nil {
		flags = m.flags
	}
	newlen := len(e.val) + len(data)
	if mc_item_size(len(key), newlen, flags) > mc_item_size_max {
		mc_out(c, "NOT_STORED\r\n")
		return
	}
	mc_writing = true
	if op == .Append {
		entry_append(e, data)
	} else {
		clear(&mc_tmp)
		append(&mc_tmp, ..data)
		append(&mc_tmp, ..e.val)
		entry_assign(e, mc_tmp[:])
	}
	mc_writing = false
	mc_meta_set(db, e.kp, id, flags, mc_item_size(len(key), newlen, flags))
	mc_stats.total_items += 1
	mc_changed(db, key, .String, "append")
	if aof.feed {
		if op == .Append {
			aof_mc_command(aof_bytes("APPEND"), key, data)
		} else {
			aof_mc_set(key, mc_tmp[:], 0, true)
		}
	}
	mc_out(c, "STORED\r\n")
}

@(private = "file")
mc_store :: proc(c: ^Conn, op: Mc_Store, key: []u8, flags: u32, exptime: i64, data: []u8, cas_in: u64) {
	db := &dbs[0]
	id := mc_cas_next()
	if op == .Append || op == .Prepend {
		mc_concat(c, db, op, key, data, id)
		return
	}
	at, dead := mc_expire_at(exptime)
	e: ^Entry
	switch op {
	case .Set:
		if !dead {
			e, _ = db_upsert_in(db, key)
		}
	case .Add:
		if db_find_in(db, key) != nil {
			mc_out(c, "NOT_STORED\r\n")
			return
		}
		if !dead {
			e, _ = db_upsert_in(db, key)
		}
	case .Replace:
		e = db_find_in(db, key)
		if e == nil {
			mc_out(c, "NOT_STORED\r\n")
			return
		}
	case .Cas:
		e = db_find_in(db, key)
		if e == nil {
			mc_stats.cas_misses += 1
			mc_out(c, "NOT_FOUND\r\n")
			return
		}
		m := mc_meta_get(db, e.kp)
		if m == nil || m.cas != cas_in {
			mc_stats.cas_badval += 1
			mc_out(c, "EXISTS\r\n")
			return
		}
		mc_stats.cas_hits += 1
	case .Append, .Prepend:
	}
	if dead {
		mc_store_dead(db, key)
		mc_stats.total_items += 1
		mc_out(c, "STORED\r\n")
		return
	}
	mc_write(db, e, key, data, flags, at, id)
	mc_out(c, "STORED\r\n")
}

@(private = "file")
mc_cmd_store :: proc(c: ^Conn, t: ^Mc_Line, op: Mc_Store, buf: []u8, used: int) -> int {
	ntok := mc_take_noreply(t, 2)
	vlen := -1
	if ntok >= 5 {
		if v, ok := mc_parse_exptime32(t.tok[4]); ok && v >= 0 && v <= MC_VLEN_MAX {
			vlen = int(v)
		}
	}
	if vlen < 0 {
		mc_noreply = false
		mc_out(c, MC_ERR_FORMAT)
		return used
	}
	key := t.tok[1]
	flags: u64
	exptime: i64
	cas_in: u64
	flags_ok, exp_ok, cas_ok := false, false, true
	if ntok >= (6 if op == .Cas else 5) && len(key) <= MC_KEY_MAX {
		flags, flags_ok = mc_text_unsigned(t.tok[2])
		exptime, exp_ok = mc_text_signed(t.tok[3])
		if op == .Cas {
			cas_in, cas_ok = mc_parse_digits(t.tok[5], MC_LONG_NUM)
		}
	}
	if !flags_ok || !exp_ok || !cas_ok {
		return mc_swallow(c, buf, used, vlen + 2, .Format)
	}
	f := u32(flags)
	if mc_item_size(len(key), vlen, f) > mc_item_size_max {
		mc_stats.store_too_large += 1
		if op == .Set {
			mc_delete(&dbs[0], key)
		}
		return mc_swallow(c, buf, used, vlen + 2, .Too_Large)
	}
	if mc_oom {
		mc_stats.store_no_memory += 1
		if op == .Set {
			mc_delete(&dbs[0], key)
		}
		return mc_swallow(c, buf, used, vlen + 2, .No_Memory)
	}
	total := used + vlen + 2
	if len(buf) < total {
		c.need = total
		return 0
	}
	mc_stats.cmd_set += 1
	if p := mc_prefix_of(key); p != nil {
		p.set += 1
	}
	if buf[total - 2] != '\r' || buf[total - 1] != '\n' {
		mc_out(c, MC_ERR_CHUNK)
		return total
	}
	mc_store(c, op, key, f, i64(i32(exptime)), buf[used:used + vlen], cas_in)
	return total
}

@(private = "file")
mc_cmd_delete :: proc(c: ^Conn, t: ^Mc_Line) {
	ntok := mc_take_noreply(t, 2)
	if ntok < 2 || len(t.tok[1]) > MC_KEY_MAX {
		mc_out(c, MC_ERR_FORMAT)
		return
	}
	if p := mc_prefix_of(t.tok[1]); p != nil {
		p.del += 1
	}
	if mc_delete(&dbs[0], t.tok[1]) {
		mc_stats.delete_hits += 1
		mc_out(c, "DELETED\r\n")
		return
	}
	mc_stats.delete_misses += 1
	mc_out(c, "NOT_FOUND\r\n")
}

@(private = "file")
mc_cmd_arith :: proc(c: ^Conn, t: ^Mc_Line, incr: bool) #no_bounds_check {
	ntok := mc_take_noreply(t, 3)
	if ntok < 3 || len(t.tok[1]) > MC_KEY_MAX {
		mc_out(c, MC_ERR_FORMAT)
		return
	}
	key := t.tok[1]
	delta, ok := mc_parse_digits(t.tok[2], MC_LONG_NUM)
	if !ok {
		mc_out(c, MC_ERR_DELTA)
		return
	}
	db := &dbs[0]
	e := db_find_in(db, key)
	if e == nil {
		if incr {
			mc_stats.incr_misses += 1
		} else {
			mc_stats.decr_misses += 1
		}
		mc_out(c, "NOT_FOUND\r\n")
		return
	}
	if !entry_is_string(e) {
		mc_out(c, MC_ERR_NON_NUMERIC)
		return
	}
	cur, numeric := mc_text_unsigned(e.val)
	if !numeric {
		mc_out(c, MC_ERR_NON_NUMERIC)
		return
	}
	nv: u64
	if incr {
		mc_stats.incr_hits += 1
		nv = cur + delta
	} else {
		mc_stats.decr_hits += 1
		nv = cur - delta if cur >= delta else 0
	}
	id := mc_cas_next()
	digits: [24]u8
	dn := mc_fmt_u64(&digits[0], nv)
	old := len(e.val)
	flags: u32 = 0
	if m := mc_meta_get(db, e.kp); m != nil {
		flags = m.flags
	}
	size := old
	mc_writing = true
	if dn <= old {
		clear(&mc_tmp)
		resize(&mc_tmp, old)
		for i in 0 ..< old {
			mc_tmp[i] = digits[i] if i < dn else ' '
		}
		entry_assign(e, mc_tmp[:])
		if aof.feed {
			aof_mc_set(key, mc_tmp[:], 0, true)
		}
	} else {
		entry_assign(e, digits[:dn])
		size = dn
		mc_stats.total_items += 1
		if aof.feed {
			aof_mc_set(key, digits[:dn], 0, true)
		}
	}
	mc_writing = false
	mc_meta_set(db, e.kp, id, flags, mc_item_size(len(key), size, flags))
	mc_changed(db, key, .String, "incrby")
	digits[dn] = '\r'
	digits[dn + 1] = '\n'
	mc_out_bytes(c, digits[:dn + 2])
}

@(private = "file")
mc_cmd_touch :: proc(c: ^Conn, t: ^Mc_Line) {
	ntok := mc_take_noreply(t, 3)
	if ntok < 3 || len(t.tok[1]) > MC_KEY_MAX {
		mc_out(c, MC_ERR_FORMAT)
		return
	}
	exptime, ok := mc_parse_exptime32(t.tok[2])
	if !ok {
		mc_out(c, MC_ERR_EXPTIME)
		return
	}
	db := &dbs[0]
	key := t.tok[1]
	mc_stats.cmd_touch += 1
	e := db_find_in(db, key)
	if e == nil {
		mc_stats.touch_misses += 1
		mc_out(c, "NOT_FOUND\r\n")
		return
	}
	mc_stats.touch_hits += 1
	mc_apply_ttl(db, e, key, exptime)
	mc_out(c, "TOUCHED\r\n")
}

@(private = "file")
mc_cmd_flush :: proc(c: ^Conn, t: ^Mc_Line) {
	ntok := mc_take_noreply(t, 2)
	delay: i64 = 0
	if ntok >= 2 {
		d, ok := mc_parse_exptime32(t.tok[1])
		if !ok {
			mc_out(c, MC_ERR_EXPTIME)
			return
		}
		delay = d
	}
	mc_stats.cmd_flush += 1
	mc_flush(delay)
	mc_out(c, "OK\r\n")
}

@(private = "file")
mc_cmd_verbosity :: proc(c: ^Conn, t: ^Mc_Line) {
	ntok := mc_take_noreply(t, 2)
	if ntok < 2 {
		mc_out(c, MC_ERR_FORMAT)
		return
	}
	v, ok := mc_parse_digits(t.tok[1], MC_SHORT_NUM)
	if !ok || v > u64(max(u32)) {
		mc_out(c, MC_ERR_FORMAT)
		return
	}
	mc_verbosity = u32(v)
	mc_out(c, "OK\r\n")
}

@(private = "file")
mc_stat :: proc(b: ^[dynamic]u8, name: string, v: u64) {
	tmp: [24]u8
	n := mc_fmt_u64(&tmp[0], v)
	sb_str(b, "STAT ")
	sb_str(b, name)
	sb_byte(b, ' ')
	sb_bytes(b, tmp[:n])
	sb_str(b, "\r\n")
}

@(private = "file")
mc_stat_str :: proc(b: ^[dynamic]u8, name: string, v: string) {
	sb_str(b, "STAT ")
	sb_str(b, name)
	sb_byte(b, ' ')
	sb_str(b, v)
	sb_str(b, "\r\n")
}

@(private = "file")
mc_stat_time :: proc(b: ^[dynamic]u8, name: string, tv: linux.Time_Val) {
	tmp: [24]u8
	sb_str(b, "STAT ")
	sb_str(b, name)
	sb_byte(b, ' ')
	n := mc_fmt_u64(&tmp[0], u64(tv.seconds))
	sb_bytes(b, tmp[:n])
	sb_byte(b, '.')
	n = mc_fmt_u64(&tmp[0], u64(tv.microseconds))
	for _ in n ..< 6 {
		sb_byte(b, '0')
	}
	sb_bytes(b, tmp[:n])
	sb_str(b, "\r\n")
}

@(private = "file")
mc_stats_general :: proc(b: ^[dynamic]u8) {
	db := &dbs[0]
	ru: linux.RUsage
	linux.getrusage(.SELF, &ru)
	s := &mc_stats
	mc_stat(b, "pid", u64(srv.pid))
	mc_stat(b, "uptime", u64((srv.now_ms - srv.start_ms) / 1000))
	mc_stat(b, "time", u64(srv.now_ms / 1000))
	mc_stat_str(b, "version", VERSION)
	mc_stat(b, "pointer_size", u64(size_of(rawptr) * 8))
	mc_stat_time(b, "rusage_user", ru.utime)
	mc_stat_time(b, "rusage_system", ru.stime)
	mc_stat(b, "curr_connections", u64(mc_conn_count() + 1))
	mc_stat(b, "total_connections", s.total_conns)
	mc_stat(b, "rejected_connections", 0)
	mc_stat(b, "cmd_get", s.cmd_get)
	mc_stat(b, "cmd_set", s.cmd_set)
	mc_stat(b, "cmd_flush", s.cmd_flush)
	mc_stat(b, "cmd_touch", s.cmd_touch)
	mc_stat(b, "get_hits", s.get_hits)
	mc_stat(b, "get_misses", s.get_misses)
	mc_stat(b, "get_expired", s.get_expired)
	mc_stat(b, "get_flushed", 0)
	mc_stat(b, "delete_misses", s.delete_misses)
	mc_stat(b, "delete_hits", s.delete_hits)
	mc_stat(b, "incr_misses", s.incr_misses)
	mc_stat(b, "incr_hits", s.incr_hits)
	mc_stat(b, "decr_misses", s.decr_misses)
	mc_stat(b, "decr_hits", s.decr_hits)
	mc_stat(b, "cas_misses", s.cas_misses)
	mc_stat(b, "cas_hits", s.cas_hits)
	mc_stat(b, "cas_badval", s.cas_badval)
	mc_stat(b, "touch_hits", s.touch_hits)
	mc_stat(b, "touch_misses", s.touch_misses)
	mc_stat(b, "store_too_large", s.store_too_large)
	mc_stat(b, "store_no_memory", s.store_no_memory)
	mc_stat(b, "auth_cmds", 0)
	mc_stat(b, "auth_errors", 0)
	mc_stat(b, "bytes_read", s.bytes_read)
	mc_stat(b, "bytes_written", s.bytes_written)
	mc_stat(b, "limit_maxbytes", maxmemory_bytes)
	mc_stat(b, "accepting_conns", 1)
	mc_stat(b, "listen_disabled_num", 0)
	mc_stat(b, "time_in_listen_disabled_us", 0)
	mc_stat(b, "threads", 1)
	mc_stat(b, "conn_yields", 0)
	mc_stat(b, "bytes", u64(db.mc.bytes) if db.mc != nil else 0)
	mc_stat(b, "curr_items", u64(db_size_of(db)))
	mc_stat(b, "total_items", s.total_items)
	mc_stat(b, "evictions", u64(stat_evicted_keys))
	mc_stat(b, "reclaimed", 0)
}

@(private = "file")
mc_stats_settings :: proc(b: ^[dynamic]u8) {
	mc_stat(b, "maxbytes", maxmemory_bytes)
	mc_stat(b, "tcpport", u64(mc_port))
	mc_stat(b, "udpport", 0)
	mc_stat_str(b, "inter", srv.bind_str)
	mc_stat(b, "verbosity", u64(mc_verbosity))
	mc_stat_str(b, "evictions", "off" if maxmemory_policy == .Noeviction else "on")
	mc_stat_str(b, "domain_socket", "NULL")
	mc_stat_str(b, "shutdown_command", "no")
	mc_stat(b, "num_threads", 1)
	mc_stat_str(b, "detail_enabled", "yes" if mc_detail_on else "no")
	mc_stat_str(b, "cas_enabled", "yes")
	mc_stat(b, "tcp_backlog", LISTEN_BACKLOG)
	mc_stat_str(b, "binding_protocol", "ascii")
	mc_stat_str(b, "auth_enabled_sasl", "no")
	mc_stat_str(b, "auth_enabled_ascii", "no")
	mc_stat(b, "item_size_max", u64(mc_item_size_max))
	mc_stat_str(b, "flush_enabled", "yes")
	mc_stat(b, "client_flags_size", MC_CLIENT_FLAGS_SIZE)
}

@(private = "file")
mc_cmd_stats :: proc(c: ^Conn, t: ^Mc_Line) {
	b := &scratch
	clear(b)
	if t.ntok >= 2 {
		switch string(t.tok[1]) {
		case "settings":
			mc_stats_settings(b)
		case "reset":
			mc_stats = {}
			mc_prefix_reset()
			mc_out(c, "RESET\r\n")
			return
		case "detail":
			if !mc_stats_detail(c, t, b) {
				return
			}
		case "conns":
			mc_stats_conns(b, c)
		case "cachedump":
			if !mc_stats_cachedump(c, t) {
				return
			}
		case "items", "extstore":
		case "slabs":
			mc_stat(b, "active_slabs", 0)
			mc_stat(b, "total_malloced", u64(db_used_memory))
		case "sizes":
			mc_stat_str(b, "sizes_status", "disabled")
		case:
			mc_out(c, "ERROR\r\n")
			return
		}
	} else {
		mc_stats_general(b)
	}
	sb_str(b, "END\r\n")
	mc_out_bytes(c, b[:])
}

@(private = "file")
mc_cmd_unknown :: proc(c: ^Conn, t: ^Mc_Line) {
	if t.ntok >= 2 && t.ntok <= MC_LAST_TOKEN_SCAN_TOKENS && len(t.last) >= 5 && string(t.last[:5]) == "HTTP/" {
		mc_drop(c)
		return
	}
	if t.ntok <= MC_LAST_TOKEN_SCAN_TOKENS && string(t.last) == "noreply" {
		return
	}
	mc_out(c, "ERROR\r\n")
}

@(private = "file")
mc_command :: proc(c: ^Conn, buf: []u8, nl: int) -> int #no_bounds_check {
	end := nl
	if end > 0 && buf[end - 1] == '\r' {
		end -= 1
	}
	line := buf[:end]
	used := nl + 1
	mc_noreply = false
	mc_oom = maxmemory_bytes != 0 && perform_evictions() == .Fail
	if len(line) < 2 {
		mc_out(c, MC_ERR_FORMAT)
		return used
	}
	cmd_end := 0
	for cmd_end < len(line) && line[cmd_end] != ' ' {
		cmd_end += 1
	}
	cmd := string(line[:cmd_end])
	switch cmd {
	case "get":
		mc_cmd_get(c, line[cmd_end:], .Get, 0)
		return used
	case "gets":
		mc_cmd_get(c, line[cmd_end:], .Gets, 0)
		return used
	}
	t: Mc_Line
	mc_tokenize(&t, line)
	switch cmd {
	case "set":
		return mc_cmd_store(c, &t, .Set, buf, used)
	case "add":
		return mc_cmd_store(c, &t, .Add, buf, used)
	case "replace":
		return mc_cmd_store(c, &t, .Replace, buf, used)
	case "append":
		return mc_cmd_store(c, &t, .Append, buf, used)
	case "prepend":
		return mc_cmd_store(c, &t, .Prepend, buf, used)
	case "cas":
		return mc_cmd_store(c, &t, .Cas, buf, used)
	case "delete":
		mc_cmd_delete(c, &t)
	case "incr":
		mc_cmd_arith(c, &t, true)
	case "decr":
		mc_cmd_arith(c, &t, false)
	case "touch":
		mc_cmd_touch(c, &t)
	case "gat":
		mc_cmd_gat(c, &t, line, false)
	case "gats":
		mc_cmd_gat(c, &t, line, true)
	case "flush_all":
		mc_cmd_flush(c, &t)
	case "stats":
		mc_cmd_stats(c, &t)
	case "version":
		mc_out(c, MC_VERSION_LINE)
	case "verbosity":
		mc_cmd_verbosity(c, &t)
	case "quit":
		c.close_after = true
	case "shutdown":
		mc_take_noreply(&t, 2)
		mc_out(c, MC_ERR_SHUTDOWN)
	case:
		mc_cmd_unknown(c, &t)
	}
	return used
}

mc_process_input :: proc(c: ^Conn) {
	db_cur = &dbs[0]
	store_no_touch = false
	for !c.close_after && c.rpos < c.rlen {
		if c.need < 0 {
			mc_swallow_step(c)
			continue
		}
		buf := c.rbuf[c.rpos:c.rlen]
		nl := mc_find_nl(buf)
		if nl < 0 {
			if (len(buf) > MC_LINE_MAX && !mc_is_get_line(buf)) || len(buf) > MC_GET_LINE_MAX {
				mc_drop(c)
			}
			break
		}
		used := mc_command(c, buf, nl)
		if used == 0 {
			break
		}
		if c.need > 0 {
			c.need = 0
		}
		c.rpos += used
		mc_stats.bytes_read += u64(used)
		srv.stat_commands += 1
	}
	mc_noreply = false
	if c.close_after || c.rpos >= c.rlen {
		c.rpos = 0
		c.rlen = 0
	} else if c.rpos > 0 {
		rem := c.rlen - c.rpos
		intrinsics.mem_copy(c.rbuf, &c.rbuf[c.rpos], rem)
		c.rlen = rem
		c.rpos = 0
	}
	if c.rlen == 0 && c.rcap > BUF_SHRINK_SIZE {
		conn_mem -= c.rcap - RBUF_INIT
		mem_free(c.rbuf)
		c.rbuf = mem_alloc(RBUF_INIT)
		c.rcap = RBUF_INIT
		c.rpeak = 0
		if c.need > 0 {
			c.need = 0
		}
	}
}

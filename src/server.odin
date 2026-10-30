package main

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import ht "hashtype"
import st "settype"
import zt "zsettype"

RBUF_INIT :: 16 * 1024
WBUF_INIT :: 16 * 1024
READ_MIN_FREE :: 4096
READ_BATCH_MAX :: 1 << 20
BUF_SHRINK_SIZE :: 1 << 20
MAX_EVENTS :: 1024
CRON_INTERVAL_MS :: 100
LISTEN_BACKLOG :: 1024

Conn :: struct {
	fd:          linux.Fd,
	id:          i64,
	rbuf:        [^]u8,
	rcap:        int,
	rlen:        int,
	rpos:        int,
	need:        int,
	wbuf:        [^]u8,
	wcap:        int,
	wlen:        int,
	wpos:        int,
	want_write:  bool,
	close_after: bool,
	resp:        u8,
	reply:       bit_set[Reply_Flag;u8],
	held:        bool,
	blocked:     Block_Type,
	flags:       bit_set[Client_Flag;u8],
	ps:          bit_set[Pubsub_Flag;u8],
	kind:        Conn_Kind,
	ev_bucket:   u8,
	acl_gate:    bool,
	authed:      bool,
	ever_authed: bool,
	name:        []u8,
	addr:        [24]u8,
	addr_len:    int,
	laddr:       [24]u8,
	laddr_len:   int,
	ctime_ms:    i64,
	atime_ms:    i64,
	last_cmd:    string,
	db:          ^Db,
	rpeak:       int,
	lib_name:    []u8,
	lib_ver:     []u8,
	bstate:      ^Block_State,
	wake_queued: bool,
	txf:         bit_set[Tx_Flag;u8],
	pubsub:      ^Ps_State,
	tx:          ^Tx_State,
	obuf_soft:   i64,
	ev_seq:      u64,
	user:        ^Acl_User,
	mbulk_max:   int,
	inline_owner: ^Request_Inline_Owner,
	compute:     ^Lcs_Task,
	compute_token: u64,
	read_eof:    bool,
	keyspace:    ^Keyspace_Task,
	keyspace_token: u64,
	keyspace_ready: bool,
}

Server :: struct {
	port:                int,
	bind:                [4]u8,
	bind_str:            string,
	lfds:                [CONFIG_BIND_MAX]linux.Fd,
	nlfd:                int,
	epfd:                linux.Fd,
	conns:               [dynamic]^Conn,
	nconns:              int,
	next_id:             i64,
	now_ms:              i64,
	start_ms:            i64,
	next_cron_ms:        i64,
	pid:                 i64,
	run_id:              [40]u8,
	stat_conns:          i64,
	stat_rejected_conns: i64,
	stat_commands:       i64,
	stat_expired:        i64,
	stat_hits:           i64,
	stat_misses:         i64,
	pause_end_ms:        i64,
	pause_all:           bool,
	resume_due:          bool,
	held_count:          int,
	last_timeout_ms:     i64,
}

srv: Server
events: [MAX_EVENTS]linux.EPoll_Event

update_clock :: #force_inline proc() {
	ts, _ := linux.clock_gettime(.REALTIME)
	srv.now_ms = i64(ts.time_sec) * 1000 + i64(ts.time_nsec / 1_000_000)
	lru_now = u32(srv.now_ms / 1000) & LRU_CLOCK_MAX
}

format_addr :: proc(dst: []u8, ip: [4]u8, port: int) -> int #no_bounds_check {
	n := 0
	for i in 0 ..< 4 {
		if i > 0 {
			dst[n] = '.'
			n += 1
		}
		n += format_i64(&dst[n], i64(ip[i]))
	}
	dst[n] = ':'
	n += 1
	n += format_i64(&dst[n], i64(port))
	return n
}

listen_addr :: proc(ip: [4]u8, port: int) -> (linux.Fd, linux.Errno) {
	fd, err := linux.socket(.INET, .STREAM, {.NONBLOCK, .CLOEXEC}, .TCP)
	if err != .NONE {
		return fd, err
	}
	one: i32 = 1
	linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &one)
	addr := linux.Sock_Addr_In {
		sin_family = .INET,
		sin_port   = u16be(port),
		sin_addr   = ip,
	}
	if berr := linux.bind(fd, &addr); berr != .NONE {
		linux.close(fd)
		return fd, berr
	}
	backlog := i32(clamp(cfg.tcp_backlog, 0, i64(max(i32))))
	if lerr := linux.listen(fd, backlog); lerr != .NONE {
		linux.close(fd)
		return fd, lerr
	}
	return fd, .NONE
}

server_listen :: proc(port: int) -> (linux.Fd, bool) {
	fd, err := listen_addr(srv.bind, port)
	if err != .NONE {
		write_fd(2, "eski: bind failed, address in use or not available\n")
		return fd, false
	}
	return fd, true
}

@(private = "file")
listen_fail :: proc(fds: []linux.Fd, name: string, port: int, err: string) -> (int, bool) {
	for fd in fds {
		linux.close(fd)
	}
	tmp: [24]u8
	n := format_i64(&tmp[0], i64(port))
	plog(LOG_WARNING, "Warning: Could not create server TCP listening socket ", name, ":", string(tmp[:n]), ": ", err)
	return 0, false
}

server_open_listeners :: proc(port: int, fds: ^[CONFIG_BIND_MAX]linux.Fd) -> (count: int, ok: bool) {
	if port == 0 {
		return 0, true
	}
	for a in config_bind {
		optional := len(a) > 0 && a[0] == '-'
		name := a[1:] if optional else a
		ip: [4]u8
		if name != "*" {
			is_v6 := false
			for ch in transmute([]u8)name {
				if ch == ':' {
					is_v6 = true
				}
			}
			if is_v6 {
				if optional {
					continue
				}
				return listen_fail(fds[:count], name, port, "IPv6 listening is not supported")
			}
			parsed, good := inet_aton(name)
			if !good {
				return listen_fail(fds[:count], name, port, "Name or service not known")
			}
			ip = parsed
		}
		fd, err := listen_addr(ip, port)
		if err != .NONE {
			if optional && (err == .EADDRNOTAVAIL || err == .EAFNOSUPPORT || err == .EPROTONOSUPPORT) {
				continue
			}
			return listen_fail(fds[:count], name, port, errno_text(err))
		}
		fds[count] = fd
		count += 1
	}
	return count, true
}

inet_aton :: proc(s: string) -> (addr: [4]u8, ok: bool) {
	if s == "localhost" {
		return {127, 0, 0, 1}, true
	}
	parts: [4]u64
	n := 0
	i := 0
	for {
		if n == 4 || i >= len(s) {
			return
		}
		base: u64 = 10
		if s[i] == '0' {
			base = 8
			i += 1
			if i < len(s) && (s[i] == 'x' || s[i] == 'X') {
				base = 16
				i += 1
			}
		}
		v: u64 = 0
		digits := 0
		for i < len(s) && s[i] != '.' {
			ch := s[i]
			d: u64
			switch {
			case ch >= '0' && ch <= '9':
				d = u64(ch - '0')
			case ch >= 'a' && ch <= 'f':
				d = u64(ch - 'a' + 10)
			case ch >= 'A' && ch <= 'F':
				d = u64(ch - 'A' + 10)
			case:
				return
			}
			if d >= base {
				return
			}
			v = v * base + d
			if v > 0xffffffff {
				return
			}
			digits += 1
			i += 1
		}
		if digits == 0 && base != 8 {
			return
		}
		parts[n] = v
		n += 1
		if i >= len(s) {
			break
		}
		i += 1
		if i >= len(s) {
			return
		}
	}
	val: u64
	switch n {
	case 1:
		val = parts[0]
	case 2:
		if parts[0] > 0xff || parts[1] > 0xffffff {
			return
		}
		val = parts[0] << 24 | parts[1]
	case 3:
		if parts[0] > 0xff || parts[1] > 0xff || parts[2] > 0xffff {
			return
		}
		val = parts[0] << 24 | parts[1] << 16 | parts[2]
	case 4:
		if parts[0] > 0xff || parts[1] > 0xff || parts[2] > 0xff || parts[3] > 0xff {
			return
		}
		val = parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
	}
	return {u8(val >> 24), u8(val >> 16), u8(val >> 8), u8(val)}, true
}

server_close_listeners :: proc() {
	for i in 0 ..< srv.nlfd {
		linux.close(srv.lfds[i])
	}
	srv.nlfd = 0
}

server_primary_bind :: proc() {
	srv.bind = {0, 0, 0, 0}
	srv.bind_str = "0.0.0.0"
	for a in config_bind {
		name := a[1:] if len(a) > 0 && a[0] == '-' else a
		if name == "*" {
			return
		}
		if ip, ok := parse_ipv4(name); ok {
			srv.bind = ip
			srv.bind_str = name
			return
		}
	}
}

server_relisten :: proc() -> bool {
	server_close_listeners()
	fds: [CONFIG_BIND_MAX]linux.Fd
	n, ok := server_open_listeners(srv.port, &fds)
	if !ok {
		return false
	}
	for i in 0 ..< n {
		if epoll_set(fds[i], .ADD, false, 0) != .NONE {
			for j in 0 ..< n {
				linux.close(fds[j])
			}
			return false
		}
	}
	srv.lfds = fds
	srv.nlfd = n
	server_primary_bind()
	return true
}

epoll_set :: proc(fd: linux.Fd, op: linux.EPoll_Ctl_Opcode, want_out: bool, id: i64) -> linux.Errno {
	ev := linux.EPoll_Event {
		events = {.IN, .OUT} if want_out else {.IN},
		data = {u64 = u64(u32(fd)) | u64(u32(id)) << 32},
	}
	if id != 0 && int(fd) >= 0 && int(fd) < len(srv.conns) {
		if c := srv.conns[fd]; c != nil && c.id == id && c.read_eof {
			ev.events -= {.IN}
		}
	}
	return linux.epoll_ctl(srv.epfd, op, fd, &ev)
}

conn_laddr :: proc(c: ^Conn) -> []u8 {
	if c.laddr_len == 0 {
		local: linux.Sock_Addr_Any
		if linux.getsockname(c.fd, &local) == .NONE && local.family == .INET {
			c.laddr_len = format_addr(c.laddr[:], local.ipv4.sin_addr, int(local.ipv4.sin_port))
		}
	}
	return c.laddr[:c.laddr_len]
}

conn_by_id :: proc(id: i64) -> ^Conn {
	for c in srv.conns {
		if c != nil && c.id == id {
			return c
		}
	}
	return nil
}

@(cold)
reject_client :: #force_no_inline proc(fd: linux.Fd) {
	msg := "-ERR max number of clients reached\r\n"
	linux.write(fd, transmute([]u8)msg)
	linux.close(fd)
	srv.stat_rejected_conns += 1
}

@(cold)
set_keepalive :: #force_no_inline proc(fd: linux.Fd, interval: i64) {
	one: i32 = 1
	linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.KEEPALIVE, &one)
	idle := i32(clamp(interval, 1, i64(max(i32))))
	intvl := max(idle / 3, 1)
	cnt: i32 = 3
	linux.setsockopt(fd, linux.SOL_TCP, linux.Socket_TCP_Option.KEEPIDLE, &idle)
	linux.setsockopt(fd, linux.SOL_TCP, linux.Socket_TCP_Option.KEEPINTVL, &intvl)
	linux.setsockopt(fd, linux.SOL_TCP, linux.Socket_TCP_Option.KEEPCNT, &cnt)
}

accept_clients :: proc(lfd: linux.Fd, kind: Conn_Kind) {
	budget := 1024 if kind == .Memcached else int(cfg.max_new_connections_per_cycle)
	for _ in 0 ..< budget {
		peer: linux.Sock_Addr_In
		fd, err := linux.accept(lfd, &peer, {.NONBLOCK, .CLOEXEC})
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			break
		}
		if i64(srv.nconns) >= cfg.maxclients {
			reject_client(fd)
			continue
		}
		one: i32 = 1
		linux.setsockopt(fd, linux.SOL_TCP, linux.Socket_TCP_Option.NODELAY, &one)
		if cfg.tcp_keepalive > 0 {
			set_keepalive(fd, cfg.tcp_keepalive)
		}
		if epoll_set(fd, .ADD, false, srv.next_id + 1) != .NONE {
			linux.close(fd)
			continue
		}
		c := new(Conn)
		c.fd = fd
		srv.next_id += 1
		c.id = srv.next_id
		c.rbuf = mem_alloc(RBUF_INIT)
		c.rcap = RBUF_INIT
		c.wbuf = mem_alloc(WBUF_INIT)
		c.wcap = WBUF_INIT
		conn_mem += size_of(Conn) + RBUF_INIT + WBUF_INIT
		c.ctime_ms = srv.now_ms
		c.atime_ms = srv.now_ms
		c.last_cmd = "NULL"
		c.db = &dbs[0]
		c.resp = RESP2
		c.kind = kind
		if kind == .Memcached {
			mc_stats.total_conns += 1
		}
		c.addr_len = format_addr(c.addr[:], peer.sin_addr, int(peer.sin_port))
		acl_conn_init(c)
		if int(fd) >= len(srv.conns) {
			resize(&srv.conns, max(int(fd) + 1, len(srv.conns) * 2))
		}
		srv.conns[fd] = c
		srv.nconns += 1
		srv.stat_conns += 1
	}
}

@(cold)
qbuf_limit_reached :: #force_no_inline proc(c: ^Conn) {
	b := make([dynamic]u8, context.temp_allocator)
	sb_str(&b, "Closing client that reached max query buffer length: id=")
	sb_int(&b, c.id)
	sb_str(&b, " addr=")
	sb_bytes(&b, c.addr[:c.addr_len])
	sb_str(&b, " (qbuf initial bytes: ")
	sds_repr(&b, c.rbuf[c.rpos:min(c.rlen, c.rpos + 64)])
	sb_str(&b, ")")
	plog(LOG_WARNING, string(b[:]))
	stat_qbuf_limit_disconnections += 1
	conn_close(c)
}

stat_qbuf_limit_disconnections: i64

tx_queued_bytes :: #force_inline proc(c: ^Conn) -> i64 {
	return i64(c.tx.mem) if c.tx != nil else 0
}

conn_close :: proc(c: ^Conn) {
	keyspace_conn_closed(c)
	compute_conn_closed(c)
	if len(acl_doomed) > 0 {
		acl_forget(c)
	}
	if .Monitor in c.flags {
		monitor_remove(c)
	}
	block_conn_closed(c)
	if c.pubsub != nil {
		pubsub_conn_closed(c)
	}
	if c.tx != nil {
		tx_conn_closed(c)
	}
	linux.close(c.fd)
	if int(c.fd) < len(srv.conns) {
		srv.conns[c.fd] = nil
	}
	if c.held {
		srv.held_count -= 1
	}
	request_inline_close(c)
	conn_mem -= size_of(Conn) + c.rcap + c.wcap
	mem_free(c.rbuf)
	mem_free(c.wbuf)
	mem_free(raw_data(c.name))
	mem_free(raw_data(c.lib_name))
	mem_free(raw_data(c.lib_ver))
	free(c)
	srv.nconns -= 1
}

conn_kill :: proc(c: ^Conn) {
	if c.wlen > c.wpos {
		linux.write(c.fd, c.wbuf[c.wpos:c.wlen])
	}
	conn_close(c)
}

conn_flush :: proc(c: ^Conn) -> bool {
	if len(aof.buf) > 0 {
		aof_flush_for_reply()
	}
	if obuf_normal_limited && c.wpos < c.wlen && c.kind == .Redis && .Subscribed not_in c.ps && obuf_normal_over(c) {
		conn_close(c)
		return false
	}
	if c.mbulk_max == 0 && !c.ever_authed && c.kind == .Redis && ps_obuf_usage(c) > ACL_UNAUTH_OBUF {
		stat_obuf_disconnections += 1
		conn_close(c)
		return false
	}
	for c.wpos < c.wlen {
		n, err := linux.write(c.fd, c.wbuf[c.wpos:c.wlen])
		if err == .EINTR {
			continue
		}
		if err == .EAGAIN {
			break
		}
		if err != .NONE {
			conn_close(c)
			return false
		}
		c.wpos += n
		stat_writes_processed += 1
		stat_net_output_bytes += i64(n)
		c.atime_ms = srv.now_ms
		if c.wpos < c.wlen {
			break
		}
	}
	if c.wpos >= c.wlen {
		c.wpos = 0
		c.wlen = 0
		if c.close_after {
			conn_close(c)
			return false
		}
		if c.want_write {
			epoll_set(c.fd, .MOD, false, c.id)
			c.want_write = false
		}
		if c.wcap > BUF_SHRINK_SIZE && reply_buffer_resizing {
			stat_reply_buffer_shrinks += 1
			conn_mem -= c.wcap - WBUF_INIT
			mem_free(c.wbuf)
			c.wbuf = mem_alloc(WBUF_INIT)
			c.wcap = WBUF_INIT
		}
	} else {
		if obuf_normal_limited && c.kind == .Redis && .Subscribed not_in c.ps && obuf_normal_over(c) {
			conn_close(c)
			return false
		}
		if !c.want_write {
			epoll_set(c.fd, .MOD, true, c.id)
			c.want_write = true
		}
	}
	if client_buckets_on {
		client_bucket_track(c)
	}
	return true
}

obuf_normal_limited: bool

obuf_class_over :: proc(c: ^Conn, class: Obuf_Class, soft_since: ^i64) -> bool {
	used := ps_obuf_usage(c)
	lim := obuf_limits[class]
	hard := lim.hard != 0 && used >= lim.hard
	soft := lim.soft != 0 && used >= lim.soft
	if soft {
		now := srv.now_ms / 1000
		if soft_since^ == 0 {
			soft_since^ = now
			soft = false
		} else if now - soft_since^ <= lim.seconds {
			soft = false
		}
	} else {
		soft_since^ = 0
	}
	return soft || hard
}

@(cold)
obuf_normal_over :: #force_no_inline proc(c: ^Conn) -> bool {
	if obuf_class_over(c, .Normal, &c.obuf_soft) {
		stat_obuf_disconnections += 1
		return true
	}
	return false
}

execute_guarded :: proc(c: ^Conn, argv: [][]u8) -> bool {
	if srv.pause_end_ms != 0 && pause_should_hold(c, argv) {
		if !c.held {
			c.held = true
			srv.held_count += 1
		}
		return false
	}
	if c.held {
		c.held = false
		srv.held_count -= 1
	}
	if c.reply == {} {
		execute(c, argv)
		return true
	}
	if .Skip_Next in c.reply {
		c.reply = c.reply - {.Skip_Next} + {.Skip}
	}
	pending := c.wlen - c.wpos
	tx_reply_managed = false
	execute(c, argv)
	if tx_reply_managed {
		tx_reply_managed = false
	} else if c.reply & {.Off, .Skip} != {} {
		c.wlen = c.wpos + pending
	}
	c.reply -= {.Skip}
	return true
}

pause_clients :: proc(end_ms: i64, all: bool) {
	if srv.pause_end_ms != 0 && srv.pause_end_ms <= srv.now_ms {
		pause_clear()
	}
	keep_all := srv.pause_end_ms != 0 && srv.pause_all
	if end_ms > srv.pause_end_ms {
		srv.pause_end_ms = end_ms
	}
	if srv.pause_end_ms <= srv.now_ms {
		srv.pause_end_ms = 0
		return
	}
	srv.pause_all = all || keep_all
}

pause_clear :: proc() {
	srv.pause_end_ms = 0
	srv.pause_all = false
	if srv.held_count > 0 {
		srv.resume_due = true
	}
}

resume_held_clients :: proc() {
	srv.resume_due = false
	for i := 0; i < len(srv.conns); i += 1 {
		c := srv.conns[i]
		if c == nil || !c.held {
			continue
		}
		c.held = false
		srv.held_count -= 1
		if c.rlen > c.rpos {
			process_input(c)
		}
		conn_flush(c)
	}
}

process_input :: proc(c: ^Conn) {
	for !c.close_after && c.rpos < c.rlen && c.blocked == .None && c.compute == nil && c.keyspace == nil && !c.keyspace_ready {
		start := c.rpos
		r := parse_command(c)
		if r != .Command {
			break
		}
		if argc == 0 {
			continue
		}
		c.need = 0
		if srv.pause_end_ms != 0 || c.reply != {} {
			if !execute_guarded(c, argv_buf[:argc]) {
				c.rpos = start
				break
			}
		} else {
			execute(c, argv_buf[:argc])
		}
		if block_work != 0 && block_after_command(c, start) {
			break
		}
	}
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
		c.need = 0
		c.rpeak = 0
	}
	if c.read_eof && c.compute == nil && c.keyspace == nil && !c.keyspace_ready && !c.held {
		c.close_after = true
	}
}

conn_read :: proc(c: ^Conn) {
	eof := false
	c.atime_ms = srv.now_ms
	for {
		want := max(c.rlen + READ_MIN_FREE, c.need)
		if want > c.rcap {
			newcap := max(want, c.rcap * 2)
			c.rbuf = ([^]u8)(runtime.heap_resize(c.rbuf, newcap))
			conn_mem += newcap - c.rcap
			c.rcap = newcap
		}
		space := c.rcap - c.rlen
		n, err := linux.read(c.fd, c.rbuf[c.rlen:c.rcap])
		if err == .EINTR {
			continue
		}
		if err == .EAGAIN {
			break
		}
		if err != .NONE {
			conn_close(c)
			return
		}
		stat_reads_processed += 1
		if n == 0 {
			eof = true
			break
		}
		c.rlen += n
		stat_net_input_bytes += i64(n)
		if n < space {
			break
		}
		if c.rlen >= READ_BATCH_MAX && c.rlen >= c.need {
			break
		}
	}
	if c.rlen > c.rpeak {
		c.rpeak = c.rlen
	}
	if c.kind == .Redis && (i64(c.rlen - c.rpos) > cfg.client_query_buffer_limit - tx_queued_bytes(c) || (c.mbulk_max == 0 && c.rlen - c.rpos > ACL_UNAUTH_QBUF)) {
		qbuf_limit_reached(c)
		return
	}
	if c.rlen > c.rpos {
		if c.kind == .Redis {
			process_input(c)
		} else {
			keyspace_fence()
			mc_process_input(c)
		}
	}
	if eof {
		if c.compute != nil || c.keyspace != nil || c.keyspace_ready {
			c.read_eof = true
			epoll_set(c.fd, .MOD, c.want_write, c.id)
			conn_flush(c)
			return
		}
		if len(aof.buf) > 0 {
			aof_flush_for_reply()
		}
		if c.wlen > c.wpos {
			linux.write(c.fd, c.wbuf[c.wpos:c.wlen])
		}
		conn_close(c)
		return
	}
	if aof.feed && c.wlen > c.wpos {
		aof_defer_conn(c)
		return
	}
	conn_flush(c)
}

handle_event :: proc(c: ^Conn, evs: linux.EPoll_Event_Set) {
	if .ERR in evs {
		conn_close(c)
		return
	}
	if .IN in evs {
		conn_read(c)
		return
	}
	if .HUP in evs {
		conn_close(c)
		return
	}
	if .OUT in evs {
		conn_flush(c)
	}
}

server_cron :: proc() {
	mem_cron()
	persist_cron()
	db_active_expire()
	pubsub_cron()
	if cfg.timeout > 0 && srv.now_ms - srv.last_timeout_ms >= 1000 {
		srv.last_timeout_ms = srv.now_ms
		clients_timeout_cron()
	}
	config_update_dynamic_hz()
	stats_cron()
}

ignore_sigpipe :: proc() {
	if !persist_set_signal(.SIGPIPE, transmute(linux.Sig_Handler_Fn)uintptr(1)) {
		write_fd(2, "eski: cannot ignore SIGPIPE\n")
		linux.exit_group(1)
	}
}

server_run :: proc() -> bool {
	ignore_sigpipe()
	update_clock()
	srv.start_ms = srv.now_ms
	srv.next_cron_ms = srv.now_ms + cron_interval_ms()
	srv.pid = i64(linux.getpid())
	rng_state ~= u64(srv.now_ms) * 0x2545F4914F6CDD1D ~ u64(srv.pid)
	hex := "0123456789abcdef"
	for i in 0 ..< 40 {
		srv.run_id[i] = hex[rng_next() & 15]
	}
	db_init()
	block_init()
	argv_init()
	commands_init()
	acl_startup()
	srv.conns = make([dynamic]^Conn, 1024)
	server_primary_bind()
	nlfd, lok := server_open_listeners(srv.port, &srv.lfds)
	if !lok {
		write_fd(2, "eski: bind failed, address in use or not available\n")
		return false
	}
	srv.nlfd = nlfd
	if !mc_listen() {
		return false
	}
	epfd, err := linux.epoll_create1({.FDCLOEXEC})
	if err != .NONE {
		write_fd(2, "eski: epoll_create1 failed\n")
		return false
	}
	srv.epfd = epfd
	for i in 0 ..< srv.nlfd {
		if epoll_set(srv.lfds[i], .ADD, false, 0) != .NONE {
			write_fd(2, "eski: epoll_ctl on listener failed\n")
			return false
		}
	}
	if mc_lfd >= 0 && epoll_set(mc_lfd, .ADD, false, 0) != .NONE {
		write_fd(2, "eski: epoll_ctl on listener failed\n")
		return false
	}
	mem_init()
	persist_startup()
	compute_start()
	defer compute_shutdown()
	defer keyspace_shutdown()
	log_startup()
	maxmemory_startup_warning()
	el_after_sleep()
	for {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		interval := cron_interval_ms()
		timeout := i32(clamp(srv.next_cron_ms - srv.now_ms, 0, interval))
		if ht.maintenance_pending() || st.maintenance_pending() || zt.maintenance_pending() || slab_reclaim_pending() {
			timeout = min(timeout, 10)
		}
		if srv.pause_end_ms != 0 {
			timeout = min(timeout, i32(clamp(srv.pause_end_ms - srv.now_ms, 0, interval)))
		}
		if block_work != 0 {
			timeout = block_wait_ms(timeout)
		}
		if evict_timer {
			timeout = 0
		}
		if tracking_clients > 0 {
			keyspace_fence()
			tracking_before_sleep()
		}
		if cfg.maxmemory_clients != 0 {
			keyspace_fence()
			evict_clients(nil)
		}
		if len(acl_doomed) > 0 {
			acl_close_doomed()
		}
		if len(keyspace_ready) > 0 {
			timeout = 0
		}
		el_before_sleep()
		n, werr := linux.epoll_wait(srv.epfd, &events[0], MAX_EVENTS, timeout)
		update_clock()
		el_after_sleep()
		if werr != .NONE {
			if werr != .EINTR {
				write_fd(2, "eski: epoll_wait failed\n")
				return false
			}
			n = 0
		}
		for i in 0 ..< int(n) {
			ev := events[i]
			fd := linux.Fd(u32(ev.data.u64))
			if u32(ev.data.u64 >> 32) == 0 {
				if fd == keyspace_event_fd() || fd == compute_event_fd() {
					continue
				} else if fd == lazy_efd {
					lazyfree_drain()
				} else {
					accept_clients(fd, .Memcached if fd == mc_lfd else .Redis)
				}
				continue
			}
			if int(fd) >= len(srv.conns) {
				continue
			}
			c := srv.conns[fd]
			if c == nil || u32(c.id) != u32(ev.data.u64 >> 32) {
				continue
			}
			handle_event(c, ev.events)
		}
		compute_tick()
		keyspace_tick()
		if aof.feed || len(aof.deferred) > 0 || len(aof.buf) > 0 {
			keyspace_fence()
			aof_start := mono_now()
			aof_before_sleep()
			el_note_aof(aof_start)
		}
		if srv.pause_end_ms != 0 && srv.now_ms >= srv.pause_end_ms {
			pause_clear()
		}
		if srv.resume_due {
			keyspace_fence()
			resume_held_clients()
		}
		if block_work != 0 {
			keyspace_fence()
			block_before_sleep()
		}
		if evict_timer {
			keyspace_fence()
			evict_timer_step()
		}
		db_tick()
		if srv.next_cron_ms - srv.now_ms > interval {
			srv.next_cron_ms = srv.now_ms + interval
		}
		if srv.now_ms >= srv.next_cron_ms {
			if !cron_paused {
				cron_start := mono_now()
				server_cron()
				el_note_cron(cron_start)
			}
			srv.next_cron_ms = srv.now_ms + cron_interval_ms()
		}
	}
}

log_startup :: proc() {
	b: [dynamic]u8
	defer delete(b)
	sb_str(&b, "eski ")
	sb_str(&b, VERSION)
	sb_str(&b, " listening on ")
	sb_str(&b, srv.bind_str)
	sb_byte(&b, ':')
	sb_int(&b, i64(srv.port))
	sb_str(&b, " pid ")
	sb_int(&b, srv.pid)
	sb_byte(&b, '\n')
	if mc_lfd >= 0 {
		sb_str(&b, "eski memcached text protocol listening on ")
		sb_str(&b, srv.bind_str)
		sb_byte(&b, ':')
		sb_int(&b, i64(mc_port))
		sb_byte(&b, '\n')
	}
	write_fd(1, string(b[:]))
}

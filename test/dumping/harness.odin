package dumping

import "base:runtime"
import "core:strconv"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import eski "../../src"

@(private)
started: bool

heap :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

boot :: proc() {
	if started {
		return
	}
	eski.mono_init()
	eski.config_table_init()
	eski.config_init()
	eski.commands_init()
	eski.stats_init()
	eski.acl_init()
	eski.db_init()
	eski.block_init()
	eski.mem_init()
	eski.info_init()
	eski.hash_store_init()
	eski.persist_init_commands()
	eski.argv_init()
	started = true
}

new_conn :: proc() -> ^eski.Conn {
	c := new(eski.Conn, heap())
	c.resp = 2
	c.fd = -1
	c.db = &eski.dbs[0]
	eski.acl_conn_init(c)
	return c
}

fresh :: proc() -> ^eski.Conn {
	boot()
	eski.update_clock()
	eski.db_flush_all()
	c := new_conn()
	eski.db_cur = c.db
	run(c, "config", "set", "notify-keyspace-events", "")
	run(c, "config", "set", "maxmemory-policy", "noeviction")
	run(c, "config", "set", "sanitize-dump-payload", "no")
	run(c, "config", "set", "rdbcompression", "no")
	eski.pst.skip_checksum = false
	drop_migrate_cache()
	return c
}

drop_migrate_cache :: proc() {
	for cs in eski.migrate_cache {
		cs.idle_since = -(1 << 40)
	}
	eski.migrate_cron()
}

bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

run_argv :: proc(c: ^eski.Conn, argv: [][]u8) -> string {
	c.wlen = 0
	eski.db_cur = c.db
	eski.update_clock()
	eski.execute(c, argv)
	return string(c.wbuf[:c.wlen])
}

run :: proc(c: ^eski.Conn, args: ..string) -> string {
	argv := make([][]u8, len(args), heap())
	defer delete(argv, heap())
	for a, i in args {
		argv[i] = transmute([]u8)a
	}
	return run_argv(c, argv)
}

run_bytes :: proc(c: ^eski.Conn, args: ..[]u8) -> string {
	return run_argv(c, args)
}

bulk_of :: proc(reply: string) -> (data: []u8, ok: bool) {
	if len(reply) < 4 || reply[0] != '$' {
		return nil, false
	}
	at := 1
	for at < len(reply) && reply[at] != '\r' {
		at += 1
	}
	n, parsed := strconv.parse_int(reply[1:at], 10)
	if !parsed || n < 0 || at + 2 + n > len(reply) {
		return nil, false
	}
	out := make([]u8, n, heap())
	copy(out, reply[at + 2:at + 2 + n])
	return out, true
}

int_of :: proc(reply: string) -> (i64, bool) {
	if len(reply) < 4 || reply[0] != ':' {
		return 0, false
	}
	v, parsed := strconv.parse_i64(reply[1:len(reply) - 2], 10)
	return v, parsed
}

dump_of :: proc(c: ^eski.Conn, key: string) -> []u8 {
	data, _ := bulk_of(run(c, "dump", key))
	return data
}

hex_decode :: proc(s: string) -> []u8 {
	out := make([]u8, len(s) / 2, heap())
	for i in 0 ..< len(out) {
		hi := hex_digit(s[2 * i])
		lo := hex_digit(s[2 * i + 1])
		out[i] = hi << 4 | lo
	}
	return out
}

@(private)
hex_digit :: proc(b: u8) -> u8 {
	switch b {
	case '0' ..= '9':
		return b - '0'
	case 'a' ..= 'f':
		return b - 'a' + 10
	case 'A' ..= 'F':
		return b - 'A' + 10
	}
	return 0
}

hex_encode :: proc(data: []u8) -> string {
	digits := "0123456789abcdef"
	out := make([]u8, 2 * len(data), heap())
	for b, i in data {
		out[2 * i] = digits[b >> 4]
		out[2 * i + 1] = digits[b & 15]
	}
	return string(out)
}

itoa :: proc(buf: []u8, v: i64) -> string {
	return strconv.write_int(buf, v, 10)
}

Subscriber :: struct {
	conn: ^eski.Conn,
}

subscribe_events :: proc(c: ^eski.Conn, flags: string) -> Subscriber {
	run(c, "config", "set", "notify-keyspace-events", flags)
	sub := new_conn()
	run(sub, "psubscribe", "__keyevent*")
	sub.wlen = 0
	eski.db_cur = c.db
	return Subscriber{conn = sub}
}

take_events :: proc(s: Subscriber) -> string {
	out := string(s.conn.wbuf[:s.conn.wlen])
	cloned := make([]u8, len(out), heap())
	copy(cloned, out)
	s.conn.wlen = 0
	return string(cloned)
}

event_frame :: proc(event: string, key: string) -> string {
	b: [dynamic]u8
	b.allocator = heap()
	channel := concat("__keyevent@0__:", event)
	parts := [?]string{"pmessage", "__keyevent*", channel, key}
	append(&b, "*4\r\n")
	for p in parts {
		buf: [24]u8
		append(&b, '$')
		append(&b, itoa(buf[:], i64(len(p))))
		append(&b, "\r\n")
		append(&b, p)
		append(&b, "\r\n")
	}
	return string(b[:])
}

concat :: proc(a: string, b: string) -> string {
	out := make([]u8, len(a) + len(b), heap())
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

reply_error_text :: proc(msg: string) -> string {
	return concat(concat("-", msg), "\r\n")
}

Fake_Command :: struct {
	conn: int,
	args: [dynamic][]u8,
}

@(private)
Fake_Client :: struct {
	fd:  linux.Fd,
	id:  int,
	buf: [dynamic]u8,
}

Fake_Target :: struct {
	listener: linux.Fd,
	port:     int,
	port_buf: [24]u8,
	port_str: string,
	worker:   ^thread.Thread,
	lock:     sync.Mutex,
	stop:     bool,
	silent:   bool,
	kick:     int,
	kicked:   int,
	accepted: int,
	script:   [dynamic]string,
	log:      [dynamic]Fake_Command,
}

listen_local :: proc(backlog: i32) -> (fd: linux.Fd, port: int, ok: bool) {
	s, err := linux.socket(.INET, .STREAM, {.CLOEXEC}, .TCP)
	if err != .NONE {
		return -1, 0, false
	}
	one: i32 = 1
	linux.setsockopt(s, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &one)
	sa := linux.Sock_Addr_In {
		sin_family = .INET,
		sin_port   = 0,
		sin_addr   = {127, 0, 0, 1},
	}
	if linux.bind(s, &sa) != .NONE || linux.listen(s, backlog) != .NONE {
		linux.close(s)
		return -1, 0, false
	}
	bound: linux.Sock_Addr_Any
	if linux.getsockname(s, &bound) != .NONE {
		linux.close(s)
		return -1, 0, false
	}
	return s, int(bound.ipv4.sin_port), true
}

fake_start :: proc(t: ^testing.T) -> ^Fake_Target {
	ft := new(Fake_Target, heap())
	ft.script.allocator = heap()
	ft.log.allocator = heap()
	fd, port, ok := listen_local(16)
	if !testing.expect(t, ok, "fake target could not listen on 127.0.0.1") {
		free(ft, heap())
		return nil
	}
	ft.listener = fd
	ft.port = port
	ft.port_str = itoa(ft.port_buf[:], i64(port))
	ft.worker = thread.create_and_start_with_poly_data(ft, fake_serve)
	return ft
}

fake_stop :: proc(ft: ^Fake_Target) {
	if ft == nil {
		return
	}
	sync.mutex_lock(&ft.lock)
	ft.stop = true
	sync.mutex_unlock(&ft.lock)
	thread.join(ft.worker)
	thread.destroy(ft.worker)
	linux.close(ft.listener)
	for &cmd in ft.log {
		for a in cmd.args {
			delete(a, heap())
		}
		delete(cmd.args)
	}
	delete(ft.log)
	delete(ft.script)
	free(ft, heap())
}

fake_script :: proc(ft: ^Fake_Target, replies: ..string) {
	sync.mutex_lock(&ft.lock)
	defer sync.mutex_unlock(&ft.lock)
	for r in replies {
		append(&ft.script, r)
	}
}

fake_set_silent :: proc(ft: ^Fake_Target, silent: bool) {
	sync.mutex_lock(&ft.lock)
	defer sync.mutex_unlock(&ft.lock)
	ft.silent = silent
}

fake_commands :: proc(ft: ^Fake_Target) -> []Fake_Command {
	sync.mutex_lock(&ft.lock)
	defer sync.mutex_unlock(&ft.lock)
	return ft.log[:]
}

fake_accepted :: proc(ft: ^Fake_Target) -> int {
	sync.mutex_lock(&ft.lock)
	defer sync.mutex_unlock(&ft.lock)
	return ft.accepted
}

fake_clear_log :: proc(ft: ^Fake_Target) {
	sync.mutex_lock(&ft.lock)
	defer sync.mutex_unlock(&ft.lock)
	for &cmd in ft.log {
		for a in cmd.args {
			delete(a, heap())
		}
		delete(cmd.args)
	}
	clear(&ft.log)
}

fake_drop_clients :: proc(ft: ^Fake_Target) -> bool {
	sync.mutex_lock(&ft.lock)
	ft.kick += 1
	want := ft.kick
	sync.mutex_unlock(&ft.lock)
	for _ in 0 ..< 500 {
		sync.mutex_lock(&ft.lock)
		done := ft.kicked >= want
		sync.mutex_unlock(&ft.lock)
		if done {
			return true
		}
		pause_ms(2)
	}
	return false
}

pause_ms :: proc(ms: i64) {
	ts := linux.Time_Spec {
		time_sec  = uint(ms / 1000),
		time_nsec = uint((ms % 1000) * 1_000_000),
	}
	linux.nanosleep(&ts, nil)
}

clock_ms :: proc() -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1000 + i64(ts.time_nsec) / 1_000_000
}

@(private)
fake_parse :: proc(buf: []u8) -> (args: [dynamic][]u8, used: int, complete: bool) {
	line_end :: proc(buf: []u8, from: int) -> int {
		for i in from ..< len(buf) - 1 {
			if buf[i] == '\r' && buf[i + 1] == '\n' {
				return i
			}
		}
		return -1
	}
	if len(buf) < 4 || buf[0] != '*' {
		return
	}
	end := line_end(buf, 0)
	if end < 0 {
		return
	}
	count, _ := strconv.parse_int(string(buf[1:end]), 10)
	at := end + 2
	args.allocator = heap()
	for _ in 0 ..< count {
		if at >= len(buf) || buf[at] != '$' {
			fake_free_args(&args)
			return
		}
		hdr := line_end(buf, at)
		if hdr < 0 {
			fake_free_args(&args)
			return
		}
		n, _ := strconv.parse_int(string(buf[at + 1:hdr]), 10)
		start := hdr + 2
		if start + n + 2 > len(buf) {
			fake_free_args(&args)
			return
		}
		arg := make([]u8, n, heap())
		copy(arg, buf[start:start + n])
		append(&args, arg)
		at = start + n + 2
	}
	return args, at, true
}

@(private)
fake_free_args :: proc(args: ^[dynamic][]u8) {
	for a in args {
		delete(a, heap())
	}
	delete(args^)
	args^ = nil
}

@(private)
fake_close_client :: proc(clients: ^[dynamic]Fake_Client, i: int) {
	linux.close(clients[i].fd)
	delete(clients[i].buf)
	ordered_remove(clients, i)
}

@(private)
fake_serve :: proc(ft: ^Fake_Target) {
	context.allocator = heap()
	clients: [dynamic]Fake_Client
	defer {
		for len(clients) > 0 {
			fake_close_client(&clients, 0)
		}
		delete(clients)
	}
	next_id := 0
	chunk: [65536]u8
	for {
		sync.mutex_lock(&ft.lock)
		stopping := ft.stop
		kick := ft.kick > ft.kicked
		sync.mutex_unlock(&ft.lock)
		if stopping {
			return
		}
		if kick {
			for len(clients) > 0 {
				fake_close_client(&clients, 0)
			}
			sync.mutex_lock(&ft.lock)
			ft.kicked = ft.kick
			sync.mutex_unlock(&ft.lock)
		}
		fds := make([]linux.Poll_Fd, len(clients) + 1, heap())
		defer delete(fds, heap())
		fds[0] = {fd = ft.listener, events = {.IN}}
		for cl, i in clients {
			fds[i + 1] = {fd = cl.fd, events = {.IN}}
		}
		n, _ := linux.poll(fds, 10)
		if n <= 0 {
			continue
		}
		if .IN in fds[0].revents {
			peer: linux.Sock_Addr_In
			fd, err := linux.accept(ft.listener, &peer, {.CLOEXEC})
			if err == .NONE {
				next_id += 1
				append(&clients, Fake_Client{fd = fd, id = next_id, buf = make([dynamic]u8, heap())})
				sync.mutex_lock(&ft.lock)
				ft.accepted += 1
				sync.mutex_unlock(&ft.lock)
			}
		}
		i := len(fds) - 1
		for i >= 1 {
			defer i -= 1
			if fds[i].revents == {} {
				continue
			}
			cl := &clients[i - 1]
			got, err := linux.recv(cl.fd, chunk[:], {})
			if err != .NONE || got <= 0 {
				fake_close_client(&clients, i - 1)
				continue
			}
			append(&cl.buf, ..chunk[:got])
			for {
				args, used, complete := fake_parse(cl.buf[:])
				if !complete {
					break
				}
				remove_range(&cl.buf, 0, used)
				sync.mutex_lock(&ft.lock)
				append(&ft.log, Fake_Command{conn = cl.id, args = args})
				silent := ft.silent
				reply := "+OK"
				if len(ft.script) > 0 {
					reply = ft.script[0]
					ordered_remove(&ft.script, 0)
				}
				sync.mutex_unlock(&ft.lock)
				if silent {
					continue
				}
				line := make([]u8, len(reply) + 2, heap())
				copy(line, reply)
				line[len(reply)] = '\r'
				line[len(reply) + 1] = '\n'
				linux.send(cl.fd, line, {.NOSIGNAL})
				delete(line, heap())
			}
		}
	}
}

args_equal :: proc(got: [dynamic][]u8, want: ..string) -> bool {
	if len(got) != len(want) {
		return false
	}
	for w, i in want {
		if string(got[i]) != w {
			return false
		}
	}
	return true
}

command_names :: proc(cmds: []Fake_Command) -> string {
	b: [dynamic]u8
	b.allocator = heap()
	for cmd, i in cmds {
		if i > 0 {
			append(&b, ' ')
		}
		if len(cmd.args) > 0 {
			append(&b, ..cmd.args[0])
		}
	}
	return string(b[:])
}

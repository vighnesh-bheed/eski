package blockingops

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import eski "../../src"

Client :: struct {
	fd:   linux.Fd,
	id:   i64,
	conn: ^eski.Conn,
	buf:  [dynamic]u8,
}

@(private = "file")
harness_ready: bool

@(private = "file")
harness_lfd: linux.Fd

@(private = "file")
harness_port: u16

main :: proc() {
}

setup :: proc() {
	if harness_ready {
		return
	}
	context.allocator = runtime.heap_allocator()
	eski.mono_init()
	eski.config_init()
	eski.stats_init()
	eski.info_init()
	eski.update_clock()
	eski.srv.start_ms = eski.srv.now_ms
	eski.srv.next_cron_ms = eski.srv.now_ms + 100
	eski.db_init()
	eski.block_init()
	eski.argv_init()
	eski.commands_init()
	eski.acl_startup()
	eski.srv.conns = make([dynamic]^eski.Conn, 1024)
	epfd, eerr := linux.epoll_create1({.FDCLOEXEC})
	assert(eerr == .NONE)
	eski.srv.epfd = epfd
	lfd, lerr := eski.listen_addr({127, 0, 0, 1}, 0)
	assert(lerr == .NONE)
	harness_lfd = lfd
	assert(eski.epoll_set(lfd, .ADD, false, 0) == .NONE)
	any: linux.Sock_Addr_Any
	assert(linux.getsockname(lfd, &any) == .NONE)
	harness_port = u16(any.ipv4.sin_port)
	harness_ready = true
}

begin :: proc() -> runtime.Allocator {
	setup()
	return runtime.heap_allocator()
}

pump :: proc(rounds := 1, wait_ms: i32 = 0) {
	for _ in 0 ..< rounds {
		timeout := wait_ms
		if eski.block_work != 0 {
			timeout = eski.block_wait_ms(timeout)
		}
		n, _ := linux.epoll_wait(eski.srv.epfd, &eski.events[0], eski.MAX_EVENTS, timeout)
		eski.update_clock()
		for i in 0 ..< int(max(n, 0)) {
			ev := eski.events[i]
			fd := linux.Fd(u32(ev.data.u64))
			if u32(ev.data.u64 >> 32) == 0 {
				if fd == harness_lfd {
					eski.accept_clients(fd, .Redis)
				} else if fd == eski.lazy_efd {
					eski.lazyfree_drain()
				}
				continue
			}
			if int(fd) >= len(eski.srv.conns) {
				continue
			}
			c := eski.srv.conns[fd]
			if c == nil || u32(c.id) != u32(ev.data.u64 >> 32) {
				continue
			}
			eski.handle_event(c, ev.events)
		}
		if eski.srv.pause_end_ms != 0 && eski.srv.now_ms >= eski.srv.pause_end_ms {
			eski.pause_clear()
		}
		if eski.srv.resume_due {
			eski.resume_held_clients()
		}
		if eski.block_work != 0 {
			eski.block_before_sleep()
		}
	}
}

encode :: proc(args: ..string) -> []u8 {
	b: [dynamic]u8
	append(&b, '*')
	append_int(&b, len(args))
	append(&b, "\r\n")
	for a in args {
		append(&b, '$')
		append_int(&b, len(a))
		append(&b, "\r\n")
		append(&b, a)
		append(&b, "\r\n")
	}
	return b[:]
}

append_int :: proc(b: ^[dynamic]u8, v: int) {
	tmp: [32]u8
	append(b, strconv.write_int(tmp[:], i64(v), 10))
}

send_raw :: proc(cl: ^Client, data: []u8) {
	off := 0
	for off < len(data) {
		n, err := linux.send(cl.fd, data[off:], {})
		assert(err == .NONE)
		off += n
	}
}

send :: proc(cl: ^Client, args: ..string) {
	data := encode(..args)
	defer delete(data)
	send_raw(cl, data)
}

@(private = "file")
fill :: proc(cl: ^Client) -> (closed: bool) {
	tmp: [65536]u8
	for {
		n, err := linux.recv(cl.fd, tmp[:], {.DONTWAIT})
		if err == .EAGAIN || err == .EWOULDBLOCK {
			return false
		}
		if err != .NONE || n == 0 {
			return true
		}
		append(&cl.buf, ..tmp[:n])
	}
}

frame_len :: proc(b: []u8) -> int {
	if len(b) == 0 {
		return 0
	}
	eol := -1
	for i in 0 ..< len(b) - 1 {
		if b[i] == '\r' && b[i + 1] == '\n' {
			eol = i
			break
		}
	}
	if eol < 0 {
		return 0
	}
	head := string(b[1:eol])
	body := eol + 2
	switch b[0] {
	case '$', '=', '!':
		n, _ := strconv.parse_int(head)
		if n < 0 {
			return body
		}
		if len(b) < body + n + 2 {
			return 0
		}
		return body + n + 2
	case '*', '~', '>', '%', '|':
		n, _ := strconv.parse_int(head)
		if n < 0 {
			return body
		}
		if b[0] == '%' || b[0] == '|' {
			n *= 2
		}
		off := body
		for _ in 0 ..< n {
			k := frame_len(b[off:])
			if k == 0 {
				return 0
			}
			off += k
		}
		return off
	}
	return body
}

reply :: proc(cl: ^Client, limit_ms := 2000) -> string {
	start := time.tick_now()
	for {
		fill(cl)
		n := frame_len(cl.buf[:])
		if n > 0 {
			s := strings.clone(string(cl.buf[:n]))
			remove_range(&cl.buf, 0, n)
			return s
		}
		if int(time.duration_milliseconds(time.tick_since(start))) > limit_ms {
			return ""
		}
		pump(1, 5)
	}
}

silent :: proc(cl: ^Client, ms := 50) -> bool {
	start := time.tick_now()
	for int(time.duration_milliseconds(time.tick_since(start))) < ms {
		pump(1, 5)
	}
	fill(cl)
	return len(cl.buf) == 0
}

call :: proc(cl: ^Client, args: ..string) -> string {
	send(cl, ..args)
	return reply(cl)
}

connect :: proc() -> ^Client {
	fd, err := linux.socket(.INET, .STREAM, {.CLOEXEC}, .TCP)
	assert(err == .NONE)
	addr := linux.Sock_Addr_In {
		sin_family = .INET,
		sin_port   = u16be(harness_port),
		sin_addr   = {127, 0, 0, 1},
	}
	assert(linux.connect(fd, &addr) == .NONE)
	cl := new(Client)
	cl.fd = fd
	pump(2)
	r := call(cl, "CLIENT", "ID")
	defer delete(r)
	id, _ := strconv.parse_i64(r[1:len(r) - 2])
	cl.id = id
	cl.conn = eski.conn_by_id(id)
	return cl
}

disconnect :: proc(cl: ^Client) {
	linux.close(cl.fd)
	for _ in 0 ..< 4 {
		pump(1, 1)
	}
	delete(cl.buf)
	free(cl)
}

expect_reply :: proc(t: ^testing.T, cl: ^Client, want: string, loc := #caller_location) {
	got := reply(cl)
	defer delete(got)
	testing.expectf(t, got == want, "got %q want %q", got, want, loc = loc)
}

expect_call :: proc(t: ^testing.T, cl: ^Client, want: string, args: ..string, loc := #caller_location) {
	send(cl, ..args)
	expect_reply(t, cl, want, loc)
}

expect_silent :: proc(t: ^testing.T, cl: ^Client, ms := 50, loc := #caller_location) {
	testing.expectf(t, silent(cl, ms), "unexpected reply %q", string(cl.buf[:]), loc = loc)
}

NULL_ARRAY :: "*-1\r\n"

NULL_BULK :: "$-1\r\n"

WRONGTYPE :: "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"

OK :: "+OK\r\n"

info_field :: proc(cl: ^Client, section: string, name: string) -> string {
	r := call(cl, "INFO", section)
	defer delete(r)
	prefix := strings.concatenate({name, ":"}, context.temp_allocator)
	rest := r
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, prefix) {
			return strings.clone(strings.trim_right(line[len(prefix):], "\r"), context.temp_allocator)
		}
	}
	return ""
}

idle_state :: proc(t: ^testing.T, loc := #caller_location) {
	pump(2, 1)
	testing.expect_value(t, eski.block_count(), 0, loc = loc)
	testing.expect_value(t, eski.block_total_keys(), 0, loc = loc)
	testing.expect_value(t, eski.block_total_nokey_keys(), 0, loc = loc)
	testing.expect_value(t, len(eski.block_ready), 0, loc = loc)
	testing.expect_value(t, len(eski.block_unblocked), 0, loc = loc)
	testing.expect_value(t, eski.block_work, 0, loc = loc)
	testing.expect_value(t, eski.block_nokey_clients, 0, loc = loc)
	total := 0
	for m in eski.block_keys {
		total += len(m)
	}
	testing.expect_value(t, total, 0, loc = loc)
}

wait_blocked :: proc(t: ^testing.T, cl: ^Client, loc := #caller_location) {
	start := time.tick_now()
	for cl.conn.blocked == .None && time.duration_milliseconds(time.tick_since(start)) < 1000 {
		pump(1, 2)
	}
	testing.expect(t, cl.conn.blocked != .None, "client did not block", loc = loc)
}

start_cmd :: proc(t: ^testing.T, cl: ^Client, args: ..string, loc := #caller_location) {
	send(cl, ..args)
	wait_blocked(t, cl, loc)
}

elapsed_ms :: proc(start: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(start))
}

fresh :: proc() -> ^Client {
	w := connect()
	r := call(w, "FLUSHALL")
	delete(r)
	return w
}

id_of :: proc(cl: ^Client) -> string {
	return fmt.tprint(cl.id)
}

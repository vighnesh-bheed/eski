package sortwork

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import "core:time"
import eski "../../src"

@(private)
booted: bool

main :: proc() {
}

heap :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

boot :: proc() {
	if booted {
		return
	}
	context.allocator = heap()
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
	eski.update_clock()
	efd, _ := linux.epoll_create1({})
	eski.srv.epfd = efd
	booted = true
}

Session :: struct {
	conn:   ^eski.Conn,
	sub:    ^eski.Conn,
	peers:  [2]linux.Fd,
	extras: [dynamic]^eski.Conn,
	fds:    [dynamic]linux.Fd,
}

@(private)
next_conn_id: i64 = 5000

@(private)
attach_conn :: proc(resp: u8) -> (c: ^eski.Conn, peer: linux.Fd) {
	fds: [2]linux.Fd
	linux.socketpair(.UNIX, .STREAM, .HOPOPT, &fds)
	c = new(eski.Conn)
	c.fd = fds[0]
	c.resp = resp
	c.db = &eski.dbs[0]
	c.id = next_conn_id
	next_conn_id += 1
	eski.acl_conn_init(c)
	for len(eski.srv.conns) <= int(c.fd) {
		append(&eski.srv.conns, nil)
	}
	eski.srv.conns[c.fd] = c
	eski.srv.nconns += 1
	return c, fds[1]
}

open_session :: proc(resp: u8, events: string = "") -> Session {
	boot()
	s: Session
	s.conn, s.peers[0] = attach_conn(resp)
	call(&s, "FLUSHALL")
	call(&s, "CONFIG", "SET", "maxmemory", "0")
	call(&s, "CONFIG", "SET", "maxmemory-policy", "noeviction")
	call(&s, "CONFIG", "SET", "notify-keyspace-events", events)
	if events != "" {
		s.sub, s.peers[1] = attach_conn(2)
		run_on(s.sub, {"PSUBSCRIBE", "__key*__:*"})
		s.sub.wlen = 0
		s.sub.wpos = 0
	}
	return s
}

close_session :: proc(s: ^Session) {
	call(s, "AUTH", "default", "x")
	call(s, "CONFIG", "SET", "notify-keyspace-events", "")
	call(s, "CONFIG", "SET", "maxmemory", "0")
	call(s, "CONFIG", "SET", "maxmemory-policy", "noeviction")
	call(s, "FLUSHALL")
	if s.sub != nil {
		eski.conn_close(s.sub)
		linux.close(s.peers[1])
	}
	for c, i in s.extras {
		eski.conn_close(c)
		linux.close(s.fds[i])
	}
	delete(s.extras)
	delete(s.fds)
	eski.conn_close(s.conn)
	linux.close(s.peers[0])
}

peer :: proc(s: ^Session, resp: u8 = 2) -> ^eski.Conn {
	c, fd := attach_conn(resp)
	append(&s.extras, c)
	append(&s.fds, fd)
	return c
}

call_on :: proc(c: ^eski.Conn, args: ..string) -> string {
	return run_on(c, args)
}

pending_on :: proc(c: ^eski.Conn) -> string {
	out := strings.clone(string(c.wbuf[c.wpos:c.wlen]), context.temp_allocator)
	c.wlen = c.wpos
	return out
}

@(private)
run_on :: proc(c: ^eski.Conn, args: []string) -> string {
	argv := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		argv[i] = transmute([]u8)a
	}
	return run_argv(c, argv)
}

run_argv :: proc(c: ^eski.Conn, argv: [][]u8) -> string {
	before := c.wlen
	eski.db_cur = c.db
	eski.update_clock()
	eski.execute(c, argv)
	settle_lazyfree(c)
	out := strings.clone(string(c.wbuf[before:c.wlen]), context.temp_allocator)
	c.wlen = before
	return out
}

call :: proc(s: ^Session, args: ..string) -> string {
	return run_on(s.conn, args)
}

call_bytes :: proc(s: ^Session, args: ..[]u8) -> string {
	return run_argv(s.conn, args)
}

take_events :: proc(s: ^Session) -> string {
	if s.sub == nil {
		return ""
	}
	raw := string(s.sub.wbuf[s.sub.wpos:s.sub.wlen])
	s.sub.wlen = s.sub.wpos
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	rest := raw
	first := true
	for len(rest) > 0 {
		node, used, ok := resp_parse(rest)
		if !ok || used == 0 {
			break
		}
		rest = rest[used:]
		if node.kind != .Array && node.kind != .Push {
			continue
		}
		if len(node.items) != 4 {
			continue
		}
		if !first {
			strings.write_string(&b, " | ")
		}
		first = false
		strings.write_string(&b, node.items[2].text)
		strings.write_byte(&b, ' ')
		strings.write_string(&b, node.items[3].text)
	}
	return strings.to_string(b)
}

settle_lazyfree :: proc(c: ^eski.Conn) {
	for _ in 0 ..< 5000 {
		if c.blocked != .Lazyfree {
			return
		}
		eski.lazyfree_drain()
		if c.blocked != .Lazyfree {
			return
		}
		time.sleep(100 * time.Microsecond)
	}
}

pause :: proc(ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
	eski.update_clock()
}

bulk :: proc(s: string) -> string {
	return strings.concatenate({"$", itoa(len(s)), "\r\n", s, "\r\n"}, context.temp_allocator)
}

itoa :: proc(n: int) -> string {
	buf: [32]u8
	i := len(buf)
	v := n
	neg := v < 0
	if neg {
		v = -v
	}
	for {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	if neg {
		i -= 1
		buf[i] = '-'
	}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

Wire_Peer :: struct {
	conn: ^eski.Conn,
	fd:   linux.Fd,
}

wire_peer :: proc(s: ^Session, resp: u8 = 2) -> Wire_Peer {
	c := peer(s, resp)
	return Wire_Peer{conn = c, fd = s.fds[len(s.fds) - 1]}
}

wire_send :: proc(p: Wire_Peer, args: ..string) {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_byte(&b, '*')
	strings.write_int(&b, len(args))
	strings.write_string(&b, "\r\n")
	for a in args {
		strings.write_byte(&b, '$')
		strings.write_int(&b, len(a))
		strings.write_string(&b, "\r\n")
		strings.write_string(&b, a)
		strings.write_string(&b, "\r\n")
	}
	linux.write(p.fd, transmute([]u8)strings.to_string(b))
	eski.update_clock()
	eski.conn_read(p.conn)
}

wire_take :: proc(p: Wire_Peer) -> string {
	eski.block_serve_ready()
	eski.conn_flush(p.conn)
	out: [dynamic]u8
	out.allocator = context.temp_allocator
	buf: [4096]u8
	for {
		pfd := []linux.Poll_Fd{{fd = p.fd, events = {.IN}}}
		n, _ := linux.poll(pfd, 0)
		if n <= 0 {
			break
		}
		got, err := linux.read(p.fd, buf[:])
		if err != nil || got <= 0 {
			break
		}
		append(&out, ..buf[:got])
	}
	return string(out[:])
}

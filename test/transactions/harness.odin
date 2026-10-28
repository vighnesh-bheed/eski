package transactions

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import j "../../src"

Client :: struct {
	c:    ^j.Conn,
	peer: linux.Fd,
	fd:   linux.Fd,
}

booted: bool

next_client_id: i64 = 1000

main :: proc() {
}

boot :: proc() -> runtime.Allocator {
	if !booted {
		booted = true
		context.allocator = runtime.heap_allocator()
		j.mono_init()
		j.config_init()
		j.db_init()
		j.commands_init()
		j.acl_init()
		j.block_init()
		j.persist_init_commands()
		j.update_clock()
		efd, _ := linux.epoll_create1({})
		j.srv.epfd = efd
	}
	return runtime.heap_allocator()
}

open_client :: proc() -> Client {
	fds: [2]linux.Fd
	linux.socketpair(.UNIX, .STREAM, .HOPOPT, &fds)
	c := new(j.Conn)
	c.fd = fds[0]
	c.resp = j.RESP2
	c.db = &j.dbs[0]
	c.id = next_client_id
	next_client_id += 1
	j.acl_conn_init(c)
	for len(j.srv.conns) <= int(c.fd) {
		append(&j.srv.conns, nil)
	}
	j.srv.conns[c.fd] = c
	j.srv.nconns += 1
	return Client{c, fds[1], fds[0]}
}

client_alive :: proc(cl: Client) -> bool {
	return int(cl.fd) < len(j.srv.conns) && j.srv.conns[cl.fd] == cl.c
}

close_client :: proc(cl: Client) {
	if client_alive(cl) {
		j.conn_close(cl.c)
	}
	linux.close(cl.peer)
}

argv_of :: proc(args: []string) -> [][]u8 {
	argv := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		argv[i] = transmute([]u8)a
	}
	return argv
}

call :: proc(cl: Client, args: ..string) -> string {
	c := cl.c
	before := c.wlen
	j.update_clock()
	j.execute(c, argv_of(args))
	finish_lazyfree(c)
	out := strings.clone(string(c.wbuf[before:c.wlen]), context.temp_allocator)
	c.wlen = before
	return out
}

pending :: proc(cl: Client) -> string {
	c := cl.c
	out := strings.clone(string(c.wbuf[c.wpos:c.wlen]), context.temp_allocator)
	c.wlen = c.wpos
	return out
}

encode :: proc(b: ^[dynamic]u8, args: []string) {
	j.sb_byte(b, '*')
	j.sb_int(b, i64(len(args)))
	j.sb_str(b, "\r\n")
	for a in args {
		j.sb_byte(b, '$')
		j.sb_int(b, i64(len(a)))
		j.sb_str(b, "\r\n")
		j.sb_str(b, a)
		j.sb_str(b, "\r\n")
	}
}

drain :: proc(fd: linux.Fd) -> string {
	out: [dynamic]u8
	out.allocator = context.temp_allocator
	buf: [16384]u8
	for {
		pfd := []linux.Poll_Fd{{fd = fd, events = {.IN}}}
		n, _ := linux.poll(pfd, 0)
		if n <= 0 {
			break
		}
		r, err := linux.read(fd, buf[:])
		if err != nil || r <= 0 {
			break
		}
		append(&out, ..buf[:r])
	}
	return string(out[:])
}

wire_many :: proc(cl: Client, cmds: ..[]string) -> string {
	b: [dynamic]u8
	b.allocator = context.temp_allocator
	for args in cmds {
		encode(&b, args)
	}
	linux.write(cl.peer, b[:])
	j.update_clock()
	j.conn_read(cl.c)
	if client_alive(cl) {
		finish_lazyfree(cl.c)
		j.conn_flush(cl.c)
	}
	return drain(cl.peer)
}

wire :: proc(cl: Client, args: ..string) -> string {
	return wire_many(cl, args)
}

split :: proc(line: string) -> []string {
	return strings.fields(line, context.temp_allocator)
}

expect_call :: proc(t: ^testing.T, cl: Client, line: string, want: string, loc := #caller_location) -> bool {
	got := call(cl, ..split(line))
	return testing.expectf(t, got == want, "%s: got %q want %q", line, got, want, loc = loc)
}

expect_wire :: proc(t: ^testing.T, cl: Client, line: string, want: string, loc := #caller_location) -> bool {
	got := wire(cl, ..split(line))
	return testing.expectf(t, got == want, "%s: got %q want %q", line, got, want, loc = loc)
}

info_field :: proc(cl: Client, section: string, name: string) -> string {
	text := call(cl, "INFO", section)
	prefix := strings.concatenate({name, ":"}, context.temp_allocator)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, prefix) {
			return strings.trim_right(line[len(prefix):], "\r")
		}
	}
	return ""
}

client_line :: proc(target: Client, viewer: Client) -> string {
	b: [dynamic]u8
	b.allocator = context.temp_allocator
	j.client_info_line(&b, target.c, viewer.c, argv_of({"CLIENT", "LIST"}))
	return string(b[:])
}

client_field :: proc(line: string, name: string) -> string {
	prefix := strings.concatenate({name, "="}, context.temp_allocator)
	rest := line
	for field in strings.fields_iterator(&rest) {
		if strings.has_prefix(field, prefix) {
			return field[len(prefix):]
		}
	}
	return "?"
}

settle :: proc(ms: int) {
	time.sleep(time.Duration(ms) * time.Millisecond)
	j.update_clock()
}

finish_lazyfree :: proc(c: ^j.Conn) {
	for _ in 0 ..< 5000 {
		if c.blocked != .Lazyfree {
			return
		}
		j.lazyfree_drain()
		if c.blocked != .Lazyfree {
			return
		}
		time.sleep(100 * time.Microsecond)
	}
}

reset_server :: proc(cl: Client) {
	call(cl, "FLUSHALL")
}

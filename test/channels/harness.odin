package channels

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import j "../../src"

suite_track: mem.Tracking_Allocator
suite_once: sync.Once
server_once: sync.Once
session_active: bool
next_conn_id: i64 = 1000

Client :: struct {
	conn: ^j.Conn,
	peer: linux.Fd,
	fd:   linux.Fd,
	open: bool,
}

suite_init :: proc() {
	mem.tracking_allocator_init(&suite_track, runtime.heap_allocator(), runtime.heap_allocator())
	suite_track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
}

suite_allocator :: proc() -> runtime.Allocator {
	sync.once_do(&suite_once, suite_init)
	return mem.tracking_allocator(&suite_track)
}

server_init :: proc() {
	j.ignore_sigpipe()
	j.commands_init()
	j.config_table_init()
	j.config_init()
	j.db_init()
	j.acl_init()
	j.info_init()
	j.stats_init()
}

@(deferred_in = session_end)
session :: proc(t: ^testing.T) {
	testing.expect(t, context.allocator.data == rawptr(&suite_track), "tests must run on the suite allocator")
	if intrinsics.atomic_exchange(&session_active, true) {
		testing.fail_now(t, "sessions overlap; run with -define:ODIN_TEST_THREADS=1")
	}
	sync.once_do(&server_once, server_init)
	expect_quiet(t)
}

session_end :: proc(t: ^testing.T) {
	expect_quiet(t)
	testing.expect_value(t, len(suite_track.bad_free_array), 0)
	intrinsics.atomic_store(&session_active, false)
}

expect_quiet :: proc(t: ^testing.T, loc := #caller_location) {
	testing.expect_value(t, registry_shared_memory(), 0, loc)
	testing.expect_value(t, j.client_metadata_total, 0, loc)
	for kind in j.Ps_Kind {
		testing.expect_value(t, len(j.ps_maps[kind]), 0, loc)
	}
	testing.expect_value(t, len(j.ps_patterns), 0, loc)
	testing.expect_value(t, len(j.ps_conns), 0, loc)
	testing.expect(t, j.ps_exec == nil, "ps_exec must be cleared between commands", loc = loc)
}

live_allocations :: proc() -> int {
	return len(suite_track.allocation_map)
}

fresh_id :: proc() -> i64 {
	next_conn_id += 1
	return next_conn_id
}

fake :: proc(resp: u8 = 2) -> ^j.Conn {
	c := new(j.Conn)
	c.fd = -1
	c.id = fresh_id()
	c.resp = resp
	c.want_write = true
	c.db = &j.dbs[0]
	return c
}

fake_free :: proc(c: ^j.Conn) {
	if c.pubsub != nil {
		j.pubsub_conn_closed(c)
	}
	if c.wbuf != nil {
		j.mem_free(c.wbuf)
	}
	free(c)
}

take :: proc(c: ^j.Conn) -> string {
	s := strings.clone(string(c.wbuf[c.wpos:c.wlen]), context.temp_allocator)
	c.wpos = 0
	c.wlen = 0
	return s
}

u8s :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

words :: proc(list: ..string) -> [][]u8 {
	r := make([][]u8, len(list), context.temp_allocator)
	for w, i in list {
		r[i] = transmute([]u8)w
	}
	return r
}

dial :: proc() -> ^Client {
	pair: [2]linux.Fd
	err := linux.socketpair(.UNIX, .STREAM, .HOPOPT, &pair)
	assert(err == .NONE)
	linux.fcntl(pair[0], linux.F_SETFL, linux.Open_Flags{.NONBLOCK})
	c := new(j.Conn)
	c.fd = pair[0]
	c.id = fresh_id()
	c.resp = 2
	c.db = &j.dbs[0]
	j.acl_conn_init(c)
	for len(j.srv.conns) <= int(pair[0]) {
		append(&j.srv.conns, nil)
	}
	j.srv.conns[pair[0]] = c
	j.srv.nconns += 1
	cl := new(Client)
	cl^ = {c, pair[1], pair[0], true}
	return cl
}

alive :: proc(cl: ^Client) -> bool {
	if cl.open && j.srv.conns[cl.fd] != cl.conn {
		cl.open = false
	}
	return cl.open
}

drain :: proc(cl: ^Client) -> string {
	out := strings.builder_make(context.temp_allocator)
	buf: [65536]u8
	for {
		n, err := linux.recv(cl.peer, buf[:], {.DONTWAIT})
		if err != .NONE || n <= 0 {
			break
		}
		strings.write_bytes(&out, buf[:n])
	}
	return strings.to_string(out)
}

recv :: proc(cl: ^Client) -> string {
	if alive(cl) {
		j.conn_flush(cl.conn)
	}
	return drain(cl)
}

encode :: proc(list: ..string) -> string {
	out := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&out, "*%d\r\n", len(list))
	for w in list {
		fmt.sbprintf(&out, "$%d\r\n%s\r\n", len(w), w)
	}
	return strings.to_string(out)
}

send :: proc(cl: ^Client, list: ..string) -> string {
	assert(alive(cl))
	payload := encode(..list)
	n, err := linux.send(cl.peer, transmute([]u8)payload, {})
	assert(err == .NONE && n == len(payload))
	for _ in 0 ..< 256 {
		j.conn_read(cl.conn)
		reply := recv(cl)
		if len(reply) > 0 || !alive(cl) { return reply }
	}
	panic("synchronous actor reply did not arrive within the bounded read pump")
}

peer_closed :: proc(cl: ^Client) -> bool {
	buf: [1]u8
	n, err := linux.recv(cl.peer, buf[:], {.DONTWAIT})
	return err == .NONE && n == 0
}

hangup :: proc(cl: ^Client) {
	linux.close(cl.peer)
	cl.peer = -1
	if alive(cl) {
		j.conn_read(cl.conn)
	}
	if alive(cl) {
		j.conn_close(cl.conn)
		cl.open = false
	}
}

release :: proc(cl: ^Client) {
	if alive(cl) {
		j.conn_close(cl.conn)
		cl.open = false
	}
	if cl.peer >= 0 {
		linux.close(cl.peer)
	}
	free(cl)
}

bulk :: proc(s: string) -> string {
	return fmt.tprintf("$%d\r\n%s\r\n", len(s), s)
}

num :: proc(n: int) -> string {
	return fmt.tprintf(":%d\r\n", n)
}

head :: proc(n: int, push := false) -> string {
	return fmt.tprintf("%c%d\r\n", '>' if push else '*', n)
}

errline :: proc(s: string) -> string {
	return fmt.tprintf("-%s\r\n", s)
}

notice :: proc(verb: string, name: string, count: int, push := false) -> string {
	return strings.concatenate({head(3, push), bulk(verb), bulk(name), num(count)}, context.temp_allocator)
}

notice_nil :: proc(verb: string, count: int, push := false) -> string {
	return strings.concatenate({head(3, push), bulk(verb), "_\r\n" if push else "$-1\r\n", num(count)}, context.temp_allocator)
}

message :: proc(channel: string, payload: string, push := false) -> string {
	return strings.concatenate({head(3, push), bulk("message"), bulk(channel), bulk(payload)}, context.temp_allocator)
}

pmessage :: proc(pattern: string, channel: string, payload: string, push := false) -> string {
	return strings.concatenate({head(4, push), bulk("pmessage"), bulk(pattern), bulk(channel), bulk(payload)}, context.temp_allocator)
}

smessage :: proc(channel: string, payload: string, push := false) -> string {
	return strings.concatenate({head(3, push), bulk("smessage"), bulk(channel), bulk(payload)}, context.temp_allocator)
}

pong :: proc(arg: string) -> string {
	return strings.concatenate({head(2), bulk("pong"), bulk(arg)}, context.temp_allocator)
}

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

reject :: proc(name: string) -> string {
	return errline(cat("ERR Can't execute '", name, j.PS_REJECT_TAIL))
}

resp_line_end :: proc(s: string, at: int) -> int {
	i := strings.index(s[at:], "\r\n")
	assert(i >= 0)
	return at + i
}

resp_skip :: proc(s: string, at: int) -> int {
	stop := resp_line_end(s, at)
	kind := s[at]
	switch kind {
	case '$', '=', '!':
		n, _ := strconv_int(s[at + 1:stop])
		if n < 0 {
			return stop + 2
		}
		return stop + 2 + n + 2
	case '*', '>', '~', '%':
		n, _ := strconv_int(s[at + 1:stop])
		if kind == '%' {
			n *= 2
		}
		pos := stop + 2
		for _ in 0 ..< max(n, 0) {
			pos = resp_skip(s, pos)
		}
		return pos
	}
	return stop + 2
}

strconv_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	neg := s[0] == '-'
	v := 0
	for ch in s[1 if neg else 0:] {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		v = v * 10 + int(ch - '0')
	}
	return -v if neg else v, true
}

frames :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	pos := 0
	for pos < len(s) {
		next := resp_skip(s, pos)
		append(&out, s[pos:next])
		pos = next
	}
	return out[:]
}

sorted_frames :: proc(s: string) -> []string {
	f := frames(s)
	slice.sort(f)
	return f
}

array_items :: proc(s: string) -> []string {
	stop := resp_line_end(s, 0)
	n, _ := strconv_int(s[1:stop])
	out := make([dynamic]string, context.temp_allocator)
	pos := stop + 2
	for _ in 0 ..< max(n, 0) {
		next := resp_skip(s, pos)
		item := s[pos:next]
		if item[0] == '$' {
			body := resp_line_end(item, 0) + 2
			append(&out, item[body:len(item) - 2])
		} else {
			append(&out, item[1:len(item) - 2])
		}
		pos = next
	}
	return out[:]
}

sorted_items :: proc(s: string) -> []string {
	items := array_items(s)
	slice.sort(items)
	return items
}

expect_same :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
	if !slice.equal(got, want) {
		testing.expectf(t, false, "got %q want %q", got, want, loc = loc)
	}
}

client_line :: proc(list: string, id: i64) -> string {
	key := fmt.tprintf("id=%d ", id)
	for line in strings.split_lines(list, context.temp_allocator) {
		if strings.has_prefix(line, key) {
			return line
		}
	}
	return ""
}

info_field :: proc(info: string, name: string) -> string {
	key := cat(name, ":")
	for line in strings.split_lines(info, context.temp_allocator) {
		if strings.has_prefix(line, key) {
			return strings.trim_right(line[len(key):], "\r")
		}
	}
	return ""
}

bulk_body :: proc(s: string) -> string {
	if len(s) == 0 || s[0] != '$' {
		return s
	}
	start := resp_line_end(s, 0) + 2
	return s[start:len(s) - 2]
}

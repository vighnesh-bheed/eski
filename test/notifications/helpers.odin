package notifications

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import m "../../src"

Client :: struct {
	c:    ^m.Conn,
	peer: linux.Fd,
}

main :: proc() {}

@(private)
env_ready: bool

@(private)
env_next_id: i64 = 5000

env_setup :: proc() {
	if env_ready {
		return
	}
	env_ready = true
	m.config_table_init()
	m.config_init()
	m.db_init()
	m.commands_init()
}

expect_bytes :: proc(t: ^testing.T, got: string, want: string, loc := #caller_location) {
	if got == want {
		return
	}
	at := 0
	for at < len(got) && at < len(want) && got[at] == want[at] {
		at += 1
	}
	from := max(0, at - 40)
	testing.expectf(t, false, "bytes differ at %d of got %d want %d\n got:  %q\n want: %q", at, len(got), len(want), got[from:min(len(got), at + 80)], want[from:min(len(want), at + 80)], loc = loc)
}

frame :: proc(head: u8, items: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%c%d\r\n", head, len(items))
	for s in items {
		bulk(&b, s)
	}
	return strings.to_string(b)
}

env_check_clean :: proc(t: ^testing.T) {
	testing.expect_value(t, m.tracking_clients, 0)
	testing.expect_value(t, m.tracking_on, false)
	testing.expect_value(t, stats(), "tracking_total_keys:0\r\ntracking_total_items:0\r\ntracking_total_prefixes:0\r\n")
	testing.expect_value(t, m.key_hooks, false)
}

env_reset :: proc() {
	m.notify_apply({})
	m.trk_max_keys = 1000000
}

client_open :: proc(resp: u8 = 2) -> Client {
	sv: [2]linux.Fd
	err := linux.socketpair(.UNIX, .STREAM, .HOPOPT, &sv)
	assert(err == .NONE)
	c := new(m.Conn)
	env_next_id += 1
	c.id = env_next_id
	c.resp = resp
	c.fd = sv[0]
	c.want_write = true
	c.db = &m.dbs[0]
	for len(m.srv.conns) <= int(c.fd) {
		append(&m.srv.conns, nil)
	}
	m.srv.conns[c.fd] = c
	m.srv.nconns += 1
	return Client{c, sv[1]}
}

client_close :: proc(cl: Client) {
	m.conn_close(cl.c)
	linux.close(cl.peer)
}

argv_of :: proc(line: string) -> [][]u8 {
	parts := strings.split(line, " ", context.temp_allocator)
	argv := make([][]u8, len(parts), context.temp_allocator)
	for p, i in parts {
		argv[i] = transmute([]u8)p
	}
	return argv
}

run_argv :: proc(cl: Client, argv: [][]u8) -> string {
	m.execute(cl.c, argv)
	return take(cl)
}

run :: proc(cl: Client, line: string) -> string {
	return run_argv(cl, argv_of(line))
}

take :: proc(cl: Client) -> string {
	c := cl.c
	if c.wbuf == nil || c.wlen == c.wpos {
		return ""
	}
	s := strings.clone(string(c.wbuf[c.wpos:c.wlen]), context.temp_allocator)
	c.wpos = c.wlen
	return s
}

sleep_cycle :: proc() {
	m.tracking_before_sleep()
}

stats :: proc() -> string {
	b: [dynamic]u8
	defer delete(b)
	m.tracking_info_stats(&b)
	return strings.clone(string(b[:]), context.temp_allocator)
}

bulk :: proc(b: ^strings.Builder, s: string) {
	fmt.sbprintf(b, "$%d\r\n%s\r\n", len(s), s)
}

keys_array :: proc(b: ^strings.Builder, keys: []string) {
	fmt.sbprintf(b, "*%d\r\n", len(keys))
	for k in keys {
		bulk(b, k)
	}
}

push_inv :: proc(keys: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ">2\r\n$10\r\ninvalidate\r\n")
	keys_array(&b, keys)
	return strings.to_string(b)
}

push_null :: proc() -> string {
	return ">2\r\n$10\r\ninvalidate\r\n_\r\n"
}

msg_inv :: proc(keys: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "*3\r\n$7\r\nmessage\r\n$20\r\n__redis__:invalidate\r\n")
	keys_array(&b, keys)
	return strings.to_string(b)
}

msg_null :: proc() -> string {
	return "*3\r\n$7\r\nmessage\r\n$20\r\n__redis__:invalidate\r\n$-1\r\n"
}

push_broken :: proc(id: i64) -> string {
	return fmt.tprintf(">2\r\n$21\r\ntracking-redir-broken\r\n:%d\r\n", id)
}

resp_strings :: proc(head: u8, items: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%c%d\r\n", head, len(items))
	for s in items {
		bulk(&b, s)
	}
	return strings.to_string(b)
}

trackinginfo_reply :: proc(resp3: bool, flags: []string, redirect: i64, prefixes: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "%3\r\n" if resp3 else "*6\r\n")
	bulk(&b, "flags")
	strings.write_string(&b, resp_strings('~' if resp3 else '*', flags))
	bulk(&b, "redirect")
	fmt.sbprintf(&b, ":%d\r\n", redirect)
	bulk(&b, "prefixes")
	strings.write_string(&b, resp_strings('*', prefixes))
	return strings.to_string(b)
}

err_line :: proc(msg: string) -> string {
	return fmt.tprintf("-%s\r\n", msg)
}

info_line :: proc(text: string, name: string) -> string {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, name) {
			return strings.trim_right(line, "\r")
		}
	}
	return ""
}

list_field :: proc(list: string, id: i64, name: string) -> string {
	head := fmt.tprintf("id=%d", id)
	key := fmt.tprintf("%s=", name)
	rest := list
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 || fields[0] != head {
			continue
		}
		for f in fields {
			if strings.has_prefix(f, key) {
				return f[len(key):]
			}
		}
	}
	return ""
}

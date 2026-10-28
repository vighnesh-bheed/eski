package stringwork

import "base:runtime"
import "core:strconv"
import "core:strings"
import j "../../src"

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
	j.mono_init()
	j.config_table_init()
	j.config_init()
	j.commands_init()
	j.stats_init()
	j.acl_init()
	j.db_init()
	j.block_init()
	j.mem_init()
	j.info_init()
	j.hash_store_init()
	j.persist_init_commands()
	j.argv_init()
	booted = true
}

Session :: struct {
	conn: ^j.Conn,
	sub:  ^j.Conn,
	resp: u8,
}

new_conn :: proc(resp: u8) -> ^j.Conn {
	c := new(j.Conn)
	c.resp = resp
	c.fd = -1
	c.db = &j.dbs[0]
	j.acl_conn_init(c)
	return c
}

open_session :: proc(resp: u8, events: bool) -> Session {
	boot()
	j.update_clock()
	j.db_flush_all()
	s := Session {
		conn = new_conn(resp),
		resp = resp,
	}
	call(&s, "config", "set", "proto-max-bulk-len", "536870912")
	call(&s, "config", "set", "maxmemory-policy", "noeviction")
	if events {
		call(&s, "config", "set", "notify-keyspace-events", "KEA")
		s.sub = new_conn(j.RESP2)
		raw_call(s.sub, {bytes_of("psubscribe"), bytes_of("__key*@*__:*")})
		s.sub.wlen = 0
	} else {
		call(&s, "config", "set", "notify-keyspace-events", "")
	}
	return s
}

close_session :: proc(s: ^Session) {
	if s.sub != nil {
		raw_call(s.sub, {bytes_of("punsubscribe")})
		s.sub.wlen = 0
	}
	call(s, "config", "set", "notify-keyspace-events", "")
	j.db_flush_all()
}

bytes_of :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

raw_call :: proc(c: ^j.Conn, argv: [][]u8) -> string {
	c.wlen = 0
	j.db_cur = c.db
	j.update_clock()
	j.execute(c, argv)
	return strings.clone(string(c.wbuf[:c.wlen]))
}

call_argv :: proc(s: ^Session, argv: [][]u8) -> string {
	return raw_call(s.conn, argv)
}

call :: proc(s: ^Session, args: ..string) -> string {
	argv := make([][]u8, len(args))
	defer delete(argv)
	for a, i in args {
		argv[i] = bytes_of(a)
	}
	return call_argv(s, argv)
}

now_ms :: proc() -> i64 {
	j.update_clock()
	return j.expire_now()
}

take_events :: proc(s: ^Session) -> [dynamic]string {
	out: [dynamic]string
	if s.sub == nil {
		return out
	}
	data := string(s.sub.wbuf[:s.sub.wlen])
	at := 0
	for at < len(data) && data[at] == '*' {
		count := int(read_number(data, &at))
		parts: [4]string
		for k in 0 ..< count {
			if at >= len(data) || data[at] != '$' {
				break
			}
			size := int(read_number(data, &at))
			if k < len(parts) {
				parts[k] = data[at:at + size]
			}
			at += size + 2
		}
		if count == 4 && parts[0] == "pmessage" {
			append(&out, strings.concatenate({parts[2], " ", parts[3]}))
		}
	}
	s.sub.wlen = 0
	return out
}

read_number :: proc(data: string, at: ^int) -> i64 {
	start := at^ + 1
	end := start
	for end < len(data) && data[end] != '\r' {
		end += 1
	}
	v, _ := strconv.parse_i64(data[start:end])
	at^ = end + 2
	return v
}

int_reply :: proc(reply: string) -> (i64, bool) {
	if len(reply) < 4 || reply[0] != ':' || !strings.has_suffix(reply, "\r\n") {
		return 0, false
	}
	return strconv.parse_i64(reply[1:len(reply) - 2])
}

hex_value :: proc(c: u8) -> u8 {
	switch c {
	case '0' ..= '9':
		return c - '0'
	case 'a' ..= 'f':
		return c - 'a' + 10
	case 'A' ..= 'F':
		return c - 'A' + 10
	}
	return 0
}

hex_decode :: proc(s: string) -> []u8 {
	out := make([]u8, len(s) / 2)
	for i in 0 ..< len(out) {
		out[i] = hex_value(s[2 * i]) << 4 | hex_value(s[2 * i + 1])
	}
	return out
}

is_hex_digit :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

fold_eq :: proc(a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x := a[i]
		y := b[i]
		if x >= 'A' && x <= 'Z' {
			x += 32
		}
		if y >= 'A' && y <= 'Z' {
			y += 32
		}
		if x != y {
			return false
		}
	}
	return true
}

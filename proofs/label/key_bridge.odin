package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import lb "label"

VERSION :: "proof-harness"
REDIS_COMPAT_VERSION :: "7.4.11"

proof_conn: ^Conn
proof_watch: ^Conn
proof_logins: map[string]^Acl_User

proof_unhex :: proc(s: string) -> []u8 {
	if s == "-" {
		return make([]u8, 0)
	}
	assert(len(s) % 2 == 0)
	out := make([]u8, len(s) / 2)
	for i in 0 ..< len(out) {
		v, ok := strconv.parse_u64(s[2 * i:2 * i + 2], 16)
		assert(ok)
		out[i] = u8(v)
	}
	return out
}

proof_names :: proc(s: string) -> []string {
	if s == "-" {
		return nil
	}
	return strings.split(s, ",")
}

proof_escape :: proc(b: ^strings.Builder, out: []u8) {
	if len(out) == 0 {
		strings.write_byte(b, '-')
		return
	}
	digits := "0123456789abcdef"
	for i := 0; i < len(out); i += 1 {
		x := out[i]
		if x == '\r' && i + 1 < len(out) && out[i + 1] == '\n' {
			strings.write_byte(b, '^')
			i += 1
			continue
		}
		if x >= 0x20 && x < 0x7f && x != '\\' && x != '|' && x != '^' {
			strings.write_byte(b, x)
			continue
		}
		strings.write_string(b, "\\x")
		strings.write_byte(b, digits[x >> 4])
		strings.write_byte(b, digits[x & 15])
	}
}

proof_login :: proc(name: string, rules: []string) -> ^Acl_User {
	u := new(Acl_User)
	u.username = transmute([]u8)strings.clone(name)
	u.labels.clearance_top = true
	u.labels.trust_top = true
	for r in rules {
		e, handled := acl_label_rule(&u.labels, transmute([]u8)r)
		assert(handled && e == .None)
	}
	proof_logins[name] = u
	return u
}

proof_new_conn :: proc(u: ^Acl_User, id: i64) -> ^Conn {
	c := new(Conn)
	c.fd = -1
	c.id = id
	c.wbuf = mem_alloc(WBUF_INIT)
	c.wcap = WBUF_INIT
	c.last_cmd = "NULL"
	c.db = &dbs[0]
	c.resp = RESP2
	c.user = u
	c.authed = true
	return c
}

proof_boot :: proc(levels, comps, trusts: string, seed: i64, labelled: bool, owners: bool) {
	config_init()
	acl_init()
	access_init()
	lb.config_destroy(&label_scheme)
	lb.config_init(&label_scheme)
	for n in proof_names(levels) {
		assert(lb.config_add_level(&label_scheme, n) == .None)
	}
	for n in proof_names(comps) {
		assert(lb.config_add_compartment(&label_scheme, n) == .None)
	}
	for n in proof_names(trusts) {
		assert(lb.config_add_trust(&label_scheme, n) == .None)
	}
	labels_on = labelled && lb.config_labelled(&label_scheme)
	if owners {
		owners_on = true
		owners_wanted = true
		label_scheme_labelled = lb.config_labelled(&label_scheme)
		labels_on = true
		label_scheme_runtime = true
	}
	access_scheme_changed()
	label_stream_seed = seed
	update_clock()
	srv.now_ms = 1_700_000_000_000
	access_seconds_now = u32(srv.now_ms / 1000) & SECONDS_STAMP_MASK
	db_init()
	block_init()
	argv_init()
	commands_init()
	hooks_update()
	u: ^Acl_User
	if owners {
		clear(&pst.save_params)
		u = proof_login("any", {"owners:*", "owner-shared", "owner-operator"})
		proof_login("op", {"owner-operator"})
		proof_login("plain", {})
		proof_login("fx", {"owner:fx", "owner-operator"})
		proof_watch = proof_new_conn(proof_login("watch", {"owners:*", "owner-shared"}), 2)
	} else {
		u = proof_login("proof", {})
	}
	proof_conn = proof_new_conn(u, 1)
}

proof_on :: proc(c: ^Conn, f: []string) -> []u8 {
	argv := make([][]u8, len(f))
	for a, i in f {
		argv[i] = proof_unhex(a)
	}
	assert(c.wlen == c.wpos)
	c.wlen = 0
	c.wpos = 0
	execute(c, argv)
	out := slice.clone(c.wbuf[:c.wlen])
	c.wlen = 0
	c.wpos = 0
	return out
}

proof_run :: proc(f: []string) -> []u8 {
	if proof_watch != nil && proof_watch.wlen > 0 {
		append(&proof_pending, ..proof_watch.wbuf[:proof_watch.wlen])
		proof_watch.wlen = 0
		proof_watch.wpos = 0
	}
	out := proof_on(proof_conn, f)
	if proof_watch != nil && proof_watch.wlen > 0 {
		append(&proof_pending, ..proof_watch.wbuf[:proof_watch.wlen])
		proof_watch.wlen = 0
		proof_watch.wpos = 0
	}
	return out
}

proof_pending: [dynamic]u8

proof_sorted :: proc(b: ^strings.Builder, out: []u8, scan: bool) {
	text := string(out)
	parts := strings.split(text, "\r\n")
	head := 1
	if scan {
		assert(strings.has_prefix(text, "*2\r\n"))
		head = 4
		strings.write_string(b, parts[2])
		strings.write_byte(b, ':')
	}
	assert(len(parts) > head && strings.has_prefix(parts[head - 1], "*"))
	names := make([dynamic]string)
	for i := head; i + 1 < len(parts); i += 2 {
		assert(strings.has_prefix(parts[i], "$"))
		append(&names, parts[i + 1])
	}
	slice.sort(names[:])
	fmt.sbprintf(b, "%d", len(names))
	for n in names {
		strings.write_byte(b, ',')
		proof_escape(b, transmute([]u8)n)
	}
}

main :: proc() {
	assert(len(os.args) == 2)
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	lines := strings.split(string(input), "\n")
	booted := false
	for line in lines {
		if len(line) == 0 {
			continue
		}
		f := strings.split(line, " ")
		b := strings.builder_make()
		switch f[0] {
		case "S":
			assert(!booted)
			seed, ok := strconv.parse_i64(f[4], 10)
			assert(ok)
			owners := len(f) > 6 && f[6] == "1"
			proof_boot(f[1], f[2], f[3], seed, f[5] == "1", owners)
			booted = true
			fmt.sbprintf(&b, "S|%d|%d", len(label_scheme.levels), 1 if labels_on else 0)
			if owners {
				fmt.sbprintf(&b, "|%d", 1 if owners_on else 0)
			}
		case "U":
			assert(booted && owners_on)
			u, found := proof_logins[f[1]]
			assert(found)
			proof_conn.user = u
			access_user_changed(proof_conn)
			fmt.sbprintf(&b, "U|%s", f[1])
		case "W":
			assert(booted && proof_watch != nil)
			strings.write_string(&b, "W|")
			out := proof_on(proof_watch, f[1:])
			proof_escape(&b, out)
		case "Q":
			assert(booted && proof_watch != nil)
			strings.write_string(&b, "Q|")
			if proof_watch.wlen > 0 {
				append(&proof_pending, ..proof_watch.wbuf[:proof_watch.wlen])
				proof_watch.wlen = 0
				proof_watch.wpos = 0
			}
			proof_escape(&b, proof_pending[:])
			clear(&proof_pending)
		case "A":
			assert(booted && !labels_on)
			msg := label_scheme_apply()
			assert(msg == "")
			fmt.sbprintf(&b, "A|%d", 1 if labels_on else 0)
		case "T":
			assert(booted)
			n, ok := strconv.parse_i64(f[1], 10)
			assert(ok && n >= srv.now_ms)
			srv.now_ms = n
			access_seconds_now = u32(srv.now_ms / 1000) & SECONDS_STAMP_MASK
			fmt.sbprintf(&b, "T|%d", n)
		case "E", "R":
			assert(booted)
			strings.write_string(&b, "E|")
			proof_escape(&b, proof_run(f[1:]))
		case "N", "C":
			assert(booted)
			out := proof_run(f[1:])
			strings.write_string(&b, f[0])
			strings.write_byte(&b, '|')
			if len(out) > 0 && out[0] == '*' {
				proof_sorted(&b, out, f[0] == "C")
			} else {
				proof_escape(&b, out)
			}
		case:
			panic("unknown row")
		}
		fmt.println(strings.to_string(b))
		free_all(context.temp_allocator)
	}
}

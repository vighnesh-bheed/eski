package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import lb "label"

VERSION :: "proof-harness"
REDIS_COMPAT_VERSION :: "7.4.11"
PROJECT_LICENSE :: "Apache-2.0"

proof_conn: ^Conn
proof_user_ref: ^Acl_User

proof_unhex :: proc(s: string) -> []u8 {
	if s == "-" {
		return nil
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

proof_boot :: proc(levels, comps, trusts: string, seed: i64, labelled: bool) {
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
	access_scheme_changed()
	label_stream_seed = seed
	update_clock()
	db_init()
	block_init()
	argv_init()
	commands_init()
	hooks_update()
	u := new(Acl_User)
	u.username = transmute([]u8)strings.clone("proof")
	u.labels.clearance_top = true
	u.labels.trust_top = true
	proof_user_ref = u
	c := new(Conn)
	c.fd = -1
	c.wbuf = mem_alloc(WBUF_INIT)
	c.wcap = WBUF_INIT
	c.last_cmd = "NULL"
	c.db = &dbs[0]
	c.resp = RESP2
	c.user = u
	c.authed = true
	proof_conn = c
}

proof_execute :: proc(b: ^strings.Builder, f: []string) {
	c := proof_conn
	argv := make([][]u8, len(f))
	for a, i in f {
		argv[i] = proof_unhex(a)
		if argv[i] == nil {
			argv[i] = make([]u8, 0)
		}
	}
	assert(c.wlen == c.wpos)
	c.wlen = 0
	c.wpos = 0
	execute(c, argv)
	out := c.wbuf[:c.wlen]
	strings.write_string(b, "E|")
	proof_escape(b, out)
	c.wlen = 0
	c.wpos = 0
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
			proof_boot(f[1], f[2], f[3], seed, f[5] == "1")
			booted = true
			fmt.sbprintf(&b, "S|%d|%d", len(label_scheme.levels), 1 if labels_on else 0)
		case "A":
			assert(booted && !labels_on)
			msg := label_scheme_apply()
			assert(msg == "")
			fmt.sbprintf(&b, "A|%d", 1 if labels_on else 0)
		case "E":
			assert(booted)
			proof_execute(&b, f[1:])
		case:
			panic("unknown row")
		}
		fmt.println(strings.to_string(b))
		free_all(context.temp_allocator)
	}
}

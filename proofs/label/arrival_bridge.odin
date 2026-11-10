package main

import "base:runtime"
import "core:crypto/ed25519"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import lb "label"

VERSION :: "proof-harness"
REDIS_COMPAT_VERSION :: "7.4.11"

PROOF_FIXED :: "0123456789abcdef0123456789abcdef"

proof_users: [dynamic]^Acl_User
proof_conns: map[int]^Conn
proof_handles: [dynamic][LABEL_HANDLE_BYTES]u8
proof_tokens: map[int][]u8

proof_nat :: proc(s: string) -> int {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok && v >= 0)
	return int(v)
}

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

proof_hex_text :: proc(b: ^strings.Builder, data: []u8, upper := false) {
	digits := "0123456789ABCDEF" if upper else "0123456789abcdef"
	for x in data {
		strings.write_byte(b, digits[x >> 4])
		strings.write_byte(b, digits[x & 15])
	}
}

proof_write_hex :: proc(b: ^strings.Builder, data: []u8) {
	if len(data) == 0 {
		strings.write_byte(b, '-')
		return
	}
	proof_hex_text(b, data)
}

proof_write_label :: proc(b: ^strings.Builder, l: lb.Label) {
	fmt.sbprintf(b, "%d:", l.level)
	first := true
	for k := lb.compartment_next(l, 0); k < lb.COMPARTMENT_LIMIT; k = lb.compartment_next(l, k + 1) {
		if !first {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%d", k)
		first = false
	}
	if first {
		strings.write_byte(b, '-')
	}
	fmt.sbprintf(b, ":%d", l.trust)
}

proof_bit :: proc(b: ^strings.Builder, v: bool) {
	strings.write_byte(b, '1' if v else '0')
}

proof_names :: proc(s: string) -> [dynamic][]u8 {
	out := make([dynamic][]u8)
	if s == "-" {
		return out
	}
	parts := strings.split(s, ",")
	defer delete(parts)
	for p in parts {
		append(&out, proof_unhex(p))
	}
	return out
}

proof_private :: proc(k: int, priv: ^ed25519.Private_Key) {
	seed: [32]u8
	for i in 0 ..< 32 {
		seed[i] = u8((k * 37 + i * 11 + 5) & 0xff)
	}
	assert(ed25519.private_key_set_bytes(priv, seed[:]))
}

proof_user :: proc(login: []u8) -> ^Acl_User {
	for u in proof_users {
		if string(u.username) == string(login) {
			return u
		}
	}
	u := new(Acl_User)
	u.username = login
	append(&proof_users, u)
	return u
}

proof_handle_ordinal :: proc(h: [LABEL_HANDLE_BYTES]u8) -> int {
	for x, i in proof_handles {
		if x == h {
			return i
		}
	}
	return -1
}

proof_ctx_text :: proc(b: ^strings.Builder, x: ^Label_Context) {
	if x == nil {
		strings.write_byte(b, '-')
		return
	}
	n := proof_handle_ordinal(x.handle)
	assert(n >= 0)
	fmt.sbprintf(b, "h%d", n)
}

proof_handle_text :: proc(n: int, upper: bool) -> []u8 {
	b := strings.builder_make()
	proof_hex_text(&b, proof_handles[n][:], upper)
	return b.buf[:]
}

proof_arg :: proc(s: string) -> []u8 {
	switch {
	case s == "o":
		return transmute([]u8)strings.clone(PROOF_FIXED)
	case strings.has_prefix(s, "x:"):
		return proof_unhex(s[2:])
	case strings.has_prefix(s, "h:"):
		return proof_handle_text(proof_nat(s[2:]), false)
	case strings.has_prefix(s, "H:"):
		return proof_handle_text(proof_nat(s[2:]), true)
	case strings.has_prefix(s, "t:"):
		t, ok := proof_tokens[proof_nat(s[2:])]
		assert(ok)
		return t
	}
	panic("unknown argument")
}

proof_reset :: proc(levels, comps, trusts, audience: string, idle, cap: int) {
	for _, c in proof_conns {
		tx_conn_closed(c)
		access_conn_closed(c)
		runtime.heap_free(c.wbuf)
		free(c)
	}
	clear(&proof_conns)
	for len(label_contexts) > 0 {
		label_contexts_drop_owner(label_contexts[0].owner)
	}
	label_token_cache_clear()
	for u in proof_users {
		acl_label_rules_free(&u.labels)
		free(u)
	}
	clear(&proof_users)
	clear(&proof_handles)
	clear(&proof_tokens)
	lb.config_destroy(&label_scheme)
	lb.config_init(&label_scheme)
	for n in proof_names(levels) {
		assert(lb.config_add_level(&label_scheme, string(n)) == .None)
	}
	for n in proof_names(comps) {
		assert(lb.config_add_compartment(&label_scheme, string(n)) == .None)
	}
	for n in proof_names(trusts) {
		assert(lb.config_add_trust(&label_scheme, string(n)) == .None)
	}
	access_scheme_changed()
	labels_on = lb.config_labelled(&label_scheme)
	assert(labels_on)
	label_scheme_runtime = true
	access = {}
	label_token_audience = string(proof_unhex(audience))
	label_context_idle = i64(idle)
	label_context_cap = i64(cap)
}

proof_rules :: proc(u: ^Acl_User, keys: string, rules: string) -> int {
	acl_label_rules_reset(&u.labels)
	for r in proof_names(rules) {
		e, handled := acl_label_rule(&u.labels, r)
		assert(handled && e == .None)
	}
	count := 0
	if keys != "-" {
		parts := strings.split(keys, ",")
		defer delete(parts)
		for p in parts {
			priv: ed25519.Private_Key
			proof_private(proof_nat(p), &priv)
			key: [32]u8
			ed25519.private_key_public_bytes(&priv, key[:])
			b := strings.builder_make()
			strings.write_string(&b, "token-key:")
			proof_hex_text(&b, key[:])
			e, handled := acl_label_rule(&u.labels, b.buf[:])
			assert(handled && e == .None)
			count += 1
		}
	}
	label_token_cache_clear()
	return count
}

proof_token :: proc(f: []string) -> []u8 {
	secret, marking, trust, expires, audience, ref, flaw := proof_nat(f[2]), f[3], f[4], f[5], f[6], f[7], proof_nat(f[8])
	s := strings.builder_make()
	strings.write_string(&s, "eski-label-token 2\n" if flaw == 2 else "eski-label-token 1\n")
	if marking != "-" {
		strings.write_string(&s, "marking ")
		strings.write_bytes(&s, proof_unhex(marking))
		strings.write_byte(&s, '\n')
	}
	if trust != "-" {
		strings.write_string(&s, "trust ")
		strings.write_bytes(&s, proof_unhex(trust))
		strings.write_byte(&s, '\n')
	}
	if flaw != 8 {
		strings.write_string(&s, "expires ")
		strings.write_bytes(&s, proof_unhex(expires))
		strings.write_byte(&s, '\n')
	}
	if audience != "-" {
		strings.write_string(&s, "audience ")
		strings.write_bytes(&s, proof_unhex(audience))
		strings.write_byte(&s, '\n')
	}
	switch {
	case ref == "s":
		strings.write_string(&s, "context " + PROOF_FIXED + "\n")
	case ref == "m":
		strings.write_string(&s, "context zz\n")
	case strings.has_prefix(ref, "h:"):
		strings.write_string(&s, "context ")
		strings.write_bytes(&s, proof_handle_text(proof_nat(ref[2:]), false))
		strings.write_byte(&s, '\n')
	}
	if flaw == 3 {
		strings.write_string(&s, "expires 1\n")
	}
	if flaw == 4 {
		strings.write_string(&s, "color red\n")
	}
	if flaw == 9 {
		strings.write_string(&s, "padding ")
		for _ in 0 ..< 9000 {
			strings.write_byte(&s, 'p')
		}
		strings.write_byte(&s, '\n')
	}
	statement := s.buf[:]
	priv: ed25519.Private_Key
	proof_private(secret, &priv)
	sig: [ed25519.SIGNATURE_SIZE]u8
	ed25519.sign(&priv, statement, sig[:])
	if flaw == 1 {
		sig[0] ~= 1
	}
	t := strings.builder_make()
	proof_hex_text(&t, statement)
	if flaw == 6 {
		t.buf[0] = 'g'
	}
	if flaw != 5 {
		strings.write_byte(&t, '.')
	}
	proof_hex_text(&t, sig[:])
	if flaw == 7 {
		resize(&t.buf, len(t.buf) - 2)
	}
	return t.buf[:]
}

proof_reply :: proc(c: ^Conn, creating: bool) -> string {
	out := string(c.wbuf[:c.wlen])
	c.wlen = 0
	c.wpos = 0
	if len(out) == 0 {
		return "-"
	}
	switch out[0] {
	case '+', '-':
		assert(strings.has_suffix(out, "\r\n"))
		return strings.clone(out[1:len(out) - 2])
	case '$':
		assert(creating)
		nl := strings.index(out, "\r\n")
		body := out[nl + 2:len(out) - 2]
		h: [LABEL_HANDLE_BYTES]u8
		assert(label_hex_decode(transmute([]u8)body, h[:]))
		assert(proof_handle_ordinal(h) < 0)
		append(&proof_handles, h)
		return fmt.aprintf("h%d", len(proof_handles) - 1)
	case '*':
		parts := strings.split(out, "\r\n")
		assert(len(parts) == 10 && parts[0] == "*4" && parts[2] == "marking" && parts[6] == "trust")
		b := strings.builder_make()
		strings.write_string(&b, "info:")
		proof_write_hex(&b, transmute([]u8)parts[4])
		strings.write_byte(&b, ':')
		proof_write_hex(&b, transmute([]u8)parts[8])
		return strings.to_string(b)
	}
	panic("unexpected reply")
}

proof_handler :: proc(c: ^Conn, s: ^Cmd_Slot, inner: [][]u8) -> string {
	if .Multi in c.txf && (s == nil || !tx_immediate(s.cmd)) {
		return "queued"
	}
	if s == nil {
		return "-"
	}
	h := s.cmd.handler
	switch {
	case h == cmd_multi:
		cmd_multi(c, inner)
	case h == cmd_exec:
		if .Multi in c.txf && .Dirty_Exec not_in c.txf {
			tx_discard(c)
			return "exec"
		}
		cmd_exec(c, inner)
	case h == cmd_discard:
		cmd_discard(c, inner)
	case h == cmd_label && len(inner) >= 2 && eq_nocase(inner[1], "session"):
		cmd_label(c, inner)
	case h == cmd_context && len(inner) >= 2 && (eq_nocase(inner[1], "create") || eq_nocase(inner[1], "info") || eq_nocase(inner[1], "drop")):
		cmd_context(c, inner)
		return proof_reply(c, eq_nocase(inner[1], "create"))
	case:
		return "-"
	}
	return proof_reply(c, false)
}

proof_request :: proc(b: ^strings.Builder, kind: string, id: int, f: []string) {
	c, found := proof_conns[id]
	assert(found)
	argv := make([][]u8, len(f))
	for a, i in f {
		argv[i] = proof_arg(a)
	}
	assert(c.wlen == 0)
	inner, s, ok := access_enter(c, argv, lookup_entry(argv[0]))
	strings.write_string(b, kind)
	if ok {
		strings.write_string(b, "|ok:")
		proof_write_label(b, access.label)
		fmt.sbprintf(b, ":%d:", len(inner))
		proof_ctx_text(b, access.ctx)
		strings.write_byte(b, '|')
		strings.write_string(b, proof_handler(c, s, inner))
	} else {
		strings.write_string(b, "|no:")
		strings.write_string(b, proof_reply(c, false))
		strings.write_string(b, "|-")
	}
	a := c.label
	assert(a != nil)
	strings.write_byte(b, '|')
	proof_bit(b, .Multi in c.txf)
	proof_bit(b, .Dirty_Exec in c.txf)
	proof_bit(b, a.explicit)
	strings.write_byte(b, ':')
	if a.explicit {
		proof_write_label(b, a.session)
	} else {
		strings.write_byte(b, '-')
	}
	strings.write_byte(b, ':')
	proof_write_label(b, a.bound)
	fmt.sbprintf(b, "|%d", len(label_contexts))
}

main :: proc() {
	assert(len(os.args) == 2)
	access_init()
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	lines := strings.split(string(input), "\n")
	for line in lines {
		if len(line) == 0 {
			continue
		}
		f := strings.split(line, " ")
		b := strings.builder_make()
		switch f[0] {
		case "AX":
			proof_reset(f[1], f[2], f[3], f[4], proof_nat(f[5]), proof_nat(f[6]))
			fmt.sbprintf(&b, "AX|%d|%d|%d", len(label_scheme.levels), len(label_scheme.compartments), len(label_scheme.trusts))
		case "AU":
			u := proof_user(proof_unhex(f[1]))
			n := proof_rules(u, f[6], f[7])
			strings.write_string(&b, "AU|")
			proof_write_label(&b, access_ceiling(u))
			strings.write_byte(&b, '|')
			proof_bit(&b, u.labels.per_command)
			strings.write_byte(&b, '|')
			proof_bit(&b, u.labels.require_token)
			fmt.sbprintf(&b, "|%d", n)
		case "AC":
			c := new(Conn)
			c^ = Conn{fd = -1, resp = 2, wcap = 1 << 16, user = proof_user(proof_unhex(f[2])), authed = true}
			c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
			id := proof_nat(f[1])
			assert(id not_in proof_conns)
			proof_conns[id] = c
			fmt.sbprintf(&b, "AC|%d", id)
		case "AT":
			srv.now_ms = i64(proof_nat(f[1]))
			fmt.sbprintf(&b, "AT|%d", srv.now_ms)
		case "AO":
			n := proof_nat(f[1])
			proof_tokens[n] = proof_token(f)
			fmt.sbprintf(&b, "AO|%d", n)
		case "AW":
			label_context_cron()
			fmt.sbprintf(&b, "AW|%d", len(label_contexts))
		case "AQ":
			c, found := proof_conns[proof_nat(f[1])]
			assert(found)
			x := label_context_find(c, proof_arg(f[2]))
			strings.write_string(&b, "AQ|")
			proof_ctx_text(&b, x)
			fmt.sbprintf(&b, "|%d", len(label_contexts))
		case "AS":
			argv := make([][]u8, len(f) - 1)
			for a, i in f[1:] {
				argv[i] = proof_arg(a)
			}
			cmd := lookup_command(argv[0])
			assert(cmd != nil)
			strings.write_string(&b, "AS|")
			proof_bit(&b, label_script_denied(cmd, argv))
		case "AR", "AH":
			proof_request(&b, f[0], proof_nat(f[1]), f[2:])
		case:
			panic("unknown row")
		}
		fmt.println(strings.to_string(b))
	}
}

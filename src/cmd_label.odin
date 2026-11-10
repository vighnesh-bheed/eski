package main

import "core:crypto/ed25519"
import "core:crypto/sha2"
import "core:sys/linux"
import lb "label"

LABEL_HANDLE_BYTES :: 16
LABEL_TOKEN_MAX :: 8192
LABEL_TOKEN_HEADER :: "eski-label-token 1"
LABEL_TOKEN_CACHE_MAX :: 4096
LABEL_TOKEN_KEYS_MAX :: 8

ERR_LABEL_CONTEXT_CAP :: "ERR this login already holds the maximum number of contexts"

Label_Context :: struct {
	handle:  [LABEL_HANDLE_BYTES]u8,
	owner:   []u8,
	label:   lb.Label,
	last_ms: i64,
	slot:    int,
}

@(private = "file")
Label_Token_Entry :: struct {
	label:       lb.Label,
	expires_ms:  i64,
	has_context: bool,
	handle:      [LABEL_HANDLE_BYTES]u8,
}

label_contexts: [dynamic]^Label_Context

@(private = "file")
label_context_index: map[[LABEL_HANDLE_BYTES]u8]^Label_Context

@(private = "file")
label_context_cursor: int

@(private = "file")
label_token_cache: map[[32]u8]Label_Token_Entry

@(private = "file")
label_help_lines := [?]string {
	"LABEL <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"AS <marking> [TRUST <trust>] [CONTEXT <handle>] <command> [<arg> ...]",
	"    Run one command at the given lb.",
	"AS CONTEXT <handle> <command> [<arg> ...]",
	"    Run one command at the label of a context.",
	"AS TOKEN <token> <command> [<arg> ...]",
	"    Run one command at the label of a signed label token.",
	"SESSION <marking> [TRUST <trust>]",
	"    Set the label of this connection's later commands.",
	"WHOAMI",
	"    Show the login, its clearance and the label of this command.",
	"HELP",
	"    Print this help.",
}

@(private = "file")
context_help_lines := [?]string {
	"CONTEXT <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"CREATE [LEVEL <marking>] [TRUST <trust>]",
	"    Create a context with a fixed label and return its handle.",
	"INFO <handle>",
	"    Show the marking and trust of a context.",
	"DROP <handle>",
	"    End a context.",
	"HELP",
	"    Print this help.",
}

@(private = "file")
label_hex_value :: proc "contextless" (b: u8) -> int {
	switch {
	case b >= '0' && b <= '9':
		return int(b - '0')
	case b >= 'a' && b <= 'f':
		return int(b - 'a') + 10
	case b >= 'A' && b <= 'F':
		return int(b - 'A') + 10
	}
	return -1
}

label_hex_decode :: proc(text: []u8, out: []u8) -> bool {
	if len(text) != 2 * len(out) {
		return false
	}
	for i in 0 ..< len(out) {
		hi := label_hex_value(text[2 * i])
		lo := label_hex_value(text[2 * i + 1])
		if hi < 0 || lo < 0 {
			return false
		}
		out[i] = u8(hi << 4 | lo)
	}
	return true
}

label_hex_encode :: proc(b: ^[dynamic]u8, data: []u8) {
	hexd := "0123456789abcdef"
	for x in data {
		sb_byte(b, hexd[x >> 4])
		sb_byte(b, hexd[x & 15])
	}
}

label_handle_shaped :: proc(text: []u8) -> bool {
	h: [LABEL_HANDLE_BYTES]u8
	return label_hex_decode(text, h[:])
}

@(private = "file")
label_owner_of :: proc(c: ^Conn) -> []u8 {
	if c.user == nil {
		return nil
	}
	return c.user.username
}

@(private = "file")
label_context_expired :: proc(x: ^Label_Context) -> bool {
	return srv.now_ms - x.last_ms >= label_context_idle * 1000
}

@(private = "file")
label_context_remove :: proc(x: ^Label_Context) {
	delete_key(&label_context_index, x.handle)
	last := label_contexts[len(label_contexts) - 1]
	label_contexts[x.slot] = last
	last.slot = x.slot
	pop(&label_contexts)
	delete(x.owner)
	free(x)
}

label_context_find :: proc(c: ^Conn, text: []u8) -> ^Label_Context {
	h: [LABEL_HANDLE_BYTES]u8
	if !label_hex_decode(text, h[:]) {
		return nil
	}
	x := label_context_index[h]
	if x == nil {
		return nil
	}
	if label_context_expired(x) {
		label_context_remove(x)
		return nil
	}
	if !bytes_eq(x.owner, label_owner_of(c)) || c.user == nil {
		return nil
	}
	if !lb.ceiling_admits(access_ceiling(c.user), x.label) {
		return nil
	}
	x.last_ms = srv.now_ms
	return x
}

@(private = "file")
label_context_count :: proc(owner: []u8) -> i64 {
	n: i64 = 0
	for x in label_contexts {
		if bytes_eq(x.owner, owner) && !label_context_expired(x) {
			n += 1
		}
	}
	return n
}

label_contexts_prune :: proc() {
	for i := len(label_contexts) - 1; i >= 0; i -= 1 {
		if i < len(label_contexts) && acl_user_find(label_contexts[i].owner) == nil {
			label_context_remove(label_contexts[i])
		}
	}
}

label_contexts_drop_owner :: proc(owner: []u8) {
	for i := len(label_contexts) - 1; i >= 0; i -= 1 {
		if bytes_eq(label_contexts[i].owner, owner) {
			label_context_remove(label_contexts[i])
		}
	}
}

label_context_cron :: proc() {
	if len(label_contexts) == 0 {
		return
	}
	for _ in 0 ..< 64 {
		if len(label_contexts) == 0 {
			return
		}
		if label_context_cursor >= len(label_contexts) {
			label_context_cursor = 0
		}
		x := label_contexts[label_context_cursor]
		if label_context_expired(x) {
			label_context_remove(x)
		} else {
			label_context_cursor += 1
		}
	}
}

@(private = "file")
label_random :: proc(out: []u8) -> bool {
	got := 0
	for got < len(out) {
		n, err := linux.getrandom(out[got:], {})
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			return false
		}
		got += n
	}
	return true
}

label_token_cache_clear :: proc() {
	clear(&label_token_cache)
}

@(private = "file")
label_parse_with_trust :: proc(marking: []u8, trust: []u8, has_trust: bool) -> (l: lb.Label, ok: bool) {
	parsed, f := lb.parse(&label_scheme, string(marking))
	if f.error != .None {
		return {}, false
	}
	if has_trust {
		for b in marking {
			if b == ';' {
				return {}, false
			}
		}
		t, found := lb.config_find_trust(&label_scheme, string(trust))
		if !found {
			return {}, false
		}
		parsed.trust = u8(t)
	}
	return parsed, true
}

@(private = "file")
label_token_field :: proc(line: []u8, key: string) -> ([]u8, bool) {
	if len(line) <= len(key) || string(line[:len(key)]) != key || line[len(key)] != ' ' {
		return nil, false
	}
	return line[len(key) + 1:], true
}

@(private = "file")
label_token_check :: proc(c: ^Conn, token: []u8) -> (entry: Label_Token_Entry, ok: bool) {
	if c.user == nil || len(c.user.labels.keys) == 0 || len(label_token_audience) == 0 || len(token) > LABEL_TOKEN_MAX {
		return {}, false
	}
	dot := -1
	for b, i in token {
		if b == '.' {
			dot = i
			break
		}
	}
	if dot <= 0 || dot & 1 != 0 {
		return {}, false
	}
	statement := make([]u8, dot / 2, context.temp_allocator)
	if !label_hex_decode(token[:dot], statement) {
		return {}, false
	}
	signature: [ed25519.SIGNATURE_SIZE]u8
	if !label_hex_decode(token[dot + 1:], signature[:]) {
		return {}, false
	}
	verified := false
	for &key in c.user.labels.keys {
		pub: ed25519.Public_Key
		if !ed25519.public_key_set_bytes(&pub, key[:]) {
			continue
		}
		if ed25519.verify(&pub, statement, signature[:]) {
			verified = true
			break
		}
	}
	if !verified {
		return {}, false
	}
	lines := make([dynamic][]u8, context.temp_allocator)
	start := 0
	for i in 0 ..= len(statement) {
		if i == len(statement) || statement[i] == '\n' {
			append(&lines, statement[start:i])
			start = i + 1
		}
	}
	if len(lines) > 0 && len(lines[len(lines) - 1]) == 0 {
		pop(&lines)
	}
	if len(lines) == 0 || string(lines[0]) != LABEL_TOKEN_HEADER {
		return {}, false
	}
	marking, trust, expires, audience, handle: []u8
	seen: [5]bool
	keys := [5]string{"marking", "trust", "expires", "audience", "context"}
	for line in lines[1:] {
		matched := false
		for key, k in keys {
			value, hit := label_token_field(line, key)
			if !hit {
				continue
			}
			if seen[k] {
				return {}, false
			}
			seen[k] = true
			matched = true
			switch k {
			case 0:
				marking = value
			case 1:
				trust = value
			case 2:
				expires = value
			case 3:
				audience = value
			case 4:
				handle = value
			}
		}
		if !matched {
			return {}, false
		}
	}
	if !seen[0] || !seen[2] || !seen[3] || string(audience) != label_token_audience {
		return {}, false
	}
	deadline, dok := parse_i64(expires)
	if !dok {
		return {}, false
	}
	l, lok := label_parse_with_trust(marking, trust, seen[1])
	if !lok {
		return {}, false
	}
	entry = Label_Token_Entry{label = l, expires_ms = deadline}
	if seen[4] {
		if !label_hex_decode(handle, entry.handle[:]) {
			return {}, false
		}
		entry.has_context = true
	}
	return entry, true
}

label_token_verify :: proc(c: ^Conn, token: []u8) -> (l: lb.Label, ctx: ^Label_Context, ok: bool) {
	if c.user == nil {
		return {}, nil, false
	}
	h: sha2.Context_256
	sha2.init_256(&h)
	sha2.update(&h, c.user.username)
	zero := [1]u8{0}
	sha2.update(&h, zero[:])
	sha2.update(&h, token)
	digest: [32]u8
	sha2.final(&h, digest[:])
	entry, cached := label_token_cache[digest]
	if !cached {
		checked, good := label_token_check(c, token)
		if !good {
			return {}, nil, false
		}
		if len(label_token_cache) >= LABEL_TOKEN_CACHE_MAX {
			clear(&label_token_cache)
		}
		label_token_cache[digest] = checked
		entry = checked
	}
	if srv.now_ms >= entry.expires_ms {
		delete_key(&label_token_cache, digest)
		return {}, nil, false
	}
	if !lb.config_valid(&label_scheme, entry.label) || !lb.ceiling_admits(access_ceiling(c.user), entry.label) {
		return {}, nil, false
	}
	if entry.has_context {
		text := make([dynamic]u8, context.temp_allocator)
		label_hex_encode(&text, entry.handle[:])
		x := label_context_find(c, text[:])
		if x == nil || x.label != entry.label {
			return {}, nil, false
		}
		ctx = x
	}
	return entry.label, ctx, true
}

label_as_parse :: proc(c: ^Conn, args: [][]u8, out: ^lb.Label, ctx: ^^Label_Context) -> (used: int, msg: string) {
	rules := &c.user.labels if c.user != nil else nil
	i := 2
	if i >= len(args) {
		return 0, "ERR wrong number of arguments for 'label|as' command"
	}
	switch {
	case eq_nocase(args[i], "token") && i + 2 < len(args):
		l, x, ok := label_token_verify(c, args[i + 1])
		if !ok {
			return 0, ERR_LABEL_TOKEN
		}
		out^ = l
		ctx^ = x
		return i + 2, ""
	case rules != nil && rules.require_token:
		return 0, ERR_LABEL_TOKEN_ONLY
	case eq_nocase(args[i], "context") && i + 2 < len(args) && label_handle_shaped(args[i + 1]):
		x := label_context_find(c, args[i + 1])
		if x == nil {
			return 0, ERR_LABEL_CONTEXT
		}
		out^ = x.label
		ctx^ = x
		return i + 2, ""
	}
	marking := args[i]
	i += 1
	trust: []u8
	has_trust := false
	if i + 2 < len(args) && eq_nocase(args[i], "trust") {
		trust = args[i + 1]
		has_trust = true
		i += 2
	}
	l, ok := label_parse_with_trust(marking, trust, has_trust)
	if !ok || !lb.ceiling_admits(access_ceiling(c.user), l) {
		return 0, ERR_LABEL_INVALID
	}
	if i + 2 < len(args) && eq_nocase(args[i], "context") && label_handle_shaped(args[i + 1]) {
		x := label_context_find(c, args[i + 1])
		if x == nil {
			return 0, ERR_LABEL_CONTEXT
		}
		if x.label != l {
			return 0, ERR_LABEL_CONTEXT_MISMATCH
		}
		ctx^ = x
		i += 2
	}
	if i >= len(args) {
		return 0, "ERR wrong number of arguments for 'label|as' command"
	}
	out^ = l
	return i, ""
}

@(private = "file")
label_reply_text :: proc(c: ^Conn, l: lb.Label, marking_only: bool) {
	b := make([dynamic]u8, context.temp_allocator)
	if marking_only {
		access_format_marking(&b, l)
	} else {
		access_format_label(&b, l)
	}
	reply_bulk(c, b[:])
}

@(private = "file")
label_whoami :: proc(c: ^Conn) {
	ceiling := access_ceiling(c.user)
	rules := &c.user.labels if c.user != nil else nil
	reply_map(c, 10)
	reply_bulk_str(c, "login")
	if c.user != nil {
		reply_bulk(c, c.user.username)
	} else {
		reply_null(c)
	}
	reply_bulk_str(c, "label")
	label_reply_text(c, access.label, false)
	reply_bulk_str(c, "marking")
	label_reply_text(c, access.label, true)
	reply_bulk_str(c, "trust")
	reply_bulk_str(c, access_trust_name(access.label))
	reply_bulk_str(c, "clearance")
	label_reply_text(c, ceiling, true)
	reply_bulk_str(c, "trust-clearance")
	reply_bulk_str(c, access_trust_name(ceiling))
	reply_bulk_str(c, "session")
	reply_int(c, 1 if c.label != nil && c.label.explicit else 0)
	reply_bulk_str(c, "per-command")
	reply_int(c, 1 if rules != nil && rules.per_command else 0)
	reply_bulk_str(c, "require-token")
	reply_int(c, 1 if rules != nil && rules.require_token else 0)
	reply_bulk_str(c, "top")
	reply_int(c, 1 if access.top else 0)
}

@(private = "file")
label_session :: proc(c: ^Conn, argv: [][]u8) {
	rules := &c.user.labels if c.user != nil else nil
	if rules != nil && (rules.per_command || rules.require_token) {
		reply_error(c, ERR_LABEL_SESSION_DENIED)
		return
	}
	trust: []u8
	has_trust := false
	switch len(argv) {
	case 3:
	case 5:
		if !eq_nocase(argv[3], "trust") {
			reply_error(c, ERR_SYNTAX)
			return
		}
		trust = argv[4]
		has_trust = true
	case:
		reply_error(c, ERR_SYNTAX)
		return
	}
	l, ok := label_parse_with_trust(argv[2], trust, has_trust)
	if !ok || !lb.ceiling_admits(access_ceiling(c.user), l) {
		reply_error(c, ERR_LABEL_INVALID)
		return
	}
	if _, interned := access_intern(l); !interned {
		reply_error(c, ERR_LABEL_INVALID)
		return
	}
	a := access_conn(c)
	a.session = l
	a.explicit = true
	reply_ok(c)
}

cmd_label :: proc(c: ^Conn, argv: [][]u8) {
	sub := argv[1]
	switch {
	case eq_nocase(sub, "help"):
		c.last_cmd = "label|help"
		if len(argv) != 2 {
			reply_wrong_args(c, "label|help")
			return
		}
		reply_array(c, len(label_help_lines))
		for line in label_help_lines {
			reply_simple(c, line)
		}
		return
	case eq_nocase(sub, "as"):
		c.last_cmd = "label|as"
		if len(argv) < 4 {
			reply_wrong_args(c, "label|as")
			return
		}
	case eq_nocase(sub, "session"):
		c.last_cmd = "label|session"
		if len(argv) < 3 {
			reply_wrong_args(c, "label|session")
			return
		}
	case eq_nocase(sub, "whoami"):
		c.last_cmd = "label|whoami"
		if len(argv) != 2 {
			reply_wrong_args(c, "label|whoami")
			return
		}
	case:
		c.last_cmd = "NULL"
		reply_unknown_subcommand(c, sub, "LABEL")
		return
	}
	if !labels_on {
		reply_error(c, ERR_LABELS_OFF)
		return
	}
	switch {
	case eq_nocase(sub, "as"):
		reply_error(c, ERR_LABEL_NESTED)
	case eq_nocase(sub, "session"):
		label_session(c, argv)
	case eq_nocase(sub, "whoami"):
		label_whoami(c)
	}
}

@(private = "file")
context_create :: proc(c: ^Conn, argv: [][]u8) {
	l := access.label
	marking, trust: []u8
	has_level, has_trust := false, false
	for i := 2; i < len(argv); i += 2 {
		if i + 1 >= len(argv) {
			reply_error(c, ERR_SYNTAX)
			return
		}
		switch {
		case eq_nocase(argv[i], "level") && !has_level:
			marking = argv[i + 1]
			has_level = true
		case eq_nocase(argv[i], "trust") && !has_trust:
			trust = argv[i + 1]
			has_trust = true
		case:
			reply_error(c, ERR_SYNTAX)
			return
		}
	}
	if has_level {
		parsed, ok := label_parse_with_trust(marking, trust, has_trust)
		if !ok {
			reply_error(c, ERR_LABEL_INVALID)
			return
		}
		if !has_trust {
			semi := false
			for b in marking {
				semi = semi || b == ';'
			}
			if !semi {
				parsed.trust = l.trust
			}
		}
		l = parsed
	} else if has_trust {
		t, found := lb.config_find_trust(&label_scheme, string(trust))
		if !found {
			reply_error(c, ERR_LABEL_INVALID)
			return
		}
		l.trust = u8(t)
	}
	if c.user == nil || !lb.ceiling_admits(access_ceiling(c.user), l) {
		reply_error(c, ERR_LABEL_INVALID)
		return
	}
	if _, interned := access_intern(l); !interned {
		reply_error(c, ERR_LABEL_INVALID)
		return
	}
	if label_context_count(c.user.username) >= label_context_cap {
		reply_error(c, ERR_LABEL_CONTEXT_CAP)
		return
	}
	x := new(Label_Context)
	for {
		if !label_random(x.handle[:]) {
			free(x)
			reply_error(c, "ERR the system random source failed")
			return
		}
		if x.handle not_in label_context_index {
			break
		}
	}
	x.owner = clone_bytes(c.user.username)
	x.label = l
	x.last_ms = srv.now_ms
	x.slot = len(label_contexts)
	append(&label_contexts, x)
	label_context_index[x.handle] = x
	b := make([dynamic]u8, context.temp_allocator)
	label_hex_encode(&b, x.handle[:])
	reply_bulk(c, b[:])
}

cmd_context :: proc(c: ^Conn, argv: [][]u8) {
	sub := argv[1]
	switch {
	case eq_nocase(sub, "help"):
		c.last_cmd = "context|help"
		if len(argv) != 2 {
			reply_wrong_args(c, "context|help")
			return
		}
		reply_array(c, len(context_help_lines))
		for line in context_help_lines {
			reply_simple(c, line)
		}
		return
	case eq_nocase(sub, "create"):
		c.last_cmd = "context|create"
	case eq_nocase(sub, "info"), eq_nocase(sub, "drop"):
		c.last_cmd = "context|info" if eq_nocase(sub, "info") else "context|drop"
		if len(argv) != 3 {
			reply_wrong_args(c, c.last_cmd)
			return
		}
	case:
		c.last_cmd = "NULL"
		reply_unknown_subcommand(c, sub, "CONTEXT")
		return
	}
	if !labels_on {
		reply_error(c, ERR_LABELS_OFF)
		return
	}
	if eq_nocase(sub, "create") {
		context_create(c, argv)
		return
	}
	x := label_context_find(c, argv[2])
	if x == nil {
		reply_error(c, ERR_LABEL_CONTEXT)
		return
	}
	if eq_nocase(sub, "drop") {
		label_context_remove(x)
		reply_ok(c)
		return
	}
	reply_map(c, 2)
	reply_bulk_str(c, "marking")
	label_reply_text(c, x.label, true)
	reply_bulk_str(c, "trust")
	reply_bulk_str(c, access_trust_name(x.label))
}

label_script_denied :: proc(cmd: ^Command, argv: [][]u8) -> bool {
	if cmd.handler == cmd_label {
		return len(argv) < 2 || !(eq_nocase(argv[1], "whoami") || eq_nocase(argv[1], "help"))
	}
	if cmd.handler == cmd_context {
		return len(argv) < 2 || !eq_nocase(argv[1], "help")
	}
	return false
}

@(private = "file")
label_commands := [?]Command{{"label", cmd_label, -2}, {"context", cmd_context, -2}}

@(init)
register_label_commands :: proc "contextless" () {
	register_commands(label_commands[:])
}

@(private = "file")
acl_label_text :: proc(rule: []u8) -> []u8 {
	out := make([]u8, len(rule), context.temp_allocator)
	for b, i in rule {
		out[i] = ' ' if b == '+' else b
	}
	return out
}

acl_label_rule :: proc(r: ^Acl_Label_Rules, rule: []u8) -> (e: Acl_Rule_Error, handled: bool) {
	words := [?]string{"label-per-command", "label-per-session", "require-token", "token-optional", "reset-token-keys"}
	prefixed := len(rule) > 10 && eq_nocase(rule[:10], "clearance:") || len(rule) > 6 && eq_nocase(rule[:6], "trust:") || len(rule) > 10 && eq_nocase(rule[:10], "token-key:")
	if !prefixed {
		found := false
		for w in words {
			if eq_nocase(rule, w) {
				found = true
			}
		}
		if !found {
			return .None, false
		}
	}
	if !label_scheme_runtime {
		return .None, true
	}
	if !labels_on {
		return .Labels_Off, true
	}
	switch {
	case eq_nocase(rule, "label-per-command"):
		r.per_command = true
	case eq_nocase(rule, "label-per-session"):
		r.per_command = false
	case eq_nocase(rule, "require-token"):
		r.require_token = true
	case eq_nocase(rule, "token-optional"):
		r.require_token = false
	case eq_nocase(rule, "reset-token-keys"):
		clear(&r.keys)
	case eq_nocase(rule[:min(len(rule), 10)], "token-key:"):
		key: [32]u8
		if !label_hex_decode(rule[10:], key[:]) {
			return .Bad_Label, true
		}
		pub: ed25519.Public_Key
		if !ed25519.public_key_set_bytes(&pub, key[:]) {
			return .Bad_Label, true
		}
		for k in r.keys {
			if k == key {
				return .None, true
			}
		}
		if len(r.keys) >= LABEL_TOKEN_KEYS_MAX {
			return .Bad_Label, true
		}
		append(&r.keys, key)
	case eq_nocase(rule[:min(len(rule), 10)], "clearance:"):
		text := acl_label_text(rule[10:])
		if string(text) == "*" {
			r.clearance_top = true
			r.clearance_set = false
			r.clearance = {}
			return .None, true
		}
		for b in text {
			if b == ';' {
				return .Bad_Label, true
			}
		}
		l, f := lb.parse(&label_scheme, string(text))
		if f.error != .None {
			return .Bad_Label, true
		}
		r.clearance = l
		r.clearance_set = true
		r.clearance_top = false
	case:
		text := acl_label_text(rule[6:])
		if string(text) == "*" {
			r.trust_top = true
			r.trust_set = false
			r.trust = 0
			return .None, true
		}
		t, found := lb.config_find_trust(&label_scheme, string(text))
		if !found {
			return .Bad_Label, true
		}
		r.trust = u8(t)
		r.trust_set = true
		r.trust_top = false
	}
	return .None, true
}

acl_label_rules_reset :: proc(r: ^Acl_Label_Rules) {
	keys := r.keys
	clear(&keys)
	r^ = Acl_Label_Rules{keys = keys}
}

acl_label_rules_copy :: proc(dst, src: ^Acl_Label_Rules) {
	keys := dst.keys
	clear(&keys)
	append(&keys, ..src.keys[:])
	dst^ = src^
	dst.keys = keys
}

acl_label_rules_free :: proc(r: ^Acl_Label_Rules) {
	delete(r.keys)
	r.keys = nil
}

@(private = "file")
acl_label_rule_text :: proc(b: ^[dynamic]u8, text: string) {
	for i in 0 ..< len(text) {
		sb_byte(b, '+' if text[i] == ' ' else text[i])
	}
}

acl_label_describe :: proc(b: ^[dynamic]u8, r: ^Acl_Label_Rules) {
	if r.clearance_top {
		sb_str(b, "clearance:* ")
	} else if r.clearance_set {
		text := make([dynamic]u8, context.temp_allocator)
		access_format_marking(&text, r.clearance)
		sb_str(b, "clearance:")
		acl_label_rule_text(b, string(text[:]))
		sb_byte(b, ' ')
	}
	if r.trust_top {
		sb_str(b, "trust:* ")
	} else if r.trust_set {
		sb_str(b, "trust:")
		acl_label_rule_text(b, lb.config_trust_name(&label_scheme, int(r.trust)))
		sb_byte(b, ' ')
	}
	if r.per_command {
		sb_str(b, "label-per-command ")
	}
	if r.require_token {
		sb_str(b, "require-token ")
	}
	for &k in r.keys {
		sb_str(b, "token-key:")
		label_hex_encode(b, k[:])
		sb_byte(b, ' ')
	}
}

acl_label_flag_count :: proc(r: ^Acl_Label_Rules) -> int {
	return int(r.per_command) + int(r.require_token)
}

acl_label_reply_flags :: proc(c: ^Conn, r: ^Acl_Label_Rules) {
	if r.per_command {
		reply_bulk_str(c, "label-per-command")
	}
	if r.require_token {
		reply_bulk_str(c, "require-token")
	}
}

acl_label_reply_fields :: proc(c: ^Conn, r: ^Acl_Label_Rules) {
	reply_bulk_str(c, "clearance")
	if r.clearance_top {
		reply_bulk_str(c, "*")
	} else if r.clearance_set {
		label_reply_text(c, r.clearance, true)
	} else {
		reply_bulk_str(c, "")
	}
	reply_bulk_str(c, "trust")
	if r.trust_top {
		reply_bulk_str(c, "*")
	} else if r.trust_set {
		reply_bulk_str(c, lb.config_trust_name(&label_scheme, int(r.trust)))
	} else {
		reply_bulk_str(c, "")
	}
	reply_bulk_str(c, "token-keys")
	reply_array(c, len(r.keys))
	for &k in r.keys {
		b := make([dynamic]u8, context.temp_allocator)
		label_hex_encode(&b, k[:])
		reply_bulk(c, b[:])
	}
}

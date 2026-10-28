package main

import "core:crypto/sha2"
import "core:sys/linux"

ACL_CMD_COUNT :: len(cmd_docs)
ACL_WORDS :: ACL_CMD_COUNT / 64 + 1
ACL_FUTURE_BIT :: ACL_WORDS * 64 - 1
ACL_HASH_LEN :: 64
ACL_LOG_GROUP_MS :: 60000
ACL_LOG_SCAN :: 10
ACL_UNAUTH_MBULK :: 10
ACL_UNAUTH_BULK :: 16384
ACL_UNAUTH_QBUF :: 1024 * 1024
ACL_UNAUTH_OBUF :: 1024
ACL_GENPASS_MAX_BITS :: 4096
ACL_NAME_MAX :: 64

ERR_NOAUTH :: "NOAUTH Authentication required."
ERR_NOAUTH_HELLO :: "NOAUTH HELLO must be called with the client already authenticated, otherwise the HELLO <proto> AUTH <user> <pass> option can be used to authenticate the client and select the RESP protocol version at the same time"
ERR_ACL_NO_FILE :: "ERR This Redis instance is not configured to use an ACL file. You may want to specify users via the ACL SETUSER command and then issue a CONFIG REWRITE (assuming you have a Redis configuration file set) in order to store users in the Redis configuration."

Acl_Result :: enum u8 {
	Ok,
	Cmd,
	Key,
	Auth,
	Channel,
}

Acl_Context :: enum u8 {
	Toplevel,
	Lua,
	Multi,
	Module,
}

Acl_Errno :: enum u8 {
	None,
	Noent,
	Inval,
	Exist,
	Isdir,
	Nodev,
	Badmsg,
	Already,
	Child,
}

Acl_User_Flag :: enum u8 {
	Enabled,
	Disabled,
	Nopass,
	Skip_Sanitize,
	Sanitize,
}

Acl_User_Flags :: bit_set[Acl_User_Flag;u8]

Acl_Selector_Flag :: enum u8 {
	Root,
	All_Keys,
	All_Commands,
	All_Channels,
}

Acl_Selector_Flags :: bit_set[Acl_Selector_Flag;u8]

Acl_Perm :: enum u8 {
	Read,
	Write,
}

Acl_Perms :: bit_set[Acl_Perm;u8]

Acl_Pattern :: struct {
	pattern: []u8,
	perms:   Acl_Perms,
}

Acl_First_Args :: struct {
	id:   int,
	args: [dynamic][]u8,
}

Acl_Selector :: struct {
	flags:     Acl_Selector_Flags,
	allowed:   [ACL_WORDS]u64,
	firstargs: [dynamic]Acl_First_Args,
	patterns:  [dynamic]Acl_Pattern,
	channels:  [dynamic][]u8,
	rules:     [dynamic]u8,
}

Acl_User :: struct {
	name:      []u8,
	flags:     Acl_User_Flags,
	passwords: [dynamic][ACL_HASH_LEN]u8,
	selectors: [dynamic]^Acl_Selector,
	open:      bool,
}

Acl_Channel_Kind :: enum u8 {
	None,
	Subscribe,
	Pattern,
	Publish,
}

Acl_Cmd_Meta :: struct {
	parent:  i16,
	sub_lo:  i16,
	sub_hi:  i16,
	channel: Acl_Channel_Kind,
}

Acl_Log_Entry :: struct {
	count:    i64,
	reason:   Acl_Result,
	ctx:      Acl_Context,
	object:   []u8,
	username: []u8,
	ctime:    i64,
	cinfo:    []u8,
	id:       i64,
	created:  i64,
}

acl_users: [dynamic]^Acl_User
acl_default: ^Acl_User
acl_auth_needed: bool
acl_denied: [Acl_Result]i64
acl_doomed: [dynamic]^Conn

@(private = "file")
acl_meta: [ACL_CMD_COUNT]Acl_Cmd_Meta
@(private = "file")
acl_errno: Acl_Errno
@(private = "file")
acl_log: [dynamic]^Acl_Log_Entry
@(private = "file")
acl_log_count: i64
@(private = "file")
acl_to_load: [dynamic][][]u8
@(private = "file")
acl_keys: [dynamic]Key_Ref
@(private = "file")
acl_buf: [dynamic]u8
@(private = "file")
acl_initialized: bool

@(private = "file")
acl_user_flag_names := [Acl_User_Flag]string {
	.Enabled       = "on",
	.Disabled      = "off",
	.Nopass        = "nopass",
	.Skip_Sanitize = "skip-sanitize-payload",
	.Sanitize      = "sanitize-payload",
}

@(private = "file")
acl_reason_names := [Acl_Result]string {
	.Ok      = "unknown",
	.Cmd     = "command",
	.Key     = "key",
	.Auth    = "auth",
	.Channel = "channel",
}

@(private = "file")
acl_context_names := [Acl_Context]string {
	.Toplevel = "toplevel",
	.Lua      = "lua",
	.Multi    = "multi",
	.Module   = "module",
}

@(private = "file")
acl_help_lines := [?]string {
	"ACL <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"CAT [<category>]",
	"    List all commands that belong to <category>, or all command categories",
	"    when no category is specified.",
	"DELUSER <username> [<username> ...]",
	"    Delete a list of users.",
	"DRYRUN <username> <command> [<arg> ...]",
	"    Returns whether the user can execute the given command without executing the command.",
	"GETUSER <username>",
	"    Get the user's details.",
	"GENPASS [<bits>]",
	"    Generate a secure 256-bit user password. The optional `bits` argument can",
	"    be used to specify a different size.",
	"LIST",
	"    Show users details in config file format.",
	"LOAD",
	"    Reload users from the ACL file.",
	"LOG [<count> | RESET]",
	"    Show the ACL log entries.",
	"SAVE",
	"    Save the current config to the ACL file.",
	"SETUSER <username> <attribute> [<attribute> ...]",
	"    Create or modify a user with the specified attributes.",
	"USERS",
	"    List all the registered usernames.",
	"WHOAMI",
	"    Return the current connection username.",
	"HELP",
	"    Print this help.",
}

@(private = "file")
acl_strerror :: proc(e: Acl_Errno) -> string {
	switch e {
	case .Noent:
		return "Unknown command or category name in ACL"
	case .Inval:
		return "Syntax error"
	case .Exist:
		return "Adding a pattern after the * pattern (or the 'allkeys' flag) is not valid and does not have any effect. Try 'resetkeys' to start with an empty list of patterns"
	case .Isdir:
		return "Adding a pattern after the * pattern (or the 'allchannels' flag) is not valid and does not have any effect. Try 'resetchannels' to start with an empty list of channels"
	case .Nodev:
		return "The password you are trying to remove from the user does not exist"
	case .Badmsg:
		return "The password hash must be exactly 64 characters and contain only lowercase hexadecimal characters"
	case .Already:
		return "Duplicate user found. A user can only be defined once in config files"
	case .Child:
		return "Allowing first-arg of a subcommand is not supported"
	case .None:
	}
	return "Wrong format"
}

@(private = "file")
acl_clone :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}

@(private = "file")
acl_has_spaces :: proc(s: []u8) -> bool {
	for b in s {
		if b == 0 || b == ' ' || (b >= '\t' && b <= '\r') {
			return true
		}
	}
	return false
}

@(private = "file")
acl_name_cmp :: proc(a: []u8, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return -1 if len(a) < len(b) else 1
}

@(private = "file")
acl_doc_index :: proc(name: string) -> int {
	lo, hi := 0, ACL_CMD_COUNT
	for lo < hi {
		mid := (lo + hi) / 2
		if cmd_docs[mid].name < name {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < ACL_CMD_COUNT && cmd_docs[lo].name == name {
		return lo
	}
	return -1
}

acl_command_id :: proc(name: string) -> i32 {
	acl_init()
	return i32(acl_doc_index(name))
}

@(private = "file")
acl_lookup_name :: proc(name: []u8) -> int {
	buf: [ACL_NAME_MAX]u8
	if len(name) == 0 || len(name) > len(buf) {
		return -1
	}
	for b, i in name {
		buf[i] = lower(b)
	}
	return acl_doc_index(string(buf[:len(name)]))
}

@(private = "file")
acl_lookup_sub :: proc(base: int, sub: []u8) -> int {
	buf: [ACL_NAME_MAX]u8
	name := cmd_docs[base].name
	if len(name) + 1 + len(sub) > len(buf) || len(sub) == 0 {
		return -1
	}
	n := copy(buf[:], name)
	buf[n] = '|'
	n += 1
	for b in sub {
		buf[n] = lower(b)
		n += 1
	}
	id := acl_doc_index(string(buf[:n]))
	if id < 0 || int(acl_meta[id].parent) != base {
		return -1
	}
	return id
}

@(private = "file")
acl_lookup_strict :: proc(name: []u8) -> int {
	bar := -1
	for b, i in name {
		if b == '|' {
			if bar >= 0 {
				return -1
			}
			bar = i
		}
	}
	if bar < 0 {
		return acl_lookup_name(name)
	}
	base := acl_lookup_name(name[:bar])
	if base < 0 || acl_meta[base].sub_lo < 0 {
		return -1
	}
	return acl_lookup_sub(base, name[bar + 1:])
}

@(private = "file")
acl_lookup_argv :: proc(argv: [][]u8) -> int {
	base := acl_lookup_name(argv[0])
	if base < 0 || acl_meta[base].parent >= 0 {
		return -1
	}
	if len(argv) == 1 || acl_meta[base].sub_lo < 0 {
		return base
	}
	return acl_lookup_sub(base, argv[1])
}

acl_init :: proc() {
	if acl_initialized {
		return
	}
	acl_initialized = true
	for i in 0 ..< ACL_CMD_COUNT {
		acl_meta[i] = {
			parent = -1,
			sub_lo = -1,
			sub_hi = -1,
		}
	}
	for i in 0 ..< ACL_CMD_COUNT {
		name := cmd_docs[i].name
		for j in 0 ..< len(name) {
			if name[j] != '|' {
				continue
			}
			p := acl_doc_index(name[:j])
			acl_meta[i].parent = i16(p)
			if p >= 0 {
				if acl_meta[p].sub_lo < 0 {
					acl_meta[p].sub_lo = i16(i)
				}
				acl_meta[p].sub_hi = i16(i + 1)
			}
			break
		}
	}
	kinds := [?]struct {
		name: string,
		kind: Acl_Channel_Kind,
	}{{"subscribe", .Subscribe}, {"ssubscribe", .Subscribe}, {"psubscribe", .Pattern}, {"publish", .Publish}, {"spublish", .Publish}}
	for k in kinds {
		if id := acl_doc_index(k.name); id >= 0 {
			acl_meta[id].channel = k.kind
		}
	}
	acl_default = acl_user_new(transmute([]u8)string(DEFAULT_USER))
	acl_set_user(acl_default, transmute([]u8)string("+@all"))
	acl_set_user(acl_default, transmute([]u8)string("~*"))
	acl_set_user(acl_default, transmute([]u8)string("&*"))
	acl_set_user(acl_default, transmute([]u8)string("on"))
	acl_set_user(acl_default, transmute([]u8)string("nopass"))
	acl_user_update_open(acl_default)
	append(&acl_users, acl_default)
	acl_auth_needed = false
}

@(private = "file")
acl_bit :: #force_inline proc "contextless" (s: ^Acl_Selector, id: int) -> bool {
	return s.allowed[id >> 6] & (u64(1) << uint(id & 63)) != 0
}

@(private = "file")
acl_set_bit :: proc(s: ^Acl_Selector, id: int, on: bool) {
	mask := u64(1) << uint(id & 63)
	if on {
		s.allowed[id >> 6] |= mask
	} else {
		s.allowed[id >> 6] &~= mask
		s.flags -= {.All_Commands}
	}
}

@(private = "file")
acl_firstargs_find :: proc(s: ^Acl_Selector, id: int) -> int {
	for fa, i in s.firstargs {
		if fa.id == id {
			return i
		}
	}
	return -1
}

@(private = "file")
acl_firstargs_reset_for :: proc(s: ^Acl_Selector, id: int) {
	i := acl_firstargs_find(s, id)
	if i < 0 {
		return
	}
	for a in s.firstargs[i].args {
		delete(a)
	}
	delete(s.firstargs[i].args)
	ordered_remove(&s.firstargs, i)
}

@(private = "file")
acl_firstargs_reset :: proc(s: ^Acl_Selector) {
	for fa in s.firstargs {
		for a in fa.args {
			delete(a)
		}
		delete(fa.args)
	}
	clear(&s.firstargs)
}

@(private = "file")
acl_firstargs_add :: proc(s: ^Acl_Selector, id: int, sub: []u8) {
	i := acl_firstargs_find(s, id)
	if i < 0 {
		append(&s.firstargs, Acl_First_Args{id = id})
		i = len(s.firstargs) - 1
	}
	fa := &s.firstargs[i]
	for a in fa.args {
		if eq_fold(a, sub) {
			return
		}
	}
	append(&fa.args, acl_clone(sub))
}

@(private = "file")
acl_clear_patterns :: proc(s: ^Acl_Selector) {
	for p in s.patterns {
		delete(p.pattern)
	}
	clear(&s.patterns)
}

@(private = "file")
acl_clear_channels :: proc(s: ^Acl_Selector) {
	for ch in s.channels {
		delete(ch)
	}
	clear(&s.channels)
}

@(private = "file")
acl_selector_new :: proc(flags: Acl_Selector_Flags) -> ^Acl_Selector {
	s := new(Acl_Selector)
	s.flags = flags
	if cfg.acl_pubsub_default != 0 {
		s.flags += {.All_Channels}
	}
	return s
}

@(private = "file")
acl_selector_free :: proc(s: ^Acl_Selector) {
	acl_clear_patterns(s)
	delete(s.patterns)
	acl_clear_channels(s)
	delete(s.channels)
	acl_firstargs_reset(s)
	delete(s.firstargs)
	delete(s.rules)
	free(s)
}

@(private = "file")
acl_selector_copy :: proc(src: ^Acl_Selector) -> ^Acl_Selector {
	dst := new(Acl_Selector)
	dst.flags = src.flags
	dst.allowed = src.allowed
	for p in src.patterns {
		append(&dst.patterns, Acl_Pattern{acl_clone(p.pattern), p.perms})
	}
	for ch in src.channels {
		append(&dst.channels, acl_clone(ch))
	}
	for fa in src.firstargs {
		for a in fa.args {
			acl_firstargs_add(dst, fa.id, a)
		}
	}
	append(&dst.rules, ..src.rules[:])
	return dst
}

@(private = "file")
acl_change_perm :: proc(s: ^Acl_Selector, id: int, allow: bool) {
	acl_set_bit(s, id, allow)
	acl_firstargs_reset_for(s, id)
	m := acl_meta[id]
	if m.sub_lo >= 0 {
		for j in int(m.sub_lo) ..< int(m.sub_hi) {
			acl_set_bit(s, j, allow)
		}
	}
}

@(private = "file")
acl_set_category_bits :: proc(s: ^Acl_Selector, cat: Acl_Cat, allow: bool) {
	for i in 0 ..< ACL_CMD_COUNT {
		m := acl_meta[i]
		if m.parent >= 0 {
			continue
		}
		if cat in cmd_docs[i].acl {
			acl_change_perm(s, i, allow)
		}
		if m.sub_lo >= 0 {
			for j in int(m.sub_lo) ..< int(m.sub_hi) {
				if cat in cmd_docs[j].acl {
					acl_change_perm(s, j, allow)
				}
			}
		}
	}
}

@(private = "file")
acl_rules_remove :: proc(s: ^Acl_Selector, rule: []u8) {
	i := 0
	for i < len(s.rules) {
		copy_pos := i
		i += 1
		end := i
		for end < len(s.rules) && s.rules[end] != ' ' {
			end += 1
		}
		if end >= len(s.rules) && copy_pos != 0 {
			copy_pos -= 1
		}
		copy_end := end
		if copy_end < len(s.rules) && s.rules[copy_end] == ' ' {
			copy_end += 1
		}
		existing := s.rules[i:end]
		m := min(len(existing), len(rule))
		if bytes_eq(existing[:m], rule[:m]) && (len(existing) == len(rule) || (len(existing) > len(rule) && existing[len(rule)] == '|')) {
			remove_range(&s.rules, copy_pos, copy_end)
			i = copy_pos
			continue
		}
		i = copy_end
	}
}

@(private = "file")
acl_rules_update :: proc(s: ^Acl_Selector, rule: []u8, allow: bool) {
	buf := make([]u8, len(rule), context.temp_allocator)
	for b, i in rule {
		buf[i] = lower(b)
	}
	acl_rules_remove(s, buf)
	if len(s.rules) > 0 {
		append(&s.rules, ' ')
	}
	append(&s.rules, '+' if allow else '-')
	append(&s.rules, ..buf)
}

@(private = "file")
acl_set_selector :: proc(s: ^Acl_Selector, op: []u8) -> bool {
	switch {
	case eq_nocase(op, "allkeys") || eq_nocase(op, "~*"):
		s.flags += {.All_Keys}
		acl_clear_patterns(s)
	case eq_nocase(op, "resetkeys"):
		s.flags -= {.All_Keys}
		acl_clear_patterns(s)
	case eq_nocase(op, "allchannels") || eq_nocase(op, "&*"):
		s.flags += {.All_Channels}
		acl_clear_channels(s)
	case eq_nocase(op, "resetchannels"):
		s.flags -= {.All_Channels}
		acl_clear_channels(s)
	case eq_nocase(op, "allcommands") || eq_nocase(op, "+@all"):
		for &w in s.allowed {
			w = max(u64)
		}
		s.flags += {.All_Commands}
		clear(&s.rules)
		acl_firstargs_reset(s)
	case eq_nocase(op, "nocommands") || eq_nocase(op, "-@all"):
		s.allowed = {}
		s.flags -= {.All_Commands}
		clear(&s.rules)
		acl_firstargs_reset(s)
	case len(op) > 0 && (op[0] == '~' || op[0] == '%'):
		return acl_add_key_pattern(s, op)
	case len(op) > 0 && op[0] == '&':
		if .All_Channels in s.flags {
			acl_errno = .Isdir
			return false
		}
		if acl_has_spaces(op[1:]) {
			acl_errno = .Inval
			return false
		}
		found := false
		for ch in s.channels {
			if bytes_eq(ch, op[1:]) {
				found = true
				break
			}
		}
		if !found {
			append(&s.channels, acl_clone(op[1:]))
		}
		s.flags -= {.All_Channels}
	case len(op) > 0 && op[0] == '+' && (len(op) < 2 || op[1] != '@'):
		return acl_allow_command(s, op[1:])
	case len(op) > 0 && op[0] == '-' && (len(op) < 2 || op[1] != '@'):
		id := acl_lookup_strict(op[1:])
		if id < 0 {
			acl_errno = .Noent
			return false
		}
		acl_change_perm(s, id, false)
		acl_rules_update(s, transmute([]u8)cmd_docs[id].name, false)
	case len(op) >= 2 && (op[0] == '+' || op[0] == '-') && op[1] == '@':
		cat, ok := acl_cat_by_name(op[2:])
		if !ok {
			acl_errno = .Noent
			return false
		}
		allow := op[0] == '+'
		acl_rules_update(s, op[1:], allow)
		acl_set_category_bits(s, cat, allow)
	case:
		acl_errno = .Inval
		return false
	}
	return true
}

@(private = "file")
acl_add_key_pattern :: proc(s: ^Acl_Selector, op: []u8) -> bool {
	if .All_Keys in s.flags {
		acl_errno = .Exist
		return false
	}
	perms: Acl_Perms
	offset := 1
	if op[0] == '%' {
		perm_ok := true
		for ; offset < len(op); offset += 1 {
			ch := op[offset]
			if (ch == 'R' || ch == 'r') && .Read not_in perms {
				perms += {.Read}
			} else if (ch == 'W' || ch == 'w') && .Write not_in perms {
				perms += {.Write}
			} else if ch == '~' {
				offset += 1
				break
			} else {
				perm_ok = false
				break
			}
		}
		if perms == {} || !perm_ok {
			acl_errno = .Inval
			return false
		}
	} else {
		perms = {.Read, .Write}
	}
	pat := op[offset:]
	if acl_has_spaces(pat) {
		acl_errno = .Inval
		return false
	}
	found := false
	for &p in s.patterns {
		if bytes_eq(p.pattern, pat) {
			p.perms += perms
			found = true
			break
		}
	}
	if !found {
		append(&s.patterns, Acl_Pattern{acl_clone(pat), perms})
	}
	s.flags -= {.All_Keys}
	return true
}

@(private = "file")
acl_allow_command :: proc(s: ^Acl_Selector, name: []u8) -> bool {
	bar := -1
	for b, i in name {
		if b == '|' {
			bar = i
		}
	}
	if bar < 0 {
		id := acl_lookup_strict(name)
		if id < 0 {
			acl_errno = .Noent
			return false
		}
		acl_change_perm(s, id, true)
		acl_rules_update(s, transmute([]u8)cmd_docs[id].name, true)
		return true
	}
	sub := name[bar + 1:]
	id := acl_lookup_strict(name[:bar])
	if id < 0 {
		acl_errno = .Noent
		return false
	}
	if acl_meta[id].parent >= 0 {
		acl_errno = .Child
		return false
	}
	if len(sub) == 0 {
		acl_errno = .Inval
		return false
	}
	if acl_meta[id].sub_lo >= 0 {
		sid := acl_lookup_strict(name)
		if sid < 0 {
			acl_errno = .Noent
			return false
		}
		acl_change_perm(s, sid, true)
	} else {
		plog(LOG_WARNING, "Deprecation warning: Allowing a first arg of an otherwise blocked command is a misuse of ACL and may get disabled in the future (offender: +", string(name), ")")
		acl_firstargs_add(s, id, sub)
	}
	acl_rules_update(s, name, true)
	return true
}

@(private = "file")
acl_selector_from_opset :: proc(op: []u8) -> ^Acl_Selector {
	s := acl_selector_new({})
	ops := make([dynamic][]u8, context.temp_allocator)
	if !split_args(op[1:len(op) - 1], &ops, context.temp_allocator) {
		clear(&ops)
	}
	for a in ops {
		if !acl_set_selector(s, a) {
			acl_selector_free(s)
			return nil
		}
	}
	return s
}

@(private = "file")
acl_user_new :: proc(name: []u8) -> ^Acl_User {
	u := new(Acl_User)
	u.name = acl_clone(name)
	u.flags = {.Disabled, .Sanitize}
	append(&u.selectors, acl_selector_new({.Root}))
	return u
}

@(private = "file")
acl_user_clear :: proc(u: ^Acl_User) {
	clear(&u.passwords)
	for s in u.selectors {
		acl_selector_free(s)
	}
	clear(&u.selectors)
}

@(private = "file")
acl_user_free :: proc(u: ^Acl_User) {
	acl_user_clear(u)
	delete(u.passwords)
	delete(u.selectors)
	delete(u.name)
	free(u)
}

@(private = "file")
acl_user_copy_into :: proc(dst: ^Acl_User, src: ^Acl_User) {
	acl_user_clear(dst)
	dst.flags = src.flags
	append(&dst.passwords, ..src.passwords[:])
	for s in src.selectors {
		append(&dst.selectors, acl_selector_copy(s))
	}
	acl_user_update_open(dst)
}

@(private = "file")
acl_user_update_open :: proc(u: ^Acl_User) {
	root := u.selectors[0]
	u.open = root.flags >= {.All_Keys, .All_Commands, .All_Channels}
}

acl_hash_password :: proc(pw: []u8) -> (out: [ACL_HASH_LEN]u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, pw)
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	hexd := "0123456789abcdef"
	for x, i in digest {
		out[i * 2] = hexd[x >> 4]
		out[i * 2 + 1] = hexd[x & 15]
	}
	return
}

@(private = "file")
acl_hash_from_hex :: proc(h: []u8) -> (out: [ACL_HASH_LEN]u8, ok: bool) {
	if len(h) != ACL_HASH_LEN {
		return
	}
	for ch, i in h {
		if (ch < 'a' || ch > 'f') && (ch < '0' || ch > '9') {
			return
		}
		out[i] = ch
	}
	return out, true
}

@(private = "file")
acl_password_index :: proc(u: ^Acl_User, h: [ACL_HASH_LEN]u8) -> int {
	for p, i in u.passwords {
		if p == h {
			return i
		}
	}
	return -1
}

@(private = "file")
acl_set_user :: proc(u: ^Acl_User, op: []u8) -> bool {
	if len(op) == 0 {
		return true
	}
	switch {
	case eq_nocase(op, "on"):
		u.flags += {.Enabled}
		u.flags -= {.Disabled}
	case eq_nocase(op, "off"):
		u.flags += {.Disabled}
		u.flags -= {.Enabled}
	case eq_nocase(op, "skip-sanitize-payload"):
		u.flags += {.Skip_Sanitize}
		u.flags -= {.Sanitize}
	case eq_nocase(op, "sanitize-payload"):
		u.flags += {.Sanitize}
		u.flags -= {.Skip_Sanitize}
	case eq_nocase(op, "nopass"):
		u.flags += {.Nopass}
		clear(&u.passwords)
	case eq_nocase(op, "resetpass"):
		u.flags -= {.Nopass}
		clear(&u.passwords)
	case op[0] == '>' || op[0] == '#':
		h: [ACL_HASH_LEN]u8
		if op[0] == '>' {
			h = acl_hash_password(op[1:])
		} else {
			ok: bool
			h, ok = acl_hash_from_hex(op[1:])
			if !ok {
				acl_errno = .Badmsg
				return false
			}
		}
		if acl_password_index(u, h) < 0 {
			append(&u.passwords, h)
		}
		u.flags -= {.Nopass}
	case op[0] == '<' || op[0] == '!':
		h: [ACL_HASH_LEN]u8
		if op[0] == '<' {
			h = acl_hash_password(op[1:])
		} else {
			ok: bool
			h, ok = acl_hash_from_hex(op[1:])
			if !ok {
				acl_errno = .Badmsg
				return false
			}
		}
		i := acl_password_index(u, h)
		if i < 0 {
			acl_errno = .Nodev
			return false
		}
		ordered_remove(&u.passwords, i)
	case op[0] == '(' && op[len(op) - 1] == ')':
		s := acl_selector_from_opset(op)
		if s == nil {
			return false
		}
		append(&u.selectors, s)
	case eq_nocase(op, "clearselectors"):
		for i in 1 ..< len(u.selectors) {
			acl_selector_free(u.selectors[i])
		}
		resize(&u.selectors, 1)
	case eq_nocase(op, "reset"):
		acl_set_user(u, transmute([]u8)string("resetpass"))
		acl_set_user(u, transmute([]u8)string("resetkeys"))
		acl_set_user(u, transmute([]u8)string("resetchannels"))
		if cfg.acl_pubsub_default != 0 {
			acl_set_user(u, transmute([]u8)string("allchannels"))
		}
		acl_set_user(u, transmute([]u8)string("off"))
		acl_set_user(u, transmute([]u8)string("sanitize-payload"))
		acl_set_user(u, transmute([]u8)string("clearselectors"))
		acl_set_user(u, transmute([]u8)string("-@all"))
	case:
		if !acl_set_selector(u.selectors[0], op) {
			return false
		}
	}
	return true
}

acl_user_find :: proc(name: []u8) -> ^Acl_User {
	lo, hi := 0, len(acl_users)
	for lo < hi {
		mid := (lo + hi) / 2
		if acl_name_cmp(acl_users[mid].name, name) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(acl_users) && acl_name_cmp(acl_users[lo].name, name) == 0 {
		return acl_users[lo]
	}
	return nil
}

@(private = "file")
acl_users_insert :: proc(users: ^[dynamic]^Acl_User, u: ^Acl_User) -> bool {
	lo, hi := 0, len(users)
	for lo < hi {
		mid := (lo + hi) / 2
		if acl_name_cmp(users[mid].name, u.name) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(users) && acl_name_cmp(users[lo].name, u.name) == 0 {
		return false
	}
	inject_at(users, lo, u)
	return true
}

@(private = "file")
acl_merge_args :: proc(argv: [][]u8, out: ^[dynamic][]u8) -> (ok: bool, invalid: int) {
	clear(out)
	open := -1
	cur: [dynamic]u8
	for op, j in argv {
		if open == -1 && len(op) > 0 && op[0] == '(' && op[len(op) - 1] != ')' {
			cur = make([dynamic]u8, context.temp_allocator)
			append(&cur, ..op)
			open = j
			continue
		}
		if open != -1 {
			append(&cur, ' ')
			append(&cur, ..op)
			if len(op) > 0 && op[len(op) - 1] == ')' {
				open = -1
				append(out, cur[:])
			}
			continue
		}
		append(out, op)
	}
	if open != -1 {
		return false, open
	}
	return true, 0
}

@(private = "file")
acl_describe_selector :: proc(b: ^[dynamic]u8, s: ^Acl_Selector) {
	if .All_Keys in s.flags {
		sb_str(b, "~* ")
	} else {
		for p in s.patterns {
			acl_pattern_string(b, p)
			sb_byte(b, ' ')
		}
	}
	if .All_Channels in s.flags {
		sb_str(b, "&* ")
	} else {
		sb_str(b, "resetchannels ")
		for ch in s.channels {
			sb_byte(b, '&')
			sb_bytes(b, ch)
			sb_byte(b, ' ')
		}
	}
	acl_describe_commands(b, s)
}

@(private = "file")
acl_describe_commands :: proc(b: ^[dynamic]u8, s: ^Acl_Selector) {
	sb_str(b, "+@all" if acl_bit(s, ACL_FUTURE_BIT) else "-@all")
	if len(s.rules) > 0 {
		sb_byte(b, ' ')
		sb_bytes(b, s.rules[:])
	}
}

@(private = "file")
acl_pattern_string :: proc(b: ^[dynamic]u8, p: Acl_Pattern) {
	switch p.perms {
	case {.Read}:
		sb_str(b, "%R~")
	case {.Write}:
		sb_str(b, "%W~")
	case:
		sb_byte(b, '~')
	}
	sb_bytes(b, p.pattern)
}

acl_describe_user :: proc(b: ^[dynamic]u8, u: ^Acl_User) {
	for f in Acl_User_Flag {
		if f in u.flags {
			sb_str(b, acl_user_flag_names[f])
			sb_byte(b, ' ')
		}
	}
	for p in u.passwords {
		sb_byte(b, '#')
		pw := p
		sb_bytes(b, pw[:])
		sb_byte(b, ' ')
	}
	for s, i in u.selectors {
		if i == 0 {
			acl_describe_selector(b, s)
		} else {
			sb_str(b, " (")
			acl_describe_selector(b, s)
			sb_byte(b, ')')
		}
	}
}

@(private = "file")
acl_check_key :: proc(s: ^Acl_Selector, key: []u8, flags: Key_Flags) -> bool {
	if .All_Keys in s.flags {
		return true
	}
	need: Acl_Perms
	if .Access in flags {
		need += {.Read}
	}
	if flags & {.Insert, .Delete, .Update} != {} {
		need += {.Write}
	}
	for p in s.patterns {
		if p.perms & need != need {
			continue
		}
		if glob_match(p.pattern, key, false) {
			return true
		}
	}
	return false
}

@(private = "file")
acl_unrestricted_selector :: proc(s: ^Acl_Selector, flags: Key_Flags) -> bool {
	if .All_Keys in s.flags {
		return true
	}
	need: Acl_Perms
	if .Access in flags {
		need += {.Read}
	}
	if flags & {.Insert, .Delete, .Update} != {} {
		need += {.Write}
	}
	for p in s.patterns {
		if p.perms & need != need {
			continue
		}
		if string(p.pattern) == "*" {
			return true
		}
	}
	return false
}

@(private = "file")
acl_channel_allowed :: proc(list: [][]u8, channel: []u8, is_pattern: bool) -> bool {
	for p in list {
		if is_pattern {
			if bytes_eq(p, channel) {
				return true
			}
		} else if glob_match(p, channel, false) {
			return true
		}
	}
	return false
}

@(private = "file")
acl_selector_check :: proc(s: ^Acl_Selector, id: int, argv: [][]u8, keys_ready: ^bool) -> (Acl_Result, int) {
	spec := &cmd_specs[id]
	if .All_Commands not_in s.flags && .No_Auth not_in spec.flags && !acl_bit(s, id) {
		fi := acl_firstargs_find(s, id)
		if len(argv) < 2 || fi < 0 {
			return .Cmd, 0
		}
		idx := 2 if acl_meta[id].parent >= 0 else 1
		if idx >= len(argv) {
			return .Cmd, 0
		}
		matched := false
		for a in s.firstargs[fi].args {
			if eq_fold(argv[idx], a) {
				matched = true
				break
			}
		}
		if !matched {
			return .Cmd, 0
		}
	}
	if .All_Keys not_in s.flags && spec_has_keys(spec) {
		if !keys_ready^ {
			find_keys(spec, argv, &acl_keys)
			keys_ready^ = true
		}
		for k in acl_keys {
			if !acl_check_key(s, argv[k.pos], k.flags) {
				return .Key, k.pos
			}
		}
	}
	kind := acl_meta[id].channel
	if kind != .None && .All_Channels not_in s.flags {
		stop := len(argv) if kind != .Publish else min(2, len(argv))
		for i in 1 ..< stop {
			if !acl_channel_allowed(s.channels[:], argv[i], kind == .Pattern) {
				return .Channel, i
			}
		}
	}
	return .Ok, 0
}

acl_check_user :: proc(u: ^Acl_User, id: int, argv: [][]u8) -> (Acl_Result, int) {
	if u == nil {
		return .Ok, 0
	}
	relevant := Acl_Result.Cmd
	last := 0
	keys_ready := false
	for s in u.selectors {
		res, idx := acl_selector_check(s, id, argv, &keys_ready)
		if res == .Ok {
			return .Ok, 0
		}
		if res > relevant || (res == relevant && idx > last) {
			relevant = res
			last = idx
		}
	}
	return relevant, last
}

acl_unrestricted_access :: proc(c: ^Conn, argv: [][]u8, flags: Key_Flags) -> bool {
	u := c.user
	if u == nil || u.open {
		return true
	}
	cmd := lookup_command(argv[0])
	if cmd == nil {
		return false
	}
	id := acl_doc_index(cmd.name)
	if id < 0 {
		return false
	}
	keys_ready := false
	for s in u.selectors {
		res, _ := acl_selector_check(s, id, argv, &keys_ready)
		if res == .Ok && acl_unrestricted_selector(s, flags) {
			return true
		}
	}
	return false
}

acl_skips_sanitize :: proc(c: ^Conn) -> bool {
	return c.user != nil && .Skip_Sanitize in c.user.flags
}

acl_user_name :: proc(c: ^Conn) -> string {
	if c.user == nil {
		return "(superuser)"
	}
	return string(c.user.name)
}

acl_conn_init :: proc(c: ^Conn) {
	c.user = acl_default
	c.authed = acl_default_free()
	if c.authed {
		c.ever_authed = true
	}
	acl_conn_refresh(c)
}

@(private = "file")
acl_default_free :: proc() -> bool {
	return .Nopass in acl_default.flags && .Disabled not_in acl_default.flags
}

acl_conn_refresh :: proc(c: ^Conn) {
	need_auth := acl_auth_needed && !c.authed
	c.acl_gate = need_auth || (c.user != nil && !c.user.open)
	c.mbulk_max = 0 if need_auth else MBULK_MAX
}

acl_refresh_all :: proc() {
	acl_auth_needed = !acl_default_free()
	for c in srv.conns {
		if c != nil {
			acl_conn_refresh(c)
		}
	}
}

acl_auth_required :: #force_inline proc(c: ^Conn) -> bool {
	return acl_auth_needed && !c.authed
}

@(private = "file")
acl_set_conn_user :: proc(c: ^Conn, u: ^Acl_User, authed: bool) {
	c.user = u
	c.authed = authed
	if authed {
		c.ever_authed = true
	}
	acl_conn_refresh(c)
}

acl_conn_reset :: proc(c: ^Conn) {
	acl_set_conn_user(c, acl_default, acl_default_free())
}

@(private = "file")
acl_credentials_ok :: proc(username: []u8, password: []u8) -> ^Acl_User {
	u := acl_user_find(username)
	if u == nil || .Disabled in u.flags {
		return nil
	}
	if .Nopass in u.flags {
		return u
	}
	h := acl_hash_password(password)
	for p in u.passwords {
		diff: u8 = 0
		for i in 0 ..< ACL_HASH_LEN {
			diff |= p[i] ~ h[i]
		}
		if diff == 0 {
			return u
		}
	}
	return nil
}

acl_authenticate :: proc(c: ^Conn, argv: [][]u8, username: []u8, password: []u8) -> bool {
	u := acl_credentials_ok(username, password)
	if u != nil {
		acl_set_conn_user(c, u, true)
		return true
	}
	acl_log_add(c, .Auth, .Multi if .Multi in c.txf else .Toplevel, argv, 0, username, argv[0])
	return false
}

@(private = "file")
acl_free_entry :: proc(e: ^Acl_Log_Entry) {
	delete(e.object)
	delete(e.username)
	delete(e.cinfo)
	free(e)
}

@(private = "file")
acl_log_trim :: proc() {
	n := len(acl_log) - int(cfg.acllog_max_len)
	if n <= 0 {
		return
	}
	for i in 0 ..< n {
		acl_free_entry(acl_log[i])
	}
	remove_range(&acl_log, 0, n)
}

acl_log_add :: proc(c: ^Conn, reason: Acl_Result, ctx: Acl_Context, argv: [][]u8, pos: int, username: []u8, object: []u8) {
	acl_denied[reason] += 1
	if cfg.acllog_max_len == 0 {
		acl_log_trim()
		return
	}
	obj := object
	if obj == nil {
		obj = argv[pos]
	}
	uname := username
	if uname == nil {
		uname = transmute([]u8)acl_user_name(c)
	}
	now := srv.now_ms
	info := make([dynamic]u8, context.temp_allocator)
	client_info_line(&info, c, c, argv)
	if len(info) > 0 && info[len(info) - 1] == '\n' {
		resize(&info, len(info) - 1)
	}
	scanned := 0
	for i := len(acl_log) - 1; i >= 0 && scanned < ACL_LOG_SCAN; i -= 1 {
		scanned += 1
		e := acl_log[i]
		delta := e.ctime - now
		if delta < 0 {
			delta = -delta
		}
		if e.reason != reason || e.ctx != ctx || delta > ACL_LOG_GROUP_MS || !bytes_eq(e.object, obj) || !bytes_eq(e.username, uname) {
			continue
		}
		ordered_remove(&acl_log, i)
		append(&acl_log, e)
		delete(e.cinfo)
		e.cinfo = acl_clone(info[:])
		e.ctime = now
		e.count += 1
		return
	}
	e := new(Acl_Log_Entry)
	e.count = 1
	e.reason = reason
	e.ctx = ctx
	e.object = acl_clone(obj)
	e.username = acl_clone(uname)
	e.ctime = now
	e.created = now
	e.cinfo = acl_clone(info[:])
	e.id = acl_log_count
	acl_log_count += 1
	append(&acl_log, e)
	acl_log_trim()
}

@(cold)
acl_reject :: #force_no_inline proc(c: ^Conn, cmd: ^Command, st: ^Cmd_Hot, argv: [][]u8) -> bool {
	if cmd.handler == cmd_debug && !debug_allowed(c) {
		return false
	}
	target := &st.stats
	if len(st.subs) > 0 && len(argv) >= 2 {
		target = stat_target(&st.stats, argv)
		if target == nil || !arity_ok(int(target.arity), len(argv)) {
			return false
		}
	}
	id := int(target.acl_id)
	if id < 0 {
		return false
	}
	spec := &cmd_specs[id]
	c.last_cmd = target.name
	if acl_auth_required(c) && .No_Auth not_in spec.flags {
		stat_cur = nil
		if cmd.handler == cmd_exec {
			tx_exec_abort(c, ERR_NOAUTH)
		} else {
			reply_error(c, ERR_NOAUTH)
		}
		acl_rejected(c, st, argv)
		return true
	}
	if .Multi in c.txf && .No_Multi in spec.flags {
		return false
	}
	res, pos := acl_check_user(c.user, id, argv)
	if res == .Ok {
		return false
	}
	acl_log_add(c, res, .Multi if .Multi in c.txf else .Toplevel, argv, pos, nil, transmute([]u8)target.name if res == .Cmd else nil)
	stat_cur = nil
	clear(&acl_buf)
	sb_str(&acl_buf, "NOPERM ")
	acl_error_message(&acl_buf, res, c.user, target.name, nil)
	if cmd.handler == cmd_exec {
		tx_exec_abort(c, string(acl_buf[:]))
	} else {
		reply_error_bytes(c, acl_buf[:])
	}
	acl_rejected(c, st, argv)
	return true
}

@(private = "file")
acl_rejected :: proc(c: ^Conn, st: ^Cmd_Hot, argv: [][]u8) {
	tx_flag(c)
	stat_reject(st, argv)
	if block_in_reexecution() {
		stats_conn_closed(c)
	}
}

@(private = "file")
acl_error_message :: proc(b: ^[dynamic]u8, res: Acl_Result, u: ^Acl_User, fullname: string, value: []u8) {
	#partial switch res {
	case .Cmd:
		sb_str(b, "User ")
		sb_bytes(b, u.name)
		sb_str(b, " has no permissions to run the '")
		sb_str(b, fullname)
		sb_str(b, "' command")
	case .Key:
		if value == nil {
			sb_str(b, "No permissions to access a key")
		} else {
			sb_str(b, "User ")
			sb_bytes(b, u.name)
			sb_str(b, " has no permissions to access the '")
			sb_bytes(b, value)
			sb_str(b, "' key")
		}
	case .Channel:
		if value == nil {
			sb_str(b, "No permissions to access a channel")
		} else {
			sb_str(b, "User ")
			sb_bytes(b, u.name)
			sb_str(b, " has no permissions to access the '")
			sb_bytes(b, value)
			sb_str(b, "' channel")
		}
	}
}

@(cold)
acl_exec_rejects :: #force_no_inline proc(c: ^Conn, cmd: ^Command, argv: [][]u8) -> bool {
	parent := stat_of(cmd)
	if parent == nil {
		return false
	}
	target := stat_target(&parent.stats, argv)
	if target == nil || target.acl_id < 0 {
		return false
	}
	res, pos := acl_check_user(c.user, int(target.acl_id), argv)
	if res == .Ok {
		return false
	}
	acl_log_add(c, res, .Multi, argv, pos, nil, transmute([]u8)target.name if res == .Cmd else nil)
	reason: string
	#partial switch res {
	case .Cmd:
		reason = "no permission to execute the command or subcommand"
	case .Key:
		reason = "no permission to touch the specified keys"
	case .Channel:
		reason = "no permission to access one of the channels used as arguments"
	case:
		reason = "no permission"
	}
	stat_cur = nil
	reply_error_parts(c, "NOPERM ACLs rules changed between the moment the transaction was accumulated and the EXEC call. This command is no longer allowed for the following reason: ", reason)
	return true
}

@(private = "file")
acl_kill_list :: proc(c: ^Conn, upcoming: [][]u8) -> bool {
	if .Subscribed not_in c.ps || c.pubsub == nil {
		return false
	}
	for e in c.pubsub.lists[.Pattern] {
		if !acl_channel_allowed(upcoming, e.name, true) {
			return true
		}
	}
	for e in c.pubsub.lists[.Channel] {
		if !acl_channel_allowed(upcoming, e.name, false) {
			return true
		}
	}
	for e in c.pubsub.lists[.Shard] {
		if !acl_channel_allowed(upcoming, e.name, false) {
			return true
		}
	}
	return false
}

@(private = "file")
acl_upcoming_channels :: proc(next: ^Acl_User, current: ^Acl_User, out: ^[dynamic][]u8) -> bool {
	clear(out)
	for s in next.selectors {
		if .All_Channels in s.flags {
			return false
		}
	}
	for s in next.selectors {
		append(out, ..s.channels[:])
	}
	for s in current.selectors {
		if .All_Channels in s.flags {
			return true
		}
		for ch in s.channels {
			found := false
			for x in out {
				if bytes_eq(x, ch) {
					found = true
					break
				}
			}
			if !found {
				return true
			}
		}
	}
	return false
}

@(private = "file")
acl_close_later :: proc(c: ^Conn, self: ^Conn) {
	c.close_after = true
	if c == self {
		return
	}
	for d in acl_doomed {
		if d == c {
			return
		}
	}
	append(&acl_doomed, c)
}

@(private = "file")
acl_close_conn :: proc(c: ^Conn, self: ^Conn) {
	acl_set_conn_user(c, acl_default, false)
	acl_close_later(c, self)
}

acl_close_doomed :: proc() {
	for len(acl_doomed) > 0 {
		conn_close(pop(&acl_doomed))
	}
}

acl_is_doomed :: proc(c: ^Conn) -> bool {
	for d in acl_doomed {
		if d == c {
			return true
		}
	}
	return false
}

acl_forget :: proc(c: ^Conn) {
	for d, i in acl_doomed {
		if d == c {
			unordered_remove(&acl_doomed, i)
			return
		}
	}
}

@(private = "file")
acl_kill_pubsub :: proc(self: ^Conn, next: ^Acl_User, current: ^Acl_User) {
	if len(ps_conns) == 0 {
		return
	}
	upcoming := make([dynamic][]u8, context.temp_allocator)
	if !acl_upcoming_channels(next, current, &upcoming) {
		return
	}
	for i in 0 ..< len(srv.conns) {
		c := srv.conns[i]
		if c == nil || c.user != current {
			continue
		}
		if acl_kill_list(c, upcoming[:]) {
			acl_close_conn(c, self)
		}
	}
}

@(private = "file")
acl_string_set_user :: proc(self: ^Conn, u: ^Acl_User, username: []u8, ops: [][]u8) -> string {
	merged := make([dynamic][]u8, context.temp_allocator)
	ok, invalid := acl_merge_args(ops, &merged)
	if !ok {
		return concat_temp(concat_temp("ERR Unmatched parenthesis in acl selector starting at '", string(ops[invalid])), "'.")
	}
	temp := acl_user_new(username)
	defer acl_user_free(temp)
	if u != nil {
		acl_user_copy_into(temp, u)
	}
	for op in merged {
		if !acl_set_user(temp, op) {
			b := make([dynamic]u8, context.temp_allocator)
			sb_str(&b, "ERR Error in ACL SETUSER modifier '")
			sb_bytes(&b, op)
			sb_str(&b, "': ")
			sb_str(&b, acl_strerror(acl_errno))
			return string(b[:])
		}
	}
	target := u
	if target != nil {
		acl_kill_pubsub(self, temp, target)
	} else {
		target = acl_user_new(username)
		acl_users_insert(&acl_users, target)
	}
	acl_user_copy_into(target, temp)
	return ""
}

acl_update_default_password :: proc(password: string) {
	acl_init()
	acl_set_user(acl_default, transmute([]u8)string("resetpass"))
	if password != "" {
		op := make([]u8, len(password) + 1, context.temp_allocator)
		op[0] = '>'
		copy(op[1:], password)
		acl_set_user(acl_default, op)
	} else {
		acl_set_user(acl_default, transmute([]u8)string("nopass"))
	}
	acl_user_update_open(acl_default)
	acl_refresh_all()
}

config_apply_requirepass :: proc() -> string {
	acl_update_default_password(cfg.requirepass)
	return ""
}

@(private = "file")
acl_split_spaces :: proc(line: []u8, out: ^[dynamic][]u8) {
	clear(out)
	start := 0
	for i in 0 ..= len(line) {
		if i == len(line) || line[i] == ' ' {
			append(out, line[start:i])
			start = i + 1
		}
	}
}

@(private = "file")
acl_trim :: proc(s: []u8, set: string) -> []u8 {
	in_set :: proc(b: u8, set: string) -> bool {
		for i in 0 ..< len(set) {
			if set[i] == b {
				return true
			}
		}
		return false
	}
	lo, hi := 0, len(s)
	for lo < hi && in_set(s[lo], set) {
		lo += 1
	}
	for hi > lo && in_set(s[hi - 1], set) {
		hi -= 1
	}
	return s[lo:hi]
}

@(private = "file")
acl_load_file :: proc(self: ^Conn) -> string {
	path := cfg.aclfile
	data, rerr := read_whole_file(path)
	if rerr != .NONE {
		return concat_temp(concat_temp(concat_temp("Error loading ACLs, opening file '", path), "': "), errno_text(rerr))
	}
	errors := make([dynamic]u8, context.temp_allocator)
	users := make([dynamic]^Acl_User)
	argv := make([dynamic][]u8, context.temp_allocator)
	merged := make([dynamic][]u8, context.temp_allocator)
	tmp: [24]u8
	linenum := 0
	start := 0
	for at in 0 ..= len(data) {
		if at < len(data) && data[at] != '\n' {
			continue
		}
		raw := data[start:at]
		start = at + 1
		linenum += 1
		line := acl_trim(raw, " \t\r\n")
		if len(line) == 0 {
			continue
		}
		num := string(tmp[:format_i64(&tmp[0], i64(linenum))])
		acl_split_spaces(line, &argv)
		if string(argv[0]) != "user" || len(argv) < 2 {
			sb_str(&errors, path)
			sb_str(&errors, ":")
			sb_str(&errors, num)
			sb_str(&errors, " should start with user keyword followed by the username. ")
			continue
		}
		if acl_has_spaces(argv[1]) {
			sb_str(&errors, "'")
			sb_str(&errors, path)
			sb_str(&errors, ":")
			sb_str(&errors, num)
			sb_str(&errors, ": username '")
			sb_bytes(&errors, argv[1])
			sb_str(&errors, "' contains invalid characters. ")
			continue
		}
		u := acl_user_new(argv[1])
		if !acl_users_insert(&users, u) {
			acl_user_free(u)
			sb_str(&errors, "WARNING: Duplicate user '")
			sb_bytes(&errors, argv[1])
			sb_str(&errors, "' found on line ")
			sb_str(&errors, num)
			sb_str(&errors, ". ")
			continue
		}
		if ok, _ := acl_merge_args(argv[2:], &merged); !ok {
			sb_str(&errors, path)
			sb_str(&errors, ":")
			sb_str(&errors, num)
			sb_str(&errors, ": Unmatched parenthesis in selector definition.")
			continue
		}
		syntax_error := false
		for op in merged {
			trimmed := acl_trim(op, "\t\r\n")
			if acl_set_user(u, trimmed) {
				continue
			}
			if acl_errno == .Noent {
				sb_str(&errors, path)
				sb_str(&errors, ":")
				sb_str(&errors, num)
				sb_str(&errors, ": Error in applying operation '")
				sb_bytes(&errors, trimmed)
				sb_str(&errors, "': ")
				sb_str(&errors, acl_strerror(acl_errno))
				sb_str(&errors, ". ")
			} else if !syntax_error {
				sb_str(&errors, path)
				sb_str(&errors, ":")
				sb_str(&errors, num)
				sb_str(&errors, ": ")
				sb_str(&errors, acl_strerror(acl_errno))
				sb_str(&errors, ". ")
				syntax_error = true
			}
		}
		acl_user_update_open(u)
	}
	if len(errors) > 0 {
		for u in users {
			acl_user_free(u)
		}
		delete(users)
		sb_str(&errors, "WARNING: ACL errors detected, no change to the previously active ACL rules was performed")
		return string(errors[:])
	}
	acl_install_users(self, &users)
	return ""
}

@(private = "file")
acl_install_users :: proc(self: ^Conn, users: ^[dynamic]^Acl_User) {
	nd := acl_user_find_in(users[:], transmute([]u8)string(DEFAULT_USER))
	if nd == nil {
		nd = acl_user_new(transmute([]u8)string(DEFAULT_USER))
		acl_set_user(nd, transmute([]u8)string("+@all"))
		acl_set_user(nd, transmute([]u8)string("~*"))
		acl_set_user(nd, transmute([]u8)string("&*"))
		acl_set_user(nd, transmute([]u8)string("on"))
		acl_set_user(nd, transmute([]u8)string("nopass"))
		acl_users_insert(users, nd)
	}
	acl_user_copy_into(acl_default, nd)
	for &x in users^ {
		if x == nd {
			x = acl_default
		}
	}
	acl_user_free(nd)
	old := acl_users
	acl_users = users^
	upcoming := make([dynamic][]u8, context.temp_allocator)
	for i in 0 ..< len(srv.conns) {
		c := srv.conns[i]
		if c == nil || c.user == nil {
			continue
		}
		current := c.user
		nu := acl_user_find(current.name)
		kill := nu == nil
		if !kill && len(ps_conns) > 0 && acl_upcoming_channels(nu, current, &upcoming) {
			kill = acl_kill_list(c, upcoming[:])
		}
		if kill {
			acl_close_conn(c, self)
			continue
		}
		c.user = nu
	}
	for u in old {
		if u != acl_default {
			acl_user_free(u)
		}
	}
	delete(old)
	acl_refresh_all()
}

@(private = "file")
acl_user_find_in :: proc(users: []^Acl_User, name: []u8) -> ^Acl_User {
	for u in users {
		if bytes_eq(u.name, name) {
			return u
		}
	}
	return nil
}

@(private = "file")
acl_save_file :: proc() -> bool {
	content := make([dynamic]u8, context.temp_allocator)
	for u in acl_users {
		sb_str(&content, "user ")
		sb_bytes(&content, u.name)
		sb_byte(&content, ' ')
		acl_describe_user(&content, u)
		sb_byte(&content, '\n')
	}
	path := cfg.aclfile
	tmp := make([dynamic]u8, context.temp_allocator)
	sb_str(&tmp, path)
	sb_str(&tmp, ".tmp-")
	sb_int(&tmp, srv.pid)
	sb_byte(&tmp, '-')
	sb_int(&tmp, srv.now_ms)
	tbuf: [4096]u8
	pbuf: [4096]u8
	tpath := persist_cstr(string(tmp[:]), tbuf[:])
	fd, err := linux.open(tpath, {.WRONLY, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if err != .NONE {
		plog(LOG_WARNING, "Opening temp ACL file for ACL SAVE: ", errno_text(err))
		return false
	}
	off := 0
	for off < len(content) {
		n, werr := linux.write(fd, content[off:])
		if werr == .EINTR {
			continue
		}
		if werr != .NONE || n <= 0 {
			plog(LOG_WARNING, "Writing ACL file for ACL SAVE: ", errno_text(werr))
			linux.close(fd)
			linux.unlink(tpath)
			return false
		}
		off += n
	}
	if ferr := linux.fsync(fd); ferr != .NONE {
		plog(LOG_WARNING, "Syncing ACL file for ACL SAVE: ", errno_text(ferr))
		linux.close(fd)
		linux.unlink(tpath)
		return false
	}
	linux.close(fd)
	if rerr := linux.rename(tpath, persist_cstr(path, pbuf[:])); rerr != .NONE {
		plog(LOG_WARNING, "Renaming ACL file for ACL SAVE: ", errno_text(rerr))
		linux.unlink(tpath)
		return false
	}
	return true
}

acl_config_directive :: proc(argv: [][]u8) -> (handled: bool, err: string) {
	if !eq_nocase(argv[0], "user") || len(argv) < 2 {
		return false, ""
	}
	acl_init()
	for def in acl_to_load {
		if bytes_eq(def[0], argv[1]) {
			return true, acl_declaration_error(argv[1], .Already)
		}
	}
	merged := make([dynamic][]u8, context.temp_allocator)
	ok, invalid := acl_merge_args(argv[2:], &merged)
	if !ok {
		return true, acl_declaration_error(argv[invalid], .Noent)
	}
	fake := acl_user_new(transmute([]u8)string("__fakeuser__"))
	defer acl_user_free(fake)
	for op, j in merged {
		if !acl_set_user(fake, op) && acl_errno != .Noent {
			return true, acl_declaration_error(argv[j], acl_errno)
		}
	}
	def := make([][]u8, len(merged) + 1)
	def[0] = acl_clone(argv[1])
	for op, j in merged {
		def[j + 1] = acl_clone(op)
	}
	append(&acl_to_load, def)
	return true, ""
}

@(private = "file")
acl_declaration_error :: proc(arg: []u8, e: Acl_Errno) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	sb_str(&b, "Error in user declaration '")
	sb_bytes(&b, arg)
	sb_str(&b, "': ")
	sb_str(&b, acl_strerror(e))
	return string(b[:])
}

acl_startup :: proc() {
	acl_init()
	acl_update_default_password(cfg.requirepass)
	if cfg.aclfile != "" && len(acl_to_load) != 0 {
		plog(LOG_WARNING, "Configuring Redis with users defined in redis.conf and at the same setting an ACL file path is invalid. This setup is very likely to lead to configuration errors and security holes, please define either an ACL file or declare users directly in your redis.conf, but not both.")
		linux.exit_group(1)
	}
	for def in acl_to_load {
		name := def[0]
		if acl_has_spaces(name) {
			plog(LOG_WARNING, "Spaces not allowed in ACL usernames")
			plog(LOG_WARNING, "Critical error while loading ACLs. Exiting.")
			linux.exit_group(1)
		}
		u := acl_user_find(name)
		if u == nil {
			u = acl_user_new(name)
			acl_users_insert(&acl_users, u)
		} else {
			acl_set_user(u, transmute([]u8)string("reset"))
		}
		for op in def[1:] {
			if !acl_set_user(u, op) {
				plog(LOG_WARNING, "Error loading ACL rule '", string(op), "' for the user named '", string(name), "': ", acl_strerror(acl_errno))
				plog(LOG_WARNING, "Critical error while loading ACLs. Exiting.")
				linux.exit_group(1)
			}
		}
		acl_user_update_open(u)
		if .Disabled in u.flags {
			plog(LOG_NOTICE, "The user '", string(name), "' is disabled (there is no 'on' modifier in the user description). Make sure this is not a configuration error.")
		}
	}
	if cfg.aclfile != "" {
		if errors := acl_load_file(nil); errors != "" {
			plog(LOG_WARNING, "Aborting Redis startup because of ACL errors: ", errors)
			linux.exit_group(1)
		}
	}
	acl_refresh_all()
}

@(private = "file")
acl_reply_selector :: proc(c: ^Conn, s: ^Acl_Selector) {
	b := make([dynamic]u8, context.temp_allocator)
	reply_bulk_str(c, "commands")
	acl_describe_commands(&b, s)
	reply_bulk(c, b[:])
	reply_bulk_str(c, "keys")
	if .All_Keys in s.flags {
		reply_bulk_str(c, "~*")
	} else {
		clear(&b)
		for p, i in s.patterns {
			if i > 0 {
				sb_byte(&b, ' ')
			}
			acl_pattern_string(&b, p)
		}
		reply_bulk(c, b[:])
	}
	reply_bulk_str(c, "channels")
	if .All_Channels in s.flags {
		reply_bulk_str(c, "&*")
	} else {
		clear(&b)
		for ch, i in s.channels {
			if i > 0 {
				sb_byte(&b, ' ')
			}
			sb_byte(&b, '&')
			sb_bytes(&b, ch)
		}
		reply_bulk(c, b[:])
	}
}

@(private = "file")
acl_cmd_setuser :: proc(c: ^Conn, argv: [][]u8) {
	username := argv[2]
	if acl_has_spaces(username) {
		reply_error(c, "ERR Usernames can't contain spaces or null characters")
		return
	}
	u := acl_user_find(username)
	if e := acl_string_set_user(c, u, username, argv[3:]); e != "" {
		clear(&scratch)
		sb_str(&scratch, e)
		sanitize_scratch()
		reply_error_bytes(c, scratch[:])
		return
	}
	acl_refresh_all()
	reply_ok(c)
}

@(private = "file")
acl_cmd_deluser :: proc(c: ^Conn, argv: [][]u8) {
	for name in argv[2:] {
		if string(name) == DEFAULT_USER {
			reply_error(c, "ERR The 'default' user cannot be removed")
			return
		}
	}
	deleted: i64 = 0
	for name in argv[2:] {
		u := acl_user_find(name)
		if u == nil {
			continue
		}
		for x, i in acl_users {
			if x == u {
				ordered_remove(&acl_users, i)
				break
			}
		}
		for i in 0 ..< len(srv.conns) {
			other := srv.conns[i]
			if other != nil && other.user == u {
				acl_close_conn(other, c)
			}
		}
		acl_user_free(u)
		deleted += 1
	}
	acl_refresh_all()
	reply_int(c, deleted)
}

@(private = "file")
acl_cmd_getuser :: proc(c: ^Conn, argv: [][]u8) {
	u := acl_user_find(argv[2])
	if u == nil {
		reply_null(c)
		return
	}
	reply_map(c, 6)
	reply_bulk_str(c, "flags")
	n := 0
	for f in Acl_User_Flag {
		if f in u.flags {
			n += 1
		}
	}
	reply_set(c, n)
	for f in Acl_User_Flag {
		if f in u.flags {
			reply_bulk_str(c, acl_user_flag_names[f])
		}
	}
	reply_bulk_str(c, "passwords")
	reply_array(c, len(u.passwords))
	for p in u.passwords {
		pw := p
		reply_bulk(c, pw[:])
	}
	acl_reply_selector(c, u.selectors[0])
	reply_bulk_str(c, "selectors")
	reply_array(c, len(u.selectors) - 1)
	for s in u.selectors[1:] {
		reply_map(c, 3)
		acl_reply_selector(c, s)
	}
}

@(private = "file")
acl_cmd_list :: proc(c: ^Conn, argv: [][]u8) {
	reply_array(c, len(acl_users))
	b := make([dynamic]u8, context.temp_allocator)
	for u in acl_users {
		clear(&b)
		sb_str(&b, "user ")
		sb_bytes(&b, u.name)
		sb_byte(&b, ' ')
		acl_describe_user(&b, u)
		reply_bulk(c, b[:])
	}
}

@(private = "file")
acl_cmd_users :: proc(c: ^Conn, argv: [][]u8) {
	reply_array(c, len(acl_users))
	for u in acl_users {
		reply_bulk(c, u.name)
	}
}

@(private = "file")
acl_cmd_whoami :: proc(c: ^Conn, argv: [][]u8) {
	if c.user == nil {
		reply_null(c)
		return
	}
	reply_bulk(c, c.user.name)
}

@(private = "file")
acl_cmd_load :: proc(c: ^Conn, argv: [][]u8) {
	if cfg.aclfile == "" {
		reply_error(c, ERR_ACL_NO_FILE)
		return
	}
	if e := acl_load_file(c); e != "" {
		clear(&scratch)
		sb_str(&scratch, "ERR ")
		sb_str(&scratch, e)
		sanitize_scratch()
		reply_error_bytes(c, scratch[:])
		return
	}
	reply_ok(c)
}

@(private = "file")
acl_cmd_save :: proc(c: ^Conn, argv: [][]u8) {
	if cfg.aclfile == "" {
		reply_error(c, ERR_ACL_NO_FILE)
		return
	}
	if !acl_save_file() {
		reply_error(c, "ERR There was an error trying to save the ACLs. Please check the server logs for more information")
		return
	}
	reply_ok(c)
}

@(private = "file")
acl_cmd_cat :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) == 2 {
		reply_array(c, len(Acl_Cat))
		for cat in Acl_Cat {
			reply_bulk_str(c, acl_names[cat][1:])
		}
		return
	}
	if len(argv) != 3 {
		reply_subcommand_syntax_error(c, argv[1], "ACL")
		return
	}
	cat, ok := acl_cat_by_name(argv[2])
	if !ok {
		reply_error_quoted(c, "ERR Unknown category '", argv[2][:min(len(argv[2]), 128)], "'")
		return
	}
	n := 0
	for i in 0 ..< ACL_CMD_COUNT {
		if cat in cmd_docs[i].acl {
			n += 1
		}
	}
	reply_array(c, n)
	for i in 0 ..< ACL_CMD_COUNT {
		if cat in cmd_docs[i].acl {
			reply_bulk_str(c, cmd_docs[i].name)
		}
	}
}

@(private = "file")
acl_cmd_genpass :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) > 3 {
		reply_subcommand_syntax_error(c, argv[1], "ACL")
		return
	}
	bits: i64 = 256
	if len(argv) == 3 {
		v, ok := parse_i64(argv[2])
		if !ok {
			reply_error(c, ERR_NOT_INT)
			return
		}
		bits = v
	}
	if bits <= 0 || bits > ACL_GENPASS_MAX_BITS {
		reply_error(c, "ERR ACL GENPASS argument must be the number of bits for the output password, a positive number up to 4096")
		return
	}
	chars := int((bits + 3) / 4)
	raw: [ACL_GENPASS_MAX_BITS / 4]u8
	got := 0
	for got < chars {
		n, err := linux.getrandom(raw[got:chars], {})
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			for i in got ..< chars {
				raw[i] = u8(rng_next())
			}
			break
		}
		got += n
	}
	hexd := "0123456789abcdef"
	for i in 0 ..< chars {
		raw[i] = hexd[raw[i] & 15]
	}
	reply_bulk(c, raw[:chars])
}

@(private = "file")
acl_cmd_log :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) > 3 {
		reply_subcommand_syntax_error(c, argv[1], "ACL")
		return
	}
	count: i64 = 10
	if len(argv) == 3 {
		if eq_nocase(argv[2], "reset") {
			for e in acl_log {
				acl_free_entry(e)
			}
			clear(&acl_log)
			reply_ok(c)
			return
		}
		v, ok := parse_i64(argv[2])
		if !ok {
			reply_error(c, ERR_NOT_INT)
			return
		}
		count = max(v, 0)
	}
	count = min(count, i64(len(acl_log)))
	reply_array(c, int(count))
	now := srv.now_ms
	for k in 0 ..< int(count) {
		e := acl_log[len(acl_log) - 1 - k]
		reply_map(c, 10)
		reply_bulk_str(c, "count")
		reply_int(c, e.count)
		reply_bulk_str(c, "reason")
		reply_bulk_str(c, acl_reason_names[e.reason])
		reply_bulk_str(c, "context")
		reply_bulk_str(c, acl_context_names[e.ctx])
		reply_bulk_str(c, "object")
		reply_bulk(c, e.object)
		reply_bulk_str(c, "username")
		reply_bulk(c, e.username)
		reply_bulk_str(c, "age-seconds")
		reply_double(c, f64(now - e.ctime) / 1000)
		reply_bulk_str(c, "client-info")
		reply_bulk(c, e.cinfo)
		reply_bulk_str(c, "entry-id")
		reply_int(c, e.id)
		reply_bulk_str(c, "timestamp-created")
		reply_int(c, e.created)
		reply_bulk_str(c, "timestamp-last-updated")
		reply_int(c, e.ctime)
	}
}

@(private = "file")
acl_cmd_dryrun :: proc(c: ^Conn, argv: [][]u8) {
	u := acl_user_find(argv[2])
	if u == nil {
		reply_error_quoted(c, "ERR User '", argv[2], "' not found")
		return
	}
	args := argv[3:]
	id := acl_lookup_argv(args)
	if id < 0 {
		reply_error_quoted(c, "ERR Command '", argv[3], "' not found")
		return
	}
	arity := int(cmd_specs[id].arity)
	if (arity > 0 && arity != len(args)) || len(args) < -arity {
		reply_error_parts(c, "ERR wrong number of arguments for '", cmd_docs[id].name, "' command")
		return
	}
	res, idx := acl_check_user(u, id, args)
	if res != .Ok {
		b := make([dynamic]u8, context.temp_allocator)
		acl_error_message(&b, res, u, cmd_docs[id].name, args[idx])
		reply_bulk(c, b[:])
		return
	}
	reply_ok(c)
}

@(private = "file")
acl_cmd_help :: proc(c: ^Conn, argv: [][]u8) {
	reply_array(c, len(acl_help_lines))
	for line in acl_help_lines {
		reply_simple(c, line)
	}
}

@(private = "file")
Acl_Subcommand :: struct {
	name:    string,
	full:    string,
	arity:   int,
	handler: Command_Proc,
}

@(private = "file")
acl_subcommands := [?]Acl_Subcommand {
	{"cat", "acl|cat", -2, acl_cmd_cat},
	{"deluser", "acl|deluser", -3, acl_cmd_deluser},
	{"dryrun", "acl|dryrun", -4, acl_cmd_dryrun},
	{"genpass", "acl|genpass", -2, acl_cmd_genpass},
	{"getuser", "acl|getuser", 3, acl_cmd_getuser},
	{"help", "acl|help", 2, acl_cmd_help},
	{"list", "acl|list", 2, acl_cmd_list},
	{"load", "acl|load", 2, acl_cmd_load},
	{"log", "acl|log", -2, acl_cmd_log},
	{"save", "acl|save", 2, acl_cmd_save},
	{"setuser", "acl|setuser", -3, acl_cmd_setuser},
	{"users", "acl|users", 2, acl_cmd_users},
	{"whoami", "acl|whoami", 2, acl_cmd_whoami},
}

cmd_acl :: proc(c: ^Conn, argv: [][]u8) {
	for &s in acl_subcommands {
		if eq_nocase(argv[1], s.name) {
			c.last_cmd = s.full
			if !arity_ok(s.arity, len(argv)) {
				reply_wrong_args(c, s.full)
				return
			}
			s.handler(c, argv)
			return
		}
	}
	c.last_cmd = "NULL"
	reply_unknown_subcommand(c, argv[1], "ACL")
}

@(private = "file")
acl_commands := [?]Command{{"acl", cmd_acl, -2}}

@(init)
register_acl_commands :: proc "contextless" () {
	register_commands(acl_commands[:])
}

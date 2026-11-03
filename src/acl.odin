package main

import "core:crypto/sha2"
import "core:sys/linux"

ACL_CMD_COUNT :: len(cmd_docs)
ACL_WORDS :: (ACL_CMD_COUNT + 63) / 64
ACL_HASH_LEN :: 64
ACL_LOG_MERGE_WINDOW_MS :: 60000
ACL_LOG_MERGE_LOOKBACK :: 10
ACL_UNAUTH_MBULK :: 10
ACL_UNAUTH_BULK :: 16384
ACL_UNAUTH_QBUF :: 1024 * 1024
ACL_UNAUTH_OBUF :: 1024
ACL_GENPASS_MAX_BITS :: 4096
ACL_NAME_MAX :: 64

ERR_NOAUTH :: "NOAUTH Authentication required."
ERR_NOAUTH_HELLO :: "NOAUTH HELLO must be called with the client already authenticated, otherwise the HELLO <proto> AUTH <user> <pass> option can be used to authenticate the client and select the RESP protocol version at the same time"
ERR_ACL_NO_FILE :: "ERR This Redis instance is not configured to use an ACL file. You may want to specify users via the ACL SETUSER command and then issue a CONFIG REWRITE (assuming you have a Redis configuration file set) in order to store users in the Redis configuration."

Acl_Verdict :: enum u8 {
	Allowed,
	Auth_Failed,
	Command_Denied,
	Key_Denied,
	Channel_Denied,
}

Acl_Context :: enum u8 {
	Toplevel,
	Lua,
	Multi,
	Module,
}

Acl_Rule_Error :: enum u8 {
	None,
	Unknown_Name,
	Bad_Syntax,
	Key_After_Wildcard,
	Channel_After_Wildcard,
	Missing_Password,
	Malformed_Hash,
	Duplicate_User,
	Subcommand_First_Arg,
}

Acl_User_Flag :: enum u8 {
	Enabled,
	Disabled,
	Nopass,
	Skip_Sanitize,
	Sanitize,
}

Acl_User_Flags :: bit_set[Acl_User_Flag;u8]

Acl_Scope :: enum u8 {
	Keys,
	Channels,
	Commands,
}

Acl_Scopes :: bit_set[Acl_Scope;u8]

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

Acl_Command_Rule :: struct {
	granted: bool,
	subject: []u8,
}

Acl_Selector :: struct {
	wildcards:        Acl_Scopes,
	future_commands:  bool,
	command_bits:     [ACL_WORDS]u64,
	command_rules:    [dynamic]Acl_Command_Rule,
	first_args:       [dynamic]Acl_First_Args,
	key_patterns:     [dynamic]Acl_Pattern,
	channel_patterns: [dynamic][]u8,
}

Acl_User :: struct {
	username:        []u8,
	attributes:      Acl_User_Flags,
	password_hashes: [dynamic][ACL_HASH_LEN]u8,
	root:            ^Acl_Selector,
	added_selectors: [dynamic]^Acl_Selector,
	unrestricted:    bool,
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
	entry_id:    i64,
	verdict:     Acl_Verdict,
	origin:      Acl_Context,
	username:    []u8,
	object:      []u8,
	occurrences: i64,
	first_ms:    i64,
	last_ms:     i64,
	client_info: []u8,
}

@(private = "file")
Acl_Request :: struct {
	id:         int,
	argv:       [][]u8,
	keys_known: bool,
}

@(private = "file")
Acl_Selector_Keyword :: enum u8 {
	All_Keys,
	Reset_Keys,
	All_Channels,
	Reset_Channels,
	All_Commands,
	No_Commands,
}

@(private = "file")
Acl_User_Keyword :: enum u8 {
	Enable,
	Disable,
	Skip_Sanitize,
	Sanitize,
	No_Password,
	Reset_Passwords,
	Clear_Selectors,
	Reset,
}

acl_users: [dynamic]^Acl_User
acl_default: ^Acl_User
acl_auth_needed: bool
acl_denied: [Acl_Verdict]i64
acl_doomed: [dynamic]^Conn

@(private = "file")
acl_meta: [ACL_CMD_COUNT]Acl_Cmd_Meta
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
acl_reason_names := [Acl_Verdict]string {
	.Allowed        = "unknown",
	.Auth_Failed    = "auth",
	.Command_Denied = "command",
	.Key_Denied     = "key",
	.Channel_Denied = "channel",
}

@(private = "file")
acl_denial_depth := [Acl_Verdict]int {
	.Allowed        = 0,
	.Auth_Failed    = 0,
	.Command_Denied = 1,
	.Key_Denied     = 2,
	.Channel_Denied = 3,
}

@(private = "file")
acl_rule_error_text := [Acl_Rule_Error]string {
	.None                   = "Wrong format",
	.Unknown_Name           = "Unknown command or category name in ACL",
	.Bad_Syntax             = "Syntax error",
	.Key_After_Wildcard     = "Adding a pattern after the * pattern (or the 'allkeys' flag) is not valid and does not have any effect. Try 'resetkeys' to start with an empty list of patterns",
	.Channel_After_Wildcard = "Adding a pattern after the * pattern (or the 'allchannels' flag) is not valid and does not have any effect. Try 'resetchannels' to start with an empty list of channels",
	.Missing_Password       = "The password you are trying to remove from the user does not exist",
	.Malformed_Hash         = "The password hash must be exactly 64 characters and contain only lowercase hexadecimal characters",
	.Duplicate_User         = "Duplicate user found. A user can only be defined once in config files",
	.Subcommand_First_Arg   = "Allowing first-arg of a subcommand is not supported",
}

@(private = "file")
acl_selector_words := [?]struct {
	word:    string,
	keyword: Acl_Selector_Keyword,
} {
	{"allkeys", .All_Keys},
	{"~*", .All_Keys},
	{"resetkeys", .Reset_Keys},
	{"allchannels", .All_Channels},
	{"&*", .All_Channels},
	{"resetchannels", .Reset_Channels},
	{"allcommands", .All_Commands},
	{"+@all", .All_Commands},
	{"nocommands", .No_Commands},
	{"-@all", .No_Commands},
}

@(private = "file")
acl_user_words := [?]struct {
	word:    string,
	keyword: Acl_User_Keyword,
} {
	{"on", .Enable},
	{"off", .Disable},
	{"skip-sanitize-payload", .Skip_Sanitize},
	{"sanitize-payload", .Sanitize},
	{"nopass", .No_Password},
	{"resetpass", .Reset_Passwords},
	{"clearselectors", .Clear_Selectors},
	{"reset", .Reset},
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
	acl_default = acl_default_user_new()
	append(&acl_users, acl_default)
	acl_auth_needed = false
}

@(private = "file")
acl_default_user_new :: proc() -> ^Acl_User {
	u := acl_user_new(transmute([]u8)string(DEFAULT_USER))
	opening := [?]string{"+@all", "~*", "&*", "on", "nopass"}
	for rule in opening {
		acl_apply_rule(u, transmute([]u8)rule)
	}
	acl_user_update_open(u)
	return u
}

@(private = "file")
acl_bit :: #force_inline proc "contextless" (s: ^Acl_Selector, id: int) -> bool {
	return s.command_bits[id >> 6] & (u64(1) << uint(id & 63)) != 0
}

@(private = "file")
acl_mark_command :: proc(s: ^Acl_Selector, id: int, granted: bool) {
	word := &s.command_bits[id / 64]
	bit := u64(1) << uint(id % 64)
	if granted {
		word^ |= bit
		return
	}
	word^ &~= bit
	s.wildcards -= {.Commands}
}

@(private = "file")
acl_firstargs_find :: proc(s: ^Acl_Selector, id: int) -> int {
	for fa, i in s.first_args {
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
	for a in s.first_args[i].args {
		delete(a)
	}
	delete(s.first_args[i].args)
	ordered_remove(&s.first_args, i)
}

@(private = "file")
acl_firstargs_reset :: proc(s: ^Acl_Selector) {
	for fa in s.first_args {
		for a in fa.args {
			delete(a)
		}
		delete(fa.args)
	}
	clear(&s.first_args)
}

@(private = "file")
acl_firstargs_add :: proc(s: ^Acl_Selector, id: int, sub: []u8) {
	i := acl_firstargs_find(s, id)
	if i < 0 {
		append(&s.first_args, Acl_First_Args{id = id})
		i = len(s.first_args) - 1
	}
	fa := &s.first_args[i]
	for a in fa.args {
		if eq_fold(a, sub) {
			return
		}
	}
	append(&fa.args, acl_clone(sub))
}

@(private = "file")
acl_clear_patterns :: proc(s: ^Acl_Selector) {
	for p in s.key_patterns {
		delete(p.pattern)
	}
	clear(&s.key_patterns)
}

@(private = "file")
acl_clear_channels :: proc(s: ^Acl_Selector) {
	for ch in s.channel_patterns {
		delete(ch)
	}
	clear(&s.channel_patterns)
}

@(private = "file")
acl_clear_command_rules :: proc(s: ^Acl_Selector) {
	for r in s.command_rules {
		delete(r.subject)
	}
	clear(&s.command_rules)
}

@(private = "file")
acl_selector_new :: proc() -> ^Acl_Selector {
	s := new(Acl_Selector)
	if cfg.acl_pubsub_default != 0 {
		s.wildcards += {.Channels}
	}
	return s
}

@(private = "file")
acl_selector_free :: proc(s: ^Acl_Selector) {
	acl_clear_command_rules(s)
	acl_firstargs_reset(s)
	acl_clear_patterns(s)
	acl_clear_channels(s)
	delete(s.command_rules)
	delete(s.first_args)
	delete(s.key_patterns)
	delete(s.channel_patterns)
	free(s)
}

@(private = "file")
acl_selector_copy :: proc(src: ^Acl_Selector) -> ^Acl_Selector {
	dst := new(Acl_Selector)
	dst.wildcards = src.wildcards
	dst.future_commands = src.future_commands
	dst.command_bits = src.command_bits
	for r in src.command_rules {
		append(&dst.command_rules, Acl_Command_Rule{granted = r.granted, subject = acl_clone(r.subject)})
	}
	for fa in src.first_args {
		for a in fa.args {
			acl_firstargs_add(dst, fa.id, a)
		}
	}
	for p in src.key_patterns {
		append(&dst.key_patterns, Acl_Pattern{acl_clone(p.pattern), p.perms})
	}
	for ch in src.channel_patterns {
		append(&dst.channel_patterns, acl_clone(ch))
	}
	return dst
}

@(private = "file")
acl_change_perm :: proc(s: ^Acl_Selector, id: int, allow: bool) {
	acl_mark_command(s, id, allow)
	acl_firstargs_reset_for(s, id)
	m := acl_meta[id]
	if m.sub_lo >= 0 {
		for j in int(m.sub_lo) ..< int(m.sub_hi) {
			acl_mark_command(s, j, allow)
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
acl_rule_covers :: proc(existing: []u8, subject: []u8) -> bool {
	if len(existing) < len(subject) || !bytes_eq(existing[:len(subject)], subject) {
		return false
	}
	return len(existing) == len(subject) || existing[len(subject)] == '|'
}

@(private = "file")
acl_forget_command_rules :: proc(s: ^Acl_Selector, subject: []u8) {
	kept := 0
	for r in s.command_rules {
		if acl_rule_covers(r.subject, subject) {
			delete(r.subject)
			continue
		}
		s.command_rules[kept] = r
		kept += 1
	}
	resize(&s.command_rules, kept)
}

@(private = "file")
acl_record_command_rule :: proc(s: ^Acl_Selector, subject: []u8, granted: bool) {
	folded := make([]u8, len(subject))
	for b, i in subject {
		folded[i] = lower(b)
	}
	acl_forget_command_rules(s, folded)
	append(&s.command_rules, Acl_Command_Rule{granted = granted, subject = folded})
}

@(private = "file")
acl_set_wildcard :: proc(s: ^Acl_Selector, scope: Acl_Scope, on: bool) {
	if on {
		s.wildcards += {scope}
	} else {
		s.wildcards -= {scope}
	}
}

@(private = "file")
acl_apply_selector_keyword :: proc(s: ^Acl_Selector, keyword: Acl_Selector_Keyword) {
	switch keyword {
	case .All_Keys, .Reset_Keys:
		acl_clear_patterns(s)
		acl_set_wildcard(s, .Keys, keyword == .All_Keys)
	case .All_Channels, .Reset_Channels:
		acl_clear_channels(s)
		acl_set_wildcard(s, .Channels, keyword == .All_Channels)
	case .All_Commands, .No_Commands:
		everything := keyword == .All_Commands
		fill: u64 = max(u64) if everything else 0
		for &word in s.command_bits {
			word = fill
		}
		s.future_commands = everything
		acl_set_wildcard(s, .Commands, everything)
		acl_clear_command_rules(s)
		acl_firstargs_reset(s)
	}
}

@(private = "file")
acl_key_rule_parts :: proc(rule: []u8) -> (perms: Acl_Perms, pattern: []u8, ok: bool) {
	if rule[0] == '~' {
		return {.Read, .Write}, rule[1:], true
	}
	at := 1
	for at < len(rule) && rule[at] != '~' {
		wanted: Acl_Perm
		switch rule[at] {
		case 'R', 'r':
			wanted = .Read
		case 'W', 'w':
			wanted = .Write
		case:
			return {}, nil, false
		}
		if wanted in perms {
			return {}, nil, false
		}
		perms += {wanted}
		at += 1
	}
	if perms == {} {
		return {}, nil, false
	}
	return perms, rule[min(at + 1, len(rule)):], true
}

@(private = "file")
acl_grant_key_pattern :: proc(s: ^Acl_Selector, rule: []u8) -> Acl_Rule_Error {
	if .Keys in s.wildcards {
		return .Key_After_Wildcard
	}
	perms, pattern, ok := acl_key_rule_parts(rule)
	if !ok || acl_has_spaces(pattern) {
		return .Bad_Syntax
	}
	for &known in s.key_patterns {
		if bytes_eq(known.pattern, pattern) {
			known.perms |= perms
			return .None
		}
	}
	append(&s.key_patterns, Acl_Pattern{pattern = acl_clone(pattern), perms = perms})
	return .None
}

@(private = "file")
acl_grant_channel_pattern :: proc(s: ^Acl_Selector, pattern: []u8) -> Acl_Rule_Error {
	if .Channels in s.wildcards {
		return .Channel_After_Wildcard
	}
	if acl_has_spaces(pattern) {
		return .Bad_Syntax
	}
	if !acl_channel_allowed(s.channel_patterns[:], pattern, true) {
		append(&s.channel_patterns, acl_clone(pattern))
	}
	return .None
}

@(private = "file")
acl_apply_category_rule :: proc(s: ^Acl_Selector, rule: []u8) -> Acl_Rule_Error {
	cat, found := acl_cat_by_name(rule[2:])
	if !found {
		return .Unknown_Name
	}
	granted := rule[0] == '+'
	acl_set_category_bits(s, cat, granted)
	acl_record_command_rule(s, rule[1:], granted)
	return .None
}

@(private = "file")
acl_set_whole_command :: proc(s: ^Acl_Selector, name: []u8, granted: bool) -> Acl_Rule_Error {
	id := acl_lookup_strict(name)
	if id < 0 {
		return .Unknown_Name
	}
	acl_change_perm(s, id, granted)
	acl_record_command_rule(s, transmute([]u8)cmd_docs[id].name, granted)
	return .None
}

@(private = "file")
acl_grant_command :: proc(s: ^Acl_Selector, name: []u8) -> Acl_Rule_Error {
	cut := len(name) - 1
	for cut >= 0 && name[cut] != '|' {
		cut -= 1
	}
	if cut < 0 {
		return acl_set_whole_command(s, name, true)
	}
	owner := acl_lookup_strict(name[:cut])
	switch {
	case owner < 0:
		return .Unknown_Name
	case acl_meta[owner].parent >= 0:
		return .Subcommand_First_Arg
	case cut == len(name) - 1:
		return .Bad_Syntax
	case acl_meta[owner].sub_lo >= 0:
		return acl_set_whole_command(s, name, true)
	}
	plog(LOG_WARNING, "Deprecation warning: Allowing a first arg of an otherwise blocked command is a misuse of ACL and may get disabled in the future (offender: +", string(name), ")")
	acl_firstargs_add(s, owner, name[cut + 1:])
	acl_record_command_rule(s, name, true)
	return .None
}

@(private = "file")
acl_apply_selector_rule :: proc(s: ^Acl_Selector, rule: []u8) -> Acl_Rule_Error {
	for w in acl_selector_words {
		if eq_nocase(rule, w.word) {
			acl_apply_selector_keyword(s, w.keyword)
			return .None
		}
	}
	if len(rule) == 0 {
		return .Bad_Syntax
	}
	switch rule[0] {
	case '~', '%':
		return acl_grant_key_pattern(s, rule)
	case '&':
		return acl_grant_channel_pattern(s, rule[1:])
	case '+', '-':
		if len(rule) > 1 && rule[1] == '@' {
			return acl_apply_category_rule(s, rule)
		}
		if rule[0] == '-' {
			return acl_set_whole_command(s, rule[1:], false)
		}
		return acl_grant_command(s, rule[1:])
	}
	return .Bad_Syntax
}

@(private = "file")
acl_user_new :: proc(name: []u8) -> ^Acl_User {
	u := new(Acl_User)
	u.username = acl_clone(name)
	u.attributes = {.Disabled, .Sanitize}
	u.root = acl_selector_new()
	return u
}

@(private = "file")
acl_drop_added_selectors :: proc(u: ^Acl_User) {
	for s in u.added_selectors {
		acl_selector_free(s)
	}
	clear(&u.added_selectors)
}

@(private = "file")
acl_user_clear :: proc(u: ^Acl_User) {
	clear(&u.password_hashes)
	acl_drop_added_selectors(u)
	if u.root != nil {
		acl_selector_free(u.root)
		u.root = nil
	}
}

@(private = "file")
acl_user_free :: proc(u: ^Acl_User) {
	acl_user_clear(u)
	delete(u.password_hashes)
	delete(u.added_selectors)
	delete(u.username)
	free(u)
}

@(private = "file")
acl_user_copy_into :: proc(dst: ^Acl_User, src: ^Acl_User) {
	acl_user_clear(dst)
	dst.attributes = src.attributes
	append(&dst.password_hashes, ..src.password_hashes[:])
	dst.root = acl_selector_copy(src.root)
	for s in src.added_selectors {
		append(&dst.added_selectors, acl_selector_copy(s))
	}
	acl_user_update_open(dst)
}

@(private = "file")
acl_user_update_open :: proc(u: ^Acl_User) {
	u.unrestricted = u.root.wildcards == {.Keys, .Commands, .Channels}
}

@(private = "file")
acl_selector_count :: #force_inline proc "contextless" (u: ^Acl_User) -> int {
	return len(u.added_selectors) + 1
}

@(private = "file")
acl_selector_at :: #force_inline proc "contextless" (u: ^Acl_User, i: int) -> ^Acl_Selector {
	return u.root if i == 0 else u.added_selectors[i - 1]
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
	for p, i in u.password_hashes {
		if p == h {
			return i
		}
	}
	return -1
}

@(private = "file")
acl_apply_password_rule :: proc(u: ^Acl_User, rule: []u8) -> Acl_Rule_Error {
	digest: [ACL_HASH_LEN]u8
	switch rule[0] {
	case '#', '!':
		parsed, ok := acl_hash_from_hex(rule[1:])
		if !ok {
			return .Malformed_Hash
		}
		digest = parsed
	case:
		digest = acl_hash_password(rule[1:])
	}
	known := acl_password_index(u, digest)
	if rule[0] == '<' || rule[0] == '!' {
		if known < 0 {
			return .Missing_Password
		}
		ordered_remove(&u.password_hashes, known)
		return .None
	}
	if known < 0 {
		append(&u.password_hashes, digest)
	}
	u.attributes -= {.Nopass}
	return .None
}

@(private = "file")
acl_choose_flag :: proc(u: ^Acl_User, chosen: Acl_User_Flag, other: Acl_User_Flag) {
	u.attributes += {chosen}
	u.attributes -= {other}
}

@(private = "file")
acl_apply_user_keyword :: proc(u: ^Acl_User, keyword: Acl_User_Keyword) {
	switch keyword {
	case .Enable:
		acl_choose_flag(u, .Enabled, .Disabled)
	case .Disable:
		acl_choose_flag(u, .Disabled, .Enabled)
	case .Skip_Sanitize:
		acl_choose_flag(u, .Skip_Sanitize, .Sanitize)
	case .Sanitize:
		acl_choose_flag(u, .Sanitize, .Skip_Sanitize)
	case .No_Password:
		clear(&u.password_hashes)
		u.attributes += {.Nopass}
	case .Reset_Passwords:
		clear(&u.password_hashes)
		u.attributes -= {.Nopass}
	case .Clear_Selectors:
		acl_drop_added_selectors(u)
	case .Reset:
		clear(&u.password_hashes)
		u.attributes = {.Disabled, .Sanitize}
		acl_drop_added_selectors(u)
		acl_apply_selector_keyword(u.root, .Reset_Keys)
		acl_apply_selector_keyword(u.root, .Reset_Channels)
		if cfg.acl_pubsub_default != 0 {
			acl_apply_selector_keyword(u.root, .All_Channels)
		}
		acl_apply_selector_keyword(u.root, .No_Commands)
	}
}

@(private = "file")
acl_add_selector :: proc(u: ^Acl_User, body: []u8) -> Acl_Rule_Error {
	words := make([dynamic][]u8, context.temp_allocator)
	if !split_args(body, &words, context.temp_allocator) {
		clear(&words)
	}
	s := acl_selector_new()
	for w in words {
		if e := acl_apply_selector_rule(s, w); e != .None {
			acl_selector_free(s)
			return e
		}
	}
	append(&u.added_selectors, s)
	return .None
}

@(private = "file")
acl_apply_rule :: proc(u: ^Acl_User, rule: []u8) -> Acl_Rule_Error {
	if len(rule) == 0 {
		return .None
	}
	for w in acl_user_words {
		if eq_nocase(rule, w.word) {
			acl_apply_user_keyword(u, w.keyword)
			return .None
		}
	}
	switch rule[0] {
	case '>', '<', '#', '!':
		return acl_apply_password_rule(u, rule)
	case '(':
		if rule[len(rule) - 1] == ')' {
			return acl_add_selector(u, rule[1:len(rule) - 1])
		}
	}
	return acl_apply_selector_rule(u.root, rule)
}

acl_user_find :: proc(name: []u8) -> ^Acl_User {
	lo, hi := 0, len(acl_users)
	for lo < hi {
		mid := (lo + hi) / 2
		if acl_name_cmp(acl_users[mid].username, name) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(acl_users) && acl_name_cmp(acl_users[lo].username, name) == 0 {
		return acl_users[lo]
	}
	return nil
}

@(private = "file")
acl_users_insert :: proc(users: ^[dynamic]^Acl_User, u: ^Acl_User) -> bool {
	lo, hi := 0, len(users)
	for lo < hi {
		mid := (lo + hi) / 2
		if acl_name_cmp(users[mid].username, u.username) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(users) && acl_name_cmp(users[lo].username, u.username) == 0 {
		return false
	}
	inject_at(users, lo, u)
	return true
}

@(private = "file")
acl_opens_group :: #force_inline proc(word: []u8) -> bool {
	return len(word) > 0 && word[0] == '(' && word[len(word) - 1] != ')'
}

@(private = "file")
acl_closes_group :: #force_inline proc(word: []u8) -> bool {
	return len(word) > 0 && word[len(word) - 1] == ')'
}

@(private = "file")
acl_group_selector_tokens :: proc(words: [][]u8, out: ^[dynamic][]u8) -> (unclosed_at: int, ok: bool) {
	clear(out)
	at := 0
	for at < len(words) {
		if !acl_opens_group(words[at]) {
			append(out, words[at])
			at += 1
			continue
		}
		last := at + 1
		for last < len(words) && !acl_closes_group(words[last]) {
			last += 1
		}
		if last == len(words) {
			return at, false
		}
		joined := make([dynamic]u8, context.temp_allocator)
		for w, k in words[at:last + 1] {
			if k > 0 {
				append(&joined, ' ')
			}
			append(&joined, ..w)
		}
		append(out, joined[:])
		at = last + 1
	}
	return -1, true
}

@(private = "file")
acl_describe_selector :: proc(b: ^[dynamic]u8, s: ^Acl_Selector) {
	if .Keys in s.wildcards {
		sb_str(b, "~* ")
	} else {
		for p in s.key_patterns {
			acl_pattern_string(b, p)
			sb_byte(b, ' ')
		}
	}
	if .Channels in s.wildcards {
		sb_str(b, "&* ")
	} else {
		sb_str(b, "resetchannels ")
		for ch in s.channel_patterns {
			sb_byte(b, '&')
			sb_bytes(b, ch)
			sb_byte(b, ' ')
		}
	}
	acl_command_rules_text(b, s)
}

@(private = "file")
acl_command_rules_text :: proc(b: ^[dynamic]u8, s: ^Acl_Selector) {
	sb_str(b, s.future_commands ? "+@all" : "-@all")
	for r in s.command_rules {
		sb_byte(b, ' ')
		sb_byte(b, r.granted ? '+' : '-')
		sb_bytes(b, r.subject)
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
		if f in u.attributes {
			sb_str(b, acl_user_flag_names[f])
			sb_byte(b, ' ')
		}
	}
	for p in u.password_hashes {
		sb_byte(b, '#')
		pw := p
		sb_bytes(b, pw[:])
		sb_byte(b, ' ')
	}
	acl_describe_selector(b, u.root)
	for s in u.added_selectors {
		sb_str(b, " (")
		acl_describe_selector(b, s)
		sb_byte(b, ')')
	}
}

@(private = "file")
acl_check_key :: proc(s: ^Acl_Selector, key: []u8, flags: Key_Flags) -> bool {
	if .Keys in s.wildcards {
		return true
	}
	need: Acl_Perms
	if .Access in flags {
		need += {.Read}
	}
	if flags & {.Insert, .Delete, .Update} != {} {
		need += {.Write}
	}
	for p in s.key_patterns {
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
	if .Keys in s.wildcards {
		return true
	}
	need: Acl_Perms
	if .Access in flags {
		need += {.Read}
	}
	if flags & {.Insert, .Delete, .Update} != {} {
		need += {.Write}
	}
	for p in s.key_patterns {
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
acl_request_keys :: proc(req: ^Acl_Request) -> []Key_Ref {
	if !req.keys_known {
		find_keys(&cmd_specs[req.id], req.argv, &acl_keys)
		req.keys_known = true
	}
	return acl_keys[:]
}

@(private = "file")
acl_selector_runs_command :: proc(s: ^Acl_Selector, req: ^Acl_Request) -> bool {
	if .Commands in s.wildcards || .No_Auth in cmd_specs[req.id].flags || acl_bit(s, req.id) {
		return true
	}
	if len(req.argv) < 2 {
		return false
	}
	slot := acl_firstargs_find(s, req.id)
	if slot < 0 {
		return false
	}
	for permitted in s.first_args[slot].args {
		if eq_fold(req.argv[1], permitted) {
			return true
		}
	}
	return false
}

@(private = "file")
acl_selector_key_block :: proc(s: ^Acl_Selector, req: ^Acl_Request) -> (blocked: bool, at: int) {
	if .Keys in s.wildcards || !spec_has_keys(&cmd_specs[req.id]) {
		return false, 0
	}
	for k in acl_request_keys(req) {
		if !acl_check_key(s, req.argv[k.pos], k.flags) {
			return true, k.pos
		}
	}
	return false, 0
}

@(private = "file")
acl_selector_channel_block :: proc(s: ^Acl_Selector, req: ^Acl_Request) -> (blocked: bool, at: int) {
	kind := acl_meta[req.id].channel
	if kind == .None || .Channels in s.wildcards {
		return false, 0
	}
	last := len(req.argv) - 1
	if kind == .Publish {
		last = min(last, 1)
	}
	for i in 1 ..= last {
		if !acl_channel_allowed(s.channel_patterns[:], req.argv[i], kind == .Pattern) {
			return true, i
		}
	}
	return false, 0
}

@(private = "file")
acl_selector_verdict :: proc(s: ^Acl_Selector, req: ^Acl_Request) -> (Acl_Verdict, int) {
	if !acl_selector_runs_command(s, req) {
		return .Command_Denied, 0
	}
	if blocked, at := acl_selector_key_block(s, req); blocked {
		return .Key_Denied, at
	}
	if blocked, at := acl_selector_channel_block(s, req); blocked {
		return .Channel_Denied, at
	}
	return .Allowed, 0
}

acl_check_user :: proc(u: ^Acl_User, id: int, argv: [][]u8) -> (Acl_Verdict, int) {
	if u == nil {
		return .Allowed, 0
	}
	req := Acl_Request{id = id, argv = argv}
	worst, worst_at := Acl_Verdict.Command_Denied, 0
	for i in 0 ..< acl_selector_count(u) {
		s := acl_selector_at(u, i)
		if s == nil {
			continue
		}
		verdict, at := acl_selector_verdict(s, &req)
		if verdict == .Allowed {
			return .Allowed, 0
		}
		deeper := acl_denial_depth[verdict] - acl_denial_depth[worst]
		if deeper > 0 || (deeper == 0 && at > worst_at) {
			worst, worst_at = verdict, at
		}
	}
	return worst, worst_at
}

acl_unrestricted_access :: proc(c: ^Conn, argv: [][]u8, flags: Key_Flags) -> bool {
	u := c.user
	if u == nil || u.unrestricted {
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
	req := Acl_Request{id = id, argv = argv}
	for i in 0 ..< acl_selector_count(u) {
		s := acl_selector_at(u, i)
		if s == nil {
			continue
		}
		verdict, _ := acl_selector_verdict(s, &req)
		if verdict == .Allowed && acl_unrestricted_selector(s, flags) {
			return true
		}
	}
	return false
}

acl_skips_sanitize :: proc(c: ^Conn) -> bool {
	return c.user != nil && .Skip_Sanitize in c.user.attributes
}

acl_user_name :: proc(c: ^Conn) -> string {
	if c.user == nil {
		return "(superuser)"
	}
	return string(c.user.username)
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
	return .Nopass in acl_default.attributes && .Disabled not_in acl_default.attributes
}

acl_conn_refresh :: proc(c: ^Conn) {
	need_auth := acl_auth_needed && !c.authed
	c.acl_gate = need_auth || (c.user != nil && !c.user.unrestricted)
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
	if u == nil || .Disabled in u.attributes {
		return nil
	}
	if .Nopass in u.attributes {
		return u
	}
	h := acl_hash_password(password)
	for p in u.password_hashes {
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
	acl_log_add(c, .Auth_Failed, .Multi if .Multi in c.txf else .Toplevel, argv, 0, username, argv[0])
	return false
}

@(private = "file")
acl_free_entry :: proc(e: ^Acl_Log_Entry) {
	delete(e.object)
	delete(e.username)
	delete(e.client_info)
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

@(private = "file")
acl_log_recent_match :: proc(verdict: Acl_Verdict, origin: Acl_Context, object: []u8, username: []u8, now: i64) -> int {
	stop := max(len(acl_log) - ACL_LOG_MERGE_LOOKBACK, 0)
	for i := len(acl_log) - 1; i >= stop; i -= 1 {
		e := acl_log[i]
		if e.verdict != verdict || e.origin != origin || abs(e.last_ms - now) > ACL_LOG_MERGE_WINDOW_MS {
			continue
		}
		if bytes_eq(e.object, object) && bytes_eq(e.username, username) {
			return i
		}
	}
	return -1
}

@(private = "file")
acl_log_touch :: proc(at: int, info: []u8, now: i64) {
	e := acl_log[at]
	ordered_remove(&acl_log, at)
	append(&acl_log, e)
	delete(e.client_info)
	e.client_info = acl_clone(info)
	e.last_ms = now
	e.occurrences += 1
}

acl_log_add :: proc(c: ^Conn, verdict: Acl_Verdict, origin: Acl_Context, argv: [][]u8, pos: int, username: []u8, object: []u8) {
	acl_denied[verdict] += 1
	if cfg.acllog_max_len != 0 {
		acl_log_record(c, verdict, origin, argv, pos, username, object)
		return
	}
	acl_log_trim()
}

@(private = "file")
acl_log_record :: proc(c: ^Conn, verdict: Acl_Verdict, origin: Acl_Context, argv: [][]u8, pos: int, username: []u8, object: []u8) {
	subject := object if object != nil else argv[pos]
	who := username if username != nil else transmute([]u8)acl_user_name(c)
	info := make([dynamic]u8, context.temp_allocator)
	client_info_line(&info, c, c, argv)
	if n := len(info); n > 0 && info[n - 1] == '\n' {
		pop(&info)
	}
	now := srv.now_ms
	if at := acl_log_recent_match(verdict, origin, subject, who, now); at >= 0 {
		acl_log_touch(at, info[:], now)
		return
	}
	entry := new(Acl_Log_Entry)
	entry^ = Acl_Log_Entry {
		entry_id    = acl_log_count,
		verdict     = verdict,
		origin      = origin,
		username    = acl_clone(who),
		object      = acl_clone(subject),
		occurrences = 1,
		first_ms    = now,
		last_ms     = now,
		client_info = acl_clone(info[:]),
	}
	acl_log_count += 1
	append(&acl_log, entry)
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
		keyspace_settle(c)
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
	if res == .Allowed {
		return false
	}
	acl_log_add(c, res, .Multi if .Multi in c.txf else .Toplevel, argv, pos, nil, transmute([]u8)target.name if res == .Command_Denied else nil)
	keyspace_settle(c)
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

acl_error_message :: proc(b: ^[dynamic]u8, res: Acl_Verdict, u: ^Acl_User, fullname: string, value: []u8) {
	#partial switch res {
	case .Command_Denied:
		sb_str(b, "User ")
		sb_bytes(b, u.username)
		sb_str(b, " has no permissions to run the '")
		sb_str(b, fullname)
		sb_str(b, "' command")
	case .Key_Denied:
		if value == nil {
			sb_str(b, "No permissions to access a key")
		} else {
			sb_str(b, "User ")
			sb_bytes(b, u.username)
			sb_str(b, " has no permissions to access the '")
			sb_bytes(b, value)
			sb_str(b, "' key")
		}
	case .Channel_Denied:
		if value == nil {
			sb_str(b, "No permissions to access a channel")
		} else {
			sb_str(b, "User ")
			sb_bytes(b, u.username)
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
	if res == .Allowed {
		return false
	}
	acl_log_add(c, res, .Multi, argv, pos, nil, transmute([]u8)target.name if res == .Command_Denied else nil)
	reason: string
	#partial switch res {
	case .Command_Denied:
		reason = "no permission to execute the command or subcommand"
	case .Key_Denied:
		reason = "no permission to touch the specified keys"
	case .Channel_Denied:
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
acl_channel_revocation :: proc(next: ^Acl_User, current: ^Acl_User, granted: ^[dynamic][]u8) -> bool {
	clear(granted)
	for i in 0 ..< acl_selector_count(next) {
		s := acl_selector_at(next, i)
		if .Channels in s.wildcards {
			return false
		}
		append(granted, ..s.channel_patterns[:])
	}
	revoked := false
	for i in 0 ..< acl_selector_count(current) {
		revoked = revoked || acl_selector_loses_channels(acl_selector_at(current, i), granted[:])
	}
	return revoked
}

@(private = "file")
acl_selector_loses_channels :: proc(s: ^Acl_Selector, granted: [][]u8) -> bool {
	lost := .Channels in s.wildcards
	for ch in s.channel_patterns {
		if lost {
			break
		}
		lost = !acl_channel_allowed(granted, ch, true)
	}
	return lost
}

@(private = "file")
acl_evict_conn :: proc(c: ^Conn, self: ^Conn) {
	acl_set_conn_user(c, acl_default, false)
	c.close_after = true
	if c != self && !acl_is_doomed(c) {
		append(&acl_doomed, c)
	}
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
	granted := make([dynamic][]u8, context.temp_allocator)
	if !acl_channel_revocation(next, current, &granted) {
		return
	}
	for c in srv.conns {
		if c != nil && c.user == current && acl_kill_list(c, granted[:]) {
			acl_evict_conn(c, self)
		}
	}
}

@(private = "file")
acl_setuser_apply :: proc(self: ^Conn, existing: ^Acl_User, username: []u8, args: [][]u8) -> string {
	rules := make([dynamic][]u8, context.temp_allocator)
	if unclosed, ok := acl_group_selector_tokens(args, &rules); !ok {
		return concat_temp(concat_temp("ERR Unmatched parenthesis in acl selector starting at '", string(args[unclosed])), "'.")
	}
	draft := acl_user_new(username)
	if existing != nil {
		acl_user_copy_into(draft, existing)
	}
	for rule in rules {
		e := acl_apply_rule(draft, rule)
		if e == .None {
			continue
		}
		acl_user_free(draft)
		msg := make([dynamic]u8, context.temp_allocator)
		sb_str(&msg, "ERR Error in ACL SETUSER modifier '")
		sb_bytes(&msg, rule)
		sb_str(&msg, "': ")
		sb_str(&msg, acl_rule_error_text[e])
		return string(msg[:])
	}
	if existing == nil {
		acl_user_update_open(draft)
		acl_users_insert(&acl_users, draft)
		return ""
	}
	acl_kill_pubsub(self, draft, existing)
	acl_user_copy_into(existing, draft)
	acl_user_free(draft)
	return ""
}

acl_update_default_password :: proc(password: string) {
	acl_init()
	acl_apply_user_keyword(acl_default, .Reset_Passwords)
	if password != "" {
		op := make([]u8, len(password) + 1, context.temp_allocator)
		op[0] = '>'
		copy(op[1:], password)
		acl_apply_password_rule(acl_default, op)
	} else {
		acl_apply_user_keyword(acl_default, .No_Password)
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
acl_file_where :: proc(out: ^[dynamic]u8, number: int) {
	sb_str(out, cfg.aclfile)
	sb_byte(out, ':')
	sb_int(out, i64(number))
}

@(private = "file")
acl_file_rules :: proc(report: ^[dynamic]u8, u: ^Acl_User, rules: [][]u8, number: int) {
	reported_syntax := false
	for raw in rules {
		rule := acl_trim(raw, "\t\r\n")
		e := acl_apply_rule(u, rule)
		if e == .None || (e != .Unknown_Name && reported_syntax) {
			continue
		}
		acl_file_where(report, number)
		if e == .Unknown_Name {
			sb_str(report, ": Error in applying operation '")
			sb_bytes(report, rule)
			sb_str(report, "'")
		} else {
			reported_syntax = true
		}
		sb_str(report, ": ")
		sb_str(report, acl_rule_error_text[e])
		sb_str(report, ". ")
	}
}

@(private = "file")
acl_file_line :: proc(report: ^[dynamic]u8, loaded: ^[dynamic]^Acl_User, line: []u8, number: int) {
	words := make([dynamic][]u8, context.temp_allocator)
	acl_split_spaces(line, &words)
	if len(words) < 2 || string(words[0]) != "user" {
		acl_file_where(report, number)
		sb_str(report, " should start with user keyword followed by the username. ")
		return
	}
	name := words[1]
	if acl_has_spaces(name) {
		sb_byte(report, '\'')
		acl_file_where(report, number)
		sb_str(report, ": username '")
		sb_bytes(report, name)
		sb_str(report, "' contains invalid characters. ")
		return
	}
	u := acl_user_new(name)
	if !acl_users_insert(loaded, u) {
		acl_user_free(u)
		sb_str(report, "WARNING: Duplicate user '")
		sb_bytes(report, name)
		sb_str(report, "' found on line ")
		sb_int(report, i64(number))
		sb_str(report, ". ")
		return
	}
	rules := make([dynamic][]u8, context.temp_allocator)
	if _, ok := acl_group_selector_tokens(words[2:], &rules); !ok {
		acl_file_where(report, number)
		sb_str(report, ": Unmatched parenthesis in selector definition.")
		return
	}
	acl_file_rules(report, u, rules[:], number)
	acl_user_update_open(u)
}

@(private = "file")
acl_file_load :: proc(self: ^Conn) -> string {
	data, err := read_whole_file(cfg.aclfile)
	if err != .NONE {
		return concat_temp(concat_temp(concat_temp("Error loading ACLs, opening file '", cfg.aclfile), "': "), errno_text(err))
	}
	report := make([dynamic]u8, context.temp_allocator)
	loaded := make([dynamic]^Acl_User)
	number := 0
	for start := 0; start <= len(data); {
		stop := start
		for stop < len(data) && data[stop] != '\n' {
			stop += 1
		}
		number += 1
		if line := acl_trim(data[start:stop], " \t\r\n"); len(line) > 0 {
			acl_file_line(&report, &loaded, line, number)
		}
		start = stop + 1
	}
	if len(report) == 0 {
		acl_file_activate(self, &loaded)
		return ""
	}
	for u in loaded {
		acl_user_free(u)
	}
	delete(loaded)
	sb_str(&report, "WARNING: ACL errors detected, no change to the previously active ACL rules was performed")
	return string(report[:])
}

@(private = "file")
acl_keeps_conn :: proc(c: ^Conn, replacement: ^Acl_User, granted: ^[dynamic][]u8) -> bool {
	if replacement == nil {
		return false
	}
	if len(ps_conns) == 0 || !acl_channel_revocation(replacement, c.user, granted) {
		return true
	}
	return !acl_kill_list(c, granted[:])
}

@(private = "file")
acl_file_activate :: proc(self: ^Conn, loaded: ^[dynamic]^Acl_User) {
	incoming := acl_user_find_in(loaded[:], transmute([]u8)string(DEFAULT_USER))
	if incoming == nil {
		incoming = acl_default_user_new()
		acl_users_insert(loaded, incoming)
	}
	acl_user_copy_into(acl_default, incoming)
	for &slot in loaded^ {
		if slot == incoming {
			slot = acl_default
		}
	}
	acl_user_free(incoming)
	retired := acl_users
	acl_users = loaded^
	granted := make([dynamic][]u8, context.temp_allocator)
	for c in srv.conns {
		if c == nil || c.user == nil {
			continue
		}
		replacement := acl_user_find(c.user.username)
		if acl_keeps_conn(c, replacement, &granted) {
			c.user = replacement
		} else {
			acl_evict_conn(c, self)
		}
	}
	for u in retired {
		if u == acl_default {
			continue
		}
		acl_user_free(u)
	}
	delete(retired)
	acl_refresh_all()
}

@(private = "file")
acl_user_find_in :: proc(users: []^Acl_User, name: []u8) -> ^Acl_User {
	for u in users {
		if bytes_eq(u.username, name) {
			return u
		}
	}
	return nil
}

@(private = "file")
acl_store_text :: proc(fd: linux.Fd, text: []u8) -> (step: string, failure: linux.Errno) {
	rest := text
	for len(rest) > 0 {
		n, err := linux.write(fd, rest)
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			return "Writing", err
		}
		rest = rest[n:]
	}
	if err := linux.fsync(fd); err != .NONE {
		return "Syncing", err
	}
	return "", .NONE
}

@(private = "file")
acl_file_save :: proc() -> bool {
	text := make([dynamic]u8, context.temp_allocator)
	for u in acl_users {
		sb_str(&text, "user ")
		sb_bytes(&text, u.username)
		sb_byte(&text, ' ')
		acl_describe_user(&text, u)
		sb_byte(&text, '\n')
	}
	staging := make([dynamic]u8, context.temp_allocator)
	sb_str(&staging, cfg.aclfile)
	sb_str(&staging, ".tmp-")
	sb_int(&staging, srv.pid)
	sb_byte(&staging, '-')
	sb_int(&staging, srv.now_ms)
	sbuf: [4096]u8
	tbuf: [4096]u8
	spath := persist_cstr(string(staging[:]), sbuf[:])
	fd, err := linux.open(spath, {.WRONLY, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if err != .NONE {
		plog(LOG_WARNING, "Opening temp ACL file for ACL SAVE: ", errno_text(err))
		return false
	}
	step, failure := acl_store_text(fd, text[:])
	linux.close(fd)
	if step == "" {
		failure = linux.rename(spath, persist_cstr(cfg.aclfile, tbuf[:]))
		if failure == .NONE {
			return true
		}
		step = "Renaming"
	}
	plog(LOG_WARNING, step, " ACL file for ACL SAVE: ", errno_text(failure))
	linux.unlink(spath)
	return false
}

@(private = "file")
acl_declaration_error :: proc(arg: []u8, e: Acl_Rule_Error) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	sb_str(&b, "Error in user declaration '")
	sb_bytes(&b, arg)
	sb_str(&b, "': ")
	sb_str(&b, acl_rule_error_text[e])
	return string(b[:])
}

@(private = "file")
acl_already_declared :: proc(name: []u8) -> bool {
	for declared in acl_to_load {
		if bytes_eq(declared[0], name) {
			return true
		}
	}
	return false
}

@(private = "file")
acl_declare_user :: proc(argv: [][]u8) -> string {
	if acl_already_declared(argv[1]) {
		return acl_declaration_error(argv[1], .Duplicate_User)
	}
	rules := make([dynamic][]u8, context.temp_allocator)
	if unclosed, ok := acl_group_selector_tokens(argv[2:], &rules); !ok {
		return acl_declaration_error(argv[unclosed], .Unknown_Name)
	}
	trial := acl_user_new(transmute([]u8)string("__fakeuser__"))
	defer acl_user_free(trial)
	for rule, k in rules {
		if e := acl_apply_rule(trial, rule); e != .None && e != .Unknown_Name {
			return acl_declaration_error(argv[k], e)
		}
	}
	saved := make([][]u8, len(rules) + 1)
	saved[0] = acl_clone(argv[1])
	for rule, k in rules {
		saved[k + 1] = acl_clone(rule)
	}
	append(&acl_to_load, saved)
	return ""
}

acl_config_directive :: proc(argv: [][]u8) -> (handled: bool, err: string) {
	if len(argv) < 2 || !eq_nocase(argv[0], "user") {
		return false, ""
	}
	acl_init()
	return true, acl_declare_user(argv)
}

@(private = "file")
acl_abort_loading :: proc(parts: ..string) {
	plog(LOG_WARNING, ..parts)
	plog(LOG_WARNING, "Critical error while loading ACLs. Exiting.")
	linux.exit_group(1)
}

@(private = "file")
acl_install_declared :: proc(saved: [][]u8) {
	name := saved[0]
	if acl_has_spaces(name) {
		acl_abort_loading("Spaces not allowed in ACL usernames")
	}
	u := acl_user_find(name)
	if u != nil {
		acl_apply_user_keyword(u, .Reset)
	} else {
		u = acl_user_new(name)
		acl_users_insert(&acl_users, u)
	}
	for rule in saved[1:] {
		if e := acl_apply_rule(u, rule); e != .None {
			acl_abort_loading("Error loading ACL rule '", string(rule), "' for the user named '", string(name), "': ", acl_rule_error_text[e])
		}
	}
	acl_user_update_open(u)
	if .Disabled in u.attributes {
		plog(LOG_NOTICE, "The user '", string(name), "' is disabled (there is no 'on' modifier in the user description). Make sure this is not a configuration error.")
	}
}

acl_startup :: proc() {
	acl_init()
	acl_update_default_password(cfg.requirepass)
	if len(acl_to_load) > 0 && cfg.aclfile != "" {
		plog(LOG_WARNING, "Configuring Eski with users defined in the configuration file and at the same time an ACL file path is invalid. This setup is very likely to lead to configuration errors and security holes, please define either an ACL file or declare users directly in your configuration file, but not both.")
		linux.exit_group(1)
	}
	for saved in acl_to_load {
		acl_install_declared(saved)
	}
	if cfg.aclfile != "" {
		acl_load_at_startup()
	}
	acl_refresh_all()
}

@(private = "file")
acl_load_at_startup :: proc() {
	problems := acl_file_load(nil)
	if problems == "" {
		return
	}
	plog(LOG_WARNING, "Aborting Eski startup because of ACL errors: ", problems)
	linux.exit_group(1)
}

@(private = "file")
acl_reply_selector :: proc(c: ^Conn, s: ^Acl_Selector) {
	b := make([dynamic]u8, context.temp_allocator)
	reply_bulk_str(c, "commands")
	acl_command_rules_text(&b, s)
	reply_bulk(c, b[:])
	reply_bulk_str(c, "keys")
	if .Keys in s.wildcards {
		reply_bulk_str(c, "~*")
	} else {
		clear(&b)
		for p, i in s.key_patterns {
			if i > 0 {
				sb_byte(&b, ' ')
			}
			acl_pattern_string(&b, p)
		}
		reply_bulk(c, b[:])
	}
	reply_bulk_str(c, "channels")
	if .Channels in s.wildcards {
		reply_bulk_str(c, "&*")
	} else {
		clear(&b)
		for ch, i in s.channel_patterns {
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
	if e := acl_setuser_apply(c, u, username, argv[3:]); e != "" {
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
				acl_evict_conn(other, c)
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
		if f in u.attributes {
			n += 1
		}
	}
	reply_set(c, n)
	for f in Acl_User_Flag {
		if f in u.attributes {
			reply_bulk_str(c, acl_user_flag_names[f])
		}
	}
	reply_bulk_str(c, "passwords")
	reply_array(c, len(u.password_hashes))
	for p in u.password_hashes {
		pw := p
		reply_bulk(c, pw[:])
	}
	acl_reply_selector(c, u.root)
	reply_bulk_str(c, "selectors")
	reply_array(c, len(u.added_selectors))
	for s in u.added_selectors {
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
		sb_bytes(&b, u.username)
		sb_byte(&b, ' ')
		acl_describe_user(&b, u)
		reply_bulk(c, b[:])
	}
}

@(private = "file")
acl_cmd_users :: proc(c: ^Conn, argv: [][]u8) {
	reply_array(c, len(acl_users))
	for u in acl_users {
		reply_bulk(c, u.username)
	}
}

@(private = "file")
acl_cmd_whoami :: proc(c: ^Conn, argv: [][]u8) {
	if c.user == nil {
		reply_null(c)
		return
	}
	reply_bulk(c, c.user.username)
}

@(private = "file")
acl_cmd_load :: proc(c: ^Conn, argv: [][]u8) {
	if cfg.aclfile == "" {
		reply_error(c, ERR_ACL_NO_FILE)
		return
	}
	if e := acl_file_load(c); e != "" {
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
	if !acl_file_save() {
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
		reply_int(c, e.occurrences)
		reply_bulk_str(c, "reason")
		reply_bulk_str(c, acl_reason_names[e.verdict])
		reply_bulk_str(c, "context")
		reply_bulk_str(c, acl_context_names[e.origin])
		reply_bulk_str(c, "object")
		reply_bulk(c, e.object)
		reply_bulk_str(c, "username")
		reply_bulk(c, e.username)
		reply_bulk_str(c, "age-seconds")
		reply_double(c, f64(now - e.last_ms) / 1000)
		reply_bulk_str(c, "client-info")
		reply_bulk(c, e.client_info)
		reply_bulk_str(c, "entry-id")
		reply_int(c, e.entry_id)
		reply_bulk_str(c, "timestamp-created")
		reply_int(c, e.first_ms)
		reply_bulk_str(c, "timestamp-last-updated")
		reply_int(c, e.last_ms)
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
	if res != .Allowed {
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

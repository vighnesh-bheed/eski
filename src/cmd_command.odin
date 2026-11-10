package main

Cmd_Group :: enum u8 {
	Generic,
	String,
	List,
	Set,
	Sorted_Set,
	Hash,
	Pubsub,
	Transactions,
	Connection,
	Server,
	Scripting,
	Hyperloglog,
	Cluster,
	Sentinel,
	Geo,
	Stream,
	Bitmap,
	Module,
}

Acl_Cat :: enum u8 {
	Keyspace,
	Read,
	Write,
	Set,
	Sortedset,
	List,
	Hash,
	String,
	Bitmap,
	Hyperloglog,
	Geo,
	Stream,
	Pubsub,
	Admin,
	Fast,
	Slow,
	Blocking,
	Dangerous,
	Connection,
	Transaction,
	Scripting,
}

Acl_Cats :: bit_set[Acl_Cat;u32]

Doc_Flag :: enum u8 {
	Deprecated,
	Syscmd,
}

Doc_Flags :: bit_set[Doc_Flag;u8]

Arg_Kind :: enum u8 {
	String,
	Integer,
	Double,
	Key,
	Pattern,
	Unix_Time,
	Pure_Token,
	Oneof,
	Block,
}

Arg_Flag :: enum u8 {
	Optional,
	Multiple,
	Multiple_Token,
}

Arg_Flags :: bit_set[Arg_Flag;u8]

Cmd_Arg :: struct {
	name:             string,
	display:          string,
	token:            Maybe(string),
	summary:          string,
	since:            string,
	deprecated_since: string,
	args:             []Cmd_Arg,
	key_spec:         Maybe(u8),
	kind:             Arg_Kind,
	flags:            Arg_Flags,
}

Cmd_History :: struct {
	since:   string,
	changes: string,
}

Cmd_Doc :: struct {
	name:             string,
	summary:          string,
	since:            string,
	complexity:       string,
	deprecated_since: string,
	replaced_by:      string,
	tips:             []string,
	notes:            []string,
	history:          []Cmd_History,
	args:             []Cmd_Arg,
	acl:              Acl_Cats,
	group:            Cmd_Group,
	doc_flags:        Doc_Flags,
	module:           string,
}

#assert(len(cmd_docs) == len(cmd_specs))

Key_Ref :: struct {
	pos:   int,
	flags: Key_Flags,
}

@(private = "file")
Info_Flag :: struct {
	flag: Cmd_Flag,
	name: string,
}

@(private = "file")
info_flags := [?]Info_Flag {
	{.Write, "write"},
	{.Readonly, "readonly"},
	{.Denyoom, "denyoom"},
	{.Module, "module"},
	{.Admin, "admin"},
	{.Pubsub, "pubsub"},
	{.Noscript, "noscript"},
	{.Blocking, "blocking"},
	{.Loading, "loading"},
	{.Stale, "stale"},
	{.Skip_Monitor, "skip_monitor"},
	{.Skip_Slowlog, "skip_slowlog"},
	{.Asking, "asking"},
	{.Fast, "fast"},
	{.No_Auth, "no_auth"},
	{.No_Mandatory_Keys, "no_mandatory_keys"},
	{.No_Async_Loading, "no_async_loading"},
	{.No_Multi, "no_multi"},
}

@(private = "file")
group_names := [Cmd_Group]string {
	.Generic      = "generic",
	.String       = "string",
	.List         = "list",
	.Set          = "set",
	.Sorted_Set   = "sorted-set",
	.Hash         = "hash",
	.Pubsub       = "pubsub",
	.Transactions = "transactions",
	.Connection   = "connection",
	.Server       = "server",
	.Scripting    = "scripting",
	.Hyperloglog  = "hyperloglog",
	.Cluster      = "cluster",
	.Sentinel     = "sentinel",
	.Geo          = "geo",
	.Stream       = "stream",
	.Bitmap       = "bitmap",
	.Module       = "module",
}

acl_names := [Acl_Cat]string {
	.Keyspace    = "@keyspace",
	.Read        = "@read",
	.Write       = "@write",
	.Set         = "@set",
	.Sortedset   = "@sortedset",
	.List        = "@list",
	.Hash        = "@hash",
	.String      = "@string",
	.Bitmap      = "@bitmap",
	.Hyperloglog = "@hyperloglog",
	.Geo         = "@geo",
	.Stream      = "@stream",
	.Pubsub      = "@pubsub",
	.Admin       = "@admin",
	.Fast        = "@fast",
	.Slow        = "@slow",
	.Blocking    = "@blocking",
	.Dangerous   = "@dangerous",
	.Connection  = "@connection",
	.Transaction = "@transaction",
	.Scripting   = "@scripting",
}

@(private = "file")
key_flag_names := [Key_Flag]string {
	.Ro             = "RO",
	.Rw             = "RW",
	.Ow             = "OW",
	.Rm             = "RM",
	.Access         = "access",
	.Update         = "update",
	.Insert         = "insert",
	.Delete         = "delete",
	.Not_Key        = "not_key",
	.Incomplete     = "incomplete",
	.Variable_Flags = "variable_flags",
}

@(private = "file")
arg_kind_names := [Arg_Kind]string {
	.String     = "string",
	.Integer    = "integer",
	.Double     = "double",
	.Key        = "key",
	.Pattern    = "pattern",
	.Unix_Time  = "unix-time",
	.Pure_Token = "pure-token",
	.Oneof      = "oneof",
	.Block      = "block",
}

@(private = "file")
arg_flag_names := [Arg_Flag]string {
	.Optional       = "optional",
	.Multiple       = "multiple",
	.Multiple_Token = "multiple_token",
}

@(private = "file")
doc_flag_names := [Doc_Flag]string {
	.Deprecated = "deprecated",
	.Syscmd     = "syscmd",
}

@(private = "file")
command_help_lines := [?]string {
	"COMMAND <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"(no subcommand)",
	"    Return details about all commands.",
	"COUNT",
	"    Return the total number of commands in this server.",
	"LIST",
	"    Return a list of all commands in this server.",
	"INFO [<command-name> ...]",
	"    Return details about multiple commands.",
	"    If no command names are given, documentation details for all",
	"    commands are returned.",
	"DOCS [<command-name> ...]",
	"    Return documentation details about multiple commands.",
	"    If no command names are given, documentation details for all",
	"    commands are returned.",
	"GETKEYS <full-command>",
	"    Return the keys from a full command.",
	"GETKEYSANDFLAGS <full-command>",
	"    Return the keys and the access flags from a full command.",
	"HELP",
	"    Print this help.",
}

@(private = "file")
Command_Sub :: struct {
	name:    string,
	full:    string,
	arity:   int,
	handler: Command_Proc,
}

@(private = "file")
command_subs := [?]Command_Sub {
	{"count", "command|count", 2, command_count},
	{"docs", "command|docs", -2, command_docs},
	{"getkeys", "command|getkeys", -3, command_getkeys},
	{"getkeysandflags", "command|getkeysandflags", -3, command_getkeysandflags},
	{"help", "command|help", 2, command_help},
	{"info", "command|info", -2, command_info},
	{"list", "command|list", -2, command_list},
}

@(private = "file")
Found :: struct {
	cmd: ^Command,
	doc: int,
}

@(private = "file")
List_Filter :: enum u8 {
	None,
	Module,
	Aclcat,
	Pattern,
}

@(private = "file")
getkeys_out: [dynamic]Key_Ref

@(private = "file")
doc_lower_bound :: proc(key: string) -> int {
	lo, hi := 0, len(cmd_docs)
	for lo < hi {
		mid := (lo + hi) / 2
		if cmd_docs[mid].name < key {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private = "file")
doc_find :: proc(name: string) -> int {
	i := doc_lower_bound(name)
	if i < len(cmd_docs) && cmd_docs[i].name == name {
		return i
	}
	return -1
}

@(private = "file")
doc_subs :: proc(i: int) -> (lo: int, hi: int) {
	buf: [64]u8
	name := cmd_docs[i].name
	if len(name) + 1 > len(buf) {
		return i, i
	}
	n := copy(buf[:], name)
	buf[n] = '|'
	prefix := string(buf[:n + 1])
	lo = doc_lower_bound(prefix)
	hi = lo
	for hi < len(cmd_docs) && len(cmd_docs[hi].name) > len(prefix) && cmd_docs[hi].name[:len(prefix)] == prefix {
		hi += 1
	}
	return
}

@(private = "file")
doc_container :: proc(i: int) -> bool {
	lo, hi := doc_subs(i)
	return lo < hi
}

@(private = "file")
doc_sub_find :: proc(parent: int, sub: []u8) -> int {
	buf: [64]u8
	name := cmd_docs[parent].name
	if len(name) + 1 + len(sub) > len(buf) {
		return -1
	}
	n := copy(buf[:], name)
	buf[n] = '|'
	n += 1
	for b in sub {
		buf[n] = lower(b)
		n += 1
	}
	return doc_find(string(buf[:n]))
}

@(private = "file")
doc_spec :: proc(i: int) -> ^Cmd_Spec {
	if cmd_specs[i].name == cmd_docs[i].name {
		return &cmd_specs[i]
	}
	return nil
}

@(private = "file")
lookup_by_name :: proc(name: []u8) -> Found {
	bar := -1
	for b, j in name {
		if b == '|' {
			if bar >= 0 {
				return {nil, -1}
			}
			bar = j
		}
	}
	if bar < 0 {
		cmd := lookup_command(name)
		if cmd == nil {
			return {nil, -1}
		}
		return {cmd, doc_find(cmd.name)}
	}
	cmd := lookup_command(name[:bar])
	if cmd == nil {
		return {nil, -1}
	}
	parent := doc_find(cmd.name)
	if parent < 0 || !doc_container(parent) {
		return {nil, -1}
	}
	i := doc_sub_find(parent, name[bar + 1:])
	if i < 0 {
		return {nil, -1}
	}
	return {cmd, i}
}

@(private = "file")
lookup_by_argv :: proc(args: [][]u8) -> int {
	cmd := lookup_command(args[0])
	if cmd == nil {
		return -1
	}
	i := doc_find(cmd.name)
	if i < 0 || len(args) == 1 || !doc_container(i) {
		return i
	}
	return doc_sub_find(i, args[1])
}

@(private = "file")
spec_movable :: proc(s: ^Cmd_Spec) -> bool {
	if len(s.specs) == 0 {
		return false
	}
	if len(s.specs) == 1 && s.specs[0].search == .Index && s.specs[0].find == .Range {
		return .Incomplete in s.specs[0].flags
	}
	movable := false
	found := false
	last_key: i32 = 0
	prev_last: i32 = 0
	for &k in s.specs {
		if k.search != .Index || k.find != .Range {
			movable = true
			continue
		}
		if k.b != 1 || (prev_last != 0 && prev_last != k.pos - 1) {
			movable = true
			continue
		}
		if .Incomplete in k.flags {
			movable = true
		}
		found = true
		abs_last := k.a
		if abs_last >= 0 {
			abs_last += k.pos
		}
		last_key = i32(max(u32(last_key), u32(abs_last)))
		prev_last = last_key
	}
	return movable || !found
}

@(private = "file")
reply_key_flags :: proc(c: ^Conn, flags: Key_Flags) {
	reply_set(c, card(flags))
	for f in Key_Flag {
		if f in flags {
			reply_simple(c, key_flag_names[f])
		}
	}
}

@(private = "file")
reply_info_flags :: proc(c: ^Conn, s: ^Cmd_Spec) {
	movable := spec_movable(s)
	n := 0
	for f in info_flags {
		if f.flag in s.flags {
			n += 1
		}
	}
	if movable {
		n += 1
	}
	if .Allow_Busy in s.flags {
		n += 1
	}
	reply_set(c, n)
	for f in info_flags {
		if f.flag in s.flags {
			reply_simple(c, f.name)
		}
	}
	if movable {
		reply_simple(c, "movablekeys")
	}
	if .Allow_Busy in s.flags {
		reply_simple(c, "allow_busy")
	}
}

@(private = "file")
reply_key_specs :: proc(c: ^Conn, d: ^Cmd_Doc, s: ^Cmd_Spec) {
	reply_set(c, len(s.specs))
	for &k, j in s.specs {
		note := d.notes[j] if j < len(d.notes) else ""
		reply_map(c, 4 if note != "" else 3)
		if note != "" {
			reply_bulk_str(c, "notes")
			reply_bulk_str(c, note)
		}
		reply_bulk_str(c, "flags")
		reply_key_flags(c, k.flags)
		reply_bulk_str(c, "begin_search")
		reply_map(c, 2)
		reply_bulk_str(c, "type")
		switch k.search {
		case .Index:
			reply_bulk_str(c, "index")
			reply_bulk_str(c, "spec")
			reply_map(c, 1)
			reply_bulk_str(c, "index")
			reply_int(c, i64(k.pos))
		case .Keyword:
			reply_bulk_str(c, "keyword")
			reply_bulk_str(c, "spec")
			reply_map(c, 2)
			reply_bulk_str(c, "keyword")
			reply_bulk_str(c, k.keyword)
			reply_bulk_str(c, "startfrom")
			reply_int(c, i64(k.from))
		case .Unknown:
			reply_bulk_str(c, "unknown")
			reply_bulk_str(c, "spec")
			reply_map(c, 0)
		}
		reply_bulk_str(c, "find_keys")
		reply_map(c, 2)
		reply_bulk_str(c, "type")
		switch k.find {
		case .Range:
			reply_bulk_str(c, "range")
			reply_bulk_str(c, "spec")
			reply_map(c, 3)
			reply_bulk_str(c, "lastkey")
			reply_int(c, i64(k.a))
			reply_bulk_str(c, "keystep")
			reply_int(c, i64(k.b))
			reply_bulk_str(c, "limit")
			reply_int(c, i64(k.c))
		case .Keynum:
			reply_bulk_str(c, "keynum")
			reply_bulk_str(c, "spec")
			reply_map(c, 3)
			reply_bulk_str(c, "keynumidx")
			reply_int(c, i64(k.a))
			reply_bulk_str(c, "firstkey")
			reply_int(c, i64(k.b))
			reply_bulk_str(c, "keystep")
			reply_int(c, i64(k.c))
		case .Unknown:
			reply_bulk_str(c, "unknown")
			reply_bulk_str(c, "spec")
			reply_map(c, 0)
		}
	}
}

@(private = "file")
reply_info :: proc(c: ^Conn, i: int) {
	d := &cmd_docs[i]
	s := doc_spec(i)
	reply_array(c, 10)
	reply_bulk_str(c, d.name)
	if s == nil {
		reply_int(c, 0)
		reply_set(c, 0)
		reply_int(c, 0)
		reply_int(c, 0)
		reply_int(c, 0)
	} else {
		reply_int(c, i64(s.arity))
		reply_info_flags(c, s)
		last := s.last
		if last >= 0 {
			last += s.first
		}
		reply_int(c, i64(s.first))
		reply_int(c, i64(last))
		reply_int(c, i64(s.step))
	}
	reply_set(c, card(d.acl))
	for cat in Acl_Cat {
		if cat in d.acl {
			reply_simple(c, acl_names[cat])
		}
	}
	reply_set(c, len(d.tips))
	for tip in d.tips {
		reply_bulk_str(c, tip)
	}
	if s == nil {
		reply_set(c, 0)
	} else {
		reply_key_specs(c, d, s)
	}
	lo, hi := doc_subs(i)
	if lo == hi {
		reply_set(c, 0)
		return
	}
	reply_array(c, hi - lo)
	for j in lo ..< hi {
		reply_info(c, j)
	}
}

@(private = "file")
reply_info_bare :: proc(c: ^Conn, cmd: ^Command) {
	reply_array(c, 10)
	reply_bulk_str(c, cmd.name)
	reply_int(c, i64(cmd.arity))
	reply_set(c, 0)
	reply_int(c, 0)
	reply_int(c, 0)
	reply_int(c, 0)
	reply_set(c, 0)
	reply_set(c, 0)
	reply_set(c, 0)
	reply_set(c, 0)
}

@(private = "file")
reply_found_info :: proc(c: ^Conn, f: Found) {
	if f.doc >= 0 {
		reply_info(c, f.doc)
	} else if f.cmd != nil {
		reply_info_bare(c, f.cmd)
	} else {
		reply_null(c)
	}
}

@(private = "file")
reply_args :: proc(c: ^Conn, args: []Cmd_Arg) {
	reply_array(c, len(args))
	for &a in args {
		nested := a.kind == .Oneof || a.kind == .Block
		key_spec, has_key_spec := a.key_spec.?
		token, has_token := a.token.?
		n := 2
		if !nested {
			n += 1
		}
		if has_key_spec {
			n += 1
		}
		if has_token {
			n += 1
		}
		if a.summary != "" {
			n += 1
		}
		if a.since != "" {
			n += 1
		}
		if a.deprecated_since != "" {
			n += 1
		}
		if a.flags != {} {
			n += 1
		}
		if nested {
			n += 1
		}
		reply_map(c, n)
		reply_bulk_str(c, "name")
		reply_bulk_str(c, a.name)
		reply_bulk_str(c, "type")
		reply_bulk_str(c, arg_kind_names[a.kind])
		if !nested {
			reply_bulk_str(c, "display_text")
			reply_bulk_str(c, a.display if a.display != "" else a.name)
		}
		if has_key_spec {
			reply_bulk_str(c, "key_spec_index")
			reply_int(c, i64(key_spec))
		}
		if has_token {
			reply_bulk_str(c, "token")
			reply_bulk_str(c, token)
		}
		if a.summary != "" {
			reply_bulk_str(c, "summary")
			reply_bulk_str(c, a.summary)
		}
		if a.since != "" {
			reply_bulk_str(c, "since")
			reply_bulk_str(c, a.since)
		}
		if a.deprecated_since != "" {
			reply_bulk_str(c, "deprecated_since")
			reply_bulk_str(c, a.deprecated_since)
		}
		if a.flags != {} {
			reply_bulk_str(c, "flags")
			reply_set(c, card(a.flags))
			for f in Arg_Flag {
				if f in a.flags {
					reply_simple(c, arg_flag_names[f])
				}
			}
		}
		if nested {
			reply_bulk_str(c, "arguments")
			reply_args(c, a.args)
		}
	}
}

@(private = "file")
reply_docs :: proc(c: ^Conn, i: int) {
	d := &cmd_docs[i]
	lo, hi := doc_subs(i)
	n := 1
	if d.summary != "" {
		n += 1
	}
	if d.since != "" {
		n += 1
	}
	if d.complexity != "" {
		n += 1
	}
	if d.module != "" {
		n += 1
	}
	if d.doc_flags != {} {
		n += 1
	}
	if d.deprecated_since != "" {
		n += 1
	}
	if d.replaced_by != "" {
		n += 1
	}
	if len(d.history) > 0 {
		n += 1
	}
	if len(d.args) > 0 {
		n += 1
	}
	if lo < hi {
		n += 1
	}
	reply_map(c, n)
	if d.summary != "" {
		reply_bulk_str(c, "summary")
		reply_bulk_str(c, d.summary)
	}
	if d.since != "" {
		reply_bulk_str(c, "since")
		reply_bulk_str(c, d.since)
	}
	reply_bulk_str(c, "group")
	reply_bulk_str(c, group_names[d.group])
	if d.module != "" {
		reply_bulk_str(c, "module")
		reply_bulk_str(c, d.module)
	}
	if d.complexity != "" {
		reply_bulk_str(c, "complexity")
		reply_bulk_str(c, d.complexity)
	}
	if d.doc_flags != {} {
		reply_bulk_str(c, "doc_flags")
		reply_set(c, card(d.doc_flags))
		for f in Doc_Flag {
			if f in d.doc_flags {
				reply_simple(c, doc_flag_names[f])
			}
		}
	}
	if d.deprecated_since != "" {
		reply_bulk_str(c, "deprecated_since")
		reply_bulk_str(c, d.deprecated_since)
	}
	if d.replaced_by != "" {
		reply_bulk_str(c, "replaced_by")
		reply_bulk_str(c, d.replaced_by)
	}
	if len(d.history) > 0 {
		reply_bulk_str(c, "history")
		reply_set(c, len(d.history))
		for h in d.history {
			reply_array(c, 2)
			reply_bulk_str(c, h.since)
			reply_bulk_str(c, h.changes)
		}
	}
	if len(d.args) > 0 {
		reply_bulk_str(c, "arguments")
		reply_args(c, d.args)
	}
	if lo < hi {
		reply_bulk_str(c, "subcommands")
		reply_map(c, hi - lo)
		for j in lo ..< hi {
			reply_bulk_str(c, cmd_docs[j].name)
			reply_docs(c, j)
		}
	}
}

@(private = "file")
reply_found_docs :: proc(c: ^Conn, f: Found) {
	if f.doc >= 0 {
		reply_bulk_str(c, cmd_docs[f.doc].name)
		reply_docs(c, f.doc)
		return
	}
	reply_bulk_str(c, f.cmd.name)
	reply_map(c, 1)
	reply_bulk_str(c, "group")
	reply_bulk_str(c, group_names[.Generic])
}

@(private = "file")
reply_all_info :: proc(c: ^Conn) {
	reply_array(c, cmd_count)
	for &slot in cmd_table {
		if slot.cmd != nil {
			reply_found_info(c, {slot.cmd, doc_find(slot.cmd.name)})
		}
	}
}

cmd_command :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) == 1 {
		reply_all_info(c)
		return
	}
	sub := argv[1]
	for &s in command_subs {
		if eq_nocase(sub, s.name) {
			c.last_cmd = s.full
			if !arity_ok(s.arity, len(argv)) {
				reply_wrong_args(c, s.full)
				return
			}
			s.handler(c, argv)
			return
		}
	}
	command_unknown(c, sub)
}

@(cold)
@(private = "file")
command_unknown :: #force_no_inline proc(c: ^Conn, sub: []u8) {
	c.last_cmd = "NULL"
	reply_unknown_subcommand(c, sub, "COMMAND")
}

@(private = "file")
command_count :: proc(c: ^Conn, argv: [][]u8) {
	reply_int(c, i64(cmd_count))
}

@(private = "file")
command_help :: proc(c: ^Conn, argv: [][]u8) {
	reply_array(c, len(command_help_lines))
	for line in command_help_lines {
		reply_simple(c, line)
	}
}

@(private = "file")
command_info :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) == 2 {
		reply_all_info(c)
		return
	}
	reply_array(c, len(argv) - 2)
	for name in argv[2:] {
		reply_found_info(c, lookup_by_name(name))
	}
}

@(private = "file")
command_docs :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) == 2 {
		reply_map(c, cmd_count)
		for &slot in cmd_table {
			if slot.cmd != nil {
				reply_found_docs(c, {slot.cmd, doc_find(slot.cmd.name)})
			}
		}
		return
	}
	n := 0
	for name in argv[2:] {
		if lookup_by_name(name).cmd != nil {
			n += 1
		}
	}
	reply_map(c, n)
	for name in argv[2:] {
		if f := lookup_by_name(name); f.cmd != nil {
			reply_found_docs(c, f)
		}
	}
}

acl_cat_by_name :: proc(name: []u8) -> (Acl_Cat, bool) {
	for cat in Acl_Cat {
		if eq_nocase(name, acl_names[cat][1:]) {
			return cat, true
		}
	}
	return .Keyspace, false
}

@(private = "file")
list_match :: proc(filter: List_Filter, arg: []u8, name: string, acl: Acl_Cats, module: string = "") -> bool {
	switch filter {
	case .None:
		return true
	case .Module:
		return module != "" && eq_nocase(arg, module)
	case .Aclcat:
		cat, ok := acl_cat_by_name(arg)
		return ok && cat in acl
	case .Pattern:
		return glob_match(arg, transmute([]u8)name, true)
	}
	return false
}

@(private = "file")
list_walk :: proc(c: ^Conn, filter: List_Filter, arg: []u8, emit: bool) -> int {
	n := 0
	for &slot in cmd_table {
		if slot.cmd == nil {
			continue
		}
		i := doc_find(slot.cmd.name)
		if i < 0 {
			if list_match(filter, arg, slot.cmd.name, {}) {
				n += 1
				if emit {
					reply_bulk_str(c, slot.cmd.name)
				}
			}
			continue
		}
		lo, hi := doc_subs(i)
		if list_match(filter, arg, cmd_docs[i].name, cmd_docs[i].acl, cmd_docs[i].module) {
			n += 1
			if emit {
				reply_bulk_str(c, cmd_docs[i].name)
			}
		}
		for j in lo ..< hi {
			if list_match(filter, arg, cmd_docs[j].name, cmd_docs[j].acl, cmd_docs[j].module) {
				n += 1
				if emit {
					reply_bulk_str(c, cmd_docs[j].name)
				}
			}
		}
	}
	return n
}

@(private = "file")
command_list :: proc(c: ^Conn, argv: [][]u8) {
	filter := List_Filter.None
	arg: []u8
	for i := 2; i < len(argv); i += 3 {
		if !eq_nocase(argv[i], "filterby") || len(argv) - 1 - i != 2 {
			reply_error(c, ERR_SYNTAX)
			return
		}
		kind := argv[i + 1]
		switch {
		case eq_nocase(kind, "module"):
			filter = .Module
		case eq_nocase(kind, "aclcat"):
			filter = .Aclcat
		case eq_nocase(kind, "pattern"):
			filter = .Pattern
		case:
			reply_error(c, ERR_SYNTAX)
			return
		}
		arg = argv[i + 2]
	}
	reply_array(c, list_walk(c, filter, arg, false))
	list_walk(c, filter, arg, true)
}

spec_has_keys :: proc(s: ^Cmd_Spec) -> bool {
	if s.getkeys != .None {
		return true
	}
	for &k in s.specs {
		if .Not_Key not_in k.flags {
			return true
		}
	}
	return false
}

@(private = "file")
keys_from_specs :: proc(s: ^Cmd_Spec, argv: [][]u8, out: ^[dynamic]Key_Ref) -> bool {
	argc := len(argv)
	for &k in s.specs {
		if .Not_Key in k.flags {
			continue
		}
		first := 0
		switch k.search {
		case .Index:
			first = int(k.pos)
		case .Keyword:
			from := int(k.from)
			start := from if from > 0 else argc + from
			end := argc - 1 if from > 0 else 1
			for i := start; i != end; i = i + 1 if start <= end else i - 1 {
				if i >= argc || i < 1 {
					break
				}
				if eq_fold(argv[i], transmute([]u8)k.keyword) {
					first = i + 1
					break
				}
			}
			if first == 0 {
				continue
			}
		case .Unknown:
			return false
		}
		last, step: int
		switch k.find {
		case .Range:
			step = int(k.b)
			if k.a >= 0 {
				last = first + int(k.a)
			} else if k.c == 0 {
				last = argc + int(k.a)
			} else {
				last = first + ((argc - first) / int(k.c) + int(k.a))
			}
		case .Keynum:
			step = int(k.c)
			at := first + int(k.a)
			if at >= argc {
				return false
			}
			numkeys, ok := parse_i64(argv[at])
			if !ok || numkeys < 0 || numkeys > i64(argc) {
				return false
			}
			first += int(k.b)
			last = first + int(numkeys) - 1
		case .Unknown:
			return false
		}
		if last >= argc || last < first || first >= argc {
			return false
		}
		for i := first; i <= last; i += max(step, 1) {
			append(out, Key_Ref{i, k.flags})
		}
		if .Incomplete in k.flags {
			return false
		}
	}
	return true
}

@(private = "file")
c_int_atoi :: proc(s: []u8) -> int {
	i := 0
	for i < len(s) && (s[i] == ' ' || (s[i] >= '\t' && s[i] <= '\r')) {
		i += 1
	}
	neg := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		neg = s[i] == '-'
		i += 1
	}
	v: u64 = 0
	limit: u64 = u64(I64_MAX) + 1 if neg else u64(I64_MAX)
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		d := u64(s[i] - '0')
		if v > (limit - d) / 10 {
			v = limit
			for i < len(s) && s[i] >= '0' && s[i] <= '9' {
				i += 1
			}
			break
		}
		v = v * 10 + d
		i += 1
	}
	r := cast(i64)(0 - v) if neg else i64(v)
	return int(i32(r))
}

@(private = "file")
keys_generic :: proc(store, count, first, step: int, argv: [][]u8, out: ^[dynamic]Key_Ref) {
	argc := len(argv)
	if count >= argc {
		return
	}
	num := c_int_atoi(argv[count])
	if num < 1 || num > (argc - first) / step {
		return
	}
	for i in 0 ..< num {
		append(out, Key_Ref{first + i * step, {}})
	}
	if store != 0 {
		append(out, Key_Ref{store, {}})
	}
}

@(private = "file")
keys_from_proc :: proc(p: Getkeys_Proc, argv: [][]u8, out: ^[dynamic]Key_Ref) {
	argc := len(argv)
	switch p {
	case .None:
	case .Sintercard, .Zunion_Inter_Diff, .Lmpop, .Zmpop:
		keys_generic(0, 1, 2, 1, argv, out)
	case .Zunion_Inter_Diff_Store:
		keys_generic(1, 2, 3, 1, argv, out)
	case .Eval, .Function, .Blmpop:
		keys_generic(0, 2, 3, 1, argv, out)
	case .Sort_Ro:
		append(out, Key_Ref{1, {.Ro, .Access}})
	case .Sort:
		append(out, Key_Ref{1, {.Ro, .Access}})
		store := -1
		skips := [?]struct {
			name: string,
			skip: int,
		}{{"limit", 2}, {"get", 1}, {"by", 1}}
		for i := 2; i < argc; i += 1 {
			for s in skips {
				if eq_nocase(argv[i], s.name) {
					i += s.skip
					break
				} else if eq_nocase(argv[i], "store") && i + 1 < argc {
					store = i + 1
					i += 1
					break
				}
			}
		}
		if store >= 0 {
			append(out, Key_Ref{store, {.Ow, .Update}})
		}
	case .Migrate:
		first, num := 3, 1
		if argc > 6 {
			scan: for i := 6; i < argc; i += 1 {
				switch {
				case eq_nocase(argv[i], "keys"):
					if len(argv[3]) > 0 {
						num = 0
					} else {
						first = i + 1
						num = argc - first
					}
					break scan
				case eq_nocase(argv[i], "auth"):
					i += 1
				case eq_nocase(argv[i], "auth2"):
					i += 2
				}
			}
		}
		for i in 0 ..< num {
			append(out, Key_Ref{first + i, {.Rw, .Access, .Delete}})
		}
	case .Georadius:
		append(out, Key_Ref{1, {.Ro, .Access}})
		stored := -1
		for i := 5; i < argc; i += 1 {
			if (eq_nocase(argv[i], "store") || eq_nocase(argv[i], "storedist")) && i + 1 < argc {
				stored = i + 1
				i += 1
			}
		}
		if stored >= 0 {
			append(out, Key_Ref{stored, {.Ow, .Update}})
		}
	case .Xread:
		streams := -1
		scan_x: for i := 1; i < argc; i += 1 {
			switch {
			case eq_nocase(argv[i], "block"), eq_nocase(argv[i], "count"):
				i += 1
			case eq_nocase(argv[i], "group"):
				i += 2
			case eq_nocase(argv[i], "noack"):
			case eq_nocase(argv[i], "streams"):
				streams = i
				break scan_x
			case:
				break scan_x
			}
		}
		if streams < 0 {
			return
		}
		num := argc - streams - 1
		if num == 0 || num % 2 != 0 {
			return
		}
		num /= 2
		for i in streams + 1 ..< argc - num {
			append(out, Key_Ref{i, {.Ro, .Access}})
		}
	case .Set:
		for i in 3 ..< argc {
			if eq_nocase(argv[i], "get") {
				append(out, Key_Ref{1, {.Rw, .Access, .Update}})
				return
			}
		}
		append(out, Key_Ref{1, {.Ow, .Update}})
	case .Bitfield:
		readonly := true
		for i := 2; i < argc; i += 1 {
			remaining := argc - i - 1
			switch {
			case eq_nocase(argv[i], "get") && remaining >= 2:
				i += 2
				continue
			case (eq_nocase(argv[i], "set") || eq_nocase(argv[i], "incrby")) && remaining >= 3:
				readonly = false
			case eq_nocase(argv[i], "overflow") && remaining >= 1:
				i += 1
				continue
			case:
				readonly = false
			}
			break
		}
		if readonly {
			append(out, Key_Ref{1, {.Ro, .Access}})
		} else {
			append(out, Key_Ref{1, {.Rw, .Access, .Update}})
		}
	}
}

find_keys :: proc(s: ^Cmd_Spec, argv: [][]u8, out: ^[dynamic]Key_Ref) {
	clear(out)
	any_key_spec, varying_flags := false, false
	for &k in s.specs {
		if .Not_Key not_in k.flags {
			any_key_spec = true
		}
		if .Variable_Flags in k.flags {
			varying_flags = true
		}
	}
	if any_key_spec && !varying_flags {
		if keys_from_specs(s, argv, out) {
			return
		}
		clear(out)
	}
	keys_from_proc(s.getkeys, argv, out)
}

@(private = "file")
getkeys_reply :: proc(c: ^Conn, argv: [][]u8, with_flags: bool) {
	args := argv[2:]
	i := lookup_by_argv(args)
	if i < 0 {
		getkeys_error(c, "ERR Invalid command specified")
		return
	}
	s := doc_spec(i)
	if s == nil || !spec_has_keys(s) {
		getkeys_error(c, "ERR The command has no key arguments")
		return
	}
	n := len(args)
	if (s.arity > 0 && int(s.arity) != n) || n < -int(s.arity) {
		getkeys_error(c, "ERR Invalid number of arguments specified for command")
		return
	}
	find_keys(s, args, &getkeys_out)
	if len(getkeys_out) == 0 {
		if .No_Mandatory_Keys in s.flags {
			reply_array(c, 0)
		} else {
			getkeys_error(c, "ERR Invalid arguments specified for command")
		}
		return
	}
	reply_array(c, len(getkeys_out))
	for k in getkeys_out {
		if with_flags {
			reply_array(c, 2)
			reply_bulk(c, args[k.pos])
			reply_key_flags(c, k.flags)
		} else {
			reply_bulk(c, args[k.pos])
		}
	}
}

@(cold)
@(private = "file")
getkeys_error :: #force_no_inline proc(c: ^Conn, msg: string) {
	reply_error(c, msg)
}

@(private = "file")
command_getkeys :: proc(c: ^Conn, argv: [][]u8) {
	getkeys_reply(c, argv, false)
}

@(private = "file")
command_getkeysandflags :: proc(c: ^Conn, argv: [][]u8) {
	getkeys_reply(c, argv, true)
}

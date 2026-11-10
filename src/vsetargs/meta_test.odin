package vsetargs

import "core:fmt"
import "core:strings"
import "core:testing"

Info_Flag_Name :: struct {
	flag: Cmd_Flag,
	name: string,
}

@(rodata)
INFO_FLAG_ORDER := [?]Info_Flag_Name {
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

@(rodata)
GROUP_TEXT := [Cmd_Group]string {
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

@(rodata)
KEY_FLAG_TEXT := [Key_Flag]string {
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

@(rodata)
ARG_KIND_TEXT := [Arg_Kind]string {
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

@(rodata)
ARG_FLAG_TEXT := [Arg_Flag]string {
	.Optional       = "optional",
	.Multiple       = "multiple",
	.Multiple_Token = "multiple_token",
}

Resp_Writer :: struct {
	b:     strings.Builder,
	proto: int,
}

resp_aggregate :: proc(w: ^Resp_Writer, prefix: u8, n: int) {
	fmt.sbprintf(&w.b, "%c%d\r\n", prefix, n)
}

resp_array :: proc(w: ^Resp_Writer, n: int) {
	resp_aggregate(w, '*', n)
}

resp_set :: proc(w: ^Resp_Writer, n: int) {
	resp_aggregate(w, '~' if w.proto == 3 else '*', n)
}

resp_map :: proc(w: ^Resp_Writer, n: int) {
	if w.proto == 3 {
		resp_aggregate(w, '%', n)
	} else {
		resp_aggregate(w, '*', 2 * n)
	}
}

resp_bulk :: proc(w: ^Resp_Writer, s: string) {
	fmt.sbprintf(&w.b, "$%d\r\n%s\r\n", len(s), s)
}

resp_simple :: proc(w: ^Resp_Writer, s: string) {
	fmt.sbprintf(&w.b, "+%s\r\n", s)
}

resp_int :: proc(w: ^Resp_Writer, v: i64) {
	fmt.sbprintf(&w.b, ":%d\r\n", v)
}

write_info :: proc(w: ^Resp_Writer, cmd: Command) {
	s := &COMMAND_SPECS[cmd]
	d := &COMMAND_DOCS[cmd]
	resp_array(w, 10)
	resp_bulk(w, s.name)
	resp_int(w, i64(s.arity))
	n := 0
	for f in INFO_FLAG_ORDER {
		if f.flag in s.flags {
			n += 1
		}
	}
	resp_set(w, n)
	for f in INFO_FLAG_ORDER {
		if f.flag in s.flags {
			resp_simple(w, f.name)
		}
	}
	last := s.last
	if last >= 0 {
		last += s.first
	}
	resp_int(w, i64(s.first))
	resp_int(w, i64(last))
	resp_int(w, i64(s.step))
	resp_set(w, card(d.acl))
	resp_set(w, len(d.tips))
	for tip in d.tips {
		resp_bulk(w, tip)
	}
	resp_set(w, len(s.specs))
	for &k in s.specs {
		resp_map(w, 3)
		resp_bulk(w, "flags")
		resp_set(w, card(k.flags))
		for f in Key_Flag {
			if f in k.flags {
				resp_simple(w, KEY_FLAG_TEXT[f])
			}
		}
		resp_bulk(w, "begin_search")
		resp_map(w, 2)
		resp_bulk(w, "type")
		resp_bulk(w, "index")
		resp_bulk(w, "spec")
		resp_map(w, 1)
		resp_bulk(w, "index")
		resp_int(w, i64(k.pos))
		resp_bulk(w, "find_keys")
		resp_map(w, 2)
		resp_bulk(w, "type")
		resp_bulk(w, "range")
		resp_bulk(w, "spec")
		resp_map(w, 3)
		resp_bulk(w, "lastkey")
		resp_int(w, i64(k.a))
		resp_bulk(w, "keystep")
		resp_int(w, i64(k.b))
		resp_bulk(w, "limit")
		resp_int(w, i64(k.c))
	}
	resp_set(w, 0)
}

write_args :: proc(w: ^Resp_Writer, args: []Cmd_Arg) {
	resp_array(w, len(args))
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
		resp_map(w, n)
		resp_bulk(w, "name")
		resp_bulk(w, a.name)
		resp_bulk(w, "type")
		resp_bulk(w, ARG_KIND_TEXT[a.kind])
		if !nested {
			resp_bulk(w, "display_text")
			resp_bulk(w, a.display if a.display != "" else a.name)
		}
		if has_key_spec {
			resp_bulk(w, "key_spec_index")
			resp_int(w, i64(key_spec))
		}
		if has_token {
			resp_bulk(w, "token")
			resp_bulk(w, token)
		}
		if a.summary != "" {
			resp_bulk(w, "summary")
			resp_bulk(w, a.summary)
		}
		if a.since != "" {
			resp_bulk(w, "since")
			resp_bulk(w, a.since)
		}
		if a.deprecated_since != "" {
			resp_bulk(w, "deprecated_since")
			resp_bulk(w, a.deprecated_since)
		}
		if a.flags != {} {
			resp_bulk(w, "flags")
			resp_set(w, card(a.flags))
			for f in Arg_Flag {
				if f in a.flags {
					resp_simple(w, ARG_FLAG_TEXT[f])
				}
			}
		}
		if nested {
			resp_bulk(w, "arguments")
			write_args(w, a.args)
		}
	}
}

write_docs :: proc(w: ^Resp_Writer, cmd: Command) {
	d := &COMMAND_DOCS[cmd]
	n := 1
	if d.since != "" {
		n += 1
	}
	if d.complexity != "" {
		n += 1
	}
	if d.module != "" {
		n += 1
	}
	if len(d.args) > 0 {
		n += 1
	}
	resp_map(w, n)
	if d.since != "" {
		resp_bulk(w, "since")
		resp_bulk(w, d.since)
	}
	resp_bulk(w, "group")
	resp_bulk(w, GROUP_TEXT[d.group])
	if d.complexity != "" {
		resp_bulk(w, "complexity")
		resp_bulk(w, d.complexity)
	}
	if d.module != "" {
		resp_bulk(w, "module")
		resp_bulk(w, d.module)
	}
	if len(d.args) > 0 {
		resp_bulk(w, "arguments")
		write_args(w, d.args)
	}
}

render_introspection :: proc(kind: Introspection_Kind, cmd: Command, proto: int) -> string {
	w := Resp_Writer{b = strings.builder_make(context.temp_allocator), proto = proto}
	switch kind {
	case .Info:
		resp_array(&w, 1)
		write_info(&w, cmd)
	case .Docs:
		resp_map(&w, 1)
		resp_bulk(&w, COMMAND_DOCS[cmd].name)
		write_docs(&w, cmd)
	}
	return strings.to_string(w.b)
}

@(test)
command_info_and_docs_match_the_capture :: proc(t: ^testing.T) {
	seen: [Introspection_Kind][Command][2]bool
	for c in INTROSPECTION_CASES {
		got := render_introspection(c.kind, c.command, c.proto)
		testing.expectf(t, got == c.reply, "case %d COMMAND %v %v RESP%d\n  got  %q\n  want %q", c.id, c.kind, c.command, c.proto, got, c.reply)
		seen[c.kind][c.command][c.proto - 2] = true
		free_all(context.temp_allocator)
	}
	for kind in Introspection_Kind {
		for cmd in Command {
			testing.expectf(t, seen[kind][cmd][0] && seen[kind][cmd][1], "no capture for COMMAND %v %v", kind, cmd)
		}
	}
}

@(test)
metadata_is_consistent :: proc(t: ^testing.T) {
	for cmd in Command {
		s := &COMMAND_SPECS[cmd]
		d := &COMMAND_DOCS[cmd]
		testing.expect_value(t, s.name, d.name)
		testing.expect_value(t, d.group, Cmd_Group.Module)
		testing.expect_value(t, d.module, MODULE_NAME)
		testing.expect(t, d.acl == {} && len(d.tips) == 0 && d.complexity == "" && len(d.history) == 0 && d.summary != "")
		testing.expect(t, .Module in s.flags)
		testing.expect(t, (.Write in s.flags) != (.Readonly in s.flags))
		testing.expect(t, s.first == 1 && s.last == 0 && s.step == 1 && len(s.specs) == 1)
		testing.expect(t, len(d.args) > 0 && d.args[0].kind == .Key)
		found, ok := command_lookup(transmute([]u8)strings.to_lower(s.name, context.temp_allocator))
		testing.expect(t, ok && found == cmd)
		testing.expect_value(t, command_name(cmd), s.name)
		testing.expect_value(t, ARITY_TEXTS[cmd], fmt.tprintf("ERR wrong number of arguments for '%s' command", s.name))
	}
	_, missing := command_lookup(transmute([]u8)string("VADDX"))
	testing.expect(t, !missing)
	_, nul := command_lookup(transmute([]u8)string("VADD\x00"))
	testing.expect(t, !nul)
	free_all(context.temp_allocator)
}

@(test)
arity_matches_the_registered_values :: proc(t: ^testing.T) {
	cases := [?]struct {
		cmd:   Command,
		argc:  int,
		valid: bool,
	} {
		{.Vadd, 4, false},
		{.Vadd, 5, true},
		{.Vadd, 50, true},
		{.Vsim, 3, false},
		{.Vsim, 4, true},
		{.Vrem, 3, true},
		{.Vrem, 4, false},
		{.Vcard, 2, true},
		{.Vcard, 1, false},
		{.Vsetattr, 4, true},
		{.Vsetattr, 5, false},
		{.Vrandmember, 2, true},
		{.Vrandmember, 1, false},
		{.Vrange, 4, true},
		{.Vrange, 3, false},
		{.Vemb, 3, true},
		{.Vlinks, 2, false},
	}
	for c in cases {
		testing.expectf(t, arity_ok(c.cmd, c.argc) == c.valid, "%v with %d arguments", c.cmd, c.argc)
	}
}

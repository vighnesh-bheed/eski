package main

import "base:runtime"
import "core:strings"
import "core:testing"
import "rdb"
import va "vsetargs"
import vt "vsettype"

@(private = "file")
Vset_Test :: struct {
	c:    Conn,
	used: int,
}

@(private = "file")
vt_open :: proc(t: ^Vset_Test, resp: u8 = 2) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	t.used = db_used_memory
	t.c = Conn{fd = -1, db = db_cur, resp = resp, wcap = 1 << 20}
	t.c.wbuf = cast([^]u8)runtime.heap_alloc(t.c.wcap)
}

@(private = "file")
vt_close :: proc(t: ^Vset_Test) {
	db_flush_all()
	runtime.heap_free(t.c.wbuf)
	stats_reset()
}

@(private = "file")
vt_args :: proc(args: ..string) -> [][]u8 {
	out := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		out[i] = transmute([]u8)a
	}
	return out
}

@(private = "file")
vt_call :: proc(t: ^Vset_Test, handler: Command_Proc, argv: [][]u8) -> string {
	t.c.wlen = 0
	t.c.wpos = 0
	saved := context.allocator
	context.allocator = runtime.heap_allocator()
	db_cur = t.c.db
	handler(&t.c, argv)
	context.allocator = saved
	return strings.clone(string(t.c.wbuf[:t.c.wlen]), context.temp_allocator)
}

@(private = "file")
vt_run :: proc(t: ^Vset_Test, handler: Command_Proc, args: ..string) -> string {
	return vt_call(t, handler, vt_args(..args))
}

@(private = "file")
vt_bulk :: proc(reply: string) -> []u8 {
	if len(reply) < 4 || reply[0] != '$' {
		return nil
	}
	at := strings.index(reply, "\r\n")
	n := 0
	for ch in reply[1:at] {
		n = n * 10 + int(ch - '0')
	}
	return transmute([]u8)reply[at + 2:][:n]
}

@(private = "file")
vt_set :: proc(key: string) -> vt.Vset {
	e := db_find_notouch(transmute([]u8)key)
	if e == nil || entry_type(e) != .Vectorset {
		return nil
	}
	return cast(vt.Vset)entry_object(e, .Vectorset)
}

@(private = "file")
vt_args_equal :: proc(a: []va.Cmd_Arg, b: []Cmd_Arg) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		y := b[i]
		xt, xh := x.token.?
		yt, yh := y.token.?
		xk, xkh := x.key_spec.?
		yk, ykh := y.key_spec.?
		if x.name != y.name || x.display != y.display || xh != yh || xt != yt || x.summary != y.summary || x.since != y.since {
			return false
		}
		if xkh != ykh || xk != yk || int(x.kind) != int(y.kind) || transmute(u8)x.flags != transmute(u8)y.flags {
			return false
		}
		if !vt_args_equal(x.args, y.args) {
			return false
		}
	}
	return true
}

@(test)
vset_module_type_id_names_eski :: proc(t: ^testing.T) {
	name: [9]u8
	testing.expect_value(t, rdb.module_name_by_id(VSET_RDB_MODULE_ID, &name), VSET_RDB_TYPE_NAME)
	testing.expect_value(t, VSET_RDB_MODULE_ID & 1023, u64(1))
	reference: [9]u8
	testing.expect_value(t, rdb.module_name_by_id(0xbde72da2bb1eb400, &reference), "vectorset")
	testing.expect(t, VSET_RDB_MODULE_ID != 0xbde72da2bb1eb400)
}

@(test)
vset_tables_mirror_parser_metadata :: proc(t: ^testing.T) {
	for cmd in va.Command {
		spec := va.COMMAND_SPECS[cmd]
		doc := va.COMMAND_DOCS[cmd]
		di := -1
		for d, i in cmd_docs {
			if d.name == doc.name {
				di = i
			}
		}
		testing.expectf(t, di >= 0, "%s missing from cmd_docs", doc.name)
		if di < 0 {
			continue
		}
		s := cmd_specs[di]
		testing.expect_value(t, s.name, spec.name)
		testing.expect_value(t, s.arity, spec.arity)
		testing.expect_value(t, transmute(u32)s.flags, transmute(u32)spec.flags)
		testing.expect_value(t, s.first, spec.first)
		testing.expect_value(t, s.last, spec.last)
		testing.expect_value(t, s.step, spec.step)
		testing.expect_value(t, len(s.specs), len(spec.specs))
		writes := .Write in s.flags
		for k, i in spec.specs {
			m := s.specs[i]
			testing.expect(t, int(m.search) == int(k.search) && m.pos == k.pos && m.keyword == k.keyword && m.from == k.from)
			testing.expect(t, int(m.find) == int(k.find) && m.a == k.a && m.b == k.b && m.c == k.c)
			testing.expect_value(t, transmute(u16)k.flags, transmute(u16)va.Key_Flags{.Rw, .Access, .Update})
			testing.expectf(t, m.flags == (Key_Flags{.Rw, .Access, .Update} if writes else Key_Flags{.Ro, .Access}), "%s key flags %v", spec.name, m.flags)
		}
		d := cmd_docs[di]
		testing.expect_value(t, d.summary, doc.summary)
		testing.expect_value(t, d.since, doc.since)
		testing.expect_value(t, d.module, doc.module)
		testing.expect_value(t, d.group, Cmd_Group.Module)
		testing.expect_value(t, transmute(u32)doc.acl, u32(0))
		want := Acl_Cats{.Write if writes else .Read, .Fast if .Fast in s.flags else .Slow}
		testing.expectf(t, d.acl == want, "%s categories %v, want %v", spec.name, d.acl, want)
		testing.expectf(t, vt_args_equal(doc.args, d.args), "%s arguments differ", doc.name)
		slot := lookup_entry(transmute([]u8)strings.to_lower(spec.name, context.temp_allocator))
		testing.expectf(t, slot != nil && slot.cmd.name == spec.name && slot.cmd.arity == int(spec.arity), "%s is not registered as written", spec.name)
	}
	for i in 1 ..< len(cmd_docs) {
		testing.expect(t, cmd_docs[i - 1].name < cmd_docs[i].name)
		testing.expect_value(t, cmd_specs[i].name, cmd_docs[i].name)
	}
}

@(private = "file")
Vset_Login :: struct {
	user:    string,
	rules:   []string,
	allowed: []string,
	denial:  Acl_Verdict,
}

@(private = "file")
vt_probe :: proc(name: string) -> [][]u8 {
	switch name {
	case "VADD":
		return vt_args("VADD", "v", "VALUES", "2", "1", "0", "x")
	case "VCARD", "VDIM", "VINFO", "VRANDMEMBER":
		return vt_args(name, "v")
	case "VRANGE":
		return vt_args("VRANGE", "v", "-", "+")
	case "VSETATTR":
		return vt_args("VSETATTR", "v", "a", "{}")
	case "VSIM":
		return vt_args("VSIM", "v", "VALUES", "2", "1", "0")
	}
	return vt_args(name, "v", "a")
}

@(private = "file")
vt_has :: proc(list: []string, name: string) -> bool {
	for n in list {
		if n == name {
			return true
		}
	}
	return false
}

@(private = "file")
vt_listed :: proc(reply: string, name: string) -> bool {
	return strings.contains(reply, strings.concatenate({"\r\n", name, "\r\n"}, context.temp_allocator))
}

@(test)
vset_acl_categories_grant_reads_and_writes :: proc(t: ^testing.T) {
	v: Vset_Test
	vt_open(&v)
	defer vt_close(&v)
	context.allocator = runtime.heap_allocator()
	acl_init()
	all := []string{"VADD", "VCARD", "VDIM", "VEMB", "VGETATTR", "VINFO", "VISMEMBER", "VLINKS", "VRANDMEMBER", "VRANGE", "VREM", "VSETATTR", "VSIM"}
	reads := []string{"VCARD", "VDIM", "VEMB", "VGETATTR", "VINFO", "VISMEMBER", "VLINKS", "VRANDMEMBER", "VRANGE", "VSIM"}
	writes := []string{"VADD", "VREM", "VSETATTR"}
	fast := []string{"VCARD", "VDIM", "VEMB", "VGETATTR", "VINFO", "VLINKS", "VSETATTR"}
	slow := []string{"VADD", "VISMEMBER", "VRANDMEMBER", "VRANGE", "VREM", "VSIM"}
	logins := []Vset_Login {
		{"vt-read", {"~*", "+@read"}, reads, .Command_Denied},
		{"vt-write", {"~*", "+@write"}, writes, .Command_Denied},
		{"vt-nowrite", {"~*", "+@all", "-@write"}, reads, .Command_Denied},
		{"vt-rokeys", {"%R~*", "+@all"}, reads, .Key_Denied},
		{"vt-fast", {"~*", "+@fast"}, fast, .Command_Denied},
		{"vt-named", {"~*", "-@all", "+vadd", "+VSIM", "+vcard"}, {"VADD", "VSIM", "VCARD"}, .Command_Denied},
		{"vt-unnamed", {"~*", "+@all", "-vadd", "-vsim"}, {"VCARD", "VDIM", "VEMB", "VGETATTR", "VINFO", "VISMEMBER", "VLINKS", "VRANDMEMBER", "VRANGE", "VREM", "VSETATTR"}, .Command_Denied},
		{"vt-mixed", {"~*", "+@read", "+vadd", "-vsim"}, {"VADD", "VCARD", "VDIM", "VEMB", "VGETATTR", "VINFO", "VISMEMBER", "VLINKS", "VRANDMEMBER", "VRANGE"}, .Command_Denied},
	}
	for l in logins {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "ACL", "SETUSER", l.user, "reset", "on", "nopass")
		append(&args, ..l.rules)
		testing.expect_value(t, vt_call(&v, cmd_acl, vt_args(..args[:])), "+OK\r\n")
		u := acl_user_find(transmute([]u8)l.user)
		if !testing.expectf(t, u != nil, "%s was not created", l.user) {
			continue
		}
		for name in all {
			verdict, _ := acl_check_user(u, int(acl_command_id(name)), vt_probe(name))
			want := Acl_Verdict.Allowed if vt_has(l.allowed, name) else l.denial
			testing.expectf(t, verdict == want, "%s running %s: %v, want %v", l.user, name, verdict, want)
			dry := make([dynamic][]u8, context.temp_allocator)
			append(&dry, transmute([]u8)string("ACL"), transmute([]u8)string("DRYRUN"), transmute([]u8)l.user)
			append(&dry, ..vt_probe(name))
			ran := vt_call(&v, cmd_acl, dry[:]) == "+OK\r\n"
			testing.expectf(t, ran == (want == .Allowed), "%s ACL DRYRUN %s ran %v", l.user, name, ran)
		}
	}
	cats := [?]struct {
		name:  string,
		names: []string,
	}{{"read", reads}, {"write", writes}, {"fast", fast}, {"slow", slow}}
	for cat in cats {
		listing := vt_run(&v, cmd_acl, "ACL", "CAT", cat.name)
		filtered := vt_run(&v, cmd_command, "COMMAND", "LIST", "FILTERBY", "ACLCAT", cat.name)
		for name in all {
			want := vt_has(cat.names, name)
			testing.expectf(t, vt_listed(listing, name) == want, "ACL CAT %s lists %s: %v", cat.name, name, !want)
			testing.expectf(t, vt_listed(filtered, name) == want, "COMMAND LIST FILTERBY ACLCAT %s lists %s: %v", cat.name, name, !want)
		}
	}
	info := vt_run(&v, cmd_command, "COMMAND", "INFO", "VSIM", "VADD")
	testing.expect(t, strings.contains(info, "*2\r\n+@read\r\n+@slow\r\n") && strings.contains(info, "*2\r\n+@write\r\n+@slow\r\n"))
	testing.expect_value(t, vt_run(&v, cmd_command, "COMMAND", "GETKEYSANDFLAGS", "VSIM", "k", "VALUES", "2", "1", "0"), "*1\r\n*2\r\n$1\r\nk\r\n*2\r\n+RO\r\n+access\r\n")
	testing.expect_value(t, vt_run(&v, cmd_command, "COMMAND", "GETKEYSANDFLAGS", "VADD", "k", "VALUES", "2", "1", "0", "e"), "*1\r\n*2\r\n$1\r\nk\r\n*3\r\n+RW\r\n+access\r\n+update\r\n")
	testing.expect_value(t, vt_run(&v, cmd_acl, "ACL", "CAT", "vectorset"), "-ERR Unknown category 'vectorset'\r\n")
	testing.expect_value(t, vt_run(&v, cmd_acl, "ACL", "DELUSER", "vt-read", "vt-write", "vt-nowrite", "vt-rokeys", "vt-fast", "vt-named", "vt-unnamed", "vt-mixed"), ":8\r\n")
}

@(test)
vset_replies_both_protocols :: proc(t: ^testing.T) {
	v: Vset_Test
	vt_open(&v)
	defer vt_close(&v)
	testing.expect_value(t, vt_run(&v, cmd_vadd, "VADD", "v", "VALUES", "2", "1", "0", "a", "SETATTR", `{"x":1}`), ":1\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vadd, "VADD", "v", "VALUES", "2", "0", "1", "b"), ":1\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vadd, "VADD", "v", "VALUES", "2", "1", "1", "c"), ":1\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vadd, "vadd", "v", "values", "2", "-1", "0", "d"), ":1\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vadd, "VADD", "v", "VALUES", "2", "-1", "0", "d"), ":0\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vsim, "VSIM", "v", "VALUES", "2", "1", "0", "WITHSCORES", "TRUTH"), "*8\r\n$1\r\na\r\n$1\r\n1\r\n$1\r\nc\r\n$18\r\n0.8535533845424652\r\n$1\r\nb\r\n$3\r\n0.5\r\n$1\r\nd\r\n$1\r\n0\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vsim, "VSIM", "v", "ELE", "a", "WITHATTRIBS", "COUNT", "2", "TRUTH"), "*4\r\n$1\r\na\r\n$7\r\n{\"x\":1}\r\n$1\r\nc\r\n$-1\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vsim, "VSIM", "nokey", "ELE", "zz", "COUNT", "0"), "*0\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vsim, "VSIM", "v", "ELE", "zz", "COUNT", "0"), "-ERR element not found in set\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vsim, "VSIM", "v", "VALUES", "3", "1", "0", "0", "COUNT", "0"), "-ERR Vector dimension mismatch - got 3 but set has 2\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vsim, "VSIM", "v", "VALUES", "2", "1", "0", "COUNT", "0"), "-ERR invalid COUNT\r\n")
	filtered := vt_run(&v, cmd_vsim, "VSIM", "v", "VALUES", "2", "1", "0", "FILTER", ".x ==\r\n1 ==")
	testing.expect(t, strings.has_prefix(filtered, "-ERR syntax error in FILTER expression near: "))
	testing.expect_value(t, strings.index(filtered, "\r\n"), len(filtered) - 2)
	testing.expect_value(t, vt_run(&v, cmd_vemb, "VEMB", "v", "a", "RAW"), "*4\r\n+int8\r\n$2\r\n\x7f\x00\r\n$1\r\n1\r\n$1\r\n1\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vemb, "VEMB", "v", "zz"), "$-1\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vcard, "VCARD", "v"), ":4\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vdim, "VDIM", "nokey"), "-ERR key does not exist\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vrange, "VRANGE", "v", "(a", "+", "2"), "*2\r\n$1\r\nb\r\n$1\r\nc\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vrandmember, "VRANDMEMBER", "v", "-9223372036854775808"), "-ERR COUNT value is out of range\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vrandmember, "VRANDMEMBER", "nokey", "-3"), "*0\r\n")
	testing.expect(t, strings.has_prefix(vt_run(&v, cmd_vrandmember, "VRANDMEMBER", "v", "-3000"), "*3000\r\n"))
	testing.expect_value(t, vt_run(&v, cmd_vgetattr, "VGETATTR", "v", "a"), "$7\r\n{\"x\":1}\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vsetattr, "VSETATTR", "v", "a", ""), ":1\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vgetattr, "VGETATTR", "v", "a"), "$-1\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vsetattr, "VSETATTR", "nokey", "a", "{}"), ":0\r\n")
	testing.expect(t, db_find_notouch(transmute([]u8)string("nokey")) == nil)
	v.c.resp = 3
	testing.expect_value(t, vt_run(&v, cmd_vsim, "VSIM", "v", "VALUES", "2", "1", "0", "WITHSCORES", "WITHATTRIBS", "COUNT", "2", "TRUTH"), "%2\r\n$1\r\na\r\n*2\r\n,1\r\n_\r\n$1\r\nc\r\n*2\r\n,0.8535533845424652\r\n_\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vismember, "VISMEMBER", "v", "b"), "#t\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vinfo, "VINFO", "nokey"), "_\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vemb, "VEMB", "v", "a"), "*2\r\n,1\r\n,0\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vrem, "VREM", "v", "zz"), "#f\r\n")
	testing.expect_value(t, vt_run(&v, cmd_vadd, "VADD", "v", "VALUES", "2", "1", "0", "e", "BIN"), "-ERR asked quantization mismatch with existing vector set\r\n")
	testing.expect_value(t, vt_run(&v, cmd_type, "TYPE", "v"), "+vectorset\r\n")
	testing.expect_value(t, vt_run(&v, cmd_copy, "COPY", "v", "w"), "-ERR not supported for this module key\r\n")
	testing.expect_value(t, vt_run(&v, cmd_module, "MODULE", "LIST"), "*1\r\n%4\r\n$4\r\nname\r\n$9\r\nvectorset\r\n$3\r\nver\r\n:1\r\n$4\r\npath\r\n$0\r\n\r\n$4\r\nargs\r\n*0\r\n")
}

@(test)
vset_memory_follows_every_write :: proc(t: ^testing.T) {
	v: Vset_Test
	vt_open(&v)
	defer vt_close(&v)
	start := db_used_memory
	values: [8]string
	text: [8][24]u8
	for i in 0 ..< 200 {
		for j in 0 ..< 8 {
			n := format_i64(raw_data(text[j][:]), i64((i * 7 + j * 13) % 29) - 14)
			values[j] = string(text[j][:n])
		}
		name: [24]u8
		k := format_i64(raw_data(name[:]), i64(i))
		args := []string{"VADD", "m", "VALUES", "8", values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7], string(name[:k]), "SETATTR", `{"n":1}`}
		vt_call(&v, cmd_vadd, vt_args(..args))
		s := vt_set("m")
		testing.expect_value(t, db_used_memory - start, vt.memory_usage(s))
	}
	for i in 0 ..< 200 {
		name: [24]u8
		k := format_i64(raw_data(name[:]), i64(i))
		if i % 2 == 0 {
			vt_run(&v, cmd_vsetattr, "VSETATTR", "m", string(name[:k]), `{"a much longer attribute than before":12345}`)
		} else {
			vt_run(&v, cmd_vrem, "VREM", "m", string(name[:k]))
		}
		s := vt_set("m")
		testing.expect_value(t, db_used_memory - start, vt.memory_usage(s))
		testing.expect_value(t, object_acct_of(.Vectorset, s), vt.memory_usage(s))
	}
	for i := 0; i < 200; i += 2 {
		name: [24]u8
		k := format_i64(raw_data(name[:]), i64(i))
		vt_run(&v, cmd_vrem, "VREM", "m", string(name[:k]))
	}
	testing.expect(t, db_find_notouch(transmute([]u8)string("m")) == nil)
	testing.expect_value(t, db_used_memory, start)
	vt_run(&v, cmd_vadd, "VADD", "f", "VALUES", "1", "1", "x")
	testing.expect(t, db_used_memory > start)
	vt_run(&v, cmd_del, "DEL", "f")
	testing.expect_value(t, db_used_memory, start)
}

@(test)
vset_dump_restore_rewrite_round_trip :: proc(t: ^testing.T) {
	v: Vset_Test
	vt_open(&v)
	defer vt_close(&v)
	vt_run(&v, cmd_vadd, "VADD", "d", "VALUES", "3", "0.1", "-0.2", "0.3", "a", "SETATTR", `{"k":"v"}`)
	vt_run(&v, cmd_vadd, "VADD", "d", "VALUES", "3", "0.5", "0.5", "-1", "b", "SETATTR", "")
	vt_run(&v, cmd_vadd, "VADD", "d", "VALUES", "3", "1", "1", "1", "c")
	dumped := vt_run(&v, cmd_dump, "DUMP", "d")
	payload := vt_bulk(dumped)
	testing.expect(t, len(payload) > 20)
	testing.expect_value(t, payload[0], u8(rdb.TYPE_MODULE_2))
	testing.expect_value(t, payload[1], u8(rdb.LEN_64BIT))
	testing.expect(t, dump_verify(payload))
	e := db_find_notouch(transmute([]u8)string("d"))
	testing.expect_value(t, vset_serialized_length(entry_object(e, .Vectorset)), len(payload) - 1 - VSET_DUMP_TRAILER)
	plain: rdb.Writer
	rdb.writer_init_mem(&plain, false, false)
	persist_write_value(&plain, transmute([]u8)string("d"), persist_slot_value(e.db, e.kp, e.vp), false)
	testing.expect_value(t, string(rdb.writer_bytes(&plain)), string(payload[:len(payload) - VSET_DUMP_TRAILER]))
	rdb.writer_destroy(&plain)
	restore := vt_args("RESTORE", "r", "0", "")
	restore[3] = payload
	testing.expect_value(t, vt_call(&v, cmd_restore, restore), "+OK\r\n")
	for name in ([]string{"a", "b", "c"}) {
		testing.expect_value(t, vt_run(&v, cmd_vemb, "VEMB", "r", name, "RAW"), vt_run(&v, cmd_vemb, "VEMB", "d", name, "RAW"))
		testing.expect_value(t, vt_run(&v, cmd_vgetattr, "VGETATTR", "r", name), vt_run(&v, cmd_vgetattr, "VGETATTR", "d", name))
	}
	testing.expect_value(t, vt_run(&v, cmd_vsim, "VSIM", "r", "ELE", "a", "WITHSCORES", "TRUTH"), vt_run(&v, cmd_vsim, "VSIM", "d", "ELE", "a", "WITHSCORES", "TRUTH"))
	e = db_find_notouch(transmute([]u8)string("d"))
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	defer rdb.writer_destroy(&w)
	aof_rewrite_value(&w, transmute([]u8)string("d"), persist_slot_value(e.db, e.kp, e.vp))
	written := string(rdb.writer_bytes(&w))
	head := "*4\r\n$7\r\nRESTORE\r\n$1\r\nd\r\n$1\r\n0\r\n"
	testing.expect(t, strings.has_prefix(written, head))
	testing.expect_value(t, string(vt_bulk(written[len(head):])), string(payload))
	broken := make([]u8, len(payload), context.temp_allocator)
	copy(broken, payload)
	magic := strings.index(string(broken), "EVS")
	testing.expect(t, magic > 0)
	broken[magic + 1] ~= 0x5a
	sum := rdb.crc64(0, broken[:len(broken) - 8])
	for i in 0 ..< 8 {
		broken[len(broken) - 8 + i] = u8(sum >> (8 * uint(i)))
	}
	restore[1] = transmute([]u8)string("bad")
	restore[3] = broken
	testing.expect_value(t, vt_call(&v, cmd_restore, restore), "-ERR Bad data format\r\n")
	alien := make([]u8, len(payload), context.temp_allocator)
	copy(alien, payload)
	reference := [8]u8{0xbd, 0xe7, 0x2d, 0xa2, 0xbb, 0x1e, 0xb4, 0x00}
	copy(alien[2:10], reference[:])
	sum = rdb.crc64(0, alien[:len(alien) - 8])
	for i in 0 ..< 8 {
		alien[len(alien) - 8 + i] = u8(sum >> (8 * uint(i)))
	}
	restore[3] = alien
	testing.expect_value(t, vt_call(&v, cmd_restore, restore), "-ERR Bad data format\r\n")
	testing.expect(t, db_find_notouch(transmute([]u8)string("bad")) == nil)
}

@(test)
vset_vlinks_lists_twins_on_small_sets :: proc(t: ^testing.T) {
	v: Vset_Test
	vt_open(&v)
	defer vt_close(&v)
	vt_run(&v, cmd_vadd, "VADD", "l", "VALUES", "2", "1", "0", "a")
	vt_run(&v, cmd_vadd, "VADD", "l", "VALUES", "2", "0", "1", "b")
	for name in ([]string{"e", "f", "g", "h", "i"}) {
		vt_run(&v, cmd_vadd, "VADD", "l", "VALUES", "2", "1", "0.1", name)
	}
	names := []string{"a", "b", "e", "f", "g", "h", "i"}
	for name in names {
		reply := vt_run(&v, cmd_vlinks, "VLINKS", "l", name)
		layer0 := reply[strings.last_index(reply, "*"):]
		testing.expectf(t, strings.has_prefix(layer0, "*6\r\n"), "%s layer 0 is %q", name, layer0)
		for other in names {
			if other != name {
				needle := strings.concatenate({"$1\r\n", other, "\r\n"}, context.temp_allocator)
				testing.expectf(t, strings.contains(layer0, needle), "%s does not list %s: %q", name, other, layer0)
			}
		}
	}
}

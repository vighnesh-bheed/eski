package main

import "core:testing"
import "base:runtime"
import st "settype"

set_test_bytes :: proc(s: string) -> []u8 {
	return raw_data(s)[:len(s)]
}

set_test_call :: proc(c: ^Conn, handler: Command_Proc, args: []string) -> string {
	argv := make([][]u8, len(args))
	defer delete(argv)
	for arg, i in args {
		argv[i] = set_test_bytes(arg)
	}
	c.wlen = 0
	c.wpos = 0
	tracked_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	handler(c, argv)
	context.allocator = tracked_allocator
	return string(c.wbuf[:c.wlen])
}

set_test_cleanup :: proc() {
	db_flush_all()
	set_scratch_trim()
	delete(set_vals)
	delete(set_srcs)
	set_vals = nil
	set_srcs = nil
	st.popped_destroy(&set_pop)
	stats_reset()
	for st.maintenance_pending() {
		if st.maintenance_release() == 0 {
			break
		}
	}
}

@(test)
set_aliases_pop_and_accounting :: proc(t: ^testing.T) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	defer set_test_cleanup()
	c := Conn{fd = -1, db = db_cur, resp = 2, wcap = 65536}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	testing.expect_value(t, set_test_call(&c, cmd_sadd, []string{"SADD", "src", "1", "2", "3", "4"}), ":4\r\n")
	e, src, _ := set_lookup(set_test_bytes("src"), false)
	entry_set_expire(e, 2500000000000)
	testing.expect_value(t, src.acct, st.memory_usage(src))
	testing.expect_value(t, set_test_call(&c, cmd_sadd, []string{"SADD", "src", "1", "1"}), ":0\r\n")
	testing.expect_value(t, db_find(set_test_bytes("src")).expire_at, i64(2500000000000))
	testing.expect_value(t, set_test_call(&c, cmd_smove, []string{"SMOVE", "src", "src", "1"}), ":1\r\n")
	testing.expect_value(t, st.size(src), 4)
	testing.expect_value(t, set_test_call(&c, cmd_sadd, []string{"SADD", "other", "2", "3", "5"}), ":3\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_sinterstore, []string{"SINTERSTORE", "src", "src", "other"}), ":2\r\n")
	e, src, _ = set_lookup(set_test_bytes("src"), false)
	testing.expect_value(t, e.expire_at, i64(0))
	testing.expect(t, st.is_member(src, set_test_bytes("2")) && st.is_member(src, set_test_bytes("3")))
	testing.expect_value(t, src.acct, st.memory_usage(src))
	set_test_call(&c, cmd_sadd, []string{"SADD", "src", "4", "5"})
	set_test_call(&c, cmd_spop, []string{"SPOP", "src", "2"})
	_, src, _ = set_lookup(set_test_bytes("src"), false)
	testing.expect(t, src != nil)
	testing.expect_value(t, st.size(src), 2)
	testing.expect_value(t, src.acct, st.memory_usage(src))
	set_test_call(&c, cmd_spop, []string{"SPOP", "src", "10"})
	testing.expect(t, db_find(set_test_bytes("src")) == nil)
	testing.expect_value(t, set_test_call(&c, cmd_sdiffstore, []string{"SDIFFSTORE", "other", "other", "other"}), ":0\r\n")
	testing.expect(t, db_find(set_test_bytes("other")) == nil)
	for index in 0 ..< 70 {
		buffer: [21]u8
		n := format_u64(raw_data(buffer[:]), u64(index))
		arguments := []string{"SADD", "large", string(buffer[:n])}
		set_test_call(&c, cmd_sadd, arguments)
	}
	set_test_call(&c, cmd_spop, []string{"SPOP", "large", "65"})
	_, large, _ := set_lookup(set_test_bytes("large"), false)
	testing.expect_value(t, st.size(large), 5)
	testing.expect_value(t, large.acct, st.memory_usage(large))
	set_test_call(&c, cmd_sadd, []string{"SADD", "copy-src", "a", "b", "01"})
	source_entry := db_find(set_test_bytes("copy-src"))
	copy, _, copied := set_copy_dup(source_entry)
	testing.expect(t, copied)
	copy_entry, _ := db_upsert(set_test_bytes("copy-dst"))
	set_copy_attach(copy_entry, copy)
	copy_set := cast(st.Set)copy
	testing.expect_value(t, copy_set.acct, st.memory_usage(copy_set))
	testing.expect(t, db_move(&dbs[0], &dbs[1], set_test_bytes("copy-dst")))
	testing.expect(t, db_find_in(&dbs[1], set_test_bytes("copy-dst")) != nil)
	_, source_set, _ := set_lookup(set_test_bytes("copy-src"), false)
	st.add(source_set, set_test_bytes("independent"))
	set_done(db_find(set_test_bytes("copy-src")), source_set)
	testing.expect(t, !st.is_member(copy_set, set_test_bytes("independent")))
}

@(test)
set_missing_errors_and_scan :: proc(t: ^testing.T) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	defer set_test_cleanup()
	c := Conn{fd = -1, db = db_cur, resp = 2, wcap = 65536}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	testing.expect_value(t, set_test_call(&c, cmd_scard, []string{"SCARD", "missing"}), ":0\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_spop, []string{"SPOP", "missing", "0"}), "*0\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_srandmember, []string{"SRANDMEMBER", "missing", "bad"}), "-ERR value is not an integer or out of range\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_sintercard, []string{"SINTERCARD", "2", "missing"}), "-ERR Number of keys can't be greater than number of args\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_sscan, []string{"SSCAN", "missing", "bad"}), "-ERR invalid cursor\r\n")
	set_test_call(&c, cmd_sadd, []string{"SADD", "scan", "apple", "banana", "apricot"})
	testing.expect_value(t, set_test_call(&c, cmd_sscan, []string{"SSCAN", "scan", "0", "MATCH", "a*", "COUNT", "1"}), "*2\r\n$1\r\n0\r\n*2\r\n$5\r\napple\r\n$7\r\napricot\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_spop, []string{"SPOP", "scan", "-1"}), "-ERR value is out of range, must be positive\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_srandmember, []string{"SRANDMEMBER", "scan", "-9223372036854775808"}), "-" + SRANDMEMBER_RANGE_ERROR + "\r\n")
}

@(test)
set_scratch_retention_limits :: proc(t: ^testing.T) {
	defer set_test_cleanup()
	set_vals = make([dynamic]st.Value, 0, 65536)
	set_srcs = make([dynamic]st.Set, 0, 1)
	set_pop.arena = make([dynamic]u8, 0, 1 << 20)
	set_pop.items = make([dynamic]st.Popped_Item, 0, 65536)
	set_scratch_trim()
	testing.expect_value(t, cap(set_vals), 65536)
	testing.expect_value(t, cap(set_pop.arena), 1 << 20)
	testing.expect_value(t, cap(set_pop.items), 65536)
	delete(set_vals)
	delete(set_pop.arena)
	delete(set_pop.items)
	set_vals = make([dynamic]st.Value, 0, 65537)
	set_pop.arena = make([dynamic]u8, 0, (1 << 20) + 1)
	set_pop.items = make([dynamic]st.Popped_Item, 0, 65537)
	set_scratch_trim()
	testing.expect_value(t, cap(set_vals), 0)
	testing.expect_value(t, cap(set_pop.arena), 0)
	testing.expect_value(t, cap(set_pop.items), 0)
}

@(test)
set_option_parser_precedence :: proc(t: ^testing.T) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	defer set_test_cleanup()
	c := Conn{fd = -1, db = db_cur, resp = 2, wcap = 65536}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	set_test_call(&c, cmd_sadd, []string{"SADD", "parser", "apple", "banana", "apricot"})
	for text in ([]string{"0", "-1", "+1", "01", "", "x", "9223372036854775808", "1\x00tail"}) {
		testing.expect_value(t, set_test_call(&c, cmd_sintercard, []string{"SINTERCARD", text, "parser"}), "-ERR numkeys should be greater than 0\r\n")
	}
	for text in ([]string{"-1", "+1", "01", "x", "9223372036854775808"}) {
		testing.expect_value(t, set_test_call(&c, cmd_sintercard, []string{"SINTERCARD", "1", "parser", "LIMIT", text}), "-ERR LIMIT can't be negative\r\n")
	}
	testing.expect_value(t, set_test_call(&c, cmd_sintercard, []string{"SINTERCARD", "1", "parser", "LIMIT", "0", "LIMIT", "1"}), ":1\r\n")
	for text in ([]string{"-1", "+0", "00", "x", "9223372036854775808"}) {
		testing.expect_value(t, set_test_call(&c, cmd_spop, []string{"SPOP", "parser", text}), "-ERR value is out of range, must be positive\r\n")
	}
	testing.expect_value(t, set_test_call(&c, cmd_sscan, []string{"SSCAN", "parser", "0", "COUNT\x00x", "1", "MATCH", "a*"}), "*2\r\n$1\r\n0\r\n*2\r\n$5\r\napple\r\n$7\r\napricot\r\n")
}

@(test)
srandmember_extra_arguments :: proc(t: ^testing.T) {
	c := Conn{fd = -1, resp = 2, wcap = 1024}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	defer stats_reset()
	testing.expect_value(t, set_test_call(&c, cmd_srandmember, []string{"SRANDMEMBER", "any", "1", "extra"}), "-ERR syntax error\r\n")
}

@(test)
spop_extra_arguments :: proc(t: ^testing.T) {
	c := Conn{fd = -1, resp = 2, wcap = 1024}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	defer stats_reset()
	testing.expect_value(t, set_test_call(&c, cmd_spop, []string{"SPOP", "any", "1", "extra"}), "-ERR syntax error\r\n")
}

@(test)
sadd_incoming_hint :: proc(t: ^testing.T) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	defer set_test_cleanup()
	old_int, old_pack := st.set_max_intset_entries, st.set_max_listpack_entries
	defer {
		st.set_max_intset_entries, st.set_max_listpack_entries = old_int, old_pack
	}
	c := Conn{fd = -1, db = db_cur, resp = 2, wcap = 65536}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	set_test_call(&c, cmd_sadd, []string{"SADD", "hint", "a", "b", "c"})
	st.set_max_listpack_entries = 2
	testing.expect_value(t, set_test_call(&c, cmd_sadd, []string{"SADD", "hint", "a"}), ":0\r\n")
	_, pack, _ := set_lookup(set_test_bytes("hint"), false)
	testing.expect_value(t, pack.encoding, .Listpack)
	testing.expect_value(t, set_test_call(&c, cmd_sadd, []string{"SADD", "hint", "a", "b", "c"}), ":0\r\n")
	_, pack, _ = set_lookup(set_test_bytes("hint"), false)
	testing.expect_value(t, pack.encoding, .Hashtable)
	testing.expect_value(t, pack.acct, st.memory_usage(pack))
	st.set_max_intset_entries = 512
	set_test_call(&c, cmd_sadd, []string{"SADD", "int-hint", "1", "2", "3"})
	st.set_max_intset_entries = 2
	testing.expect_value(t, set_test_call(&c, cmd_sadd, []string{"SADD", "int-hint", "1"}), ":0\r\n")
	_, integers, _ := set_lookup(set_test_bytes("int-hint"), false)
	testing.expect_value(t, integers.encoding, .Intset)
	testing.expect_value(t, set_test_call(&c, cmd_sadd, []string{"SADD", "int-hint", "1", "2", "3"}), ":0\r\n")
	_, integers, _ = set_lookup(set_test_bytes("int-hint"), false)
	testing.expect_value(t, integers.encoding, .Hashtable)
}

@(test)
spop_detachment_accounting :: proc(t: ^testing.T) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	defer set_test_cleanup()
	object := st.create_table(256)
	for index in 0 ..< 256 {
		buffer: [21]u8
		length := format_u64(raw_data(buffer[:]), u64(index))
		st.add(object, buffer[:length])
	}
	st.table_resize(object.table, 1024)
	for object.table.resize != nil && object.table.resize.old_count > 16 {
		st.table_step(object.table, 64, 4)
	}
	testing.expect(t, object.table.resize != nil)
	testing.expect_value(t, object.table.resize.old_count, 16)
	_, retired_before, _ := st.maintenance_memory()
	entry, _ := db_upsert(set_test_bytes("detach"))
	set_attach(entry, object)
	before := db_cur.heap_bytes
	old_charge := object.acct
	c := Conn{fd = -1, db = db_cur, resp = 2, wcap = 65536}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	reply := set_test_call(&c, cmd_spop, []string{"SPOP", "detach", "250"})
	testing.expect_value(t, reply[:6], "*250\r\n")
	_, remaining, _ := set_lookup(set_test_bytes("detach"), false)
	testing.expect_value(t, st.size(remaining), 6)
	testing.expect_value(t, remaining.encoding, .Listpack)
	testing.expect_value(t, remaining.acct, st.memory_usage(remaining))
	testing.expect_value(t, db_cur.heap_bytes, before - old_charge + remaining.acct)
	_, retired_after, _ := st.maintenance_memory()
	testing.expect(t, retired_after >= retired_before + 8192)
}

@(test)
set_intset_boundary_pop_order :: proc(t: ^testing.T) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	defer set_test_cleanup()
	c := Conn{fd = -1, db = db_cur, resp = 2, wcap = 65536}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	set_test_call(&c, cmd_sadd, []string{"SADD", "boundary", "18", "29", "-12", "-63923594512", "15", "-11"})
	reply := set_test_call(&c, cmd_spop, []string{"SPOP", "boundary", "5"})
	testing.expect_value(t, reply[:4], "*5\r\n")
	position := 4
	previous := min(i64)
	_, remaining, _ := set_lookup(set_test_bytes("boundary"), false)
	testing.expect_value(t, st.size(remaining), 1)
	for _ in 0 ..< 5 {
		testing.expect_value(t, reply[position], u8('$'))
		position += 1
		end := position
		for reply[end] != '\r' {
			end += 1
		}
		length, valid_length := parse_i64(raw_data(reply)[position:end])
		testing.expect(t, valid_length && length > 0)
		position = end + 2
		value, valid := parse_i64(raw_data(reply)[position:position + int(length)])
		testing.expect(t, valid && value > previous)
		testing.expect(t, !st.is_member_aux(remaining, {ival = value, is_int = true}))
		previous = value
		position += int(length) + 2
	}
	testing.expect_value(t, position, len(reply))
}

@(test)
set_full_pop_order :: proc(t: ^testing.T) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	defer set_test_cleanup()
	c := Conn{fd = -1, db = db_cur, resp = 2, wcap = 65536}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	cases := []struct {
		members: []string,
		expected: string,
	} {
		{{"-28", "-2147483649", "m10", "-8", "m33"}, "*5\r\n$11\r\n-2147483649\r\n$3\r\n-28\r\n$3\r\nm10\r\n$2\r\n-8\r\n$3\r\nm33\r\n"},
		{{"9", "1", "x", "3", "2"}, "*5\r\n$1\r\n1\r\n$1\r\n9\r\n$1\r\nx\r\n$1\r\n3\r\n$1\r\n2\r\n"},
		{{"5", "4", "3", "2", "1"}, "*5\r\n$1\r\n1\r\n$1\r\n2\r\n$1\r\n3\r\n$1\r\n4\r\n$1\r\n5\r\n"},
		{{"z", "9", "1", "x"}, "*4\r\n$1\r\nz\r\n$1\r\n9\r\n$1\r\n1\r\n$1\r\nx\r\n"},
		{{"01", "1", "0", "-0"}, "*4\r\n$2\r\n01\r\n$1\r\n1\r\n$1\r\n0\r\n$2\r\n-0\r\n"},
	}
	for fixture in cases {
		for extra in ([]int{0, 3}) {
			arguments := make([dynamic]string)
			append(&arguments, "SADD", "all-pop", "__marker__")
			append(&arguments, ..fixture.members)
			set_test_call(&c, cmd_sadd, arguments[:])
			delete(arguments)
			set_test_call(&c, cmd_srem, []string{"SREM", "all-pop", "__marker__"})
			_, source, _ := set_lookup(set_test_bytes("all-pop"), false)
			testing.expect_value(t, source.encoding, .Listpack)
			before, charge := db_cur.heap_bytes, source.acct
			buffer: [21]u8
			length := format_u64(raw_data(buffer[:]), u64(len(fixture.members) + extra))
			reply := set_test_call(&c, cmd_spop, []string{"SPOP", "all-pop", string(buffer[:length])})
			testing.expect_value(t, reply, fixture.expected)
			testing.expect(t, db_find(set_test_bytes("all-pop")) == nil)
			testing.expect_value(t, db_cur.heap_bytes, before - charge)
		}
	}
}

set_test_notification_frame :: proc(out: ^[dynamic]u8, protocol: u8, channel, payload: string) {
	append(out, '>' if protocol == 3 else '*', '4', '\r', '\n')
	for field in ([]string{"pmessage", "*", channel, payload}) {
		buffer: [21]u8
		length := format_u64(raw_data(buffer[:]), u64(len(field)))
		append(out, '$')
		append(out, ..buffer[:length])
		append(out, '\r', '\n')
		append(out, ..set_test_bytes(field))
		append(out, '\r', '\n')
	}
}

@(test)
smove_notification_order :: proc(t: ^testing.T) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	old_flags := notify_config
	defer notify_apply(old_flags)
	defer set_test_cleanup()
	for protocol in ([]u8{2, 3}) {
		c := Conn{fd = -1, db = db_cur, resp = protocol, wcap = 65536}
		c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
		subscriber := Conn{fd = -1, db = db_cur, resp = protocol, wcap = 65536}
		subscriber.wbuf = cast([^]u8)runtime.heap_alloc(subscriber.wcap)
		set_test_call(&subscriber, cmd_psubscribe, []string{"PSUBSCRIBE", "*"})
		for empty in ([]bool{false, true}) {
			notify_apply({})
			db_flush_all()
			arguments := []string{"SADD", "event-src", "a", "b"}
			if empty {
				arguments = arguments[:3]
			}
			set_test_call(&c, cmd_sadd, arguments)
			notify_apply({.Keyspace, .Keyevent, .Generic, .Set, .New})
			subscriber.wlen = 0
			testing.expect_value(t, set_test_call(&c, cmd_smove, []string{"SMOVE", "event-src", "event-dst", "a"}), ":1\r\n")
			expected := make([dynamic]u8)
			set_test_notification_frame(&expected, protocol, "__keyspace@0__:event-src", "srem")
			set_test_notification_frame(&expected, protocol, "__keyevent@0__:srem", "event-src")
			if empty {
				set_test_notification_frame(&expected, protocol, "__keyspace@0__:event-src", "del")
				set_test_notification_frame(&expected, protocol, "__keyevent@0__:del", "event-src")
			}
			set_test_notification_frame(&expected, protocol, "__keyspace@0__:event-dst", "new")
			set_test_notification_frame(&expected, protocol, "__keyevent@0__:new", "event-dst")
			set_test_notification_frame(&expected, protocol, "__keyspace@0__:event-dst", "sadd")
			set_test_notification_frame(&expected, protocol, "__keyevent@0__:sadd", "event-dst")
			testing.expect_value(t, string(subscriber.wbuf[:subscriber.wlen]), string(expected[:]))
			delete(expected)
			_, destination, _ := set_lookup(set_test_bytes("event-dst"), false)
			testing.expect_value(t, destination.acct, st.memory_usage(destination))
			testing.expect_value(t, st.size(destination), 1)
			testing.expect_value(t, db_find(set_test_bytes("event-src")) == nil, empty)
		}
		notify_apply({})
		old_allocator := context.allocator
		context.allocator = runtime.heap_allocator()
		pubsub_conn_closed(&subscriber)
		context.allocator = old_allocator
		runtime.heap_free(subscriber.wbuf)
		runtime.heap_free(c.wbuf)
	}
}

@(test)
smove_alias_duplicate_wrongtype :: proc(t: ^testing.T) {
	if len(dbs) == 0 {
		db_init()
	}
	db_cur = &dbs[0]
	db_flush_all()
	defer set_test_cleanup()
	c := Conn{fd = -1, db = db_cur, resp = 2, wcap = 65536}
	c.wbuf = cast([^]u8)runtime.heap_alloc(c.wcap)
	defer runtime.heap_free(c.wbuf)
	set_test_call(&c, cmd_sadd, []string{"SADD", "move-src", "a", "b"})
	set_test_call(&c, cmd_sadd, []string{"SADD", "move-dst", "a"})
	source_entry, source, _ := set_lookup(set_test_bytes("move-src"), false)
	entry_set_expire(source_entry, 2500000000000)
	destination_entry, destination, _ := set_lookup(set_test_bytes("move-dst"), false)
	entry_set_expire(destination_entry, 2500000000001)
	testing.expect_value(t, set_test_call(&c, cmd_smove, []string{"SMOVE", "move-src", "move-src", "a"}), ":1\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_smove, []string{"SMOVE", "move-src", "move-src", "absent"}), ":0\r\n")
	testing.expect_value(t, st.size(source), 2)
	testing.expect_value(t, set_test_call(&c, cmd_smove, []string{"SMOVE", "move-src", "move-dst", "a"}), ":1\r\n")
	testing.expect_value(t, st.size(source), 1)
	testing.expect_value(t, st.size(destination), 1)
	testing.expect_value(t, db_find(set_test_bytes("move-src")).expire_at, i64(2500000000000))
	testing.expect_value(t, db_find(set_test_bytes("move-dst")).expire_at, i64(2500000000001))
	db_set(set_test_bytes("move-wrong"), set_test_bytes("string"), 0)
	testing.expect_value(t, set_test_call(&c, cmd_smove, []string{"SMOVE", "move-src", "move-wrong", "b"}), "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n")
	testing.expect(t, st.is_member(source, set_test_bytes("b")))
	testing.expect_value(t, set_test_call(&c, cmd_smove, []string{"SMOVE", "move-src", "move-wrong", "absent"}), "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_smove, []string{"SMOVE", "move-missing", "move-wrong", "b"}), ":0\r\n")
	testing.expect_value(t, set_test_call(&c, cmd_smove, []string{"SMOVE", "move-src", "move-dst", "b"}), ":1\r\n")
	testing.expect(t, db_find(set_test_bytes("move-src")) == nil)
	_, destination, _ = set_lookup(set_test_bytes("move-dst"), false)
	testing.expect_value(t, st.size(destination), 2)
	testing.expect_value(t, destination.acct, st.memory_usage(destination))
}

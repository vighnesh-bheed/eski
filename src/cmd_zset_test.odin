package main

import "base:runtime"
import "core:testing"
import zt "zsettype"

@(test)
zset_reply_shapes_and_copy :: proc(t: ^testing.T) {
	for version in ([2]u8{2, 3}) {
		c := Conn{resp = version}
		items := [2]zt.Item{zt.Item{str = []u8{'a'}, score = 0.1}, zt.Item{str = []u8{'b'}, score = 2}}
		reply_zset_items(&c, items[:], true)
		expected := "*4\r\n$1\r\na\r\n$3\r\n0.1\r\n$1\r\nb\r\n$1\r\n2\r\n"
		if version == 3 {
			expected = "*2\r\n*2\r\n$1\r\na\r\n,0.1\r\n*2\r\n$1\r\nb\r\n,2\r\n"
		}
		testing.expect(t, string(c.wbuf[:c.wlen]) == expected)
		c.wlen = 0
		member := []u8{'a', 0, 'b'}
		item := zt.Item{str = member}
		reply_zset_member(&c, &item)
		member[0] = 'z'
		testing.expect(t, string(c.wbuf[:c.wlen]) == "$3\r\na\x00b\r\n")
		runtime.heap_free(c.wbuf)
	}
}

@(test)
zset_zero_pop_shapes :: proc(t: ^testing.T) {
	for version in ([2]u8{2, 3}) {
		z := zt.create_listpack()
		_, _, _ = zt.add(z, 1, []u8{'m'}, {})
		c := Conn{resp = version}
		deleted := zpop_emit(&c, []u8{'k'}, nil, z, Zpop_Order{shape = .Keyed_Run, count = 0})
		testing.expect(t, !deleted && zt.length(z) == 1)
		testing.expect(t, string(c.wbuf[:c.wlen]) == "*2\r\n$1\r\nk\r\n*0\r\n")
		runtime.heap_free(c.wbuf)
		zt.destroy(z)
	}
}

@(test)
zrandmember_rejects_reply_overflow_before_lookup :: proc(t: ^testing.T) {
	saved_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer {
		context.allocator = saved_allocator
	}
	for count in ([4]string{"4611686018427387904", "-4611686018427387904", "9223372036854770000", "-9223372036854770000"}) {
		c := Conn{resp = 2}
		args := [4][]u8{[]u8{'z'}, []u8{'k'}, transmute([]u8)count, []u8{'w', 'i', 't', 'h', 's', 'c', 'o', 'r', 'e', 's'}}
		cmd_zrandmember(&c, args[:])
		testing.expect(t, string(c.wbuf[:c.wlen]) == "-ERR value is out of range\r\n")
		runtime.heap_free(c.wbuf)
	}
}

@(test)
zset_captured_error_replies :: proc(t: ^testing.T) {
	saved_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer {
		context.allocator = saved_allocator
	}
	cases := []struct {
		handler: Command_Proc,
		args: [][]u8,
		expected: string,
	}{
		{cmd_zincrby, [][]u8{transmute([]u8)string("\x5a\x49\x4e\x43\x52\x42\x59"), transmute([]u8)string("\x7a\x6f"), transmute([]u8)string("\x6e\x78"), transmute([]u8)string("\x61")}, "\x2d\x45\x52\x52\x20\x73\x79\x6e\x74\x61\x78\x20\x65\x72\x72\x6f\x72\x0d\x0a"},
		{cmd_zincrby, [][]u8{transmute([]u8)string("\x5a\x49\x4e\x43\x52\x42\x59"), transmute([]u8)string("\x7a\x6f"), transmute([]u8)string("\x69\x6e\x63\x72"), transmute([]u8)string("\x69\x6e\x63\x72")}, "\x2d\x45\x52\x52\x20\x73\x79\x6e\x74\x61\x78\x20\x65\x72\x72\x6f\x72\x0d\x0a"},
		{cmd_zrange, [][]u8{transmute([]u8)string("\x5a\x52\x41\x4e\x47\x45"), transmute([]u8)string("\x72\x6b"), transmute([]u8)string("\x30"), transmute([]u8)string("\x31"), transmute([]u8)string("\x52\x45\x56"), transmute([]u8)string("\x52\x45\x56")}, "\x2d\x45\x52\x52\x20\x73\x79\x6e\x74\x61\x78\x20\x65\x72\x72\x6f\x72\x0d\x0a"},
		{cmd_zpopmin, [][]u8{transmute([]u8)string("\x5a\x50\x4f\x50\x4d\x49\x4e"), transmute([]u8)string("\x70\x7a"), transmute([]u8)string("\x61")}, "\x2d\x45\x52\x52\x20\x76\x61\x6c\x75\x65\x20\x69\x73\x20\x6f\x75\x74\x20\x6f\x66\x20\x72\x61\x6e\x67\x65\x2c\x20\x6d\x75\x73\x74\x20\x62\x65\x20\x70\x6f\x73\x69\x74\x69\x76\x65\x0d\x0a"},
		{cmd_zpopmin, [][]u8{transmute([]u8)string("\x5a\x50\x4f\x50\x4d\x49\x4e"), transmute([]u8)string("\x70\x7a"), transmute([]u8)string("\x31"), transmute([]u8)string("\x32")}, "\x2d\x45\x52\x52\x20\x73\x79\x6e\x74\x61\x78\x20\x65\x72\x72\x6f\x72\x0d\x0a"},
		{cmd_zpopmax, [][]u8{transmute([]u8)string("\x5a\x50\x4f\x50\x4d\x41\x58"), transmute([]u8)string("\x70\x7a"), transmute([]u8)string("\x31\x2e\x35")}, "\x2d\x45\x52\x52\x20\x76\x61\x6c\x75\x65\x20\x69\x73\x20\x6f\x75\x74\x20\x6f\x66\x20\x72\x61\x6e\x67\x65\x2c\x20\x6d\x75\x73\x74\x20\x62\x65\x20\x70\x6f\x73\x69\x74\x69\x76\x65\x0d\x0a"},
		{cmd_zmpop, [][]u8{transmute([]u8)string("\x5a\x4d\x50\x4f\x50"), transmute([]u8)string("\x61"), transmute([]u8)string("\x70\x7a"), transmute([]u8)string("\x4d\x49\x4e")}, "\x2d\x45\x52\x52\x20\x6e\x75\x6d\x6b\x65\x79\x73\x20\x73\x68\x6f\x75\x6c\x64\x20\x62\x65\x20\x67\x72\x65\x61\x74\x65\x72\x20\x74\x68\x61\x6e\x20\x30\x0d\x0a"},
		{cmd_zrandmember, [][]u8{transmute([]u8)string("\x5a\x52\x41\x4e\x44\x4d\x45\x4d\x42\x45\x52"), transmute([]u8)string("\x72\x64\x30"), transmute([]u8)string("\x2d\x39\x32\x32\x33\x33\x37\x32\x30\x33\x36\x38\x35\x34\x37\x37\x35\x38\x30\x38")}, "\x2d\x45\x52\x52\x20\x76\x61\x6c\x75\x65\x20\x69\x73\x20\x6f\x75\x74\x20\x6f\x66\x20\x72\x61\x6e\x67\x65\x2c\x20\x76\x61\x6c\x75\x65\x20\x6d\x75\x73\x74\x20\x62\x65\x74\x77\x65\x65\x6e\x20\x2d\x39\x32\x32\x33\x33\x37\x32\x30\x33\x36\x38\x35\x34\x37\x37\x35\x38\x30\x37\x20\x61\x6e\x64\x20\x39\x32\x32\x33\x33\x37\x32\x30\x33\x36\x38\x35\x34\x37\x37\x35\x38\x30\x37\x0d\x0a"},
		{cmd_zrandmember, [][]u8{transmute([]u8)string("\x5a\x52\x41\x4e\x44\x4d\x45\x4d\x42\x45\x52"), transmute([]u8)string("\x72\x64\x30"), transmute([]u8)string("\x2d\x39\x32\x32\x33\x33\x37\x32\x30\x33\x36\x38\x35\x34\x37\x37\x35\x38\x30\x38"), transmute([]u8)string("\x57\x49\x54\x48\x53\x43\x4f\x52\x45\x53")}, "\x2d\x45\x52\x52\x20\x76\x61\x6c\x75\x65\x20\x69\x73\x20\x6f\x75\x74\x20\x6f\x66\x20\x72\x61\x6e\x67\x65\x2c\x20\x76\x61\x6c\x75\x65\x20\x6d\x75\x73\x74\x20\x62\x65\x74\x77\x65\x65\x6e\x20\x2d\x39\x32\x32\x33\x33\x37\x32\x30\x33\x36\x38\x35\x34\x37\x37\x35\x38\x30\x37\x20\x61\x6e\x64\x20\x39\x32\x32\x33\x33\x37\x32\x30\x33\x36\x38\x35\x34\x37\x37\x35\x38\x30\x37\x0d\x0a"},
		{cmd_zrandmember, [][]u8{transmute([]u8)string("\x5a\x52\x41\x4e\x44\x4d\x45\x4d\x42\x45\x52"), transmute([]u8)string("\x72\x64\x30"), transmute([]u8)string("\x2d\x39\x32\x32\x33\x33\x37\x32\x30\x33\x36\x38\x35\x34\x37\x37\x30\x30\x30\x30"), transmute([]u8)string("\x57\x49\x54\x48\x53\x43\x4f\x52\x45\x53")}, "\x2d\x45\x52\x52\x20\x76\x61\x6c\x75\x65\x20\x69\x73\x20\x6f\x75\x74\x20\x6f\x66\x20\x72\x61\x6e\x67\x65\x0d\x0a"},
		{cmd_zrandmember, [][]u8{transmute([]u8)string("\x5a\x52\x41\x4e\x44\x4d\x45\x4d\x42\x45\x52"), transmute([]u8)string("\x72\x64\x30"), transmute([]u8)string("\x39\x32\x32\x33\x33\x37\x32\x30\x33\x36\x38\x35\x34\x37\x37\x30\x30\x30\x30"), transmute([]u8)string("\x57\x49\x54\x48\x53\x43\x4f\x52\x45\x53")}, "\x2d\x45\x52\x52\x20\x76\x61\x6c\x75\x65\x20\x69\x73\x20\x6f\x75\x74\x20\x6f\x66\x20\x72\x61\x6e\x67\x65\x0d\x0a"},
	}
	for c in cases {
		conn := Conn{resp = 2}
		c.handler(&conn, c.args)
		testing.expect(t, string(conn.wbuf[:conn.wlen]) == c.expected)
		runtime.heap_free(conn.wbuf)
	}
}

zset_database_ready :: proc() {
	if db_cur == nil {
		db_init()
		block_init()
		zt.set_seed(8101)
		zset_seeded = true
	}
}

@(test)
zpop_resp3_count_shapes :: proc(t: ^testing.T) {
	saved_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer {
		context.allocator = saved_allocator
	}
	zset_database_ready()
	key := []u8{'p', 'o', 'p', '-', 's', 'h', 'a', 'p', 'e'}
	for use_sl in ([2]bool{false, true}) {
		for initial in ([2]int{1, 2}) {
			for explicit_count in ([2]bool{false, true}) {
				z := zt.create_listpack()
				if use_sl {
					zt.convert_to_skiplist(z, 0)
				}
				for i in 0 ..< initial {
					member := [1]u8{u8('a' + i)}
					_, _, _ = zt.add(z, f64(i + 1), member[:], {})
				}
				_ = zset_attach_new(key, z)
				conn := Conn{resp = 3}
				args := [3][]u8{[]u8{'z'}, key, []u8{'1'}}
				argc := explicit_count ? 3 : 2
				cmd_zpopmin(&conn, args[:argc])
				_, remaining, wrong := zset_lookup(key, true)
				testing.expect(t, !wrong && (remaining == nil) == (initial == 1))
				if remaining != nil {
					testing.expect(t, zt.length(remaining) == 1)
				}
				db_remove(key)
				expected := "*2\r\n$1\r\na\r\n,1\r\n"
				if explicit_count {
					expected = "*1\r\n*2\r\n$1\r\na\r\n,1\r\n"
				}
				testing.expect(t, string(conn.wbuf[:conn.wlen]) == expected)
				runtime.heap_free(conn.wbuf)
			}
		}
	}
}

@(test)
zset_nonstore_scores_and_error_precedence :: proc(t: ^testing.T) {
	saved_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer {
		context.allocator = saved_allocator
	}
	zset_database_ready()
	saved_entries, saved_value := zt.zset_max_listpack_entries, zt.zset_max_listpack_value
	zt.zset_max_listpack_entries = 128
	zt.zset_max_listpack_value = 64
	defer {
		zt.zset_max_listpack_entries = saved_entries
		zt.zset_max_listpack_value = saved_value
	}
	source_key := []u8{'s', 'c', 'o', 'r', 'e', '-', 's', 'r', 'c'}
	dest_key := []u8{'s', 'c', 'o', 'r', 'e', '-', 'd', 's', 't'}
	z := zt.create_listpack()
	_, _, _ = zt.add(z, 1, []u8{'a'}, {})
	_ = zset_attach_new(source_key, z)
	for resp in ([2]u8{2, 3}) {
		conn := Conn{resp = resp}
		args := [6][]u8{[]u8{'z'}, []u8{'1'}, source_key, []u8{'w', 'e', 'i', 'g', 'h', 't', 's'}, []u8{'-', '0'}, []u8{'w', 'i', 't', 'h', 's', 'c', 'o', 'r', 'e', 's'}}
		cmd_zunion(&conn, args[:])
		expected := "*2\r\n$1\r\na\r\n$2\r\n-0\r\n"
		if resp == 3 {
			expected = "*1\r\n*2\r\n$1\r\na\r\n,-0\r\n"
		}
		testing.expect(t, string(conn.wbuf[:conn.wlen]) == expected)
		runtime.heap_free(conn.wbuf)
	}
	conn := Conn{resp = 2}
	store_args := [6][]u8{[]u8{'z'}, dest_key, []u8{'1'}, source_key, []u8{'w', 'e', 'i', 'g', 'h', 't', 's'}, []u8{'-', '0'}}
	cmd_zunionstore(&conn, store_args[:])
	testing.expect(t, string(conn.wbuf[:conn.wlen]) == ":1\r\n")
	runtime.heap_free(conn.wbuf)
	_, stored, wrong := zset_lookup(dest_key, true)
	testing.expect(t, !wrong && stored != nil && stored.encoding == .Listpack)
	stored_score, found := zt.score(stored, []u8{'a'})
	testing.expect(t, found && transmute(u64)stored_score == 0)
	db_remove(source_key)
	db_remove(dest_key)
	str_key, missing := []u8{'s', 't', 'r'}, []u8{'n', 'o', 'k', 'e', 'y'}
	e, _ := db_upsert(str_key)
	entry_assign(e, []u8{'v'})
	testing.expect(t, entry_type(e) == .String)
	conn = Conn{resp = 2}
	bad_union := [6][]u8{[]u8{'z'}, []u8{'2'}, str_key, missing, []u8{'w', 'e', 'i', 'g', 'h', 't', 's'}, []u8{'x'}}
	cmd_zunion(&conn, bad_union[:])
	testing.expect(t, string(conn.wbuf[:conn.wlen]) == "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n")
	runtime.heap_free(conn.wbuf)
	db_remove(str_key)
	conn = Conn{resp = 2}
	bad_card := [5][]u8{[]u8{'z'}, []u8{'1'}, missing, []u8{'l', 'i', 'm', 'i', 't'}, []u8{'x'}}
	cmd_zintercard(&conn, bad_card[:])
	testing.expect(t, string(conn.wbuf[:conn.wlen]) == "-ERR LIMIT can't be negative\r\n")
	runtime.heap_free(conn.wbuf)
	for i := 0; i < 1024 && zt.maintenance_pending(); i += 1 {
		zt.maintenance_release()
	}
	testing.expect(t, !zt.maintenance_pending())
}

@(test)
zset_mpop_count_replies :: proc(t: ^testing.T) {
	saved_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer {
		context.allocator = saved_allocator
	}
	zset_database_ready()
	key := []u8{'m', 'p', 'o', 'p', '-', 'e', 'd', 'g', 'e'}
	for resp in ([2]u8{2, 3}) {
		for blocking in ([2]bool{false, true}) {
			for text in ([9]string{"x", "0", "-1", "+1", "01", "1.0", "9223372036854775808", "-9223372036854775809", "1"}) {
				z := zt.create_listpack()
				_, _, _ = zt.add(z, 1, []u8{'m'}, {})
				_ = zset_attach_new(key, z)
				conn := Conn{resp = resp}
				args := [7][]u8{[]u8{'z'}, []u8{'0'}, []u8{'1'}, key, []u8{'m', 'i', 'n'}, []u8{'c', 'o', 'u', 'n', 't'}, transmute([]u8)text}
				if blocking {
					cmd_bzmpop(&conn, args[:])
				} else {
					args[1] = []u8{'z', 'm', 'p', 'o', 'p'}
					cmd_zmpop(&conn, args[1:])
				}
				expected := "-ERR count should be greater than 0\r\n"
				_, remaining, wrong := zset_lookup(key, true)
				if text == "1" {
					testing.expect(t, !wrong && remaining == nil)
					expected = "*2\r\n$9\r\nmpop-edge\r\n*1\r\n*2\r\n$1\r\nm\r\n$1\r\n1\r\n"
					if resp == 3 {
						expected = "*2\r\n$9\r\nmpop-edge\r\n*1\r\n*2\r\n$1\r\nm\r\n,1\r\n"
					}
				} else {
					testing.expect(t, !wrong && remaining != nil && zt.length(remaining) == 1)
				}
				db_remove(key)
				testing.expect(t, string(conn.wbuf[:conn.wlen]) == expected)
				runtime.heap_free(conn.wbuf)
			}
		}
	}
}

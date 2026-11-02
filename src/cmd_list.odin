package main

import lt "listtype"
import "core:fmt"

list_move_buf: [dynamic]u8

list_positions: [dynamic]int

	list_commands := [?]Command {
	{"lpush", cmd_lpush, -3},
	{"rpush", cmd_rpush, -3},
	{"lpushx", cmd_lpushx, -3},
	{"rpushx", cmd_rpushx, -3},
	{"linsert", cmd_linsert, 5},
	{"llen", cmd_llen, 2},
	{"lindex", cmd_lindex, 3},
	{"lset", cmd_lset, 4},
	{"lpop", cmd_lpop, -2},
	{"rpop", cmd_rpop, -2},
	{"lmpop", cmd_lmpop, -4},
	{"lrange", cmd_lrange, 4},
	{"ltrim", cmd_ltrim, 4},
	{"lpos", cmd_lpos, -3},
	{"lrem", cmd_lrem, 4},
	{"lmove", cmd_lmove, 5},
	{"rpoplpush", cmd_rpoplpush, 3},
	{"blpop", cmd_blpop, -3},
	{"brpop", cmd_brpop, -3},
	{"blmpop", cmd_blmpop, -5},
	{"blmove", cmd_blmove, 6},
	{"brpoplpush", cmd_brpoplpush, 4},
}

list_obj_encoding :: proc "contextless" (l: lt.List) -> Obj_Encoding {
	if l.encoding == .Listpack {
		return .Listpack
	}
	return .Quicklist
}

list_object_release :: proc "contextless" (obj: rawptr) -> int {
	l := cast(lt.List)obj
	if l == nil {
		return 0
	}
	n := l.acct
	lt.destroy(l)
	return n
}

list_object_acct :: proc "contextless" (obj: rawptr) -> int {
	l := cast(lt.List)obj
	if l == nil {
		return 0
	}
	return l.acct
}

list_memory :: proc "contextless" (obj: rawptr) -> int {
	if obj == nil {
		return 0
	}
	return lt.memory_usage(cast(lt.List)obj)
}

list_sync :: proc "contextless" (db: ^Db, l: lt.List) {
	n := lt.memory_usage(l)
	object_account(db, n-l.acct)
	l.acct = n
}

list_done :: proc "contextless" (e: ^Entry, l: lt.List) {
	entry_set_encoding(e, list_obj_encoding(l))
	list_sync(e.db, l)
}

list_lookup :: proc(key: []u8, read: bool) -> (e: ^Entry, l: lt.List, wrong: bool) {
	if read {
		e = db_find_read(key)
	} else {
		e = db_find(key)
	}
	if e == nil {
		return
	}
	if entry_type(e) != .List {
		wrong = true
		return
	}
	l = cast(lt.List)entry_object(e, .List)
	return
}

list_create :: proc(key: []u8) -> (e: ^Entry, l: lt.List) {
	e, _ = db_upsert(key)
	l = lt.create()
	l.acct = lt.memory_usage(l)
	entry_object_attach(e, l, .List, list_obj_encoding(l), l.acct)
	block_signal_key(e.db, key, .List)
	return
}

reply_list_error :: proc(c: ^Conn, err: lt.Error) {
	buf: [512]u8
	message := fmt.bprintf(buf[:], "ERR %s", lt.error_message(err))
	reply_error(c, message)
}

reply_list_value :: proc(c: ^Conn, v: lt.Value) {
	buf: [21]u8
	reply_bulk(c, lt.value_bytes(v, &buf))
}

list_after_remove :: proc(key: []u8, e: ^Entry, l: lt.List, event: string) {
	notify(.List, event, key)
	if lt.length(l) == 0 {
		db_remove(key)
		notify(.Generic, "del", key)
	} else {
		lt.try_conversion(l, .Shrinking)
		list_done(e, l)
	}
	signal_key(key)
}

pop_event :: proc(where_: lt.Where) -> string {
	if where_ == .Head {
		return "lpop"
	}
	return "rpop"
}

push_event :: proc(where_: lt.Where) -> string {
	if where_ == .Head {
		return "lpush"
	}
	return "rpush"
}

list_range_reply :: proc(c: ^Conn, l: lt.List, start: int, end: int, reverse: bool) {
	s, e, ok := lt.range_normalize(lt.length(l), start, end)
	if !ok {
		reply_array(c, 0)
		return
	}
	reply_array(c, e-s+1)
	idx := s
	dir := lt.Where.Tail
	if reverse {
		idx = e
		dir = .Head
	}
	it := lt.iterator(l, idx, dir)
	entry: lt.List_Entry
	for _ in 0..<e-s+1 {
		if !lt.iter_next(&it, &entry) {
			break
		}
		reply_list_value(c, lt.entry_value(&it, &entry))
	}
}

push_generic :: proc(c: ^Conn, argv: [][]u8, where_: lt.Where, xx: bool) {
	pst.dirty_explicit = true
	key := argv[1]
	e, l, wrong := list_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if l == nil {
		if xx {
			reply_int(c, 0)
			return
		}
		e, l = list_create(key)
	}
	pst.dirty += i64(len(argv) - 2)
	lt.try_conversion_append_values(l, argv[2:])
	for v in argv[2:] {
		lt.push(l, v, where_)
	}
	list_done(e, l)
	signal_key(key)
	notify(.List, push_event(where_), key)
	block_signal_key(e.db, key, .List)
	reply_int(c, i64(lt.length(l)))
}

cmd_lpush :: proc(c: ^Conn, argv: [][]u8) {
	push_generic(c, argv, .Head, false)
}

cmd_rpush :: proc(c: ^Conn, argv: [][]u8) {
	push_generic(c, argv, .Tail, false)
}

cmd_lpushx :: proc(c: ^Conn, argv: [][]u8) {
	push_generic(c, argv, .Head, true)
}

cmd_rpushx :: proc(c: ^Conn, argv: [][]u8) {
	push_generic(c, argv, .Tail, true)
}

cmd_linsert :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	after, err := lt.parse_linsert_where(argv[2])
	if err != .None {
		reply_list_error(c, err)
		return
	}
	e, l, wrong := list_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if l == nil {
		reply_int(c, 0)
		return
	}
	if !lt.linsert(l, after, argv[3], argv[4]) {
		list_done(e, l)
		reply_int(c, -1)
		return
	}
	pst.dirty += 1
	list_done(e, l)
	signal_key(argv[1])
	notify(.List, "linsert", argv[1])
	block_signal_key(e.db, argv[1], .List)
	reply_int(c, i64(lt.length(l)))
}

cmd_llen :: proc(c: ^Conn, argv: [][]u8) {
	_, l, wrong := list_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_int(c, i64(lt.length(l)))
}

cmd_lindex :: proc(c: ^Conn, argv: [][]u8) {
	_, l, wrong := list_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if l == nil {
		reply_null(c)
		return
	}
	idx, err := lt.parse_index(argv[2])
	if err != .None {
		reply_list_error(c, err)
		return
	}
	v, ok := lt.index(l, idx)
	if !ok {
		reply_null(c)
	} else {
		reply_list_value(c, v)
	}
}

cmd_lset :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	e, l, wrong := list_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if l == nil {
		reply_list_error(c, .No_Such_Key)
		return
	}
	idx, err := lt.parse_index(argv[2])
	if err != .None {
		reply_list_error(c, err)
		return
	}
	if !lt.lset(l, idx, argv[3]) {
		list_done(e, l)
		reply_list_error(c, .Index_Out_Of_Range)
		return
	}
	pst.dirty += 1
	list_done(e, l)
	signal_key(argv[1])
	notify(.List, "lset", argv[1])
	reply_ok(c)
}

pop_generic :: proc(c: ^Conn, argv: [][]u8, where_: lt.Where, name: string) {
	pst.dirty_explicit = true
	if len(argv) > 3 {
		reply_wrong_args(c, name)
		return
	}
	count := 1
	many := len(argv) == 3
	if many {
		err: lt.Error
		count, err = lt.parse_pop_count(argv[2])
		if err != .None {
			reply_list_error(c, err)
			return
		}
	}
	e, l, wrong := list_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if l == nil {
		if many {
			reply_null_array(c)
		} else {
			reply_null(c)
		}
		return
	}
	count = min(count, lt.length(l))
	if many {
		reply_array(c, count)
	}
	if count == 0 {
		return
	}
	idx := 0
	dir := lt.Where.Tail
	if where_ == .Tail {
		idx = -1
		dir = .Head
	}
	it := lt.iterator(l, idx, dir)
	entry: lt.List_Entry
	for _ in 0..<count {
		if !lt.iter_next(&it, &entry) {
			break
		}
		reply_list_value(c, lt.entry_value(&it, &entry))
	}
	pst.dirty += i64(count)
	start, n := lt.pop_range_bounds(l, where_, count)
	lt.delete_range(l, start, n)
	lt.try_conversion(l, .Shrinking)
	list_after_remove(argv[1], e, l, pop_event(where_))
}

cmd_lpop :: proc(c: ^Conn, argv: [][]u8) {
	pop_generic(c, argv, .Head, "lpop")
}

cmd_rpop :: proc(c: ^Conn, argv: [][]u8) {
	pop_generic(c, argv, .Tail, "rpop")
}

list_pop_with_key :: proc(c: ^Conn, key: []u8, e: ^Entry, l: lt.List, where_: lt.Where, count: int) {
	reply_array(c, 2)
	reply_bulk(c, key)
	n := 1
	if count >= 0 {
		n = min(count, lt.length(l))
		reply_array(c, n)
	}
	idx := 0
	dir := lt.Where.Tail
	if where_ == .Tail {
		idx = -1
		dir = .Head
	}
	it := lt.iterator(l, idx, dir)
	entry: lt.List_Entry
	for _ in 0..<n {
		if !lt.iter_next(&it, &entry) {
			break
		}
		reply_list_value(c, lt.entry_value(&it, &entry))
	}
	pst.dirty_explicit = true
	pst.dirty += i64(n)
	start, actual := lt.pop_range_bounds(l, where_, n)
	lt.delete_range(l, start, actual)
	lt.try_conversion(l, .Shrinking)
	list_after_remove(key, e, l, pop_event(where_))
}

cmd_lmpop :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	a, err := lt.parse_mpop_args(argv, 1)
	if err != .None {
		reply_list_error(c, err)
		return
	}
	for key in argv[2:2+a.numkeys] {
		e, l, wrong := list_lookup(key, false)
		if wrong {
			reply_wrongtype(c)
			return
		}
		if l != nil && lt.length(l) > 0 {
			list_pop_with_key(c, key, e, l, a.where_, a.count)
			return
		}
	}
	reply_null_array(c)
}

cmd_lrange :: proc(c: ^Conn, argv: [][]u8) {
	start, err := lt.parse_index(argv[2])
	if err != .None {
		reply_list_error(c, err)
		return
	}
	end, e2 := lt.parse_index(argv[3])
	if e2 != .None {
		reply_list_error(c, e2)
		return
	}
	_, l, wrong := list_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if l == nil {
		reply_array(c, 0)
		return
	}
	list_range_reply(c, l, start, end, false)
}

cmd_ltrim :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	start, err := lt.parse_index(argv[2])
	if err != .None {
		reply_list_error(c, err)
		return
	}
	end, e2 := lt.parse_index(argv[3])
	if e2 != .None {
		reply_list_error(c, e2)
		return
	}
	e, l, wrong := list_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if l != nil {
		before := lt.length(l)
		lt.ltrim(l, start, end)
		pst.dirty += i64(before - lt.length(l))
		list_after_remove(argv[1], e, l, "ltrim")
	}
	reply_ok(c)
}

cmd_lpos :: proc(c: ^Conn, argv: [][]u8) {
	a, err := lt.parse_lpos_args(argv[3:])
	if err != .None {
		reply_list_error(c, err)
		return
	}
	_, l, wrong := list_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if l == nil {
		if a.count == -1 {
			reply_null(c)
		} else {
			reply_array(c, 0)
		}
		return
	}
	clear(&list_positions)
	pos := lt.lpos(l, argv[2], a.rank, a.count, a.maxlen, &list_positions)
	if a.count == -1 {
		if pos < 0 {
			reply_null(c)
		} else {
			reply_int(c, i64(pos))
		}
	} else {
		reply_array(c, len(list_positions))
		for n in list_positions {
			reply_int(c, i64(n))
		}
	}
}

cmd_lrem :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	n, err := lt.parse_lrem_count(argv[2])
	if err != .None {
		reply_list_error(c, err)
		return
	}
	e, l, wrong := list_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	removed := 0
	if l != nil {
		removed = lt.lrem(l, n, argv[3])
		pst.dirty += i64(removed)
		if removed != 0 {
			list_after_remove(argv[1], e, l, "lrem")
		}
	}
	reply_int(c, i64(removed))
}

lmove_generic :: proc(c: ^Conn, argv: [][]u8, wherefrom: lt.Where, whereto: lt.Where) {
	pst.dirty_explicit = true
	source := argv[1]
	destination := argv[2]
	se, src, wrong := list_lookup(source, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if src == nil || lt.length(src) == 0 {
		reply_null(c)
		return
	}
	de, dst, bad := list_lookup(destination, false)
	if bad {
		reply_wrongtype(c)
		return
	}
	same := string(source) == string(destination)
	v, _ := lt.peek(src, wherefrom)
	scratch: [21]u8
	bytes := lt.value_bytes(v, &scratch)
	clear(&list_move_buf)
	append(&list_move_buf, ..bytes)
	owned := list_move_buf[:]
	if dst == nil {
		de, dst = list_create(destination)
	}
	source_encoding := src.encoding
	if same {
		lt.pop_discard(src, wherefrom)
	}
	lt.try_conversion_append(dst, lt.moved_add_bytes(source_encoding, v, len(owned)), 1)
	lt.push(dst, owned, whereto)
	list_done(de, dst)
	signal_key(destination)
	notify(.List, push_event(whereto), destination)
	block_signal_key(de.db, destination, .List)
	if !same {
		lt.pop_discard(src, wherefrom)
	}
	se, _, _ = list_lookup(source, false)
	list_after_remove(source, se, src, pop_event(wherefrom))
	pst.dirty += 1
	reply_bulk(c, owned)
}

cmd_lmove :: proc(c: ^Conn, argv: [][]u8) {
	from, err := lt.parse_direction(argv[3])
	if err != .None {
		reply_list_error(c, err)
		return
	}
	to, e2 := lt.parse_direction(argv[4])
	if e2 != .None {
		reply_list_error(c, e2)
		return
	}
	lmove_generic(c, argv, from, to)
}

cmd_rpoplpush :: proc(c: ^Conn, argv: [][]u8) {
	lmove_generic(c, argv, .Tail, .Head)
}

list_copy_dup :: proc(src: ^Entry) -> (obj: rawptr, extra: u64, ok: bool) {
	if entry_type(src) != .List {
		return nil, 0, false
	}
	l := lt.dup(cast(lt.List)entry_object(src, .List))
	return l, 0, true
}

list_copy_attach :: proc(dst: ^Entry, obj: rawptr) {
	l := cast(lt.List)obj
	l.acct = lt.memory_usage(l)
	entry_object_attach(dst, l, .List, list_obj_encoding(l), l.acct)
}

list_sort_len :: proc(e: ^Entry) -> i64 {
	if e == nil || entry_type(e) != .List {
		return 0
	}
	return i64(lt.length(cast(lt.List)entry_object(e, .List)))
}

list_sort_load :: proc(e: ^Entry, natural: bool, desc: bool, start: i64, end: i64, count: i64) -> (direct: bool) {
	if e == nil || entry_type(e) != .List {
		return false
	}
	l := cast(lt.List)entry_object(e, .List)
	n := lt.length(l)
	begin := 0
	take := n
	dir := lt.Where.Tail
	if natural {
		if count == 0 || start >= i64(n) || end < start {
			return false
		}
		begin = int(start)
		take = min(int(end-start+1), n-begin)
		if take <= 0 {
			return false
		}
		if desc {
			begin = n-1-begin
			dir = .Head
		}
	}
	it := lt.iterator(l, begin, dir)
	entry: lt.List_Entry
	buf: [21]u8
	for _ in 0..<take {
		if !lt.iter_next(&it, &entry) {
			break
		}
		sort_add_element(lt.value_bytes(lt.entry_value(&it, &entry), &buf))
	}
	return natural
}

list_sort_store :: proc(key: []u8, values: [][]u8) {
	if len(values) == 0 {
		db_remove(key)
		return
	}
	l := lt.create_quicklist()
	for v in values {
		lt.push(l, v, .Tail)
	}
	lt.try_conversion(l, .Auto)
	e, _ := db_upsert(key)
	l.acct = lt.memory_usage(l)
	entry_object_attach(e, l, .List, list_obj_encoding(l), l.acct)
	entry_set_expire(e, 0)
	block_signal_key(e.db, key, .List)
}

list_debug_object_extra :: proc(b: ^[dynamic]u8, e: ^Entry) {
	if e == nil || entry_type(e) != .List {
		return
	}
	info, ok := lt.quicklist_info(cast(lt.List)entry_object(e, .List))
	if !ok {
		return
	}
	avg: [64]u8
	text: [256]u8
	compressed := 0
	if info.compressed {
		compressed = 1
	}
	s := fmt.bprintf(text[:], " ql_nodes:%d ql_avg_node:%s ql_listpack_max:%d ql_compressed:%d ql_uncompressed_size:%d", info.nodes, lt.format_avg_node(info, avg[:]), info.fill, compressed, info.uncompressed_size)
	append(b, ..transmute([]u8)s)
}

list_debug :: proc(c: ^Conn, argv: [][]u8) -> (handled: bool) {
	if len(argv) < 2 || !lt.eq_nocase(argv[1], "quicklist-packed-threshold") {
		return false
	}
	if len(argv) != 3 {
		reply_subcommand_syntax_error(c, argv[1], "DEBUG")
		return true
	}
	err := lt.parse_packed_threshold(argv[2])
	if err != .None {
		reply_list_error(c, err)
	} else {
		reply_ok(c)
	}
	return true
}

@(init)
register_list_commands :: proc "contextless" () {
	register_commands(list_commands[:])
}

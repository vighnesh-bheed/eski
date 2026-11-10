package main

import st "settype"
import ht "hashtype"

SRANDMEMBER_RANGE_ERROR :: "ERR value is out of range, value must between -9223372036854775807 and 9223372036854775807"

set_vals: [dynamic]st.Member

set_pop: st.Popped

set_srcs: [dynamic]st.Set

@(private = "file")
set_commands := [?]Command {
	{"sadd", cmd_sadd, -3},
	{"srem", cmd_srem, -3},
	{"smove", cmd_smove, 4},
	{"sismember", cmd_sismember, 3},
	{"smismember", cmd_smismember, -3},
	{"scard", cmd_scard, 2},
	{"spop", cmd_spop, -2},
	{"srandmember", cmd_srandmember, -2},
	{"smembers", cmd_smembers, 2},
	{"sinter", cmd_sinter, -2},
	{"sintercard", cmd_sintercard, -3},
	{"sinterstore", cmd_sinterstore, -3},
	{"sunion", cmd_sunion, -2},
	{"sunionstore", cmd_sunionstore, -3},
	{"sdiff", cmd_sdiff, -2},
	{"sdiffstore", cmd_sdiffstore, -3},
	{"sscan", cmd_sscan, -3},
}

set_resize_db_next: int

set_obj_encoding :: proc "contextless" (s: st.Set) -> Obj_Encoding {
	switch s.encoding {
	case .Intset:
		return .Intset
	case .Listpack:
		return .Listpack
	case .Hashtable:
		return .Hashtable
	}
	return .Hashtable
}

set_object_release :: proc "contextless" (obj: rawptr) -> int {
	s := cast(st.Set)obj
	if s == nil {
		return 0
	}
	n := s.acct
	st.destroy(s)
	return n
}

set_object_move :: proc "contextless" (obj: rawptr, from: ^Db, to: ^Db) -> int {
	s := cast(st.Set)obj
	if s == nil {
		return 0
	}
	st.maintenance_bind(s, to.sctx)
	return s.acct
}

set_object_acct :: proc "contextless" (obj: rawptr) -> int {
	s := cast(st.Set)obj
	return s.acct if s != nil else 0
}

set_sync :: proc "contextless" (db: ^Db, s: st.Set) {
	st.maintenance_bind(s, db.sctx)
	n := st.memory_usage(s)
	object_account(db, n - s.acct)
	s.acct = n
}

set_done :: proc "contextless" (e: ^Entry, s: st.Set) {
	entry_set_encoding(e, set_obj_encoding(s))
	set_sync(e.db, s)
}

set_attach :: proc "contextless" (e: ^Entry, s: st.Set) {
	s.acct = st.memory_usage(s)
	entry_object_attach(e, s, .Set, set_obj_encoding(s), s.acct)
	st.maintenance_bind(s, e.db.sctx)
}

set_lookup :: proc(key: []u8, read: bool) -> (e: ^Entry, s: st.Set, wrong: bool) {
	e = db_find_read(key) if read else db_find(key)
	if e == nil {
		return
	}
	if entry_type(e) != .Set {
		return e, nil, true
	}
	return e, cast(st.Set)entry_object(e, .Set), false
}

reply_set_value :: proc(c: ^Conn, v: st.Member) {
	buf: [21]u8
	reply_bulk(c, st.value_bytes(v, &buf))
}

reply_set_members :: proc(c: ^Conn, s: st.Set) {
	reply_set(c, st.size(s))
	it := st.iterator(s)
	for {
		value, ok := st.next(&it)
		if !ok {
			break
		}
		reply_set_value(c, value)
	}
}

set_scratch_trim :: proc() {
	clear(&set_vals)
	clear(&set_srcs)
	st.popped_reset(&set_pop)
	if cap(set_vals) > 65536 {
		delete(set_vals)
		set_vals = nil
	}
	if cap(set_srcs) > 65536 {
		delete(set_srcs)
		set_srcs = nil
	}
	if cap(set_pop.arena) > 1 << 20 {
		delete(set_pop.arena)
		set_pop.arena = nil
	}
	if cap(set_pop.items) > 65536 {
		delete(set_pop.items)
		set_pop.items = nil
	}
}

set_sort_len :: proc(e: ^Entry) -> i64 {
	if e == nil || entry_type(e) != .Set {
		return 0
	}
	return i64(st.size(cast(st.Set)entry_object(e, .Set)))
}

set_sort_load :: proc(e: ^Entry) {
	if e == nil || entry_type(e) != .Set {
		return
	}
	it := st.iterator(cast(st.Set)entry_object(e, .Set))
	for {
		value, ok := st.next(&it)
		if !ok {
			break
		}
		buffer: [21]u8
		sort_add_element(st.value_bytes(value, &buffer))
	}
}

set_copy_dup :: proc(src: ^Entry) -> (obj: rawptr, extra: u64, ok: bool) {
	if entry_type(src) != .Set {
		return nil, 0, false
	}
	return st.dup(cast(st.Set)entry_object(src, .Set)), 0, true
}

set_copy_attach :: proc(dst: ^Entry, obj: rawptr) {
	set_attach(dst, cast(st.Set)obj)
}

cmd_sadd :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	key := argv[1]
	e, s, wrong := set_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		s = st.create(argv[2], len(argv) - 2)
		e, _ = db_upsert(key)
		set_attach(e, s)
	} else {
		st.maybe_convert(s, len(argv) - 2)
	}
	added := 0
	for member in argv[2:] {
		added += int(st.add(s, member))
	}
	pst.dirty += i64(added)
	set_done(e, s)
	if added > 0 {
		signal_key(key)
		notify(.Set, "sadd", key)
	}
	reply_int(c, i64(added))
}

cmd_srem :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	key := argv[1]
	e, s, wrong := set_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	removed := 0
	if s != nil {
		for member in argv[2:] {
			removed += int(st.remove(s, member))
		}
	}
	pst.dirty += i64(removed)
	if removed > 0 {
		set_done(e, s)
		empty := st.size(s) == 0
		if empty {
			db_remove(key)
		}
		signal_key(key)
		notify(.Set, "srem", key)
		if empty {
			notify(.Generic, "del", key)
		}
	}
	reply_int(c, i64(removed))
}

cmd_smove :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	source, destination, member := argv[1], argv[2], argv[3]
	_, src, wrong := set_lookup(source, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if src == nil {
		reply_int(c, 0)
		return
	}
	de, dst, bad := set_lookup(destination, false)
	if bad {
		reply_wrongtype(c)
		return
	}
	if !st.is_member(src, member) {
		reply_int(c, 0)
		return
	}
	if string(source) == string(destination) {
		reply_int(c, 1)
		return
	}
	st.remove(src, member)
	se := db_find(source)
	set_done(se, src)
	empty := st.size(src) == 0
	if empty {
		db_remove(source)
	}
	signal_key(source)
	notify(.Set, "srem", source)
	if empty {
		notify(.Generic, "del", source)
	}
	if dst == nil {
		dst = st.create(member, 1)
		de, _ = db_upsert(destination)
		set_attach(de, dst)
	} else {
		de = db_find(destination)
	}
	added := st.add(dst, member)
	pst.dirty += 1 + i64(added)
	set_done(de, dst)
	if added {
		signal_key(destination)
		notify(.Set, "sadd", destination)
	}
	reply_int(c, 1)
}

cmd_sismember :: proc(c: ^Conn, argv: [][]u8) {
	_, s, wrong := set_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_int(c, i64(s != nil && st.is_member(s, argv[2])))
}

cmd_smismember :: proc(c: ^Conn, argv: [][]u8) {
	_, s, wrong := set_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_array(c, len(argv) - 2)
	for member in argv[2:] {
		reply_int(c, i64(s != nil && st.is_member(s, member)))
	}
}

cmd_scard :: proc(c: ^Conn, argv: [][]u8) {
	_, s, wrong := set_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_int(c, i64(st.size(s)))
}

spop_with_count :: proc(c: ^Conn, argv: [][]u8) {
	requested, valid := parse_i64(argv[2])
	if !valid {
		reply_error(c, "ERR value is out of range, must be positive")
		return
	}
	if requested < 0 {
		reply_error(c, "ERR value is out of range, must be positive")
		return
	}
	e, s, wrong := set_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	n := min(requested, i64(st.size(s)))
	reply_set(c, int(n))
	pst.dirty += n
	if n == 0 {
		return
	}
	st.popped_reset(&set_pop)
	all := int(n) == st.size(s)
	if all {
		sources := []st.Set{s}
		reply_set_object := st.union_diff(sources, .Union)
		it := st.iterator(reply_set_object)
		for {
			value, ok := st.next(&it)
			if !ok {
				break
			}
			st.popped_push(&set_pop, value)
		}
		st.destroy(reply_set_object)
	} else {
		replacement := st.spop_count(s, int(n), &set_pop)
		if replacement != nil {
			set_done(e, s)
			set_attach(e, replacement)
			s = replacement
		}
	}
	for index in 0 ..< st.popped_len(&set_pop) {
		reply_set_value(c, st.popped_get(&set_pop, index))
	}
	if all {
		set_done(e, s)
		db_remove(argv[1])
		signal_key(argv[1])
		notify(.Set, "spop", argv[1])
		notify(.Generic, "del", argv[1])
		st.popped_reset(&set_pop)
		return
	}
	set_done(e, s)
	signal_key(argv[1])
	notify(.Set, "spop", argv[1])
	st.popped_reset(&set_pop)
}

cmd_spop :: proc(c: ^Conn, argv: [][]u8) {
	pst.dirty_explicit = true
	if len(argv) > 3 {
		reply_error(c, "ERR syntax error")
		return
	}
	if len(argv) == 3 {
		spop_with_count(c, argv)
		return
	}
	e, s, wrong := set_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_null(c)
		return
	}
	st.popped_reset(&set_pop)
	st.pop_random(s, &set_pop)
	pst.dirty += 1
	reply_set_value(c, st.popped_get(&set_pop, 0))
	set_done(e, s)
	empty := st.size(s) == 0
	if empty {
		db_remove(argv[1])
	}
	signal_key(argv[1])
	notify(.Set, "spop", argv[1])
	if empty {
		notify(.Generic, "del", argv[1])
	}
	st.popped_reset(&set_pop)
}

srandmember_with_count :: proc(c: ^Conn, argv: [][]u8) {
	count, valid := parse_i64(argv[2])
	if !valid {
		reply_error(c, "ERR value is not an integer or out of range")
		return
	}
	if count == min(i64) {
		reply_error(c, SRANDMEMBER_RANGE_ERROR)
		return
	}
	_, s, wrong := set_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_array(c, 0)
		return
	}
	n := min(count, i64(st.size(s))) if count >= 0 else -count
	reply_array(c, int(n))
	clear(&set_vals)
	if count >= 0 {
		st.random_unique(s, int(n), &set_vals)
		for value in set_vals {
			reply_set_value(c, value)
		}
	} else {
		remaining := n
		for remaining > 0 {
			clear(&set_vals)
			batch := min(remaining, st.SRANDMEMBER_REPLY_BATCH)
			st.random_with_repeats(s, int(batch), &set_vals)
			for value in set_vals {
				reply_set_value(c, value)
			}
			remaining -= batch
		}
	}
	clear(&set_vals)
}

cmd_srandmember :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) > 3 {
		reply_error(c, "ERR syntax error")
		return
	}
	if len(argv) == 3 {
		srandmember_with_count(c, argv)
		return
	}
	_, s, wrong := set_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_null(c)
	} else {
		reply_set_value(c, st.random_element(s))
	}
}

set_gather :: proc(c: ^Conn, keys: [][]u8) -> (ok: bool, empty: int) {
	clear(&set_srcs)
	for key in keys {
		_, s, wrong := set_lookup(key, true)
		if wrong {
			reply_wrongtype(c)
			clear(&set_srcs)
			return false, empty
		}
		append(&set_srcs, s)
		empty += int(s == nil)
	}
	return true, empty
}

set_store_delete :: proc(key: []u8) {
	removed, expired := db_remove(key)
	pst.dirty_explicit = true
	if removed {
		if !expired { pst.dirty += 1 }
		signal_key(key)
		notify(.Generic, "del", key)
	}
}

set_store_result :: proc(c: ^Conn, key: []u8, d: st.Set, event: string) {
	pst.dirty_explicit = true
	n := st.size(d)
	if n == 0 {
		st.destroy(d)
		set_store_delete(key)
	} else {
		pst.dirty += 1
		e, _ := db_upsert(key)
		set_attach(e, d)
		entry_set_expire(e, 0)
		signal_key(key)
		notify(.Set, event, key)
	}
	reply_int(c, i64(n))
}

sinter_generic :: proc(c: ^Conn, keys: [][]u8, dstkey: []u8, store: bool) {
	if store { pst.dirty_explicit = true }
	ok, _ := set_gather(c, keys)
	if !ok {
		return
	}
	if store {
		result := st.inter_store(set_srcs[:])
		clear(&set_srcs)
		set_store_result(c, dstkey, result, "sinterstore")
	} else {
		clear(&set_vals)
		st.inter_collect(set_srcs[:], &set_vals)
		reply_set(c, len(set_vals))
		for value in set_vals {
			reply_set_value(c, value)
		}
		clear(&set_vals)
		clear(&set_srcs)
	}
}

sunion_diff_generic :: proc(c: ^Conn, keys: [][]u8, dstkey: []u8, store: bool, op: st.Op) {
	if store { pst.dirty_explicit = true }
	ok, _ := set_gather(c, keys)
	if !ok {
		return
	}
	result := st.union_diff(set_srcs[:], op)
	clear(&set_srcs)
	if store {
		set_store_result(c, dstkey, result, "sunionstore" if op == .Union else "sdiffstore")
	} else {
		reply_set_members(c, result)
		st.destroy(result)
	}
}

cmd_smembers :: proc(c: ^Conn, argv: [][]u8) {
	_, s, wrong := set_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_set_members(c, s)
}

cmd_sinter :: proc(c: ^Conn, argv: [][]u8) {
	sinter_generic(c, argv[1:], nil, false)
}

cmd_sinterstore :: proc(c: ^Conn, argv: [][]u8) {
	sinter_generic(c, argv[2:], argv[1], true)
}

cmd_sunion :: proc(c: ^Conn, argv: [][]u8) {
	sunion_diff_generic(c, argv[1:], nil, false, .Union)
}

cmd_sunionstore :: proc(c: ^Conn, argv: [][]u8) {
	sunion_diff_generic(c, argv[2:], argv[1], true, .Union)
}

cmd_sdiff :: proc(c: ^Conn, argv: [][]u8) {
	sunion_diff_generic(c, argv[1:], nil, false, .Diff)
}

cmd_sdiffstore :: proc(c: ^Conn, argv: [][]u8) {
	sunion_diff_generic(c, argv[2:], argv[1], true, .Diff)
}

cmd_sintercard :: proc(c: ^Conn, argv: [][]u8) {
	numkeys, valid := parse_i64(argv[1])
	if !valid || numkeys <= 0 {
		reply_error(c, "ERR numkeys should be greater than 0")
		return
	}
	if numkeys > i64(len(argv) - 2) {
		reply_error(c, "ERR Number of keys can't be greater than number of args")
		return
	}
	limit := i64(0)
	end := 2 + int(numkeys)
	for position := end; position < len(argv); position += 2 {
		if position + 1 >= len(argv) || !eq_nocase(argv[position], "limit") {
			reply_error(c, "ERR syntax error")
			return
		}
		limit, valid = parse_i64(argv[position + 1])
		if !valid || limit < 0 {
			reply_error(c, "ERR LIMIT can't be negative")
			return
		}
	}
	ok, _ := set_gather(c, argv[2:end])
	if ok {
		reply_int(c, i64(st.inter_card(set_srcs[:], int(limit))))
		clear(&set_srcs)
	}
}

reply_cursor :: proc(c: ^Conn, v: u64) {
	buffer: [21]u8
	n := format_u64(raw_data(buffer[:]), v)
	reply_bulk(c, buffer[:n])
}

cmd_sscan :: proc(c: ^Conn, argv: [][]u8) {
	cursor, valid := ht.parse_scan_cursor(argv[2])
	if !valid {
		reply_error(c, "ERR invalid cursor")
		return
	}
	_, s, wrong := set_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if s == nil {
		reply_array(c, 2)
		reply_cursor(c, 0)
		reply_array(c, 0)
		return
	}
	opts, err := ht.parse_scan_options(argv[3:], false)
	if err != .None {
		reply_hash_error(c, err)
		return
	}
	clear(&set_vals)
	next_cursor := st.scan(s, cursor, opts.count, &set_vals)
	if opts.use_pattern {
		write := 0
		for value in set_vals {
			buffer: [21]u8
			if glob_match(opts.pattern, st.value_bytes(value, &buffer), false) {
				set_vals[write] = value
				write += 1
			}
		}
		resize(&set_vals, write)
	}
	reply_array(c, 2)
	reply_cursor(c, next_cursor)
	reply_array(c, len(set_vals))
	for value in set_vals {
		reply_set_value(c, value)
	}
	clear(&set_vals)
}

@(init)
register_set_commands :: proc "contextless" () {
	register_commands(set_commands[:])
}

set_resize_tick :: proc "contextless" () {
	if !st.maintenance_pending() {
		return
	}
	deadline := now_ns() + 150_000
	scans, moves, grants := 4096, 256, 64
	empty, visits := 0, 0
	finished := false
	for grants > 0 && empty < len(db_parts) && visits < 128 && !finished {
		visits += 1
		d := db_parts[set_resize_db_next]
		set_resize_db_next = (set_resize_db_next + 1) % len(db_parts)
		if d.sctx.resize_head == nil {
			empty += 1
			continue
		}
		empty = 0
		for _ in 0 ..< 16 {
			h, work := st.maintenance_step(d.sctx, min(scans, st.RESIZE_WRITE_SCANS), min(moves, st.RESIZE_WRITE_MOVES))
			if h == nil {
				break
			}
			grants -= 1
			scans -= work.scanned
			moves -= work.moved
			set_sync((^Db)(d.sctx.owner), h)
			if grants == 0 || scans == 0 || moves == 0 || now_ns() >= deadline {
				finished = true
				break
			}
		}
	}
	st.maintenance_release(deadline_ns = now_ns() + 50_000)
}

package main

import zt "zsettype"
import st "settype"
import ht "hashtype"
import "core:fmt"

ZSET_REPLY_CHUNK :: 1000

zset_items: [dynamic]zt.Item

zset_scores: [dynamic]f64

zset_srcs: [dynamic]zt.Source

zset_weights: [dynamic]f64

zset_temps: [dynamic]zt.Zset

zset_seeded: bool

zset_resize_db_next: int

zset_object_release :: proc "contextless" (obj: rawptr) -> int {
	z := cast(zt.Zset)obj
	if z == nil {
		return 0
	}
	n := z.acct
	zt.destroy(z)
	return n
}

zset_object_move :: proc "contextless" (obj: rawptr, from: ^Db, to: ^Db) -> int {
	z := cast(zt.Zset)obj
	if z == nil {
		return 0
	}
	zt.maintenance_bind(z, to.zctx)
	return z.acct
}

zset_object_acct :: proc "contextless" (obj: rawptr) -> int {
	if obj == nil {
		return 0
	}
	return (cast(zt.Zset)obj).acct
}

zset_memory :: proc "contextless" (obj: rawptr) -> int {
	return zt.memory_usage(cast(zt.Zset)obj)
}

zset_obj_encoding :: proc "contextless" (z: zt.Zset) -> Obj_Encoding {
	return z.encoding == .Listpack ? .Listpack : .Skiplist
}

zset_sync :: proc "contextless" (db: ^Db, z: zt.Zset) {
	zt.maintenance_bind(z, db.zctx)
	n := zt.memory_usage(z)
	object_account(db, n - z.acct)
	z.acct = n
}

zset_done :: proc "contextless" (e: ^Entry, z: zt.Zset) {
	entry_set_encoding(e, zset_obj_encoding(z))
	zset_sync(e.db, z)
}

zset_seed :: proc() {
	if !zset_seeded {
		zt.set_seed(u64(now_ns()))
		zset_seeded = true
	}
}

zset_lookup :: proc(key: []u8, read: bool) -> (e: ^Entry, z: zt.Zset, wrong: bool) {
	e = read ? db_find_read(key) : db_find(key)
	if e == nil {
		return
	}
	if entry_type(e) != .Zset {
		return e, nil, true
	}
	z = cast(zt.Zset)entry_object(e, .Zset)
	return
}

zset_attach_new :: proc(key: []u8, z: zt.Zset) -> ^Entry {
	e, _ := db_upsert(key)
	zt.maintenance_bind(z, e.db.zctx)
	z.acct = zt.memory_usage(z)
	entry_object_attach(e, z, .Zset, zset_obj_encoding(z), z.acct)
	return e
}

zset_store :: proc(db: ^Db, key: []u8, z: zt.Zset) {
	e, _ := db_upsert_in(db, key)
	zt.maintenance_bind(z, db.zctx)
	z.acct = zt.memory_usage(z)
	entry_object_attach(e, z, .Zset, zset_obj_encoding(z), z.acct)
	entry_set_expire(e, 0)
}

reply_zset_error :: proc(c: ^Conn, err: zt.Error) {
	buf: [512]u8
	reply_error(c, fmt.bprintf(buf[:], "ERR %s", zt.error_message(err)))
}

reply_zset_member :: proc(c: ^Conn, it: ^zt.Item) {
	buf: [21]u8
	reply_bulk(c, zt.item_bytes(it, &buf))
}

reply_zset_pairs :: proc(c: ^Conn, items: []zt.Item, withscores: bool) {
	for &item in items {
		if withscores && c.resp == 3 {
			reply_array(c, 2)
		}
		reply_zset_member(c, &item)
		if withscores {
			reply_double(c, item.score)
		}
	}
}

reply_zset_items :: proc(c: ^Conn, items: []zt.Item, withscores: bool) {
	width := withscores && c.resp != 3 ? 2 : 1
	reply_array(c, len(items) * width)
	reply_zset_pairs(c, items, withscores)
}

zset_reset_scratch :: proc() {
	clear(&zset_items)
	clear(&zset_scores)
	clear(&zset_srcs)
	clear(&zset_weights)
	clear(&zset_temps)
}

zset_new_skiplist :: proc(expected: int) -> zt.Zset {
	zset_seed()
	return zt.create_skiplist(expected)
}

zset_store_result :: proc(db: ^Db, key: []u8, z: zt.Zset, event: string) {
	if zt.length(z) == 0 {
		zt.destroy(z)
		zset_store_delete(key)
		return
	}
	zset_store(db, key, z)
	signal_key_in(key, db)
	notify_in(.Zset, event, key, db)
	block_signal_key(db, key, .Zset)
}

zset_store_delete :: proc(key: []u8) {
	found, _ := db_remove(key)
	if found {
		signal_key(key)
		notify(.Generic, "del", key)
	}
}

zadd_notify :: proc(key: []u8, added, updated: int, incr: bool) {
	if added + updated == 0 {
		return
	}
	signal_key(key)
	notify(.Zset, incr ? "zincr" : "zadd", key)
	block_signal_key(cur_db(), key, .Zset)
}

zadd_generic :: proc(c: ^Conn, argv: [][]u8, incr_cmd: bool) {
	a, err := zt.parse_zadd(argv, incr_cmd)
	if err != .None {
		reply_zset_error(c, err)
		return
	}
	clear(&zset_scores)
	for i in 0 ..< a.elements {
		v, good := zt.parse_score(argv[a.scoreidx + 2 * i])
		if !good {
			reply_zset_error(c, .Not_Float)
			return
		}
		append(&zset_scores, v)
	}
	key := argv[1]
	e, z, wrong := zset_lookup(key, false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if z == nil {
		if .Xx in a.flags {
			if .Incr in a.flags {
				reply_null(c)
			} else {
				reply_int(c, 0)
			}
			return
		}
		zset_seed()
		z = zt.type_create(a.elements, len(argv[a.scoreidx + 1]))
		e = zset_attach_new(key, z)
	}
	added, updated := 0, 0
	nop := false
	result: f64
	for v, i in zset_scores {
		out, value, good := zt.add(z, v, argv[a.scoreidx + i * 2 + 1], a.flags)
		if !good {
			zset_done(e, z)
			reply_zset_error(c, .Nan_Result)
			return
		}
		if .Added in out {
			added += 1
		}
		if .Updated in out {
			updated += 1
		}
		nop = .Nop in out
		result = value
	}
	zset_done(e, z)
	zadd_notify(key, added, updated, incr_cmd)
	if .Incr in a.flags {
		if nop {
			reply_null(c)
		} else {
			reply_double(c, result)
		}
	} else {
		reply_int(c, i64(a.ch ? added + updated : added))
	}
}

cmd_zadd :: proc(c: ^Conn, argv: [][]u8) {
	zadd_generic(c, argv, false)
}

zset_zadd_command :: proc(c: ^Conn, argv: [][]u8) {
	cmd_zadd(c, argv)
}

cmd_zincrby :: proc(c: ^Conn, argv: [][]u8) {
	zadd_generic(c, argv, true)
}

zset_removed :: proc(key: []u8, e: ^Entry, z: zt.Zset, removed: int, event: string) {
	if removed == 0 {
		return
	}
	notify(.Zset, event, key)
	if zt.length(z) == 0 {
		db_remove(key)
		notify(.Generic, "del", key)
	} else {
		zset_done(e, z)
	}
	signal_key(key)
}

cmd_zrem :: proc(c: ^Conn, argv: [][]u8) {
	e, z, wrong := zset_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	n := 0
	if z != nil {
		for member in argv[2:] {
			if zt.del(z, member) {
				n += 1
			}
		}
		zset_removed(argv[1], e, z, n, "zrem")
	}
	reply_int(c, i64(n))
}

zremrange_generic :: proc(c: ^Conn, argv: [][]u8, kind: zt.Range_Kind) {
	a, err := zt.parse_zrange(argv, 1, false, kind, .Forward)
	if err != .None {
		reply_zset_error(c, err)
		return
	}
	e, z, wrong := zset_lookup(argv[1], false)
	if wrong {
		reply_wrongtype(c)
		return
	}
	n := 0
	event := "zremrangebyrank"
	if z != nil {
		switch kind {
		case .Rank:
			n = zt.remrange_by_rank(z, a.start, a.end)
		case .Score:
			n = zt.remrange_by_score(z, &a.srange)
			event = "zremrangebyscore"
		case .Lex:
			n = zt.remrange_by_lex(z, &a.lrange)
			event = "zremrangebylex"
		case .Auto:
		}
		zset_removed(argv[1], e, z, n, event)
	}
	reply_int(c, i64(n))
}

zrange_generic :: proc(c: ^Conn, argv: [][]u8, argc_start: int, store: bool, kind: zt.Range_Kind, dir: zt.Direction) {
	a, err := zt.parse_zrange(argv, argc_start, store, kind, dir)
	if err != .None {
		reply_zset_error(c, err)
		return
	}
	key := argv[argc_start]
	_, z, wrong := zset_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	clear(&zset_items)
	if z != nil {
		switch a.kind {
		case .Rank:
			zt.rank_range(z, a.start, a.end, a.reverse, &zset_items)
		case .Score:
			zt.score_range(z, &a.srange, a.offset, a.limit, a.reverse, &zset_items)
		case .Lex:
			zt.lex_range(z, &a.lrange, a.offset, a.limit, a.reverse, store, &zset_items)
		case .Auto:
		}
	}
	if store {
		dst := zset_new_skiplist(len(zset_items))
		maxlen, totlen := 0, 0
		for &item in zset_items {
			buf: [21]u8
			member := zt.item_bytes(&item, &buf)
			maxlen = max(maxlen, len(member))
			totlen += len(member)
			_, _, _ = zt.add(dst, item.score, member, {})
		}
		zt.convert_to_listpack_if_needed(dst, maxlen, totlen)
		n := zt.length(dst)
		clear(&zset_items)
		zset_store_result(cur_db(), argv[1], dst, "zrangestore")
		reply_int(c, i64(n))
	} else {
		reply_zset_items(c, zset_items[:], a.withscores)
		clear(&zset_items)
	}
}

cmd_zcard :: proc(c: ^Conn, argv: [][]u8) {
	_, z, wrong := zset_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	n := z == nil ? 0 : zt.length(z)
	reply_int(c, i64(n))
}

cmd_zscore :: proc(c: ^Conn, argv: [][]u8) {
	_, z, wrong := zset_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if z != nil {
		if score, found := zt.score(z, argv[2]); found {
			reply_double(c, score)
			return
		}
	}
	reply_null(c)
}

cmd_zmscore :: proc(c: ^Conn, argv: [][]u8) {
	_, z, wrong := zset_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	reply_array(c, len(argv) - 2)
	for member in argv[2:] {
		if z != nil {
			if score, found := zt.score(z, member); found {
				reply_double(c, score)
				continue
			}
		}
		reply_null(c)
	}
}

zrank_generic :: proc(c: ^Conn, argv: [][]u8, reverse: bool, name: string) {
	if len(argv) > 4 {
		reply_wrong_args(c, name)
		return
	}
	withscore := len(argv) == 4
	if withscore && !zt.keyword(argv[3], "withscore") {
		reply_zset_error(c, .Syntax)
		return
	}
	_, z, wrong := zset_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if z != nil {
		if rank, score, found := zt.rank(z, argv[2], reverse); found {
			if withscore {
				reply_array(c, 2)
			}
			reply_int(c, i64(rank))
			if withscore {
				reply_double(c, score)
			}
			return
		}
	}
	if withscore {
		reply_null_array(c)
	} else {
		reply_null(c)
	}
}

cmd_zcount :: proc(c: ^Conn, argv: [][]u8) {
	r, good := zt.parse_range(argv[2], argv[3])
	if !good {
		reply_zset_error(c, .Min_Max_Float)
		return
	}
	_, z, wrong := zset_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	n := z == nil ? 0 : zt.count_in_range(z, &r)
	reply_int(c, i64(n))
}

cmd_zlexcount :: proc(c: ^Conn, argv: [][]u8) {
	r, good := zt.parse_lex_range(argv[2], argv[3])
	if !good {
		reply_zset_error(c, .Min_Max_Lex)
		return
	}
	_, z, wrong := zset_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	n := z == nil ? 0 : zt.lex_count(z, &r)
	reply_int(c, i64(n))
}

cmd_zremrangebyrank :: proc(c: ^Conn, argv: [][]u8) {
	zremrange_generic(c, argv, .Rank)
}

cmd_zremrangebyscore :: proc(c: ^Conn, argv: [][]u8) {
	zremrange_generic(c, argv, .Score)
}

cmd_zremrangebylex :: proc(c: ^Conn, argv: [][]u8) {
	zremrange_generic(c, argv, .Lex)
}

cmd_zrange :: proc(c: ^Conn, argv: [][]u8) {
	zrange_generic(c, argv, 1, false, .Auto, .Auto)
}

cmd_zrangestore :: proc(c: ^Conn, argv: [][]u8) {
	zrange_generic(c, argv, 2, true, .Auto, .Auto)
}

cmd_zrevrange :: proc(c: ^Conn, argv: [][]u8) {
	zrange_generic(c, argv, 1, false, .Rank, .Reverse)
}

cmd_zrangebyscore :: proc(c: ^Conn, argv: [][]u8) {
	zrange_generic(c, argv, 1, false, .Score, .Forward)
}

cmd_zrevrangebyscore :: proc(c: ^Conn, argv: [][]u8) {
	zrange_generic(c, argv, 1, false, .Score, .Reverse)
}

cmd_zrangebylex :: proc(c: ^Conn, argv: [][]u8) {
	zrange_generic(c, argv, 1, false, .Lex, .Forward)
}

cmd_zrevrangebylex :: proc(c: ^Conn, argv: [][]u8) {
	zrange_generic(c, argv, 1, false, .Lex, .Reverse)
}

cmd_zrank :: proc(c: ^Conn, argv: [][]u8) {
	zrank_generic(c, argv, false, "zrank")
}

cmd_zrevrank :: proc(c: ^Conn, argv: [][]u8) {
	zrank_generic(c, argv, true, "zrevrank")
}

zset_set_source :: proc(e: ^Entry) -> (z: zt.Zset, id: rawptr, ok: bool) {
	if e == nil {
		return nil, nil, true
	}
	if entry_type(e) == .Zset {
		z = cast(zt.Zset)entry_object(e, .Zset)
		return z, rawptr(z), true
	}
	if entry_type(e) != .Set {
		return nil, nil, false
	}
	s := cast(st.Set)entry_object(e, .Set)
	z = zt.set_source_create(st.size(s))
	it := st.iterator(s)
	for {
		value, good := st.next(&it)
		if !good {
			break
		}
		buf: [21]u8
		zt.set_source_add(z, st.value_bytes(value, &buf))
	}
	append(&zset_temps, z)
	return z, rawptr(s), true
}

zset_free_temps :: proc() {
	for z in zset_temps {
		zt.destroy(z)
	}
	clear(&zset_temps)
}

setop_generic :: proc(c: ^Conn, argv: [][]u8, name: string, numkeys_index: int, op: zt.Setop, cardinality_only: bool) {
	n, err := zt.parse_setop_numkeys(argv, numkeys_index)
	if err != .None {
		if err == .At_Least_One_Key {
			reply_error_parts(c, "ERR at least 1 input key is needed for '", name, "' command")
		} else {
			reply_zset_error(c, err)
		}
		return
	}
	store := numkeys_index == 2
	clear(&zset_weights)
	resize(&zset_weights, n)
	clear(&zset_srcs)
	clear(&zset_temps)
	defer zset_free_temps()
	for i in 0 ..< n {
		e := db_find_read(argv[numkeys_index + 1 + i])
		z, id, good := zset_set_source(e)
		if !good {
			reply_wrongtype(c)
			return
		}
		src := zt.source_make(z, 1)
		src.id = id
		append(&zset_srcs, src)
	}
	o, option_err := zt.parse_setop_options(argv, numkeys_index + n + 1, n, op, store, cardinality_only, zset_weights[:])
	if option_err != .None {
		reply_zset_error(c, option_err)
		return
	}
	for &src, i in zset_srcs {
		src.weight = zset_weights[i]
	}
	zset_seed()
	dst, card, maxlen, totlen := zt.setop_compute(zset_srcs[:], op, o.aggregate, cardinality_only, int(o.limit))
	if cardinality_only {
		reply_int(c, i64(card))
		return
	}
	card = zt.length(dst)
	if store {
		zt.convert_to_listpack_if_needed(dst, maxlen, totlen)
		zset_store_result(cur_db(), argv[1], dst, name)
		reply_int(c, i64(card))
	} else {
		clear(&zset_items)
		zt.rank_range(dst, 0, -1, false, &zset_items)
		reply_zset_items(c, zset_items[:], o.withscores)
		clear(&zset_items)
		zt.destroy(dst)
	}
}

zpop_serve :: proc(c: ^Conn, key: []u8, e: ^Entry, z: zt.Zset, max_end: bool, emit_key: bool, count_in: i64, nested: bool) -> (deleted: bool) {
	count := count_in < 0 ? 1 : int(min(count_in, i64(zt.length(z))))
	if emit_key {
		reply_array(c, count_in < 0 ? 3 : 2)
		reply_bulk(c, key)
	}
	if count_in < 0 && !emit_key {
		reply_array(c, 2)
	}
	if count_in >= 0 {
		width := nested || c.resp == 3 ? 1 : 2
		reply_array(c, count * width)
	}
	for _ in 0 ..< count {
		item := zt.peek(z, max_end)
		if count_in >= 0 && (nested || c.resp == 3) {
			reply_array(c, 2)
		}
		reply_zset_member(c, &item)
		reply_double(c, item.score)
		zt.pop(z, max_end)
	}
	deleted = count > 0 && zt.length(z) == 0
	zset_removed(key, e, z, count, max_end ? "zpopmax" : "zpopmin")
	return
}

zpop_generic :: proc(c: ^Conn, keys: [][]u8, max_end: bool, emit_key: bool, count: i64, nested: bool, nil_when_empty: bool) {
	for key in keys {
		e, z, wrong := zset_lookup(key, false)
		if wrong {
			reply_wrongtype(c)
			return
		}
		if z != nil && zt.length(z) > 0 {
			_ = zpop_serve(c, key, e, z, max_end, emit_key, count, nested)
			return
		}
	}
	if nil_when_empty {
		reply_null_array(c)
	} else {
		reply_array(c, 0)
	}
}

zpopminmax :: proc(c: ^Conn, argv: [][]u8, max_end: bool) {
	count, err := zt.parse_zpop_count(argv)
	if err != .None {
		reply_zset_error(c, err)
		return
	}
	zpop_generic(c, argv[1:2], max_end, false, count, false, false)
}

cmd_zmpop :: proc(c: ^Conn, argv: [][]u8) {
	a, err := zt.parse_zmpop(argv, 1)
	if err != .None {
		reply_zset_error(c, err)
		return
	}
	zpop_generic(c, argv[2:2 + a.numkeys], a.max_end, true, a.count, true, true)
}

reply_bulk_int_u64 :: proc(c: ^Conn, v: u64) {
	buf: [21]u8
	n := format_u64(raw_data(buf[:]), v)
	reply_bulk(c, buf[:n])
}

cmd_zscan :: proc(c: ^Conn, argv: [][]u8) {
	cursor, good := ht.parse_scan_cursor(argv[2])
	if !good {
		reply_zset_error(c, .Invalid_Cursor)
		return
	}
	_, z, wrong := zset_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if z == nil {
		reply_array(c, 2)
		reply_bulk_int_u64(c, 0)
		reply_array(c, 0)
		return
	}
	opts, err := ht.parse_scan_options(argv[3:], false)
	if err != .None {
		reply_hash_error(c, err)
		return
	}
	clear(&zset_items)
	next := zt.scan(z, cursor, opts.count, &zset_items)
	kept := 0
	for i := 0; i + 1 < len(zset_items); i += 2 {
		buf: [zt.G17_MAX]u8
		member := zt.scan_value_bytes(&zset_items[i], &buf)
		if !opts.use_pattern || glob_match(opts.pattern, member, false) {
			zset_items[kept] = zset_items[i]
			zset_items[kept + 1] = zset_items[i + 1]
			kept += 2
		}
	}
	reply_array(c, 2)
	reply_bulk_int_u64(c, next)
	reply_array(c, kept)
	for i in 0 ..< kept {
		buf: [zt.G17_MAX]u8
		reply_bulk(c, zt.scan_value_bytes(&zset_items[i], &buf))
	}
	clear(&zset_items)
}

zrandmember_with_count :: proc(c: ^Conn, key: []u8, l: i64, withscores: bool) {
	_, z, wrong := zset_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if z == nil {
		reply_array(c, 0)
		return
	}
	n := l >= 0 ? min(l, i64(zt.length(z))) : -l
	width := withscores && c.resp != 3 ? 2 : 1
	reply_array(c, int(n) * width)
	clear(&zset_items)
	if l >= 0 {
		zt.random_unique(z, int(n), &zset_items)
		reply_zset_pairs(c, zset_items[:], withscores)
	} else {
		left := n
		for left > 0 {
			batch := min(left, ZSET_REPLY_CHUNK)
			clear(&zset_items)
			zt.random_with_repeats(z, int(batch), &zset_items)
			reply_zset_pairs(c, zset_items[:], withscores)
			left -= batch
		}
	}
	clear(&zset_items)
}

cmd_zrandmember :: proc(c: ^Conn, argv: [][]u8) {
	count, withscores, err := zt.parse_zrandmember(argv)
	if err != .None {
		reply_zset_error(c, err)
		return
	}
	if len(argv) >= 3 {
		zrandmember_with_count(c, argv[1], count, withscores)
		return
	}
	_, z, wrong := zset_lookup(argv[1], true)
	if wrong {
		reply_wrongtype(c)
		return
	}
	if z == nil {
		reply_null(c)
		return
	}
	item := zt.random_element(z)
	reply_zset_member(c, &item)
}

zset_copy_dup :: proc(src: ^Entry) -> (obj: rawptr, extra: u64, ok: bool) {
	if entry_type(src) != .Zset {
		return nil, 0, false
	}
	return zt.dup(cast(zt.Zset)entry_object(src, .Zset)), 0, true
}

zset_copy_attach :: proc(dst: ^Entry, key: []u8, obj: rawptr, extra: u64) {
	z := cast(zt.Zset)obj
	zt.maintenance_bind(z, dst.db.zctx)
	z.acct = zt.memory_usage(z)
	entry_object_attach(dst, z, .Zset, zset_obj_encoding(z), z.acct)
	block_signal_key(dst.db, key, .Zset)
}

zset_sort_input_len :: proc(e: ^Entry) -> i64 {
	if e == nil || entry_type(e) != .Zset {
		return 0
	}
	return i64(zt.length(cast(zt.Zset)entry_object(e, .Zset)))
}

zset_sort_load :: proc(e: ^Entry, dontsort: bool, desc: bool, start: i64, count: i64) -> bool {
	if e == nil || entry_type(e) != .Zset {
		return false
	}
	z := cast(zt.Zset)entry_object(e, .Zset)
	it := zt.iter_make(z, dontsort && desc)
	item: zt.Item
	index: i64
	for zt.iter_next(&it, &item) {
		if !dontsort || index >= start && index - start < count {
			buf: [21]u8
			sort_add_element(zt.item_bytes(&item, &buf))
		}
		index += 1
	}
	return dontsort
}

zset_resize_tick :: proc "contextless" () {
	if !zt.maintenance_pending() {
		return
	}
	deadline := now_ns() + 150_000
	scans, moves, grants := 4096, 256, 64
	empty, visits := 0, 0
	finished := false
	for grants > 0 && empty < len(dbs) && visits < 128 && !finished {
		visits += 1
		d := &dbs[zset_resize_db_next]
		zset_resize_db_next = (zset_resize_db_next + 1) % len(dbs)
		if d.zctx.resize_head == nil {
			empty += 1
			continue
		}
		empty = 0
		for _ in 0 ..< 16 {
			h, work := zt.maintenance_step(d.zctx, min(scans, zt.RESIZE_WRITE_SCANS), min(moves, zt.RESIZE_WRITE_MOVES))
			if h == nil {
				break
			}
			grants -= 1
			scans -= work.scanned
			moves -= work.moved
			zset_sync((^Db)(d.zctx.owner), h)
			if grants == 0 || scans == 0 || moves == 0 || now_ns() >= deadline {
				finished = true
				break
			}
		}
	}
	zt.maintenance_release(deadline_ns = now_ns() + 50_000)
}

cmd_zunionstore :: proc(c: ^Conn, argv: [][]u8) {
	setop_generic(c, argv, "zunionstore", 2, .Union, false)
}

cmd_zinterstore :: proc(c: ^Conn, argv: [][]u8) {
	setop_generic(c, argv, "zinterstore", 2, .Inter, false)
}

cmd_zdiffstore :: proc(c: ^Conn, argv: [][]u8) {
	setop_generic(c, argv, "zdiffstore", 2, .Diff, false)
}

cmd_zunion :: proc(c: ^Conn, argv: [][]u8) {
	setop_generic(c, argv, "zunion", 1, .Union, false)
}

cmd_zinter :: proc(c: ^Conn, argv: [][]u8) {
	setop_generic(c, argv, "zinter", 1, .Inter, false)
}

cmd_zdiff :: proc(c: ^Conn, argv: [][]u8) {
	setop_generic(c, argv, "zdiff", 1, .Diff, false)
}

cmd_zintercard :: proc(c: ^Conn, argv: [][]u8) {
	setop_generic(c, argv, "zintercard", 1, .Inter, true)
}

cmd_zpopmin :: proc(c: ^Conn, argv: [][]u8) {
	zpopminmax(c, argv, false)
}

cmd_zpopmax :: proc(c: ^Conn, argv: [][]u8) {
	zpopminmax(c, argv, true)
}

@(private = "file")
zset_commands := [?]Command{
	{"zadd", cmd_zadd, -4},
	{"zincrby", cmd_zincrby, 4},
	{"zrem", cmd_zrem, -3},
	{"zcard", cmd_zcard, 2},
	{"zscore", cmd_zscore, 3},
	{"zmscore", cmd_zmscore, -3},
	{"zrank", cmd_zrank, -3},
	{"zrevrank", cmd_zrevrank, -3},
	{"zrange", cmd_zrange, -4},
	{"zrangestore", cmd_zrangestore, -5},
	{"zrevrange", cmd_zrevrange, -4},
	{"zrangebyscore", cmd_zrangebyscore, -4},
	{"zrevrangebyscore", cmd_zrevrangebyscore, -4},
	{"zrangebylex", cmd_zrangebylex, -4},
	{"zrevrangebylex", cmd_zrevrangebylex, -4},
	{"zcount", cmd_zcount, 4},
	{"zlexcount", cmd_zlexcount, 4},
	{"zremrangebyrank", cmd_zremrangebyrank, 4},
	{"zremrangebyscore", cmd_zremrangebyscore, 4},
	{"zremrangebylex", cmd_zremrangebylex, 4},
	{"zunionstore", cmd_zunionstore, -4},
	{"zinterstore", cmd_zinterstore, -4},
	{"zdiffstore", cmd_zdiffstore, -4},
	{"zunion", cmd_zunion, -3},
	{"zinter", cmd_zinter, -3},
	{"zdiff", cmd_zdiff, -3},
	{"zintercard", cmd_zintercard, -3},
	{"zpopmin", cmd_zpopmin, -2},
	{"zpopmax", cmd_zpopmax, -2},
	{"zmpop", cmd_zmpop, -4},
	{"bzpopmin", cmd_bzpopmin, -3},
	{"bzpopmax", cmd_bzpopmax, -3},
	{"bzmpop", cmd_bzmpop, -5},
	{"zrandmember", cmd_zrandmember, -2},
	{"zscan", cmd_zscan, -3},
}

@(init)
register_zset_commands :: proc "contextless" () {
	register_commands(zset_commands[:])
}

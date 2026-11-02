package main

import zt "zsettype"
import st "settype"
import ht "hashtype"
import "core:fmt"

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
	pst.dirty_explicit = true
	if zt.length(z) == 0 {
		zt.destroy(z)
		zset_store_delete(key)
		return
	}
	pst.dirty += 1
	zset_store(db, key, z)
	signal_key_in(key, db)
	notify_in(.Zset, event, key, db)
	block_signal_key(db, key, .Zset)
}

zset_store_delete :: proc(key: []u8) {
	found, expired := db_remove(key)
	pst.dirty_explicit = true
	if found {
		if !expired { pst.dirty += 1 }
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

@(private = "file")
Zadd_Tally :: struct {
	inserted: int,
	rescored: int,
	last:     f64,
	declined: bool,
	invalid:  bool,
}

@(private = "file")
zadd_read_scores :: proc(c: ^Conn, argv: [][]u8, first: int) -> bool {
	clear(&zset_scores)
	for at := first; at < len(argv); at += 2 {
		score, numeric := zt.parse_score(argv[at])
		if !numeric {
			reply_zset_error(c, .Not_Float)
			return false
		}
		append(&zset_scores, score)
	}
	return true
}

@(private = "file")
zadd_merge :: proc(z: zt.Zset, members: [][]u8, flags: zt.Zadd_Flags) -> (tally: Zadd_Tally) {
	defer pst.dirty += i64(tally.inserted + tally.rescored)
	for score, n in zset_scores {
		effect, now, defined := zt.add(z, score, members[2 * n], flags)
		if !defined {
			tally.invalid = true
			return
		}
		tally.inserted += int(.Added in effect)
		tally.rescored += int(.Updated in effect)
		tally.declined = .Nop in effect
		tally.last = now
	}
	return
}

@(private = "file")
zadd_answer :: proc(c: ^Conn, opts: ^zt.Zadd_Args, tally: ^Zadd_Tally) {
	if .Incr not_in opts.flags {
		total := tally.inserted
		if opts.ch {
			total += tally.rescored
		}
		reply_int(c, i64(total))
	} else if tally.declined {
		reply_null(c)
	} else {
		reply_double(c, tally.last)
	}
}

@(private = "file")
zset_add_command :: proc(c: ^Conn, argv: [][]u8, zincrby: bool) {
	pst.dirty_explicit = true
	opts, refused := zt.parse_zadd(argv, zincrby)
	if refused != .None {
		reply_zset_error(c, refused)
		return
	}
	if !zadd_read_scores(c, argv, opts.scoreidx) {
		return
	}
	e, z, wrong := zset_lookup(argv[1], false)
	switch {
	case wrong:
		reply_wrongtype(c)
	case z == nil && .Xx in opts.flags:
		untouched := Zadd_Tally{declined = true}
		zadd_answer(c, &opts, &untouched)
	case:
		zadd_apply(c, argv, &opts, e, z)
	}
}

@(private = "file")
zadd_apply :: proc(c: ^Conn, argv: [][]u8, opts: ^zt.Zadd_Args, found: ^Entry, existing: zt.Zset) {
	key := argv[1]
	e, z := found, existing
	if z == nil {
		zset_seed()
		z = zt.type_create(len(zset_scores), len(argv[opts.scoreidx + 1]))
		e = zset_attach_new(key, z)
	}
	tally := zadd_merge(z, argv[opts.scoreidx + 1:], opts.flags)
	zset_done(e, z)
	if tally.invalid {
		reply_zset_error(c, .Nan_Result)
		return
	}
	zadd_notify(key, tally.inserted, tally.rescored, .Incr in opts.flags)
	zadd_answer(c, opts, &tally)
}

cmd_zadd :: proc(c: ^Conn, argv: [][]u8) {
	zset_add_command(c, argv, false)
}

zset_zadd_command :: proc(c: ^Conn, argv: [][]u8) {
	cmd_zadd(c, argv)
}

cmd_zincrby :: proc(c: ^Conn, argv: [][]u8) {
	zset_add_command(c, argv, true)
}

zset_removed :: proc(key: []u8, e: ^Entry, z: zt.Zset, removed: int, event: string) {
	pst.dirty_explicit = true
	if removed == 0 {
		return
	}
	pst.dirty += i64(removed)
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
	pst.dirty_explicit = true
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
	pst.dirty_explicit = true
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

@(private = "file")
zset_for_read :: proc(c: ^Conn, key: []u8) -> (z: zt.Zset, ok: bool) {
	_, found, wrong := zset_lookup(key, true)
	if wrong {
		reply_wrongtype(c)
		return nil, false
	}
	return found, true
}

Zrange_Variant :: enum u8 {
	Zrange,
	Zrangestore,
	Zrevrange,
	Zrangebyscore,
	Zrevrangebyscore,
	Zrangebylex,
	Zrevrangebylex,
}

@(private = "file")
Zrange_Fixed :: struct {
	kind: zt.Range_Kind,
	dir:  zt.Direction,
}

@(private = "file")
zrange_fixed := [Zrange_Variant]Zrange_Fixed {
	.Zrange           = {.Auto, .Auto},
	.Zrangestore      = {.Auto, .Auto},
	.Zrevrange        = {.Rank, .Reverse},
	.Zrangebyscore    = {.Score, .Forward},
	.Zrevrangebyscore = {.Score, .Reverse},
	.Zrangebylex      = {.Lex, .Forward},
	.Zrevrangebylex   = {.Lex, .Reverse},
}

@(private = "file")
zrange_select :: proc(z: zt.Zset, spec: ^zt.Zrange_Args, keep_scores: bool) {
	#partial switch spec.kind {
	case .Rank:
		zt.rank_range(z, spec.start, spec.end, spec.reverse, &zset_items)
	case .Score:
		zt.score_range(z, &spec.srange, spec.offset, spec.limit, spec.reverse, &zset_items)
	case .Lex:
		zt.lex_range(z, &spec.lrange, spec.offset, spec.limit, spec.reverse, keep_scores, &zset_items)
	}
}

@(private = "file")
zrange_save_selection :: proc(c: ^Conn, dest: []u8) {
	out := zset_new_skiplist(len(zset_items))
	widest, bytes_total := 0, 0
	for &picked in zset_items {
		scratch: [21]u8
		name := zt.item_bytes(&picked, &scratch)
		widest = max(widest, len(name))
		bytes_total += len(name)
		_, _, _ = zt.add(out, picked.score, name, {})
	}
	zt.convert_to_listpack_if_needed(out, widest, bytes_total)
	stored := zt.length(out)
	zset_store_result(cur_db(), dest, out, "zrangestore")
	reply_int(c, i64(stored))
}

zrange_command :: proc(c: ^Conn, argv: [][]u8, variant: Zrange_Variant) {
	saving := variant == .Zrangestore
	if saving {
		pst.dirty_explicit = true
	}
	source := 2 if saving else 1
	fixed := zrange_fixed[variant]
	spec, refused := zt.parse_zrange(argv, source, saving, fixed.kind, fixed.dir)
	if refused != .None {
		reply_zset_error(c, refused)
		return
	}
	z, readable := zset_for_read(c, argv[source])
	if !readable {
		return
	}
	clear(&zset_items)
	defer clear(&zset_items)
	if z != nil {
		zrange_select(z, &spec, saving)
	}
	if saving {
		zrange_save_selection(c, argv[1])
	} else {
		reply_zset_items(c, zset_items[:], spec.withscores)
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
	zrange_command(c, argv, .Zrange)
}

cmd_zrangestore :: proc(c: ^Conn, argv: [][]u8) {
	zrange_command(c, argv, .Zrangestore)
}

cmd_zrevrange :: proc(c: ^Conn, argv: [][]u8) {
	zrange_command(c, argv, .Zrevrange)
}

cmd_zrangebyscore :: proc(c: ^Conn, argv: [][]u8) {
	zrange_command(c, argv, .Zrangebyscore)
}

cmd_zrevrangebyscore :: proc(c: ^Conn, argv: [][]u8) {
	zrange_command(c, argv, .Zrevrangebyscore)
}

cmd_zrangebylex :: proc(c: ^Conn, argv: [][]u8) {
	zrange_command(c, argv, .Zrangebylex)
}

cmd_zrevrangebylex :: proc(c: ^Conn, argv: [][]u8) {
	zrange_command(c, argv, .Zrevrangebylex)
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

Zset_Algebra_Output :: enum u8 {
	Reply,
	Store,
	Count,
}

@(private = "file")
zset_algebra_names := [zt.Setop][Zset_Algebra_Output]string {
	.Union = {.Reply = "zunion", .Store = "zunionstore", .Count = "zunion"},
	.Inter = {.Reply = "zinter", .Store = "zinterstore", .Count = "zintercard"},
	.Diff  = {.Reply = "zdiff", .Store = "zdiffstore", .Count = "zdiff"},
}

@(private = "file")
zset_algebra_inputs :: proc(keys: [][]u8) -> bool {
	for key in keys {
		z, origin, usable := zset_set_source(db_find_read(key))
		if !usable {
			return false
		}
		input := zt.source_make(z, 1)
		input.id = origin
		append(&zset_srcs, input)
	}
	return true
}

@(private = "file")
zset_algebra_deliver :: proc(c: ^Conn, argv: [][]u8, name: string, output: Zset_Algebra_Output, opts: ^zt.Setop_Options, result: zt.Zset, card: int, widest: int, bytes_total: int) {
	switch output {
	case .Count:
		reply_int(c, i64(card))
	case .Store:
		members := zt.length(result)
		zt.convert_to_listpack_if_needed(result, widest, bytes_total)
		zset_store_result(cur_db(), argv[1], result, name)
		reply_int(c, i64(members))
	case .Reply:
		clear(&zset_items)
		zt.rank_range(result, 0, -1, false, &zset_items)
		reply_zset_items(c, zset_items[:], opts.withscores)
		clear(&zset_items)
		zt.destroy(result)
	}
}

zset_algebra :: proc(c: ^Conn, argv: [][]u8, op: zt.Setop, output: Zset_Algebra_Output) {
	storing := output == .Store
	if storing {
		pst.dirty_explicit = true
	}
	name := zset_algebra_names[op][output]
	count_at := 2 if storing else 1
	inputs, refused := zt.parse_setop_numkeys(argv, count_at)
	if refused == .At_Least_One_Key {
		reply_error_parts(c, "ERR at least 1 input key is needed for '", name, "' command")
		return
	}
	if refused != .None {
		reply_zset_error(c, refused)
		return
	}
	clear(&zset_srcs)
	clear(&zset_temps)
	defer zset_free_temps()
	if !zset_algebra_inputs(argv[count_at + 1:][:inputs]) {
		reply_wrongtype(c)
		return
	}
	resize(&zset_weights, inputs)
	opts, bad_option := zt.parse_setop_options(argv, count_at + 1 + inputs, inputs, op, storing, output == .Count, zset_weights[:])
	if bad_option != .None {
		reply_zset_error(c, bad_option)
		return
	}
	for &input, n in zset_srcs {
		input.weight = zset_weights[n]
	}
	zset_seed()
	result, card, widest, bytes_total := zt.setop_compute(zset_srcs[:], op, opts.aggregate, output == .Count, int(opts.limit))
	zset_algebra_deliver(c, argv, name, output, &opts, result, card, widest, bytes_total)
}

Zpop_Shape :: enum u8 {
	Pair,
	Run,
	Keyed_Pair,
	Keyed_Run,
}

Zpop_Order :: struct {
	shape: Zpop_Shape,
	top:   bool,
	count: i64,
}

Zpop_Probe :: enum u8 {
	Empty,
	Ready,
	Wrong,
}

zpop_find_ready :: proc(keys: [][]u8) -> (key: []u8, e: ^Entry, z: zt.Zset, probe: Zpop_Probe) {
	for candidate in keys {
		entry, set, wrong := zset_lookup(candidate, false)
		if wrong {
			return candidate, entry, nil, .Wrong
		}
		if set != nil && zt.length(set) > 0 {
			return candidate, entry, set, .Ready
		}
	}
	return nil, nil, nil, .Empty
}

zpop_emit :: proc(c: ^Conn, key: []u8, e: ^Entry, z: zt.Zset, order: Zpop_Order) -> (emptied: bool) {
	take := 1
	grouped := false
	switch order.shape {
	case .Pair:
		reply_array(c, 2)
	case .Keyed_Pair:
		reply_array(c, 3)
		reply_bulk(c, key)
	case .Run:
		take = int(min(order.count, i64(zt.length(z))))
		grouped = c.resp == 3
		reply_array(c, take if grouped else 2 * take)
	case .Keyed_Run:
		take = int(min(order.count, i64(zt.length(z))))
		grouped = true
		reply_array(c, 2)
		reply_bulk(c, key)
		reply_array(c, take)
	}
	for _ in 0 ..< take {
		head := zt.peek(z, order.top)
		if grouped {
			reply_array(c, 2)
		}
		reply_zset_member(c, &head)
		reply_double(c, head.score)
		zt.pop(z, order.top)
	}
	emptied = take > 0 && zt.length(z) == 0
	zset_removed(key, e, z, take, "zpopmax" if order.top else "zpopmin")
	return
}

@(private = "file")
zpop_from_keys :: proc(c: ^Conn, keys: [][]u8, order: Zpop_Order) {
	pst.dirty_explicit = true
	key, e, z, probe := zpop_find_ready(keys)
	switch probe {
	case .Wrong:
		reply_wrongtype(c)
	case .Ready:
		zpop_emit(c, key, e, z, order)
	case .Empty:
		if order.shape == .Keyed_Run {
			reply_null_array(c)
			return
		}
		reply_array(c, 0)
	}
}

@(private = "file")
zpop_command :: proc(c: ^Conn, argv: [][]u8, top: bool) {
	count, refused := zt.parse_zpop_count(argv)
	if refused != .None {
		reply_zset_error(c, refused)
		return
	}
	shape := Zpop_Shape.Pair if count < 0 else .Run
	zpop_from_keys(c, argv[1:2], Zpop_Order{shape = shape, top = top, count = count})
}

cmd_zmpop :: proc(c: ^Conn, argv: [][]u8) {
	spec, refused := zt.parse_zmpop(argv, 1)
	if refused != .None {
		reply_zset_error(c, refused)
		return
	}
	zpop_from_keys(c, argv[2:][:spec.numkeys], Zpop_Order{shape = .Keyed_Run, top = spec.max_end, count = spec.count})
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

@(private = "file")
zrandmember_repeats :: proc(c: ^Conn, z: zt.Zset, picks: i64, withscores: bool) {
	reply_array(c, int(picks) * (2 if withscores && c.resp != 3 else 1))
	for _ in 0 ..< picks {
		pick := zt.random_element(z)
		reply_zset_pairs(c, ([^]zt.Item)(&pick)[:1], withscores)
	}
}

@(private = "file")
zrandmember_distinct :: proc(c: ^Conn, z: zt.Zset, wanted: i64, withscores: bool) {
	clear(&zset_items)
	zt.random_unique(z, int(min(wanted, i64(zt.length(z)))), &zset_items)
	reply_zset_items(c, zset_items[:], withscores)
	clear(&zset_items)
}

@(private = "file")
zrandmember_counted :: proc(c: ^Conn, key: []u8, count: i64, withscores: bool) {
	z, readable := zset_for_read(c, key)
	switch {
	case !readable:
	case z == nil:
		reply_array(c, 0)
	case count < 0:
		zrandmember_repeats(c, z, -count, withscores)
	case:
		zrandmember_distinct(c, z, count, withscores)
	}
}

cmd_zrandmember :: proc(c: ^Conn, argv: [][]u8) {
	count, withscores, err := zt.parse_zrandmember(argv)
	if err != .None {
		reply_zset_error(c, err)
		return
	}
	if len(argv) >= 3 {
		zrandmember_counted(c, argv[1], count, withscores)
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

zset_sort_load :: proc(e: ^Entry, natural: bool, desc: bool, start: i64, count: i64) -> bool {
	if e == nil || entry_type(e) != .Zset {
		return false
	}
	z := cast(zt.Zset)entry_object(e, .Zset)
	it := zt.iter_make(z, natural && desc)
	item: zt.Item
	index: i64
	for zt.iter_next(&it, &item) {
		if !natural || index >= start && index - start < count {
			buf: [21]u8
			sort_add_element(zt.item_bytes(&item, &buf))
		}
		index += 1
	}
	return natural
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
	zset_algebra(c, argv, .Union, .Store)
}

cmd_zinterstore :: proc(c: ^Conn, argv: [][]u8) {
	zset_algebra(c, argv, .Inter, .Store)
}

cmd_zdiffstore :: proc(c: ^Conn, argv: [][]u8) {
	zset_algebra(c, argv, .Diff, .Store)
}

cmd_zunion :: proc(c: ^Conn, argv: [][]u8) {
	zset_algebra(c, argv, .Union, .Reply)
}

cmd_zinter :: proc(c: ^Conn, argv: [][]u8) {
	zset_algebra(c, argv, .Inter, .Reply)
}

cmd_zdiff :: proc(c: ^Conn, argv: [][]u8) {
	zset_algebra(c, argv, .Diff, .Reply)
}

cmd_zintercard :: proc(c: ^Conn, argv: [][]u8) {
	zset_algebra(c, argv, .Inter, .Count)
}

cmd_zpopmin :: proc(c: ^Conn, argv: [][]u8) {
	zpop_command(c, argv, false)
}

cmd_zpopmax :: proc(c: ^Conn, argv: [][]u8) {
	zpop_command(c, argv, true)
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

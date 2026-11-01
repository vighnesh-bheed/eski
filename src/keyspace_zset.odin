package main

import ks "keyspace"
import zt "zsettype"
import st "settype"
import ht "hashtype"
import "fpconv"

keyspace_builder_double :: proc "contextless" (task: ^Keyspace_Task, b: ^Keyspace_Builder, value: f64) {
	buf: [fpconv.DOUBLE_STR_MAX]u8
	n := fpconv.format_double(buf[:], value)
	if task.client.resp == RESP3 { keyspace_builder_text(b, ","); keyspace_builder_bytes(b, buf[:n]); keyspace_builder_text(b, "\r\n") } else { keyspace_builder_bulk(b, buf[:n]) }
}

keyspace_zset_reply_items :: proc(task: ^Keyspace_Task, b: ^Keyspace_Builder, items: []zt.Item, scores: bool, nested: bool = false) {
	width := 2 if scores && task.client.resp != RESP3 && !nested else 1
	keyspace_builder_integer(b, i64(len(items) * width), '*')
	for &item in items {
		if scores && (task.client.resp == RESP3 || nested) { keyspace_builder_integer(b, 2, '*') }
		buf: [21]u8
		keyspace_builder_bulk(b, zt.item_bytes(&item, &buf))
		if scores { keyspace_builder_double(task, b, item.score) }
	}
}

keyspace_zset_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	argv := task.argv
	name := task.command_name
	if name == "zunion" || name == "zinter" || name == "zdiff" || name == "zunionstore" || name == "zinterstore" || name == "zdiffstore" || name == "zintercard" { keyspace_zset_algebra(task); return }
	if name == "zpopmin" || name == "zpopmax" || name == "zmpop" { keyspace_zset_pop(task); return }
	if name == "zadd" || name == "zincrby" { keyspace_zset_add(task); return }
	store := name == "zrangestore"
	index := 2 if store else 1
	r := keyspace_task_record(task, argv[index])
	if r == nil { task.failed = true; return }
	kind := zt.Range_Kind.Auto
	direction := zt.Direction.Auto
	if name == "zrevrange" { kind = .Rank; direction = .Reverse }
	if name == "zrangebyscore" { kind = .Score; direction = .Forward }
	if name == "zrevrangebyscore" { kind = .Score; direction = .Reverse }
	if name == "zrangebylex" { kind = .Lex; direction = .Forward }
	if name == "zrevrangebylex" { kind = .Lex; direction = .Reverse }
	remove := name == "zremrangebyrank" || name == "zremrangebyscore" || name == "zremrangebylex"
	if remove { kind = .Rank if name == "zremrangebyrank" else .Score if name == "zremrangebyscore" else .Lex; direction = .Forward }
	ranged := remove || store || name == "zrange" || name == "zrevrange" || name == "zrangebyscore" || name == "zrevrangebyscore" || name == "zrangebylex" || name == "zrevrangebylex"
	args: zt.Zrange_Args
	if ranged {
		parsed, err := zt.parse_zrange(argv, index, store, kind, direction)
		if err != .None { task.failed = true; return }; args = parsed
	}
	if name == "zrank" || name == "zrevrank" {
		if len(argv) > 4 || (len(argv) == 4 && !zt.keyword(argv[3], "withscore")) { task.failed = true; return }
	}
	if name == "zcount" { _, ok := zt.parse_range(argv[2], argv[3]); if !ok { task.failed = true; return } }
	if name == "zlexcount" { _, ok := zt.parse_lex_range(argv[2], argv[3]); if !ok { task.failed = true; return } }
	if name == "zrandmember" { _, _, err := zt.parse_zrandmember(argv); if err != .None { task.failed = true; return } }
	if name == "zscan" { _, ok := ht.parse_scan_cursor(argv[2]); if !ok { task.failed = true; return } }
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Zset) { task.failed = true; return }
	z := cast(zt.Zset)r.object
	if name == "zrem" || remove { keyspace_touch(task, r) } else { keyspace_read(task, r) }
	b := keyspace_object_builder(task, .Zset, z, len(argv) * 64)
	defer ks.free(&keyspace_pool, b.bytes)
	if b.failed { return }
	if name == "zcard" { task.integer = i64(keyspace_zset_length(z)); return }
	if name == "zscore" || name == "zmscore" {
		if name == "zmscore" { keyspace_builder_integer(&b, i64(len(argv) - 2), '*') }
		for member in argv[2:] {
			score: f64; found := false
			if z != nil { score, found = zt.score(z, member) }
			if found { keyspace_builder_double(task, &b, score) } else { keyspace_hash_null(task, &b) }
		}
		keyspace_builder_finish(task, &b); return
	}
	if name == "zrank" || name == "zrevrank" {
		rank: int; score: f64; found := false
		if z != nil { rank, score, found = zt.rank(z, argv[2], name == "zrevrank") }
		if found {
			if len(argv) == 4 { keyspace_builder_integer(&b, 2, '*') }
			keyspace_builder_integer(&b, i64(rank))
			if len(argv) == 4 { keyspace_builder_double(task, &b, score) }
		} else if len(argv) == 4 { keyspace_builder_text(&b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n") } else { keyspace_hash_null(task, &b) }
		keyspace_builder_finish(task, &b); return
	}
	if name == "zcount" {
		range, ok := zt.parse_range(argv[2], argv[3]); if !ok { task.failed = true; return }
		if z != nil { task.integer = i64(zt.count_in_range(z, &range)) }; return
	}
	if name == "zlexcount" {
		range, ok := zt.parse_lex_range(argv[2], argv[3]); if !ok { task.failed = true; return }
		if z != nil { task.integer = i64(zt.lex_count(z, &range)) }; return
	}
	if name == "zrem" || remove {
		if z == nil { return }
		work, ok := keyspace_object_work(task, r, .Zset)
		if !ok { return }; defer keyspace_object_discard(&work)
		candidate := cast(zt.Zset)work.object
		if name == "zrem" { for member in argv[2:] { task.integer += i64(zt.del(candidate, member)) } } else {
			switch args.kind {
			case .Rank: task.integer = i64(zt.remrange_by_rank(candidate, args.start, args.end))
			case .Score: task.integer = i64(zt.remrange_by_score(candidate, &args.srange))
			case .Lex: task.integer = i64(zt.remrange_by_lex(candidate, &args.lrange))
			case .Auto:
			}
		}
		if task.integer == 0 { return }
		if !keyspace_object_commit(task, r, &work) { return }; task.dirty = task.integer
		keyspace_notify(task, r, .Zset, name)
		if !r.exists { keyspace_notify(task, r, .Generic, "del") }
		keyspace_invalidate(task, r); return
	}
	charge := keyspace_zset_length(z) * 4 * size_of(zt.Item) + 1024
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
	items := make([dynamic]zt.Item, 0, keyspace_zset_length(z) * 2); defer delete(items)
	if ranged {
		if z != nil {
			switch args.kind {
			case .Rank: zt.rank_range(z, args.start, args.end, args.reverse, &items)
			case .Score: zt.score_range(z, &args.srange, args.offset, args.limit, args.reverse, &items)
			case .Lex: zt.lex_range(z, &args.lrange, args.offset, args.limit, args.reverse, store, &items)
			case .Auto:
			}
		}
		if store { keyspace_zset_store_items(task, argv[1], items[:]); return }
		keyspace_zset_reply_items(task, &b, items[:], args.withscores); keyspace_builder_finish(task, &b); return
	}
	if name == "zscan" {
		cursor, ok := ht.parse_scan_cursor(argv[2]); if !ok { task.failed = true; return }
		opts: ht.Scan_Options
		if z != nil { parsed, err := ht.parse_scan_options(argv[3:], false); if err != .None { task.failed = true; return }; opts = parsed }
		next: u64
		if z != nil { next = zt.scan(z, cursor, opts.count, &items) }
		kept := 0
		for i := 0; i + 1 < len(items); i += 2 {
			buf: [zt.G17_MAX]u8
			if !opts.use_pattern || glob_match(opts.pattern, zt.scan_value_bytes(&items[i], &buf), false) { items[kept] = items[i]; items[kept + 1] = items[i + 1]; kept += 2 }
		}
		keyspace_builder_integer(&b, 2, '*'); digits: [24]u8
		n := format_u64(raw_data(digits[:]), next); keyspace_builder_bulk(&b, digits[:n]); keyspace_builder_integer(&b, i64(kept), '*')
		for i in 0 ..< kept { buf: [zt.G17_MAX]u8; keyspace_builder_bulk(&b, zt.scan_value_bytes(&items[i], &buf)) }
		keyspace_builder_finish(task, &b); return
	}
	if name == "zrandmember" {
		count, scores, err := zt.parse_zrandmember(argv)
		if err != .None { task.failed = true; return }
		if len(argv) == 2 {
			if z == nil { task.null = true; return }
			item := zt.random_element(z); buf: [21]u8
			keyspace_builder_bulk(&b, zt.item_bytes(&item, &buf)); keyspace_builder_finish(task, &b); return
		}
		if z == nil { keyspace_builder_integer(&b, 0, '*'); keyspace_builder_finish(task, &b); return }
		n := min(count, i64(keyspace_zset_length(z))) if count >= 0 else -count
		if n > i64(max(int) / (4 * size_of(zt.Item))) { task.failed = true; return }
		if count >= 0 { zt.random_unique(z, int(n), &items) } else {
			additional := int(n) * 2 * size_of(zt.Item)
			if !ks.reserve_external(&keyspace_pool, additional) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, additional)
			if reserve(&items, int(n)) != nil { task.failed = true; return }
			zt.random_with_repeats(z, int(n), &items)
		}
		keyspace_zset_reply_items(task, &b, items[:], scores); keyspace_builder_finish(task, &b); return
	}
	task.failed = true
}

keyspace_zset_add :: proc(task: ^Keyspace_Task) {
	argv := task.argv
	args, err := zt.parse_zadd(argv, task.command_name == "zincrby")
	if err != .None { task.failed = true; return }
	charge := args.elements * size_of(f64)
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
	scores := make([]f64, args.elements); defer delete(scores)
	for _, i in scores { value, ok := zt.parse_score(argv[args.scoreidx + 2 * i]); if !ok { task.failed = true; return }; scores[i] = value }
	r := task.records[0]
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Zset) { task.failed = true; return }
	keyspace_touch(task, r)
	if !r.exists && .Xx in args.flags { task.null = .Incr in args.flags; return }
	work, ok := keyspace_object_work(task, r, .Zset)
	if !ok { return }; defer keyspace_object_discard(&work)
	if !r.exists { zt.destroy(cast(zt.Zset)work.object); work.object = zt.type_create(args.elements, len(argv[args.scoreidx + 1])) }
	z := cast(zt.Zset)work.object
	added, updated := 0, 0
	nop := false
	result: f64
	for score, i in scores {
		flags, value, valid := zt.add(z, score, argv[args.scoreidx + i * 2 + 1], args.flags)
		if !valid { task.failed = true; return }
		added += int(.Added in flags); updated += int(.Updated in flags); nop = .Nop in flags; result = value
	}
	if .Incr in args.flags {
		if nop { task.null = true } else {
			b := keyspace_object_builder(task, .Zset, z); defer ks.free(&keyspace_pool, b.bytes)
			if b.failed { return }; keyspace_builder_double(task, &b, result); if !keyspace_builder_finish(task, &b) { return }
		}
	} else { task.integer = i64(added + updated if args.ch else added) }
	if added + updated == 0 { return }
	if !keyspace_object_commit(task, r, &work) { return }; task.dirty = i64(added + updated)
	keyspace_changed(task, r, .Zset, "zincr" if .Incr in args.flags else "zadd")
	keyspace_wake(task, r, .Zset)
}

keyspace_zset_store_items :: proc(task: ^Keyspace_Task, key: []u8, items: []zt.Item, event_name: string = "zrangestore") {
	r := keyspace_task_record(task, key)
	if r == nil { task.failed = true; return }
	keyspace_expire(task, r)
	charge := u128(len(items)) * 512 + 8192
	for &item in items { buf: [21]u8; charge += u128(len(zt.item_bytes(&item, &buf))) * 4 }
	if charge > u128(max(int)) || !ks.reserve_external(&keyspace_pool, int(charge)) { task.failed = true; return }
	work := Keyspace_Object_Work{kind = .Zset, object = zt.create_skiplist(len(items)), charge = int(charge)}
	defer keyspace_object_discard(&work)
	z := cast(zt.Zset)work.object
	maxlen, totlen := 0, 0
	for &item in items {
		buf: [21]u8; member := zt.item_bytes(&item, &buf)
		maxlen = max(maxlen, len(member)); totlen += len(member)
		_, _, _ = zt.add(z, item.score, member, {})
	}
	zt.convert_to_listpack_if_needed(z, maxlen, totlen)
	existed := r.exists
	if !keyspace_object_commit(task, r, &work) { return }
	if r.exists { r.expire_at = 0 }
	task.integer = i64(len(items)); task.dirty = i64(len(items) != 0 || existed)
	if len(items) > 0 { keyspace_changed(task, r, .Zset, event_name); keyspace_wake(task, r, .Zset) } else if existed { keyspace_changed(task, r, .Generic, "del") }
}

keyspace_zset_pop :: proc(task: ^Keyspace_Task) {
	argv := task.argv
	many := task.command_name == "zmpop"
	max_end := task.command_name == "zpopmax"
	count: i64
	if many { args, err := zt.parse_zmpop(argv, 1); if err != .None { task.failed = true; return }; max_end = args.max_end; count = args.count } else {
		value, err := zt.parse_zpop_count(argv); if err != .None { task.failed = true; return }; count = value
	}
	for r in task.records {
		keyspace_expire(task, r)
		if r.exists && r.kind != u8(Obj_Type.Zset) { task.failed = true; return }
		keyspace_touch(task, r)
		if !r.exists { continue }
		work, ok := keyspace_object_work(task, r, .Zset)
		if !ok { return }; defer keyspace_object_discard(&work)
		z := cast(zt.Zset)work.object
		n := 1 if count < 0 else int(min(count, i64(keyspace_zset_length(z))))
		b := keyspace_object_builder(task, .Zset, z); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		if many { keyspace_builder_integer(&b, 2, '*'); keyspace_builder_bulk(&b, transmute([]u8)r.key) }
		width := 1 if many || (count >= 0 && task.client.resp == RESP3) else 2
		keyspace_builder_integer(&b, i64(n * width), '*')
		for _ in 0 ..< n {
			item := zt.peek(z, max_end)
			if many || (count >= 0 && task.client.resp == RESP3) { keyspace_builder_integer(&b, 2, '*') }
			buf: [21]u8; keyspace_builder_bulk(&b, zt.item_bytes(&item, &buf)); keyspace_builder_double(task, &b, item.score)
			zt.pop(z, max_end)
		}
		if !keyspace_builder_finish(task, &b) { return }
		if n > 0 { if !keyspace_object_commit(task, r, &work) { return }; task.dirty = i64(n)
			keyspace_notify(task, r, .Zset, "zpopmax" if max_end else "zpopmin")
			if !r.exists { keyspace_notify(task, r, .Generic, "del") }
			keyspace_invalidate(task, r)
		}; return
	}
	b := keyspace_object_builder(task, .Zset, nil); defer ks.free(&keyspace_pool, b.bytes)
	if b.failed { return }
	keyspace_builder_text(&b, "_\r\n" if many && task.client.resp == RESP3 else "*-1\r\n" if many else "*0\r\n")
	keyspace_builder_finish(task, &b)
}

keyspace_zset_algebra :: proc(task: ^Keyspace_Task) {
	argv := task.argv
	name := task.command_name
	store := name == "zunionstore" || name == "zinterstore" || name == "zdiffstore"
	index := 2 if store else 1
	n, err := zt.parse_setop_numkeys(argv, index)
	if err != .None { task.failed = true; return }
	op := zt.Setop.Union if name == "zunion" || name == "zunionstore" else zt.Setop.Diff if name == "zdiff" || name == "zdiffstore" else zt.Setop.Inter
	card_only := name == "zintercard"
	reservation := u128(n) * (size_of(zt.Source) + size_of(f64) + size_of(zt.Zset)) + 8192
	for i in 0 ..< n {
		r := keyspace_task_record(task, argv[index + 1 + i])
		if r == nil { task.failed = true; return }
		keyspace_expire(task, r)
		if r.exists && r.kind != u8(Obj_Type.Zset) && r.kind != u8(Obj_Type.Set) { task.failed = true; return }
		keyspace_read(task, r)
		reservation += u128(keyspace_object_memory(Obj_Type(r.kind), r.object)) * 4 + u128(keyspace_object_length(Obj_Type(r.kind), r.object)) * 512
	}
	if reservation > u128(max(int)) || !ks.reserve_external(&keyspace_pool, int(reservation)) { task.failed = true; return }
	defer ks.release_external(&keyspace_pool, int(reservation))
	weights := make([]f64, n); defer delete(weights)
	sources := make([]zt.Source, n); defer delete(sources)
	temps := make([]zt.Zset, n); defer { for z in temps { if z != nil { zt.destroy(z) } }; delete(temps) }
	for i in 0 ..< n {
		r := keyspace_task_record(task, argv[index + 1 + i])
		z := cast(zt.Zset)r.object
		if r.kind == u8(Obj_Type.Set) && r.exists {
			s := cast(st.Set)r.object; z = zt.set_source_create(st.size(s)); temps[i] = z
			it := st.iterator(s)
			for { value, more := st.next(&it); if !more { break }; buf: [21]u8; zt.set_source_add(z, st.value_bytes(value, &buf)) }
		}
		sources[i] = zt.source_make(z, 1); sources[i].id = rawptr(r)
	}
	options, failure := zt.parse_setop_options(argv, index + n + 1, n, op, store, card_only, weights)
	if failure != .None { task.failed = true; return }
	for &source, i in sources { source.weight = weights[i] }
	result, card, maxlen, totlen := zt.setop_compute(sources, op, options.aggregate, card_only, int(options.limit))
	if card_only { task.integer = i64(card); return }
	card = zt.length(result)
	defer zt.destroy(result)
	if store {
		zt.convert_to_listpack_if_needed(result, maxlen, totlen)
		r := keyspace_task_record(task, argv[1]); if r == nil { task.failed = true; return }; keyspace_expire(task, r)
		actual := zt.memory_usage(result)
		if !ks.reserve_external(&keyspace_pool, actual) { task.failed = true; return }
		work := Keyspace_Object_Work{kind = .Zset, object = result, charge = actual}; result = nil; defer keyspace_object_discard(&work)
		existed := r.exists
		if !keyspace_object_commit(task, r, &work) { return }; if r.exists { r.expire_at = 0 }
		task.integer = i64(card); task.dirty = i64(card != 0 || existed)
		if card > 0 { keyspace_changed(task, r, .Zset, task.command_name); keyspace_wake(task, r, .Zset) } else if existed { keyspace_changed(task, r, .Generic, "del") }; return
	}
	items := make([dynamic]zt.Item, 0, zt.length(result)); defer delete(items)
	zt.rank_range(result, 0, -1, false, &items)
	b := keyspace_object_builder(task, .Zset, result); defer ks.free(&keyspace_pool, b.bytes)
	if b.failed { return }; keyspace_zset_reply_items(task, &b, items[:], options.withscores); keyspace_builder_finish(task, &b)
}

keyspace_zset_length :: proc(z: zt.Zset) -> int {
	return 0 if z == nil else zt.length(z)
}

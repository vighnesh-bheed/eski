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

keyspace_zset_reply_items :: proc(task: ^Keyspace_Task, b: ^Keyspace_Builder, items: []zt.Item, scores: bool, paired: bool = false) {
	width := 2 if scores && task.client.resp != RESP3 && !paired else 1
	keyspace_builder_integer(b, i64(len(items) * width), '*')
	for &item in items {
		if scores && (task.client.resp == RESP3 || paired) { keyspace_builder_integer(b, 2, '*') }
		buf: [21]u8
		keyspace_builder_bulk(b, zt.item_bytes(&item, &buf))
		if scores { keyspace_builder_double(task, b, item.score) }
	}
}

keyspace_zset_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	switch task.command_name {
	case "zunion", "zinter", "zdiff", "zunionstore", "zinterstore", "zdiffstore", "zintercard":
		keyspace_zset_algebra(task)
	case "zpopmin", "zpopmax", "zmpop":
		keyspace_zset_pop(task)
	case "zadd", "zincrby":
		keyspace_zset_add(task)
	case:
		keyspace_zset_query(task)
	}
}

@(private = "file")
Keyspace_Zset_Shape :: struct {
	kind:      zt.Range_Kind,
	direction: zt.Direction,
	key_at:    int,
	ranged:    bool,
	trims:     bool,
	stores:    bool,
}

@(private = "file")
Keyspace_Zset_Call :: struct {
	task:  ^Keyspace_Task,
	r:     ^ks.Record,
	z:     zt.Zset,
	b:     ^Keyspace_Builder,
	shape: Keyspace_Zset_Shape,
	args:  zt.Zrange_Args,
}

@(private = "file")
keyspace_zset_shape :: proc "contextless" (name: string) -> (shape: Keyspace_Zset_Shape) {
	shape.key_at = 1
	shape.kind = .Auto
	shape.direction = .Auto
	switch name {
	case "zrange":
		shape.ranged = true
	case "zrangestore":
		shape.ranged, shape.stores, shape.key_at = true, true, 2
	case "zrevrange":
		shape.ranged, shape.kind, shape.direction = true, .Rank, .Reverse
	case "zrangebyscore":
		shape.ranged, shape.kind, shape.direction = true, .Score, .Forward
	case "zrevrangebyscore":
		shape.ranged, shape.kind, shape.direction = true, .Score, .Reverse
	case "zrangebylex":
		shape.ranged, shape.kind, shape.direction = true, .Lex, .Forward
	case "zrevrangebylex":
		shape.ranged, shape.kind, shape.direction = true, .Lex, .Reverse
	case "zremrangebyrank":
		shape.ranged, shape.trims, shape.kind, shape.direction = true, true, .Rank, .Forward
	case "zremrangebyscore":
		shape.ranged, shape.trims, shape.kind, shape.direction = true, true, .Score, .Forward
	case "zremrangebylex":
		shape.ranged, shape.trims, shape.kind, shape.direction = true, true, .Lex, .Forward
	}
	return
}

@(private = "file")
keyspace_zset_precheck :: proc(call: ^Keyspace_Zset_Call) -> bool {
	argv := call.task.argv
	if call.shape.ranged {
		parsed, err := zt.parse_zrange(argv, call.shape.key_at, call.shape.stores, call.shape.kind, call.shape.direction)
		if err != .None {
			return false
		}
		call.args = parsed
	}
	switch call.task.command_name {
	case "zrank", "zrevrank":
		return len(argv) <= 3 || (len(argv) == 4 && zt.keyword(argv[3], "withscore"))
	case "zcount":
		_, ok := zt.parse_range(argv[2], argv[3])
		return ok
	case "zlexcount":
		_, ok := zt.parse_lex_range(argv[2], argv[3])
		return ok
	case "zrandmember":
		_, _, err := zt.parse_zrandmember(argv)
		return err == .None
	case "zscan":
		_, ok := ht.parse_scan_cursor(argv[2])
		return ok
	}
	return true
}

@(private = "file")
keyspace_zset_query :: proc(task: ^Keyspace_Task) {
	call := Keyspace_Zset_Call{task = task, shape = keyspace_zset_shape(task.command_name)}
	call.r = keyspace_task_record(task, task.argv[call.shape.key_at])
	if call.r == nil || !keyspace_zset_precheck(&call) {
		task.failed = true
		return
	}
	keyspace_expire(task, call.r)
	if call.r.exists && call.r.kind != u8(Obj_Type.Zset) {
		task.failed = true
		return
	}
	call.z = cast(zt.Zset)call.r.object
	writes := call.shape.trims || task.command_name == "zrem"
	if writes { keyspace_touch(task, call.r) } else { keyspace_read(task, call.r) }
	b := keyspace_object_builder(task, .Zset, call.z, len(task.argv) * 64)
	defer ks.free(&keyspace_pool, b.bytes)
	if b.failed {
		return
	}
	call.b = &b
	switch {
	case writes:
		keyspace_zset_trim(&call)
	case task.command_name == "zcard":
		task.integer = i64(keyspace_zset_length(call.z))
	case task.command_name == "zscore" || task.command_name == "zmscore":
		keyspace_zset_scores(&call)
	case task.command_name == "zrank" || task.command_name == "zrevrank":
		keyspace_zset_ranking(&call)
	case task.command_name == "zcount" || task.command_name == "zlexcount":
		keyspace_zset_counting(&call)
	case:
		keyspace_zset_listing(&call)
	}
}

@(private = "file")
keyspace_zset_scores :: proc(call: ^Keyspace_Zset_Call) {
	task, b := call.task, call.b
	members := task.argv[2:]
	if task.command_name == "zmscore" {
		keyspace_builder_integer(b, i64(len(members)), '*')
	}
	for member in members {
		value, present := f64(0), false
		if call.z != nil {
			value, present = zt.score(call.z, member)
		}
		if present { keyspace_builder_double(task, b, value) } else { keyspace_hash_null(task, b) }
	}
	keyspace_builder_finish(task, b)
}

@(private = "file")
keyspace_zset_ranking :: proc(call: ^Keyspace_Zset_Call) {
	task, b := call.task, call.b
	scored := len(task.argv) == 4
	place, value, present := 0, f64(0), false
	if call.z != nil {
		place, value, present = zt.rank(call.z, task.argv[2], task.command_name == "zrevrank")
	}
	switch {
	case present:
		if scored { keyspace_builder_integer(b, 2, '*') }
		keyspace_builder_integer(b, i64(place))
		if scored { keyspace_builder_double(task, b, value) }
	case scored:
		keyspace_builder_text(b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n")
	case:
		keyspace_hash_null(task, b)
	}
	keyspace_builder_finish(task, b)
}

@(private = "file")
keyspace_zset_counting :: proc(call: ^Keyspace_Zset_Call) {
	task := call.task
	low, high := task.argv[2], task.argv[3]
	if task.command_name == "zlexcount" {
		span, ok := zt.parse_lex_range(low, high)
		if !ok { task.failed = true; return }
		if call.z != nil { task.integer = i64(zt.lex_count(call.z, &span)) }
		return
	}
	span, ok := zt.parse_range(low, high)
	if !ok { task.failed = true; return }
	if call.z != nil { task.integer = i64(zt.count_in_range(call.z, &span)) }
}

@(private = "file")
keyspace_zset_trim :: proc(call: ^Keyspace_Zset_Call) {
	task := call.task
	if call.z == nil {
		return
	}
	work, ok := keyspace_object_work(task, call.r, .Zset)
	if !ok {
		return
	}
	defer keyspace_object_discard(&work)
	target := cast(zt.Zset)work.object
	removed := 0
	if call.shape.trims {
		#partial switch call.args.kind {
		case .Rank:
			removed = zt.remrange_by_rank(target, call.args.start, call.args.end)
		case .Score:
			removed = zt.remrange_by_score(target, &call.args.srange)
		case .Lex:
			removed = zt.remrange_by_lex(target, &call.args.lrange)
		}
	} else {
		for member in task.argv[2:] {
			if zt.del(target, member) { removed += 1 }
		}
	}
	task.integer = i64(removed)
	if removed == 0 || !keyspace_object_commit(task, call.r, &work) {
		return
	}
	task.dirty = task.integer
	keyspace_notify(task, call.r, .Zset, task.command_name)
	if !call.r.exists { keyspace_notify(task, call.r, .Generic, "del") }
	keyspace_invalidate(task, call.r)
}

@(private = "file")
keyspace_zset_listing :: proc(call: ^Keyspace_Zset_Call) {
	task := call.task
	size := keyspace_zset_length(call.z)
	charge := size * 4 * size_of(zt.Item) + 1024
	if !ks.reserve_external(&keyspace_pool, charge) {
		task.failed = true
		return
	}
	defer ks.release_external(&keyspace_pool, charge)
	items := make([dynamic]zt.Item, 0, size * 2)
	defer delete(items)
	switch {
	case call.shape.ranged:
		keyspace_zset_window(call, &items)
	case task.command_name == "zscan":
		keyspace_zset_scan_reply(call, &items)
	case task.command_name == "zrandmember":
		keyspace_zset_sample(call, &items)
	case:
		task.failed = true
	}
}

@(private = "file")
keyspace_zset_window :: proc(call: ^Keyspace_Zset_Call, items: ^[dynamic]zt.Item) {
	spec := &call.args
	if call.z != nil {
		#partial switch spec.kind {
		case .Rank:
			zt.rank_range(call.z, spec.start, spec.end, spec.reverse, items)
		case .Score:
			zt.score_range(call.z, &spec.srange, spec.offset, spec.limit, spec.reverse, items)
		case .Lex:
			zt.lex_range(call.z, &spec.lrange, spec.offset, spec.limit, spec.reverse, call.shape.stores, items)
		}
	}
	if call.shape.stores {
		keyspace_zset_store_items(call.task, call.task.argv[1], items^[:])
		return
	}
	keyspace_zset_reply_items(call.task, call.b, items^[:], spec.withscores)
	keyspace_builder_finish(call.task, call.b)
}

@(private = "file")
keyspace_zset_scan_reply :: proc(call: ^Keyspace_Zset_Call, items: ^[dynamic]zt.Item) {
	task, b := call.task, call.b
	cursor, valid := ht.parse_scan_cursor(task.argv[2])
	if !valid {
		task.failed = true
		return
	}
	options: ht.Scan_Options
	next: u64
	if call.z != nil {
		parsed, err := ht.parse_scan_options(task.argv[3:], false)
		if err != .None {
			task.failed = true
			return
		}
		options = parsed
		next = zt.scan(call.z, cursor, options.count, items)
	}
	view := items^[:]
	kept := 0
	for pair := 0; pair + 1 < len(view); pair += 2 {
		scratch: [zt.G17_MAX]u8
		if options.use_pattern && !glob_match(options.pattern, zt.scan_value_bytes(&view[pair], &scratch), false) {
			continue
		}
		view[kept], view[kept + 1] = view[pair], view[pair + 1]
		kept += 2
	}
	digits: [24]u8
	keyspace_builder_integer(b, 2, '*')
	keyspace_builder_bulk(b, digits[:format_u64(raw_data(digits[:]), next)])
	keyspace_builder_integer(b, i64(kept), '*')
	for index in 0 ..< kept {
		scratch: [zt.G17_MAX]u8
		keyspace_builder_bulk(b, zt.scan_value_bytes(&view[index], &scratch))
	}
	keyspace_builder_finish(task, b)
}

@(private = "file")
keyspace_zset_sample :: proc(call: ^Keyspace_Zset_Call, items: ^[dynamic]zt.Item) {
	task, b := call.task, call.b
	wanted, scores, err := zt.parse_zrandmember(task.argv)
	if err != .None {
		task.failed = true
		return
	}
	if len(task.argv) == 2 {
		if call.z == nil {
			task.null = true
			return
		}
		pick := zt.random_element(call.z)
		scratch: [21]u8
		keyspace_builder_bulk(b, zt.item_bytes(&pick, &scratch))
		keyspace_builder_finish(task, b)
		return
	}
	if call.z == nil {
		keyspace_builder_integer(b, 0, '*')
		keyspace_builder_finish(task, b)
		return
	}
	unique := wanted >= 0
	total := min(wanted, i64(keyspace_zset_length(call.z))) if unique else -wanted
	if total > i64(max(int) / (4 * size_of(zt.Item))) {
		task.failed = true
		return
	}
	if unique {
		zt.random_unique(call.z, int(total), items)
	} else {
		extra := int(total) * 2 * size_of(zt.Item)
		if !ks.reserve_external(&keyspace_pool, extra) {
			task.failed = true
			return
		}
		defer ks.release_external(&keyspace_pool, extra)
		if reserve(items, int(total)) != nil {
			task.failed = true
			return
		}
		zt.random_with_repeats(call.z, int(total), items)
	}
	keyspace_zset_reply_items(task, b, items^[:], scores)
	keyspace_builder_finish(task, b)
}

@(private = "file")
Keyspace_Zadd_Outcome :: struct {
	added:   int,
	updated: int,
	skipped: bool,
	last:    f64,
}

@(private = "file")
keyspace_zset_read_scores :: proc(argv: [][]u8, args: zt.Zadd_Args, scores: []f64) -> bool {
	for &slot, i in scores {
		value, ok := zt.parse_score(argv[args.scoreidx + 2 * i])
		if !ok {
			return false
		}
		slot = value
	}
	return true
}

@(private = "file")
keyspace_zset_merge :: proc(z: zt.Zset, pairs: [][]u8, scores: []f64, flags: zt.Zadd_Flags) -> (outcome: Keyspace_Zadd_Outcome, ok: bool) {
	for value, i in scores {
		outs, current, valid := zt.add(z, value, pairs[2 * i + 1], flags)
		if !valid {
			return outcome, false
		}
		if .Added in outs { outcome.added += 1 }
		if .Updated in outs { outcome.updated += 1 }
		outcome.skipped = .Nop in outs
		outcome.last = current
	}
	return outcome, true
}

@(private = "file")
keyspace_zset_add_reply :: proc(task: ^Keyspace_Task, z: zt.Zset, args: zt.Zadd_Args, outcome: Keyspace_Zadd_Outcome) -> bool {
	if .Incr not_in args.flags {
		task.integer = i64(outcome.added + outcome.updated if args.ch else outcome.added)
		return true
	}
	if outcome.skipped {
		task.null = true
		return true
	}
	b := keyspace_object_builder(task, .Zset, z)
	defer ks.free(&keyspace_pool, b.bytes)
	if b.failed {
		return false
	}
	keyspace_builder_double(task, &b, outcome.last)
	return keyspace_builder_finish(task, &b)
}

keyspace_zset_add :: proc(task: ^Keyspace_Task) {
	args, err := zt.parse_zadd(task.argv, task.command_name == "zincrby")
	if err != .None {
		task.failed = true
		return
	}
	room := args.elements * size_of(f64)
	if !ks.reserve_external(&keyspace_pool, room) {
		task.failed = true
		return
	}
	defer ks.release_external(&keyspace_pool, room)
	scores := make([]f64, args.elements)
	defer delete(scores)
	if !keyspace_zset_read_scores(task.argv, args, scores) {
		task.failed = true
		return
	}
	r := task.records[0]
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Zset) {
		task.failed = true
		return
	}
	keyspace_touch(task, r)
	incremental := .Incr in args.flags
	if !r.exists && .Xx in args.flags {
		task.null = incremental
		return
	}
	work, ok := keyspace_object_work(task, r, .Zset)
	if !ok {
		return
	}
	defer keyspace_object_discard(&work)
	if !r.exists {
		zt.destroy(cast(zt.Zset)work.object)
		work.object = zt.type_create(args.elements, len(task.argv[args.scoreidx + 1]))
	}
	target := cast(zt.Zset)work.object
	outcome, applied := keyspace_zset_merge(target, task.argv[args.scoreidx:], scores, args.flags)
	if !applied {
		task.failed = true
		return
	}
	if !keyspace_zset_add_reply(task, target, args, outcome) {
		return
	}
	changed := outcome.added + outcome.updated
	if changed == 0 || !keyspace_object_commit(task, r, &work) {
		return
	}
	task.dirty = i64(changed)
	keyspace_changed(task, r, .Zset, "zincr" if incremental else "zadd")
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

@(private = "file")
keyspace_zset_setop_kind :: proc "contextless" (name: string) -> (op: zt.Setop, stores, card_only: bool) {
	switch name {
	case "zunionstore":
		return .Union, true, false
	case "zinter":
		return .Inter, false, false
	case "zinterstore":
		return .Inter, true, false
	case "zintercard":
		return .Inter, false, true
	case "zdiff":
		return .Diff, false, false
	case "zdiffstore":
		return .Diff, true, false
	}
	return .Union, false, false
}

@(private = "file")
keyspace_zset_gather :: proc(task: ^Keyspace_Task, keys: [][]u8) -> (budget: u128, ok: bool) {
	budget = u128(len(keys)) * (size_of(zt.Source) + size_of(f64) + size_of(zt.Zset)) + 8192
	for key in keys {
		r := keyspace_task_record(task, key)
		if r == nil {
			return
		}
		keyspace_expire(task, r)
		if r.exists && r.kind != u8(Obj_Type.Zset) && r.kind != u8(Obj_Type.Set) {
			return
		}
		keyspace_read(task, r)
		kind := Obj_Type(r.kind)
		budget += u128(keyspace_object_memory(kind, r.object)) * 4 + u128(keyspace_object_length(kind, r.object)) * 512
	}
	return budget, true
}

@(private = "file")
keyspace_zset_source :: proc(r: ^ks.Record, temp: ^zt.Zset) -> zt.Source {
	z := cast(zt.Zset)r.object
	if r.exists && r.kind == u8(Obj_Type.Set) {
		members := cast(st.Set)r.object
		z = zt.set_source_create(st.size(members))
		temp^ = z
		walk := st.iterator(members)
		for {
			value, more := st.next(&walk)
			if !more {
				break
			}
			scratch: [21]u8
			zt.set_source_add(z, st.value_bytes(value, &scratch))
		}
	}
	source := zt.source_make(z, 1)
	source.id = rawptr(r)
	return source
}

@(private = "file")
keyspace_zset_setop_store :: proc(task: ^Keyspace_Task, result: ^zt.Zset, widest, total_len: int) {
	card := zt.length(result^)
	zt.convert_to_listpack_if_needed(result^, widest, total_len)
	r := keyspace_task_record(task, task.argv[1])
	if r == nil {
		task.failed = true
		return
	}
	keyspace_expire(task, r)
	actual := zt.memory_usage(result^)
	if !ks.reserve_external(&keyspace_pool, actual) {
		task.failed = true
		return
	}
	work := Keyspace_Object_Work{kind = .Zset, object = result^, charge = actual}
	result^ = nil
	defer keyspace_object_discard(&work)
	existed := r.exists
	if !keyspace_object_commit(task, r, &work) {
		return
	}
	if r.exists { r.expire_at = 0 }
	task.integer = i64(card)
	task.dirty = i64(card != 0 || existed)
	switch {
	case card > 0:
		keyspace_changed(task, r, .Zset, task.command_name)
		keyspace_wake(task, r, .Zset)
	case existed:
		keyspace_changed(task, r, .Generic, "del")
	}
}

@(private = "file")
keyspace_zset_setop_reply :: proc(task: ^Keyspace_Task, result: zt.Zset, withscores: bool) {
	items := make([dynamic]zt.Item, 0, zt.length(result))
	defer delete(items)
	zt.rank_range(result, 0, -1, false, &items)
	b := keyspace_object_builder(task, .Zset, result)
	defer ks.free(&keyspace_pool, b.bytes)
	if b.failed {
		return
	}
	keyspace_zset_reply_items(task, &b, items[:], withscores)
	keyspace_builder_finish(task, &b)
}

keyspace_zset_algebra :: proc(task: ^Keyspace_Task) {
	op, stores, card_only := keyspace_zset_setop_kind(task.command_name)
	first := 2 if stores else 1
	count, err := zt.parse_setop_numkeys(task.argv, first)
	if err != .None {
		task.failed = true
		return
	}
	keys := task.argv[first + 1:][:count]
	budget, gathered := keyspace_zset_gather(task, keys)
	if !gathered || budget > u128(max(int)) || !ks.reserve_external(&keyspace_pool, int(budget)) {
		task.failed = true
		return
	}
	defer ks.release_external(&keyspace_pool, int(budget))
	weights := make([]f64, count)
	defer delete(weights)
	sources := make([]zt.Source, count)
	defer delete(sources)
	temps := make([]zt.Zset, count)
	defer {
		for temp in temps { if temp != nil { zt.destroy(temp) } }
		delete(temps)
	}
	for key, i in keys {
		sources[i] = keyspace_zset_source(keyspace_task_record(task, key), &temps[i])
	}
	options, failure := zt.parse_setop_options(task.argv, first + count + 1, count, op, stores, card_only, weights)
	if failure != .None {
		task.failed = true
		return
	}
	for &source, i in sources { source.weight = weights[i] }
	result, card, widest, total_len := zt.setop_compute(sources, op, options.aggregate, card_only, int(options.limit))
	if card_only {
		task.integer = i64(card)
		return
	}
	defer zt.destroy(result)
	if stores {
		keyspace_zset_setop_store(task, &result, widest, total_len)
		return
	}
	keyspace_zset_setop_reply(task, result, options.withscores)
}

keyspace_zset_length :: proc(z: zt.Zset) -> int {
	return 0 if z == nil else zt.length(z)
}

package main

import ks "keyspace"
import lt "listtype"

keyspace_list_destroy :: proc "contextless" (object: rawptr) {
	lt.destroy(cast(lt.List)object)
}

keyspace_list_seed :: proc(c: ^Conn, key: []u8, owner: int) -> ^ks.Record {
	pointer, kind, clock, expires, eligible := keyspace_store_seed_object(c.db, key)
	if !eligible || kind != .List { return nil }
	original := cast(lt.List)pointer
	charge := lt.memory_usage(original)
	if !ks.reserve_external(&keyspace_pool, charge) { return nil }
	object := lt.dup(original)
	actual := lt.memory_usage(object)
	if actual > charge && !ks.reserve_external(&keyspace_pool, actual - charge) {
		lt.destroy(object); ks.release_external(&keyspace_pool, charge); return nil
	}
	if actual < charge { ks.release_external(&keyspace_pool, charge - actual) }
	r := ks.record_new(&keyspace_pool, c.db.id, key, owner, false, nil, clock)
	if r == nil { lt.destroy(object); ks.release_external(&keyspace_pool, actual); return nil }
	r.exists = true
	r.kind = u8(Obj_Type.List)
	r.encoding = u8(list_obj_encoding(object))
	r.expire_at = expires
	r.object = object
	r.object_charge = actual
	r.object_destroy = keyspace_list_destroy
	return r
}

keyspace_list_import :: proc(db: ^Db, r: ^ks.Record) {
	keyspace_store_import_list(db, transmute([]u8)r.key, r.object, r.clock, r.expire_at)
	r.object = nil
	ks.release_external(&keyspace_pool, r.object_charge)
	r.object_charge = 0
}

Keyspace_List_Work :: struct {
	object: lt.List,
	charge: int,
}

keyspace_list_work :: proc(task: ^Keyspace_Task, r: ^ks.Record) -> (work: Keyspace_List_Work, ok: bool) {
	original := cast(lt.List)r.object
	size := u128(lt.memory_usage(original)) * 4 + u128(lt.length(original)) * 256 + u128(len(task.argv)) * 512 + 4096
	for arg in task.argv { size += u128(len(arg)) * 4 }
	if size > u128(max(int)) || !ks.reserve_external(&keyspace_pool, int(size)) { task.failed = true; return }
	work.charge = int(size)
	work.object = lt.dup(original) if original != nil else lt.create()
	ok = true
	return
}

keyspace_list_discard :: proc "contextless" (work: ^Keyspace_List_Work) {
	if work.object != nil { lt.destroy(work.object); work.object = nil }
	ks.release_external(&keyspace_pool, work.charge)
	work.charge = 0
}

keyspace_list_prepare_commit :: proc(task: ^Keyspace_Task, work: ^Keyspace_List_Work) -> bool {
	actual := lt.memory_usage(work.object)
	if actual > work.charge && !ks.reserve_external(&keyspace_pool, actual - work.charge) { task.failed = true; return false }
	if actual < work.charge { ks.release_external(&keyspace_pool, work.charge - actual) }
	work.charge = actual
	return true
}

keyspace_list_commit :: proc(task: ^Keyspace_Task, r: ^ks.Record, work: ^Keyspace_List_Work) -> bool {
	if !keyspace_list_prepare_commit(task, work) { return false }
	if lt.length(work.object) == 0 {
		keyspace_list_discard(work)
		keyspace_remove(r)
		return true
	}
	created := !r.exists
	ks.record_object_clear(r)
	ks.value_release(r.value)
	r.value = nil
	r.exists = true
	r.kind = u8(Obj_Type.List)
	r.object = work.object
	r.object_charge = work.charge
	r.object_destroy = keyspace_list_destroy
	r.encoding = u8(list_obj_encoding(work.object))
	r.changed = true
	r.value_changed = true
	keyspace_touch(task, r, created = created)
	if created { keyspace_notify(task, r, .New, "new") }
	work.object = nil
	work.charge = 0
	return true
}

Keyspace_Builder :: struct {
	bytes: []u8,
	used: int,
	failed: bool,
}

keyspace_builder :: proc(task: ^Keyspace_Task, l: lt.List) -> Keyspace_Builder {
	size := u128(lt.memory_usage(l)) * 2 + u128(lt.length(l)) * 32 + 1024
	for arg in task.argv { size += u128(len(arg)) }
	if size > u128(max(int)) { task.failed = true; return {failed = true} }
	bytes := ks.allocate(&keyspace_pool, int(size))
	if len(bytes) == 0 { task.failed = true; return {failed = true} }
	return {bytes = bytes}
}

keyspace_builder_bytes :: proc "contextless" (b: ^Keyspace_Builder, bytes: []u8) {
	if len(bytes) > len(b.bytes) - b.used { b.failed = true; return }
	copy(b.bytes[b.used:], bytes)
	b.used += len(bytes)
}

keyspace_builder_text :: proc "contextless" (b: ^Keyspace_Builder, text: string) {
	keyspace_builder_bytes(b, transmute([]u8)text)
}

keyspace_builder_integer :: proc "contextless" (b: ^Keyspace_Builder, value: i64, prefix: u8 = ':') {
	keyspace_builder_bytes(b, []u8{prefix})
	digits: [24]u8
	n := format_i64(raw_data(digits[:]), value)
	keyspace_builder_bytes(b, digits[:n])
	keyspace_builder_text(b, "\r\n")
}

keyspace_builder_bulk :: proc "contextless" (b: ^Keyspace_Builder, bytes: []u8) {
	keyspace_builder_integer(b, i64(len(bytes)), '$')
	keyspace_builder_bytes(b, bytes)
	keyspace_builder_text(b, "\r\n")
}

keyspace_builder_finish :: proc "contextless" (task: ^Keyspace_Task, b: ^Keyspace_Builder) -> bool {
	if b.failed { task.failed = true; return false }
	task.results[0] = ks.value_new(&keyspace_pool, b.bytes[:b.used])
	if task.results[0] == nil { task.failed = true; return false }
	task.raw = true
	return true
}

keyspace_list_reply_range :: proc(l: lt.List, start, count: int, b: ^Keyspace_Builder) {
	it := lt.iterator(l, start, .Tail)
	entry: lt.List_Entry
	buf: [21]u8
	for _ in 0 ..< count {
		if !lt.iter_next(&it, &entry) { b.failed = true; return }
		keyspace_builder_bulk(b, lt.value_bytes(lt.entry_value(&it, &entry), &buf))
	}
}

keyspace_list_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	argv := task.argv
	r := task.records[0]
	op := task.op
	start, end: int
	if op == .Lrange || op == .Ltrim {
		a, x := lt.parse_index(argv[2]); b, y := lt.parse_index(argv[3])
		if x != .None || y != .None { task.failed = true; return }; start = a; end = b
	}
	positions: lt.Lpos_Args
	if op == .Lpos {
		parsed, err := lt.parse_lpos_args(argv[3:])
		if err != .None { task.failed = true; return }; positions = parsed
	}
	where_ := lt.Where.Head
	count := 1
	if op == .Lpop || op == .Rpop {
		if len(argv) > 3 { task.failed = true; return }
		if len(argv) == 3 {
			n, err := lt.parse_pop_count(argv[2]); if err != .None { task.failed = true; return }; count = n
		}
		if op == .Rpop { where_ = .Tail }
	}
	if op == .Lmove || op == .Rpoplpush { keyspace_list_move(task); return }
	if op == .Lmpop { keyspace_list_mpop(task); return }
	if op == .Linsert {
		_, err := lt.parse_linsert_where(argv[2]); if err != .None { task.failed = true; return }
	}
	if op == .Lrem {
		_, err := lt.parse_lrem_count(argv[2]); if err != .None { task.failed = true; return }
	}
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.List) { task.failed = true; return }
	l := cast(lt.List)r.object
	read := op == .Llen || op == .Lindex || op == .Lrange || op == .Lpos
	if read { keyspace_read(task, r) } else { keyspace_touch(task, r) }
	#partial switch op {
	case .Llen:
		task.integer = i64(lt.length(l)); return
	case .Lindex:
		task.bulk = true
		if !r.exists { task.null = true; return }
		index, err := lt.parse_index(argv[2]); if err != .None { task.failed = true; return }
		value, ok := lt.index(l, index)
		if !ok { task.null = true; return }
		buf: [21]u8
		task.results[0] = ks.value_new(&keyspace_pool, lt.value_bytes(value, &buf))
		if task.results[0] == nil { task.failed = true }; return
	case .Lrange:
		b := keyspace_builder(task, l); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		a, z, ok := lt.range_normalize(lt.length(l), start, end)
		n := z - a + 1 if ok else 0
		keyspace_builder_integer(&b, i64(n), '*')
		if n > 0 { keyspace_list_reply_range(l, a, n, &b) }
		keyspace_builder_finish(task, &b); return
	case .Lpos:
		if l == nil && positions.count == -1 { task.null = true; return }
		b := keyspace_builder(task, l); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		charge := lt.length(l) * 2 * size_of(int)
		if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }
		defer ks.release_external(&keyspace_pool, charge)
		matches := make([dynamic]int, 0, lt.length(l))
		defer delete(matches)
		pos := -1
		if l != nil { pos = lt.lpos(l, argv[2], positions.rank, positions.count, positions.maxlen, &matches) }
		if positions.count == -1 {
			if pos < 0 { task.null = true } else { task.integer = i64(pos) }; return
		}
		keyspace_builder_integer(&b, i64(len(matches)), '*')
		for position in matches { keyspace_builder_integer(&b, i64(position)) }
		keyspace_builder_finish(task, &b); return
	case:
	}
	if !r.exists && (op == .Lpushx || op == .Rpushx || op == .Linsert || op == .Lrem) { return }
	if !r.exists && op == .Lset { task.failed = true; return }
	if op == .Lpop || op == .Rpop {
		if !r.exists {
			if len(argv) == 3 {
				b := keyspace_builder(task, nil); defer ks.free(&keyspace_pool, b.bytes)
				if b.failed { return }
				keyspace_builder_text(&b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n")
				keyspace_builder_finish(task, &b)
			} else { task.null = true }; return
		}
		count = min(count, lt.length(l))
		if len(argv) == 2 && count == 0 { task.null = true; return }
	}
	if (op == .Lpop || op == .Rpop) && count == 0 {
		b := keyspace_builder(task, nil); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		keyspace_builder_integer(&b, 0, '*'); keyspace_builder_finish(task, &b); return
	}
	work, ok := keyspace_list_work(task, r)
	if !ok { return }
	defer keyspace_list_discard(&work)
	candidate := work.object
	#partial switch op {
	case .Lpush, .Rpush, .Lpushx, .Rpushx:
		if op == .Rpush || op == .Rpushx { where_ = .Tail }
		lt.try_conversion_append_values(candidate, argv[2:])
		for value in argv[2:] { lt.push(candidate, value, where_) }
		task.integer = i64(lt.length(candidate)); task.dirty = i64(len(argv) - 2)
	case .Lpop, .Rpop:
		b := keyspace_builder(task, candidate); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		if len(argv) == 3 { keyspace_builder_integer(&b, i64(count), '*') }
		index := 0 if where_ == .Head else -1
		direction := lt.Where.Tail if where_ == .Head else lt.Where.Head
		it := lt.iterator(candidate, index, direction)
		entry: lt.List_Entry
		buf: [21]u8
		for _ in 0 ..< count {
			if !lt.iter_next(&it, &entry) { task.failed = true; return }
			keyspace_builder_bulk(&b, lt.value_bytes(lt.entry_value(&it, &entry), &buf))
		}
		if !keyspace_builder_finish(task, &b) { return }
		a, n := lt.pop_range_bounds(candidate, where_, count)
		lt.delete_range(candidate, a, n)
		lt.try_conversion(candidate, .Shrinking)
		task.dirty = i64(count)
	case .Lset:
		index, err := lt.parse_index(argv[2])
		if err != .None || !lt.lset(candidate, index, argv[3]) { task.failed = true; return }
		task.ok = true; task.dirty = 1
	case .Linsert:
		after, _ := lt.parse_linsert_where(argv[2])
		if !lt.linsert(candidate, after, argv[3], argv[4]) { task.integer = -1; return }
		task.integer = i64(lt.length(candidate)); task.dirty = 1
	case .Ltrim:
		before := lt.length(candidate)
		lt.ltrim(candidate, start, end)
		task.dirty = i64(before - lt.length(candidate)); task.ok = true
	case .Lrem:
		n, _ := lt.parse_lrem_count(argv[2])
		removed := lt.lrem(candidate, n, argv[3])
		task.integer = i64(removed); task.dirty = i64(removed)
		if removed == 0 { return }
		lt.try_conversion(candidate, .Shrinking)
	case:
		task.failed = true; return
	}
	if !keyspace_list_commit(task, r, &work) { task.dirty = 0; return }
	#partial switch op {
	case .Lpush, .Rpush, .Lpushx, .Rpushx:
		keyspace_changed(task, r, .List, "lpush" if where_ == .Head else "rpush")
		keyspace_wake(task, r, .List)
	case .Lset: keyspace_changed(task, r, .List, "lset")
	case .Linsert: keyspace_changed(task, r, .List, "linsert"); keyspace_wake(task, r, .List)
	case .Lpop, .Rpop, .Ltrim, .Lrem:
		event := "lpop" if op == .Lpop else "rpop" if op == .Rpop else "ltrim" if op == .Ltrim else "lrem"
		keyspace_notify(task, r, .List, event)
		if !r.exists { keyspace_notify(task, r, .Generic, "del") }
		keyspace_invalidate(task, r)
	}
}

keyspace_list_move :: proc(task: ^Keyspace_Task) {
	argv := task.argv
	from, to := lt.Where.Tail, lt.Where.Head
	if task.op == .Lmove {
		a, x := lt.parse_direction(argv[3]); b, y := lt.parse_direction(argv[4])
		if x != .None || y != .None { task.failed = true; return }; from = a; to = b
	}
	source, destination := task.records[0], task.records[1]
	keyspace_expire(task, source)
	if source.exists && source.kind != u8(Obj_Type.List) { task.failed = true; return }
	keyspace_touch(task, source)
	if !source.exists { task.null = true; return }
	keyspace_expire(task, destination)
	if destination.exists && destination.kind != u8(Obj_Type.List) { task.failed = true; return }
	keyspace_touch(task, destination)
	left, ok := keyspace_list_work(task, source)
	if !ok { return }; defer keyspace_list_discard(&left)
	right: Keyspace_List_Work
	if source != destination {
		valid: bool
		right, valid = keyspace_list_work(task, destination)
		if !valid { return }
	}
	defer keyspace_list_discard(&right)
	src := left.object
	dst := src if source == destination else right.object
	value, found := lt.peek(src, from)
	if !found { task.null = true; return }
	buf: [21]u8
	bytes := lt.value_bytes(value, &buf)
	task.results[0] = ks.value_new(&keyspace_pool, bytes)
	if task.results[0] == nil { task.failed = true; return }
	owned := ks.value_data(task.results[0])
	encoding := src.encoding
	if source == destination { lt.pop_discard(src, from) }
	lt.try_conversion_append(dst, lt.moved_add_bytes(encoding, value, len(owned)), 1)
	lt.push(dst, owned, to)
	if source != destination { lt.pop_discard(src, from) }
	lt.try_conversion(src, .Shrinking)
	if !keyspace_list_prepare_commit(task, &left) { return }
	if source != destination && !keyspace_list_prepare_commit(task, &right) { return }
	if !keyspace_list_commit(task, source, &left) { return }
	if source != destination && !keyspace_list_commit(task, destination, &right) { task.failed = true; return }
	task.bulk = true; task.dirty = 1
	keyspace_changed(task, destination, .List, "lpush" if to == .Head else "rpush")
	keyspace_wake(task, destination, .List)
	keyspace_notify(task, source, .List, "lpop" if from == .Head else "rpop")
	if !source.exists { keyspace_notify(task, source, .Generic, "del") }
	keyspace_invalidate(task, source)
}

keyspace_list_mpop :: proc(task: ^Keyspace_Task) {
	plan, err := lt.parse_mpop_args(task.argv, 1)
	if err != .None { task.failed = true; return }
	for r in task.records {
		keyspace_expire(task, r)
		if r.exists && r.kind != u8(Obj_Type.List) { task.failed = true; return }
		keyspace_touch(task, r)
		if !r.exists { continue }
		work, ok := keyspace_list_work(task, r)
		if !ok { return }; defer keyspace_list_discard(&work)
		l := work.object
		count := min(plan.count, lt.length(l))
		b := keyspace_builder(task, l); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		keyspace_builder_integer(&b, 2, '*')
		keyspace_builder_bulk(&b, transmute([]u8)r.key)
		keyspace_builder_integer(&b, i64(count), '*')
		index := 0 if plan.where_ == .Head else -1
		direction := lt.Where.Tail if plan.where_ == .Head else lt.Where.Head
		it := lt.iterator(l, index, direction)
		entry: lt.List_Entry
		buf: [21]u8
		for _ in 0 ..< count {
			if !lt.iter_next(&it, &entry) { task.failed = true; return }
			keyspace_builder_bulk(&b, lt.value_bytes(lt.entry_value(&it, &entry), &buf))
		}
		if !keyspace_builder_finish(task, &b) { return }
		a, n := lt.pop_range_bounds(l, plan.where_, count)
		lt.delete_range(l, a, n)
		lt.try_conversion(l, .Shrinking)
		if !keyspace_list_commit(task, r, &work) { return }
		task.dirty = i64(count)
		keyspace_notify(task, r, .List, "lpop" if plan.where_ == .Head else "rpop")
		if !r.exists { keyspace_notify(task, r, .Generic, "del") }
		keyspace_invalidate(task, r); return
	}
	b := keyspace_builder(task, nil); defer ks.free(&keyspace_pool, b.bytes)
	if b.failed { return }
	keyspace_builder_text(&b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n")
	keyspace_builder_finish(task, &b)
}

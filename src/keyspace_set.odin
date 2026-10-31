package main

import ks "keyspace"
import st "settype"
import ht "hashtype"

keyspace_set_prefix :: proc "contextless" (task: ^Keyspace_Task) -> u8 {
	return '~' if task.client.resp == RESP3 else '*'
}

keyspace_set_reply_object :: proc(task: ^Keyspace_Task, object: st.Set, b: ^Keyspace_Builder) {
	keyspace_builder_integer(b, i64(st.size(object)), keyspace_set_prefix(task))
	it := st.iterator(object)
	buf: [21]u8
	for {
		value, ok := st.next(&it)
		if !ok { break }
		keyspace_builder_bulk(b, st.value_bytes(value, &buf))
	}
}

keyspace_set_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	argv := task.argv
	op := task.op
	if op == .Smove { keyspace_set_move(task); return }
	if op == .Sinter || op == .Sunion || op == .Sdiff || op == .Sinterstore || op == .Sunionstore || op == .Sdiffstore || op == .Sintercard { keyspace_set_algebra(task); return }
	requested: i64 = 1
	if op == .Spop || op == .Srandmember {
		if len(argv) > 3 { task.failed = true; return }
		if len(argv) == 3 {
			parsed: bool
			requested, parsed = parse_i64(argv[2])
			if !parsed || (op == .Spop && requested < 0) || requested == min(i64) { task.failed = true; return }
		}
	}
	cursor: u64
	if op == .Sscan {
		parsed: bool
		cursor, parsed = ht.parse_scan_cursor(argv[2])
		if !parsed { task.failed = true; return }
	}
	r := task.records[0]
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Set) { task.failed = true; return }
	s := cast(st.Set)r.object
	read := op != .Sadd && op != .Srem && op != .Spop
	if read { keyspace_read(task, r) } else { keyspace_touch(task, r) }
	if op == .Scard { task.integer = i64(st.size(s)); return }
	if op == .Sismember { task.integer = i64(s != nil && st.is_member(s, argv[2])); return }
	if op == .Smismember {
		b := keyspace_object_builder(task, .Set, s); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		keyspace_builder_integer(&b, i64(len(argv) - 2), '*')
		for member in argv[2:] { keyspace_builder_integer(&b, i64(s != nil && st.is_member(s, member))) }
		keyspace_builder_finish(task, &b); return
	}
	if op == .Smembers {
		b := keyspace_object_builder(task, .Set, s); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }; keyspace_set_reply_object(task, s, &b); keyspace_builder_finish(task, &b); return
	}
	if op == .Sscan {
		keyspace_set_scan(task, s, cursor); return
	}
	if op == .Srandmember {
		if s == nil && len(argv) == 2 { task.null = true; return }
		if len(argv) == 2 {
			value := st.random_element(s); buf: [21]u8
			task.results[0] = ks.value_new(&keyspace_pool, st.value_bytes(value, &buf))
			if task.results[0] == nil { task.failed = true; return }; task.bulk = true; return
		}
		n := min(requested, i64(st.size(s))) if requested >= 0 else (-requested if s != nil else 0)
		if n > i64(max(int) / (2 * size_of(st.Value) + 64)) { task.failed = true; return }
		charge := (int(n) + st.size(s)) * 2 * size_of(st.Value)
		if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
		values := make([dynamic]st.Value, 0, int(n)); defer delete(values)
		if n > 0 {
			if requested >= 0 { st.random_unique(s, int(n), &values) } else { st.random_with_repeats(s, int(n), &values) }
		}
		max_length := 0
		it := st.iterator(s)
		for { value, more := st.next(&it); if !more { break }; buf: [21]u8; max_length = max(max_length, len(st.value_bytes(value, &buf))) }
		extra := u128(n) * u128(max_length + 64)
		if extra > u128(max(int)) { task.failed = true; return }
		b := keyspace_object_builder(task, .Set, s, int(extra)); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		keyspace_builder_integer(&b, n, '*'); buf: [21]u8
		for value in values { keyspace_builder_bulk(&b, st.value_bytes(value, &buf)) }
		keyspace_builder_finish(task, &b); return
	}
	if op == .Srem && s == nil { return }
	if op == .Spop && s == nil && len(argv) == 2 { task.null = true; return }
	if op == .Spop && (s == nil || requested == 0) {
		b := keyspace_object_builder(task, .Set, nil); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }; keyspace_builder_integer(&b, 0, keyspace_set_prefix(task)); keyspace_builder_finish(task, &b); return
	}
	work, ok := keyspace_object_work(task, r, .Set)
	if !ok { return }; defer keyspace_object_discard(&work)
	candidate := cast(st.Set)work.object
	#partial switch op {
	case .Sadd:
		if !r.exists {
			st.destroy(candidate); candidate = st.create(argv[2], len(argv) - 2); work.object = candidate
		} else { st.maybe_convert(candidate, len(argv) - 2) }
		for member in argv[2:] { task.integer += i64(st.add(candidate, member)) }
		task.dirty = task.integer
	case .Srem:
		for member in argv[2:] { task.integer += i64(st.remove(candidate, member)) }
		task.dirty = task.integer
		if task.integer == 0 { return }
	case .Spop:
		count := min(int(requested), st.size(candidate))
		b := keyspace_object_builder(task, .Set, candidate); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		if len(argv) == 3 { keyspace_builder_integer(&b, i64(count), keyspace_set_prefix(task)) }
		popped: st.Popped
		defer st.popped_destroy(&popped)
		reservation := keyspace_object_memory(.Set, candidate) * 2 + count * 2 * size_of(st.Popped_Item) + 128
		if !ks.reserve_external(&keyspace_pool, reservation) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, reservation)
		buf: [21]u8
		if len(argv) == 3 && count == st.size(candidate) {
			inputs := []st.Set{candidate}
			reply_object := st.union_diff(inputs, .Union)
			defer st.destroy(reply_object)
			it := st.iterator(reply_object)
			for { value, more := st.next(&it); if !more { break }; keyspace_builder_bulk(&b, st.value_bytes(value, &buf)) }
			st.destroy(candidate); candidate = st.create_intset(); work.object = candidate
		} else if len(argv) == 3 {
			replacement := st.spop_count(candidate, count, &popped)
			if replacement != nil { st.destroy(candidate); candidate = replacement; work.object = candidate }
			for i in 0 ..< st.popped_len(&popped) { keyspace_builder_bulk(&b, st.value_bytes(st.popped_get(&popped, i), &buf)) }
		} else {
			st.pop_random(candidate, &popped); keyspace_builder_bulk(&b, st.value_bytes(st.popped_get(&popped, 0), &buf))
		}
		if !keyspace_builder_finish(task, &b) { return }
		task.dirty = i64(count)
	case:
		task.failed = true; return
	}
	if !keyspace_object_commit(task, r, &work) { task.dirty = 0; return }
	if task.dirty > 0 {
		event := "sadd" if op == .Sadd else ("srem" if op == .Srem else "spop")
		keyspace_changed(task, r, .Set, event, !r.exists)
	}
}

keyspace_set_scan :: proc(task: ^Keyspace_Task, s: st.Set, cursor: u64) {
	opts: ht.Scan_Options
	if s != nil {
		err: ht.Error
		opts, err = set_scan_options(task.argv[3:])
		if err != .None { task.failed = true; return }
	}
	charge := st.size(s) * 2 * size_of(st.Value) + len(task.argv) * size_of([]u8)
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
	values := make([dynamic]st.Value, 0, st.size(s)); defer delete(values)
	next: u64
	if s != nil { next = st.scan(s, cursor, opts.count, &values) }
	if opts.use_pattern {
		at := 0
		for value in values {
			buf: [21]u8
			if glob_match(opts.pattern, st.value_bytes(value, &buf), false) { values[at] = value; at += 1 }
		}
		resize(&values, at)
	}
	b := keyspace_object_builder(task, .Set, s); defer ks.free(&keyspace_pool, b.bytes)
	if b.failed { return }
	keyspace_builder_integer(&b, 2, '*')
	digits: [24]u8
	n := format_u64(raw_data(digits[:]), next)
	keyspace_builder_bulk(&b, digits[:n]); keyspace_builder_integer(&b, i64(len(values)), '*')
	buf: [21]u8
	for value in values { keyspace_builder_bulk(&b, st.value_bytes(value, &buf)) }
	keyspace_builder_finish(task, &b)
}

keyspace_set_move :: proc(task: ^Keyspace_Task) {
	source, destination := task.records[0], task.records[1]
	keyspace_expire(task, source)
	if source.exists && source.kind != u8(Obj_Type.Set) { task.failed = true; return }
	keyspace_touch(task, source)
	if !source.exists { return }
	keyspace_expire(task, destination)
	if destination.exists && destination.kind != u8(Obj_Type.Set) { task.failed = true; return }
	keyspace_touch(task, destination)
	member := task.argv[3]
	if !st.is_member(cast(st.Set)source.object, member) { return }
	task.integer = 1
	if source == destination { return }
	left, a := keyspace_object_work(task, source, .Set)
	if !a { return }; defer keyspace_object_discard(&left)
	right, b := keyspace_object_work(task, destination, .Set)
	if !b { return }; defer keyspace_object_discard(&right)
	st.remove(cast(st.Set)left.object, member)
	if !destination.exists { st.destroy(cast(st.Set)right.object); right.object = st.create(member, 1) }
	added := st.add(cast(st.Set)right.object, member)
	if !keyspace_object_prepare(task, &left) || !keyspace_object_prepare(task, &right) { return }
	if !keyspace_object_commit(task, source, &left) { return }
	keyspace_changed(task, source, .Set, "srem", !source.exists)
	if !keyspace_object_commit(task, destination, &right) { return }
	if added { keyspace_changed(task, destination, .Set, "sadd") }
	task.dirty = 1 + i64(added)
}

keyspace_set_algebra :: proc(task: ^Keyspace_Task) {
	op := task.op
	store := op == .Sinterstore || op == .Sunionstore || op == .Sdiffstore
	start := 1 if store else 0
	records := task.records[start:]
	limit := i64(0)
	if op == .Sintercard {
		argv := task.argv
		numkeys, parsed := parse_i64(argv[1])
		if !parsed || numkeys <= 0 || numkeys != i64(len(records)) { task.failed = true; return }
		for at := 2 + len(records); at < len(argv); at += 2 {
			if at + 1 >= len(argv) || !eq_nocase(argv[at], "limit") { task.failed = true; return }
			value, ok := parse_i64(argv[at + 1]); if !ok || value < 0 { task.failed = true; return }; limit = value
		}
	}
	reservation := u128(len(records)) * size_of(st.Set) + 8192
	for r in records {
		keyspace_expire(task, r)
		if r.exists && r.kind != u8(Obj_Type.Set) { task.failed = true; return }
		keyspace_read(task, r)
		reservation += u128(keyspace_object_memory(.Set, r.object)) * 4 + u128(keyspace_object_length(.Set, r.object)) * 256
	}
	if reservation > u128(max(int)) || !ks.reserve_external(&keyspace_pool, int(reservation)) { task.failed = true; return }
	defer ks.release_external(&keyspace_pool, int(reservation))
	sources := make([]st.Set, len(records)); defer delete(sources)
	for r, i in records { sources[i] = cast(st.Set)r.object }
	if op == .Sintercard { task.integer = i64(st.inter_card(sources, int(limit))); return }
	intersection := op == .Sinter || op == .Sinterstore
	if intersection && !store {
		values := make([dynamic]st.Value, 0, keyspace_object_length(.Set, records[0].object)); defer delete(values)
		st.inter_collect(sources, &values)
		b := keyspace_object_builder(task, .Set, records[0].object); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }
		keyspace_builder_integer(&b, i64(len(values)), keyspace_set_prefix(task)); buf: [21]u8
		for value in values { keyspace_builder_bulk(&b, st.value_bytes(value, &buf)) }
		keyspace_builder_finish(task, &b); return
	}
	result := st.inter_store(sources) if intersection else st.union_diff(sources, .Diff if op == .Sdiff || op == .Sdiffstore else .Union)
	defer st.destroy(result)
	if !store {
		b := keyspace_object_builder(task, .Set, result); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }; keyspace_set_reply_object(task, result, &b); keyspace_builder_finish(task, &b); return
	}
	destination := task.records[0]
	keyspace_expire(task, destination)
	count := st.size(result)
	actual := st.memory_usage(result)
	if !ks.reserve_external(&keyspace_pool, actual) { task.failed = true; return }
	work := Keyspace_Object_Work{kind = .Set, object = result, charge = actual}
	result = nil
	defer keyspace_object_discard(&work)
	existed := destination.exists
	if !keyspace_object_commit(task, destination, &work) { return }
	if destination.exists { destination.expire_at = 0 }
	task.integer = i64(count); task.dirty = i64(count != 0 || existed)
	if count != 0 { keyspace_changed(task, destination, .Set, task.command_name) } else if existed { keyspace_changed(task, destination, .Generic, "del") }
}

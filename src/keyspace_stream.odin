package main

import ks "keyspace"
import sm "streamtype"
import rx "rax"

keyspace_stream_admission :: proc(name: string, argv: [][]u8) -> bool {
	if name != "xread" && name != "xreadgroup" { return true }
	args, err := sm.parse_xread_args(argv, srv.now_ms, name == "xreadgroup")
	return err == .None && args.timeout == -1
}

keyspace_builder_prefix :: proc "contextless" (b: ^Keyspace_Builder, mark: int, prefix: u8, count: i64) {
	header: [32]u8
	header[0] = prefix
	n := format_i64(&header[1], count)
	header[n + 1], header[n + 2] = '\r', '\n'
	n += 3
	if mark < 0 || mark > b.used || n > len(b.bytes) - b.used { b.failed = true; return }
	for at := b.used; at > mark; at -= 1 { b.bytes[at - 1 + n] = b.bytes[at - 1] }
	copy(b.bytes[mark:mark + n], header[:n])
	b.used += n
}

keyspace_stream_id :: proc "contextless" (b: ^Keyspace_Builder, id: sm.ID) {
	buf: [sm.ID_TEXT_MAX]u8
	keyspace_builder_bulk(b, sm.format_id(&buf, id))
}

keyspace_stream_map :: proc "contextless" (task: ^Keyspace_Task, b: ^Keyspace_Builder, count: int) {
	keyspace_builder_integer(b, i64(count if task.client.resp == RESP3 else count * 2), '%' if task.client.resp == RESP3 else '*')
}

keyspace_stream_label :: proc "contextless" (b: ^Keyspace_Builder, name: string) { keyspace_builder_bulk(b, transmute([]u8)name) }

keyspace_stream_range :: proc(task: ^Keyspace_Task, b: ^Keyspace_Builder, s: sm.Stream, start, end: ^sm.ID, count: int, reverse, raw: bool, group: ^sm.CG = nil, consumer: ^sm.Consumer = nil, noack: bool = false) -> int {
	mark := b.used
	iterator: sm.Iterator
	sm.iterator_start(&iterator, s, start, end, reverse)
	defer sm.iterator_stop(&iterator)
	emitted := 0
	id: sm.ID
	fields: i64
	for (count <= 0 || emitted < count) && sm.iterator_get_id(&iterator, &id, &fields) {
		keyspace_builder_integer(b, 2, '*'); keyspace_stream_id(b, id); keyspace_builder_integer(b, fields * 2, '*')
		for _ in 0 ..< fields { field, value := sm.iterator_get_field(&iterator); keyspace_builder_bulk(b, field); keyspace_builder_bulk(b, value) }
		if group != nil { sm.group_deliver(s, group, consumer, id, noack, task.now) }
		emitted += 1
	}
	if !raw { keyspace_builder_prefix(b, mark, '*', i64(emitted)) }
	return emitted
}

keyspace_stream_builder :: proc(task: ^Keyspace_Task, s: sm.Stream) -> Keyspace_Builder {
	return keyspace_object_builder(task, .Stream, s, sm.memory_usage(s) * 4 + len(task.argv) * 128)
}

keyspace_stream_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	name := task.command_name
	argv := task.argv
	if name == "xread" || name == "xreadgroup" { keyspace_stream_read(task, name == "xreadgroup"); return }
	if name == "xgroup" { keyspace_stream_group(task); return }
	if name == "xpending" || name == "xack" || name == "xclaim" || name == "xautoclaim" { keyspace_stream_pending(task); return }
	index := 2 if name == "xinfo" else 1
	r := keyspace_task_record(task, argv[index])
	if r == nil { task.failed = true; return }
	add: sm.Xadd_Spec
	if name == "xadd" {
		spec, err := sm.parse_xadd(argv)
		if err != .None { task.failed = true; return }; add = spec
	} else if name == "xtrim" {
		limits, err := sm.parse_xtrim(argv)
		if err != .None { task.failed = true; return }; add.trim = limits
	}
	start, end: sm.ID
	count: i64
	if name == "xrange" || name == "xrevrange" {
		a, z, n, err := sm.parse_range_args(argv, name == "xrevrange")
		if err != .None { task.failed = true; return }; start = a; end = z; count = n
	}
	setid: sm.Setid_Args
	if name == "xsetid" { args, err := sm.parse_xsetid_args(argv); if err != .None { task.failed = true; return }; setid = args }
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Stream) { task.failed = true; return }
	s := cast(sm.Stream)r.object
	read := name == "xrange" || name == "xrevrange" || name == "xlen" || name == "xinfo"
	if read { keyspace_read(task, r) } else { keyspace_touch(task, r) }
	if name == "xlen" { task.integer = i64(sm.length(s)); return }
	b := keyspace_stream_builder(task, s); defer ks.free(&keyspace_pool, b.bytes)
	if b.failed { return }
	if name == "xrange" || name == "xrevrange" {
		if s == nil { keyspace_builder_integer(&b, 0, '*') } else if count == 0 { keyspace_builder_text(&b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n") } else {
			limit := 0 if count < 0 else int(min(count, i64(max(int))))
			keyspace_stream_range(task, &b, s, &start, &end, limit, name == "xrevrange", false)
		}
		keyspace_builder_finish(task, &b); return
	}
	if name == "xinfo" { if s == nil { task.failed = true; return }; keyspace_stream_info(task, s, &b); return }
	if s == nil && name != "xadd" {
		if name == "xsetid" { task.failed = true }; return
	}
	if s == nil && name == "xadd" && add.nomkstream { task.null = true; return }
	ids := make([dynamic]sm.ID, 0, max(0, len(argv) - 2)); defer delete(ids)
	charge := cap(ids) * size_of(sm.ID)
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
	if name == "xdel" {
		for arg in argv[2:] { id, ok := sm.parse_exact_id(arg); if !ok { task.failed = true; return }; append(&ids, id) }
	}
	work, ok := keyspace_object_work(task, r, .Stream)
	if !ok { return }; defer keyspace_object_discard(&work)
	candidate := cast(sm.Stream)work.object
	trimmed := i64(0)
	switch name {
	case "xadd":
		id, err := sm.xadd_apply(candidate, &add, argv[add.fields_at:], u64(task.now))
		if err != .None { task.failed = true; return }
		keyspace_stream_id(&b, id)
		if add.trim.rule != .Off { trimmed = sm.trim(candidate, &add.trim) }
		if !keyspace_builder_finish(task, &b) { return }; task.dirty = 1
	case "xdel":
		task.integer = i64(sm.xdel_apply(candidate, ids[:])); task.dirty = task.integer
		if task.dirty == 0 { return }
	case "xtrim":
		task.integer = sm.trim(candidate, &add.trim); task.dirty = task.integer
		if task.dirty == 0 { return }
	case "xsetid":
		if err := sm.xsetid_apply(candidate, &setid); err != .None { task.failed = true; return }; task.ok = true; task.dirty = 1
	case: task.failed = true; return
	}
	if !keyspace_object_commit(task, r, &work, true) { task.dirty = 0; return }
	keyspace_changed(task, r, .Stream, name)
	if trimmed > 0 { keyspace_notify(task, r, .Stream, "xtrim") }
	if name == "xadd" { keyspace_wake(task, r, .Stream) }
}

keyspace_stream_group :: proc(task: ^Keyspace_Task) {
	argv := task.argv
	sub := argv[1]
	create, setid := eq_nocase(sub, "create"), eq_nocase(sub, "setid")
	destroy := eq_nocase(sub, "destroy")
	makeconsumer, delconsumer := eq_nocase(sub, "createconsumer"), eq_nocase(sub, "delconsumer")
	if !(create || setid || destroy || makeconsumer || delconsumer) || (create && (len(argv) < 5 || len(argv) > sm.XGROUP_CREATE_MAX_ARGS)) || (setid && len(argv) < 5) || (destroy && len(argv) != 4) || ((makeconsumer || delconsumer) && len(argv) != 5) { task.failed = true; return }
	mkstream := false
	entries: i64 = sm.SCG_INVALID_ENTRIES_READ
	if create || setid {
		m, e, err := sm.parse_xgroup_opts(argv); if err != .None { task.failed = true; return }; mkstream = m; entries = e
	}
	r := keyspace_task_record(task, argv[2])
	if r == nil { task.failed = true; return }
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Stream) { task.failed = true; return }
	keyspace_touch(task, r)
	id: sm.ID
	dollar := false
	if create || setid {
		dollar = sm.is_byte(argv[4], '$')
		if !dollar {
			parsed := false
			if setid { id, parsed = sm.parse_id_or_sentinel(argv[4], 0) } else { id, parsed = sm.parse_exact_id(argv[4]) }
			if !parsed { task.failed = true; return }
		}
	}
	if !r.exists && !(create && mkstream) { task.failed = true; return }
	work, ok := keyspace_object_work(task, r, .Stream)
	if !ok { return }; defer keyspace_object_discard(&work)
	s := cast(sm.Stream)work.object
	if dollar { id = s.last_id }
	group := argv[3]
	switch {
	case create:
		if sm.create_cg(s, group, id, entries) == nil { task.failed = true; return }; task.ok = true; task.dirty = 1
	case setid:
		cg := sm.lookup_cg(s, group); if cg == nil { task.failed = true; return }
		sm.group_set_id(cg, id, entries); task.ok = true; task.dirty = 1
	case destroy:
		if !sm.destroy_cg(s, group) { return }; task.integer = 1; task.dirty = 1
	case makeconsumer:
		cg := sm.lookup_cg(s, group); if cg == nil { task.failed = true; return }
		_, created := sm.lookup_or_create_consumer(s, cg, argv[4], task.now)
		if !created { return }; task.integer = 1; task.dirty = 1
	case delconsumer:
		cg := sm.lookup_cg(s, group); if cg == nil { task.failed = true; return }
		consumer := sm.lookup_consumer(cg, argv[4]); if consumer == nil { return }
		task.integer = i64(sm.del_consumer(s, cg, consumer)); task.dirty = 1
	}
	if !keyspace_object_commit(task, r, &work, true) { task.dirty = 0; return }
	event := "xgroup-create" if create else ("xgroup-setid" if setid else ("xgroup-destroy" if destroy else ("xgroup-createconsumer" if makeconsumer else "xgroup-delconsumer")))
	if makeconsumer { keyspace_notify(task, r, .Stream, event); keyspace_invalidate(task, r) } else { keyspace_changed(task, r, .Stream, event) }
	if setid || destroy { keyspace_wake(task, r, .Stream) }
}

keyspace_stream_read :: proc(task: ^Keyspace_Task, grouped: bool) {
	argv := task.argv
	args, err := sm.parse_xread_args(argv, task.now, grouped)
	if err != .None || args.timeout != -1 { task.failed = true; return }
	n := args.key_count
	charge := n * (size_of(sm.ID) + size_of(^ks.Record) + size_of(sm.Stream) + size_of(Keyspace_Object_Work) + 4 * size_of(int) + size_of(bool))
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
	ids := make([]sm.ID, n); defer delete(ids)
	records := make([]^ks.Record, n); defer delete(records)
	streams := make([]sm.Stream, n); defer delete(streams)
	history := make([]bool, n); defer delete(history)
	mapping := make([]int, n); defer delete(mapping)
	works := make([]Keyspace_Object_Work, n)
	defer { for &work in works { keyspace_object_discard(&work) }; delete(works) }
	budget := u128(1024)
	for i in 0 ..< n {
		key := argv[args.keys_at + i]
		r := keyspace_task_record(task, key)
		if r == nil { task.failed = true; return }
		records[i] = r
		keyspace_expire(task, r)
		if r.exists && r.kind != u8(Obj_Type.Stream) { task.failed = true; return }
		keyspace_read(task, r)
		s := cast(sm.Stream)r.object
		streams[i] = s
		arg := argv[args.keys_at + n + i]
		if grouped {
			if sm.lookup_cg(s, argv[args.group_arg]) == nil || sm.is_byte(arg, '$') || sm.is_byte(arg, '+') { task.failed = true; return }
			if !sm.is_byte(arg, '>') { id, ok := sm.parse_exact_id(arg); if !ok { task.failed = true; return }; ids[i] = id; history[i] = true }
		} else {
			switch {
			case sm.is_byte(arg, '$'): if s != nil { ids[i] = s.last_id }
			case sm.is_byte(arg, '+'): if s != nil && s.length > 0 { ids[i] = sm.last_valid_id(s); sm.decr_id(&ids[i]) }
			case sm.is_byte(arg, '>'): task.failed = true; return
			case: id, ok := sm.parse_exact_id(arg); if !ok { task.failed = true; return }; ids[i] = id
			}
		}
		budget += u128(sm.memory_usage(s)) * 6 + u128(sm.length(s)) * 128 + u128(len(key)) + 128
	}
	if budget > u128(max(int)) { task.failed = true; return }
	b := Keyspace_Builder{bytes = ks.allocate(&keyspace_pool, int(budget))}
	defer ks.free(&keyspace_pool, b.bytes)
	if len(b.bytes) == 0 { task.failed = true; return }
	unique := 0
	changes := 0
	if grouped {
		for i in 0 ..< n {
			previous := -1
			for j in 0 ..< i { if records[j] == records[i] { previous = mapping[j]; break } }
			if previous < 0 {
				work, ok := keyspace_object_work(task, records[i], .Stream)
				if !ok { return }; works[unique] = work; previous = unique; unique += 1
			}
			mapping[i] = previous; streams[i] = cast(sm.Stream)works[previous].object
		}
		for s, i in streams {
			cg := sm.lookup_cg(s, argv[args.group_arg])
			consumer, created := sm.lookup_or_create_consumer(s, cg, argv[args.group_arg + 1], task.now)
			changes += int(created); consumer.seen_time = task.now
			if created { keyspace_notify(task, records[i], .Stream, "xgroup-createconsumer"); keyspace_invalidate(task, records[i]) }
		}
	}
	served := 0
	for s, i in streams {
		if !grouped {
			keyspace_read(task, records[i])
			if s == nil || s.length == 0 || sm.compare_id(sm.last_valid_id(s), ids[i]) <= 0 { continue }
		} else {
			cg := sm.lookup_cg(s, argv[args.group_arg])
			if !history[i] && (s.length == 0 || sm.compare_id(sm.last_valid_id(s), cg.last_id) <= 0) { continue }
		}
		if task.client.resp != RESP3 { keyspace_builder_integer(&b, 2, '*') }
		keyspace_builder_bulk(&b, argv[args.keys_at + i])
		if grouped {
			cg := sm.lookup_cg(s, argv[args.group_arg]); consumer := sm.lookup_consumer(cg, argv[args.group_arg + 1])
			if history[i] { keyspace_stream_history(task, &b, s, consumer, ids[i], int(args.count)) } else {
				start := cg.last_id; sm.incr_id(&start)
				keyspace_stream_range(task, &b, s, &start, nil, int(args.count), false, false, cg, consumer, args.noack)
				changes += 1
				keyspace_invalidate(task, records[i])
			}
		} else { start := ids[i]; sm.incr_id(&start); keyspace_stream_range(task, &b, s, &start, nil, int(args.count), false, false) }
		served += 1
	}
	if served == 0 { keyspace_builder_text(&b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n") } else { keyspace_builder_prefix(&b, 0, '%' if task.client.resp == RESP3 else '*', i64(served)) }
	if !keyspace_builder_finish(task, &b) { return }
	if grouped {
		for &work in works[:unique] { if !keyspace_object_prepare(task, &work) { return } }
		for i in 0 ..< n {
			first := true
			for j in 0 ..< i { if records[j] == records[i] { first = false; break } }
			if first && !keyspace_object_commit(task, records[i], &works[mapping[i]], true) { return }
		}
		task.dirty = i64(changes)
	}
}

keyspace_stream_history :: proc(task: ^Keyspace_Task, b: ^Keyspace_Builder, s: sm.Stream, consumer: ^sm.Consumer, after: sm.ID, count: int) {
	mark := b.used
	emitted := 0
	from := after
	if sm.incr_id(&from) {
		start: [16]u8; sm.encode_id(&start, from)
		it: rx.Iterator
		rx.start(&it, consumer.pel); rx.seek(&it, ">=", start[:])
		for (count <= 0 || emitted < count) && rx.next(&it) {
			id := sm.decode_id(rx.key(&it))
			if keyspace_stream_range(task, b, s, &id, &id, 1, false, true) == 0 {
				keyspace_builder_integer(b, 2, '*'); keyspace_stream_id(b, id); keyspace_builder_text(b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n")
			} else { sm.pel_touch(consumer, id, task.now) }
			emitted += 1
		}
		rx.stop(&it)
	}
	keyspace_builder_prefix(b, mark, '*', i64(emitted))
}

keyspace_stream_claimed :: proc(task: ^Keyspace_Task, b: ^Keyspace_Builder, s: sm.Stream, id: sm.ID, justid: bool) {
	if justid { keyspace_stream_id(b, id); return }
	at := id
	if keyspace_stream_range(task, b, s, &at, &at, 1, false, true) == 0 {
		keyspace_builder_integer(b, 2, '*'); keyspace_stream_id(b, id); keyspace_builder_text(b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n")
	}
}

keyspace_stream_pending :: proc(task: ^Keyspace_Task) {
	argv := task.argv
	name := task.command_name
	ids := make([dynamic]sm.ID, 0, len(argv)); defer delete(ids)
	charge := len(argv) * 2 * size_of(sm.ID)
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
	pending: sm.Xpending_Args
	claim: sm.Claim_Args
	auto: sm.Autoclaim_Args
	if name == "xpending" { args, err := sm.parse_xpending_args(argv); if err != .None { task.failed = true; return }; pending = args }
	if name == "xclaim" { args, _, err := sm.parse_xclaim_args(argv, task.now, &ids); if err != .None { task.failed = true; return }; claim = args }
	if name == "xautoclaim" { args, err := sm.parse_xautoclaim_args(argv); if err != .None { task.failed = true; return }; auto = args }
	r := task.records[0]
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Stream) { task.failed = true; return }
	keyspace_read(task, r)
	s := cast(sm.Stream)r.object
	cg := sm.lookup_cg(s, argv[2])
	if cg == nil { if name != "xack" { task.failed = true }; return }
	b := keyspace_stream_builder(task, s); defer ks.free(&keyspace_pool, b.bytes)
	if b.failed { return }
	if name == "xpending" { keyspace_stream_pending_reply(task, &b, cg, &pending); keyspace_builder_finish(task, &b); return }
	if name == "xack" { for arg in argv[3:] { id, ok := sm.parse_exact_id(arg); if !ok { task.failed = true; return }; append(&ids, id) } }
	work, ok := keyspace_object_work(task, r, .Stream)
	if !ok { return }; defer keyspace_object_discard(&work)
	candidate := cast(sm.Stream)work.object
	group := sm.lookup_cg(candidate, argv[2])
	changes := 0
	if name == "xack" {
		for id in ids { task.integer += i64(sm.ack(candidate, group, id)) }
		if task.integer == 0 { return }; changes = int(task.integer)
	} else {
		consumer, created := sm.lookup_or_create_consumer(candidate, group, argv[3], task.now)
		changes += int(created); consumer.seen_time = task.now
		if created { keyspace_notify(task, r, .Stream, "xgroup-createconsumer") }
		if name == "xclaim" {
			raised := sm.group_raise_last_id(group, claim.last_id)
			claimed, deleted := 0, 0
			for id in ids {
				switch sm.claim_entry(candidate, group, consumer, id, &claim, task.now) {
				case .Claimed: keyspace_stream_claimed(task, &b, candidate, id, claim.justid); claimed += 1
				case .Deleted: deleted += 1
				case .Skipped:
				}
			}
			keyspace_builder_prefix(&b, 0, '*', i64(claimed))
			changes += claimed + deleted + int(raised && claimed == 0)
		} else {
			reservation := int(group.pel.numele) * 2 * size_of(sm.Autoclaim_Step)
			if !ks.reserve_external(&keyspace_pool, reservation) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, reservation)
			steps := make([dynamic]sm.Autoclaim_Step, 0, int(group.pel.numele)); defer delete(steps)
			next := sm.autoclaim_scan(candidate, group, consumer, &auto, task.now, &steps)
			keyspace_builder_integer(&b, 3, '*'); keyspace_stream_id(&b, next)
			mark := b.used; claimed := 0
			for step in steps { if step.result == .Claimed { keyspace_stream_claimed(task, &b, candidate, step.id, auto.justid); claimed += 1 } }
			keyspace_builder_prefix(&b, mark, '*', i64(claimed))
			keyspace_builder_integer(&b, i64(len(steps) - claimed), '*')
			for step in steps { if step.result == .Deleted { keyspace_stream_id(&b, step.id) } }
			changes += len(steps)
		}
		if !keyspace_builder_finish(task, &b) { return }
	}
	if !keyspace_object_commit(task, r, &work, true) { return }; task.dirty = i64(changes)
	if changes > 0 { keyspace_invalidate(task, r) }
}

keyspace_stream_pending_reply :: proc(task: ^Keyspace_Task, b: ^Keyspace_Builder, cg: ^sm.CG, args: ^sm.Xpending_Args) {
	if args.justinfo {
		keyspace_builder_integer(b, 4, '*'); keyspace_builder_integer(b, i64(cg.pel.numele))
		first, last, any := sm.pel_first_last(cg.pel)
		if !any {
			keyspace_hash_null(task, b); keyspace_hash_null(task, b); keyspace_builder_text(b, "_\r\n" if task.client.resp == RESP3 else "*-1\r\n"); return
		}
		keyspace_stream_id(b, first); keyspace_stream_id(b, last)
		mark := b.used; listed := 0
		it: rx.Iterator; rx.start(&it, cg.consumers); rx.seek(&it, "^")
		for rx.next(&it) {
			consumer := cast(^sm.Consumer)it.data
			if consumer.pel.numele == 0 { continue }
			keyspace_builder_integer(b, 2, '*'); keyspace_builder_bulk(b, consumer.name)
			digits: [24]u8; n := format_u64(raw_data(digits[:]), consumer.pel.numele); keyspace_builder_bulk(b, digits[:n]); listed += 1
		}
		rx.stop(&it); keyspace_builder_prefix(b, mark, '*', i64(listed)); return
	}
	if args.count <= 0 { keyspace_builder_integer(b, 0, '*'); return }
	source := cg.pel
	if args.consumer_idx > 0 {
		consumer := sm.lookup_consumer(cg, task.argv[args.consumer_idx])
		if consumer == nil { keyspace_builder_integer(b, 0, '*'); return }; source = consumer.pel
	}
	mark := b.used
	emitted: i64
	if sm.compare_id(args.start, args.end) <= 0 {
		start: [16]u8; sm.encode_id(&start, args.start)
		it: rx.Iterator; rx.start(&it, source); rx.seek(&it, ">=", start[:])
		for emitted < args.count && rx.next(&it) {
			id := sm.decode_id(rx.key(&it)); if sm.compare_id(id, args.end) > 0 { break }
			nack := cast(^sm.NACK)it.data; idle := task.now - nack.delivery_time
			if args.minidle > 0 && idle < args.minidle { continue }
			keyspace_builder_integer(b, 4, '*'); keyspace_stream_id(b, id); keyspace_builder_bulk(b, nack.consumer.name)
			keyspace_builder_integer(b, idle); keyspace_builder_integer(b, i64(nack.delivery_count)); emitted += 1
		}
		rx.stop(&it)
	}
	keyspace_builder_prefix(b, mark, '*', emitted)
}

keyspace_stream_entries_read :: proc "contextless" (task: ^Keyspace_Task, b: ^Keyspace_Builder, cg: ^sm.CG) {
	if cg.entries_read == sm.SCG_INVALID_ENTRIES_READ { keyspace_hash_null(task, b) } else { keyspace_builder_integer(b, cg.entries_read) }
}

keyspace_stream_lag :: proc "contextless" (task: ^Keyspace_Task, b: ^Keyspace_Builder, s: sm.Stream, cg: ^sm.CG) {
	lag, ok := sm.cg_lag(s, cg)
	if ok { keyspace_builder_integer(b, lag) } else { keyspace_hash_null(task, b) }
}

keyspace_stream_info :: proc(task: ^Keyspace_Task, s: sm.Stream, b: ^Keyspace_Builder) {
	argv := task.argv
	sub := argv[1]
	if eq_nocase(sub, "groups") {
		if len(argv) != 3 { task.failed = true; return }
		keyspace_stream_info_groups(task, b, s, false, 0); keyspace_builder_finish(task, b); return
	}
	if eq_nocase(sub, "consumers") {
		if len(argv) != 4 { task.failed = true; return }
		cg := sm.lookup_cg(s, argv[3]); if cg == nil { task.failed = true; return }
		keyspace_builder_integer(b, i64(cg.consumers.numele), '*')
		it: rx.Iterator; rx.start(&it, cg.consumers); rx.seek(&it, "^")
		for rx.next(&it) {
			consumer := cast(^sm.Consumer)it.data
			keyspace_stream_map(task, b, 4)
			keyspace_stream_label(b, "name"); keyspace_builder_bulk(b, consumer.name)
			keyspace_stream_label(b, "pending"); keyspace_builder_integer(b, i64(consumer.pel.numele))
			keyspace_stream_label(b, "idle"); keyspace_builder_integer(b, task.now - consumer.seen_time)
			keyspace_stream_label(b, "inactive"); keyspace_builder_integer(b, -1 if consumer.active_time == -1 else task.now - consumer.active_time)
		}
		rx.stop(&it); keyspace_builder_finish(task, b); return
	}
	if !eq_nocase(sub, "stream") { task.failed = true; return }
	full, count, err := sm.parse_xinfo_stream_opts(argv[3:])
	if err != .None { task.failed = true; return }
	keyspace_stream_map(task, b, 9 if full else 10)
	keyspace_stream_label(b, "length"); keyspace_builder_integer(b, i64(s.length))
	keyspace_stream_label(b, "radix-tree-keys"); keyspace_builder_integer(b, i64(sm.node_count(s)))
	keyspace_stream_label(b, "radix-tree-nodes"); keyspace_builder_integer(b, i64(sm.rax_nodes(s)))
	keyspace_stream_label(b, "last-generated-id"); keyspace_stream_id(b, s.last_id)
	keyspace_stream_label(b, "max-deleted-entry-id"); keyspace_stream_id(b, s.max_deleted_entry_id)
	keyspace_stream_label(b, "entries-added"); keyspace_builder_integer(b, i64(s.entries_added))
	keyspace_stream_label(b, "recorded-first-entry-id"); keyspace_stream_id(b, s.first_id)
	if full {
		keyspace_stream_label(b, "entries")
		limit := 0 if count <= 0 else int(min(count, i64(max(int))))
		keyspace_stream_range(task, b, s, nil, nil, limit, false, false)
		keyspace_stream_label(b, "groups"); keyspace_stream_info_groups(task, b, s, true, count)
	} else {
		keyspace_stream_label(b, "groups"); keyspace_builder_integer(b, i64(sm.group_count(s)))
		keyspace_stream_label(b, "first-entry")
		if s.length == 0 || keyspace_stream_range(task, b, s, nil, nil, 1, false, true) == 0 { keyspace_hash_null(task, b) }
		keyspace_stream_label(b, "last-entry")
		if s.length == 0 || keyspace_stream_range(task, b, s, nil, nil, 1, true, true) == 0 { keyspace_hash_null(task, b) }
	}
	keyspace_builder_finish(task, b)
}

keyspace_stream_pel_limit :: proc "contextless" (pel: ^rx.Rax, count: i64) -> int {
	return int(count) if count > 0 && u64(count) < pel.numele else int(pel.numele)
}

keyspace_stream_info_groups :: proc(task: ^Keyspace_Task, b: ^Keyspace_Builder, s: sm.Stream, full: bool, count: i64) {
	keyspace_builder_integer(b, i64(sm.group_count(s)), '*')
	if s.cgroups == nil { return }
	groups: rx.Iterator; rx.start(&groups, s.cgroups); rx.seek(&groups, "^")
	for rx.next(&groups) {
		cg := cast(^sm.CG)groups.data
		keyspace_stream_map(task, b, 7 if full else 6)
		keyspace_stream_label(b, "name"); keyspace_builder_bulk(b, rx.key(&groups))
		if !full {
			keyspace_stream_label(b, "consumers"); keyspace_builder_integer(b, i64(cg.consumers.numele))
			keyspace_stream_label(b, "pending"); keyspace_builder_integer(b, i64(cg.pel.numele))
		}
		keyspace_stream_label(b, "last-delivered-id"); keyspace_stream_id(b, cg.last_id)
		keyspace_stream_label(b, "entries-read"); keyspace_stream_entries_read(task, b, cg)
		keyspace_stream_label(b, "lag"); keyspace_stream_lag(task, b, s, cg)
		if !full { continue }
		keyspace_stream_label(b, "pel-count"); keyspace_builder_integer(b, i64(cg.pel.numele))
		keyspace_stream_label(b, "pending")
		limit := keyspace_stream_pel_limit(cg.pel, count)
		keyspace_builder_integer(b, i64(limit), '*')
		pending: rx.Iterator; rx.start(&pending, cg.pel); rx.seek(&pending, "^")
		for n := 0; n < limit && rx.next(&pending); n += 1 {
			nack := cast(^sm.NACK)pending.data
			keyspace_builder_integer(b, 4, '*'); keyspace_stream_id(b, sm.decode_id(rx.key(&pending)))
			keyspace_builder_bulk(b, nack.consumer.name); keyspace_builder_integer(b, nack.delivery_time); keyspace_builder_integer(b, i64(nack.delivery_count))
		}
		rx.stop(&pending)
		keyspace_stream_label(b, "consumers"); keyspace_builder_integer(b, i64(cg.consumers.numele), '*')
		consumers: rx.Iterator; rx.start(&consumers, cg.consumers); rx.seek(&consumers, "^")
		for rx.next(&consumers) {
			consumer := cast(^sm.Consumer)consumers.data
			keyspace_stream_map(task, b, 5)
			keyspace_stream_label(b, "name"); keyspace_builder_bulk(b, consumer.name)
			keyspace_stream_label(b, "seen-time"); keyspace_builder_integer(b, consumer.seen_time)
			keyspace_stream_label(b, "active-time"); keyspace_builder_integer(b, consumer.active_time)
			keyspace_stream_label(b, "pel-count"); keyspace_builder_integer(b, i64(consumer.pel.numele))
			keyspace_stream_label(b, "pending")
			n := keyspace_stream_pel_limit(consumer.pel, count); keyspace_builder_integer(b, i64(n), '*')
			entries: rx.Iterator; rx.start(&entries, consumer.pel); rx.seek(&entries, "^")
			for i := 0; i < n && rx.next(&entries); i += 1 {
				nack := cast(^sm.NACK)entries.data
				keyspace_builder_integer(b, 3, '*'); keyspace_stream_id(b, sm.decode_id(rx.key(&entries)))
				keyspace_builder_integer(b, nack.delivery_time); keyspace_builder_integer(b, i64(nack.delivery_count))
			}
			rx.stop(&entries)
		}
		rx.stop(&consumers)
	}
	rx.stop(&groups)
}

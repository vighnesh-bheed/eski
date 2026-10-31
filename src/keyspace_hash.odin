package main

import ks "keyspace"
import ht "hashtype"
import ld "ldfloat"

keyspace_hash_reply_value :: proc "contextless" (b: ^Keyspace_Builder, value: ht.Value) {
	buf: [21]u8
	keyspace_builder_bulk(b, ht.value_bytes(value, &buf))
}

keyspace_hash_null :: proc "contextless" (task: ^Keyspace_Task, b: ^Keyspace_Builder) {
	keyspace_builder_text(b, "_\r\n" if task.client.resp == RESP3 else "$-1\r\n")
}

keyspace_hash_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	argv := task.argv
	op := task.op
	if (op == .Hset || op == .Hmset) && (len(argv) < 4 || len(argv) % 2 != 0) { task.failed = true; return }
	if op == .Hincrby { _, err := ht.parse_incrby_increment(argv[3]); if err != .None { task.failed = true; return } }
	if op == .Hincrbyfloat { _, err := ht.parse_incrbyfloat_increment(argv[3]); if err != .None { task.failed = true; return } }
	rand_args: ht.Hrandfield_Args
	if op == .Hrandfield {
		parsed, err := ht.parse_hrandfield_args(argv[2:]); if err != .None { task.failed = true; return }; rand_args = parsed
	}
	cursor: u64
	if op == .Hscan { parsed: bool; cursor, parsed = ht.parse_scan_cursor(argv[2]); if !parsed { task.failed = true; return } }
	r := task.records[0]
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.Hash) { task.failed = true; return }
	write := op == .Hset || op == .Hmset || op == .Hsetnx || op == .Hdel || op == .Hincrby || op == .Hincrbyfloat || op >= .Hexpire
	if write { keyspace_touch(task, r) } else { keyspace_read(task, r) }
	if op == .Httl || op == .Hpttl || op == .Hexpiretime || op == .Hpexpiretime { keyspace_read(task, r) }
	create := op == .Hset || op == .Hmset || op == .Hsetnx || op == .Hincrby || op == .Hincrbyfloat
	if !r.exists && !create { keyspace_hash_missing(task); return }
	work, ok := keyspace_object_work(task, r, .Hash)
	if !ok { return }; defer keyspace_object_discard(&work)
	h := cast(ht.Hash)work.object
	registry: ht.Registry
	defer ht.registry_destroy(&registry)
	defer { if work.object != nil { keyspace_hash_detach(cast(ht.Hash)work.object) } }
	trace := keyspace_hash_trace_begin(task, h, &registry)
	if task.capture_poststate { registry.owner = &trace }
	defer keyspace_hash_trace_finish(task, &trace)
	if task.failed { return }
	minimum := keyspace_hash_binding_minimum(h, work.hash_minimum)
	if minimum != ht.EB_EXPIRE_TIME_INVALID { ht.registry_add(&registry, h, minimum) }
	changed := false
	reset_ttl := false
	b := keyspace_object_builder(task, .Hash, h, len(argv) * 64)
	defer ks.free(&keyspace_pool, b.bytes)
	if b.failed { return }
	now := u64(task.now)
	#partial switch op {
	case .Hset, .Hmset:
		task.integer = i64(ht.hset(h, argv[2:])); task.ok = op == .Hmset
		task.dirty = i64((len(argv) - 2) / 2); changed = true
	case .Hsetnx:
		_, result := ht.get(h, argv[2], now)
		if result == .Ok { return }
		if result == .Expired || result == .Expired_Hash { task.subexpired += 1; changed = true }
		if result == .Expired_Hash { ht.reset(h); reset_ttl = true }
		ht.set(h, argv[2], argv[3]); task.integer = 1; task.dirty = 1; changed = true
	case .Hget, .Hexists, .Hstrlen:
		value, result := ht.get(h, argv[2], now)
		if result == .Expired || result == .Expired_Hash { task.subexpired += 1; changed = true }
		if op == .Hget {
			if result == .Ok { keyspace_hash_reply_value(&b, value) } else { keyspace_hash_null(task, &b) }
			if !keyspace_builder_finish(task, &b) { return }
		} else if result == .Ok { task.integer = 1 if op == .Hexists else i64(ht.value_len(value)) }
	case .Hmget:
		keyspace_builder_integer(&b, i64(len(argv) - 2), '*')
		empty := false
		for field in argv[2:] {
			if empty { keyspace_hash_null(task, &b); continue }
			value, result := ht.get(h, field, now)
			if result == .Ok { keyspace_hash_reply_value(&b, value) } else { keyspace_hash_null(task, &b) }
			if result == .Expired || result == .Expired_Hash { task.subexpired += 1; changed = true }
			empty = result == .Expired_Hash
		}
		if !keyspace_builder_finish(task, &b) { return }
	case .Hgetall, .Hkeys, .Hvals:
		n := ht.length_live(h, now)
		both := op == .Hgetall
		width := 2 if both else 1
		prefix := u8('*')
		if both && task.client.resp == RESP3 { prefix = '%'; width = 1 }
		keyspace_builder_integer(&b, i64(n * width), prefix)
		it := ht.iterator_live(h, now)
		for ht.next(&it) {
			if op != .Hvals { keyspace_hash_reply_value(&b, ht.current_field(&it)) }
			if op != .Hkeys { keyspace_hash_reply_value(&b, ht.current_value(&it)) }
		}
		if !keyspace_builder_finish(task, &b) { return }
	case .Hlen:
		task.integer = i64(ht.length(h))
	case .Hdel:
		n, _ := ht.hdel(h, argv[2:]); task.integer = i64(n); task.dirty = i64(n); changed = n > 0
	case .Hincrby, .Hincrbyfloat:
		_, result := ht.get(h, argv[2], now)
		if result == .Expired || result == .Expired_Hash { task.subexpired += 1; changed = true }
		if result == .Expired_Hash { ht.reset(h); reset_ttl = true }
		if op == .Hincrby {
			delta, _ := ht.parse_incrby_increment(argv[3])
			value, err := ht.incrby(h, argv[2], delta, now)
			if err != .None { task.failed = true; return }; task.integer = value
		} else {
			delta, _ := ht.parse_incrbyfloat_increment(argv[3])
			buf: [ld.MAX_LONG_DOUBLE_CHARS]u8
			value, err := ht.incrbyfloat(h, argv[2], delta, buf[:], now)
			if err != .None { task.failed = true; return }
			_, expires, found := ht.get_raw(h, argv[2])
			task.hash_expire_at = 0
			if found && expires != ht.EB_EXPIRE_TIME_INVALID { task.hash_expire_at = i64(expires) }
			keyspace_builder_bulk(&b, value); if !keyspace_builder_finish(task, &b) { return }
		}
		task.dirty = 1; changed = true
	case .Hrandfield:
		before := ht.length(h)
		ht.expire_if_needed(h, now)
		removed := before - ht.length(h)
		if removed != 0 { task.subexpired += i64(removed); changed = true }
		if !keyspace_hash_random(task, h, rand_args, &b) { return }
	case .Hscan:
		opts, err := ht.parse_scan_options(argv[3:], true)
		if err != .None { task.failed = true; return }
		charge := ht.length(h) * 4 * size_of(ht.Value)
		if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }; defer ks.release_external(&keyspace_pool, charge)
		values := make([dynamic]ht.Value, 0, ht.length(h) * 2); defer delete(values)
		next := ht.scan(h, cursor, opts, &values, now)
		keyspace_builder_integer(&b, 2, '*')
		digits: [24]u8
		n := format_u64(raw_data(digits[:]), next)
		keyspace_builder_bulk(&b, digits[:n]); keyspace_builder_integer(&b, i64(len(values)), '*')
		for value in values { keyspace_hash_reply_value(&b, value) }
		if !keyspace_builder_finish(task, &b) { return }
	case .Hexpire, .Hpexpire, .Hexpireat, .Hpexpireat, .Httl, .Hpttl, .Hexpiretime, .Hpexpiretime, .Hpersist:
		valid, modified := keyspace_hash_expiry(task, h, &registry, &b)
		if !valid { return }; changed = modified
	}
	work.hash_minimum = keyspace_hash_registered_minimum(h)
	keyspace_hash_detach(h)
	keyspace_hash_trace_unbind(&trace)
	ht.registry_destroy(&registry)
	if changed {
		if !keyspace_object_commit(task, r, &work) { task.dirty = 0; return }
		if reset_ttl && r.exists { r.expire_at = 0 }
		if task.subexpired > 0 && op < .Hexpire {
			keyspace_notify(task, r, .Hash, "hexpired")
			if !r.exists || reset_ttl { keyspace_notify(task, r, .Generic, "del") }
			keyspace_invalidate(task, r, false, repeat = int(task.subexpired))
		}
		if reset_ttl && r.exists { keyspace_notify(task, r, .New, "new") }
		if task.dirty > 0 {
			#partial switch op {
			case .Hset, .Hmset, .Hsetnx: keyspace_changed(task, r, .Hash, "hset")
			case .Hincrby: keyspace_changed(task, r, .Hash, "hincrby")
			case .Hincrbyfloat: keyspace_changed(task, r, .Hash, "hincrbyfloat")
			case .Hdel: keyspace_changed(task, r, .Hash, "hdel", !r.exists)
			case .Hpersist: keyspace_changed(task, r, .Hash, "hpersist")
			case .Hexpire, .Hpexpire, .Hexpireat, .Hpexpireat:
				keyspace_invalidate(task, r)
				if task.subexpired > 0 { keyspace_notify(task, r, .Hash, "hdel") }
				if task.dirty > task.subexpired { keyspace_notify(task, r, .Hash, "hexpire") }
				if !r.exists { keyspace_notify(task, r, .Generic, "del") }
			}
		}
	}
}

keyspace_hash_missing :: proc(task: ^Keyspace_Task) {
	op := task.op
	argv := task.argv
	#partial switch op {
	case .Hget: task.null = true
	case .Hexists, .Hstrlen, .Hlen, .Hdel:
	case .Hmget:
		b := keyspace_object_builder(task, .Hash, nil, len(argv) * 16); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }; keyspace_builder_integer(&b, i64(len(argv) - 2), '*')
		for _ in argv[2:] { keyspace_hash_null(task, &b) }; keyspace_builder_finish(task, &b)
	case .Hgetall, .Hkeys, .Hvals, .Hrandfield:
		if op == .Hrandfield {
			args, err := ht.parse_hrandfield_args(argv[2:]); if err != .None { task.failed = true; return }
			if !args.has_count { task.null = true; return }
		}
		b := keyspace_object_builder(task, .Hash, nil); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }; keyspace_builder_integer(&b, 0, '%' if op == .Hgetall && task.client.resp == RESP3 else '*'); keyspace_builder_finish(task, &b)
	case .Hscan:
		b := keyspace_object_builder(task, .Hash, nil); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }; keyspace_builder_text(&b, "*2\r\n$1\r\n0\r\n*0\r\n"); keyspace_builder_finish(task, &b)
	case .Hexpire, .Hpexpire, .Hexpireat, .Hpexpireat, .Httl, .Hpttl, .Hexpiretime, .Hpexpiretime, .Hpersist:
		fields: [][]u8
		if op == .Hexpire || op == .Hpexpire || op == .Hexpireat || op == .Hpexpireat {
			base := u64(task.now) if op == .Hexpire || op == .Hpexpire else 0
			args, err := ht.parse_expire_args(argv, op == .Hexpire || op == .Hexpireat, base)
			if err != .None { task.failed = true; return }; fields = args.fields
		} else {
			parsed, err := ht.parse_fields_args(argv); if err != .None { task.failed = true; return }; fields = parsed
		}
		b := keyspace_object_builder(task, .Hash, nil, len(fields) * 16); defer ks.free(&keyspace_pool, b.bytes)
		if b.failed { return }; keyspace_builder_integer(&b, i64(len(fields)), '*')
		for _ in fields { keyspace_builder_integer(&b, -2) }; keyspace_builder_finish(task, &b)
	case: task.failed = true
	}
}

keyspace_hash_expiry :: proc(task: ^Keyspace_Task, h: ht.Hash, registry: ^ht.Registry, b: ^Keyspace_Builder) -> (bool, bool) {
	op := task.op
	argv := task.argv
	fields: [][]u8
	args: ht.Expire_Args
	if op == .Hexpire || op == .Hpexpire || op == .Hexpireat || op == .Hpexpireat {
		base := u64(task.now) if op == .Hexpire || op == .Hpexpire else 0
		parsed, err := ht.parse_expire_args(argv, op == .Hexpire || op == .Hexpireat, base)
		if err != .None { task.failed = true; return false, false }; args = parsed; fields = args.fields; task.hash_expire_at = i64(args.expire_at)
	} else {
		parsed, err := ht.parse_fields_args(argv)
		if err != .None { task.failed = true; return false, false }; fields = parsed
	}
	charge := len(fields) * 2 * size_of(i64) + ht.memory_usage(h)
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return false, false }; defer ks.release_external(&keyspace_pool, charge)
	values := make([dynamic]i64, 0, len(fields)); defer delete(values)
	changed := false
	if op == .Hpersist {
		changed = ht.persist_fields(h, fields, u64(task.now), &values)
		task.dirty = i64(changed)
	} else if op >= .Httl && op <= .Hpexpiretime {
		kind := ht.Ttl_Kind.Ttl
		if op == .Hpttl { kind = .Pttl }; if op == .Hexpiretime { kind = .Expire_Time }; if op == .Hpexpiretime { kind = .Pexpire_Time }
		ht.ttl_fields(h, fields, kind, u64(task.now), &values)
	} else {
		ht.expire_fields(registry, nil, h, fields, args.expire_at, args.cond, u64(task.now), &values)
		for value in values {
			if value == ht.HSETEX_DELETED { task.subexpired += 1 }
			if value == ht.HSETEX_DELETED || value == ht.HSETEX_OK { changed = true; task.dirty += 1 }
		}
	}
	keyspace_builder_integer(b, i64(len(values)), '*')
	for value in values { keyspace_builder_integer(b, value) }
	return keyspace_builder_finish(task, b), changed
}

keyspace_hash_random :: proc(task: ^Keyspace_Task, h: ht.Hash, args: ht.Hrandfield_Args, b: ^Keyspace_Builder) -> bool {
	if ht.length(h) == 0 {
		if !args.has_count { task.null = true; return true }
		keyspace_builder_integer(b, 0, '*'); return keyspace_builder_finish(task, b)
	}
	if !args.has_count {
		field, _ := ht.random_element(h); keyspace_hash_reply_value(b, field); return keyspace_builder_finish(task, b)
	}
	n := min(args.count, i64(ht.length(h))) if args.count >= 0 else -args.count
	size := u128(n + i64(ht.length(h))) * (4 * size_of(ht.Value) + 128) + u128(n) * u128(ht.memory_usage(h))
	if size > u128(max(int)) || !ks.reserve_external(&keyspace_pool, int(size)) { task.failed = true; return false }
	defer ks.release_external(&keyspace_pool, int(size))
	fields := make([dynamic]ht.Value, 0, int(n)); defer delete(fields)
	values := make([dynamic]ht.Value, 0, int(n)); defer delete(values)
	if args.count >= 0 { ht.random_unique(h, int(n), args.with_values, &fields, &values) } else { ht.random_with_repeats(h, int(n), args.with_values, &fields, &values) }
	width := 2 if args.with_values && task.client.resp != RESP3 else 1
	keyspace_builder_integer(b, n * i64(width), '*')
	for field, i in fields {
		if args.with_values && task.client.resp == RESP3 { keyspace_builder_integer(b, 2, '*') }
		keyspace_hash_reply_value(b, field)
		if args.with_values { keyspace_hash_reply_value(b, values[i]) }
	}
	return keyspace_builder_finish(task, b)
}

keyspace_hash_detach :: proc "contextless" (h: ht.Hash) {
	ht.registry_remove(h)
	if h.hfe != nil {
		h.hfe.reg = nil
		h.hfe.reg_index = -1
		h.hfe.reg_expire = ht.EB_EXPIRE_TIME_INVALID
	}
}

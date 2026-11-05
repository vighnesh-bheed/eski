package main

import ks "keyspace"
import bm "bitmap"

keyspace_bitmap_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	argv := task.argv
	r := task.records[0]
	op := task.op
	if op == .Bitop { keyspace_bitmap_bitop(task); return }
	offset: u64
	on: bool
	count_args: bm.Bitcount_Args
	position_args: bm.Bitpos_Args
	program: bm.Bitfield_Program
	defer bm.bitfield_program_destroy(&program)
	parse_charge := (len(argv) + 1) * 4 * (size_of(bm.Field_Command) + size_of(bm.Bitfield_Reply))
	if !ks.reserve_external(&keyspace_pool, parse_charge) { task.failed = true; return }
	defer ks.release_external(&keyspace_pool, parse_charge)
	err: bm.Error
	#partial switch op {
	case .Setbit, .Getbit:
		offset, err = bm.parse_bit_offset(argv[2], false, 0, task.limit)
		if err == .None && op == .Setbit { on, err = bm.parse_bit_value(argv[3]) }
	case .Bitcount:
		count_args, err = bm.parse_bitcount_args(argv[2:])
	case .Bitpos:
		position_args, err = bm.parse_bitpos_args(argv[2:])
	case .Bitfield, .Bitfield_ro:
		err = bm.bitfield_parse(&program, argv[2:], op == .Bitfield_ro, task.limit)
	}
	if err != .None { task.failed = true; return }
	keyspace_expire(task, r)
	if r.exists && r.kind != u8(Obj_Type.String) { task.failed = true; return }
	bytes := ks.value_data(r.value)
	readonly := op != .Setbit && (op != .Bitfield || program.readonly)
	if readonly { keyspace_read(task, r) } else { keyspace_touch(task, r) }
	#partial switch op {
	case .Getbit: task.integer = i64(bm.getbit(bytes, i64(offset))); return
	case .Bitcount: task.integer = bm.bitcount_args(bytes, count_args); return
	case .Bitpos: task.integer = bm.bitpos_args(bytes, r.exists, position_args); return
	}
	if op == .Setbit {
		buffer, allocation := keyspace_bitmap_copy(task, bytes)
		if !allocation { return }
		capacity := len(buffer)
		defer bm.free_bytes(&buffer, keyspace_worker_allocator(), &capacity)
		old, failure := bm.setbit(&buffer, i64(offset), on, keyspace_worker_allocator(), &capacity, task.limit)
		if failure != .None { task.failed = true; return }
		if !keyspace_value(task, buffer) { return }
		changed := !r.exists || len(buffer) > len(bytes) || old != on
		keyspace_save(task, r, task.values[0], r.expire_at)
		r.encoding = u8(Obj_Encoding.Raw)
		task.integer = i64(old)
		if changed { task.dirty = 1; keyspace_changed(task, r, .String, "setbit") }; return
	}
	buffer := bytes
	capacity := 0
	if !program.readonly {
		valid: bool
		buffer, valid = keyspace_bitmap_copy(task, bytes)
		if !valid { return }
		capacity = len(buffer)
	}
	defer { if !program.readonly { bm.free_bytes(&buffer, keyspace_worker_allocator(), &capacity) } }
	changes, failure := bm.bitfield_execute(&buffer, &program, keyspace_worker_allocator(), &capacity)
	if failure != .None { task.failed = true; return }
	b := keyspace_builder(task, nil)
	defer ks.free(&keyspace_pool, b.bytes)
	needed := len(program.replies) * 32 + 32
	if needed > len(b.bytes) {
		ks.free(&keyspace_pool, b.bytes)
		b.bytes = ks.allocate(&keyspace_pool, needed); b.used = 0
		if len(b.bytes) == 0 { task.failed = true; return }
	}
	keyspace_builder_integer(&b, i64(len(program.replies)), '*')
	for reply in program.replies {
		if reply.null { keyspace_builder_text(&b, "_\r\n" if task.client.resp == RESP3 else "$-1\r\n") } else { keyspace_builder_integer(&b, reply.value) }
	}
	if !keyspace_builder_finish(task, &b) { return }
	if !program.readonly {
		if !keyspace_value(task, buffer) { return }
		keyspace_save(task, r, task.values[0], r.expire_at)
		r.encoding = u8(Obj_Encoding.Raw)
		task.dirty = i64(changes)
		if changes > 0 { keyspace_changed(task, r, .String, "setbit") }
	}
}

keyspace_bitmap_copy :: proc "contextless" (task: ^Keyspace_Task, bytes: []u8) -> ([]u8, bool) {
	if len(bytes) == 0 { return nil, true }
	buffer := ks.allocate(&keyspace_pool, len(bytes))
	if len(buffer) == 0 { task.failed = true; return nil, false }
	copy(buffer, bytes)
	return buffer, true
}

keyspace_bitmap_bitop :: proc(task: ^Keyspace_Task) {
	argv := task.argv
	op, err := bm.parse_bitop(argv[1])
	if err != .None || bm.check_bitop_arity(op, len(task.records) - 1) != .None { task.failed = true; return }
	charge := (len(task.records) - 1) * size_of([]u8)
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }
	defer ks.release_external(&keyspace_pool, charge)
	sources := make([][]u8, len(task.records) - 1)
	defer delete(sources)
	for r, i in task.records[1:] {
		keyspace_expire(task, r)
		if r.exists && r.kind != u8(Obj_Type.String) { task.failed = true; return }
		keyspace_read(task, r)
		sources[i] = ks.value_data(r.value)
	}
	buffer: []u8
	length, failure := bm.bitop(op, sources, &buffer, keyspace_worker_allocator())
	defer bm.free_bytes(&buffer, keyspace_worker_allocator())
	if failure != .None { task.failed = true; return }
	r := task.records[0]
	keyspace_expire(task, r)
	if length == 0 {
		if r.exists { keyspace_remove(r); task.dirty = 1; keyspace_changed(task, r, .Generic, "del") }; return
	}
	if !keyspace_value(task, buffer) { return }
	keyspace_save(task, r, task.values[0], 0)
	r.encoding = u8(Obj_Encoding.Raw)
	task.integer = i64(length); task.dirty = 1
	keyspace_changed(task, r, .String, "set")
}

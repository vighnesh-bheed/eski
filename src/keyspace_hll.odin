package main

import ks "keyspace"
import "hll"

keyspace_hll_valid :: proc "contextless" (r: ^ks.Record) -> bool {
	return !r.exists || (r.kind == u8(Obj_Type.String) && hll.hll_is_valid(ks.value_data(r.value)))
}

keyspace_hll_store :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record, bytes: []u8) -> bool {
	if !keyspace_value(task, bytes) { return false }
	keyspace_save(task, r, task.values[0], r.expire_at)
	r.encoding = u8(Obj_Encoding.Raw)
	return true
}

keyspace_hll_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	r := task.records[0]
	argv := task.argv
	scratch := make([dynamic]u8, 0, 0, keyspace_worker_allocator())
	defer delete(scratch)
	regs: [hll.HLL_REGISTERS]u8
	if task.op == .Pfcount && len(task.records) > 1 || task.op == .Pfmerge {
		dense := false
		for record in task.records {
			keyspace_expire(task, record)
			if !keyspace_hll_valid(record) { task.failed = true; return }
			keyspace_read(task, record)
			if !record.exists { continue }
			bytes := ks.value_data(record.value)
			if bytes[4] == hll.HLL_DENSE { dense = true }
			if hll.hll_merge_into(&regs, bytes) != .None { task.failed = true; return }
		}
		if task.op == .Pfcount { task.integer = i64(hll.hll_estimate_raw(&regs)); return }
		bytes := ks.value_data(r.value)
		mutable := ks.value_new(&keyspace_pool, bytes)
		if mutable == nil { task.failed = true; return }
		defer ks.value_release(mutable)
		in_scratch, err := hll.pfmerge_apply(ks.value_data(mutable), r.exists, &regs, dense, &scratch, hll_sparse_max_bytes)
		if err != .None { task.failed = true; return }
		result := scratch[:] if in_scratch else ks.value_data(mutable)
		if !keyspace_hll_store(task, r, result) { return }
		task.dirty = 1; task.ok = true; keyspace_changed(task, r, .String, "pfadd"); return
	}
	keyspace_expire(task, r)
	if !keyspace_hll_valid(r) { task.failed = true; return }
	bytes := ks.value_data(r.value)
	if task.op == .Pfcount {
		keyspace_read(task, r)
		if !r.exists { return }
		if hll.hll_cache_valid(bytes) { task.integer = i64(hll.hll_cached_card(bytes)); return }
		mutable := ks.value_new(&keyspace_pool, bytes)
		if mutable == nil { task.failed = true; return }; defer ks.value_release(mutable)
		invalid := false
		task.integer = i64(hll.hll_count(ks.value_data(mutable), &invalid))
		if invalid { task.failed = true; return }
		keyspace_save(task, r, mutable, r.expire_at)
		r.encoding = u8(Obj_Encoding.Raw)
		task.dirty = 1; return
	}
	keyspace_touch(task, r)
	if task.op == .Pfadd {
		created := !r.exists
		source := hll.HLL_EMPTY_SPARSE[:] if created else bytes
		mutable := ks.value_new(&keyspace_pool, source)
		if mutable == nil { task.failed = true; return }; defer ks.value_release(mutable)
		changed, in_scratch, err := hll.pfadd_apply(ks.value_data(mutable), argv[2:], &scratch, hll_sparse_max_bytes)
		if err != .None { task.failed = true; return }
		if !created && !changed { return }
		result := scratch[:] if in_scratch && changed else ks.value_data(mutable)
		if !keyspace_hll_store(task, r, result) { return }
		task.dirty = i64(created) + i64(changed); task.integer = 1; keyspace_changed(task, r, .String, "pfadd"); return
	}
	if !r.exists { task.failed = true; return }
	sub := argv[1]
	switch {
	case eq_nocase(sub, "encoding"):
		task.status = hll.hll_encoding_name(bytes)
	case eq_nocase(sub, "decode"):
		if bytes[4] != hll.HLL_SPARSE { task.failed = true; return }
		if reserve(&scratch, len(bytes) * 12 + 128) != nil { task.failed = true; return }
		hll.sparse_debug_append(bytes, &scratch)
		task.results[0] = ks.value_new(&keyspace_pool, scratch[:])
		if task.results[0] == nil { task.failed = true; return }
		task.bulk = true
	case eq_nocase(sub, "todense"), eq_nocase(sub, "getreg"):
		converted, err := hll.to_dense_apply(bytes, &scratch)
		if err != .None { task.failed = true; return }
		result := scratch[:] if converted else bytes
		if eq_nocase(sub, "getreg") {
			if hll.hll_get_registers(result, &regs) != .None { task.failed = true; return }
			b := Keyspace_Builder{bytes = ks.allocate(&keyspace_pool, hll.HLL_REGISTERS * 8 + 32)}
			defer ks.free(&keyspace_pool, b.bytes)
			if len(b.bytes) == 0 { task.failed = true; return }
			keyspace_builder_integer(&b, hll.HLL_REGISTERS, '*')
			for value in regs { keyspace_builder_integer(&b, i64(value)) }
			if !keyspace_builder_finish(task, &b) { return }
		} else { task.integer = i64(converted) }
		if converted {
			if !keyspace_hll_store(task, r, result) { return }
			task.dirty = 1
			keyspace_invalidate(task, r)
		}
	case:
		task.failed = true
	}
}

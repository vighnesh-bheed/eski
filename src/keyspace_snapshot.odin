package main

import ks "keyspace"

Keyspace_Undo :: struct {
	record: ^ks.Record,
	before: ks.Record,
	charge: int,
}

keyspace_capture_execute :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	charge := len(task.records) * size_of(Keyspace_Undo)
	if !ks.reserve_external(&keyspace_pool, charge) { task.failed = true; return }
	defer ks.release_external(&keyspace_pool, charge)
	undo := make([]Keyspace_Undo, len(task.records))
	defer delete(undo)
	count := 0
	defer {
		for &item in undo[:count] {
			ks.value_release(item.before.value)
			if item.before.object != nil { item.before.object_destroy(item.before.object) }
			ks.release_external(&keyspace_pool, item.charge)
		}
	}
	for r in task.records {
		duplicate := false
		for item in undo[:count] { if item.record == r { duplicate = true; break } }
		if duplicate { continue }
		item := &undo[count]
		item.record = r; item.before = r^
		item.before.value = ks.value_retain(r.value)
		item.before.object = nil
		count += 1
		if r.object != nil {
			reservation := u128(keyspace_object_memory(Obj_Type(r.kind), r.object)) * 4 + u128(keyspace_object_length(Obj_Type(r.kind), r.object)) * 128 + 8192
			if reservation > u128(max(int)) { task.failed = true; return }
			bytes := int(reservation)
			if !ks.reserve_external(&keyspace_pool, bytes) { task.failed = true; return }
			item.charge = bytes
			item.before.object = keyspace_object_duplicate(Obj_Type(r.kind), r.object)
			actual := keyspace_object_memory(Obj_Type(r.kind), item.before.object)
			if actual > bytes && !ks.reserve_external(&keyspace_pool, actual - bytes) { task.failed = true; return }
			if actual < bytes { ks.release_external(&keyspace_pool, bytes - actual) }
			item.charge = actual; item.before.object_charge = actual
		}
	}
	keyspace_execute_kernel(job)
	if !task.failed {
		for &item in undo[:count] {
			r := item.record
			if task.dirty == 0 && task.subexpired == 0 { continue }
			index := len(task.poststates)
			if index >= len(task.poststate_storage) { store_fatal("keyspace poststate capacity invariant") }
			payload: ^ks.Value
			if r.exists { payload = keyspace_record_payload(task, r); if task.failed { break } }
			task.poststates = task.poststate_storage[:index + 1]
			task.poststates[index] = Keyspace_Poststate{db = r.db, key = keyspace_effect_key(task, r), exists = r.exists, kind = Obj_Type(r.kind), expires = r.expire_at, clock = r.clock, payload = payload}
		}
	}
	if !task.failed { return }
	for &item in undo[:count] {
		r := item.record
		before := &item.before
		ks.value_release(r.value); ks.record_object_clear(r)
		r.value = before.value; before.value = nil
		r.object = before.object; before.object = nil
		r.object_charge = before.object_charge; item.charge = 0
		r.object_destroy = before.object_destroy
		r.exists = before.exists; r.clock = before.clock; r.changed = before.changed
		r.value_changed = before.value_changed; r.string_copy = before.string_copy
		r.expire_at = before.expire_at; r.encoding = before.encoding; r.kind = before.kind; r.touched = before.touched
		r.hash_minimum = before.hash_minimum
	}
	for state in task.poststates { ks.value_release(state.payload) }
	ks.value_release(task.hash_expired); task.hash_expired = nil
	task.hash_expired_count = 0; task.hash_aof_ready = false
	task.poststates = task.poststate_storage[:0]; task.events = task.event_storage[:0]
	task.dirty = 0; task.hits = 0; task.misses = 0; task.expired = 0; task.subexpired = 0; task.sanitized = 0
	task.rolled_back = true
}

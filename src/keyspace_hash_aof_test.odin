package main

import "core:testing"
import ht "hashtype"
import ks "keyspace"

@(test)
private_hash_expiry_trace_owns_field_bytes_and_detaches_context :: proc(t: ^testing.T) {
	encodings := [2]bool{false, true}
	for dictionary in encodings {
		h := ht.create()
		defer ht.destroy(h)
		first := transmute([]u8)string("first")
		second := transmute([]u8)string("second")
		ht.set(h, first, transmute([]u8)string("one"))
		ht.set(h, second, transmute([]u8)string("two"))
		if dictionary { ht.convert(h) }
		registry: ht.Registry
		defer ht.registry_destroy(&registry)
		values: [dynamic]i64
		defer delete(values)
		ht.expire_fields(&registry, nil, h, [][]u8{first, second}, 100, .None, 1, &values)
		bytes: [256]u8
		trace := Keyspace_Hash_Trace{builder = {bytes = bytes[:]}, registry = &registry}
		registry.owner = &trace
		registry.expired_hook = keyspace_hash_trace_expired
		_, result := ht.get(h, first, 101)
		testing.expect_value(t, result, ht.Get_Result.Expired)
		ht.expire_if_needed(h, 101)
		testing.expect_value(t, trace.count, 2)
		testing.expect_value(t, string(trace.builder.bytes[:trace.builder.used]), "$5\r\nfirst\r\n$6\r\nsecond\r\n")
		testing.expect(t, ht.key_ref(h) == nil)
		keyspace_hash_detach(h)
		keyspace_hash_trace_unbind(&trace)
		ht.registry_destroy(&registry)
		testing.expect(t, h.hfe.reg == nil && !ht.is_registered(h))
		testing.expect(t, registry.items == nil && registry.len == 0 && registry.expired_hook == nil && registry.owner == nil)
		ht.set(h, first, transmute([]u8)string("later"))
		testing.expect_value(t, trace.count, 2)
	}
}

@(test)
private_hash_expiry_trace_overflow_is_explicit :: proc(t: ^testing.T) {
	h := ht.create()
	defer ht.destroy(h)
	field := transmute([]u8)string("field")
	ht.set(h, field, transmute([]u8)string("value"))
	registry: ht.Registry
	defer ht.registry_destroy(&registry)
	values: [dynamic]i64
	defer delete(values)
	ht.expire_fields(&registry, nil, h, [][]u8{field}, 100, .None, 1, &values)
	bytes: [1]u8
	trace := Keyspace_Hash_Trace{builder = {bytes = bytes[:]}, registry = &registry}
	registry.owner = &trace
	registry.expired_hook = keyspace_hash_trace_expired
	ht.get(h, field, 101)
	testing.expect(t, trace.builder.failed)
	testing.expect_value(t, trace.count, 1)
	keyspace_hash_detach(h)
	ht.registry_destroy(&registry)
}

@(test)
private_hash_expiry_trace_value_capacity_failure_is_retryable :: proc(t: ^testing.T) {
	testing.expect(t, !keyspace_initialized && !keyspace_pool.initialized)
	if keyspace_initialized || keyspace_pool.initialized { return }
	saved := keyspace_pool
	defer keyspace_pool = saved
	testing.expect(t, ks.init(&keyspace_pool, 1, 4096))
	trace := Keyspace_Hash_Trace{builder = {bytes = ks.allocate(&keyspace_pool, 128)}, count = 1}
	testing.expect_value(t, len(trace.builder.bytes), 128)
	keyspace_builder_bulk(&trace.builder, transmute([]u8)string("expired"))
	remaining := 4096 - ks.memory_used(&keyspace_pool)
	testing.expect(t, ks.reserve_external(&keyspace_pool, remaining))
	task := Keyspace_Task{capture_poststate = true}
	keyspace_hash_trace_finish(&task, &trace)
	testing.expect(t, task.failed && !task.hash_aof_ready && task.hash_expired == nil)
	ks.release_external(&keyspace_pool, remaining)
	testing.expect_value(t, ks.memory_used(&keyspace_pool), 0)
	testing.expect(t, ks.destroy(&keyspace_pool))
}

package main

import ks "keyspace"
import ht "hashtype"

Keyspace_Hash_Trace :: struct {
	builder: Keyspace_Builder,
	registry: ^ht.Registry,
	count: int,
}

keyspace_hash_trace_begin :: proc(task: ^Keyspace_Task, h: ht.Hash, registry: ^ht.Registry) -> Keyspace_Hash_Trace {
	trace: Keyspace_Hash_Trace
	if !task.capture_poststate { return trace }
	trace.registry = registry
	trace.builder = keyspace_object_builder(task, .Hash, h)
	registry.expired_hook = keyspace_hash_trace_expired
	return trace
}

keyspace_hash_trace_expired :: proc(h: ht.Hash, field: []u8) {
	if h.hfe == nil || h.hfe.reg == nil || h.hfe.reg.owner == nil { store_fatal("private hash expiry trace ownership invariant") }
	trace := cast(^Keyspace_Hash_Trace)h.hfe.reg.owner
	keyspace_builder_bulk(&trace.builder, field)
	trace.count += 1
}

keyspace_hash_trace_unbind :: proc(trace: ^Keyspace_Hash_Trace) {
	if trace.registry != nil {
		trace.registry.expired_hook = nil
		trace.registry.owner = nil
	}
}

keyspace_hash_trace_finish :: proc(task: ^Keyspace_Task, trace: ^Keyspace_Hash_Trace) {
	keyspace_hash_trace_unbind(trace)
	defer { ks.free(&keyspace_pool, trace.builder.bytes); trace.builder.bytes = nil }
	if !task.capture_poststate || task.failed { return }
	if trace.builder.failed { task.failed = true; return }
	if trace.count > 0 {
		task.hash_expired = ks.value_new(&keyspace_pool, trace.builder.bytes[:trace.builder.used])
		if task.hash_expired == nil { task.failed = true; return }
		task.hash_expired_count = trace.count
	}
	task.hash_aof_ready = true
}

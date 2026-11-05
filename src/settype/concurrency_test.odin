package settype

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "core:thread"
import "core:testing"

Retirement_Producer :: struct { gate: ^u32 }

produce_retirement_and_random :: proc(data: rawptr) {
	state := cast(^Retirement_Producer)data
	for intrinsics.atomic_load_explicit(state.gate, .Acquire) == 0 { linux.sched_yield() }
	for _ in 0 ..< 32 {
		r := cast(^Resize_State)runtime.heap_alloc(size_of(Resize_State), true)
		r.old_cap = 1024
		r.old_slots = slots_alloc(r.old_cap)
		resize_retire(r)
		rand64()
		maintenance_release(budget = 4096, call_budget = 1)
	}
}

@(test)
independent_owners_retire_mappings_and_advance_shared_random_without_lost_updates :: proc(t: ^testing.T) {
	for intrinsics.atomic_load_explicit(&resize_retired_count, .Acquire) > 0 { maintenance_release() }
	before_mapped, before_retired, before_metadata := maintenance_memory()
	initial := intrinsics.atomic_load_explicit(&set_random_state, .Relaxed)
	gate: u32
	states: [4]Retirement_Producer
	workers: [4]^thread.Thread
	for &state, i in states {
		state.gate = &gate
		workers[i] = thread.create_and_start_with_data(&state, produce_retirement_and_random)
		testing.expect(t, workers[i] != nil)
	}
	intrinsics.atomic_store_explicit(&gate, 1, .Release)
	for worker in workers { thread.join(worker); thread.destroy(worker) }
	for intrinsics.atomic_load_explicit(&resize_retired_count, .Acquire) > 0 { maintenance_release() }
	after_mapped, after_retired, after_metadata := maintenance_memory()
	testing.expect_value(t, after_mapped, before_mapped)
	testing.expect_value(t, after_retired, before_retired)
	testing.expect_value(t, after_metadata, before_metadata)
	x := initial
	for _ in 0 ..< 128 {
		x += 0x9E3779B97F4A7C15
	}
	testing.expect_value(t, intrinsics.atomic_load_explicit(&set_random_state, .Relaxed), x)
}

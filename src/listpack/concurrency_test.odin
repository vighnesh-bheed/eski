package listpack

import "base:intrinsics"
import "core:sys/linux"
import "core:thread"
import "core:testing"

Random_Producer :: struct { gate: ^u32 }

produce_random :: proc(data: rawptr) {
	state := cast(^Random_Producer)data
	for intrinsics.atomic_load_explicit(state.gate, .Acquire) == 0 { linux.sched_yield() }
	for _ in 0 ..< 1024 { lp_rand() }
}

@(test)
concurrent_random_draws_preserve_all_state_transitions :: proc(t: ^testing.T) {
	initial := intrinsics.atomic_load_explicit(&random_state, .Relaxed)
	gate: u32
	states: [4]Random_Producer
	workers: [4]^thread.Thread
	for &state, i in states {
		state.gate = &gate
		workers[i] = thread.create_and_start_with_data(&state, produce_random)
		testing.expect(t, workers[i] != nil)
	}
	intrinsics.atomic_store_explicit(&gate, 1, .Release)
	for worker in workers { thread.join(worker); thread.destroy(worker) }
	x := initial
	for _ in 0 ..< 4096 {
		x ~= x >> 12
		x ~= x << 25
		x ~= x >> 27
	}
	testing.expect_value(t, intrinsics.atomic_load_explicit(&random_state, .Relaxed), x)
}

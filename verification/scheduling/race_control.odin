package main

import "base:intrinsics"
import "core:thread"
import "core:sys/linux"

gate: u32
shared: int

racer :: proc(data: rawptr) {
	for intrinsics.atomic_load_explicit(&gate, .Acquire) == 0 { linux.sched_yield() }
	for _ in 0 ..< 1000 { shared += 1 }
}

main :: proc() {
	a := thread.create_and_start_with_data(nil, racer)
	b := thread.create_and_start_with_data(nil, racer)
	assert(a != nil && b != nil)
	intrinsics.atomic_store_explicit(&gate, 1, .Release)
	thread.join(a); thread.join(b)
	thread.destroy(a); thread.destroy(b)
}

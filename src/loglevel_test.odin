package main

import "base:intrinsics"
import "core:sys/linux"
import "core:testing"
import "core:thread"

Loglevel_Test_State :: struct {
	stop: u32,
	visible: u32,
	suppressed: u32,
}

loglevel_test_reader :: proc(t: ^thread.Thread) {
	state := (^Loglevel_Test_State)(t.data)
	for intrinsics.atomic_load_explicit(&state.stop, .Acquire) == 0 {
		line: Log_Line
		ll_begin(&line, LOG_NOTICE)
		if line.skip {
			intrinsics.atomic_add_explicit(&state.suppressed, 1, .Release)
		} else {
			intrinsics.atomic_add_explicit(&state.visible, 1, .Release)
		}
	}
}

loglevel_test_set :: proc(cf: ^Config, value: string) -> bool {
	args := [][]u8{transmute([]u8)value}
	_, err := config_set(cf, args)
	return err == ""
}

loglevel_test_observed :: proc(counter: ^u32) -> bool {
	deadline := now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(counter, .Acquire) == 0 {
		if now_ns() >= deadline { return false }
		linux.sched_yield()
	}
	return true
}

@(test)
loglevel_generic_config_store_orders_concurrent_logger_filtering :: proc(t: ^testing.T) {
	saved := intrinsics.atomic_load_explicit(&cfg.loglevel, .Relaxed)
	cf := Config{type = .Enum, enums = enum_loglevel, store = &cfg.loglevel}
	defer testing.expect(t, loglevel_test_set(&cf, enum_loglevel[saved].name))
	testing.expect(t, loglevel_test_set(&cf, "debug"))
	state: Loglevel_Test_State
	worker := thread.create(loglevel_test_reader)
	if !testing.expect(t, worker != nil) { return }
	worker.data = &state
	thread.start(worker)
	defer {
		intrinsics.atomic_store_explicit(&state.stop, 1, .Release)
		thread.join(worker)
		thread.destroy(worker)
	}
	testing.expect(t, loglevel_test_observed(&state.visible))
	for i in 0..<10_000 {
		testing.expect(t, loglevel_test_set(&cf, "nothing" if i % 2 == 0 else "debug"))
	}
	testing.expect(t, loglevel_test_set(&cf, "nothing"))
	testing.expect(t, loglevel_test_observed(&state.suppressed))
	testing.expect(t, loglevel_test_set(&cf, "notice"))
	testing.expect_value(t, config_num_value(&cf), i64(2))
}

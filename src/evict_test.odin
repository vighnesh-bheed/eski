package main

import "core:testing"

@(test)
evict_request_bytes_count_every_argument_and_its_length :: proc(t: ^testing.T) {
	name := "set"
	key := "key"
	value := "a value of 21 bytes.."
	argv := [][]u8{transmute([]u8)name, transmute([]u8)key, transmute([]u8)value}
	testing.expect_value(t, request_bytes(argv), 27 + 3 * REQUEST_ARGUMENT_BYTES)
	testing.expect_value(t, request_bytes(argv[:1]), 3 + REQUEST_ARGUMENT_BYTES)
	testing.expect_value(t, request_bytes(nil), 0)
	many := make([][]u8, 1500)
	defer delete(many)
	for &a in many {
		a = transmute([]u8)key
	}
	testing.expect_value(t, request_bytes(many), 1500 * (3 + REQUEST_ARGUMENT_BYTES))
}

@(test)
evict_decision_counts_the_arriving_bytes :: proc(t: ^testing.T) {
	kept_limit := maxmemory_bytes
	defer maxmemory_bytes = kept_limit
	maxmemory_bytes = 0
	testing.expect(t, !memory_state_over_current(1 << 40))
	mem_registry_changed()
	base := mem_used_current() - mem_not_counted()
	limit := max(base, 0) + 4096
	maxmemory_bytes = u64(limit)
	testing.expect(t, !memory_state_over_current())
	testing.expect(t, !memory_state_over_current(limit - base))
	testing.expect(t, memory_state_over_current(limit - base + 1))
	over, tofree := memory_state_over()
	testing.expect(t, !over)
	testing.expect_value(t, tofree, 0)
}

@(test)
evict_decision_counts_queued_commands_beyond_their_bytes :: proc(t: ^testing.T) {
	kept_limit := maxmemory_bytes
	kept_extra := tx_queued_extra
	defer {
		maxmemory_bytes = kept_limit
		tx_queued_extra = kept_extra
	}
	tx_queued_extra = 0
	maxmemory_bytes = 0
	mem_registry_changed()
	used_before := mem_used()
	tx_queued_extra = 1 << 40
	testing.expect(t, !memory_state_over_current(0))
	over, tofree := memory_state_over()
	testing.expect(t, !over && tofree == 0)
	testing.expect_value(t, mem_used(), used_before)
	tx_queued_extra = 0
	base := mem_used_current() - mem_not_counted()
	limit := max(base, 0) + 4096
	maxmemory_bytes = u64(limit)
	held := 3 * QUEUED_COMMAND_BYTES + 9 * (REQUEST_ARGUMENT_BYTES - 8)
	testing.expect(t, !memory_state_over_current(limit - base - held))
	tx_queued_extra = held
	testing.expect(t, !memory_state_over_current(limit - base - held))
	testing.expect(t, memory_state_over_current(limit - base - held + 1))
	testing.expect_value(t, mem_used(), used_before)
	tx_queued_extra = 0
	testing.expect(t, !memory_state_over_current(limit - base - held + 1))
}

@(test)
evict_stays_idle_while_a_snapshot_or_log_loads :: proc(t: ^testing.T) {
	kept_limit := maxmemory_bytes
	kept_loading := pst.loading
	kept_log := aof.loading
	kept_since := stat_eviction_exceeded_since
	defer {
		maxmemory_bytes = kept_limit
		pst.loading = kept_loading
		aof.loading = kept_log
		stat_eviction_exceeded_since = kept_since
	}
	maxmemory_bytes = 1
	mem_registry_changed()
	arriving := max(mem_not_counted() - mem_used_current(), 0) + (1 << 20)
	testing.expect(t, memory_state_over_current(arriving))
	stat_eviction_exceeded_since = 0
	pst.loading = true
	testing.expect_value(t, perform_evictions(arriving), Evict_Result.Ok)
	testing.expect_value(t, stat_eviction_exceeded_since, 0)
	pst.loading = false
	aof.loading = true
	testing.expect_value(t, perform_evictions(arriving), Evict_Result.Ok)
	testing.expect_value(t, stat_eviction_exceeded_since, 0)
}

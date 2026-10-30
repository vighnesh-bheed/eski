package main

import "core:testing"
import "base:runtime"

@(test)
lcs_compute_loading_and_exec_fallback :: proc(t: ^testing.T) {
	saved_threads := compute_threads
	saved_loading := pst.loading
	saved_aof := aof.loading
	saved_exec := tx_exec_conn
	saved_fallbacks := compute_fallbacks
	defer {
		compute_threads = saved_threads
		pst.loading = saved_loading
		aof.loading = saved_aof
		tx_exec_conn = saved_exec
		compute_fallbacks = saved_fallbacks
	}
	compute_threads = 1
	c := Conn{fd = 1}
	pst.loading = true
	aof.loading = false
	tx_exec_conn = nil
	testing.expect(t, !lcs_try_compute(&c, nil, nil, nil, COMPUTE_LCS_MIN_CELLS, {}))
	pst.loading = false
	aof.loading = true
	testing.expect(t, !lcs_try_compute(&c, nil, nil, nil, COMPUTE_LCS_MIN_CELLS, {}))
	aof.loading = false
	tx_exec_conn = &c
	testing.expect(t, !lcs_try_compute(&c, nil, nil, nil, COMPUTE_LCS_MIN_CELLS, {}))
	tx_exec_conn = nil
	c.ps += {.Tracking}
	testing.expect(t, !lcs_try_compute(&c, nil, nil, nil, COMPUTE_LCS_MIN_CELLS, {}))
	testing.expect_value(t, compute_fallbacks, saved_fallbacks + 4)
	testing.expect(t, c.compute == nil)
}

@(test)
lcs_key_metadata_covers_both_inputs :: proc(t: ^testing.T) {
	saved_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer context.allocator = saved_allocator
	args := [][]u8{transmute([]u8)string("LCS"), transmute([]u8)string("first"), transmute([]u8)string("second"), transmute([]u8)string("LEN")}
	cmd := lookup_command(args[0])
	testing.expect(t, cmd != nil)
	if cmd == nil {
		return
	}
	spec := cmd_spec_lookup(cmd, args)
	keys: [dynamic]int
	defer delete(keys)
	command_keys(spec, args, &keys)
	testing.expect_value(t, len(keys), 2)
	if len(keys) == 2 {
		testing.expect_value(t, keys[0], 1)
		testing.expect_value(t, keys[1], 2)
	}
}

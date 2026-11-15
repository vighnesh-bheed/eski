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
	saved_submitted, saved_cancelled := compute_submitted, compute_cancelled
	saved_allocator := context.allocator
	context.allocator = runtime.heap_allocator()
	defer {
		compute_threads = saved_threads
		pst.loading = saved_loading
		aof.loading = saved_aof
		tx_exec_conn = saved_exec
		compute_fallbacks = saved_fallbacks
		compute_submitted, compute_cancelled = saved_submitted, saved_cancelled
		context.allocator = saved_allocator
	}
	compute_threads = 1
	a := make([]u8, 1024)
	b := make([]u8, 1024)
	defer delete(a)
	defer delete(b)
	for i in 0 ..< 1024 {
		a[i] = u8('a' + i % 3)
		b[i] = u8('a' + i % 5)
	}
	args := [][]u8{transmute([]u8)string("LCS"), transmute([]u8)string("x"), transmute([]u8)string("y"), transmute([]u8)string("LEN")}
	cells := (len(a) + 1) * (len(b) + 1)
	c := Conn{fd = 1, id = 31}
	pst.loading = false
	aof.loading = false
	tx_exec_conn = nil
	tx_exec_conn = &c
	testing.expect(t, !lcs_try_compute(&c, args, a, b, cells, Lcs_Want{length = true}))
	tx_exec_conn = nil
	c.ps += {.Tracking}
	testing.expect(t, !lcs_try_compute(&c, args, a, b, cells, Lcs_Want{length = true}))
	c.ps -= {.Tracking}
	testing.expect_value(t, compute_fallbacks, saved_fallbacks + 2)
	testing.expect(t, c.compute == nil)
	for state in 0 ..< 2 {
		pst.loading = state == 0
		aof.loading = state == 1
		before := compute_fallbacks
		testing.expect(t, lcs_try_compute(&c, args, a, b, cells, Lcs_Want{length = true}))
		task := c.compute
		testing.expect(t, task != nil && task.coordinated && task.slot == -1 && len(compute_ready) == 1 && compute_ready[0] == task)
		testing.expect(t, compute_fallbacks == before + 1 && compute_reserved == 0 && compute_pending == 0)
		if task != nil {
			lcs := cast(^Lcs_Task)task
			testing.expect(t, lcs.table[lcs.cells - 1] > 0)
		}
		c.compute = nil
		compute_ready_run()
		testing.expect(t, len(compute_ready) == 0 && compute_coordinated == 0 && compute_coordinated_bytes == 0)
	}
	pst.loading = false
	aof.loading = false
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

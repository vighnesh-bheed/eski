package rdb

import "base:intrinsics"
import "core:sys/linux"
import "core:thread"
import "core:testing"

Lzf_Producer :: struct {
	gate: ^u32,
	input: []u8,
	expected: []u8,
	identical: bool,
	destroyed: bool,
}

lzf_write_history :: proc(w: ^Writer, input: []u8) {
	for _ in 0 ..< 32 {
		put_string(w, input)
		put_string(w, input[17:])
		put_string(w, input[:137])
	}
}

lzf_produce_history :: proc(data: rawptr) {
	state := cast(^Lzf_Producer)data
	for intrinsics.atomic_load_explicit(state.gate, .Acquire) == 0 { linux.sched_yield() }
	writer: Writer
	writer_init_mem(&writer, true, false)
	lzf_write_history(&writer, state.input)
	state.identical = string(writer_bytes(&writer)) == string(state.expected)
	writer_destroy(&writer)
	state.destroyed = writer.lzf_context.table == nil && writer.lzf_context.base == 0 && writer.lzf_buf == nil && writer.buf == nil
}

@(test)
independent_writers_compress_identical_histories_and_free_private_scratch :: proc(t: ^testing.T) {
	input := make([]u8, 8192)
	defer delete(input)
	for &byte, i in input { byte = u8((i * 13) % 251) }
	reference: Writer
	writer_init_mem(&reference, true, false)
	defer writer_destroy(&reference)
	lzf_write_history(&reference, input)
	testing.expect(t, reference.lzf_context.table != nil)
	gate: u32
	states: [4]Lzf_Producer
	workers: [4]^thread.Thread
	for &state, i in states {
		state = Lzf_Producer{gate = &gate, input = input, expected = writer_bytes(&reference)}
		workers[i] = thread.create_and_start_with_data(&state, lzf_produce_history)
		testing.expect(t, workers[i] != nil)
	}
	intrinsics.atomic_store_explicit(&gate, 1, .Release)
	for worker in workers { thread.join(worker); thread.destroy(worker) }
	for state in states {
		testing.expect(t, state.identical && state.destroyed)
	}
}

@(test)
lzf_private_context_rollover_preserves_exact_bytes :: proc(t: ^testing.T) {
	input := make([]u8, 4096)
	defer delete(input)
	for &byte, i in input { byte = u8(i % 31) }
	expected := make([]u8, len(input))
	defer delete(expected)
	actual := make([]u8, len(input))
	defer delete(actual)
	n := lzf_compress(input, expected)
	testing.expect(t, n > 0)
	ctx: Lzf_Context
	defer lzf_context_destroy(&ctx)
	for _ in 0 ..< 3 {
		written := lzf_compress_with_context(&ctx, input, actual)
		testing.expect(t, written == n && string(actual[:written]) == string(expected[:n]))
	}
	ctx.base = max(u32) - u32(len(input)) + 1
	written := lzf_compress_with_context(&ctx, input, actual)
	testing.expect(t, ctx.base == u32(len(input)) && written == n && string(actual[:written]) == string(expected[:n]))
}

Crc_Producer :: struct {
	gate: ^u32,
	input: []u8,
	expected: u64,
	valid: bool,
}

crc_produce_first_call :: proc(data: rawptr) {
	state := cast(^Crc_Producer)data
	for intrinsics.atomic_load_explicit(state.gate, .Acquire) == 0 { linux.sched_yield() }
	state.valid = true
	for _ in 0 ..< 128 {
		state.valid = state.valid && crc64(0, state.input) == state.expected
	}
}

@(test)
concurrent_crc_first_call_observes_only_complete_immutable_tables :: proc(t: ^testing.T) {
	input := make([]u8, 2048)
	defer delete(input)
	for &byte, i in input { byte = u8(i % 251) }
	expected := crc64_bitwise(0, input)
	gate: u32
	states: [4]Crc_Producer
	workers: [4]^thread.Thread
	for &state, i in states {
		state = Crc_Producer{gate = &gate, input = input, expected = expected}
		workers[i] = thread.create_and_start_with_data(&state, crc_produce_first_call)
		testing.expect(t, workers[i] != nil)
	}
	intrinsics.atomic_store_explicit(&gate, 1, .Release)
	for worker in workers { thread.join(worker); thread.destroy(worker) }
	for state in states { testing.expect(t, state.valid) }
}

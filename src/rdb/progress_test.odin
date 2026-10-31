package rdb

import "core:testing"

Progress_Test :: struct {
	calls: int,
	offset: i64,
}

progress_test_callback :: proc "contextless" (r: ^Reader) {
	state := cast(^Progress_Test)r.user
	state.calls += 1
	state.offset = reader_offset(r)
}

@(test)
buffered_consumption_progress_polls_preserve_borrowed_bytes :: proc(t: ^testing.T) {
	data: [4096]u8
	for &byte, i in data { byte = u8(i & 255) }
	r: Reader
	reader_init_mem(&r, data[:], false)
	defer reader_destroy(&r)
	state: Progress_Test
	r.user = &state
	r.progress = progress_test_callback
	r.tick_every, r.next_tick = 1024, 1024
	borrowed, good := take(&r, 1024)
	testing.expect(t, good)
	before := raw_data(borrowed)
	reader_poll_progress(&r)
	testing.expect_value(t, state.calls, 1)
	testing.expect_value(t, state.offset, 1024)
	testing.expect_value(t, raw_data(borrowed), before)
	testing.expect_value(t, borrowed[511], 255)
	reader_poll_progress(&r)
	testing.expect_value(t, state.calls, 1)
	_, good = take(&r, 1024)
	testing.expect(t, good)
	reader_poll_progress(&r)
	testing.expect_value(t, state.calls, 2)
	testing.expect_value(t, state.offset, 2048)
}

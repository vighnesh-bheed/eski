package groups_test

import rx "../../src/rax"
import st "../../src/streamtype"
import "core:fmt"
import "core:testing"

T0 :: i64(1793090537000)

main :: proc() {
}

ids :: proc(pairs: ..[2]u64) -> []st.ID {
	out := make([]st.ID, len(pairs), context.temp_allocator)
	for p, i in pairs {
		out[i] = st.ID{p[0], p[1]}
	}
	return out
}

id :: #force_inline proc(ms: u64, seq: u64 = 0) -> st.ID {
	return st.ID{ms, seq}
}

b :: #force_inline proc(s: string) -> []u8 {
	return transmute([]u8)s
}

add :: proc(t: ^testing.T, s: st.Stream, ms: u64, seq: u64 = 0, field := "f", value := "v") {
	use := st.ID{ms, seq}
	fv := [2][]u8{b(field), b(value)}
	_, res := st.append_entry(s, fv[:], .Explicit, use, 0)
	testing.expectf(t, res == .Ok, "append %d-%d failed: %v", ms, seq, res)
}

stream_1_to :: proc(t: ^testing.T, n: u64) -> st.Stream {
	s := st.create()
	for i in 1 ..= n {
		add(t, s, i, 0, "f", fmt.tprintf("v%d", i))
	}
	return s
}

baseline :: proc(s: st.Stream) -> int {
	return s.group_bytes
}

deliver :: proc(s: st.Stream, cg: ^st.Group, c: ^st.Member, count: int, noack: bool, now: i64) -> []st.ID {
	out := make([dynamic]st.ID, context.temp_allocator)
	start := cg.delivered
	if !st.incr_id(&start) {
		return out[:]
	}
	si: st.Cursor
	st.cursor_open(&si, s, &start, nil, false)
	for count <= 0 || len(out) < count {
		cur, nf, more := st.cursor_next(&si)
		if !more {
			break
		}
		st.cursor_skip(&si, nf)
		st.group_deliver(s, cg, c, cur, noack, now)
		append(&out, cur)
	}
	st.cursor_close(&si)
	return out[:]
}

pel_ids :: proc(r: ^rx.Rax) -> []st.ID {
	out := make([dynamic]st.ID, context.temp_allocator)
	it: rx.Iterator
	rx.start(&it, r)
	rx.seek(&it, "^")
	for rx.next(&it) {
		append(&out, st.decode_id(rx.key(&it)))
	}
	rx.stop(&it)
	return out[:]
}

consumer_names :: proc(cg: ^st.Group) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	it: rx.Iterator
	rx.start(&it, cg.members)
	rx.seek(&it, "^")
	for rx.next(&it) {
		append(&out, string((^st.Member)(it.data).name))
	}
	rx.stop(&it)
	return out[:]
}

group_names :: proc(s: st.Stream) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if s.groups == nil {
		return out[:]
	}
	it: rx.Iterator
	rx.start(&it, s.groups)
	rx.seek(&it, "^")
	for rx.next(&it) {
		append(&out, fmt.tprintf("%s", rx.key(&it)))
	}
	rx.stop(&it)
	return out[:]
}

same_ids :: proc(a: []st.ID, b: []st.ID) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

same_strings :: proc(a: []string, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

lag_of :: proc(s: st.Stream, cg: ^st.Group) -> (lag: i64, known: bool) {
	return st.group_lag(s, cg)
}

expect_lag :: proc(t: ^testing.T, s: st.Stream, cg: ^st.Group, want: i64, loc := #caller_location) {
	lag, known := st.group_lag(s, cg)
	testing.expectf(t, known && lag == want, "lag: got %v known %v, want %v", lag, known, want, loc = loc)
}

expect_lag_unknown :: proc(t: ^testing.T, s: st.Stream, cg: ^st.Group, loc := #caller_location) {
	lag, known := st.group_lag(s, cg)
	testing.expectf(t, !known, "lag: got %v, want unknown", lag, loc = loc)
}

expect_read :: proc(t: ^testing.T, cg: ^st.Group, want: i64, loc := #caller_location) {
	testing.expectf(t, cg.reads == want, "entries read: got %v want %v", cg.reads, want, loc = loc)
}

claim_args :: proc(minidle: i64 = 0) -> st.Claim_Options {
	return st.Claim_Options{idle_floor = minidle, stamp = st.CLAIM_UNSET, tries = st.CLAIM_UNSET}
}

package svbyte

import "core:testing"

Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ z >> 30) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ z >> 27) * 0x94D0_49BB_1331_11EB
	return z ~ z >> 31
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	return int(rng_next(r) % u64(n))
}

random_values :: proc(r: ^Rng, n: int) -> []u32 {
	out := make([]u32, n)
	for i in 0 ..< n {
		bits := uint(rng_below(r, 33))
		out[i] = u32(rng_next(r) & ((u64(1) << bits) - 1))
	}
	return out
}

check_round_trip :: proc(t: ^testing.T, values: []u32, slack: int) -> bool {
	n := len(values)
	buf := make([]u8, max_encoded(n) + slack)
	defer delete(buf)
	size := encode(values, buf)
	if !testing.expect_value(t, encoded_length(buf[:size], n), size) {
		return false
	}
	out := make([]u32, n)
	defer delete(out)
	for level in Level {
		if !level_supported(level) {
			continue
		}
		k := kernels_for(level)
		for &x in out {
			x = 0xDEAD
		}
		used := k.decode(buf[:size + slack], out)
		if !testing.expect_value(t, used, size) {
			return false
		}
		for i in 0 ..< n {
			if out[i] != values[i] {
				testing.expectf(t, false, "level %v slack %d: value %d is %d, want %d", level, slack, i, out[i], values[i])
				return false
			}
		}
	}
	prev := u32(rng_seed_of(values))
	deltas := make([]u8, max_encoded(n) + slack)
	defer delete(deltas)
	sorted := make([]u32, n)
	defer delete(sorted)
	acc := prev
	for i in 0 ..< n {
		acc += values[i]
		sorted[i] = acc
	}
	dsize := encode_delta(sorted, prev, deltas)
	testing.expect_value(t, dsize, size)
	for level in Level {
		if !level_supported(level) {
			continue
		}
		k := kernels_for(level)
		used := k.decode_delta(deltas[:dsize + slack], out, prev)
		if !testing.expect_value(t, used, dsize) {
			return false
		}
		for i in 0 ..< n {
			if out[i] != sorted[i] {
				testing.expectf(t, false, "delta level %v slack %d: value %d is %d, want %d", level, slack, i, out[i], sorted[i])
				return false
			}
		}
	}
	return true
}

rng_seed_of :: proc(values: []u32) -> u32 {
	if len(values) == 0 {
		return 17
	}
	return values[0] * 2654435761
}

@(test)
round_trips_at_every_level :: proc(t: ^testing.T) {
	r := Rng{0x57_7B}
	for n in 0 ..< 70 {
		v := random_values(&r, n)
		ok := check_round_trip(t, v, 0) && check_round_trip(t, v, 15) && check_round_trip(t, v, 3)
		delete(v)
		if !ok {
			return
		}
	}
	for _ in 0 ..< 300 {
		v := random_values(&r, rng_below(&r, 2000))
		ok := check_round_trip(t, v, rng_below(&r, 20))
		delete(v)
		if !ok {
			return
		}
	}
}

@(test)
boundary_values_take_their_byte_lengths :: proc(t: ^testing.T) {
	edges := []u32{0, 1, 0xFF, 0x100, 0xFFFF, 0x1_0000, 0xFF_FFFF, 0x100_0000, max(u32), 0x7F, 0x80}
	want := []int{1, 1, 1, 2, 2, 3, 3, 4, 4, 1, 1}
	for v, i in edges {
		testing.expect_value(t, value_length(v), want[i])
	}
	check_round_trip(t, edges, 0)
	buf: [64]u8
	n := encode([]u32{1, 300, 70_000, 20_000_000}, buf[:])
	testing.expect_value(t, n, 1 + 1 + 2 + 3 + 4)
	testing.expect_value(t, buf[0], u8(0b11_10_01_00))
	testing.expect_value(t, buf[1], u8(1))
	testing.expect_value(t, buf[2], u8(300 & 0xFF))
	testing.expect_value(t, buf[3], u8(300 >> 8))
	wrap := []u32{max(u32) - 1, 3, 2}
	enc: [32]u8
	size := encode_delta(wrap, 5, enc[:])
	out: [3]u32
	used := decode_delta_reference(enc[:size], out[:], 5)
	testing.expect_value(t, used, size)
	testing.expect(t, out == [3]u32{max(u32) - 1, 3, 2})
	testing.expect_value(t, encoded_length(enc[:0], 4), -1)
}

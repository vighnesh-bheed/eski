package bitmap_harness

Rng :: struct {
	s: u64,
}

rng_make :: proc(seed: u64) -> Rng {
	return Rng{s = seed}
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.s += 0x9e3779b97f4a7c15
	z := r.s
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(rng_next(r) % u64(n))
}

rng_range :: proc(r: ^Rng, lo, hi: i64) -> i64 {
	if hi <= lo {
		return lo
	}
	span := u64(hi - lo) + 1
	if span == 0 {
		return i64(rng_next(r))
	}
	return lo + i64(rng_next(r) % span)
}

rng_chance :: proc(r: ^Rng, percent: int) -> bool {
	return rng_below(r, 100) < percent
}

rng_bytes :: proc(r: ^Rng, n: int, style: int, allocator := context.allocator) -> []u8 {
	out := make([]u8, n, allocator)
	switch style {
	case 0:
		for i in 0 ..< n {
			out[i] = u8(rng_next(r))
		}
	case 1:
		for i in 0 ..< n {
			out[i] = u8(1) << u8(rng_below(r, 8)) if rng_chance(r, 3) else 0
		}
	case 2:
		for i in 0 ..< n {
			out[i] = ~(u8(1) << u8(rng_below(r, 8))) if rng_chance(r, 3) else 0xff
		}
	case 3:
		cur: u8 = 0xff if rng_chance(r, 50) else 0
		for i in 0 ..< n {
			if rng_chance(r, 8) {
				cur = ~cur
			}
			out[i] = cur
			if rng_chance(r, 2) {
				out[i] = u8(rng_next(r))
			}
		}
	case 4:
		for i in 0 ..< n {
			out[i] = '0' + u8(rng_below(r, 10))
		}
	case 5:
		for i in 0 ..< n {
			out[i] = 0
		}
	case 6:
		for i in 0 ..< n {
			out[i] = 0xff
		}
	case:
		for i in 0 ..< n {
			out[i] = u8(rng_next(r))
		}
	}
	return out
}

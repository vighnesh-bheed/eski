package roaring

import "core:slice"
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

Shadow :: struct {
	set: map[u32]bool,
}

shadow_sorted :: proc(s: ^Shadow) -> []u32 {
	out := make([dynamic]u32, 0, len(s.set))
	for k in s.set {
		append(&out, k)
	}
	slice.sort(out[:])
	return out[:]
}

random_value :: proc(r: ^Rng) -> u32 {
	switch rng_below(r, 5) {
	case 0:
		return u32(rng_below(r, 70_000))
	case 1:
		return 3 << 16 | u32(rng_below(r, 9000))
	case 2:
		return 7 << 16 | u32(20_000 + rng_below(r, 400))
	case 3:
		return u32(rng_next(r))
	}
	return max(u32) - u32(rng_below(r, 100))
}

expect_matches :: proc(t: ^testing.T, b: ^Bitmap, want: []u32) -> bool {
	if !testing.expect_value(t, cardinality(b), len(want)) {
		return false
	}
	it: Iterator
	iterator_init(&it, b)
	for w, i in want {
		x, ok := next(&it)
		if !ok || x != w {
			testing.expectf(t, false, "element %d is %d (ok %v), want %d", i, x, ok, w)
			return false
		}
	}
	_, more := next(&it)
	testing.expect(t, !more)
	for i := 1; i < len(b.keys); i += 1 {
		testing.expect(t, b.keys[i - 1] < b.keys[i])
	}
	for c in b.containers {
		testing.expect(t, c.cardinality > 0)
		switch c.kind {
		case .Array:
			testing.expect(t, c.cardinality <= ARRAY_MAX && len(c.values) == c.cardinality)
		case .Bitset:
			testing.expect(t, c.cardinality > ARRAY_MAX && words_count(c.words) == c.cardinality)
		case .Run:
			total := 0
			for r := 0; r < len(c.values); r += 2 {
				total += int(c.values[r + 1]) + 1
			}
			testing.expect_value(t, total, c.cardinality)
		}
	}
	return true
}

@(test)
adds_and_removes_follow_a_set :: proc(t: ^testing.T) {
	r := Rng{0x0A_A7}
	b: Bitmap
	init(&b)
	defer destroy(&b)
	s: Shadow
	defer delete(s.set)
	for step in 0 ..< 60_000 {
		x := random_value(&r)
		if rng_below(&r, 3) == 0 && len(s.set) > 0 {
			removed, err := remove(&b, x)
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, removed, x in s.set)
			delete_key(&s.set, x)
		} else {
			added, err := add(&b, x)
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, added, !(x in s.set))
			s.set[x] = true
		}
		if step % 997 == 0 {
			probe := random_value(&r)
			testing.expect_value(t, contains(&b, probe), probe in s.set)
		}
		if step % 15_000 == 14_999 {
			want := shadow_sorted(&s)
			ok := expect_matches(t, &b, want)
			delete(want)
			if !ok {
				return
			}
			_, err := run_optimize(&b)
			testing.expect_value(t, err, Error.None)
			want = shadow_sorted(&s)
			ok = expect_matches(t, &b, want)
			delete(want)
			if !ok {
				return
			}
		}
	}
	for x in s.set {
		testing.expect(t, contains(&b, x))
	}
}

@(test)
dense_ranges_become_bitsets_then_runs :: proc(t: ^testing.T) {
	b: Bitmap
	init(&b)
	defer destroy(&b)
	for x in u32(100) ..< 30_100 {
		add(&b, x)
	}
	testing.expect_value(t, b.containers[0].kind, Kind.Bitset)
	changed, _ := run_optimize(&b)
	testing.expect(t, changed)
	testing.expect_value(t, b.containers[0].kind, Kind.Run)
	testing.expect_value(t, cardinality(&b), 30_000)
	lo, _ := minimum(&b)
	hi, _ := maximum(&b)
	testing.expect_value(t, lo, 100)
	testing.expect_value(t, hi, 30_099)
	testing.expect(t, contains(&b, 100) && contains(&b, 30_099) && !contains(&b, 99) && !contains(&b, 30_100))
	removed, err := remove(&b, 5000)
	testing.expect(t, removed && err == .None)
	testing.expect_value(t, cardinality(&b), 29_999)
	testing.expect(t, !contains(&b, 5000))
	for x in u32(100) ..< 30_100 {
		if x != 5000 {
			remove(&b, x)
		}
	}
	testing.expect(t, is_empty(&b))
	for x in u32(0) ..< 65_536 {
		add(&b, 2 << 16 | x)
	}
	run_optimize(&b)
	testing.expect_value(t, b.containers[0].kind, Kind.Run)
	testing.expect_value(t, len(b.containers[0].values), 2)
	testing.expect_value(t, cardinality(&b), 65_536)
}

random_bitmap :: proc(r: ^Rng, b: ^Bitmap, s: ^Shadow, n: int) {
	init(b)
	for _ in 0 ..< n {
		x := random_value(r)
		add(b, x)
		s.set[x] = true
	}
	if rng_below(r, 2) == 0 {
		lo := u32(rng_below(r, 1 << 20))
		for x in lo ..< lo + u32(rng_below(r, 20_000)) {
			add(b, x)
			s.set[x] = true
		}
	}
	if rng_below(r, 2) == 0 {
		run_optimize(b)
	}
}

@(test)
set_operations_agree_with_brute_force :: proc(t: ^testing.T) {
	r := Rng{0x0B5}
	for round in 0 ..< 40 {
		a, b: Bitmap
		sa, sb: Shadow
		random_bitmap(&r, &a, &sa, rng_below(&r, 12_000))
		random_bitmap(&r, &b, &sb, rng_below(&r, 12_000))
		ops := [?]Op{.And, .Or, .Andnot}
		for op in ops {
			out: Bitmap
			init(&out)
			testing.expect_value(t, combine(op, &a, &b, &out), Error.None)
			want := make([dynamic]u32)
			switch op {
			case .And:
				for x in sa.set {
					if x in sb.set {
						append(&want, x)
					}
				}
			case .Or:
				for x in sa.set {
					append(&want, x)
				}
				for x in sb.set {
					if !(x in sa.set) {
						append(&want, x)
					}
				}
			case .Andnot:
				for x in sa.set {
					if !(x in sb.set) {
						append(&want, x)
					}
				}
			}
			slice.sort(want[:])
			ok := expect_matches(t, &out, want[:])
			if op == .And {
				n, err := and_cardinality(&a, &b)
				testing.expect_value(t, err, Error.None)
				testing.expect_value(t, n, len(want))
			}
			delete(want)
			destroy(&out)
			if !ok {
				testing.expectf(t, false, "round %d op %v", round, op)
				break
			}
		}
		copied: Bitmap
		init(&copied)
		copy_into(&copied, &a)
		testing.expect(t, equal(&copied, &a))
		combine_into(.Or, &copied, &b)
		testing.expect_value(t, cardinality(&copied), cardinality(&a) + cardinality(&b) - must_and(&a, &b))
		destroy(&copied)
		destroy(&a)
		destroy(&b)
		delete(sa.set)
		delete(sb.set)
	}
}

must_and :: proc(a, b: ^Bitmap) -> int {
	n, _ := and_cardinality(a, b)
	return n
}

@(test)
advance_finds_the_first_value_not_below :: proc(t: ^testing.T) {
	r := Rng{0xADF}
	for _ in 0 ..< 30 {
		b: Bitmap
		s: Shadow
		random_bitmap(&r, &b, &s, rng_below(&r, 8000))
		want := shadow_sorted(&s)
		it: Iterator
		iterator_init(&it, &b)
		target := u32(0)
		pos := 0
		for _ in 0 ..< 400 {
			step := u32(rng_below(&r, 1 << uint(rng_below(&r, 24))))
			target += step
			for pos < len(want) && want[pos] < target {
				pos += 1
			}
			x, ok := advance(&it, target)
			if pos == len(want) {
				testing.expect(t, !ok)
				break
			}
			if !testing.expectf(t, ok && x == want[pos], "advance %d gave %d %v want %d", target, x, ok, want[pos]) {
				break
			}
			if rng_below(&r, 3) == 0 {
				y, more := next(&it)
				if pos + 1 < len(want) {
					testing.expect(t, more && y == want[pos + 1])
					pos += 1
					target = y
				} else {
					testing.expect(t, !more)
					break
				}
			}
		}
		delete(want)
		destroy(&b)
		delete(s.set)
	}
}

@(test)
serialization_round_trips :: proc(t: ^testing.T) {
	r := Rng{0x5E41}
	for round in 0 ..< 30 {
		b: Bitmap
		s: Shadow
		random_bitmap(&r, &b, &s, rng_below(&r, 10_000) if round > 0 else 0)
		size := serialized_size(&b)
		buf := make([]u8, size)
		testing.expect_value(t, serialize(&b, buf), size)
		back: Bitmap
		init(&back)
		used, err := deserialize(&back, buf)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, used, size)
		testing.expect(t, equal(&b, &back))
		for cut in ([?]int{0, 3, size / 2, size - 1}) {
			if cut < size && cut >= 0 {
				_, e := deserialize(&back, buf[:cut])
				testing.expect(t, e != .None || size == 8)
			}
		}
		delete(buf)
		destroy(&back)
		destroy(&b)
		delete(s.set)
	}
}

@(test)
serialized_layout_follows_the_portable_format :: proc(t: ^testing.T) {
	b: Bitmap
	init(&b)
	defer destroy(&b)
	add(&b, 1)
	add(&b, 5)
	add(&b, 1 << 16 | 3)
	buf := make([]u8, serialized_size(&b))
	defer delete(buf)
	n := serialize(&b, buf)
	want := []u8{0x3A, 0x30, 0, 0, 2, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 24, 0, 0, 0, 28, 0, 0, 0, 1, 0, 5, 0, 3, 0}
	testing.expect_value(t, n, len(want))
	testing.expect(t, slice.equal(buf[:n], want))
	for x in u32(10) ..< 20 {
		add(&b, x)
	}
	run_optimize(&b)
	testing.expect_value(t, b.containers[0].kind, Kind.Run)
	runs := make([]u8, serialized_size(&b))
	defer delete(runs)
	n = serialize(&b, runs)
	want_runs := []u8{0x3B, 0x30, 1, 0, 1, 0, 0, 11, 0, 1, 0, 0, 0, 3, 0, 1, 0, 0, 0, 5, 0, 0, 0, 10, 0, 9, 0, 3, 0}
	testing.expect_value(t, n, len(want_runs))
	testing.expect(t, slice.equal(runs[:n], want_runs))
	back: Bitmap
	init(&back)
	defer destroy(&back)
	_, err := deserialize(&back, runs[:n])
	testing.expect_value(t, err, Error.None)
	testing.expect(t, equal(&b, &back))
	bad := make([]u8, n)
	defer delete(bad)
	copy(bad, runs[:n])
	bad[0] = 0x39
	_, err = deserialize(&back, bad)
	testing.expect_value(t, err, Error.Invalid_Data)
}

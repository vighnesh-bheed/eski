package numindex

import "core:math"
import "core:slice"
import "core:testing"
import "../roaring"

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

SPECIAL := [?]f64{0, -0.0, 1, -1, 2.5, 1e300, -1e300, 9007199254740992}

random_value :: proc(r: ^Rng) -> f64 {
	switch rng_below(r, 4) {
	case 0:
		return SPECIAL[rng_below(r, len(SPECIAL))]
	case 1:
		return math.inf_f64(1) if rng_below(r, 2) == 0 else math.inf_f64(-1)
	case 2:
		return f64(rng_below(r, 40)) - 20
	}
	return f64(rng_below(r, 100_000)) / 7 - 5000
}

random_bound :: proc(r: ^Rng) -> Bound {
	switch rng_below(r, 6) {
	case 0:
		return below()
	case 1:
		return above()
	}
	return Bound{value = random_value(r), exclusive = rng_below(r, 2) == 0}
}

Pair :: struct {
	doc:   u32,
	value: f64,
}

@(test)
ranges_agree_with_a_brute_force_scan :: proc(t: ^testing.T) {
	r := Rng{0x40_E7}
	ix: Index
	init(&ix)
	defer destroy(&ix)
	shadow := make([dynamic]Pair)
	defer delete(shadow)
	for step in 0 ..< 30_000 {
		if rng_below(&r, 4) == 0 && len(shadow) > 0 {
			i := rng_below(&r, len(shadow))
			p := shadow[i]
			testing.expect(t, remove(&ix, p.doc, p.value))
			unordered_remove(&shadow, i)
		} else {
			p := Pair{doc = u32(1 + rng_below(&r, 5000)), value = random_value(&r)}
			dup := false
			for q in shadow {
				if q.doc == p.doc && q.value == p.value {
					dup = true
				}
			}
			added, err := add(&ix, p.doc, p.value)
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, added, !dup)
			if !dup {
				append(&shadow, p)
			}
		}
		if step % 3000 == 2999 {
			testing.expect_value(t, count(&ix), len(shadow))
			for _ in 0 ..< 40 {
				lo, hi := random_bound(&r), random_bound(&r)
				want := make([dynamic]u32, context.temp_allocator)
				for p in shadow {
					if above_low(p.value, lo) && below_high(p.value, hi) {
						append(&want, p.doc)
					}
				}
				slice.sort(want[:])
				uniq := slice.unique(want[:])
				got := make([dynamic]u32, context.temp_allocator)
				testing.expect_value(t, range_docs(&ix, lo, hi, &got), Error.None)
				if !testing.expectf(t, slice.equal(got[:], uniq), "range %v %v", lo, hi) {
					return
				}
				b: roaring.Bitmap
				roaring.init(&b)
				range_bitmap(&ix, lo, hi, &b)
				testing.expect_value(t, roaring.cardinality(&b), len(uniq))
				roaring.destroy(&b)
			}
			free_all(context.temp_allocator)
		}
	}
	_, err := add(&ix, 1, math.nan_f64())
	testing.expect_value(t, err, Error.Not_A_Number)
	testing.expect(t, !remove(&ix, 1, math.nan_f64()))
}

@(test)
bounds_follow_the_query_syntax :: proc(t: ^testing.T) {
	ix: Index
	init(&ix)
	defer destroy(&ix)
	for v, i in ([?]f64{1, 2, 2, 3, 5, math.inf_f64(1), math.inf_f64(-1), -0.0}) {
		add(&ix, u32(i + 1), v)
	}
	check :: proc(t: ^testing.T, ix: ^Index, lo, hi: Bound, want: []u32) {
		got := make([dynamic]u32)
		defer delete(got)
		range_docs(ix, lo, hi, &got)
		testing.expectf(t, slice.equal(got[:], want), "%v %v gave %v want %v", lo, hi, got[:], want)
	}
	check(t, &ix, inclusive(2), inclusive(3), {2, 3, 4})
	check(t, &ix, exclusive(2), inclusive(5), {4, 5})
	check(t, &ix, inclusive(1), exclusive(5), {1, 2, 3, 4})
	check(t, &ix, below(), inclusive(0), {7, 8})
	check(t, &ix, exclusive(5), above(), {6})
	check(t, &ix, below(), above(), {1, 2, 3, 4, 5, 6, 7, 8})
	check(t, &ix, inclusive(5), inclusive(1), {})
	check(t, &ix, inclusive(0), inclusive(0), {8})
	check(t, &ix, inclusive(math.inf_f64(1)), above(), {6})
	deleted: roaring.Bitmap
	roaring.init(&deleted)
	defer roaring.destroy(&deleted)
	roaring.add(&deleted, 2)
	roaring.add(&deleted, 6)
	testing.expect_value(t, collect(&ix, &deleted), 2)
	check(t, &ix, below(), above(), {1, 3, 4, 5, 7, 8})
	testing.expect_value(t, count(&ix), 6)
}

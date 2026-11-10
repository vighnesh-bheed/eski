package sorted

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

random_set :: proc(r: ^Rng, n: int, universe: u32) -> []u32 {
	out := make([dynamic]u32, 0, n)
	for _ in 0 ..< n {
		append(&out, u32(rng_next(r) % u64(universe)))
	}
	slice.sort(out[:])
	unique := slice.unique(out[:])
	return unique
}

brute_intersection :: proc(a, b: []u32) -> []u32 {
	out := make([dynamic]u32)
	for x in a {
		if _, found := slice.binary_search(b, x); found {
			append(&out, x)
		}
	}
	return out[:]
}

expect_same :: proc(t: ^testing.T, got: []u32, want: []u32, label: string) -> bool {
	if len(got) != len(want) {
		testing.expectf(t, false, "%s: %d results, want %d", label, len(got), len(want))
		return false
	}
	for i in 0 ..< len(got) {
		if got[i] != want[i] {
			testing.expectf(t, false, "%s: element %d is %d, want %d", label, i, got[i], want[i])
			return false
		}
	}
	return true
}

check_all_kernels :: proc(t: ^testing.T, a, b: []u32) -> bool {
	want := brute_intersection(a, b)
	defer delete(want)
	out := make([]u32, min(len(a), len(b)) + 1)
	defer delete(out)
	n := intersect_reference(a, b, out)
	if !expect_same(t, out[:n], want, "reference") {
		return false
	}
	n = intersect_merge(a, b, out)
	if !expect_same(t, out[:n], want, "branchless merge") {
		return false
	}
	if len(a) <= len(b) {
		n = intersect_gallop(a, b, out)
	} else {
		n = intersect_gallop(b, a, out)
	}
	if !expect_same(t, out[:n], want, "gallop") {
		return false
	}
	for level in Level {
		if !level_supported(level) {
			continue
		}
		k := kernels_for(level)
		tight := make([]u32, min(len(a), len(b)))
		n = k.intersect(a, b, tight)
		ok := expect_same(t, tight[:n], want, "simd kernel")
		delete(tight)
		if !ok {
			return false
		}
	}
	n = intersect(a, b, out)
	if !expect_same(t, out[:n], want, "dispatch") {
		return false
	}
	testing.expect_value(t, intersect_count(a, b), len(want))
	return true
}

@(test)
intersections_agree_with_brute_force :: proc(t: ^testing.T) {
	r := Rng{0x50_47}
	for round in 0 ..< 600 {
		na := rng_below(&r, 300)
		nb := rng_below(&r, 300)
		universe := u32(1 + rng_below(&r, 2000))
		if round % 7 == 0 {
			nb = rng_below(&r, 20000)
			universe = 100_000
		}
		a := random_set(&r, na, universe)
		b := random_set(&r, nb, universe)
		ok := check_all_kernels(t, a, b) && check_all_kernels(t, b, a)
		delete(a)
		delete(b)
		if !ok {
			return
		}
	}
}

@(test)
intersection_edges :: proc(t: ^testing.T) {
	empty: []u32
	one := []u32{7}
	check_all_kernels(t, empty, empty)
	check_all_kernels(t, empty, one)
	check_all_kernels(t, one, one)
	dense := make([]u32, 1000)
	defer delete(dense)
	for i in 0 ..< len(dense) {
		dense[i] = u32(i)
	}
	check_all_kernels(t, dense, dense)
	check_all_kernels(t, dense[:17], dense[3:])
	odd := make([]u32, 500)
	defer delete(odd)
	even := make([]u32, 500)
	defer delete(even)
	for i in 0 ..< 500 {
		odd[i] = u32(2 * i + 1)
		even[i] = u32(2 * i)
	}
	check_all_kernels(t, odd, even)
	high := []u32{max(u32) - 9, max(u32) - 3, max(u32) - 1, max(u32)}
	check_all_kernels(t, high, high)
	check_all_kernels(t, dense, high)
	strided := make([]u32, 64)
	defer delete(strided)
	for i in 0 ..< 64 {
		strided[i] = u32(i * 8)
	}
	check_all_kernels(t, strided, dense)
}

@(test)
searches_find_first_not_less :: proc(t: ^testing.T) {
	r := Rng{0x9A11}
	for _ in 0 ..< 300 {
		a := random_set(&r, rng_below(&r, 400), 5000)
		for _ in 0 ..< 40 {
			target := u32(rng_below(&r, 5100))
			want := 0
			for want < len(a) && a[want] < target {
				want += 1
			}
			testing.expect_value(t, lower_bound(a, target), want)
			from := rng_below(&r, want + 1)
			testing.expect_value(t, gallop(a, from, target), want)
			up := 0
			for up < len(a) && a[up] <= target {
				up += 1
			}
			testing.expect_value(t, upper_bound(a, target), up)
		}
		delete(a)
	}
	testing.expect_value(t, gallop([]u32{1, 2, 3}, 5, 2), 5)
}

@(test)
unions_and_differences_agree_with_brute_force :: proc(t: ^testing.T) {
	r := Rng{0xD1FF}
	for _ in 0 ..< 400 {
		a := random_set(&r, rng_below(&r, 200), 600)
		b := random_set(&r, rng_below(&r, 200), 600)
		out := make([]u32, len(a) + len(b))
		n := union_merge(a, b, out)
		want := make([dynamic]u32)
		append(&want, ..a)
		append(&want, ..b)
		slice.sort(want[:])
		uniq := slice.unique(want[:])
		expect_same(t, out[:n], uniq, "union")
		testing.expect(t, is_strict(out[:n]))
		n = difference_merge(a, b, out)
		diff := make([dynamic]u32)
		for x in a {
			if _, found := slice.binary_search(b, x); !found {
				append(&diff, x)
			}
		}
		expect_same(t, out[:n], diff[:], "difference")
		n = intersect_merge(a, a, a)
		testing.expect_value(t, n, len(a))
		delete(diff)
		delete(want)
		delete(out)
		delete(a)
		delete(b)
	}
}

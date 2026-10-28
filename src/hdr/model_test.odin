package hdr

import "core:math"
import "core:slice"

TEST_LOWEST :: i64(1)
TEST_HIGHEST :: i64(1_000_000_000)
TEST_DIGITS :: i32(2)
TEST_COUNT :: 4000

TEST_PERCENTILES :: [?]i64{0, 1_000, 10_000, 12_345, 25_000, 33_333, 50_000, 75_000, 90_000, 99_000, 99_900, 99_990, 99_999, 100_000}

Test_Rng :: struct {
	state: u64,
}

test_rng_next :: proc(r: ^Test_Rng) -> u64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

test_rng_below :: proc(r: ^Test_Rng, n: u64) -> i64 {
	return i64(test_rng_next(r) % n)
}

test_rng_unit :: proc(r: ^Test_Rng) -> f64 {
	return (f64(test_rng_next(r) >> 11) + 1) / 9007199254740992.0
}

Test_Distribution :: enum {
	Uniform,
	Exponential,
	Clustered,
	Log_Uniform,
}

test_generate :: proc(kind: Test_Distribution, seed: u64, n: int) -> []i64 {
	r := Test_Rng{seed}
	centers := [5]i64{40, 200, 3_000, 150_000, 80_000_000}
	spreads := [5]i64{30, 100, 500, 40_000, 5_000_000}
	values := make([]i64, n)
	for &v in values {
		switch kind {
		case .Uniform:
			v = 50_000 + test_rng_below(&r, 5_000_000)
		case .Exponential:
			v = 1 + i64(-math.ln(test_rng_unit(&r)) * 20_000)
		case .Clustered:
			c := test_rng_below(&r, 5)
			v = centers[c] + test_rng_below(&r, u64(spreads[c]))
		case .Log_Uniform:
			e := u64(test_rng_below(&r, 30))
			v = (i64(1) << e) + test_rng_below(&r, u64(1) << e)
		}
		v = clamp(v, TEST_LOWEST, TEST_HIGHEST)
	}
	return values
}

test_sorted_copy :: proc(values: []i64) -> []i64 {
	sorted := slice.clone(values)
	slice.sort(sorted)
	return sorted
}

model_bit_length :: proc(v: i64) -> uint {
	bits: uint = 0
	for x := u64(v); x != 0; x >>= 1 {
		bits += 1
	}
	return bits
}

model_width :: proc(v: i64) -> i64 {
	bits := model_bit_length(v)
	if bits <= 8 {
		return 1
	}
	return i64(1) << (bits - 8)
}

model_bucket_low :: proc(v: i64) -> i64 {
	return v - v % model_width(v)
}

model_bucket_high :: proc(v: i64) -> i64 {
	return model_bucket_low(v) + model_width(v) - 1
}

model_rank :: proc(milli_percent: i64, n: int) -> int {
	rank := int((2 * milli_percent * i64(n) + 100_000) / 200_000)
	return clamp(rank, 1, n)
}

model_count_up_to :: proc(sorted: []i64, limit: i64) -> i64 {
	total: i64 = 0
	for v in sorted {
		if model_bucket_low(v) <= limit {
			total += 1
		}
	}
	return total
}

Model_Bucket :: struct {
	low:        i64,
	high:       i64,
	count:      i64,
	cumulative: i64,
}

model_buckets :: proc(sorted: []i64) -> [dynamic]Model_Bucket {
	buckets := make([dynamic]Model_Bucket)
	cumulative: i64 = 0
	for v in sorted {
		low := model_bucket_low(v)
		cumulative += 1
		last := len(buckets) - 1
		if last >= 0 && buckets[last].low == low {
			buckets[last].count += 1
			buckets[last].cumulative = cumulative
		} else {
			append(&buckets, Model_Bucket{low = low, high = model_bucket_high(v), count = 1, cumulative = cumulative})
		}
	}
	return buckets
}

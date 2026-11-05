package hdr

import "core:slice"
import "core:testing"

check_recorded_iteration :: proc(t: ^testing.T, h: ^Histogram, sorted: []i64) {
	expected := model_buckets(sorted)
	defer delete(expected)
	it: Iter
	iter_init(&it, h)
	matched := 0
	running: i64 = 0
	steps := 0
	for iter_next(&it) {
		steps += 1
		if steps > int(h.counts_len) {
			testing.expect(t, false, "recorded iteration visited more positions than the histogram has")
			break
		}
		testing.expect_value(t, it.value_iterated_to, it.value)
		if it.count == 0 {
			testing.expect_value(t, it.cumulative_count, running)
			continue
		}
		if matched >= len(expected) {
			testing.expectf(t, false, "unexpected recorded bucket starting at %d", it.value)
			break
		}
		want := expected[matched]
		testing.expect_value(t, it.value, want.low)
		testing.expect_value(t, it.lowest_equivalent_value, want.low)
		testing.expect_value(t, it.highest_equivalent_value, want.high)
		testing.expect_value(t, it.median_equivalent_value, want.low + (want.high - want.low + 1) / 2)
		testing.expect_value(t, it.count, want.count)
		testing.expect_value(t, it.cumulative_count, want.cumulative)
		running = want.cumulative
		matched += 1
	}
	testing.expect_value(t, matched, len(expected))
	testing.expect_value(t, running, i64(len(sorted)))
	testing.expect_value(t, it.cumulative_count, i64(len(sorted)))
	testing.expect_value(t, it.total_count, h.total_count)
}

check_log_iteration :: proc(t: ^testing.T, h: ^Histogram, sorted: []i64, first: i64, base: f64) {
	n := i64(len(sorted))
	it: Iter
	iter_log_init(&it, h, first, base)
	level := first
	last_level: i64 = 0
	last_cumulative: i64 = 0
	added_total: i64 = 0
	level_steps := 0
	trailing := false
	steps := 0
	for iter_next(&it) {
		steps += 1
		if steps > 200 {
			testing.expect(t, false, "logarithmic iteration did not terminate")
			break
		}
		testing.expect(t, !trailing, "a step followed the final partial step")
		added_total += it.added_in_step
		if it.value_iterated_to == level {
			level_steps += 1
			want := model_count_up_to(sorted, model_bucket_low(level))
			testing.expectf(t, it.cumulative_count == want, "first %d base %v level %d: cumulative %d, expected %d", first, base, level, it.cumulative_count, want)
			testing.expectf(t, it.added_in_step == want - last_cumulative, "first %d base %v level %d: added %d, expected %d", first, base, level, it.added_in_step, want - last_cumulative)
			testing.expect_value(t, it.highest_equivalent_value, model_bucket_high(level))
			testing.expect_value(t, it.value_iterated_from, last_level)
			last_level = level
			last_cumulative = want
			level *= i64(base)
		} else {
			trailing = true
			testing.expect_value(t, it.cumulative_count, n)
			testing.expect_value(t, it.added_in_step, n - last_cumulative)
		}
	}
	testing.expect_value(t, added_total, n)
	testing.expect_value(t, it.cumulative_count, n)
	testing.expect_value(t, it.total_count, n)
	testing.expect(t, level_steps > 0)
}

check_iterators_over :: proc(t: ^testing.T, kind: Test_Distribution, seed: u64) {
	values := test_generate(kind, seed, TEST_COUNT)
	defer delete(values)
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	for v in values {
		record_value(h, v)
	}
	sorted := test_sorted_copy(values)
	defer delete(sorted)
	check_recorded_iteration(t, h, sorted)
	check_log_iteration(t, h, sorted, 1024, 2)
	check_log_iteration(t, h, sorted, 1, 10)
	check_log_iteration(t, h, sorted, 500, 3)
}

@(test)
iterators_over_uniform_values :: proc(t: ^testing.T) {
	check_iterators_over(t, .Uniform, 0xB001)
}

@(test)
iterators_over_exponential_values :: proc(t: ^testing.T) {
	check_iterators_over(t, .Exponential, 0xB002)
}

@(test)
iterators_over_clustered_values :: proc(t: ^testing.T) {
	check_iterators_over(t, .Clustered, 0xB003)
}

@(test)
iterators_over_log_uniform_values :: proc(t: ^testing.T) {
	check_iterators_over(t, .Log_Uniform, 0xB004)
}

@(test)
iterators_count_weighted_records :: proc(t: ^testing.T) {
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	testing.expect(t, record_values(h, 100, 5))
	testing.expect(t, record_values(h, 70000, 3))
	testing.expect(t, record_values(h, 300, 4))
	testing.expect(t, record_values(h, 100, 2))
	testing.expect_value(t, h.total_count, 14)

	it: Iter
	iter_init(&it, h)
	Seen :: struct {
		low:        i64,
		high:       i64,
		count:      i64,
		cumulative: i64,
	}
	want := [?]Seen{{100, 100, 7, 7}, {300, 301, 4, 11}, {69632, 70143, 3, 14}}
	seen := make([dynamic]Seen)
	defer delete(seen)
	for iter_next(&it) {
		if it.count > 0 {
			append(&seen, Seen{it.lowest_equivalent_value, it.highest_equivalent_value, it.count, it.cumulative_count})
		}
	}
	testing.expect(t, slice.equal(seen[:], want[:]))

	cumulative_by_level := [?]i64{11, 11, 11, 11, 11, 11, 11, 14}
	added_by_level := [?]i64{11, 0, 0, 0, 0, 0, 0, 3}
	highest_by_level := [3]i64{1031, 2063, 4127}
	iter_log_init(&it, h, 1024, 2)
	level := i64(1024)
	for i in 0 ..< len(cumulative_by_level) {
		testing.expect(t, iter_next(&it))
		testing.expect_value(t, it.value_iterated_to, level)
		testing.expect_value(t, it.cumulative_count, cumulative_by_level[i])
		testing.expect_value(t, it.added_in_step, added_by_level[i])
		if i < len(highest_by_level) {
			testing.expect_value(t, it.highest_equivalent_value, highest_by_level[i])
		}
		level *= 2
	}
	for iter_next(&it) {
		testing.expect_value(t, it.cumulative_count, 14)
	}
}

@(test)
iterators_see_nothing_after_reset :: proc(t: ^testing.T) {
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	it: Iter
	iter_init(&it, h)
	for iter_next(&it) {
		testing.expect_value(t, it.count, 0)
		testing.expect_value(t, it.cumulative_count, 0)
	}
	iter_log_init(&it, h, 1024, 2)
	testing.expect(t, !iter_next(&it))

	for v in ([?]i64{1, 50, 4000, 700_000}) {
		record_value(h, v)
	}
	reset(h)

	iter_init(&it, h)
	for iter_next(&it) {
		testing.expect_value(t, it.count, 0)
		testing.expect_value(t, it.cumulative_count, 0)
	}
	testing.expect_value(t, it.total_count, 0)
	iter_log_init(&it, h, 1024, 2)
	testing.expect(t, !iter_next(&it))
	iter_log_init(&it, h, 1, 10)
	testing.expect(t, !iter_next(&it))
}

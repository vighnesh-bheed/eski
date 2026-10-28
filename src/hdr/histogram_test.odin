package hdr

import "core:mem"
import "core:slice"
import "core:testing"

check_distribution :: proc(t: ^testing.T, kind: Test_Distribution, seed: u64, weighted: bool) {
	values := test_generate(kind, seed, TEST_COUNT)
	defer delete(values)
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	expanded := make([dynamic]i64, 0, len(values) * 3)
	defer delete(expanded)
	r := Test_Rng{seed ~ 0xA5A5A5A5}
	for v in values {
		count: i64 = 1
		if weighted {
			count = 1 + test_rng_below(&r, 3)
		}
		testing.expectf(t, record_values(h, v, count), "record_values rejected value %d with count %d", v, count)
		for _ in 0 ..< count {
			append(&expanded, v)
		}
	}
	slice.sort(expanded[:])
	n := len(expanded)
	testing.expect_value(t, h.total_count, i64(n))
	for milli in TEST_PERCENTILES {
		rank := model_rank(milli, n)
		exact := expanded[rank - 1]
		got := value_at_percentile(h, f64(milli) / 1000)
		if milli == 0 {
			want := model_bucket_low(exact)
			testing.expectf(t, got == want, "%v percentile 0: got %d, bucket start of exact %d is %d", kind, got, exact, want)
			testing.expectf(t, got <= exact && (exact - got) * 100 <= exact, "%v percentile 0: %d is not within two digits below exact %d", kind, got, exact)
		} else {
			want := model_bucket_high(exact)
			testing.expectf(t, got == want, "%v percentile %d/1000: got %d, bucket end of exact %d is %d", kind, milli, got, exact, want)
			testing.expectf(t, got >= exact && (got - exact) * 100 <= exact, "%v percentile %d/1000: %d is not within two digits above exact %d", kind, milli, got, exact)
		}
	}
	lowest_seen := expanded[0]
	highest_seen := expanded[n - 1]
	testing.expect_value(t, min_value(h), model_bucket_low(lowest_seen))
	testing.expect_value(t, max_value(h), model_bucket_high(highest_seen))
	testing.expect(t, min_value(h) <= lowest_seen && (lowest_seen - min_value(h)) * 100 <= lowest_seen)
	testing.expect(t, max_value(h) >= highest_seen && (max_value(h) - highest_seen) * 100 <= highest_seen)
	testing.expect_value(t, value_at_percentile(h, 100), max_value(h))
}

@(test)
uniform_percentiles_match_sorted_values :: proc(t: ^testing.T) {
	check_distribution(t, .Uniform, 0x1001, false)
}

@(test)
exponential_percentiles_match_sorted_values :: proc(t: ^testing.T) {
	check_distribution(t, .Exponential, 0x2002, false)
}

@(test)
clustered_percentiles_match_sorted_values :: proc(t: ^testing.T) {
	check_distribution(t, .Clustered, 0x3003, false)
}

@(test)
log_uniform_percentiles_match_sorted_values :: proc(t: ^testing.T) {
	check_distribution(t, .Log_Uniform, 0x4004, false)
}

@(test)
weighted_records_match_sorted_values :: proc(t: ^testing.T) {
	check_distribution(t, .Clustered, 0x5005, true)
	check_distribution(t, .Exponential, 0x6006, true)
}

@(test)
percentile_above_one_hundred_is_the_maximum :: proc(t: ^testing.T) {
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	for v in ([?]i64{3, 90, 4000, 123456}) {
		record_value(h, v)
	}
	testing.expect_value(t, value_at_percentile(h, 250), value_at_percentile(h, 100))
	testing.expect_value(t, value_at_percentile(h, 100), max_value(h))
}

@(test)
layout_matches_two_digit_configuration :: proc(t: ^testing.T) {
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	testing.expect(t, h != nil)
	testing.expect_value(t, h.lowest_discernible_value, TEST_LOWEST)
	testing.expect_value(t, h.highest_trackable_value, TEST_HIGHEST)
	testing.expect_value(t, h.significant_figures, TEST_DIGITS)
	testing.expect_value(t, h.unit_magnitude, 0)
	testing.expect_value(t, h.sub_bucket_count, 256)
	testing.expect_value(t, h.sub_bucket_half_count, 128)
	testing.expect_value(t, h.bucket_count, 23)
	testing.expect_value(t, h.counts_len, 24 * 128)
	testing.expect_value(t, len(h.counts), 24 * 128)
	testing.expect_value(t, h.total_count, 0)
	testing.expect_value(t, min_value(h), max(i64))
	testing.expect_value(t, max_value(h), 0)
}

@(test)
invalid_configurations_are_rejected :: proc(t: ^testing.T) {
	testing.expect(t, init(0, TEST_HIGHEST, 2) == nil)
	testing.expect(t, init(-5, TEST_HIGHEST, 2) == nil)
	testing.expect(t, init(1, TEST_HIGHEST, 0) == nil)
	testing.expect(t, init(1, TEST_HIGHEST, 6) == nil)
	testing.expect(t, init(1, 1, 2) == nil)
	testing.expect(t, init(600, 1000, 2) == nil)
	close(nil)
}

@(test)
empty_histogram_reports_nothing :: proc(t: ^testing.T) {
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	testing.expect_value(t, h.total_count, 0)
	testing.expect_value(t, min_value(h), max(i64))
	testing.expect_value(t, max_value(h), 0)
	for milli in TEST_PERCENTILES {
		testing.expect_value(t, value_at_percentile(h, f64(milli) / 1000), 0)
	}
}

@(test)
small_values_report_exact_minimum_and_maximum :: proc(t: ^testing.T) {
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	for v in ([?]i64{17, 200, 5}) {
		testing.expect(t, record_value(h, v))
	}
	testing.expect_value(t, h.total_count, 3)
	testing.expect_value(t, min_value(h), 5)
	testing.expect_value(t, max_value(h), 200)
	testing.expect_value(t, value_at_percentile(h, 0), 5)
	testing.expect_value(t, value_at_percentile(h, 50), 17)
	testing.expect_value(t, value_at_percentile(h, 100), 200)
	testing.expect(t, record_value(h, 0))
	testing.expect_value(t, h.total_count, 4)
	testing.expect_value(t, min_value(h), 0)
	testing.expect_value(t, max_value(h), 200)
}

@(test)
large_values_report_bucket_bounds_for_minimum_and_maximum :: proc(t: ^testing.T) {
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	testing.expect(t, record_value(h, 123_456_789))
	testing.expect(t, record_value(h, 70_000))
	testing.expect_value(t, min_value(h), 69_632)
	testing.expect_value(t, max_value(h), 123_731_967)
	testing.expect_value(t, value_at_percentile(h, 0), 69_632)
	testing.expect_value(t, value_at_percentile(h, 50), 70_143)
	testing.expect_value(t, value_at_percentile(h, 100), 123_731_967)
}

@(test)
out_of_range_values_follow_the_record_contract :: proc(t: ^testing.T) {
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)

	testing.expect(t, !record_value(h, -1))
	testing.expect(t, !record_values(h, min(i64), 4))
	testing.expect_value(t, h.total_count, 0)
	testing.expect_value(t, max_value(h), 0)
	testing.expect_value(t, min_value(h), max(i64))

	testing.expect(t, record_value(h, 0))
	testing.expect_value(t, h.total_count, 1)
	testing.expect_value(t, count_at_index(h, 0), 1)
	testing.expect_value(t, min_value(h), 0)

	testing.expect(t, record_value(h, TEST_HIGHEST))
	testing.expect_value(t, h.total_count, 2)
	testing.expect_value(t, max_value(h), model_bucket_high(TEST_HIGHEST))

	last_covered := (i64(h.sub_bucket_count) << u64(h.bucket_count - 1)) - 1
	testing.expect_value(t, last_covered, 1_073_741_823)
	testing.expect(t, record_value(h, TEST_HIGHEST + 1))
	testing.expect(t, record_value(h, last_covered))
	testing.expect_value(t, h.total_count, 4)
	testing.expect_value(t, max_value(h), last_covered)

	for beyond in ([?]i64{last_covered + 1, 2_000_000_000, 9_000_000_000_000_000_000, max(i64)}) {
		testing.expectf(t, !record_value(h, beyond), "value %d beyond the last bucket was accepted", beyond)
	}
	testing.expect_value(t, h.total_count, 4)
	testing.expect_value(t, max_value(h), last_covered)
	testing.expect_value(t, min_value(h), 0)
	sum: i64 = 0
	for i in 0 ..< h.counts_len {
		sum += count_at_index(h, i)
	}
	testing.expect_value(t, sum, 4)
}

@(test)
clamped_values_are_counted_at_the_limits :: proc(t: ^testing.T) {
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	inputs := [?]i64{-50, -1, 0, 1, 2, TEST_HIGHEST, TEST_HIGHEST + 1, 5_000_000_000, max(i64)}
	for v in inputs {
		clamped := clamp(v, h.lowest_discernible_value, h.highest_trackable_value)
		testing.expectf(t, record_value(h, clamped), "clamped value %d from input %d was rejected", clamped, v)
	}
	testing.expect_value(t, h.total_count, i64(len(inputs)))
	testing.expect_value(t, min_value(h), TEST_LOWEST)
	testing.expect_value(t, count_at_index(h, counts_index_for(h, TEST_LOWEST)), 4)
	testing.expect_value(t, count_at_index(h, counts_index_for(h, TEST_HIGHEST)), 4)
	testing.expect_value(t, count_at_index(h, counts_index_for(h, 2)), 1)
	testing.expect_value(t, max_value(h), model_bucket_high(TEST_HIGHEST))
	testing.expect(t, max_value(h) >= TEST_HIGHEST && (max_value(h) - TEST_HIGHEST) * 100 <= TEST_HIGHEST)
	testing.expect_value(t, value_at_percentile(h, 100), max_value(h))
	testing.expect_value(t, value_at_percentile(h, 0), TEST_LOWEST)
}

@(test)
values_below_a_larger_lowest_value_are_still_counted :: proc(t: ^testing.T) {
	h := init(1000, 1_000_000, 2)
	defer close(h)
	testing.expect(t, h != nil)
	for v in ([?]i64{1, 250, 999, 1000}) {
		testing.expectf(t, record_value(h, v), "value %d below or at the lowest discernible value was rejected", v)
	}
	testing.expect_value(t, h.total_count, 4)
	sum: i64 = 0
	for i in 0 ..< h.counts_len {
		sum += count_at_index(h, i)
	}
	testing.expect_value(t, sum, 4)
}

@(test)
reset_returns_to_the_empty_state :: proc(t: ^testing.T) {
	values := test_generate(.Clustered, 0x7007, TEST_COUNT)
	defer delete(values)
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	for v in values {
		record_value(h, v)
	}
	record_value(h, 0)
	testing.expect_value(t, h.total_count, TEST_COUNT + 1)
	size_before := memory_size(h)
	len_before := h.counts_len

	reset(h)
	testing.expect_value(t, h.total_count, 0)
	testing.expect_value(t, min_value(h), max(i64))
	testing.expect_value(t, max_value(h), 0)
	testing.expect_value(t, memory_size(h), size_before)
	testing.expect_value(t, h.counts_len, len_before)
	for i in 0 ..< h.counts_len {
		if count_at_index(h, i) != 0 {
			testing.expectf(t, false, "count at index %d survived reset", i)
			break
		}
	}
	for milli in TEST_PERCENTILES {
		testing.expect_value(t, value_at_percentile(h, f64(milli) / 1000), 0)
	}

	testing.expect(t, record_value(h, 9))
	testing.expect(t, record_value(h, 7))
	testing.expect_value(t, h.total_count, 2)
	testing.expect_value(t, min_value(h), 7)
	testing.expect_value(t, max_value(h), 9)
	testing.expect_value(t, value_at_percentile(h, 50), 7)
	testing.expect_value(t, value_at_percentile(h, 100), 9)
}

@(test)
recording_allocates_nothing :: proc(t: ^testing.T) {
	values := test_generate(.Log_Uniform, 0x8008, TEST_COUNT)
	defer delete(values)
	h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
	defer close(h)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		for v in values {
			record_value(h, v)
			record_values(h, v, 3)
		}
		record_value(h, 0)
		record_value(h, -1)
		record_value(h, max(i64))
		record_values(h, TEST_HIGHEST + 1, 2)
		value_at_percentile(h, 99.9)
		min_value(h)
		max_value(h)
		reset(h)
		record_value(h, 42)
	}
	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, track.total_memory_allocated, 0)
	testing.expect_value(t, track.total_free_count, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, h.total_count, 1)
}

@(test)
memory_is_fixed_when_the_histogram_is_created :: proc(t: ^testing.T) {
	values := test_generate(.Uniform, 0x9009, TEST_COUNT)
	defer delete(values)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		h := init(TEST_LOWEST, TEST_HIGHEST, TEST_DIGITS)
		testing.expect_value(t, track.total_allocation_count, 2)
		testing.expect_value(t, track.total_memory_allocated, i64(memory_size(h)))
		testing.expect_value(t, memory_size(h), size_of(Histogram) + int(h.counts_len) * size_of(i64))
		testing.expect(t, memory_size(h) < 32 * 1024)
		for v in values {
			record_value(h, v)
		}
		reset(h)
		for v in values {
			record_values(h, v, 2)
		}
		testing.expect_value(t, track.total_allocation_count, 2)
		testing.expect_value(t, track.total_memory_allocated, i64(memory_size(h)))
		testing.expect_value(t, track.current_memory_allocated, i64(memory_size(h)))
		close(h)
	}
	testing.expect_value(t, track.total_free_count, 2)
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

package hdr

import "base:intrinsics"
import "core:math"

Histogram :: struct {
	lowest_discernible_value:        i64,
	highest_trackable_value:         i64,
	unit_magnitude:                  i32,
	significant_figures:             i32,
	sub_bucket_half_count_magnitude: i32,
	sub_bucket_half_count:           i32,
	sub_bucket_mask:                 i64,
	sub_bucket_count:                i32,
	bucket_count:                    i32,
	min_value:                       i64,
	max_value:                       i64,
	counts_len:                      i32,
	total_count:                     i64,
	counts:                          []i64,
}

Bucket_Config :: struct {
	lowest_discernible_value:        i64,
	highest_trackable_value:         i64,
	unit_magnitude:                  i32,
	significant_figures:             i32,
	sub_bucket_half_count_magnitude: i32,
	sub_bucket_half_count:           i32,
	sub_bucket_mask:                 i64,
	sub_bucket_count:                i32,
	bucket_count:                    i32,
	counts_len:                      i32,
}

Iter :: struct {
	h:                        ^Histogram,
	counts_index:             i32,
	total_count:              i64,
	count:                    i64,
	cumulative_count:         i64,
	value:                    i64,
	highest_equivalent_value: i64,
	lowest_equivalent_value:  i64,
	median_equivalent_value:  i64,
	value_iterated_from:      i64,
	value_iterated_to:        i64,
	log_base:                 f64,
	next_level:               i64,
	next_level_lowest:        i64,
	added_in_step:            i64,
	logarithmic:              bool,
}

@(private = "file")
count_leading_zeros :: #force_inline proc "contextless" (v: i64) -> i32 {
	return i32(intrinsics.count_leading_zeros(u64(v)))
}

@(private = "file")
bucket_index_of :: #force_inline proc "contextless" (h: ^Histogram, value: i64) -> i32 {
	pow2ceiling := 64 - count_leading_zeros(value | h.sub_bucket_mask)
	return pow2ceiling - h.unit_magnitude - (h.sub_bucket_half_count_magnitude + 1)
}

@(private = "file")
sub_bucket_index_of :: #force_inline proc "contextless" (value: i64, bucket_index: i32, unit_magnitude: i32) -> i32 {
	return i32(value >> u64(bucket_index + unit_magnitude))
}

@(private = "file")
counts_index :: #force_inline proc "contextless" (h: ^Histogram, bucket_index: i32, sub_bucket_index: i32) -> i32 {
	bucket_base_index := (bucket_index + 1) << u32(h.sub_bucket_half_count_magnitude)
	offset_in_bucket := sub_bucket_index - h.sub_bucket_half_count
	return bucket_base_index + offset_in_bucket
}

@(private = "file")
value_from_index :: #force_inline proc "contextless" (bucket_index: i32, sub_bucket_index: i32, unit_magnitude: i32) -> i64 {
	return i64(sub_bucket_index) << u64(bucket_index + unit_magnitude)
}

counts_index_for :: proc "contextless" (h: ^Histogram, value: i64) -> i32 {
	bucket_index := bucket_index_of(h, value)
	sub_bucket_index := sub_bucket_index_of(value, bucket_index, h.unit_magnitude)
	return counts_index(h, bucket_index, sub_bucket_index)
}

value_at_index :: proc "contextless" (h: ^Histogram, index: i32) -> i64 {
	bucket_index := (index >> u32(h.sub_bucket_half_count_magnitude)) - 1
	sub_bucket_index := (index & (h.sub_bucket_half_count - 1)) + h.sub_bucket_half_count
	if bucket_index < 0 {
		sub_bucket_index -= h.sub_bucket_half_count
		bucket_index = 0
	}
	return value_from_index(bucket_index, sub_bucket_index, h.unit_magnitude)
}

size_of_equivalent_value_range :: proc "contextless" (h: ^Histogram, value: i64) -> i64 {
	bucket_index := bucket_index_of(h, value)
	sub_bucket_index := sub_bucket_index_of(value, bucket_index, h.unit_magnitude)
	adjusted_bucket := bucket_index + 1 if sub_bucket_index >= h.sub_bucket_count else bucket_index
	return i64(1) << u64(h.unit_magnitude + adjusted_bucket)
}

@(private = "file")
size_of_range_given_indices :: proc "contextless" (h: ^Histogram, bucket_index: i32, sub_bucket_index: i32) -> i64 {
	adjusted_bucket := bucket_index + 1 if sub_bucket_index >= h.sub_bucket_count else bucket_index
	return i64(1) << u64(h.unit_magnitude + adjusted_bucket)
}

lowest_equivalent_value :: proc "contextless" (h: ^Histogram, value: i64) -> i64 {
	bucket_index := bucket_index_of(h, value)
	sub_bucket_index := sub_bucket_index_of(value, bucket_index, h.unit_magnitude)
	return value_from_index(bucket_index, sub_bucket_index, h.unit_magnitude)
}

next_non_equivalent_value :: proc "contextless" (h: ^Histogram, value: i64) -> i64 {
	return lowest_equivalent_value(h, value) + size_of_equivalent_value_range(h, value)
}

highest_equivalent_value :: proc "contextless" (h: ^Histogram, value: i64) -> i64 {
	return next_non_equivalent_value(h, value) - 1
}

@(private = "file")
buckets_needed_to_cover_value :: proc "contextless" (value: i64, sub_bucket_count: i32, unit_magnitude: i32) -> i32 {
	smallest_untrackable_value := i64(sub_bucket_count) << u64(unit_magnitude)
	buckets_needed: i32 = 1
	for smallest_untrackable_value <= value {
		if smallest_untrackable_value > max(i64) / 2 {
			return buckets_needed + 1
		}
		smallest_untrackable_value <<= 1
		buckets_needed += 1
	}
	return buckets_needed
}

calculate_bucket_config :: proc(lowest_discernible_value: i64, highest_trackable_value: i64, significant_figures: i32) -> (cfg: Bucket_Config, ok: bool) {
	if lowest_discernible_value < 1 || significant_figures < 1 || 5 < significant_figures || lowest_discernible_value * 2 > highest_trackable_value {
		return
	}
	cfg.lowest_discernible_value = lowest_discernible_value
	cfg.significant_figures = significant_figures
	cfg.highest_trackable_value = highest_trackable_value
	largest_value_with_single_unit_resolution := 2 * i64(math.pow(10, f64(significant_figures)))
	sub_bucket_count_magnitude := i32(math.ceil(math.ln(f64(largest_value_with_single_unit_resolution)) / math.ln(f64(2))))
	cfg.sub_bucket_half_count_magnitude = (sub_bucket_count_magnitude if sub_bucket_count_magnitude > 1 else 1) - 1
	unit_magnitude := math.ln(f64(lowest_discernible_value)) / math.ln(f64(2))
	if f64(max(i32)) < unit_magnitude {
		return
	}
	cfg.unit_magnitude = i32(unit_magnitude)
	cfg.sub_bucket_count = i32(math.pow(2, f64(cfg.sub_bucket_half_count_magnitude + 1)))
	cfg.sub_bucket_half_count = cfg.sub_bucket_count / 2
	cfg.sub_bucket_mask = (i64(cfg.sub_bucket_count) - 1) << u64(cfg.unit_magnitude)
	if cfg.unit_magnitude + cfg.sub_bucket_half_count_magnitude > 61 {
		return
	}
	cfg.bucket_count = buckets_needed_to_cover_value(highest_trackable_value, cfg.sub_bucket_count, cfg.unit_magnitude)
	cfg.counts_len = (cfg.bucket_count + 1) * (cfg.sub_bucket_count / 2)
	return cfg, true
}

init :: proc(lowest_discernible_value: i64, highest_trackable_value: i64, significant_figures: i32) -> ^Histogram {
	cfg, ok := calculate_bucket_config(lowest_discernible_value, highest_trackable_value, significant_figures)
	if !ok {
		return nil
	}
	h := new(Histogram)
	h.counts = make([]i64, int(cfg.counts_len))
	h.lowest_discernible_value = cfg.lowest_discernible_value
	h.highest_trackable_value = cfg.highest_trackable_value
	h.unit_magnitude = cfg.unit_magnitude
	h.significant_figures = cfg.significant_figures
	h.sub_bucket_half_count_magnitude = cfg.sub_bucket_half_count_magnitude
	h.sub_bucket_half_count = cfg.sub_bucket_half_count
	h.sub_bucket_mask = cfg.sub_bucket_mask
	h.sub_bucket_count = cfg.sub_bucket_count
	h.min_value = max(i64)
	h.max_value = 0
	h.bucket_count = cfg.bucket_count
	h.counts_len = cfg.counts_len
	h.total_count = 0
	return h
}

close :: proc(h: ^Histogram) {
	if h != nil {
		delete(h.counts)
		free(h)
	}
}

reset :: proc(h: ^Histogram) {
	h.total_count = 0
	h.min_value = max(i64)
	h.max_value = 0
	for &v in h.counts {
		v = 0
	}
}

memory_size :: proc "contextless" (h: ^Histogram) -> int {
	return size_of(Histogram) + int(h.counts_len) * size_of(i64)
}

record_values :: proc "contextless" (h: ^Histogram, value: i64, count: i64) -> bool #no_bounds_check {
	if value < 0 {
		return false
	}
	idx := counts_index_for(h, value)
	if idx < 0 || h.counts_len <= idx {
		return false
	}
	h.counts[idx] += count
	h.total_count += count
	if value < h.min_value && value != 0 {
		h.min_value = value
	}
	if value > h.max_value {
		h.max_value = value
	}
	return true
}

record_value :: #force_inline proc "contextless" (h: ^Histogram, value: i64) -> bool {
	return record_values(h, value, 1)
}

max_value :: proc "contextless" (h: ^Histogram) -> i64 {
	if h.max_value == 0 {
		return 0
	}
	return highest_equivalent_value(h, h.max_value)
}

min_value :: proc "contextless" (h: ^Histogram) -> i64 {
	if h.counts_len > 0 && h.counts[0] > 0 {
		return 0
	}
	if h.min_value == max(i64) {
		return max(i64)
	}
	return lowest_equivalent_value(h, h.min_value)
}

@(private = "file")
value_from_idx_up_to_count :: proc "contextless" (h: ^Histogram, count_at_percentile: i64) -> i64 #no_bounds_check {
	count_to_idx: i64 = 0
	target := count_at_percentile if count_at_percentile > 0 else 1
	for idx: i32 = 0; idx < h.counts_len; idx += 1 {
		count_to_idx += h.counts[idx]
		if count_to_idx >= target {
			return value_at_index(h, idx)
		}
	}
	return 0
}

value_at_percentile :: proc "contextless" (h: ^Histogram, percentile: f64) -> i64 {
	requested := percentile if percentile < 100.0 else 100.0
	count_at_percentile := i64(((requested / 100) * f64(h.total_count)) + 0.5)
	value_from_idx := value_from_idx_up_to_count(h, count_at_percentile)
	if percentile == 0.0 {
		return lowest_equivalent_value(h, value_from_idx)
	}
	return highest_equivalent_value(h, value_from_idx)
}

count_at_index :: proc "contextless" (h: ^Histogram, index: i32) -> i64 {
	return h.counts[index]
}

@(private = "file")
move_next :: proc "contextless" (it: ^Iter) -> bool #no_bounds_check {
	it.counts_index += 1
	if it.counts_index >= it.h.counts_len {
		return false
	}
	it.count = it.h.counts[it.counts_index]
	it.cumulative_count += it.count
	value := value_at_index(it.h, it.counts_index)
	bucket_index := bucket_index_of(it.h, value)
	sub_bucket_index := sub_bucket_index_of(value, bucket_index, it.h.unit_magnitude)
	leq := value_from_index(bucket_index, sub_bucket_index, it.h.unit_magnitude)
	size := size_of_range_given_indices(it.h, bucket_index, sub_bucket_index)
	it.lowest_equivalent_value = leq
	it.value = value
	it.highest_equivalent_value = leq + size - 1
	it.median_equivalent_value = leq + (size >> 1)
	return true
}

@(private = "file")
next_value_greater_than_reporting_level_upper_bound :: proc "contextless" (it: ^Iter, upper_bound: i64) -> bool {
	if it.counts_index >= it.h.counts_len {
		return false
	}
	return value_at_index(it.h, it.counts_index + 1) > upper_bound
}

iter_init :: proc "contextless" (it: ^Iter, h: ^Histogram) {
	it^ = {}
	it.h = h
	it.counts_index = -1
	it.total_count = h.total_count
}

iter_log_init :: proc "contextless" (it: ^Iter, h: ^Histogram, value_units_first_bucket: i64, log_base: f64) {
	iter_init(it, h)
	it.logarithmic = true
	it.log_base = log_base
	it.next_level = value_units_first_bucket
	it.next_level_lowest = lowest_equivalent_value(h, value_units_first_bucket)
}

@(private = "file")
log_iter_next :: proc "contextless" (it: ^Iter) -> bool {
	it.added_in_step = 0
	if it.cumulative_count < it.total_count || next_value_greater_than_reporting_level_upper_bound(it, it.next_level_lowest) {
		for {
			if it.value >= it.next_level_lowest {
				it.value_iterated_from = it.value_iterated_to
				it.value_iterated_to = it.next_level
				it.next_level *= i64(it.log_base)
				it.next_level_lowest = lowest_equivalent_value(it.h, it.next_level)
				return true
			}
			if !move_next(it) {
				return true
			}
			it.added_in_step += it.count
		}
	}
	return false
}

iter_next :: proc "contextless" (it: ^Iter) -> bool {
	if it.logarithmic {
		return log_iter_next(it)
	}
	ok := move_next(it)
	if ok {
		it.value_iterated_from = it.value_iterated_to
		it.value_iterated_to = it.value
	}
	return ok
}

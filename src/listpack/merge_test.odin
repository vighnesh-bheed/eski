package listpack

import "core:testing"

@(test)
merge_storage_kernel_preserves_left_to_right_values_for_either_target :: proc(t: ^testing.T) {
	for target in 0..<2 {
		for empty in 0..<3 {
			left_entries := []Entry{entry_from_bytes(transmute([]u8)string("left")), entry_from_int(min(i64))}
			right_entries := []Entry{entry_from_bytes(nil), entry_from_bytes(transmute([]u8)string("right")), entry_from_int(4096)}
			expected := []string{"left", "-9223372036854775808", "", "right", "4096"}
			if empty == 1 {
				left_entries = nil
				expected = expected[2:]
			} else if empty == 2 {
				right_entries = nil
				expected = expected[:2]
			}
			first, second := test_pack(left_entries), test_pack(right_entries)
			result := merge_packs(first, second, target == 0)
			expect_values(t, result, expected)
			lp_free(result)
		}
	}
}

@(test)
merge_recounts_unknown_sources_and_selects_owner_using_logical_size :: proc(t: ^testing.T) {
	for unknown_side in 0..<3 {
		left := api_observed_pack()
		right := api_observed_pack()
		if unknown_side != 1 {
			lp_set_num_elements(left, LP_HDR_NUMELE_UNKNOWN)
		}
		if unknown_side != 0 {
			lp_set_num_elements(right, LP_HDR_NUMELE_UNKNOWN)
		}
		result := lp_merge(&left, &right)
		testing.expect(t, result == left && right == nil && lp_get_num_elements(result) == 12)
		testing.expect(t, lp_validate_integrity(result, u64(lp_bytes(result)), true, nil, nil))
		lp_free(result)
	}
	left := lp_new(8192)
	left = lp_append_integer(left, 1)
	right := lp_new(0)
	right = lp_append(right, transmute([]u8)string("longer"))
	testing.expect(t, lp_malloc_size(left) > lp_malloc_size(right) && lp_bytes(left) < lp_bytes(right))
	result := lp_merge(&left, &right)
	testing.expect(t, left == nil && right == result)
	expect_values(t, result, []string{"1", "longer"})
	lp_free(result)
}

@(test)
merge_releases_reserved_capacity_of_either_surviving_handle :: proc(t: ^testing.T) {
	for survivor in 0..<2 {
		left_value := "left-longer" if survivor == 0 else "A"
		right_value := "B" if survivor == 0 else "right-longer"
		left := lp_new(4096 if survivor == 0 else 0)
		right := lp_new(4096 if survivor == 1 else 0)
		left = lp_append(left, transmute([]u8)left_value)
		right = lp_append(right, transmute([]u8)right_value)
		reserved := lp_malloc_size(left if survivor == 0 else right)
		result := lp_merge(&left, &right)
		testing.expect(t, result != nil)
		if result == nil {
			lp_free(left)
			lp_free(right)
			continue
		}
		reference := lp_dup(result)
		testing.expect(t, lp_malloc_size(result) < reserved && lp_malloc_size(result) == lp_malloc_size(reference))
		testing.expect(t, left == result && right == nil if survivor == 0 else right == result && left == nil)
		expect_values(t, result, []string{left_value, right_value})
		lp_free(reference)
		lp_free(result)
	}
}

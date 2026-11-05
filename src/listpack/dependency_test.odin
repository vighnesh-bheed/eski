package listpack

import "core:testing"

header_dependent_pack :: proc() -> [^]u8 {
	entries: [255]Element
	for _, index in entries {
		entries[index] = entry_from_bytes(nil)
	}
	lp := test_pack(entries[:])
	lp[PACK_HEADER_BYTES + 1] = 129
	return lp
}

@(test)
header_dependent_backlen_is_repaired_only_after_dependency_breaks :: proc(t: ^testing.T) {
	lp := header_dependent_pack()
	defer lp_free(lp)
	testing.expect(t, lp_validate_integrity(lp, u64(lp_bytes(lp)), true, nil, nil))
	old_lp := lp
	old_capacity := lp_malloc_size(lp)
	lp = lp_append_entries(lp, nil)
	testing.expect(t, lp == old_lp && lp_malloc_size(lp) == old_capacity && lp[7] == 129)
	cursor: [^]u8
	lp = lp_insert_integer(lp, 17, padd(lp, lp_bytes(lp) - 1), Placement.Before, &cursor)
	testing.expect(t, lp_get_num_elements(lp) == 256 && lp[7] == 1)
	testing.expect(t, cursor == lp_last(lp) && lp_get_entry(cursor).number == 17)
	testing.expect(t, lp_get_entry(lp_first(lp)).text != nil && lp_get_entry(lp_first(lp)).text_len == 0)
	testing.expect(t, lp_validate_integrity(lp, u64(lp_bytes(lp)), true, nil, nil))
	for index := 255; index >= 0; index -= 1 {
		testing.expect(t, cursor == lp_seek(lp, i64(index)))
		cursor = lp_prev(lp, cursor)
	}
	testing.expect(t, cursor == nil)
	independent := [10]u8{10, 0, 0, 0, 1, 0, 192, 0, 130, 255}
	nonminimal := lp_malloc(len(independent))
	copy(nonminimal[:len(independent)], independent[:])
	nonminimal = lp_append_integer(nonminimal, 1)
	testing.expect(t, nonminimal[6] == 192 && nonminimal[7] == 0 && nonminimal[8] == 130)
	testing.expect(t, lp_validate_integrity(nonminimal, u64(lp_bytes(nonminimal)), true, nil, nil))
	lp_free(nonminimal)
}

@(test)
merge_repairs_header_dependency_from_either_source_without_changing_values :: proc(t: ^testing.T) {
	for dependent_side in 0..<2 {
		left, right := header_dependent_pack(), test_pack([]Element{entry_from_int(5)})
		if dependent_side == 1 {
			left, right = right, left
		}
		result := lp_merge(&left, &right)
		testing.expect(t, result != nil && lp_length(result) == 256)
		testing.expect(t, lp_validate_integrity(result, u64(lp_bytes(result)), true, nil, nil))
		if dependent_side == 0 {
			testing.expect(t, left == result && right == nil && result[7] == 1)
			testing.expect(t, lp_get_entry(lp_last(result)).text == nil && lp_get_entry(lp_last(result)).number == 5)
		} else {
			testing.expect(t, right == result && left == nil)
			testing.expect(t, lp_get_entry(lp_first(result)).text == nil && lp_get_entry(lp_first(result)).number == 5)
			p := lp_seek(result, 1)
			testing.expect(t, p[0] == 128 && p[1] == 1)
		}
		lp_free(result)
	}
}

@(test)
prepending_relocates_header_dependency_and_restores_reverse_traversal :: proc(t: ^testing.T) {
	lp := header_dependent_pack()
	defer lp_free(lp)
	lp = lp_prepend_integer(lp, 5)
	testing.expect(t, lp_validate_integrity(lp, u64(lp_bytes(lp)), true, nil, nil))
	p := lp_seek(lp, 1)
	testing.expect(t, p[0] == 128 && p[1] == 1 && lp_prev(lp, p) == lp_first(lp))
}

package listpack

import "core:testing"

@(test)
capacity_hints_do_not_change_empty_serialization :: proc(t: ^testing.T) {
	capacities := []int{-100, -1, 0, 1, 7, 8, 64}
	for capacity in capacities {
		lp := lp_new(capacity)
		testing.expect(t, lp != nil)
		if lp == nil {
			continue
		}
		testing.expect(t, lp_bytes(lp) == 7 && lp_get_num_elements(lp) == 0 && lp_malloc_size(lp) >= max(7, capacity))
		expected := [7]u8{7, 0, 0, 0, 0, 0, 255}
		for byte, index in expected {
			testing.expect(t, lp[index] == byte)
		}
		duplicate := lp_dup(lp)
		testing.expect(t, duplicate != nil && duplicate != lp)
		if duplicate != nil {
			testing.expect(t, string(lp_view(duplicate)) == string(lp_view(lp)))
			lp_free(duplicate)
		}
		lp = lp_shrink_to_fit(lp)
		testing.expect(t, lp != nil && lp_bytes(lp) == 7 && lp_malloc_size(lp) >= 7)
		lp_free(lp)
	}
}

@(test)
signed_safety_deltas_are_checked_mathematically :: proc(t: ^testing.T) {
	lp := lp_new(0)
	defer lp_free(lp)
	Fixture :: struct {
		delta: int,
		nil_result: bool,
		pack_result: bool,
	}
	fixtures := []Fixture{
		{min(int), false, false},
		{-8, false, false},
		{-7, false, true},
		{-1, false, true},
		{0, true, true},
		{1, true, true},
		{LISTPACK_MAX_SAFETY_SIZE - 7, true, true},
		{LISTPACK_MAX_SAFETY_SIZE - 6, true, false},
		{LISTPACK_MAX_SAFETY_SIZE, true, false},
		{LISTPACK_MAX_SAFETY_SIZE + 1, false, false},
		{max(int), false, false},
	}
	for fixture in fixtures {
		testing.expect(t, lp_safe_to_add(nil, fixture.delta) == fixture.nil_result)
		testing.expect(t, lp_safe_to_add(lp, fixture.delta) == fixture.pack_result)
	}
	before := lp_bytes(lp)
	testing.expect(t, lp_safe_to_add(lp, -before) && lp_bytes(lp) == before)
}

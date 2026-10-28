package listpack

import "core:testing"

@(test)
comparison_and_find_keep_numeric_adoption_strict_and_stride_relative :: proc(t: ^testing.T) {
	entries := []Entry{entry_from_int(1), entry_from_bytes(transmute([]u8)string("01")), entry_from_int(2), entry_from_bytes(nil), entry_from_int(1)}
	lp := test_pack(entries)
	defer lp_free(lp)
	testing.expect(t, lp_compare(lp_first(lp), transmute([]u8)string("1")))
	for spelling in ([]string{"01", "+1", " 1", "1\x00", "1.0"}) {
		testing.expect(t, !lp_compare(lp_first(lp), transmute([]u8)spelling))
	}
	testing.expect(t, lp_compare(lp_seek(lp, 1), transmute([]u8)string("01")))
	testing.expect(t, !lp_compare(lp_seek(lp, 1), transmute([]u8)string("1")))
	testing.expect(t, lp_find(lp, lp_seek(lp, 1), transmute([]u8)string("1"), 0) == lp_seek(lp, 4))
	testing.expect(t, lp_find(lp, lp_seek(lp, 1), transmute([]u8)string("1"), 1) == nil)
	testing.expect(t, lp_find(lp, lp_first(lp), nil, 2) == lp_seek(lp, 3))
	testing.expect(t, lp_find(lp, lp_first(lp), nil, max(u32)) == nil)
	for value in ([]i64{0, -4096, 4096, min(i64), max(i64)}) {
		for count in ([]u64{0, 1, 10, 65536}) {
			testing.expect(t, lp_estimate_bytes_repeated_integer(value, count) == 7 + lp_entry_size_integer(value) * int(count))
		}
	}
}

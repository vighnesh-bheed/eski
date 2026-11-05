package settype

import "core:testing"

@(test)
observed_store_encodings :: proc(t: ^testing.T) {
	old_int, old_pack, old_value := set_max_intset_entries, set_max_listpack_entries, set_max_listpack_value
	defer {
		set_max_intset_entries, set_max_listpack_entries, set_max_listpack_value = old_int, old_pack, old_value
	}
	cases := []struct {
		label, operation, relation: string,
		left_encoding, right_encoding, result_encoding: Encoding,
		left, right, expected: []string,
		imax, lmax, vmax: int,
	} {
		{"integer-union-overlap-compact", "union", "overlap", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"31", "32", "33", "34", "35"}, 512, 128, 64},
		{"integer-union-overlap-small", "union", "overlap", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34", "35", "32", "31"}, 2, 2, 8},
		{"integer-union-overlap-table", "union", "overlap", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"34", "33", "35", "32", "31"}, 0, 0, 8},
		{"integer-inter-overlap-compact", "inter", "overlap", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34"}, 512, 128, 64},
		{"integer-inter-overlap-small", "inter", "overlap", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34"}, 2, 2, 8},
		{"integer-inter-overlap-table", "inter", "overlap", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34"}, 0, 0, 8},
		{"integer-diff-overlap-compact", "diff", "overlap", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"31", "32"}, 512, 128, 64},
		{"integer-diff-overlap-small", "diff", "overlap", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"31", "32"}, 2, 2, 8},
		{"integer-diff-overlap-table", "diff", "overlap", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"32", "31"}, 0, 0, 8},
		{"integer-union-disjoint-compact", "union", "disjoint", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"37", "38"}, {"31", "32", "33", "34", "37", "38"}, 512, 128, 64},
		{"integer-union-disjoint-small", "union", "disjoint", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"37", "38"}, {"33", "34", "37", "38", "32", "31"}, 2, 2, 8},
		{"integer-union-disjoint-table", "union", "disjoint", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"37", "38"}, {"34", "33", "37", "38", "32", "31"}, 0, 0, 8},
		{"integer-inter-disjoint-compact", "inter", "disjoint", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"37", "38"}, {}, 512, 128, 64},
		{"integer-inter-disjoint-small", "inter", "disjoint", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"37", "38"}, {}, 2, 2, 8},
		{"integer-inter-disjoint-table", "inter", "disjoint", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"37", "38"}, {}, 0, 0, 8},
		{"integer-diff-disjoint-compact", "diff", "disjoint", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"37", "38"}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"integer-diff-disjoint-small", "diff", "disjoint", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"37", "38"}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"integer-diff-disjoint-table", "diff", "disjoint", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"37", "38"}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"integer-union-empty-left-compact", "union", "empty-left", .Intset, .Intset, .Intset, {}, {"33", "34", "35"}, {"33", "34", "35"}, 512, 128, 64},
		{"integer-union-empty-left-small", "union", "empty-left", .Intset, .Intset, .Hashtable, {}, {"33", "34", "35"}, {"33", "34", "35"}, 2, 2, 8},
		{"integer-union-empty-left-table", "union", "empty-left", .Intset, .Intset, .Hashtable, {}, {"33", "34", "35"}, {"33", "34", "35"}, 0, 0, 8},
		{"integer-inter-empty-left-compact", "inter", "empty-left", .Intset, .Intset, .Intset, {}, {"33", "34", "35"}, {}, 512, 128, 64},
		{"integer-inter-empty-left-small", "inter", "empty-left", .Intset, .Intset, .Intset, {}, {"33", "34", "35"}, {}, 2, 2, 8},
		{"integer-inter-empty-left-table", "inter", "empty-left", .Intset, .Intset, .Intset, {}, {"33", "34", "35"}, {}, 0, 0, 8},
		{"integer-diff-empty-left-compact", "diff", "empty-left", .Intset, .Intset, .Intset, {}, {"33", "34", "35"}, {}, 512, 128, 64},
		{"integer-diff-empty-left-small", "diff", "empty-left", .Intset, .Intset, .Intset, {}, {"33", "34", "35"}, {}, 2, 2, 8},
		{"integer-diff-empty-left-table", "diff", "empty-left", .Intset, .Intset, .Intset, {}, {"33", "34", "35"}, {}, 0, 0, 8},
		{"integer-union-empty-right-compact", "union", "empty-right", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"integer-union-empty-right-small", "union", "empty-right", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"integer-union-empty-right-table", "union", "empty-right", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"integer-inter-empty-right-compact", "inter", "empty-right", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {}, {}, 512, 128, 64},
		{"integer-inter-empty-right-small", "inter", "empty-right", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {}, {}, 2, 2, 8},
		{"integer-inter-empty-right-table", "inter", "empty-right", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {}, {}, 0, 0, 8},
		{"integer-diff-empty-right-compact", "diff", "empty-right", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"integer-diff-empty-right-small", "diff", "empty-right", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"integer-diff-empty-right-table", "diff", "empty-right", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"integer-union-repeat-compact", "union", "repeat", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"integer-union-repeat-small", "union", "repeat", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"integer-union-repeat-table", "union", "repeat", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"integer-inter-repeat-compact", "inter", "repeat", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"integer-inter-repeat-small", "inter", "repeat", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"integer-inter-repeat-table", "inter", "repeat", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"integer-diff-repeat-compact", "diff", "repeat", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {}, 512, 128, 64},
		{"integer-diff-repeat-small", "diff", "repeat", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {}, 2, 2, 8},
		{"integer-diff-repeat-table", "diff", "repeat", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {}, 0, 0, 8},
		{"integer-union-repeat-and-other-compact", "union", "repeat-and-other", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"31", "32", "33", "34", "35"}, 512, 128, 64},
		{"integer-union-repeat-and-other-small", "union", "repeat-and-other", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34", "35", "32", "31"}, 2, 2, 8},
		{"integer-union-repeat-and-other-table", "union", "repeat-and-other", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"34", "33", "35", "32", "31"}, 0, 0, 8},
		{"integer-inter-repeat-and-other-compact", "inter", "repeat-and-other", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34"}, 512, 128, 64},
		{"integer-inter-repeat-and-other-small", "inter", "repeat-and-other", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34"}, 2, 2, 8},
		{"integer-inter-repeat-and-other-table", "inter", "repeat-and-other", .Intset, .Intset, .Hashtable, {"31", "32", "33", "34"}, {"33", "34", "35"}, {"33", "34"}, 0, 0, 8},
		{"integer-diff-repeat-and-other-compact", "diff", "repeat-and-other", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {}, 512, 128, 64},
		{"integer-diff-repeat-and-other-small", "diff", "repeat-and-other", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {}, 2, 2, 8},
		{"integer-diff-repeat-and-other-table", "diff", "repeat-and-other", .Intset, .Intset, .Intset, {"31", "32", "33", "34"}, {"33", "34", "35"}, {}, 0, 0, 8},
		{"right-mixed-union-overlap-compact", "union", "overlap", .Intset, .Listpack, .Listpack, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"31", "32", "33", "34", "78", "79"}, 512, 128, 64},
		{"right-mixed-union-overlap-small", "union", "overlap", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"33", "34", "78", "79", "32", "31"}, 2, 2, 8},
		{"right-mixed-union-overlap-table", "union", "overlap", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"34", "33", "78", "79", "32", "31"}, 0, 0, 8},
		{"right-mixed-inter-overlap-compact", "inter", "overlap", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"32"}, 512, 128, 64},
		{"right-mixed-inter-overlap-small", "inter", "overlap", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"32"}, 2, 2, 8},
		{"right-mixed-inter-overlap-table", "inter", "overlap", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"32"}, 0, 0, 8},
		{"right-mixed-diff-overlap-compact", "diff", "overlap", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"31", "33", "34"}, 512, 128, 64},
		{"right-mixed-diff-overlap-small", "diff", "overlap", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"33", "34", "31"}, 2, 2, 8},
		{"right-mixed-diff-overlap-table", "diff", "overlap", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"33", "34", "31"}, 0, 0, 8},
		{"right-mixed-union-disjoint-compact", "union", "disjoint", .Intset, .Listpack, .Listpack, {"31", "32", "33", "34"}, {"79", "7a"}, {"31", "32", "33", "34", "79", "7a"}, 512, 128, 64},
		{"right-mixed-union-disjoint-small", "union", "disjoint", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"79", "7a"}, {"33", "34", "79", "7a", "32", "31"}, 2, 2, 8},
		{"right-mixed-union-disjoint-table", "union", "disjoint", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"79", "7a"}, {"34", "33", "79", "7a", "32", "31"}, 0, 0, 8},
		{"right-mixed-inter-disjoint-compact", "inter", "disjoint", .Intset, .Listpack, .Listpack, {"31", "32", "33", "34"}, {"79", "7a"}, {}, 512, 128, 64},
		{"right-mixed-inter-disjoint-small", "inter", "disjoint", .Intset, .Listpack, .Listpack, {"31", "32", "33", "34"}, {"79", "7a"}, {}, 2, 2, 8},
		{"right-mixed-inter-disjoint-table", "inter", "disjoint", .Intset, .Listpack, .Listpack, {"31", "32", "33", "34"}, {"79", "7a"}, {}, 0, 0, 8},
		{"right-mixed-diff-disjoint-compact", "diff", "disjoint", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"79", "7a"}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"right-mixed-diff-disjoint-small", "diff", "disjoint", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"79", "7a"}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"right-mixed-diff-disjoint-table", "diff", "disjoint", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"79", "7a"}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"right-mixed-union-empty-left-compact", "union", "empty-left", .Intset, .Listpack, .Listpack, {}, {"32", "78", "79"}, {"32", "78", "79"}, 512, 128, 64},
		{"right-mixed-union-empty-left-small", "union", "empty-left", .Intset, .Listpack, .Hashtable, {}, {"32", "78", "79"}, {"79", "32", "78"}, 2, 2, 8},
		{"right-mixed-union-empty-left-table", "union", "empty-left", .Intset, .Listpack, .Hashtable, {}, {"32", "78", "79"}, {"79", "32", "78"}, 0, 0, 8},
		{"right-mixed-inter-empty-left-compact", "inter", "empty-left", .Intset, .Listpack, .Intset, {}, {"32", "78", "79"}, {}, 512, 128, 64},
		{"right-mixed-inter-empty-left-small", "inter", "empty-left", .Intset, .Listpack, .Intset, {}, {"32", "78", "79"}, {}, 2, 2, 8},
		{"right-mixed-inter-empty-left-table", "inter", "empty-left", .Intset, .Listpack, .Intset, {}, {"32", "78", "79"}, {}, 0, 0, 8},
		{"right-mixed-diff-empty-left-compact", "diff", "empty-left", .Intset, .Listpack, .Intset, {}, {"32", "78", "79"}, {}, 512, 128, 64},
		{"right-mixed-diff-empty-left-small", "diff", "empty-left", .Intset, .Listpack, .Intset, {}, {"32", "78", "79"}, {}, 2, 2, 8},
		{"right-mixed-diff-empty-left-table", "diff", "empty-left", .Intset, .Listpack, .Intset, {}, {"32", "78", "79"}, {}, 0, 0, 8},
		{"right-mixed-union-empty-right-compact", "union", "empty-right", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"right-mixed-union-empty-right-small", "union", "empty-right", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"right-mixed-union-empty-right-table", "union", "empty-right", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"right-mixed-inter-empty-right-compact", "inter", "empty-right", .Intset, .Listpack, .Listpack, {"31", "32", "33", "34"}, {}, {}, 512, 128, 64},
		{"right-mixed-inter-empty-right-small", "inter", "empty-right", .Intset, .Listpack, .Listpack, {"31", "32", "33", "34"}, {}, {}, 2, 2, 8},
		{"right-mixed-inter-empty-right-table", "inter", "empty-right", .Intset, .Listpack, .Listpack, {"31", "32", "33", "34"}, {}, {}, 0, 0, 8},
		{"right-mixed-diff-empty-right-compact", "diff", "empty-right", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"right-mixed-diff-empty-right-small", "diff", "empty-right", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"right-mixed-diff-empty-right-table", "diff", "empty-right", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"right-mixed-union-repeat-compact", "union", "repeat", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"right-mixed-union-repeat-small", "union", "repeat", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"right-mixed-union-repeat-table", "union", "repeat", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"right-mixed-inter-repeat-compact", "inter", "repeat", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"31", "32", "33", "34"}, 512, 128, 64},
		{"right-mixed-inter-repeat-small", "inter", "repeat", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"33", "34", "32", "31"}, 2, 2, 8},
		{"right-mixed-inter-repeat-table", "inter", "repeat", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"34", "33", "32", "31"}, 0, 0, 8},
		{"right-mixed-diff-repeat-compact", "diff", "repeat", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {}, 512, 128, 64},
		{"right-mixed-diff-repeat-small", "diff", "repeat", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {}, 2, 2, 8},
		{"right-mixed-diff-repeat-table", "diff", "repeat", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {}, 0, 0, 8},
		{"right-mixed-union-repeat-and-other-compact", "union", "repeat-and-other", .Intset, .Listpack, .Listpack, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"31", "32", "33", "34", "78", "79"}, 512, 128, 64},
		{"right-mixed-union-repeat-and-other-small", "union", "repeat-and-other", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"33", "34", "78", "79", "32", "31"}, 2, 2, 8},
		{"right-mixed-union-repeat-and-other-table", "union", "repeat-and-other", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"34", "33", "78", "79", "32", "31"}, 0, 0, 8},
		{"right-mixed-inter-repeat-and-other-compact", "inter", "repeat-and-other", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"32"}, 512, 128, 64},
		{"right-mixed-inter-repeat-and-other-small", "inter", "repeat-and-other", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"32"}, 2, 2, 8},
		{"right-mixed-inter-repeat-and-other-table", "inter", "repeat-and-other", .Intset, .Listpack, .Hashtable, {"31", "32", "33", "34"}, {"32", "78", "79"}, {"32"}, 0, 0, 8},
		{"right-mixed-diff-repeat-and-other-compact", "diff", "repeat-and-other", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {}, 512, 128, 64},
		{"right-mixed-diff-repeat-and-other-small", "diff", "repeat-and-other", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {}, 2, 2, 8},
		{"right-mixed-diff-repeat-and-other-table", "diff", "repeat-and-other", .Intset, .Listpack, .Intset, {"31", "32", "33", "34"}, {"32", "78", "79"}, {}, 0, 0, 8},
		{"mixed-union-overlap-compact", "union", "overlap", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "32", "78", "", "79"}, 512, 128, 64},
		{"mixed-union-overlap-small", "union", "overlap", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "78", "79", "", "32"}, 2, 2, 8},
		{"mixed-union-overlap-table", "union", "overlap", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "78", "79", "", "32"}, 0, 0, 8},
		{"mixed-inter-overlap-compact", "inter", "overlap", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"32", "78"}, 512, 128, 64},
		{"mixed-inter-overlap-small", "inter", "overlap", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"32", "78"}, 2, 2, 8},
		{"mixed-inter-overlap-table", "inter", "overlap", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"32", "78"}, 0, 0, 8},
		{"mixed-diff-overlap-compact", "diff", "overlap", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", ""}, 512, 128, 64},
		{"mixed-diff-overlap-small", "diff", "overlap", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", ""}, 2, 2, 8},
		{"mixed-diff-overlap-table", "diff", "overlap", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"", "31"}, 0, 0, 8},
		{"mixed-union-disjoint-compact", "union", "disjoint", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"79", "7a"}, {"31", "32", "78", "", "79", "7a"}, 512, 128, 64},
		{"mixed-union-disjoint-small", "union", "disjoint", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"79", "7a"}, {"31", "78", "79", "7a", "", "32"}, 2, 2, 8},
		{"mixed-union-disjoint-table", "union", "disjoint", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"79", "7a"}, {"31", "78", "79", "7a", "", "32"}, 0, 0, 8},
		{"mixed-inter-disjoint-compact", "inter", "disjoint", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"79", "7a"}, {}, 512, 128, 64},
		{"mixed-inter-disjoint-small", "inter", "disjoint", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"79", "7a"}, {}, 2, 2, 8},
		{"mixed-inter-disjoint-table", "inter", "disjoint", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"79", "7a"}, {}, 0, 0, 8},
		{"mixed-diff-disjoint-compact", "diff", "disjoint", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"79", "7a"}, {"31", "32", "78", ""}, 512, 128, 64},
		{"mixed-diff-disjoint-small", "diff", "disjoint", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"79", "7a"}, {"31", "78", "", "32"}, 2, 2, 8},
		{"mixed-diff-disjoint-table", "diff", "disjoint", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"79", "7a"}, {"31", "78", "", "32"}, 0, 0, 8},
		{"mixed-union-empty-left-compact", "union", "empty-left", .Listpack, .Listpack, .Listpack, {}, {"32", "78", "79"}, {"32", "78", "79"}, 512, 128, 64},
		{"mixed-union-empty-left-small", "union", "empty-left", .Listpack, .Listpack, .Hashtable, {}, {"32", "78", "79"}, {"79", "32", "78"}, 2, 2, 8},
		{"mixed-union-empty-left-table", "union", "empty-left", .Listpack, .Listpack, .Hashtable, {}, {"32", "78", "79"}, {"79", "32", "78"}, 0, 0, 8},
		{"mixed-inter-empty-left-compact", "inter", "empty-left", .Listpack, .Listpack, .Listpack, {}, {"32", "78", "79"}, {}, 512, 128, 64},
		{"mixed-inter-empty-left-small", "inter", "empty-left", .Listpack, .Listpack, .Listpack, {}, {"32", "78", "79"}, {}, 2, 2, 8},
		{"mixed-inter-empty-left-table", "inter", "empty-left", .Listpack, .Listpack, .Listpack, {}, {"32", "78", "79"}, {}, 0, 0, 8},
		{"mixed-diff-empty-left-compact", "diff", "empty-left", .Listpack, .Listpack, .Intset, {}, {"32", "78", "79"}, {}, 512, 128, 64},
		{"mixed-diff-empty-left-small", "diff", "empty-left", .Listpack, .Listpack, .Intset, {}, {"32", "78", "79"}, {}, 2, 2, 8},
		{"mixed-diff-empty-left-table", "diff", "empty-left", .Listpack, .Listpack, .Intset, {}, {"32", "78", "79"}, {}, 0, 0, 8},
		{"mixed-union-empty-right-compact", "union", "empty-right", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {}, {"31", "32", "78", ""}, 512, 128, 64},
		{"mixed-union-empty-right-small", "union", "empty-right", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {}, {"31", "78", "", "32"}, 2, 2, 8},
		{"mixed-union-empty-right-table", "union", "empty-right", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {}, {"31", "78", "", "32"}, 0, 0, 8},
		{"mixed-inter-empty-right-compact", "inter", "empty-right", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {}, {}, 512, 128, 64},
		{"mixed-inter-empty-right-small", "inter", "empty-right", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {}, {}, 2, 2, 8},
		{"mixed-inter-empty-right-table", "inter", "empty-right", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {}, {}, 0, 0, 8},
		{"mixed-diff-empty-right-compact", "diff", "empty-right", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {}, {"31", "32", "78", ""}, 512, 128, 64},
		{"mixed-diff-empty-right-small", "diff", "empty-right", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {}, {"31", "78", "", "32"}, 2, 2, 8},
		{"mixed-diff-empty-right-table", "diff", "empty-right", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {}, {"31", "78", "", "32"}, 0, 0, 8},
		{"mixed-union-repeat-compact", "union", "repeat", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "32", "78", ""}, 512, 128, 64},
		{"mixed-union-repeat-small", "union", "repeat", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "78", "", "32"}, 2, 2, 8},
		{"mixed-union-repeat-table", "union", "repeat", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "78", "", "32"}, 0, 0, 8},
		{"mixed-inter-repeat-compact", "inter", "repeat", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "32", "78", ""}, 512, 128, 64},
		{"mixed-inter-repeat-small", "inter", "repeat", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "78", "", "32"}, 2, 2, 8},
		{"mixed-inter-repeat-table", "inter", "repeat", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "78", "", "32"}, 0, 0, 8},
		{"mixed-diff-repeat-compact", "diff", "repeat", .Listpack, .Listpack, .Intset, {"31", "32", "78", ""}, {"32", "78", "79"}, {}, 512, 128, 64},
		{"mixed-diff-repeat-small", "diff", "repeat", .Listpack, .Listpack, .Intset, {"31", "32", "78", ""}, {"32", "78", "79"}, {}, 2, 2, 8},
		{"mixed-diff-repeat-table", "diff", "repeat", .Listpack, .Listpack, .Intset, {"31", "32", "78", ""}, {"32", "78", "79"}, {}, 0, 0, 8},
		{"mixed-union-repeat-and-other-compact", "union", "repeat-and-other", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "32", "78", "", "79"}, 512, 128, 64},
		{"mixed-union-repeat-and-other-small", "union", "repeat-and-other", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "78", "79", "", "32"}, 2, 2, 8},
		{"mixed-union-repeat-and-other-table", "union", "repeat-and-other", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"31", "78", "79", "", "32"}, 0, 0, 8},
		{"mixed-inter-repeat-and-other-compact", "inter", "repeat-and-other", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"32", "78"}, 512, 128, 64},
		{"mixed-inter-repeat-and-other-small", "inter", "repeat-and-other", .Listpack, .Listpack, .Listpack, {"31", "32", "78", ""}, {"32", "78", "79"}, {"32", "78"}, 2, 2, 8},
		{"mixed-inter-repeat-and-other-table", "inter", "repeat-and-other", .Listpack, .Listpack, .Hashtable, {"31", "32", "78", ""}, {"32", "78", "79"}, {"32", "78"}, 0, 0, 8},
		{"mixed-diff-repeat-and-other-compact", "diff", "repeat-and-other", .Listpack, .Listpack, .Intset, {"31", "32", "78", ""}, {"32", "78", "79"}, {}, 512, 128, 64},
		{"mixed-diff-repeat-and-other-small", "diff", "repeat-and-other", .Listpack, .Listpack, .Intset, {"31", "32", "78", ""}, {"32", "78", "79"}, {}, 2, 2, 8},
		{"mixed-diff-repeat-and-other-table", "diff", "repeat-and-other", .Listpack, .Listpack, .Intset, {"31", "32", "78", ""}, {"32", "78", "79"}, {}, 0, 0, 8},
	}
	for fixture in cases {
		set_max_intset_entries, set_max_listpack_entries, set_max_listpack_value = 512, 128, 64
		left, right := create_intset(), create_intset()
		for item in fixture.left {
			bytes := decode_hex(item)
			add(left, bytes)
			delete(bytes)
		}
		for item in fixture.right {
			bytes := decode_hex(item)
			add(right, bytes)
			delete(bytes)
		}
		if left.encoding != fixture.left_encoding {
			convert(left, fixture.left_encoding)
		}
		if right.encoding != fixture.right_encoding {
			convert(right, fixture.right_encoding)
		}
		set_max_intset_entries, set_max_listpack_entries, set_max_listpack_value = fixture.imax, fixture.lmax, fixture.vmax
		inputs := []Set{left, right}
		if fixture.relation == "repeat" {
			inputs = []Set{left, left}
		} else if fixture.relation == "repeat-and-other" {
			inputs = []Set{left, left, right}
		}
		result: Set
		if fixture.operation == "inter" {
			result = inter_store(inputs)
		} else {
			result = union_diff(inputs, .Union if fixture.operation == "union" else .Diff)
		}
		testing.expectf(t, result != left && result != right, "%s independent object", fixture.label)
		testing.expectf(t, result.encoding == fixture.result_encoding, "%s encoding expected %v got %v", fixture.label, fixture.result_encoding, result.encoding)
		testing.expectf(t, size(result) == len(fixture.expected), "%s cardinality", fixture.label)
		for item in fixture.expected {
			bytes := decode_hex(item)
			testing.expectf(t, is_member(result, bytes), "%s member %s", fixture.label, item)
			delete(bytes)
		}
		destroy(left)
		destroy(right)
		destroy(result)
	}
	release_pending_maintenance()
}

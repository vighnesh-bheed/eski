package vsettype

import "core:testing"

@(test)
basic_add_search_remove :: proc(t: ^testing.T) {
	s := new_set(t, 2)
	defer destroy(s)
	testing.expect(t, add_values(t, s, "a", {1, 0}))
	testing.expect(t, add_values(t, s, "b", {0, 1}))
	testing.expect(t, add_values(t, s, "c", {1, 1}))
	testing.expect(t, add_values(t, s, "d", {-1, 0}))
	testing.expect(t, !add_values(t, s, "a", {1, 0}))
	testing.expect_value(t, card(s), 4)
	check_invariants(t, s)
	req := Search_Request{kind = .Vector, vector = {1, 0}}
	hits: [dynamic]Hit
	defer delete(hits)
	f := search(s, &req, nil, &hits)
	testing.expect_value(t, f.err, Error.None)
	testing.expect_value(t, len(hits), 4)
	want := []string{"a", "c", "b", "d"}
	scores := []f64{1, 0.8535533845424652, 0.5, 0}
	for h, i in hits {
		testing.expectf(t, name_text(s, h.slot) == want[i], "position %d holds %s", i, name_text(s, h.slot))
		testing.expectf(t, h.score == scores[i], "position %d score %v", i, h.score)
	}
	removed, _, rf := remove(s, bytes_of("c"))
	testing.expect(t, removed && rf.err == .None)
	testing.expect_value(t, card(s), 3)
	check_invariants(t, s)
	blob, err := serialize_bytes(s)
	testing.expect_value(t, err, nil)
	defer delete(blob)
	back, derr := deserialize(blob)
	testing.expect_value(t, derr, Decode_Error.None)
	defer destroy(back)
	testing.expect_value(t, card(back), 3)
	check_invariants(t, back)
}

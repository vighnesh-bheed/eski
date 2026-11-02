package groups_test

import st "../../src/streamtype"
import "core:testing"

xdel :: proc(s: st.Stream, x: ..st.ID) -> int {
	return st.xdel_apply(s, x)
}

trim_maxlen :: proc(s: st.Stream, n: i64) -> i64 {
	a := st.Trim_Spec{rule = .Max_Len, max_len = n}
	return st.trim(s, &a)
}

trim_minid :: proc(s: st.Stream, x: st.ID) -> i64 {
	a := st.Trim_Spec{rule = .Min_Id, min_id = x}
	return st.trim(s, &a)
}

@(test)
lag_on_empty_streams_is_zero :: proc(t: ^testing.T) {
	s := st.create()
	defer st.destroy(s)
	g := st.add_group(s, b("g"), s.top, -1)
	g2 := st.add_group(s, b("g2"), id(0), 5)
	g5 := st.add_group(s, b("g5"), st.ID_MAX, -1)
	expect_lag(t, s, g, 0)
	expect_lag(t, s, g2, 0)
	expect_lag(t, s, g5, 0)
	expect_read(t, g, -1)
	add(t, s, 1)
	xdel(s, id(1))
	expect_lag(t, s, g, 0)
}

@(test)
lag_transitions_from_the_transcript :: proc(t: ^testing.T) {
	s := stream_1_to(t, 10)
	defer st.destroy(s)
	g := st.add_group(s, b("g"), id(0), -1)
	expect_read(t, g, -1)
	expect_lag(t, s, g, 10)
	alice := st.add_member(s, g, b("alice"), T0)
	bob := st.add_member(s, g, b("bob"), T0)
	deliver(s, g, alice, 3, false, T0)
	expect_read(t, g, 3)
	expect_lag(t, s, g, 7)
	deliver(s, g, bob, 2, false, T0)
	deliver(s, g, alice, 1, true, T0)
	testing.expect_value(t, g.delivered, id(6))
	expect_read(t, g, 6)
	expect_lag(t, s, g, 4)
	deliver(s, g, alice, 0, false, T0)
	expect_read(t, g, 10)
	expect_lag(t, s, g, 0)
	st.group_raise_last_id(g, id(20))
	testing.expect_value(t, g.delivered, id(20))
	expect_read(t, g, 10)
	expect_lag(t, s, g, 0)
	xdel(s, id(8))
	expect_lag(t, s, g, 0)
	st.group_set_id(g, id(0), -1)
	expect_read(t, g, -1)
	expect_lag_unknown(t, s, g)
	st.group_set_id(g, s.top, 3)
	expect_lag(t, s, g, 7)
	st.group_set_id(g, id(5), 100)
	expect_lag_unknown(t, s, g)
	h := st.add_group(s, b("h"), id(0), 3)
	expect_lag_unknown(t, s, h)
	c := st.add_member(s, h, b("c"), T0)
	deliver(s, h, c, 1, false, T0)
	expect_read(t, h, -1)
	expect_lag_unknown(t, s, h)
	testing.expect_value(t, trim_maxlen(s, 3), 6)
	expect_lag_unknown(t, s, h)
	k := st.add_group(s, b("k"), s.top, -1)
	add(t, s, 20)
	expect_lag_unknown(t, s, k)
	xdel(s, id(20))
	m := st.add_group(s, b("m"), id(0, 5), -1)
	expect_lag_unknown(t, s, m)
	expect_lag_unknown(t, s, k)
}

@(test)
lag_follows_first_entry_and_tombstones :: proc(t: ^testing.T) {
	s := stream_1_to(t, 5)
	defer st.destroy(s)
	xdel(s, id(3))
	g1 := st.add_group(s, b("g1"), id(0), -1)
	g2 := st.add_group(s, b("g2"), id(0), -1)
	expect_lag_unknown(t, s, g1)
	c := st.add_member(s, g1, b("c11"), T0)
	for want in ([]st.ID{id(1), id(2), id(4)}) {
		got := deliver(s, g1, c, 1, false, T0)
		testing.expect(t, same_ids(got, {want}))
		expect_read(t, g1, -1)
		expect_lag_unknown(t, s, g1)
	}
	deliver(s, g1, c, 1, false, T0)
	expect_read(t, g1, 5)
	expect_lag(t, s, g1, 0)
	add(t, s, 6)
	expect_lag(t, s, g1, 1)
	testing.expect_value(t, trim_minid(s, id(3)), 2)
	expect_lag(t, s, g1, 1)
	expect_lag(t, s, g2, 3)
	testing.expect_value(t, trim_minid(s, id(5)), 1)
	expect_lag(t, s, g2, 2)
}

@(test)
lag_after_deleting_the_entries_behind_the_group :: proc(t: ^testing.T) {
	s := st.create()
	defer st.destroy(s)
	g := st.add_group(s, b("g1"), s.top, -1)
	add(t, s, 1)
	alice := st.add_member(s, g, b("alice"), T0)
	deliver(s, g, alice, 0, false, T0)
	expect_read(t, g, 1)
	add(t, s, 2)
	add(t, s, 3)
	xdel(s, id(2))
	expect_read(t, g, 1)
	expect_lag_unknown(t, s, g)
	xdel(s, id(1))
	expect_lag(t, s, g, 1)
	deliver(s, g, alice, 0, false, T0)
	expect_read(t, g, 3)
	expect_lag(t, s, g, 0)
}

@(test)
lag_after_trimming_and_setid :: proc(t: ^testing.T) {
	s := st.create()
	defer st.destroy(s)
	g := st.add_group(s, b("mygroup"), s.top, -1)
	for i in 1 ..= u64(5) {
		add(t, s, i)
	}
	alice := st.add_member(s, g, b("alice"), T0)
	deliver(s, g, alice, 1, false, T0)
	expect_read(t, g, 1)
	expect_lag(t, s, g, 4)
	testing.expect_value(t, trim_maxlen(s, 1), 4)
	expect_lag(t, s, g, 1)
	deliver(s, g, alice, 0, false, T0)
	expect_read(t, g, 5)
	expect_lag(t, s, g, 0)
	add(t, s, 6)
	expect_lag(t, s, g, 1)
	testing.expect_value(t, trim_maxlen(s, 0), 2)
	expect_lag(t, s, g, 0)
	st.group_set_id(g, id(0), 0)
	expect_lag(t, s, g, 0)
	a := st.Setid_Args{id = id(9), entries_added = 20, max_deleted_id = id(8)}
	testing.expect_value(t, st.xsetid_apply(s, &a), st.Error.None)
	expect_lag(t, s, g, 0)
	add(t, s, 10)
	st.group_set_id(g, id(2), -1)
	expect_lag(t, s, g, 1)
	g9 := st.add_group(s, b("g9"), id(9), 19)
	g10 := st.add_group(s, b("g10"), id(10), -1)
	g11 := st.add_group(s, b("g11"), id(11), -1)
	expect_lag(t, s, g9, 1)
	expect_lag(t, s, g10, 0)
	expect_lag_unknown(t, s, g11)
	expect_read(t, g9, 19)
	expect_read(t, g10, -1)
}

@(test)
entries_read_recomputed_at_first_entry_and_incremented_after :: proc(t: ^testing.T) {
	s := st.create()
	defer st.destroy(s)
	for i in 1 ..= u64(14) {
		add(t, s, i)
	}
	xdel(s, id(3))
	testing.expect_value(t, trim_maxlen(s, 6), 7)
	g := st.add_group(s, b("g"), id(0), -1)
	c7 := st.add_member(s, g, b("c7"), T0)
	got := deliver(s, g, c7, 3, false, T0)
	testing.expect(t, same_ids(got, ids({9, 0}, {10, 0}, {11, 0})))
	expect_read(t, g, 11)
	st.group_set_id(g, id(5), 2)
	deliver(s, g, c7, 2, false, T0)
	testing.expect_value(t, g.delivered, id(10))
	expect_read(t, g, 10)
	expect_lag(t, s, g, 4)
}

@(test)
entries_read_increments_after_lastid_jump :: proc(t: ^testing.T) {
	s := stream_1_to(t, 20)
	defer st.destroy(s)
	g := st.add_group(s, b("g3"), id(0), -1)
	c := st.add_member(s, g, b(""), T0)
	deliver(s, g, c, 8, false, T0)
	expect_read(t, g, 8)
	st.group_raise_last_id(g, id(15))
	deliver(s, g, c, 0, false, T0)
	testing.expect_value(t, g.delivered, id(20))
	expect_read(t, g, 13)
}

distance :: proc(s: st.Stream, at: st.ID) -> i64 {
	reached, known := st.added_through(s, at)
	return reached if known else -1
}

@(test)
added_through_for_old_payloads :: proc(t: ^testing.T) {
	s := st.create()
	defer st.destroy(s)
	testing.expect_value(t, distance(s, id(0)), 0)
	for i in 1 ..= u64(5) {
		add(t, s, i)
	}
	testing.expect_value(t, distance(s, id(5)), 5)
	testing.expect_value(t, distance(s, id(0)), 0)
	testing.expect_value(t, distance(s, id(6)), -1)
	testing.expect_value(t, distance(s, id(3)), -1)
	testing.expect_value(t, distance(s, id(1)), 1)
	trim_maxlen(s, 2)
	testing.expect_value(t, distance(s, id(1)), 3)
	testing.expect_value(t, distance(s, id(4)), 4)
	testing.expect_value(t, distance(s, id(5)), 5)
	xdel(s, id(5))
	testing.expect_value(t, distance(s, id(1)), -1)
	testing.expect_value(t, distance(s, id(5)), 5)
}

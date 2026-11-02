package groups_test

import st "../../src/streamtype"
import "core:testing"

@(test)
consumer_lookup_or_create_and_delete :: proc(t: ^testing.T) {
	s := stream_1_to(t, 4)
	defer st.destroy(s)
	g := st.add_group(s, b("g"), id(0), -1)
	c, created := st.member_for(s, g, b("alice"), T0)
	testing.expect(t, created && c != nil && c.seen_ms == T0 && c.active_ms == -1)
	again, made := st.member_for(s, g, b("alice"), T0 + 9)
	testing.expect(t, !made && again == c && again.seen_ms == T0)
	deliver(s, g, c, 3, false, T0)
	testing.expect_value(t, st.drop_member(s, g, c), 3)
	testing.expect_value(t, g.pending.numele, 0)
	testing.expect(t, st.find_member(g, b("alice")) == nil)
	lag, known := st.group_lag(s, g)
	testing.expect(t, known && lag == 1)
}

@(test)
pel_history_and_touch :: proc(t: ^testing.T) {
	s := stream_1_to(t, 6)
	defer st.destroy(s)
	g := st.add_group(s, b("g"), id(0), -1)
	c := st.add_member(s, g, b("c"), T0)
	deliver(s, g, c, 5, false, T0)
	out := make([dynamic]st.ID, context.temp_allocator)
	st.pel_history(c, id(2), 0, &out)
	testing.expect(t, same_ids(out[:], ids({2, 0}, {3, 0}, {4, 0}, {5, 0})))
	clear(&out)
	st.pel_history(c, id(0), 2, &out)
	testing.expect(t, same_ids(out[:], ids({1, 0}, {2, 0})))
	clear(&out)
	st.pel_history(c, id(9), 0, &out)
	testing.expect_value(t, len(out), 0)
	st.pel_touch(c, id(3), T0 + 50)
	n := st.find_delivery(g, id(3))
	testing.expect(t, n.sent_ms == T0 + 50 && n.times == 2)
	st.pel_touch(c, id(6), T0 + 60)
	testing.expect(t, st.find_delivery(g, id(6)) == nil)
}

@(test)
claim_and_autoclaim_by_consumer_name :: proc(t: ^testing.T) {
	s := stream_1_to(t, 8)
	defer st.destroy(s)
	g := st.add_group(s, b("g"), id(0), -1)
	alice := st.add_member(s, g, b("alice"), T0)
	deliver(s, g, alice, 6, false, T0)
	xdel(s, id(5))
	now := T0 + 300
	a := st.Claim_Options{idle_floor = 200, tries = -1, stamp = -1, raise_to = id(20)}
	claimed := make([dynamic]st.ID, context.temp_allocator)
	st.claim(s, g, b("bob"), &a, ids({1, 0}, {5, 0}, {7, 0}, {2, 0}), now, &claimed)
	testing.expect(t, same_ids(claimed[:], ids({1, 0}, {2, 0})))
	bob := st.find_member(g, b("bob"))
	testing.expect(t, bob != nil && bob.seen_ms == now && bob.active_ms == now)
	testing.expect(t, st.find_delivery(g, id(5)) == nil)
	testing.expect_value(t, g.delivered, id(20))
	got := make([dynamic]st.ID, context.temp_allocator)
	gone := make([dynamic]st.ID, context.temp_allocator)
	xdel(s, id(4))
	next := st.autoclaim(s, g, b("carol"), 0, id(3), 2, true, now, &got, &gone)
	testing.expect_value(t, next, id(6))
	testing.expect(t, same_ids(got[:], ids({3, 0})))
	testing.expect(t, same_ids(gone[:], ids({4, 0})))
	testing.expect_value(t, st.find_delivery(g, id(3)).times, 1)
	carol := st.find_member(g, b("carol"))
	testing.expect(t, carol != nil && carol.owned.numele == 1)
	clear(&got)
	clear(&gone)
	next = st.autoclaim(s, g, b("carol"), 0, id(0), 100, false, now, &got, &gone)
	testing.expect_value(t, next, id(0))
	testing.expect(t, same_ids(got[:], ids({1, 0}, {2, 0}, {3, 0}, {6, 0})))
	testing.expect_value(t, len(gone), 0)
}

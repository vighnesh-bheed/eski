package groups_test

import st "../../src/streamtype"
import "core:testing"

@(test)
delivery_with_and_without_noack :: proc(t: ^testing.T) {
	s := stream_1_to(t, 6)
	defer st.destroy(s)
	g := st.add_group(s, b("g"), id(0), -1)
	a := st.add_member(s, g, b("a"), T0)
	bc := st.add_member(s, g, b("b"), T0)
	deliver(s, g, a, 2, false, T0 + 10)
	testing.expect_value(t, a.active_ms, T0 + 10)
	testing.expect_value(t, g.pending.stored, 2)
	got := deliver(s, g, bc, 1, true, T0 + 20)
	testing.expect(t, same_ids(got, ids({3, 0})))
	testing.expect_value(t, g.pending.stored, 2)
	testing.expect_value(t, bc.owned.stored, 0)
	testing.expect_value(t, bc.active_ms, -1)
	testing.expect_value(t, g.delivered, id(3))
	deliver(s, g, bc, 1, false, T0 + 30)
	testing.expect_value(t, bc.active_ms, T0 + 30)
	n := st.find_delivery(g, id(4))
	testing.expect(t, n.owner == bc && n.times == 1 && n.sent_ms == T0 + 30)
	st.group_set_id(g, id(0), -1)
	n1 := st.find_delivery(g, id(1))
	n1.times = 5
	deliver(s, g, bc, 1, false, T0 + 40)
	testing.expect(t, n1.owner == bc && n1.times == 1 && n1.sent_ms == T0 + 40)
	testing.expect(t, same_ids(pel_ids(a.owned), ids({2, 0})))
	testing.expect(t, same_ids(pel_ids(bc.owned), ids({1, 0}, {4, 0})))
	deliver(s, g, a, 1, true, T0 + 50)
	n2 := st.find_delivery(g, id(2))
	testing.expect(t, n2.owner == a && n2.sent_ms == T0 + 10)
	testing.expect_value(t, a.active_ms, T0 + 10)
}

@(test)
history_reads_see_deleted_entries :: proc(t: ^testing.T) {
	s := stream_1_to(t, 5)
	defer st.destroy(s)
	g := st.add_group(s, b("g"), id(0), -1)
	c := st.add_member(s, g, b("c2"), T0)
	deliver(s, g, c, 3, false, T0)
	xdel(s, id(1))
	live := make([dynamic]st.ID, context.temp_allocator)
	gone := make([dynamic]st.ID, context.temp_allocator)
	for x in pel_ids(c.owned) {
		if st.entry_exists(s, x) {
			append(&live, x)
		} else {
			append(&gone, x)
		}
	}
	testing.expect(t, same_ids(live[:], ids({2, 0}, {3, 0})))
	testing.expect(t, same_ids(gone[:], ids({1, 0})))
	testing.expect_value(t, c.owned.stored, 3)
	testing.expect(t, st.find_delivery(g, id(1)) != nil)
}

@(test)
claim_moves_idle_entries_and_honours_options :: proc(t: ^testing.T) {
	s := stream_1_to(t, 10)
	defer st.destroy(s)
	g := st.add_group(s, b("g"), id(0), -1)
	alice := st.add_member(s, g, b("alice"), T0)
	bob := st.add_member(s, g, b("bob"), T0)
	carol := st.add_member(s, g, b("carol"), T0)
	deliver(s, g, alice, 3, false, T0)
	deliver(s, g, bob, 3, false, T0)
	deliver(s, g, carol, 1, false, T0 + 302)
	now := T0 + 302
	a := claim_args(200)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(1), &a, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(7), &a, now), st.Claim_Result.Skipped)
	n1 := st.find_delivery(g, id(1))
	testing.expect(t, n1.owner == carol && n1.times == 2 && n1.sent_ms == now)
	testing.expect_value(t, carol.active_ms, now)
	testing.expect(t, same_ids(pel_ids(alice.owned), ids({2, 0}, {3, 0})))
	j := claim_args(0)
	j.flags += {.Ids_Only}
	testing.expect_value(t, st.claim_entry(s, g, carol, id(3), &j, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.find_delivery(g, id(3)).times, 1)
	r := claim_args(0)
	r.stamp = now - 5000
	r.tries = 9
	st.claim_entry(s, g, carol, id(4), &r, now)
	n4 := st.find_delivery(g, id(4))
	testing.expect(t, n4.times == 9 && n4.sent_ms == now - 5000)
	tm := claim_args(0)
	tm.stamp = 1000
	st.claim_entry(s, g, carol, id(5), &tm, now)
	testing.expect_value(t, st.find_delivery(g, id(5)).sent_ms, 1000)
	future := claim_args(0)
	future.stamp = 99999999999999
	st.claim_entry(s, g, carol, id(6), &future, now)
	testing.expect_value(t, st.find_delivery(g, id(6)).sent_ms, now)
	neg := claim_args(0)
	neg.stamp = now + 5
	st.claim_entry(s, g, carol, id(6), &neg, now)
	testing.expect_value(t, st.find_delivery(g, id(6)).sent_ms, now)
	testing.expect_value(t, st.find_delivery(g, id(6)).times, 3)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(8), &a, now), st.Claim_Result.Skipped)
	f := claim_args(0)
	f.flags += {.Force}
	testing.expect_value(t, st.claim_entry(s, g, carol, id(8), &f, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.find_delivery(g, id(8)).times, 2)
	fj := claim_args(0)
	fj.flags += {.Force}
	fj.flags += {.Ids_Only}
	testing.expect_value(t, st.claim_entry(s, g, carol, id(9), &fj, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.find_delivery(g, id(9)).times, 1)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(99), &fj, now), st.Claim_Result.Skipped)
	fi := claim_args(1000000)
	fi.flags += {.Force}
	testing.expect_value(t, st.claim_entry(s, g, carol, id(10), &fi, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(10), &fi, now), st.Claim_Result.Skipped)
	testing.expect(t, st.group_raise_last_id(g, id(50)))
	testing.expect(t, !st.group_raise_last_id(g, id(20)))
	testing.expect_value(t, g.delivered, id(50))
	xdel(s, id(2))
	testing.expect_value(t, st.claim_entry(s, g, bob, id(2), &j, now), st.Claim_Result.Deleted)
	testing.expect(t, st.find_delivery(g, id(2)) == nil)
	testing.expect_value(t, alice.owned.stored, 0)
	testing.expect_value(t, st.claim_entry(s, g, bob, id(2), &f, now), st.Claim_Result.Skipped)
	dup := claim_args(0)
	st.claim_entry(s, g, bob, id(1), &dup, now)
	st.claim_entry(s, g, bob, id(1), &dup, now)
	testing.expect_value(t, st.find_delivery(g, id(1)).times, 4)
	testing.expect(t, same_ids(pel_ids(bob.owned), ids({1, 0})))
	testing.expect_value(t, g.pending.stored, 9)
}

autoclaim :: proc(s: st.Stream, g: ^st.Group, c: ^st.Member, start: st.ID, count: i64, minidle: i64, justid: bool, now: i64) -> (next: st.ID, claimed: []st.ID, deleted: []st.ID) {
	a := st.Autoclaim_Args{minidle = minidle, start = start, count = count, justid = justid}
	steps := make([dynamic]st.Autoclaim_Step, context.temp_allocator)
	next = st.autoclaim_scan(s, g, c, &a, now, &steps)
	cl := make([dynamic]st.ID, context.temp_allocator)
	dl := make([dynamic]st.ID, context.temp_allocator)
	for step in steps {
		if step.result == .Claimed {
			append(&cl, step.id)
		} else {
			append(&dl, step.id)
		}
	}
	return next, cl[:], dl[:]
}

@(test)
autoclaim_scans_counts_and_reports_deleted :: proc(t: ^testing.T) {
	s := stream_1_to(t, 9)
	defer st.destroy(s)
	g := st.add_group(s, b("g"), id(0), -1)
	alice := st.add_member(s, g, b("alice"), T0)
	deliver(s, g, alice, 0, false, T0)
	frank := st.add_member(s, g, b("frank"), T0)
	now := T0 + 300
	next, cl, dl := autoclaim(s, g, frank, id(0), 2, 0, false, now)
	testing.expect_value(t, next, id(3))
	testing.expect(t, same_ids(cl, ids({1, 0}, {2, 0})) && len(dl) == 0)
	testing.expect_value(t, st.find_delivery(g, id(1)).times, 2)
	next, cl, dl = autoclaim(s, g, frank, id(5), 2, 0, true, now)
	testing.expect_value(t, next, id(7))
	testing.expect(t, same_ids(cl, ids({5, 0}, {6, 0})))
	testing.expect_value(t, st.find_delivery(g, id(5)).times, 1)
	testing.expect_value(t, st.find_delivery(g, id(5)).sent_ms, now)
	next, cl, dl = autoclaim(s, g, frank, id(0), 100, 99999999, false, now)
	testing.expect_value(t, next, id(0))
	testing.expect(t, len(cl) == 0 && len(dl) == 0)
	xdel(s, id(4), id(6))
	gina := st.add_member(s, g, b("gina"), T0)
	next, cl, dl = autoclaim(s, g, gina, id(3), 2, 0, false, now)
	testing.expect_value(t, next, id(5))
	testing.expect(t, same_ids(cl, ids({3, 0})))
	testing.expect(t, same_ids(dl, ids({4, 0})))
	testing.expect(t, st.find_delivery(g, id(4)) == nil)
	next, cl, dl = autoclaim(s, g, gina, id(0), 100000, 0, false, now)
	testing.expect_value(t, next, id(0))
	testing.expect(t, same_ids(cl, ids({1, 0}, {2, 0}, {3, 0}, {5, 0}, {7, 0}, {8, 0}, {9, 0})))
	testing.expect(t, same_ids(dl, ids({6, 0})))
	testing.expect_value(t, gina.owned.stored, 7)
	testing.expect_value(t, frank.owned.stored, 0)
	testing.expect_value(t, gina.active_ms, now)
}

@(test)
autoclaim_attempts_are_bounded_by_ten_times_count :: proc(t: ^testing.T) {
	s := stream_1_to(t, 30)
	defer st.destroy(s)
	g := st.add_group(s, b("g"), id(0), -1)
	c := st.add_member(s, g, b("c"), T0)
	deliver(s, g, c, 0, false, T0)
	for i in 1 ..= u64(25) {
		st.find_delivery(g, id(i)).sent_ms = T0 + 1000
	}
	next, cl, dl := autoclaim(s, g, c, id(0), 1, 500, false, T0 + 1000)
	testing.expect_value(t, next, id(11))
	testing.expect(t, len(cl) == 0 && len(dl) == 0)
	next, cl, dl = autoclaim(s, g, c, id(0), 3, 500, false, T0 + 1000)
	testing.expect_value(t, next, id(29))
	testing.expect(t, same_ids(cl, ids({26, 0}, {27, 0}, {28, 0})))
	next, cl, dl = autoclaim(s, g, c, id(0), st.AUTOCLAIM_MAX_COUNT, 0, true, T0 + 1000)
	testing.expect_value(t, next, id(0))
	testing.expect_value(t, len(cl), 30)
}

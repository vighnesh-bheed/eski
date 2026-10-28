package groups_test

import st "../../src/streamtype"
import "core:testing"

@(test)
delivery_with_and_without_noack :: proc(t: ^testing.T) {
	s := stream_1_to(t, 6)
	defer st.destroy(s)
	g := st.create_cg(s, b("g"), id(0), -1)
	a := st.create_consumer(s, g, b("a"), T0)
	bc := st.create_consumer(s, g, b("b"), T0)
	deliver(s, g, a, 2, false, T0 + 10)
	testing.expect_value(t, a.active_time, T0 + 10)
	testing.expect_value(t, g.pel.numele, 2)
	got := deliver(s, g, bc, 1, true, T0 + 20)
	testing.expect(t, same_ids(got, ids({3, 0})))
	testing.expect_value(t, g.pel.numele, 2)
	testing.expect_value(t, bc.pel.numele, 0)
	testing.expect_value(t, bc.active_time, -1)
	testing.expect_value(t, g.last_id, id(3))
	deliver(s, g, bc, 1, false, T0 + 30)
	testing.expect_value(t, bc.active_time, T0 + 30)
	n := st.lookup_nack(g, id(4))
	testing.expect(t, n.consumer == bc && n.delivery_count == 1 && n.delivery_time == T0 + 30)
	st.group_set_id(g, id(0), -1)
	n1 := st.lookup_nack(g, id(1))
	n1.delivery_count = 5
	deliver(s, g, bc, 1, false, T0 + 40)
	testing.expect(t, n1.consumer == bc && n1.delivery_count == 1 && n1.delivery_time == T0 + 40)
	testing.expect(t, same_ids(pel_ids(a.pel), ids({2, 0})))
	testing.expect(t, same_ids(pel_ids(bc.pel), ids({1, 0}, {4, 0})))
	deliver(s, g, a, 1, true, T0 + 50)
	n2 := st.lookup_nack(g, id(2))
	testing.expect(t, n2.consumer == a && n2.delivery_time == T0 + 10)
	testing.expect_value(t, a.active_time, T0 + 10)
}

@(test)
history_reads_see_deleted_entries :: proc(t: ^testing.T) {
	s := stream_1_to(t, 5)
	defer st.destroy(s)
	g := st.create_cg(s, b("g"), id(0), -1)
	c := st.create_consumer(s, g, b("c2"), T0)
	deliver(s, g, c, 3, false, T0)
	xdel(s, id(1))
	live := make([dynamic]st.ID, context.temp_allocator)
	gone := make([dynamic]st.ID, context.temp_allocator)
	for x in pel_ids(c.pel) {
		if st.entry_exists(s, x) {
			append(&live, x)
		} else {
			append(&gone, x)
		}
	}
	testing.expect(t, same_ids(live[:], ids({2, 0}, {3, 0})))
	testing.expect(t, same_ids(gone[:], ids({1, 0})))
	testing.expect_value(t, c.pel.numele, 3)
	testing.expect(t, st.lookup_nack(g, id(1)) != nil)
}

@(test)
claim_moves_idle_entries_and_honours_options :: proc(t: ^testing.T) {
	s := stream_1_to(t, 10)
	defer st.destroy(s)
	g := st.create_cg(s, b("g"), id(0), -1)
	alice := st.create_consumer(s, g, b("alice"), T0)
	bob := st.create_consumer(s, g, b("bob"), T0)
	carol := st.create_consumer(s, g, b("carol"), T0)
	deliver(s, g, alice, 3, false, T0)
	deliver(s, g, bob, 3, false, T0)
	deliver(s, g, carol, 1, false, T0 + 302)
	now := T0 + 302
	a := claim_args(200)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(1), &a, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(7), &a, now), st.Claim_Result.Skipped)
	n1 := st.lookup_nack(g, id(1))
	testing.expect(t, n1.consumer == carol && n1.delivery_count == 2 && n1.delivery_time == now)
	testing.expect_value(t, carol.active_time, now)
	testing.expect(t, same_ids(pel_ids(alice.pel), ids({2, 0}, {3, 0})))
	j := claim_args(0)
	j.justid = true
	testing.expect_value(t, st.claim_entry(s, g, carol, id(3), &j, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.lookup_nack(g, id(3)).delivery_count, 1)
	r := claim_args(0)
	r.deliverytime = now - 5000
	r.retrycount = 9
	st.claim_entry(s, g, carol, id(4), &r, now)
	n4 := st.lookup_nack(g, id(4))
	testing.expect(t, n4.delivery_count == 9 && n4.delivery_time == now - 5000)
	tm := claim_args(0)
	tm.deliverytime = 1000
	st.claim_entry(s, g, carol, id(5), &tm, now)
	testing.expect_value(t, st.lookup_nack(g, id(5)).delivery_time, 1000)
	future := claim_args(0)
	future.deliverytime = 99999999999999
	st.claim_entry(s, g, carol, id(6), &future, now)
	testing.expect_value(t, st.lookup_nack(g, id(6)).delivery_time, now)
	neg := claim_args(0)
	neg.deliverytime = now + 5
	st.claim_entry(s, g, carol, id(6), &neg, now)
	testing.expect_value(t, st.lookup_nack(g, id(6)).delivery_time, now)
	testing.expect_value(t, st.lookup_nack(g, id(6)).delivery_count, 3)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(8), &a, now), st.Claim_Result.Skipped)
	f := claim_args(0)
	f.force = true
	testing.expect_value(t, st.claim_entry(s, g, carol, id(8), &f, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.lookup_nack(g, id(8)).delivery_count, 2)
	fj := claim_args(0)
	fj.force = true
	fj.justid = true
	testing.expect_value(t, st.claim_entry(s, g, carol, id(9), &fj, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.lookup_nack(g, id(9)).delivery_count, 1)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(99), &fj, now), st.Claim_Result.Skipped)
	fi := claim_args(1000000)
	fi.force = true
	testing.expect_value(t, st.claim_entry(s, g, carol, id(10), &fi, now), st.Claim_Result.Claimed)
	testing.expect_value(t, st.claim_entry(s, g, carol, id(10), &fi, now), st.Claim_Result.Skipped)
	testing.expect(t, st.group_raise_last_id(g, id(50)))
	testing.expect(t, !st.group_raise_last_id(g, id(20)))
	testing.expect_value(t, g.last_id, id(50))
	xdel(s, id(2))
	testing.expect_value(t, st.claim_entry(s, g, bob, id(2), &j, now), st.Claim_Result.Deleted)
	testing.expect(t, st.lookup_nack(g, id(2)) == nil)
	testing.expect_value(t, alice.pel.numele, 0)
	testing.expect_value(t, st.claim_entry(s, g, bob, id(2), &f, now), st.Claim_Result.Skipped)
	dup := claim_args(0)
	st.claim_entry(s, g, bob, id(1), &dup, now)
	st.claim_entry(s, g, bob, id(1), &dup, now)
	testing.expect_value(t, st.lookup_nack(g, id(1)).delivery_count, 4)
	testing.expect(t, same_ids(pel_ids(bob.pel), ids({1, 0})))
	testing.expect_value(t, g.pel.numele, 9)
}

autoclaim :: proc(s: st.Stream, g: ^st.CG, c: ^st.Consumer, start: st.ID, count: i64, minidle: i64, justid: bool, now: i64) -> (next: st.ID, claimed: []st.ID, deleted: []st.ID) {
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
	g := st.create_cg(s, b("g"), id(0), -1)
	alice := st.create_consumer(s, g, b("alice"), T0)
	deliver(s, g, alice, 0, false, T0)
	frank := st.create_consumer(s, g, b("frank"), T0)
	now := T0 + 300
	next, cl, dl := autoclaim(s, g, frank, id(0), 2, 0, false, now)
	testing.expect_value(t, next, id(3))
	testing.expect(t, same_ids(cl, ids({1, 0}, {2, 0})) && len(dl) == 0)
	testing.expect_value(t, st.lookup_nack(g, id(1)).delivery_count, 2)
	next, cl, dl = autoclaim(s, g, frank, id(5), 2, 0, true, now)
	testing.expect_value(t, next, id(7))
	testing.expect(t, same_ids(cl, ids({5, 0}, {6, 0})))
	testing.expect_value(t, st.lookup_nack(g, id(5)).delivery_count, 1)
	testing.expect_value(t, st.lookup_nack(g, id(5)).delivery_time, now)
	next, cl, dl = autoclaim(s, g, frank, id(0), 100, 99999999, false, now)
	testing.expect_value(t, next, id(0))
	testing.expect(t, len(cl) == 0 && len(dl) == 0)
	xdel(s, id(4), id(6))
	gina := st.create_consumer(s, g, b("gina"), T0)
	next, cl, dl = autoclaim(s, g, gina, id(3), 2, 0, false, now)
	testing.expect_value(t, next, id(5))
	testing.expect(t, same_ids(cl, ids({3, 0})))
	testing.expect(t, same_ids(dl, ids({4, 0})))
	testing.expect(t, st.lookup_nack(g, id(4)) == nil)
	next, cl, dl = autoclaim(s, g, gina, id(0), 100000, 0, false, now)
	testing.expect_value(t, next, id(0))
	testing.expect(t, same_ids(cl, ids({1, 0}, {2, 0}, {3, 0}, {5, 0}, {7, 0}, {8, 0}, {9, 0})))
	testing.expect(t, same_ids(dl, ids({6, 0})))
	testing.expect_value(t, gina.pel.numele, 7)
	testing.expect_value(t, frank.pel.numele, 0)
	testing.expect_value(t, gina.active_time, now)
}

@(test)
autoclaim_attempts_are_bounded_by_ten_times_count :: proc(t: ^testing.T) {
	s := stream_1_to(t, 30)
	defer st.destroy(s)
	g := st.create_cg(s, b("g"), id(0), -1)
	c := st.create_consumer(s, g, b("c"), T0)
	deliver(s, g, c, 0, false, T0)
	for i in 1 ..= u64(25) {
		st.lookup_nack(g, id(i)).delivery_time = T0 + 1000
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

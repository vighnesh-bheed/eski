package hnsw

import "core:log"
import "core:testing"

Churn :: struct {
	p:     Points,
	ix:    Index,
	s:     Scratch,
	live:  [dynamic]u32,
	position: [dynamic]int,
}

churn_init :: proc(t: ^testing.T, c: ^Churn, dim: int, params: Params, expected: int) {
	points_init(&c.p, dim, true, expected)
	testing.expect_value(t, init(&c.ix, params, points_distance, &c.p, context.allocator), Error.None)
	scratch_init(&c.s, context.allocator)
	c.live = make([dynamic]u32, 0, expected)
	c.position = make([dynamic]int, 0, expected)
}

churn_destroy :: proc(c: ^Churn) {
	scratch_destroy(&c.s)
	destroy(&c.ix)
	points_destroy(&c.p)
	delete(c.live)
	delete(c.position)
}

churn_insert :: proc(t: ^testing.T, c: ^Churn, v: []f32) -> u32 {
	slot := add_point(t, &c.ix, &c.s, &c.p, v)
	if len(c.position) <= int(slot) {
		resize(&c.position, int(slot) + 1)
	}
	c.position[slot] = len(c.live)
	append(&c.live, slot)
	return slot
}

churn_delete :: proc(t: ^testing.T, c: ^Churn, at: int) {
	slot := c.live[at]
	testing.expect_value(t, remove(&c.ix, &c.s, slot), Error.None)
	last := c.live[len(c.live) - 1]
	c.live[at] = last
	c.position[last] = at
	pop(&c.live)
}

churn_run :: proc(t: ^testing.T, c: ^Churn, state: ^u64, inserts, deletes: int) {
	v := make([]f32, c.p.dim)
	defer delete(v)
	ri := inserts
	rd := deletes
	for ri + rd > 0 {
		del := rd > 0 && len(c.live) > 1 && (ri == 0 || int(rng_next(state) % u64(ri + rd)) < rd)
		if del {
			churn_delete(t, c, int(rng_next(state) % u64(len(c.live))))
			rd -= 1
		} else {
			random_unit(state, v)
			churn_insert(t, c, v)
			ri -= 1
		}
	}
}

self_queries :: proc(p: ^Points, slots: []u32, count: int) -> []f32 {
	q := make([]f32, count * p.dim)
	step := max(len(slots) / count, 1)
	for i in 0 ..< count {
		copy(q[i * p.dim:(i + 1) * p.dim], points_get(p, slots[(i * step) % len(slots)]))
	}
	return q
}

@(test)
connectivity_and_recall_after_inserts_and_deletes :: proc(t: ^testing.T) {
	dim :: 32
	c: Churn
	churn_init(t, &c, dim, test_params(16, 200, 0xDE1E7E), 20_000)
	defer churn_destroy(&c)
	state := u64(0x5EED_DE1E)
	churn_run(t, &c, &state, 20_000, 10_000)
	testing.expect_value(t, size(&c.ix), 10_000)
	testing.expect_value(t, info(&c.ix).max_node_uid, u64(20_000))
	check_graph(t, &c.ix)
	reached, present := reachable_at(&c.ix, 0)
	testing.expect_value(t, reached, present)
	testing.expect_value(t, present, 10_000)
	for l in 1 ..= c.ix.max_level {
		r, n := reachable_at(&c.ix, l)
		log.infof("after churn layer %d: %d of %d nodes reachable from the entry point", l, r, n)
	}
	fresh_q := make_queries(&state, RECALL_QUERIES, dim)
	defer delete(fresh_q)
	own_q := self_queries(&c.p, c.live[:], RECALL_QUERIES)
	defer delete(own_q)
	churned_fresh := measure_recall(&c.ix, &c.s, &c.p, fresh_q, RECALL_K, RECALL_EF)
	churned_own := measure_recall(&c.ix, &c.s, &c.p, own_q, RECALL_K, RECALL_EF)
	b: Churn
	churn_init(t, &b, dim, test_params(16, 200, 0xDE1E7E), 10_000)
	defer churn_destroy(&b)
	for slot in c.live {
		churn_insert(t, &b, points_get(&c.p, slot))
	}
	rebuilt_fresh := measure_recall(&b.ix, &b.s, &b.p, fresh_q, RECALL_K, RECALL_EF)
	rebuilt_own := measure_recall(&b.ix, &b.s, &b.p, own_q, RECALL_K, RECALL_EF)
	log.infof("after 20000 inserts and 10000 deletes: recall@10 %.4f fresh queries, %.4f stored queries; rebuilt from the survivors: %.4f and %.4f", churned_fresh, churned_own, rebuilt_fresh, rebuilt_own)
	testing.expectf(t, churned_fresh > 0.9, "recall after deletes %.4f must exceed 0.9", churned_fresh)
	testing.expectf(t, churned_own > 0.9, "recall after deletes %.4f must exceed 0.9", churned_own)
}

@(test)
delete_everything_then_reuse_slots :: proc(t: ^testing.T) {
	dim :: 8
	c: Churn
	churn_init(t, &c, dim, test_params(4, 50, 7), 600)
	defer churn_destroy(&c)
	state := u64(99)
	churn_run(t, &c, &state, 500, 0)
	check_graph(t, &c.ix)
	slots_before := slot_count(&c.ix)
	for len(c.live) > 0 {
		churn_delete(t, &c, int(rng_next(&state) % u64(len(c.live))))
		if len(c.live) % 50 == 0 {
			check_graph(t, &c.ix)
			reached, present := reachable_at(&c.ix, 0)
			testing.expect_value(t, reached, present)
		}
	}
	testing.expect_value(t, size(&c.ix), 0)
	testing.expect_value(t, c.ix.entry, NONE)
	out: [4]Candidate
	q := make([]f32, dim)
	defer delete(q)
	random_unit(&state, q)
	pq := Point_Query{&c.p, q}
	n, err := search(&c.ix, &c.s, point_query_distance, &pq, 4, 10, out[:])
	testing.expect_value(t, n, 0)
	testing.expect_value(t, err, Error.None)
	churn_run(t, &c, &state, 500, 200)
	testing.expect_value(t, slot_count(&c.ix), slots_before)
	check_graph(t, &c.ix)
	reached, present := reachable_at(&c.ix, 0)
	testing.expect_value(t, reached, present)
	testing.expect_value(t, remove(&c.ix, &c.s, NONE - 1), Error.Not_Found)
	gone := c.live[0]
	churn_delete(t, &c, 0)
	testing.expect_value(t, remove(&c.ix, &c.s, gone), Error.Not_Found)
	testing.expect_value(t, insert(&c.ix, &c.s, gone), Error.Not_Reserved)
}

@(test)
clustered_churn_keeps_every_cluster_reachable :: proc(t: ^testing.T) {
	dim :: 16
	clusters :: 30
	c: Churn
	churn_init(t, &c, dim, test_params(8, 100, 0xC1), 6_000)
	defer churn_destroy(&c)
	c.p.cosine = false
	state := u64(0xC1C1)
	centers := make([]f32, clusters * dim)
	defer delete(centers)
	for i in 0 ..< clusters {
		random_unit(&state, centers[i * dim:(i + 1) * dim])
	}
	v := make([]f32, dim)
	defer delete(v)
	for round in 0 ..< 3 {
		for _ in 0 ..< 2_000 {
			random_clustered(&state, centers, dim, 0.02, v)
			churn_insert(t, &c, v)
		}
		for _ in 0 ..< 1_500 {
			churn_delete(t, &c, int(rng_next(&state) % u64(len(c.live))))
		}
		check_graph(t, &c.ix)
		for l in 0 ..= c.ix.max_level {
			reached, present := reachable_at(&c.ix, l)
			testing.expectf(t, reached == present, "round %d layer %d: %d of %d reachable", round, l, reached, present)
		}
	}
	queries := make([]f32, RECALL_QUERIES * dim)
	defer delete(queries)
	for q in 0 ..< RECALL_QUERIES {
		random_clustered(&state, centers, dim, 0.02, queries[q * dim:(q + 1) * dim])
	}
	recall := measure_recall(&c.ix, &c.s, &c.p, queries, RECALL_K, RECALL_EF)
	log.infof("tight clusters after three rounds of 2000 inserts and 1500 deletes at M 8: %d live, recall@10 %.4f", len(c.live), recall)
	testing.expectf(t, recall > 0.9, "recall after clustered churn %.4f", recall)
}

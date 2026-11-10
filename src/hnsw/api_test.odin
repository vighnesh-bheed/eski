package hnsw

import "core:testing"

@(test)
init_rejects_bad_parameters :: proc(t: ^testing.T) {
	ix: Index
	testing.expect_value(t, init(&ix, test_params(1, 200, 0), points_distance, nil, context.allocator), Error.Invalid_Parameter)
	testing.expect_value(t, init(&ix, test_params(M_MAX + 1, 200, 0), points_distance, nil, context.allocator), Error.Invalid_Parameter)
	testing.expect_value(t, init(&ix, test_params(16, 0, 0), points_distance, nil, context.allocator), Error.Invalid_Parameter)
	testing.expect_value(t, init(&ix, test_params(16, 200, 0), nil, nil, context.allocator), Error.Invalid_Parameter)
	testing.expect_value(t, init(&ix, test_params(M_MAX, 1, 0), points_distance, nil, context.allocator), Error.None)
	destroy(&ix)
	defaults := params_default()
	testing.expect_value(t, defaults.m, 16)
	testing.expect_value(t, defaults.ef_construction, 200)
	testing.expect(t, defaults.keep_pruned)
	testing.expect(t, !defaults.extend_candidates)
	testing.expect_value(t, defaults.level_law, Level_Law.Constant)
	testing.expect_value(t, defaults.promotion, 0.25)
}

@(test)
slots_reserve_release_and_reuse :: proc(t: ^testing.T) {
	dim :: 4
	p: Points
	points_init(&p, dim, true, 64)
	defer points_destroy(&p)
	ix: Index
	testing.expect_value(t, init(&ix, test_params(4, 20, 3), points_distance, &p, context.allocator), Error.None)
	defer destroy(&ix)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	out: [8]Candidate
	q := []f32{1, 0, 0, 0}
	pq := Point_Query{&p, q}
	n, err := search(&ix, &s, point_query_distance, &pq, 8, 10, out[:])
	testing.expect_value(t, n, 0)
	testing.expect_value(t, err, Error.None)
	a, _ := reserve(&ix)
	b, _ := reserve(&ix)
	testing.expect_value(t, a, u32(0))
	testing.expect_value(t, b, u32(1))
	testing.expect(t, !is_live(&ix, a))
	testing.expect_value(t, release(&ix, b), Error.None)
	testing.expect_value(t, release(&ix, b), Error.Not_Reserved)
	testing.expect_value(t, insert(&ix, &s, b), Error.Not_Reserved)
	c, _ := reserve(&ix)
	testing.expect_value(t, c, b)
	points_set(&p, a, []f32{1, 0, 0, 0})
	testing.expect_value(t, insert(&ix, &s, a), Error.None)
	testing.expect_value(t, insert(&ix, &s, a), Error.Not_Reserved)
	testing.expect(t, is_live(&ix, a))
	testing.expect_value(t, ix.entry, a)
	n, _ = search(&ix, &s, point_query_distance, &pq, 8, 10, out[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, out[0], Candidate{0, a})
	buf: [8]u32
	testing.expect_value(t, len(links_top_first(&ix, a, 0, buf[:])), 0)
	testing.expect_value(t, node_layers(&ix, a), node_level(&ix, a) + 1)
	points_set(&p, c, []f32{0, 1, 0, 0})
	testing.expect_value(t, insert(&ix, &s, c), Error.None)
	testing.expect_value(t, layer_links(&ix, a, 0, buf[:])[0], c)
	testing.expect_value(t, layer_links(&ix, c, 0, buf[:])[0], a)
	testing.expect_value(t, len(layer_links(&ix, c, 99, buf[:])), 0)
	testing.expect_value(t, len(layer_links(&ix, 40, 0, buf[:])), 0)
	testing.expect(t, layer_links(&ix, c, 0, buf[:0]) == nil, "a buffer shorter than the list gives nothing")
	n, _ = search(&ix, &s, point_query_distance, &pq, 1, 1, out[:1])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, out[0].id, a)
	testing.expect_value(t, node_level(&ix, 7), -1)
	in_use := info(&ix)
	testing.expect_value(t, in_use.size, 2)
	testing.expect_value(t, in_use.max_node_uid, u64(2))
	testing.expect_value(t, in_use.m, 4)
	testing.expect_value(t, in_use.slots, 2)
	testing.expect(t, in_use.memory >= size_of(Index) + 2 * node_fixed_bytes(4, in_use.link_width))
	testing.expect_value(t, in_use.link_width, 2)
	testing.expect_value(t, remove(&ix, &s, a), Error.None)
	testing.expect_value(t, ix.entry, c)
	testing.expect_value(t, len(layer_links(&ix, c, 0, buf[:])), 0)
	testing.expect_value(t, info(&ix).max_node_uid, u64(2))
	d, _ := reserve(&ix)
	testing.expect_value(t, d, a)
}

@(test)
links_are_listed_top_layer_first :: proc(t: ^testing.T) {
	c: Churn
	churn_init(t, &c, 8, test_params(4, 40, 77), 400)
	defer churn_destroy(&c)
	state := u64(4)
	churn_run(t, &c, &state, 400, 0)
	testing.expect(t, c.ix.max_level >= 2)
	found := false
	top_buf: [8]u32
	layer_buf: [8]u32
	for slot in c.live {
		level := node_level(&c.ix, slot)
		testing.expect_value(t, node_layers(&c.ix, slot), level + 1)
		for i in 0 ..= level {
			top := links_top_first(&c.ix, slot, i, top_buf[:])
			testing.expect_value(t, len(top), len(layer_links(&c.ix, slot, level - i, layer_buf[:])))
			testing.expect(t, len(top) <= (i == level ? 8 : 4))
		}
		testing.expect_value(t, len(links_top_first(&c.ix, slot, level + 1, top_buf[:])), 0)
		if level >= 1 && len(layer_links(&c.ix, slot, 0, layer_buf[:])) > 4 {
			found = true
		}
	}
	testing.expect(t, found, "some multi-layer node holds more than M links on layer 0")
	entry_links := links_top_first(&c.ix, c.ix.entry, 0, top_buf[:])
	for v in entry_links {
		testing.expect_value(t, node_level(&c.ix, v), c.ix.max_level)
	}
}

@(test)
search_layer_honours_a_distance_bound :: proc(t: ^testing.T) {
	c: Churn
	churn_init(t, &c, 8, test_params(8, 64, 5), 2_000)
	defer churn_destroy(&c)
	state := u64(17)
	churn_run(t, &c, &state, 2_000, 0)
	q := make([]f32, 8)
	defer delete(q)
	random_unit(&state, q)
	pq := Point_Query{&c.p, q}
	truth: [20]Candidate
	m, _ := brute_force(&c.ix, &c.s, point_query_distance, &pq, 20, truth[:])
	testing.expect_value(t, m, 20)
	bound := truth[9].dist
	probe := Probe{point_query_distance, &pq, nil}
	ep := descend(&c.ix, &c.s, probe, 0)
	clear(&c.s.entries)
	append(&c.s.entries, ep)
	search_layer(&c.ix, &c.s, probe, 100, 0, bound)
	out: [100]Candidate
	n := results_take(&c.s, 100, out[:])
	testing.expect_value(t, n, 10)
	for r in out[:n] {
		testing.expect(t, r.dist <= bound)
	}
}

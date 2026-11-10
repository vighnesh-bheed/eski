package hnsw

import "core:log"
import "core:testing"

star_index :: proc(t: ^testing.T, ix: ^Index, s: ^Scratch, p: ^Points, dim: int) -> (hub: u32) {
	points_init(p, dim, false, 16)
	params := test_params(M_MIN, 16, 0x57A2)
	params.keep_pruned = false
	params.promotion = 1e-12
	testing.expect_value(t, init(ix, params, points_distance, p, context.allocator), Error.None)
	scratch_init(s, context.allocator)
	v := make([]f32, dim)
	defer delete(v)
	hub = add_point(t, ix, s, p, v)
	for axis in 0 ..< 2 * M_MIN {
		for &x in v {
			x = 0
		}
		v[axis] = 1
		add_point(t, ix, s, p, v)
	}
	return hub
}

@(test)
shrink_fallback_never_isolates_a_node :: proc(t: ^testing.T) {
	dim :: 8
	p: Points
	ix: Index
	s: Scratch
	hub := star_index(t, &ix, &s, &p, dim)
	defer points_destroy(&p)
	defer destroy(&ix)
	defer scratch_destroy(&s)
	testing.expect_value(t, ix.max_level, 0)
	testing.expect_value(t, list_count(&ix, hub, 0), layer_cap(&ix, 0))
	buf: [8]u32
	for leaf in 1 ..= u32(2 * M_MIN) {
		links := layer_links(&ix, leaf, 0, buf[:])
		testing.expect(t, len(links) == 1 && links[0] == hub, "every leaf of the star links only to the full hub")
	}
	v := make([]f32, dim)
	defer delete(v)
	v[2 * M_MIN] = 1
	q := add_point(t, &ix, &s, &p, v)
	check_graph(t, &ix)
	reached, present := reachable_at(&ix, 0)
	testing.expectf(t, reached == present, "after the forced eviction %d of %d nodes are reachable", reached, present)
	for i in 0 ..< ix.slots {
		testing.expectf(t, list_count(&ix, u32(i), 0) > 0, "node %d keeps a link", i)
	}
	testing.expect_value(t, list_count(&ix, hub, 0), layer_cap(&ix, 0))
	testing.expect(t, list_count(&ix, q, 0) >= 1)
	first := make([]f32, dim)
	defer delete(first)
	copy(first, v)
	pq := Point_Query{&p, first}
	out: [1]Candidate
	n, _ := search(&ix, &s, point_query_distance, &pq, 1, 8, out[:])
	testing.expect(t, n == 1 && out[0].id == q, "the newcomer is found by a search for its own vector")
	for axis in 2 * M_MIN + 1 ..< dim {
		for &x in v {
			x = 0
		}
		v[axis] = 1
		late := add_point(t, &ix, &s, &p, v)
		check_graph(t, &ix)
		reached, present = reachable_at(&ix, 0)
		testing.expectf(t, reached == present, "after newcomer %d, %d of %d nodes are reachable", late, reached, present)
		n, _ = search(&ix, &s, point_query_distance, &pq, 1, 8, out[:])
		testing.expect(t, n == 1 && out[0].id == q, "the first newcomer stays findable")
	}
}

linkless_nodes :: proc(ix: ^Index) -> (orphans: int) {
	for l in 0 ..= ix.max_level {
		present := 0
		for i in 0 ..< ix.slots {
			if is_node(ix, u32(i)) && int(ix.levels[i]) >= l {
				present += 1
			}
		}
		if present < 2 {
			continue
		}
		for i in 0 ..< ix.slots {
			if is_node(ix, u32(i)) && int(ix.levels[i]) >= l && list_count(ix, u32(i), l) == 0 {
				orphans += 1
			}
		}
	}
	return
}

@(test)
duplicate_heavy_churn_never_leaves_a_node_without_links :: proc(t: ^testing.T) {
	for m in ([]int{M_MIN, 4, 16}) {
		for keep in ([]bool{false, true}) {
			dim :: 4
			distinct_points :: 40
			c: Churn
			params := test_params(m, 20, 0xD0D0)
			params.keep_pruned = keep
			churn_init(t, &c, dim, params, 800)
			defer churn_destroy(&c)
			c.p.cosine = false
			state := u64(0xD0D0D)
			base := make([]f32, distinct_points * dim)
			defer delete(base)
			for i in 0 ..< distinct_points {
				random_unit(&state, base[i * dim:(i + 1) * dim])
			}
			orphans := 0
			for op in 0 ..< 900 {
				if len(c.live) > 20 && rng_next(&state) % 5 == 0 {
					churn_delete(t, &c, int(rng_next(&state) % u64(len(c.live))))
				} else {
					at := int(rng_next(&state) % distinct_points)
					churn_insert(t, &c, base[at * dim:(at + 1) * dim])
				}
				if op % 25 == 24 {
					check_graph(t, &c.ix)
					orphans += linkless_nodes(&c.ix)
				}
			}
			reached, present := reachable_at(&c.ix, 0)
			log.infof("exact duplicates, M %d, keep_pruned %v: %d of %d nodes reachable on layer 0 after 900 operations, %d of them twins", m, keep, reached, present, c.ix.twins)
			testing.expectf(t, orphans == 0, "M %d keep_pruned %v: %d node checks found a node without links", m, keep, orphans)
			testing.expectf(t, reached == present, "M %d keep_pruned %v: %d of %d nodes reachable on layer 0", m, keep, reached, present)
			if m >= 4 {
				expect_reachable(t, &c.ix, "exact duplicates under churn")
			}
		}
	}
}

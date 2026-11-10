package hnsw

import "core:log"
import "core:math"
import "core:testing"

Range_Kind :: enum {
	Unit,
	Clustered,
	Ternary,
}

range_points :: proc(t: ^testing.T, kind: Range_Kind, b: ^Hook_Build, count, dim: int, state: ^u64) -> (queries: []f32) {
	points_init(&b.p, dim, kind != .Clustered, count)
	recorder_init(&b.r, &b.p)
	params := kind == .Unit ? test_params(16, 200, 0x2A9) : test_params(8, 80, 0x2A9 + u64(kind))
	testing.expect_value(t, init(&b.ix, params, recorded_distance, &b.r, context.allocator), Error.None)
	scratch_init(&b.s, context.allocator)
	centers := make([]f32, 30 * dim)
	defer delete(centers)
	for c in 0 ..< 30 {
		random_unit(state, centers[c * dim:(c + 1) * dim])
	}
	v := make([]f32, dim)
	defer delete(v)
	queries = make([]f32, 40 * dim)
	for i in 0 ..< count + 40 {
		switch kind {
		case .Unit:
			random_unit(state, v)
		case .Clustered:
			random_clustered(state, centers, dim, 0.05, v)
		case .Ternary:
			random_ternary(state, v)
		}
		if i < count {
			add_point(t, &b.ix, &b.s, &b.p, v)
		} else {
			copy(queries[(i - count) * dim:], v)
		}
	}
	return queries
}

range_recall :: proc(t: ^testing.T, b: ^Hook_Build, queries: []f32, rank: int, ef: int, epsilon: f32) -> f64 {
	dim := b.p.dim
	truth := make([]Candidate, rank)
	defer delete(truth)
	found := make([dynamic]Candidate, 0, 256)
	defer delete(found)
	exact := make([dynamic]Candidate, 0, 256)
	defer delete(exact)
	open_set := make([dynamic]Candidate, 0, 256)
	defer delete(open_set)
	hits := 0
	total := 0
	for qi in 0 ..< len(queries) / dim {
		pq := Point_Query{&b.p, queries[qi * dim:(qi + 1) * dim]}
		m, _ := brute_force(&b.ix, &b.s, point_query_distance, &pq, rank, truth)
		testing.expect_value(t, m, rank)
		radius := truth[rank - 1].dist
		r := Range{radius = radius, epsilon = epsilon, inclusive = true}
		n, err := search_range(&b.ix, &b.s, point_query_distance, &pq, r, ef, &found)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, n, len(found))
		brute_force_range(&b.ix, &b.s, point_query_distance, &pq, r, &exact)
		testing.expectf(t, len(exact) >= rank, "the inclusive exact range holds the node at exactly the radius (%d of %d)", len(exact), rank)
		boundary_in := false
		for c in exact {
			if c == truth[rank - 1] {
				boundary_in = true
			}
		}
		testing.expect(t, boundary_in, "a node at exactly the radius is inside an inclusive range")
		r.inclusive = false
		brute_force_range(&b.ix, &b.s, point_query_distance, &pq, r, &open_set)
		testing.expect(t, len(open_set) < len(exact), "an exclusive range drops the nodes at exactly the radius")
		for c in open_set {
			testing.expect(t, c.dist < radius)
		}
		search_range(&b.ix, &b.s, point_query_distance, &pq, r, ef, &open_set)
		for c in open_set {
			testing.expect(t, c.dist < radius, "exclusive radius search never returns a node at the radius")
		}
		for i in 1 ..< len(found) {
			testing.expect(t, closer(found[i - 1], found[i]), "results are sorted by distance and id without duplicates")
		}
		k := 0
		for c in found {
			for k < len(exact) && closer(exact[k], c) {
				k += 1
			}
			if k < len(exact) && exact[k] == c {
				hits += 1
				k += 1
			} else {
				testing.expect(t, false, "every result lies within the radius")
			}
		}
		total += len(exact)
	}
	return f64(hits) / f64(total)
}

@(test)
radius_search_matches_exact_ranges :: proc(t: ^testing.T) {
	state := u64(0x2A91)
	for kind in Range_Kind {
		b: Hook_Build
		count := kind == .Ternary ? 2_500 : 4_000
		dim := kind == .Unit ? 32 : 16
		queries := range_points(t, kind, &b, count, dim, &state)
		defer delete(queries)
		defer hook_build_destroy(&b)
		check_graph(t, &b.ix)
		ef := kind == .Unit ? 100 : 20
		narrow := range_recall(t, &b, queries, 10, ef, 0.01)
		wide := range_recall(t, &b, queries, 50, ef, 0.01)
		loose := range_recall(t, &b, queries, 50, ef, 0.2)
		log.infof("radius search on %v data, %d points: recall %.4f at the 10th neighbour's distance, %.4f at the 50th, %.4f at the 50th with epsilon 0.2 (ef %d)", kind, count, narrow, wide, loose, ef)
		testing.expectf(t, narrow > 0.9 && wide > 0.9, "%v radius search recall %.4f and %.4f", kind, narrow, wide)
		testing.expectf(t, loose >= wide, "%v a wider candidate boundary never lowers recall here (%.4f against %.4f)", kind, loose, wide)
	}
}

@(test)
radius_search_edges_filters_and_hooks :: proc(t: ^testing.T) {
	state := u64(0x2A92)
	b: Hook_Build
	queries := range_points(t, .Unit, &b, 2_000, 16, &state)
	defer delete(queries)
	defer hook_build_destroy(&b)
	found := make([dynamic]Candidate, 0, 2_048)
	defer delete(found)
	exact := make([dynamic]Candidate, 0, 2_048)
	defer delete(exact)
	pq := Point_Query{&b.p, queries[:16]}
	n, err := search_range(&b.ix, &b.s, point_query_distance, &pq, range_default(math.INF_F32), 10, &found)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, n, 2_000)
	n, _ = search_range(&b.ix, &b.s, point_query_distance, &pq, Range{radius = math.INF_F32, inclusive = true}, 1, &found)
	testing.expect_value(t, n, 2_000)
	testing.expect_value(t, range_boundary(Range{radius = 0, epsilon = math.INF_F32}), 0)
	testing.expect_value(t, range_boundary(Range{radius = math.INF_F32}), math.INF_F32)
	testing.expect_value(t, search_range_error(&b, &pq, Range{radius = -1}, 10), Error.Invalid_Parameter)
	testing.expect_value(t, search_range_error(&b, &pq, Range{radius = 0.5, epsilon = -0.1}, 10), Error.Invalid_Parameter)
	testing.expect_value(t, search_range_error(&b, &pq, Range{radius = math.nan_f32()}, 10), Error.Invalid_Parameter)
	testing.expect_value(t, search_range_error(&b, &pq, range_default(0.5), 0), Error.Invalid_Parameter)
	_, err = brute_force_range(&b.ix, &b.s, point_query_distance, &pq, Range{radius = -1}, &exact)
	testing.expect_value(t, err, Error.Invalid_Parameter)
	n, _ = search_range(&b.ix, &b.s, point_query_distance, &pq, range_default(0), 10, &found)
	testing.expect_value(t, n, 0)
	truth: [40]Candidate
	brute_force(&b.ix, &b.s, point_query_distance, &pq, 40, truth[:])
	radius := truth[39].dist
	a := Accept_Mod{modulus = 2}
	search_range(&b.ix, &b.s, point_query_distance, &pq, range_default(radius), 20, &found, accept_mod, &a)
	b2 := Accept_Mod{modulus = 2}
	brute_force_range(&b.ix, &b.s, point_query_distance, &pq, range_default(radius), &exact, accept_mod, &b2)
	testing.expect(t, len(found) > 5 && len(found) <= len(exact))
	for c in found {
		testing.expect(t, mix_slot(c.id) % 2 == 0 && c.dist <= radius, "filtered results pass the filter and lie within the radius")
	}
	testing.expect(t, a.calls < 200, "the filter is asked only about nodes inside the radius")
	plain := make([dynamic]Candidate, 0, 256)
	defer delete(plain)
	for qi in 0 ..< 40 {
		q := queries[qi * 16:(qi + 1) * 16]
		brute_force(&b.ix, &b.s, point_query_distance, &Point_Query{&b.p, q}, 40, truth[:])
		r := Range{radius = truth[39].dist, epsilon = 0.05, inclusive = true}
		clear(&b.r.log)
		qa := Recorded_Query{&b.r, q}
		search_range(&b.ix, &b.s, recorded_query, &qa, r, 10, &plain)
		plain_log := make([]u64, len(b.r.log))
		copy(plain_log, b.r.log[:])
		defer delete(plain_log)
		clear(&b.r.log)
		set_prefetch(&b.ix, recorded_prefetch, &b.r)
		search_range(&b.ix, &b.s, recorded_query, &qa, r, 10, &found, nil, nil, recorded_batch)
		set_prefetch(&b.ix, nil, nil)
		testing.expect(t, slices_equal(plain[:], found[:]), "radius search results are identical with hooks")
		testing.expect(t, logs_equal(plain_log, b.r.log[:]), "radius search visit order is identical with hooks")
		clear(&b.r.log)
		brute_force_range(&b.ix, &b.s, recorded_query, &qa, r, &exact)
		plain_exact := make([]Candidate, len(exact))
		copy(plain_exact, exact[:])
		defer delete(plain_exact)
		brute_force_range(&b.ix, &b.s, recorded_query, &qa, r, &exact, nil, nil, recorded_batch)
		testing.expect(t, slices_equal(plain_exact, exact[:]), "exact ranges are identical with the batch hook")
	}
	top: [20]Candidate
	brute_force(&b.ix, &b.s, point_query_distance, &pq, 40, truth[:])
	cut_at := truth[9].dist
	for inclusive in ([]bool{true, false}) {
		k, _ := search(&b.ix, &b.s, point_query_distance, &pq, 20, 40, top[:])
		testing.expect_value(t, k, 20)
		before := top
		kept := results_within(top[:k], Range{radius = cut_at, inclusive = inclusive})
		expected := 0
		for c in before[:k] {
			if c.dist < cut_at || inclusive && c.dist == cut_at {
				testing.expect_value(t, top[expected], c)
				expected += 1
			}
		}
		testing.expect_value(t, kept, expected)
		testing.expect_value(t, kept, inclusive ? 10 : 9)
	}
	empty: Index
	init(&empty, test_params(4, 10, 1), points_distance, &b.p, context.allocator)
	defer destroy(&empty)
	n, err = search_range(&empty, &b.s, point_query_distance, &pq, range_default(1), 10, &found)
	testing.expect(t, n == 0 && err == .None && len(found) == 0)
}

search_range_error :: proc(b: ^Hook_Build, pq: ^Point_Query, r: Range, ef: int) -> Error {
	out := make([dynamic]Candidate, 0, 4)
	defer delete(out)
	_, err := search_range(&b.ix, &b.s, point_query_distance, pq, r, ef, &out)
	return err
}

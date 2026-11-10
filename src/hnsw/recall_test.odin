package hnsw

import "core:log"
import "core:testing"

RECALL_POINTS :: 10_000
RECALL_QUERIES :: 200
RECALL_K :: 10
RECALL_EF :: 100
RECALL_EF_WIDE :: 400

Unit_Recall :: struct {
	fresh:      f64,
	stored:     f64,
	fresh_wide: f64,
}

build_unit :: proc(t: ^testing.T, ix: ^Index, s: ^Scratch, p: ^Points, state: ^u64, n: int) {
	v := make([]f32, p.dim)
	defer delete(v)
	for _ in 0 ..< n {
		random_unit(state, v)
		add_point(t, ix, s, p, v)
	}
}

unit_recall :: proc(t: ^testing.T, dim: int) -> (r: Unit_Recall) {
	p: Points
	points_init(&p, dim, true, RECALL_POINTS)
	defer points_destroy(&p)
	ix: Index
	testing.expect_value(t, init(&ix, test_params(16, 200, 0xA11CE + u64(dim)), points_distance, &p, context.allocator), Error.None)
	defer destroy(&ix)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	state := u64(0xD1CE) + u64(dim)
	build_unit(t, &ix, &s, &p, &state, RECALL_POINTS)
	check_graph(t, &ix)
	reached, present := reachable_at(&ix, 0)
	testing.expect_value(t, reached, present)
	fresh := make_queries(&state, RECALL_QUERIES, dim)
	defer delete(fresh)
	slots := make([]u32, RECALL_POINTS)
	defer delete(slots)
	for i in 0 ..< RECALL_POINTS {
		slots[i] = u32(i)
	}
	stored := self_queries(&p, slots, RECALL_QUERIES)
	defer delete(stored)
	r.fresh = measure_recall(&ix, &s, &p, fresh, RECALL_K, RECALL_EF)
	r.stored = measure_recall(&ix, &s, &p, stored, RECALL_K, RECALL_EF)
	r.fresh_wide = measure_recall(&ix, &s, &p, fresh, RECALL_K, RECALL_EF_WIDE)
	log.infof("unit vectors dim %d, %d points, M 16, ef construction 200: recall@10 at ef %d is %.4f for fresh queries and %.4f for stored queries, %.4f for fresh queries at ef %d; max level %d", dim, RECALL_POINTS, RECALL_EF, r.fresh, r.stored, r.fresh_wide, RECALL_EF_WIDE, ix.max_level)
	return r
}

@(test)
recall_unit_vectors_dimension_32 :: proc(t: ^testing.T) {
	r := unit_recall(t, 32)
	testing.expectf(t, r.fresh > 0.95, "recall@10 %.4f for fresh queries must exceed 0.95", r.fresh)
	testing.expectf(t, r.stored > 0.95, "recall@10 %.4f for stored queries must exceed 0.95", r.stored)
}

@(test)
recall_unit_vectors_dimension_128 :: proc(t: ^testing.T) {
	r := unit_recall(t, 128)
	testing.expectf(t, r.stored > 0.95, "recall@10 %.4f for stored queries must exceed 0.95", r.stored)
	testing.expectf(t, r.fresh > 0.7, "recall@10 %.4f for fresh queries at ef 100 must exceed 0.7", r.fresh)
	testing.expectf(t, r.fresh_wide > 0.95, "recall@10 %.4f for fresh queries at ef 400 must exceed 0.95", r.fresh_wide)
}

clustered_recall :: proc(t: ^testing.T, sigma: f32, clusters: int) -> f64 {
	dim :: 32
	count :: 5_000
	p: Points
	points_init(&p, dim, false, count)
	defer points_destroy(&p)
	ix: Index
	testing.expect_value(t, init(&ix, test_params(16, 200, 0xC1A5), points_distance, &p, context.allocator), Error.None)
	defer destroy(&ix)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	state := u64(0xC0FFEE)
	centers := make([]f32, clusters * dim)
	defer delete(centers)
	for c in 0 ..< clusters {
		random_unit(&state, centers[c * dim:(c + 1) * dim])
	}
	v := make([]f32, dim)
	defer delete(v)
	for _ in 0 ..< count {
		random_clustered(&state, centers, dim, sigma, v)
		add_point(t, &ix, &s, &p, v)
	}
	check_graph(t, &ix)
	reached, present := reachable_at(&ix, 0)
	testing.expect_value(t, reached, present)
	queries := make([]f32, RECALL_QUERIES * dim)
	defer delete(queries)
	for q in 0 ..< RECALL_QUERIES {
		random_clustered(&state, centers, dim, sigma, queries[q * dim:(q + 1) * dim])
	}
	recall := measure_recall(&ix, &s, &p, queries, RECALL_K, RECALL_EF)
	log.infof("clustered dim %d, %d clusters, sigma %.2f, %d points, squared L2: recall@10 %.4f at ef %d, max level %d", dim, clusters, sigma, count, recall, RECALL_EF, ix.max_level)
	return recall
}

@(test)
recall_clustered_points :: proc(t: ^testing.T) {
	tight := clustered_recall(t, 0.02, 40)
	testing.expectf(t, tight > 0.95, "recall@10 %.4f on tight clusters must exceed 0.95", tight)
	wide := clustered_recall(t, 0.25, 200)
	testing.expectf(t, wide > 0.95, "recall@10 %.4f on overlapping clusters must exceed 0.95", wide)
}

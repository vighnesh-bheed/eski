package hnsw

import "core:math"
import "core:testing"

Graph_Snapshot :: struct {
	levels: [dynamic]i32,
	links:  [dynamic]u32,
	entry:  u32,
	top:    int,
}

snapshot_destroy :: proc(g: ^Graph_Snapshot) {
	delete(g.levels)
	delete(g.links)
}

snapshot_take :: proc(ix: ^Index) -> (g: Graph_Snapshot) {
	g.entry = ix.entry
	g.top = ix.max_level
	buf := make([]u32, ix.m0)
	defer delete(buf)
	for i in 0 ..< ix.slots {
		slot := u32(i)
		level := node_level(ix, slot)
		append(&g.levels, i32(level))
		for l in 0 ..< node_layers(ix, slot) {
			links := links_top_first(ix, slot, l, buf)
			append(&g.links, u32(len(links)))
			append(&g.links, ..links)
		}
	}
	return g
}

snapshot_equal :: proc(a, b: ^Graph_Snapshot) -> bool {
	if a.entry != b.entry || a.top != b.top || len(a.levels) != len(b.levels) || len(a.links) != len(b.links) {
		return false
	}
	for v, i in a.levels {
		if b.levels[i] != v {
			return false
		}
	}
	for v, i in a.links {
		if b.links[i] != v {
			return false
		}
	}
	return true
}

seeded_build :: proc(t: ^testing.T, seed: u64) -> Graph_Snapshot {
	c: Churn
	churn_init(t, &c, 16, test_params(8, 64, seed), 3_000)
	defer churn_destroy(&c)
	state := u64(0xFEED)
	churn_run(t, &c, &state, 3_000, 1_000)
	check_graph(t, &c.ix)
	return snapshot_take(&c.ix)
}

@(test)
same_seed_gives_identical_links :: proc(t: ^testing.T) {
	a := seeded_build(t, 42)
	defer snapshot_destroy(&a)
	b := seeded_build(t, 42)
	defer snapshot_destroy(&b)
	c := seeded_build(t, 43)
	defer snapshot_destroy(&c)
	testing.expect(t, len(a.links) > 0)
	testing.expect(t, snapshot_equal(&a, &b), "two builds with the same seed and inputs have identical levels and links")
	testing.expect(t, !snapshot_equal(&a, &c), "a different seed gives a different graph")
}

level_histogram :: proc(t: ^testing.T, params: Params, draws: int) -> (counts: [LEVEL_CAP + 1]int) {
	ix: Index
	testing.expect_value(t, init(&ix, params, points_distance, nil, context.allocator), Error.None)
	defer destroy(&ix)
	for _ in 0 ..< draws {
		counts[random_level(&ix)] += 1
	}
	return counts
}

@(test)
level_law_promotes_with_a_constant_probability :: proc(t: ^testing.T) {
	quarter := math.ln(f64(0.25))
	testing.expect_value(t, level_for(1, quarter), 0)
	testing.expect_value(t, level_for(0.25, quarter), 1)
	testing.expect_value(t, level_for(0.25 + 1e-9, quarter), 0)
	testing.expect_value(t, level_for(1.0 / 16, quarter), 2)
	testing.expect_value(t, level_for(1.0 / 64, quarter), 3)
	testing.expect_value(t, level_for(UNIT_53, quarter), 26)
	testing.expect_value(t, level_for(UNIT_53, math.ln(f64(0.9))), LEVEL_CAP)
	draws :: 200_000
	for m in ([]int{4, 16, 64}) {
		counts := level_histogram(t, test_params(m, 200, 1), draws)
		above := [3]int{draws - counts[0], draws - counts[0] - counts[1], draws - counts[0] - counts[1] - counts[2]}
		expected := [3]f64{f64(draws) * 0.25, f64(draws) * 0.0625, f64(draws) * 0.015625}
		for i in 0 ..< 3 {
			testing.expectf(t, f64(above[i]) > expected[i] * 0.9 && f64(above[i]) < expected[i] * 1.1, "M %d: %d nodes above layer %d, expected about %.0f", m, above[i], i, expected[i])
		}
	}
	paper := test_params(16, 200, 1)
	paper.level_law = .Inverse_Log_M
	counts := level_histogram(t, paper, draws)
	above := draws - counts[0]
	testing.expectf(t, f64(above) > f64(draws) / 16 * 0.9 && f64(above) < f64(draws) / 16 * 1.1, "1/ln(M) law at M 16: %d above layer 0, expected about %d", above, draws / 16)
	testing.expect_value(t, level_for(1.0 / 16, -math.ln(f64(16))), 1)
	bad := test_params(16, 200, 1)
	ix: Index
	for promotion in ([]f64{0, 1, -0.5, 1.5}) {
		bad.promotion = promotion
		testing.expect_value(t, init(&ix, bad, points_distance, nil, context.allocator), Error.Invalid_Parameter)
	}
	bad.level_law = .Inverse_Log_M
	testing.expect_value(t, init(&ix, bad, points_distance, nil, context.allocator), Error.None)
	destroy(&ix)
}

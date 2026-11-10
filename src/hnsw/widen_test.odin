package hnsw

import "core:testing"

Widen_Plan :: enum {
	Natural,
	Wide_From_Start,
	Widen_Midway,
}

widen_build :: proc(t: ^testing.T, b: ^Hook_Build, plan: Widen_Plan, vectors: []f32, dim: int) {
	count := len(vectors) / dim
	points_init(&b.p, dim, true, count)
	recorder_init(&b.r, &b.p)
	testing.expect_value(t, init(&b.ix, test_params(6, 40, 0x31DE), recorded_distance, &b.r, context.allocator), Error.None)
	scratch_init(&b.s, context.allocator)
	if plan == .Wide_From_Start {
		testing.expect_value(t, reserve_capacity(&b.ix, 16), Error.None)
		testing.expect_value(t, reencode(&b.ix, b.ix.cap, 4), Error.None)
	}
	live := make([dynamic]u32, 0, count)
	defer delete(live)
	state := u64(0x51DE)
	for i in 0 ..< count {
		if i == count / 2 || i == 3 * count / 4 {
			widen_burst(t, b, &live, &state, 40)
		}
		if plan == .Widen_Midway && (i == count / 2 || i == 3 * count / 4) {
			upper_waiting := false
			for at in b.ix.upper_free {
				upper_waiting ||= at != NONE
			}
			testing.expect(t, b.ix.free_head != NONE && upper_waiting, "free slots and free upper blocks are waiting when the ids widen")
		}
		if plan == .Widen_Midway && i == count / 2 {
			testing.expect_value(t, b.ix.width, 2)
			testing.expect_value(t, reserve_capacity(&b.ix, WIDTH_U16_SLOTS + 1), Error.None)
			testing.expect_value(t, b.ix.width, 3)
			testing.expect_value(t, b.ix.cap, WIDTH_U16_SLOTS + 1)
		}
		if plan == .Widen_Midway && i == 3 * count / 4 {
			testing.expect_value(t, reencode(&b.ix, b.ix.cap, 4), Error.None)
			testing.expect_value(t, b.ix.width, 4)
		}
		slot, err := reserve(&b.ix)
		testing.expect_value(t, err, Error.None)
		points_set(&b.p, slot, vectors[i * dim:(i + 1) * dim])
		testing.expect_value(t, insert(&b.ix, &b.s, slot), Error.None)
		append(&live, slot)
		if i > 200 && rng_next(&state) % 4 == 0 {
			widen_burst(t, b, &live, &state, 1)
		}
	}
	widen_burst(t, b, &live, &state, 60)
}

widen_burst :: proc(t: ^testing.T, b: ^Hook_Build, live: ^[dynamic]u32, state: ^u64, n: int) {
	for _ in 0 ..< n {
		at := int(rng_next(state) % u64(len(live)))
		testing.expect_value(t, remove(&b.ix, &b.s, live[at]), Error.None)
		live[at] = live[len(live) - 1]
		pop(live)
	}
}

drain_free :: proc(t: ^testing.T, ix: ^Index) -> (slots: [dynamic]u32, blocks: [dynamic]u32) {
	for ix.free_head != NONE {
		slot, err := reserve(ix)
		testing.expect_value(t, err, Error.None)
		append(&slots, slot)
	}
	for level in 1 ..= LEVEL_CAP {
		for ix.upper_free[level] != NONE {
			at, err := upper_alloc(ix, level)
			testing.expect_value(t, err, Error.None)
			append(&blocks, u32(level) << 27 | at)
		}
	}
	return
}

@(test)
link_widths_are_lossless_and_widening_keeps_the_graph :: proc(t: ^testing.T) {
	dim :: 12
	count :: 2_400
	state := u64(0x3D1D)
	vectors := make([]f32, count * dim)
	defer delete(vectors)
	for i in 0 ..< count {
		random_unit(&state, vectors[i * dim:(i + 1) * dim])
	}
	builds: [Widen_Plan]Hook_Build
	for plan in Widen_Plan {
		widen_build(t, &builds[plan], plan, vectors, dim)
	}
	defer for plan in Widen_Plan {
		hook_build_destroy(&builds[plan])
	}
	testing.expect_value(t, builds[.Natural].ix.width, 2)
	testing.expect_value(t, builds[.Wide_From_Start].ix.width, 4)
	testing.expect_value(t, builds[.Widen_Midway].ix.width, 4)
	testing.expect(t, !builds[.Natural].ix.prefetch_links && builds[.Widen_Midway].ix.prefetch_links, "link rows are prefetched only once they outgrow the cache budget, without changing the graph")
	testing.expect(t, builds[.Natural].ix.free_head != NONE, "deletes left free slots to reuse")
	snaps: [Widen_Plan]Graph_Snapshot
	for plan in Widen_Plan {
		check_graph(t, &builds[plan].ix)
		snaps[plan] = snapshot_take(&builds[plan].ix)
	}
	defer for plan in Widen_Plan {
		snapshot_destroy(&snaps[plan])
	}
	testing.expect(t, snapshot_equal(&snaps[.Natural], &snaps[.Wide_From_Start]), "16-bit and 32-bit ids give the same graph")
	testing.expect(t, snapshot_equal(&snaps[.Natural], &snaps[.Widen_Midway]), "widening from 16 to 24 to 32 bits keeps the graph")
	testing.expect(t, logs_equal(builds[.Natural].r.log[:], builds[.Widen_Midway].r.log[:]), "the same distances in the same order")
	testing.expect(t, used_bytes(&builds[.Natural].ix) * 2 < used_bytes(&builds[.Wide_From_Start].ix) + 2 * builds[.Natural].ix.slots * 7)
	queries := make_queries(&state, 40, dim)
	defer delete(queries)
	outs: [Widen_Plan][10]Candidate
	for qi in 0 ..< 40 {
		counts: [Widen_Plan]int
		for plan in Widen_Plan {
			pq := Point_Query{&builds[plan].p, queries[qi * dim:(qi + 1) * dim]}
			counts[plan], _ = search(&builds[plan].ix, &builds[plan].s, point_query_distance, &pq, 10, 30, outs[plan][:])
		}
		testing.expect_value(t, counts[.Natural], counts[.Widen_Midway])
		testing.expect(t, slices_equal(outs[.Natural][:counts[.Natural]], outs[.Wide_From_Start][:counts[.Wide_From_Start]]))
		testing.expect(t, slices_equal(outs[.Natural][:counts[.Natural]], outs[.Widen_Midway][:counts[.Widen_Midway]]))
	}
	upper_free := builds[.Natural].ix.upper_free
	testing.expect(t, upper_free == builds[.Widen_Midway].ix.upper_free, "upper pool free lists survive widening")
	testing.expect(t, upper_free == builds[.Wide_From_Start].ix.upper_free)
	natural_slots, natural_blocks := drain_free(t, &builds[.Natural].ix)
	defer delete(natural_slots)
	defer delete(natural_blocks)
	testing.expectf(t, len(natural_slots) >= 60 && len(natural_blocks) > 0, "deletes left %d free slots and %d free upper blocks to reuse", len(natural_slots), len(natural_blocks))
	for plan in ([]Widen_Plan{.Wide_From_Start, .Widen_Midway}) {
		slots, blocks := drain_free(t, &builds[plan].ix)
		defer delete(slots)
		defer delete(blocks)
		testing.expect(t, len(slots) == len(natural_slots) && len(blocks) == len(natural_blocks), "free lists have the same length at every width")
		for i in 0 ..< min(len(slots), len(natural_slots)) {
			testing.expect_value(t, slots[i], natural_slots[i])
		}
		for i in 0 ..< min(len(blocks), len(natural_blocks)) {
			testing.expect_value(t, blocks[i], natural_blocks[i])
		}
	}
}

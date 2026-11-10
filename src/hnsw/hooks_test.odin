package hnsw

import "core:testing"

Recorder :: struct {
	p:          ^Points,
	log:        [dynamic]u64,
	prefetches: int,
	batches:    int,
}

Recorded_Target :: struct {
	r:    ^Recorder,
	base: u32,
}

Recorded_Query :: struct {
	r: ^Recorder,
	q: []f32,
}

recorder_init :: proc(r: ^Recorder, p: ^Points) {
	r^ = Recorder{p = p}
	r.log = make([dynamic]u64, 0, 1 << 16)
}

recorder_destroy :: proc(r: ^Recorder) {
	delete(r.log)
}

recorded_distance :: proc(ctx: rawptr, a, b: u32) -> f32 {
	r := (^Recorder)(ctx)
	append(&r.log, u64(a) << 32 | u64(b))
	return vector_distance(r.p, points_get(r.p, a), points_get(r.p, b))
}

recorded_target_query :: proc(ctx: rawptr, slot: u32) -> f32 {
	t := (^Recorded_Target)(ctx)
	return recorded_distance(t.r, t.base, slot)
}

recorded_target_batch :: proc(ctx: rawptr, slots: []u32, out: []f32) {
	t := (^Recorded_Target)(ctx)
	t.r.batches += 1
	for slot, i in slots {
		out[i] = recorded_target_query(ctx, slot)
	}
}

recorded_query :: proc(ctx: rawptr, slot: u32) -> f32 {
	q := (^Recorded_Query)(ctx)
	append(&q.r.log, u64(NONE) << 32 | u64(slot))
	return vector_distance(q.r.p, q.q, points_get(q.r.p, slot))
}

recorded_batch :: proc(ctx: rawptr, slots: []u32, out: []f32) {
	q := (^Recorded_Query)(ctx)
	q.r.batches += 1
	for slot, i in slots {
		out[i] = recorded_query(ctx, slot)
	}
}

recorded_prefetch :: proc(ctx: rawptr, slot: u32) {
	r := (^Recorder)(ctx)
	if int(slot) < len(r.p.data) / r.p.dim {
		r.prefetches += 1
	}
}

logs_equal :: proc(a, b: []u64) -> bool {
	if len(a) != len(b) {
		return false
	}
	for v, i in a {
		if b[i] != v {
			return false
		}
	}
	return true
}

Hook_Build :: struct {
	p:  Points,
	r:  Recorder,
	ix: Index,
	s:  Scratch,
}

hook_build :: proc(t: ^testing.T, b: ^Hook_Build, hooked: bool, vectors: []f32, dim: int, removals: []int) {
	count := len(vectors) / dim
	points_init(&b.p, dim, true, count)
	recorder_init(&b.r, &b.p)
	testing.expect_value(t, init(&b.ix, test_params(8, 60, 0x4007), recorded_distance, &b.r, context.allocator), Error.None)
	scratch_init(&b.s, context.allocator)
	if hooked {
		set_prefetch(&b.ix, recorded_prefetch, &b.r)
	}
	live := make([dynamic]u32, 0, count)
	defer delete(live)
	removal := 0
	for i in 0 ..< count {
		slot, err := reserve(&b.ix)
		testing.expect_value(t, err, Error.None)
		points_set(&b.p, slot, vectors[i * dim:(i + 1) * dim])
		if hooked {
			target := Recorded_Target{&b.r, slot}
			testing.expect_value(t, insert(&b.ix, &b.s, slot, 0, recorded_target_query, &target, recorded_target_batch), Error.None)
		} else {
			testing.expect_value(t, insert(&b.ix, &b.s, slot), Error.None)
		}
		append(&live, slot)
		if removal < len(removals) && i == removals[removal] {
			at := int(mix_slot(u32(i)) % u32(len(live)))
			testing.expect_value(t, remove(&b.ix, &b.s, live[at]), Error.None)
			live[at] = live[len(live) - 1]
			pop(&live)
			removal += 1
		}
	}
}

hook_build_destroy :: proc(b: ^Hook_Build) {
	scratch_destroy(&b.s)
	destroy(&b.ix)
	recorder_destroy(&b.r)
	points_destroy(&b.p)
}

random_ternary :: proc(state: ^u64, v: []f32) {
	for &x in v {
		x = f32(int(rng_next(state) % 3) - 1)
	}
	v[0] = 1
	normalize(v)
}

@(test)
hooks_keep_graphs_visit_order_and_results_identical :: proc(t: ^testing.T) {
	hooks_identical(t, false)
	hooks_identical(t, true)
}

hooks_identical :: proc(t: ^testing.T, ternary: bool) {
	dim :: 16
	count :: 3_000
	state := u64(0x400C5)
	vectors := make([]f32, count * dim)
	defer delete(vectors)
	for i in 0 ..< count {
		if ternary {
			random_ternary(&state, vectors[i * dim:(i + 1) * dim])
		} else {
			random_unit(&state, vectors[i * dim:(i + 1) * dim])
		}
	}
	removals := make([dynamic]int, 0, 400)
	defer delete(removals)
	for i := 500; i < count; i += 7 {
		append(&removals, i)
	}
	plain: Hook_Build
	hook_build(t, &plain, false, vectors, dim, removals[:])
	defer hook_build_destroy(&plain)
	hooked: Hook_Build
	hook_build(t, &hooked, true, vectors, dim, removals[:])
	defer hook_build_destroy(&hooked)
	testing.expect(t, hooked.r.prefetches > 0 && hooked.r.batches > 0, "the build exercised both hooks")
	testing.expect(t, len(plain.r.log) > 100_000)
	testing.expect(t, logs_equal(plain.r.log[:], hooked.r.log[:]), "inserts and deletes evaluate the same distances in the same order with and without hooks")
	a := snapshot_take(&plain.ix)
	defer snapshot_destroy(&a)
	b := snapshot_take(&hooked.ix)
	defer snapshot_destroy(&b)
	testing.expect(t, snapshot_equal(&a, &b), "the graphs are identical with and without hooks")
	check_graph(t, &hooked.ix)
	build_batches := hooked.r.batches
	queries := make_queries(&state, 60, dim)
	defer delete(queries)
	if ternary {
		for qi in 0 ..< 60 {
			random_ternary(&state, queries[qi * dim:(qi + 1) * dim])
		}
	}
	out_a: [20]Candidate
	out_b: [20]Candidate
	searches := 0
	for qi in 0 ..< 60 {
		q := queries[qi * dim:(qi + 1) * dim]
		for ef in ([]int{1, 10, 40, 150}) {
			clear(&plain.r.log)
			clear(&hooked.r.log)
			qa := Recorded_Query{&plain.r, q}
			qb := Recorded_Query{&hooked.r, q}
			na, ea := search(&plain.ix, &plain.s, recorded_query, &qa, 20, ef, out_a[:])
			nb, eb := search(&hooked.ix, &hooked.s, recorded_query, &qb, 20, ef, out_b[:], recorded_batch)
			testing.expect_value(t, ea, Error.None)
			testing.expect_value(t, eb, Error.None)
			testing.expect_value(t, na, nb)
			testing.expect(t, slices_equal(out_a[:na], out_b[:nb]), "plain search results identical")
			testing.expect(t, logs_equal(plain.r.log[:], hooked.r.log[:]), "plain search visit order identical")
			searches += 1
		}
		for budget in ([]int{0, 1, 5, 23, 64, 300}) {
			clear(&plain.r.log)
			clear(&hooked.r.log)
			qa := Recorded_Query{&plain.r, q}
			qb := Recorded_Query{&hooked.r, q}
			aa := Accept_Mod{modulus = 3}
			ab := Accept_Mod{modulus = 3}
			na, ia, _ := search_filtered(&plain.ix, &plain.s, recorded_query, &qa, 10, 40, accept_mod, &aa, budget, out_a[:])
			nb, ib, _ := search_filtered(&hooked.ix, &hooked.s, recorded_query, &qb, 10, 40, accept_mod, &ab, budget, out_b[:], recorded_batch)
			testing.expect_value(t, na, nb)
			testing.expect_value(t, ia, ib)
			testing.expect_value(t, aa.calls, ab.calls)
			testing.expect(t, slices_equal(out_a[:na], out_b[:nb]), "filtered search results identical")
			testing.expect(t, logs_equal(plain.r.log[:], hooked.r.log[:]), "filtered search visit order identical, including budget cut-offs")
		}
		clear(&plain.r.log)
		clear(&hooked.r.log)
		qa := Recorded_Query{&plain.r, q}
		qb := Recorded_Query{&hooked.r, q}
		aa := Accept_Mod{modulus = 2}
		ab := Accept_Mod{modulus = 2}
		na, _ := brute_force(&plain.ix, &plain.s, recorded_query, &qa, 20, out_a[:], accept_mod, &aa)
		nb, _ := brute_force(&hooked.ix, &hooked.s, recorded_query, &qb, 20, out_b[:], accept_mod, &ab, recorded_batch)
		testing.expect_value(t, na, nb)
		testing.expect_value(t, aa.calls, ab.calls)
		testing.expect(t, slices_equal(out_a[:na], out_b[:nb]), "exact search results identical")
		testing.expect(t, logs_equal(plain.r.log[:], hooked.r.log[:]), "exact search evaluates the same slots in the same order")
	}
	testing.expect_value(t, searches, 240)
	testing.expect(t, hooked.r.batches > build_batches, "the searches exercised the batch hook")
	if ternary {
		ties := 0
		for qi in 0 ..< 60 {
			q := Recorded_Query{&plain.r, queries[qi * dim:(qi + 1) * dim]}
			n, _ := brute_force(&plain.ix, &plain.s, recorded_query, &q, 20, out_a[:])
			for i in 1 ..< n {
				if out_a[i].dist == out_a[i - 1].dist {
					ties += 1
				}
			}
		}
		testing.expectf(t, ties > 100, "the ternary set has exact distance ties among the nearest twenty (%d)", ties)
	}
}

slices_equal :: proc(a, b: []Candidate) -> bool {
	if len(a) != len(b) {
		return false
	}
	for c, i in a {
		if transmute(u64)c != transmute(u64)b[i] {
			return false
		}
	}
	return true
}

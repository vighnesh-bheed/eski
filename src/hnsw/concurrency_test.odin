package hnsw

import "base:runtime"
import "core:testing"
import "core:thread"

READERS :: 4
READER_QUERIES :: 48
READER_K :: 10

Reader_Expect :: struct {
	plain:    [READER_K]Candidate,
	plain_n:  int,
	filter:   [READER_K]Candidate,
	filter_n: int,
	ranged:   [dynamic]Candidate,
}

Reader_Shared :: struct {
	ix:      ^Index,
	p:       ^Points,
	queries: []f32,
	expect:  []Reader_Expect,
	radius:  []f32,
}

Reader :: struct {
	shared:     ^Reader_Shared,
	id:         int,
	hooked:     bool,
	mismatches: int,
	searches:   int,
}

pure_batch :: proc(ctx: rawptr, slots: []u32, out: []f32) {
	for slot, i in slots {
		out[i] = point_query_distance(ctx, slot)
	}
}

pure_prefetch :: proc(ctx: rawptr, slot: u32) {
	p := (^Points)(ctx)
	_ = points_get(p, slot)
}

pure_accept :: proc(ctx: rawptr, slot: u32) -> bool {
	return mix_slot(slot) % 3 == 0
}

reader_search :: proc(sh: ^Reader_Shared, s: ^Scratch, qi: int, hooked: bool, e: ^Reader_Expect, ranged: ^[dynamic]Candidate) {
	dim := sh.p.dim
	pq := Point_Query{sh.p, sh.queries[qi * dim:(qi + 1) * dim]}
	batch: Batch_Query_Proc = hooked ? pure_batch : nil
	e.plain_n, _ = search(sh.ix, s, point_query_distance, &pq, READER_K, 40, e.plain[:], batch)
	e.filter_n, _, _ = search_filtered(sh.ix, s, point_query_distance, &pq, READER_K, 40, pure_accept, nil, 200, e.filter[:], batch)
	search_range(sh.ix, s, point_query_distance, &pq, range_default(sh.radius[qi]), 10, ranged, nil, nil, batch)
}

reader_run :: proc(r: ^Reader) {
	sh := r.shared
	s: Scratch
	scratch_init(&s, runtime.heap_allocator())
	defer scratch_destroy(&s)
	got: Reader_Expect
	ranged := make([dynamic]Candidate, 0, 256, runtime.heap_allocator())
	defer delete(ranged)
	for round in 0 ..< 3 {
		for j in 0 ..< READER_QUERIES {
			qi := (j + r.id * 7 + round * 13) % READER_QUERIES
			reader_search(sh, &s, qi, r.hooked, &got, &ranged)
			want := &sh.expect[qi]
			r.searches += 1
			if got.plain_n != want.plain_n || !slices_equal(got.plain[:got.plain_n], want.plain[:want.plain_n]) {
				r.mismatches += 1
			}
			if got.filter_n != want.filter_n || !slices_equal(got.filter[:got.filter_n], want.filter[:want.filter_n]) {
				r.mismatches += 1
			}
			if !slices_equal(ranged[:], want.ranged[:]) {
				r.mismatches += 1
			}
		}
	}
}

@(test)
concurrent_readers_share_one_index :: proc(t: ^testing.T) {
	concurrent_readers(t, false)
	concurrent_readers(t, true)
}

concurrent_readers :: proc(t: ^testing.T, copies: bool) {
	dim :: 16
	count :: 4_000
	p: Points
	points_init(&p, dim, true, count)
	defer points_destroy(&p)
	ix: Index
	testing.expect_value(t, init(&ix, test_params(8, 60, 0xC0C0), points_distance, &p, context.allocator), Error.None)
	defer destroy(&ix)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	state := u64(0xC0C0A)
	build_unit(t, &ix, &s, &p, &state, count)
	set_prefetch(&ix, pure_prefetch, &p)
	queries := make_queries(&state, READER_QUERIES, dim)
	defer delete(queries)
	if copies {
		v := make([]f32, dim)
		defer delete(v)
		for i in 0 ..< READER_QUERIES / 4 {
			copy(v, points_get(&p, u32(i * 37)))
			copy(queries[i * dim:(i + 1) * dim], v)
			for _ in 0 ..< 30 {
				add_point(t, &ix, &s, &p, v)
			}
		}
		check_graph(t, &ix)
		testing.expect(t, ix.twins > 0, "the copies hang off the graph as twins")
	}
	expect := make([]Reader_Expect, READER_QUERIES)
	defer {
		for &e in expect {
			delete(e.ranged)
		}
		delete(expect)
	}
	radius := make([]f32, READER_QUERIES)
	defer delete(radius)
	truth: [30]Candidate
	sh := Reader_Shared{&ix, &p, queries, expect, radius}
	for qi in 0 ..< READER_QUERIES {
		pq := Point_Query{&p, queries[qi * dim:(qi + 1) * dim]}
		n, _ := brute_force(&ix, &s, point_query_distance, &pq, 30, truth[:])
		radius[qi] = copies ? max(truth[n - 1].dist, 0) + 1e-6 : truth[n - 1].dist
		expect[qi].ranged = make([dynamic]Candidate, 0, 64)
		reader_search(&sh, &s, qi, false, &expect[qi], &expect[qi].ranged)
		testing.expect(t, expect[qi].plain_n == READER_K && len(expect[qi].ranged) > 0)
	}
	readers: [READERS]Reader
	threads: [READERS]^thread.Thread
	for i in 0 ..< READERS {
		readers[i] = Reader{shared = &sh, id = i, hooked = i % 2 == 1}
		threads[i] = thread.create_and_start_with_poly_data(&readers[i], reader_run, context)
	}
	for i in 0 ..< READERS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
	for r in readers {
		testing.expect_value(t, r.searches, 3 * READER_QUERIES)
		testing.expectf(t, r.mismatches == 0, "reader %d saw %d results that differ from the single-threaded ones", r.id, r.mismatches)
	}
}

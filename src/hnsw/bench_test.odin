package hnsw

import "base:runtime"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"

BENCH_ENV :: "ESKI_HNSW_BENCH"

bench_size :: proc(t: ^testing.T, count: int) {
	dim :: 128
	queries :: 1_000
	checked :: 100
	p: Points
	points_init(&p, dim, true, count)
	defer points_destroy(&p)
	ix: Index
	testing.expect_value(t, init(&ix, test_params(16, 200, 0xBE7C), points_distance, &p, context.allocator), Error.None)
	defer destroy(&ix)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	state := u64(0xBE7C4)
	vectors := make([]f32, count * dim)
	defer delete(vectors)
	for i in 0 ..< count {
		random_unit(&state, vectors[i * dim:(i + 1) * dim])
	}
	start := time.tick_now()
	for i in 0 ..< count {
		slot, _ := reserve(&ix)
		points_set(&p, slot, vectors[i * dim:(i + 1) * dim])
		insert(&ix, &s, slot)
	}
	build := time.tick_since(start)
	build_calls := p.calls
	q := make_queries(&state, queries, dim)
	defer delete(q)
	out: [10]Candidate
	counted := Points_Counted{&p, 0}
	start = time.tick_now()
	for i in 0 ..< queries {
		pq := Point_Query{&p, q[i * dim:(i + 1) * dim]}
		search(&ix, &s, counted_query_distance, &Counted_Query{&counted, &pq}, 10, 100, out[:])
	}
	lookups := time.tick_since(start)
	slots := make([]u32, count)
	defer delete(slots)
	for i in 0 ..< count {
		slots[i] = u32(i)
	}
	stored := self_queries(&p, slots, checked)
	defer delete(stored)
	fresh_recall := measure_recall(&ix, &s, &p, q[:checked * dim], 10, 100)
	stored_recall := measure_recall(&ix, &s, &p, stored, 10, 100)
	log.infof("bench %d points dim 128 M 16 ef construction 200: %.0f inserts per second (%v, %.0f distance calls per insert), %.0f queries per second at k 10 ef 100 (%v, %.0f distance calls per query), recall@10 %.4f on %d fresh and %.4f on %d stored queries, %.2f bytes per node", count, f64(count) / time.duration_seconds(build), build, f64(build_calls) / f64(count), f64(queries) / time.duration_seconds(lookups), lookups, f64(counted.calls) / f64(queries), fresh_recall, checked, stored_recall, checked, f64(used_bytes(&ix)) / f64(count))
}

Points_Counted :: struct {
	p:     ^Points,
	calls: int,
}

Counted_Query :: struct {
	counted: ^Points_Counted,
	query:   ^Point_Query,
}

counted_query_distance :: proc(ctx: rawptr, slot: u32) -> f32 {
	c := (^Counted_Query)(ctx)
	c.counted.calls += 1
	return point_query_distance(c.query, slot)
}

@(test)
bench_inserts_and_queries :: proc(t: ^testing.T) {
	value := os.get_env(BENCH_ENV, runtime.heap_allocator())
	defer delete(value, runtime.heap_allocator())
	if value == "" {
		return
	}
	bench_size(t, 10_000)
	bench_size(t, 100_000)
}

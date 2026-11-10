package hnsw

import "core:slice"
import "core:testing"

@(test)
min_heap_pops_in_ascending_order_with_id_ties :: proc(t: ^testing.T) {
	h: Min_Heap
	min_heap_init(&h, context.allocator)
	defer min_heap_destroy(&h)
	state := u64(5)
	for i in 0 ..< 1000 {
		testing.expect(t, min_heap_push(&h, Candidate{f32(rng_next(&state) % 97), u32(i)}))
	}
	testing.expect_value(t, min_heap_len(&h), 1000)
	prev := min_heap_pop(&h)
	for min_heap_len(&h) > 0 {
		c := min_heap_pop(&h)
		testing.expect(t, closer(prev, c), "each pop is farther than the previous, ties ordered by id")
		prev = c
	}
	min_heap_push(&h, Candidate{1, 9})
	min_heap_push(&h, Candidate{1, 3})
	min_heap_push(&h, Candidate{0.5, 20})
	testing.expect_value(t, min_heap_top(&h), Candidate{0.5, 20})
	testing.expect_value(t, min_heap_pop(&h), Candidate{0.5, 20})
	testing.expect_value(t, min_heap_pop(&h), Candidate{1, 3})
	testing.expect_value(t, min_heap_pop(&h), Candidate{1, 9})
	min_heap_push(&h, Candidate{2, 2})
	min_heap_clear(&h)
	testing.expect_value(t, min_heap_len(&h), 0)
}

@(test)
max_heap_pops_in_descending_order_and_replaces_top :: proc(t: ^testing.T) {
	h: Max_Heap
	max_heap_init(&h, context.allocator)
	defer max_heap_destroy(&h)
	state := u64(11)
	for i in 0 ..< 1000 {
		testing.expect(t, max_heap_push(&h, Candidate{f32(rng_next(&state) % 89), u32(i)}))
	}
	prev := max_heap_pop(&h)
	for max_heap_len(&h) > 0 {
		c := max_heap_pop(&h)
		testing.expect(t, closer(c, prev), "each pop is closer than the previous")
		prev = c
	}
	for i in 0 ..< 10 {
		max_heap_push(&h, Candidate{f32(i), u32(i)})
	}
	testing.expect_value(t, max_heap_top(&h), Candidate{9, 9})
	testing.expect_value(t, max_heap_replace_top(&h, Candidate{3.5, 100}), Candidate{9, 9})
	testing.expect_value(t, max_heap_top(&h), Candidate{8, 8})
	want := []Candidate{{8, 8}, {7, 7}, {6, 6}, {5, 5}, {4, 4}, {3.5, 100}, {3, 3}, {2, 2}, {1, 1}, {0, 0}}
	for w in want {
		testing.expect_value(t, max_heap_pop(&h), w)
	}
	max_heap_push(&h, Candidate{1, 7})
	max_heap_push(&h, Candidate{1, 2})
	testing.expect_value(t, max_heap_pop(&h), Candidate{1, 7})
	testing.expect_value(t, max_heap_pop(&h), Candidate{1, 2})
}

@(test)
visited_set_uses_one_epoch_per_query_without_clearing :: proc(t: ^testing.T) {
	v: Visited
	visited_init(&v, context.allocator)
	defer visited_destroy(&v)
	testing.expect(t, visited_begin(&v, 10))
	testing.expect_value(t, v.epoch, Stamp(1))
	testing.expect(t, visited_mark(&v, 3))
	testing.expect(t, !visited_mark(&v, 3))
	testing.expect(t, visited_contains(&v, 3))
	testing.expect(t, !visited_contains(&v, 4))
	testing.expect(t, visited_begin(&v, 10))
	testing.expect_value(t, v.epoch, Stamp(2))
	testing.expect(t, !visited_contains(&v, 3))
	testing.expect(t, visited_mark(&v, 3))
	old_cap := v.cap
	testing.expect(t, visited_begin(&v, old_cap * 4))
	testing.expect(t, v.cap >= old_cap * 4)
	for i in 0 ..< v.cap {
		testing.expect(t, !visited_contains(&v, u32(i)))
	}
	testing.expect(t, visited_mark(&v, u32(v.cap - 1)))
	v.epoch = max(Stamp) - 1
	v.stamps[5] = max(Stamp)
	testing.expect(t, visited_begin(&v, 1))
	testing.expect_value(t, v.epoch, max(Stamp))
	testing.expect(t, visited_contains(&v, 5))
	testing.expect(t, visited_begin(&v, 1))
	testing.expect_value(t, v.epoch, Stamp(1))
	for i in 0 ..< v.cap {
		testing.expect(t, !visited_contains(&v, u32(i)))
	}
	for round in 0 ..< 3 * int(max(Stamp)) {
		testing.expect(t, visited_begin(&v, 16))
		testing.expectf(t, visited_mark(&v, 7), "a fresh epoch never sees an earlier mark (round %d)", round)
		testing.expect(t, !visited_mark(&v, 7))
	}
	testing.expect_value(t, size_of(Stamp), 1)
}

@(test)
candidate_sort_matches_the_library_order :: proc(t: ^testing.T) {
	state := u64(0x5027)
	a := make([]Candidate, 120)
	defer delete(a)
	b := make([]Candidate, 120)
	defer delete(b)
	for n in 0 ..< 120 {
		for i in 0 ..< n {
			a[i] = Candidate{f32(rng_next(&state) % 7) * 0.25, u32(rng_next(&state) % 100_000) * 120 + u32(i)}
		}
		copy(b[:n], a[:n])
		candidates_sort(a[:n])
		slice.sort_by(b[:n], candidate_less)
		testing.expectf(t, slices_equal(a[:n], b[:n]), "%d candidates sort into the library order", n)
	}
}

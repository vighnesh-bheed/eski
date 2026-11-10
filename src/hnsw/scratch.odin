package hnsw

import "base:runtime"
import "core:slice"

Scratch :: struct {
	candidates: Min_Heap,
	results:    Max_Heap,
	visited:    Visited,
	entries:    [dynamic]Candidate,
	work:       [dynamic]Candidate,
	selected:   [dynamic]Candidate,
	pruned:     [dynamic]Candidate,
	shrink:     [dynamic]Candidate,
	kept:       [dynamic]Candidate,
	dropped:    [dynamic]Candidate,
	layered:    [dynamic]Candidate,
	layer_span: [LEVEL_CAP + 1][2]int,
	blockers:   [dynamic]u32,
	removed:    [dynamic]u32,
	removed_at: [LEVEL_CAP + 2]int,
	batch:      [^]u32,
	batch_cap:  int,
	allocator:  runtime.Allocator,
	oom:        bool,
}

scratch_init :: proc(s: ^Scratch, allocator: runtime.Allocator) {
	s^ = Scratch{allocator = allocator}
	min_heap_init(&s.candidates, allocator)
	max_heap_init(&s.results, allocator)
	visited_init(&s.visited, allocator)
	s.entries = make([dynamic]Candidate, 0, 0, allocator)
	s.work = make([dynamic]Candidate, 0, 0, allocator)
	s.selected = make([dynamic]Candidate, 0, 0, allocator)
	s.pruned = make([dynamic]Candidate, 0, 0, allocator)
	s.shrink = make([dynamic]Candidate, 0, 0, allocator)
	s.kept = make([dynamic]Candidate, 0, 0, allocator)
	s.dropped = make([dynamic]Candidate, 0, 0, allocator)
	s.layered = make([dynamic]Candidate, 0, 0, allocator)
	s.blockers = make([dynamic]u32, 0, 0, allocator)
	s.removed = make([dynamic]u32, 0, 0, allocator)
}

scratch_destroy :: proc(s: ^Scratch) {
	min_heap_destroy(&s.candidates)
	max_heap_destroy(&s.results)
	visited_destroy(&s.visited)
	delete(s.entries)
	delete(s.work)
	delete(s.selected)
	delete(s.pruned)
	delete(s.shrink)
	delete(s.kept)
	delete(s.dropped)
	delete(s.layered)
	delete(s.blockers)
	delete(s.removed)
	array_free(s.batch, 2 * s.batch_cap, s.allocator)
	s^ = Scratch{}
}

scratch_batch :: proc(s: ^Scratch, n: int) -> bool {
	if n <= s.batch_cap {
		return true
	}
	grown := max(n, 64)
	data, err := runtime.mem_alloc_non_zeroed(2 * grown * size_of(u32), align_of(u32), s.allocator)
	if err != nil {
		return false
	}
	array_free(s.batch, 2 * s.batch_cap, s.allocator)
	s.batch = ([^]u32)(raw_data(data))
	s.batch_cap = grown
	return true
}

batch_ids :: #force_inline proc "contextless" (s: ^Scratch) -> [^]u32 {
	return s.batch
}

batch_dists :: #force_inline proc "contextless" (s: ^Scratch) -> [^]f32 #no_bounds_check {
	return ([^]f32)(&s.batch[s.batch_cap])
}

scratch_memory :: proc "contextless" (s: ^Scratch) -> int {
	n := s.visited.cap * size_of(Stamp) + (cap(s.removed) + cap(s.blockers) + 2 * s.batch_cap) * size_of(u32)
	n += (cap(s.candidates.items) + cap(s.results.items) + cap(s.entries) + cap(s.work) + cap(s.selected)) * size_of(Candidate)
	n += (cap(s.pruned) + cap(s.shrink) + cap(s.kept) + cap(s.dropped) + cap(s.layered)) * size_of(Candidate)
	return n
}

candidate_less :: proc(a, b: Candidate) -> bool {
	return closer(a, b)
}

SORT_SMALL :: 48

candidates_sort :: proc(c: []Candidate) #no_bounds_check {
	if len(c) > SORT_SMALL {
		slice.sort_by(c, candidate_less)
		return
	}
	for i in 1 ..< len(c) {
		v := c[i]
		j := i
		for j > 0 && closer(v, c[j - 1]) {
			c[j] = c[j - 1]
			j -= 1
		}
		c[j] = v
	}
}

candidates_add :: proc(s: ^Scratch, list: ^[dynamic]Candidate, c: Candidate) {
	if _, err := append(list, c); err != nil {
		s.oom = true
	}
}

push_candidate :: #force_inline proc(s: ^Scratch, c: Candidate) {
	if !min_heap_push(&s.candidates, c) {
		s.oom = true
	}
}

push_result :: #force_inline proc(s: ^Scratch, c: Candidate, ef: int) {
	if max_heap_len(&s.results) < ef {
		if !max_heap_push(&s.results, c) {
			s.oom = true
		}
	} else if closer(c, max_heap_top(&s.results)) {
		max_heap_replace_top(&s.results, c)
	}
}

results_take :: proc(s: ^Scratch, k: int, out: []Candidate) -> int {
	for max_heap_len(&s.results) > k {
		max_heap_pop(&s.results)
	}
	n := max_heap_len(&s.results)
	for i := n - 1; i >= 0; i -= 1 {
		out[i] = max_heap_pop(&s.results)
	}
	return n
}

results_to_work :: proc(s: ^Scratch, skip: u32) {
	clear(&s.work)
	n := max_heap_len(&s.results)
	if err := resize(&s.work, n); err != nil {
		s.oom = true
		max_heap_clear(&s.results)
		return
	}
	for i := n - 1; i >= 0; i -= 1 {
		s.work[i] = max_heap_pop(&s.results)
	}
	if skip != NONE {
		j := 0
		for c in s.work {
			if c.id != skip {
				s.work[j] = c
				j += 1
			}
		}
		resize(&s.work, j)
	}
}

work_to_entries :: proc(s: ^Scratch) {
	clear(&s.entries)
	if _, err := append(&s.entries, ..s.work[:]); err != nil {
		s.oom = true
	}
}

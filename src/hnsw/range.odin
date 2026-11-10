package hnsw

Range :: struct {
	radius:    f32,
	epsilon:   f32,
	inclusive: bool,
}

range_default :: proc "contextless" (radius: f32) -> Range {
	return Range{radius = radius, epsilon = RANGE_EPSILON_DEFAULT, inclusive = true}
}

RANGE_EPSILON_DEFAULT :: f32(0.01)

range_valid :: proc "contextless" (r: Range) -> bool {
	return r.radius >= 0 && r.epsilon >= 0
}

range_within :: #force_inline proc "contextless" (r: Range, d: f32) -> bool {
	return d < r.radius || r.inclusive && d == r.radius
}

range_boundary :: #force_inline proc "contextless" (r: Range) -> f32 {
	if r.radius == 0 {
		return 0
	}
	return r.radius * (1 + r.epsilon)
}

range_add :: #force_inline proc(s: ^Scratch, out: ^[dynamic]Candidate, c: Candidate, accept: Accept_Proc, actx: rawptr) {
	if accept != nil && !accept(actx, c.id) {
		return
	}
	if _, err := append(out, c); err != nil {
		s.oom = true
	}
}

search_range :: proc(ix: ^Index, s: ^Scratch, query: Query_Proc, qctx: rawptr, r: Range, ef: int, out: ^[dynamic]Candidate, accept: Accept_Proc = nil, actx: rawptr = nil, batch: Batch_Query_Proc = nil) -> (n: int, err: Error) #no_bounds_check {
	clear(out)
	if !range_valid(r) || ef < 1 {
		return 0, .Invalid_Parameter
	}
	if ix.entry == NONE {
		return 0, .None
	}
	p := Probe{query, qctx, batch}
	ep := descend(ix, s, p, 0)
	min_heap_clear(&s.candidates)
	max_heap_clear(&s.results)
	if s.oom || !visited_begin(&s.visited, ix.slots) || !scratch_batch(s, ix.m0) {
		s.oom = false
		return 0, .Out_Of_Memory
	}
	boundary := range_boundary(r)
	visited_mark(&s.visited, ep.id)
	push_candidate(s, ep)
	push_result(s, ep, ef)
	if range_within(r, ep.dist) {
		range_add(s, out, ep, accept, actx)
	}
	if ix.twins > 0 && ep.dist <= boundary {
		twins_range(ix, s, p, ep.id, r, out, accept, actx)
	}
	for min_heap_len(&s.candidates) > 0 {
		c := min_heap_pop(&s.candidates)
		if c.dist > boundary && max_heap_len(&s.results) >= ef && c.dist > max_heap_top(&s.results).dist {
			break
		}
		if min_heap_len(&s.candidates) > 0 {
			links_prefetch(ix, min_heap_top(&s.candidates).id, 0)
		}
		count := gather(ix, s, list_get(ix, c.id, 0))
		ids := batch_ids(s)[:count]
		measure(ix, s, p, ids)
		dists := batch_dists(s)
		for e, i in ids {
			nb := Candidate{dists[i], e}
			beam := max_heap_len(&s.results) < ef || closer(nb, max_heap_top(&s.results))
			if beam || nb.dist <= boundary {
				links_prefetch(ix, e, 0)
				push_candidate(s, nb)
				if beam {
					push_result(s, nb, ef)
				}
			}
			if range_within(r, nb.dist) {
				range_add(s, out, nb, accept, actx)
			}
			if ix.twins > 0 && nb.dist <= boundary {
				twins_range(ix, s, p, e, r, out, accept, actx)
			}
		}
	}
	candidates_sort(out[:])
	if s.oom {
		s.oom = false
		return len(out), .Out_Of_Memory
	}
	return len(out), .None
}

twins_range :: proc(ix: ^Index, s: ^Scratch, p: Probe, head: u32, r: Range, out: ^[dynamic]Candidate, accept: Accept_Proc, actx: rawptr) {
	for t := ix.twin_link[head]; t != NONE; t = ix.twin_link[t] {
		d := p.query(p.ctx, t)
		if range_within(r, d) {
			range_add(s, out, Candidate{d, t}, accept, actx)
		}
	}
}

brute_force_range :: proc(ix: ^Index, s: ^Scratch, query: Query_Proc, qctx: rawptr, r: Range, out: ^[dynamic]Candidate, accept: Accept_Proc = nil, actx: rawptr = nil, batch: Batch_Query_Proc = nil) -> (n: int, err: Error) #no_bounds_check {
	clear(out)
	if !range_valid(r) {
		return 0, .Invalid_Parameter
	}
	if batch != nil && scratch_batch(s, BRUTE_CHUNK) {
		ids := batch_ids(s)
		dists := batch_dists(s)
		i := 0
		for i < ix.slots {
			count := 0
			for i < ix.slots && count < BRUTE_CHUNK {
				slot := u32(i)
				i += 1
				if !is_live(ix, slot) || accept != nil && !accept(actx, slot) {
					continue
				}
				ids[count] = slot
				count += 1
			}
			if count == 0 {
				continue
			}
			batch(qctx, ids[:count], dists[:count])
			for j in 0 ..< count {
				if range_within(r, dists[j]) {
					range_add(s, out, Candidate{dists[j], ids[j]}, nil, nil)
				}
			}
		}
	} else {
		for i in 0 ..< ix.slots {
			slot := u32(i)
			if !is_live(ix, slot) || accept != nil && !accept(actx, slot) {
				continue
			}
			d := query(qctx, slot)
			if range_within(r, d) {
				range_add(s, out, Candidate{d, slot}, nil, nil)
			}
		}
	}
	candidates_sort(out[:])
	if s.oom {
		s.oom = false
		return len(out), .Out_Of_Memory
	}
	return len(out), .None
}

results_within :: proc "contextless" (out: []Candidate, r: Range) -> int {
	n := 0
	for c in out {
		if range_within(r, c.dist) {
			out[n] = c
			n += 1
		}
	}
	return n
}

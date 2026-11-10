package hnsw

import "core:math"

UNBOUNDED :: math.INF_F32

BRUTE_CHUNK :: 64

Node_Target :: struct {
	distance: Distance_Proc,
	ctx:      rawptr,
	base:     u32,
}

Probe :: struct {
	query: Query_Proc,
	ctx:   rawptr,
	batch: Batch_Query_Proc,
}

node_target_query :: proc(ctx: rawptr, slot: u32) -> f32 {
	t := (^Node_Target)(ctx)
	return t.distance(t.ctx, t.base, slot)
}

node_probe :: #force_inline proc "contextless" (target: ^Node_Target) -> Probe {
	return Probe{node_target_query, target, nil}
}

gather_width :: #force_inline proc(ix: ^Index, s: ^Scratch, l: List, $W: int) -> int #no_bounds_check {
	ids := batch_ids(s)
	n := 0
	prefetch := ix.prefetch
	pctx := ix.prefetch_ctx
	for i in 0 ..< l.count {
		e := id_load(l.data, i, W)
		if visited_mark(&s.visited, e) {
			ids[n] = e
			n += 1
			if prefetch != nil {
				prefetch(pctx, e)
			}
		}
	}
	return n
}

gather :: proc(ix: ^Index, s: ^Scratch, l: List) -> int {
	switch ix.width {
	case 2:
		return gather_width(ix, s, l, 2)
	case 3:
		return gather_width(ix, s, l, 3)
	}
	return gather_width(ix, s, l, 4)
}

measure :: #force_inline proc(ix: ^Index, s: ^Scratch, p: Probe, ids: []u32) #no_bounds_check {
	dists := batch_dists(s)
	if p.batch != nil {
		p.batch(p.ctx, ids, dists[:len(ids)])
		return
	}
	for e, i in ids {
		dists[i] = p.query(p.ctx, e)
	}
}

greedy_closest :: proc(ix: ^Index, s: ^Scratch, p: Probe, ep: u32, d: f32, layer: int) -> (u32, f32) #no_bounds_check {
	best := Candidate{d, ep}
	for {
		changed := false
		links := list_decode(ix, list_get(ix, best.id, layer), batch_ids(s))
		if ix.prefetch != nil {
			for e in links {
				ix.prefetch(ix.prefetch_ctx, e)
			}
		}
		measure(ix, s, p, links)
		dists := batch_dists(s)
		for e, i in links {
			c := Candidate{dists[i], e}
			if closer(c, best) {
				best = c
				changed = true
			}
		}
		if !changed {
			break
		}
	}
	return best.id, best.dist
}

descend :: proc(ix: ^Index, s: ^Scratch, p: Probe, to_layer: int) -> Candidate {
	ep := ix.entry
	d := p.query(p.ctx, ep)
	if !scratch_batch(s, ix.m0) {
		s.oom = true
		return Candidate{d, ep}
	}
	for l := ix.max_level; l > to_layer; l -= 1 {
		ep, d = greedy_closest(ix, s, p, ep, d, l)
	}
	return Candidate{d, ep}
}

search_layer :: proc(ix: ^Index, s: ^Scratch, p: Probe, ef: int, layer: int, bound := UNBOUNDED) #no_bounds_check {
	min_heap_clear(&s.candidates)
	max_heap_clear(&s.results)
	if !visited_begin(&s.visited, ix.slots) || !scratch_batch(s, ix.m0) {
		s.oom = true
		return
	}
	bounded := bound < UNBOUNDED
	for e in s.entries {
		if !visited_mark(&s.visited, e.id) {
			continue
		}
		push_candidate(s, e)
		if e.dist <= bound {
			push_result(s, e, ef)
		}
	}
	for min_heap_len(&s.candidates) > 0 {
		c := min_heap_pop(&s.candidates)
		if max_heap_len(&s.results) > 0 && (!bounded || max_heap_len(&s.results) >= ef) && c.dist > max_heap_top(&s.results).dist {
			break
		}
		if min_heap_len(&s.candidates) > 0 {
			links_prefetch(ix, min_heap_top(&s.candidates).id, layer)
		}
		count := gather(ix, s, list_get(ix, c.id, layer))
		ids := batch_ids(s)[:count]
		measure(ix, s, p, ids)
		dists := batch_dists(s)
		for e, i in ids {
			n := Candidate{dists[i], e}
			if max_heap_len(&s.results) < ef || closer(n, max_heap_top(&s.results)) {
				links_prefetch(ix, e, layer)
				push_candidate(s, n)
				if n.dist <= bound {
					push_result(s, n, ef)
				}
			}
		}
	}
}

search_layer_filtered :: proc(ix: ^Index, s: ^Scratch, p: Probe, ef: int, accept: Accept_Proc, actx: rawptr, budget: int, bound := UNBOUNDED) -> int #no_bounds_check {
	min_heap_clear(&s.candidates)
	max_heap_clear(&s.results)
	if !visited_begin(&s.visited, ix.slots) || !scratch_batch(s, ix.m0) {
		s.oom = true
		return 0
	}
	inspected := 0
	for e in s.entries {
		if !visited_mark(&s.visited, e.id) {
			continue
		}
		push_candidate(s, e)
		if e.dist > bound || budget > 0 && inspected >= budget {
			continue
		}
		inspected += 1
		if accept(actx, e.id) {
			push_result(s, e, ef)
		}
		if ix.twins > 0 {
			twins_accept(ix, s, p, e, ef, accept, actx, budget, &inspected)
		}
	}
	walk: for min_heap_len(&s.candidates) > 0 {
		c := min_heap_pop(&s.candidates)
		if max_heap_len(&s.results) >= ef && c.dist > max_heap_top(&s.results).dist {
			break
		}
		if min_heap_len(&s.candidates) > 0 {
			links_prefetch(ix, min_heap_top(&s.candidates).id, 0)
		}
		l := list_get(ix, c.id, 0)
		if budget <= 0 || ix.twins == 0 && budget - inspected >= l.count {
			count := gather(ix, s, l)
			ids := batch_ids(s)[:count]
			measure(ix, s, p, ids)
			dists := batch_dists(s)
			for e, i in ids {
				n := Candidate{dists[i], e}
				if max_heap_len(&s.results) < ef || closer(n, max_heap_top(&s.results)) {
					links_prefetch(ix, e, 0)
					push_candidate(s, n)
					if n.dist > bound {
						continue
					}
					inspected += 1
					if accept(actx, e) {
						push_result(s, n, ef)
					}
					if ix.twins > 0 {
						twins_accept(ix, s, p, n, ef, accept, actx, budget, &inspected)
					}
				}
			}
			continue
		}
		for e in list_decode(ix, l, batch_ids(s)) {
			if !visited_mark(&s.visited, e) {
				continue
			}
			n := Candidate{p.query(p.ctx, e), e}
			if max_heap_len(&s.results) < ef || closer(n, max_heap_top(&s.results)) {
				links_prefetch(ix, e, 0)
				if n.dist > bound {
					push_candidate(s, n)
					continue
				}
				if budget > 0 && inspected >= budget {
					break walk
				}
				push_candidate(s, n)
				inspected += 1
				if accept(actx, e) {
					push_result(s, n, ef)
				}
				if ix.twins > 0 && !twins_accept(ix, s, p, n, ef, accept, actx, budget, &inspected) {
					break walk
				}
			}
		}
	}
	return inspected
}

twins_accept :: proc(ix: ^Index, s: ^Scratch, p: Probe, c: Candidate, ef: int, accept: Accept_Proc, actx: rawptr, budget: int, inspected: ^int) -> bool {
	for t := ix.twin_link[c.id]; t != NONE; t = ix.twin_link[t] {
		if max_heap_len(&s.results) >= ef && !(c.dist < max_heap_top(&s.results).dist) {
			return true
		}
		if budget > 0 && inspected^ >= budget {
			return false
		}
		inspected^ += 1
		if accept(actx, t) {
			push_result(s, Candidate{p.query(p.ctx, t), t}, ef)
		}
	}
	return true
}

twins_merge :: proc(ix: ^Index, s: ^Scratch, p: Probe, want: int) {
	results_to_work(s, NONE)
	for c in s.work {
		if max_heap_len(&s.results) >= want && !closer(c, max_heap_top(&s.results)) {
			break
		}
		push_result(s, c, want)
		for t := ix.twin_link[c.id]; t != NONE; t = ix.twin_link[t] {
			if max_heap_len(&s.results) >= want && !(c.dist < max_heap_top(&s.results).dist) {
				break
			}
			push_result(s, Candidate{p.query(p.ctx, t), t}, want)
		}
	}
}

search :: proc(ix: ^Index, s: ^Scratch, query: Query_Proc, qctx: rawptr, k: int, ef: int, out: []Candidate, batch: Batch_Query_Proc = nil) -> (n: int, err: Error) {
	want := min(k, len(out))
	if ix.entry == NONE || want <= 0 {
		return 0, .None
	}
	p := Probe{query, qctx, batch}
	ep := descend(ix, s, p, 0)
	clear(&s.entries)
	candidates_add(s, &s.entries, ep)
	search_layer(ix, s, p, max(ef, want), 0)
	if ix.twins > 0 {
		twins_merge(ix, s, p, want)
	}
	n = results_take(s, want, out)
	if s.oom {
		s.oom = false
		return n, .Out_Of_Memory
	}
	return n, .None
}

search_filtered :: proc(ix: ^Index, s: ^Scratch, query: Query_Proc, qctx: rawptr, k: int, ef: int, accept: Accept_Proc, actx: rawptr, budget: int, out: []Candidate, batch: Batch_Query_Proc = nil) -> (n: int, inspected: int, err: Error) {
	if accept == nil {
		n, err = search(ix, s, query, qctx, k, ef, out, batch)
		return n, 0, err
	}
	want := min(k, len(out))
	if ix.entry == NONE || want <= 0 {
		return 0, 0, .None
	}
	p := Probe{query, qctx, batch}
	ep := descend(ix, s, p, 0)
	clear(&s.entries)
	candidates_add(s, &s.entries, ep)
	inspected = search_layer_filtered(ix, s, p, max(ef, want), accept, actx, budget)
	n = results_take(s, want, out)
	if s.oom {
		s.oom = false
		return n, inspected, .Out_Of_Memory
	}
	return n, inspected, .None
}

brute_force :: proc(ix: ^Index, s: ^Scratch, query: Query_Proc, qctx: rawptr, k: int, out: []Candidate, accept: Accept_Proc = nil, actx: rawptr = nil, batch: Batch_Query_Proc = nil) -> (n: int, err: Error) #no_bounds_check {
	want := min(k, len(out))
	if want <= 0 {
		return 0, .None
	}
	max_heap_clear(&s.results)
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
				push_result(s, Candidate{dists[j], ids[j]}, want)
			}
		}
	} else {
		for i in 0 ..< ix.slots {
			slot := u32(i)
			if !is_live(ix, slot) {
				continue
			}
			if accept != nil && !accept(actx, slot) {
				continue
			}
			push_result(s, Candidate{query(qctx, slot), slot}, want)
		}
	}
	n = results_take(s, want, out)
	if s.oom {
		s.oom = false
		return n, .Out_Of_Memory
	}
	return n, .None
}

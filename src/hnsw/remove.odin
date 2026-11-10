package hnsw

remove :: proc(ix: ^Index, s: ^Scratch, slot: u32) -> Error {
	if !is_live(ix, slot) {
		return .Not_Found
	}
	if ix.levels[slot] == LEVEL_TWIN {
		twin_detach(ix, slot)
		slot_push_free(ix, slot)
		ix.live -= 1
		return .None
	}
	level := int(ix.levels[slot])
	if !scratch_batch(s, ix.m0) {
		return .Out_Of_Memory
	}
	if ix.twin_link != nil && ix.twin_link[slot] != NONE {
		twin_promote(ix, s, slot)
		return .None
	}
	clear(&s.removed)
	s.removed_at[0] = 0
	for l in 0 ..= level {
		if _, err := append(&s.removed, ..list_decode(ix, list_get(ix, slot, l), batch_ids(s))); err != nil {
			return .Out_Of_Memory
		}
		s.removed_at[l + 1] = len(s.removed)
	}
	for l in 0 ..= level {
		for n in s.removed[s.removed_at[l]:s.removed_at[l + 1]] {
			list_remove(ix, n, l, slot)
		}
	}
	if level > 0 {
		upper_release(ix, ix.upper_at[slot], level)
	}
	slot_push_free(ix, slot)
	ix.live -= 1
	if ix.live == 0 {
		ix.entry = NONE
		ix.max_level = 0
		return .None
	}
	if ix.entry == slot {
		pick_entry(ix)
	}
	for l in 0 ..= level {
		group := s.removed[s.removed_at[l]:s.removed_at[l + 1]]
		for n in group {
			repair(ix, s, n, l, group)
		}
	}
	if s.oom {
		s.oom = false
		return .Out_Of_Memory
	}
	return .None
}

pick_entry :: proc "contextless" (ix: ^Index) {
	best := NONE
	best_level := -1
	for i in 0 ..< ix.slots {
		slot := u32(i)
		if is_node(ix, slot) && int(ix.levels[slot]) > best_level {
			best = slot
			best_level = int(ix.levels[slot])
		}
	}
	ix.entry = best
	ix.max_level = max(best_level, 0)
}

other_at_level :: proc "contextless" (ix: ^Index, n: u32, layer: int) -> u32 {
	for i in 0 ..< ix.slots {
		slot := u32(i)
		if slot != n && is_node(ix, slot) && int(ix.levels[slot]) >= layer {
			return slot
		}
	}
	return NONE
}

link_pair :: proc "contextless" (ix: ^Index, a, b: u32, layer: int) {
	list_append(ix, a, layer, b)
	list_append(ix, b, layer, a)
}

repair :: proc(ix: ^Index, s: ^Scratch, n: u32, layer: int, group: []u32) {
	cap := layer_cap(ix, layer)
	if list_count(ix, n, layer) >= cap {
		return
	}
	clear(&s.work)
	for c in group {
		if c == n || list_contains(ix, n, layer, c) {
			continue
		}
		candidates_add(s, &s.work, Candidate{ix.distance(ix.ctx, n, c), c})
	}
	candidates_sort(s.work[:])
	clear(&s.pruned)
	for c in s.work {
		if list_count(ix, n, layer) >= cap {
			break
		}
		if list_count(ix, c.id, layer) >= cap {
			continue
		}
		good := true
		for r in list_decode(ix, list_get(ix, n, layer), batch_ids(s)) {
			if ix.distance(ix.ctx, c.id, r) < c.dist {
				good = false
				break
			}
		}
		if good {
			link_pair(ix, n, c.id, layer)
		} else {
			candidates_add(s, &s.pruned, c)
		}
	}
	if ix.keep_pruned {
		for c in s.pruned {
			if list_count(ix, n, layer) >= cap {
				break
			}
			if list_count(ix, c.id, layer) >= cap {
				continue
			}
			link_pair(ix, n, c.id, layer)
		}
	}
	if list_count(ix, n, layer) == 0 {
		relink(ix, s, n, layer)
	}
}

relink :: proc(ix: ^Index, s: ^Scratch, n: u32, layer: int) {
	start := ix.entry
	if start == n {
		start = other_at_level(ix, n, layer)
	}
	if start == NONE {
		return
	}
	target := Node_Target{ix.distance, ix.ctx, n}
	p := node_probe(&target)
	ep := start
	d := ix.distance(ix.ctx, n, ep)
	for l := int(ix.levels[start]); l > layer; l -= 1 {
		ep, d = greedy_closest(ix, s, p, ep, d, l)
	}
	clear(&s.entries)
	if ep != n {
		candidates_add(s, &s.entries, Candidate{d, ep})
	}
	if layer + 1 <= int(ix.levels[n]) {
		for v in list_decode(ix, list_get(ix, n, layer + 1), batch_ids(s)) {
			candidates_add(s, &s.entries, Candidate{ix.distance(ix.ctx, n, v), v})
		}
	}
	if len(s.entries) == 0 {
		candidates_add(s, &s.entries, Candidate{ix.distance(ix.ctx, n, start), start})
	}
	search_layer(ix, s, p, ix.ef_construction, layer)
	results_to_work(s, n)
	select_neighbors(ix, s, n, ix.m, layer, ix.extend_candidates, ix.keep_pruned)
	connect(ix, s, n, layer)
}

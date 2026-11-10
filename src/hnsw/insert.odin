package hnsw

insert :: proc(ix: ^Index, s: ^Scratch, slot: u32, ef_construction := 0, query: Query_Proc = nil, qctx: rawptr = nil, batch: Batch_Query_Proc = nil) -> Error {
	if int(slot) >= ix.slots || ix.levels[slot] != LEVEL_RESERVED {
		return .Not_Reserved
	}
	if !visited_begin(&s.visited, ix.slots) || !scratch_batch(s, ix.m0) {
		return .Out_Of_Memory
	}
	ef := ef_construction > 0 ? ef_construction : ix.ef_construction
	level := random_level(ix)
	if ix.entry == NONE {
		if err := node_place(ix, slot, level); err != .None {
			return err
		}
		ix.entry = slot
		ix.max_level = level
		return .None
	}
	target := Node_Target{ix.distance, ix.ctx, slot}
	p := node_probe(&target)
	if query != nil {
		p = Probe{query, qctx, batch}
	}
	ep := ix.entry
	d := p.query(p.ctx, ep)
	for l := ix.max_level; l > level; l -= 1 {
		ep, d = greedy_closest(ix, s, p, ep, d, l)
	}
	clear(&s.entries)
	candidates_add(s, &s.entries, Candidate{d, ep})
	top := min(ix.max_level, level)
	clear(&s.layered)
	for l := top; l >= 0; l -= 1 {
		search_layer(ix, s, p, ef, l)
		results_to_work(s, slot)
		work_to_entries(s)
		if top > 0 {
			s.layer_span[l] = {len(s.layered), len(s.layered) + len(s.work)}
			if _, err := append(&s.layered, ..s.work[:]); err != nil {
				s.oom = true
				s.layer_span[l] = {}
			}
		}
	}
	if head := coincident_head(ix, s, p, slot); head != NONE && twin_attach(ix, slot, head) {
		if s.oom {
			s.oom = false
			return .Out_Of_Memory
		}
		return .None
	}
	if err := node_place(ix, slot, level); err != .None {
		s.oom = false
		return err
	}
	for l := top; l >= 0; l -= 1 {
		if top > 0 {
			span := s.layer_span[l]
			clear(&s.work)
			if _, err := append(&s.work, ..s.layered[span[0]:span[1]]); err != nil {
				s.oom = true
			}
		}
		select_neighbors(ix, s, slot, ix.m, l, ix.extend_candidates, ix.keep_pruned)
		connect(ix, s, slot, l)
	}
	if level > ix.max_level {
		ix.entry = slot
		ix.max_level = level
	}
	if s.oom {
		s.oom = false
		return .Out_Of_Memory
	}
	return .None
}

node_place :: proc(ix: ^Index, slot: u32, level: int) -> Error {
	ix.upper_at[slot] = NONE
	if level > 0 {
		offset, err := upper_alloc(ix, level)
		if err != .None {
			return err
		}
		ix.upper_at[slot] = offset
	}
	ix.levels[slot] = u8(level)
	ix.degree0[slot] = 0
	ix.node_uid += 1
	ix.live += 1
	return .None
}

select_neighbors :: proc(ix: ^Index, s: ^Scratch, base: u32, m: int, layer: int, extend_candidates, keep_pruned: bool) {
	clear(&s.selected)
	clear(&s.pruned)
	if extend_candidates {
		if !visited_begin(&s.visited, ix.slots) {
			s.oom = true
			return
		}
		visited_mark(&s.visited, base)
		for c in s.work {
			visited_mark(&s.visited, c.id)
		}
		n := len(s.work)
		for i in 0 ..< n {
			for e in list_decode(ix, list_get(ix, s.work[i].id, layer), batch_ids(s)) {
				if visited_mark(&s.visited, e) {
					candidates_add(s, &s.work, Candidate{ix.distance(ix.ctx, base, e), e})
				}
			}
		}
		candidates_sort(s.work[:])
	}
	for c in s.work {
		if len(s.selected) >= m {
			break
		}
		good := true
		for r in s.selected {
			if ix.distance(ix.ctx, c.id, r.id) < c.dist {
				good = false
				break
			}
		}
		if good {
			candidates_add(s, &s.selected, c)
		} else {
			candidates_add(s, &s.pruned, c)
		}
	}
	if keep_pruned {
		for c in s.pruned {
			if len(s.selected) >= m {
				break
			}
			candidates_add(s, &s.selected, c)
		}
	}
}

connect :: proc(ix: ^Index, s: ^Scratch, q: u32, layer: int) {
	cap := layer_cap(ix, layer)
	own := list_get(ix, q, layer)
	count := 0
	for c in s.selected {
		if count >= cap {
			break
		}
		list_put(ix, own, count, c.id)
		count += 1
	}
	list_set_count(ix, q, layer, count)
	for c, i in s.selected {
		if i >= count {
			break
		}
		e := c.id
		if list_count(ix, e, layer) < cap {
			list_append(ix, e, layer, q)
			continue
		}
		victim := shrink_victim(ix, s, e, layer, q, c.dist)
		if victim == q {
			list_remove(ix, q, layer, e)
		} else {
			list_replace(ix, e, layer, victim, q)
			list_remove(ix, victim, layer, e)
		}
		if list_count(ix, victim, layer) == 0 || victim != q && stranded(ix, s, victim, e, layer) {
			adopt(ix, s, victim, e, layer)
		}
	}
}

adopt :: proc(ix: ^Index, s: ^Scratch, orphan, hub: u32, layer: int) {
	cap := layer_cap(ix, layer)
	best := Candidate{UNBOUNDED, NONE}
	for y in list_decode(ix, list_get(ix, hub, layer), batch_ids(s)) {
		if y == orphan || list_count(ix, y, layer) >= cap || list_contains(ix, y, layer, orphan) || list_contains(ix, orphan, layer, y) {
			continue
		}
		c := Candidate{ix.distance(ix.ctx, orphan, y), y}
		if best.id == NONE || closer(c, best) {
			best = c
		}
	}
	if best.id != NONE {
		link_pair(ix, orphan, best.id, layer)
	}
}

shrink_victim :: proc(ix: ^Index, s: ^Scratch, e: u32, layer: int, q: u32, dq: f32) -> u32 {
	clear(&s.shrink)
	links := list_decode(ix, list_get(ix, e, layer), batch_ids(s))
	if ix.prefetch != nil {
		for y in links {
			ix.prefetch(ix.prefetch_ctx, y)
		}
	}
	for y in links {
		candidates_add(s, &s.shrink, Candidate{ix.distance(ix.ctx, e, y), y})
	}
	candidates_add(s, &s.shrink, Candidate{dq, q})
	candidates_sort(s.shrink[:])
	clear(&s.kept)
	clear(&s.dropped)
	clear(&s.blockers)
	for c in s.shrink {
		blocker := NONE
		for r in s.kept {
			if ix.distance(ix.ctx, c.id, r.id) < c.dist {
				blocker = r.id
				break
			}
		}
		if blocker == NONE {
			candidates_add(s, &s.kept, c)
		} else {
			candidates_add(s, &s.dropped, c)
			if _, err := append(&s.blockers, blocker); err != nil {
				s.oom = true
			}
		}
	}
	for i := len(s.dropped) - 1; i >= 0; i -= 1 {
		v := s.dropped[i].id
		if i < len(s.blockers) && list_count(ix, v, layer) > 1 && list_contains(ix, v, layer, s.blockers[i]) {
			return v
		}
	}
	for c in s.dropped {
		if c.id == q && list_count(ix, q, layer) > 1 {
			return q
		}
	}
	for i := len(s.dropped) - 1; i >= 0; i -= 1 {
		if list_count(ix, s.dropped[i].id, layer) > 1 {
			return s.dropped[i].id
		}
	}
	for i := len(s.kept) - 1; i >= 0; i -= 1 {
		if list_count(ix, s.kept[i].id, layer) > 1 {
			return s.kept[i].id
		}
	}
	return s.shrink[len(s.shrink) - 1].id
}

ISLAND_LIMIT :: 64

ISLAND_SLOTS :: 256

island_insert :: #force_inline proc "contextless" (seen: ^[ISLAND_SLOTS]u32, id: u32) -> bool #no_bounds_check {
	h := (id * 0x9E37_79B1) >> 24
	for {
		if seen[h] == id {
			return false
		}
		if seen[h] == NONE {
			seen[h] = id
			return true
		}
		h = (h + 1) & (ISLAND_SLOTS - 1)
	}
}

stranded :: proc(ix: ^Index, s: ^Scratch, from, hub: u32, layer: int) -> bool #no_bounds_check {
	seen: [ISLAND_SLOTS]u32
	for &x in seen {
		x = NONE
	}
	trail: [ISLAND_LIMIT]u32
	trail[0] = from
	count := 1
	island_insert(&seen, from)
	for head := 0; head < count; head += 1 {
		for y in list_decode(ix, list_get(ix, trail[head], layer), batch_ids(s)) {
			if y == hub {
				return false
			}
			if island_insert(&seen, y) {
				if count == ISLAND_LIMIT {
					return false
				}
				trail[count] = y
				count += 1
			}
		}
	}
	return true
}

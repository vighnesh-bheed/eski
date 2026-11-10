package hnsw

import "base:runtime"

twin_grow :: proc(ix: ^Index, n: int) -> bool {
	if ix.twin_link == nil || n <= ix.twin_cap {
		return true
	}
	if !array_resize(&ix.twin_link, ix.twin_cap, n, ix.allocator) {
		return false
	}
	for i in ix.twin_cap ..< n {
		ix.twin_link[i] = NONE
	}
	ix.twin_cap = n
	return true
}

twin_prev :: #force_inline proc "contextless" (ix: ^Index, twin: u32) -> u32 {
	return word_get(ix.links0[int(twin) * ix.row:], 0, ix.width)
}

twin_prev_set :: #force_inline proc "contextless" (ix: ^Index, twin: u32, prev: u32) {
	word_set(ix.links0[int(twin) * ix.row:], 0, ix.width, prev)
}

coincident_head :: proc(ix: ^Index, s: ^Scratch, p: Probe, slot: u32) -> u32 {
	t := ix.coincident
	if t == 0 || len(s.work) < t {
		return NONE
	}
	tie := s.work[0].dist
	if s.work[t - 1].dist != tie || !(tie <= p.query(p.ctx, slot)) {
		return NONE
	}
	head := NONE
	found := 0
	for c in s.work {
		if c.dist != tie {
			break
		}
		if tie <= ix.distance(ix.ctx, c.id, c.id) {
			if head == NONE {
				head = c.id
			}
			found += 1
			if found == t {
				return head
			}
		}
	}
	return NONE
}

twin_attach :: proc(ix: ^Index, slot, head: u32) -> bool {
	if ix.twin_link == nil {
		if !array_resize(&ix.twin_link, 0, ix.cap, ix.allocator) {
			return false
		}
		ix.twin_cap = ix.cap
		for i in 0 ..< ix.cap {
			ix.twin_link[i] = NONE
		}
	}
	first := ix.twin_link[head]
	ix.twin_link[head] = slot
	ix.twin_link[slot] = first
	twin_prev_set(ix, slot, head)
	if first != NONE {
		twin_prev_set(ix, first, slot)
	}
	ix.levels[slot] = LEVEL_TWIN
	ix.degree0[slot] = 0
	ix.upper_at[slot] = NONE
	ix.twins += 1
	ix.node_uid += 1
	ix.live += 1
	return true
}

twin_detach :: proc "contextless" (ix: ^Index, slot: u32) {
	prev := twin_prev(ix, slot)
	next := ix.twin_link[slot]
	ix.twin_link[prev] = next
	if next != NONE {
		twin_prev_set(ix, next, prev)
	}
	ix.twin_link[slot] = NONE
	ix.twins -= 1
}

twin_promote :: proc(ix: ^Index, s: ^Scratch, head: u32) {
	heir := ix.twin_link[head]
	level := int(ix.levels[head])
	runtime.mem_copy_non_overlapping(&ix.links0[int(heir) * ix.row], &ix.links0[int(head) * ix.row], ix.row)
	ix.degree0[heir] = ix.degree0[head]
	ix.levels[heir] = ix.levels[head]
	ix.upper_at[heir] = ix.upper_at[head]
	for l in 0 ..= level {
		for y in list_decode(ix, list_get(ix, heir, l), batch_ids(s)) {
			list_replace(ix, y, l, head, heir)
		}
	}
	if ix.entry == head {
		ix.entry = heir
	}
	ix.twins -= 1
	slot_push_free(ix, head)
	ix.live -= 1
}

next_twin :: proc "contextless" (ix: ^Index, slot: u32) -> u32 {
	if ix.twin_link == nil || !is_live(ix, slot) {
		return NONE
	}
	return ix.twin_link[slot]
}

twin_head :: proc "contextless" (ix: ^Index, slot: u32) -> u32 {
	if !is_twin(ix, slot) {
		return NONE
	}
	at := slot
	for ix.levels[at] == LEVEL_TWIN {
		at = twin_prev(ix, at)
	}
	return at
}

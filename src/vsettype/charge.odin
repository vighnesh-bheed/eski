package vsettype

import "../hnsw"
import lbl "../label"
import "../rax"
import "../vfilter"
import "../vmath"

CHUNK_MAP_FLOOR :: 128 << 10
CHUNK_PAGE :: 4096
CHUNK_ALIGN_SLACK :: 32
CHUNK_SPARE :: 16

Tally :: struct {
	content: int,
	levels:  int,
}

Tally_Mark :: struct {
	tally:   ^Tally,
	slot:    u32,
	heir:    u32,
	content: int,
	levels:  int,
}

chunk_bytes :: proc "contextless" (size: int) -> int {
	if size <= 0 {
		return 0
	}
	n := nominal_bytes(size)
	if size >= CHUNK_MAP_FLOOR {
		need := max(32, (size + NOMINAL_HEADER_BYTES + NOMINAL_ALIGN - 1) &~ (NOMINAL_ALIGN - 1))
		n = max(n, ((need + NOMINAL_HEADER_BYTES + CHUNK_PAGE - 1) &~ (CHUNK_PAGE - 1)) - 2 * NOMINAL_HEADER_BYTES)
	}
	return n
}

block_bytes_of :: #force_inline proc "contextless" (size: int) -> int {
	if size <= 0 {
		return 0
	}
	return chunk_bytes(size) + CHUNK_SPARE
}

aligned_bytes :: #force_inline proc "contextless" (size: int) -> int {
	if size <= 0 {
		return 0
	}
	return chunk_bytes(size) + CHUNK_ALIGN_SLACK
}

element_bytes :: #force_inline proc "contextless" (e: ^Element) -> int {
	return block_bytes_of(int(e.len)) + block_bytes_of(vfilter.attribute_size(e.attr)) + NAME_INDEX_BYTES + int(e.len)
}

owner_scope_bytes :: proc "contextless" () -> int {
	return chunk_bytes(size_of(Owner_Scope)) + chunk_bytes(int(SCOPE_PARTS_MIN) * size_of(^Part_Head)) + chunk_bytes(size_of(rax.Rax)) + size_of(Owner_Slot) + size_of(^Part_Head) + size_of(u32)
}

shared_slot_bytes :: proc "contextless" () -> int {
	return 2 * size_of(^Partition)
}

SET_TABLE_MIN :: 4

set_fixed_bytes :: proc "contextless" (owned: bool) -> int {
	n := chunk_bytes(size_of(Vset_Object)) + chunk_bytes(size_of(rax.Rax)) + chunk_bytes(size_of(Labelled))
	if owned {
		return n + chunk_bytes(size_of(Owner_Index)) + chunk_bytes(SET_TABLE_MIN * size_of(^Part_Head)) + chunk_bytes(SET_TABLE_MIN * size_of(u32)) + chunk_bytes(int(OWNER_SLOTS_MIN) * size_of(Owner_Slot))
	}
	return n + 2 * chunk_bytes(SET_TABLE_MIN * size_of(^Partition))
}

part_tally :: #force_inline proc "contextless" (p: ^Part_Head) -> ^Tally {
	switch p.kind {
	case .Core:
		return nil
	case .Block:
		return &(^Part_Block)(p).tally
	case .Compact:
		return &(^Compact_Block)(p).tally
	}
	return nil
}

part_graphed :: #force_inline proc "contextless" (p: ^Part_Head) -> ^hnsw.Index {
	full := part_full(p)
	if full == nil || p.mode == .Flat {
		return nil
	}
	return &full.graph
}

slot_levels :: proc "contextless" (p: ^Part_Head, slot: u32) -> int {
	g := part_graphed(p)
	if g == nil || slot == NIL_SLOT || int(slot) >= g.slots {
		return 0
	}
	if lv := g.levels[slot]; lv <= hnsw.LEVEL_CAP {
		return int(lv)
	}
	return 0
}

slot_heir :: proc "contextless" (p: ^Part_Head, slot: u32) -> u32 {
	g := part_graphed(p)
	if g == nil || g.twin_link == nil || slot == NIL_SLOT || int(slot) >= g.slots || g.levels[slot] > hnsw.LEVEL_CAP {
		return NIL_SLOT
	}
	return g.twin_link[slot]
}

slot_live :: #force_inline proc "contextless" (p: ^Part_Head, slot: u32) -> bool {
	if slot == NIL_SLOT || slot >= p.element_cap {
		return false
	}
	pos := int(p.elements[slot].pos)
	return pos < p.count && p.order[pos] == slot
}

tally_count :: proc "contextless" (p: ^Part_Head) -> (t: Tally) {
	for i in 0 ..< p.count {
		slot := p.order[i]
		t.content += element_bytes(&p.elements[slot])
		t.levels += slot_levels(p, slot)
	}
	return
}

tally_refresh :: proc "contextless" (p: ^Part_Head) {
	if t := part_tally(p); t != nil {
		t^ = tally_count(p)
	}
}

tally_levels_refresh :: proc "contextless" (p: ^Part_Head) {
	if t := part_tally(p); t != nil {
		levels := 0
		for i in 0 ..< p.count {
			levels += slot_levels(p, p.order[i])
		}
		t.levels = levels
	}
}

tally_mark :: proc "contextless" (p: ^Part_Head, slot: u32) -> (m: Tally_Mark) {
	m.tally = part_tally(p)
	m.slot = slot
	m.heir = NIL_SLOT
	if m.tally == nil {
		return
	}
	m.heir = slot_heir(p, slot)
	if slot_live(p, slot) {
		m.content = element_bytes(&p.elements[slot])
	}
	m.levels = slot_levels(p, slot) + slot_levels(p, m.heir)
	return
}

tally_settle :: proc "contextless" (p: ^Part_Head, m: ^Tally_Mark) {
	if m.tally == nil {
		return
	}
	content := 0
	if slot_live(p, m.slot) {
		content = element_bytes(&p.elements[m.slot])
	}
	levels := slot_levels(p, m.slot) + slot_levels(p, m.heir)
	m.tally.content += content - m.content
	m.tally.levels += levels - m.levels
	m.content = content
	m.levels = levels
}

tally_drop :: #force_inline proc "contextless" (p: ^Part_Head, slot: u32) {
	if t := part_tally(p); t != nil {
		t.content -= element_bytes(&p.elements[slot])
		t.levels -= slot_levels(p, slot)
	}
}

part_pool_trim :: proc(p: ^Part_Head) {
	g := part_graphed(p)
	if g == nil || g.upper_len <= hnsw.upper_room(g, 0) {
		return
	}
	levels: int
	if t := part_tally(p); t != nil {
		levels = t.levels
	} else {
		levels = hnsw.upper_lists(g)
	}
	if g.upper_len > hnsw.upper_room(g, levels * (g.m + 1)) {
		hnsw.upper_compact(g)
	}
}

part_fixed_bytes :: proc "contextless" (p: ^Part_Head) -> int {
	switch p.kind {
	case .Core:
		return set_fixed_bytes(false) + chunk_bytes(PART_FIXED_BYTES) + shared_slot_bytes()
	case .Block:
		if p.owner != SHARED {
			return set_fixed_bytes(true) + chunk_bytes(PART_FIXED_BYTES) + owner_scope_bytes()
		}
		return set_fixed_bytes(false) + chunk_bytes(PART_FIXED_BYTES) + shared_slot_bytes()
	case .Compact:
		return set_fixed_bytes(true) + chunk_bytes(COMPACT_FIXED_BYTES) + owner_scope_bytes()
	}
	return 0
}

part_content_bytes :: proc "contextless" (s: Vset, p: ^Part_Head) -> int {
	tl: Tally
	if t := part_tally(p); t != nil {
		tl = t^
	} else {
		tl = tally_count(p)
	}
	n := part_fixed_bytes(p) + tl.content
	if cap := int(p.arena.cap); cap > 0 {
		n += aligned_bytes(vmath.arena_layout(p.arena.elem, p.arena.dim, cap, p.arena.family).size)
		slots := min(grow_capacity(cap), SLOT_MAX)
		n += block_bytes_of(slots * size_of(Element)) + block_bytes_of(slots * size_of(u32))
	}
	if g := part_graphed(p); g != nil && g.cap > 0 {
		gc := g.cap
		n += aligned_bytes(hnsw.links_bytes(gc, g.row)) + block_bytes_of(gc * size_of(u16)) + block_bytes_of(gc) + block_bytes_of(gc * size_of(u32))
		n += block_bytes_of(hnsw.pool_bytes(hnsw.upper_bound(g, tl.levels * (g.m + 1)), g.width))
		if g.twin_link != nil {
			n += block_bytes_of(gc * size_of(u32))
		}
	}
	return n
}

label_charge :: proc "contextless" (s: Vset, l: lbl.Id) -> int {
	if s == nil {
		return 0
	}
	p := part_at_label(s, l)
	if p == nil {
		return 0
	}
	if s.lab == nil {
		return part_content_bytes(s, &s.core)
	}
	return part_content_bytes(s, p)
}

scope_charge :: proc "contextless" (s: Vset, l: lbl.Id, o: Owner) -> int {
	if o == SHARED {
		return label_charge(s, l)
	}
	p := part_at_scope(s, l, o)
	if p == nil {
		return 0
	}
	return part_content_bytes(s, p)
}

charges_total :: proc "contextless" (s: Vset) -> int {
	if s == nil {
		return 0
	}
	if s.lab == nil {
		if s.count == 0 {
			return 0
		}
		return part_content_bytes(s, &s.core)
	}
	n := 0
	for i in 0 ..< s.lab.sorted_len {
		n += part_content_bytes(s, s.lab.sorted[i])
	}
	if idx := s.lab.owners; idx != nil {
		for i in 0 ..< idx.part_high {
			if p := idx.parts[i]; p != nil {
				n += part_content_bytes(s, p)
			}
		}
	}
	return n
}

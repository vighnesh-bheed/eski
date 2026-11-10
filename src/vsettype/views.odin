package vsettype

import "../hnsw"
import "../rax"
import "../vmath"

Raw_Embedding :: struct {
	quant:     Quant,
	data:      []u8,
	norm:      f32,
	range:     f32,
	has_range: bool,
}

embedding :: proc "contextless" (s: Vset, slot: u32, out: []f32) -> []f32 {
	return part_embedding(&s.core, slot, out)
}

part_embedding :: proc "contextless" (p: ^Part_Head, slot: u32, out: []f32) -> []f32 {
	values := out[:p.arena.dim]
	vmath.arena_decode(&p.arena, slot, values)
	return values
}

raw_embedding :: proc "contextless" (s: Vset, slot: u32) -> Raw_Embedding {
	return part_raw_embedding(&s.core, slot)
}

part_raw_embedding :: proc "contextless" (p: ^Part_Head, slot: u32) -> Raw_Embedding {
	return Raw_Embedding {
		quant = elem_quant(p.arena.elem),
		data = vmath.arena_bytes(&p.arena, slot),
		norm = vmath.arena_norm(&p.arena, slot),
		range = vmath.arena_range(&p.arena, slot),
		has_range = p.arena.elem == .Int8,
	}
}

link_layers :: proc "contextless" (s: Vset, slot: u32) -> int {
	return part_link_layers(&s.core, slot)
}

part_link_layers :: proc "contextless" (p: ^Partition, slot: u32) -> int {
	if hnsw.is_twin(&p.graph, slot) {
		return 1
	}
	return hnsw.node_layers(&p.graph, slot)
}

layer_links :: proc(s: Vset, slot: u32, i: int, buf: ^[dynamic]u32) -> []u32 {
	return part_layer_links(&s.core, slot, i, buf)
}

part_layer_links :: proc(p: ^Partition, slot: u32, i: int, buf: ^[dynamic]u32) -> []u32 {
	if hnsw.is_twin(&p.graph, slot) {
		if i != 0 {
			return nil
		}
		resize(buf, 1)
		buf[0] = hnsw.twin_head(&p.graph, slot)
		return buf[:1]
	}
	if resize(buf, p.graph.m0) != nil {
		return nil
	}
	return hnsw.links_top_first(&p.graph, slot, i, buf[:])
}

link_score :: proc "contextless" (s: Vset, a: u32, b: u32) -> f32 {
	return part_link_score(&s.core, a, b)
}

part_link_score :: proc "contextless" (p: ^Part_Head, a: u32, b: u32) -> f32 {
	return vmath.edge_score(vmath.arena_score(&p.arena, a, b))
}

Lex_Kind :: enum u8 {
	Min,
	Max,
	Inclusive,
	Exclusive,
}

Lex_Bound :: struct {
	kind:  Lex_Kind,
	value: []u8,
}

lex_compare :: proc "contextless" (a: []u8, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return -1 if len(a) < len(b) else 1
}

lex_range :: proc(s: Vset, start: Lex_Bound, end: Lex_Bound, count: int, out: ^[dynamic]u32) {
	if s == nil || s.lab != nil || count == 0 || start.kind == .Max || end.kind == .Min {
		return
	}
	it: rax.Iterator
	rax.start(&it, s.names)
	defer rax.stop(&it)
	switch start.kind {
	case .Min, .Max:
		rax.seek(&it, "^")
	case .Inclusive:
		rax.seek(&it, ">=", start.value)
	case .Exclusive:
		rax.seek(&it, ">", start.value)
	}
	taken := 0
	for rax.next(&it) {
		key := rax.key(&it)
		#partial switch end.kind {
		case .Inclusive:
			if lex_compare(key, end.value) > 0 {
				return
			}
		case .Exclusive:
			if lex_compare(key, end.value) >= 0 {
				return
			}
		}
		append(out, u32(uintptr(it.data) - 1))
		taken += 1
		if count > 0 && taken >= count {
			return
		}
	}
}

Element_Iterator :: struct {
	s:  Vset,
	at: int,
}

element_iterator :: proc "contextless" (s: Vset) -> Element_Iterator {
	return Element_Iterator{s = s}
}

next_element :: proc "contextless" (it: ^Element_Iterator) -> (slot: u32, ok: bool) {
	if it.s == nil || it.at >= it.s.count {
		return NIL_SLOT, false
	}
	slot = it.s.order[it.at]
	it.at += 1
	return slot, true
}

package vsettype

import "../hnsw"
import "../vmath"
import "../vfilter"

part_insert_raw :: proc(s: Vset, p: ^Partition, name: []u8, data: []u8, norm: f32, range: f32, attr: vfilter.Attribute, sc: ^Scratch) -> (slot: u32, f: Failure) {
	if err := part_ensure_slot(s, p); err != .None {
		return NIL_SLOT, failure(err)
	}
	name_copy, named := part_copy_name(s, p, name)
	if !named {
		return NIL_SLOT, failure(.Out_Of_Memory)
	}
	aslot, aerr := vmath.arena_alloc(&p.arena)
	if aerr != nil {
		part_free(s, p, name_copy)
		return NIL_SLOT, failure(.Out_Of_Memory)
	}
	if !vmath.arena_set_raw(&p.arena, aslot, data, norm, range) {
		vmath.arena_free(&p.arena, aslot)
		part_free(s, p, name_copy)
		return NIL_SLOT, failure(.Invalid_Parameter)
	}
	slot = aslot
	if p.mode != .Flat {
		gslot, gerr := hnsw.reserve(&p.graph)
		if gerr != .None || gslot != aslot {
			if gerr == .None {
				hnsw.release(&p.graph, gslot)
			}
			vmath.arena_free(&p.arena, aslot)
			part_free(s, p, name_copy)
			return NIL_SLOT, failure(.Out_Of_Memory)
		}
		if err := part_insert_node(p, slot, EF_DEFAULT, sc, nil); err != .None {
			vmath.arena_free(&p.arena, slot)
			part_free(s, p, name_copy)
			return NIL_SLOT, failure(err)
		}
	} else {
		p.graph.node_uid += 1
	}
	e := &p.elements[slot]
	e^ = Element{name = name_copy, len = u32(len(name)), seq = p.graph.node_uid}
	part_replace_attribute(s, p, e, attr)
	order_append(p, slot)
	s.version += 1
	part_refresh_prefetch(p)
	return slot, {}
}

relabel_at :: proc(s: Vset, a: ^Access, to: ^Access, name: []u8, scratch: ^Scratch = nil) -> (from_gone: bool, to_new: bool, f: Failure) {
	one: Ref
	copies := names_lookup(s, name, &one)
	at := exact_copy(a, s, copies)
	if at < 0 {
		if vi := visible_other(a, s, copies); vi >= 0 {
			return false, false, in_use(s, copies[vi])
		}
		return false, false, failure(.Element_Not_Found)
	}
	for r in copies {
		if ref_label(s, r) == to.label {
			return false, false, in_use(s, r)
		}
	}
	src := copies[at]
	sp := ref_part(s, src)
	data := vmath.arena_bytes(&sp.arena, src.slot)
	raw := make([]u8, len(data), context.temp_allocator)
	copy(raw, data)
	norm := vmath.arena_norm(&sp.arena, src.slot)
	rng := vmath.arena_range(&sp.arena, src.slot)
	text, has_attr := ref_attribute(s, src)
	kept_text := make([]u8, len(text), context.temp_allocator)
	copy(kept_text, transmute([]u8)text)
	kept_name := make([]u8, len(name), context.temp_allocator)
	copy(kept_name, name)
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	tp, created, err := part_for_write(s, to)
	if err != .None {
		return false, false, failure(err)
	}
	copies = names_lookup(s, kept_name, &one)
	at = exact_copy(a, s, copies)
	if at < 0 {
		if created {
			part_retire(s, tp)
		}
		return false, false, failure(.Element_Not_Found)
	}
	src = copies[at]
	sp = ref_part(s, src)
	attr: vfilter.Attribute
	if has_attr {
		made: bool
		if attr, made = part_make_attribute(s, tp, kept_text, true); !made {
			if created {
				part_retire(s, tp)
			}
			return false, false, failure(.Out_Of_Memory)
		}
	}
	slot, ferr := part_insert_raw(s, tp, kept_name, raw, norm, rng, attr, sc)
	if ferr.err != .None {
		part_discard_attribute(s, tp, &attr)
		if created {
			part_retire(s, tp)
		}
		return false, false, ferr
	}
	if !names_add(s, kept_name, Ref{slot = slot, part = tp.id}) {
		part_graph_remove(tp, slot, sc)
		part_drop(s, tp, slot)
		if created {
			part_retire(s, tp)
		}
		return false, false, failure(.Out_Of_Memory)
	}
	if s.lab != nil {
		s.lab.total += 1
		part_maybe_graduate(s, tp, sc)
	}
	copies = names_lookup(s, kept_name, &one)
	at = exact_copy(a, s, copies)
	src = copies[at]
	sp = ref_part(s, src)
	if gerr := part_graph_remove(sp, src.slot, sc); gerr != .None {
		return false, created, failure(gerr)
	}
	ch: Change
	drop_ref(s, sp, src.slot, &ch)
	return ch.label_gone, created, {}
}

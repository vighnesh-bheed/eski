package vsettype

import "../vfilter"

visible_other :: proc "contextless" (a: ^Access, s: Vset, copies: []Ref) -> int {
	best := -1
	for r, i in copies {
		l := ref_label(s, r)
		if l == a.label || !sees(a, l) {
			continue
		}
		if best < 0 || resolution_compare(a, l, ref_label(s, copies[best])) > 0 {
			best = i
		}
	}
	return best
}

in_use :: proc "contextless" (s: Vset, r: Ref) -> Failure {
	return Failure{err = .Name_In_Use, label = ref_label(s, r)}
}

drop_ref :: proc(s: Vset, p: ^Partition, slot: u32, ch: ^Change) {
	names_remove(s, part_element_name(p, slot), Ref{slot = slot, part = p.id})
	part_drop(s, p, slot)
	if s.lab != nil {
		s.lab.total -= 1
		if p.count == 0 {
			part_retire(s, p)
			ch.label_gone = true
		} else {
			part_maybe_flatten(s, p)
		}
	} else if s.count == 0 {
		ch.label_gone = true
	}
	ch.emptied = card(s) == 0
}

add_at :: proc(s: Vset, a: ^Access, req: ^Add_Request, scratch: ^Scratch = nil) -> (ch: Change, f: Failure) {
	if f = check_add(s, req); f.err != .None {
		return
	}
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	vector, ok := stored_vector(s, req.vector, sc)
	if !ok {
		return ch, failure(.Out_Of_Memory)
	}
	return apply_add_at(s, a, req, vector, sc, nil, PART_NONE)
}

apply_add_at :: proc(s: Vset, a: ^Access, req: ^Add_Request, vector: []f32, sc: ^Scratch, cache: ^Distance_Cache, cache_part: u32) -> (ch: Change, f: Failure) {
	ef := request_ef(req)
	one: Ref
	copies := names_lookup(s, req.name, &one)
	if at := exact_copy(a, s, copies); at >= 0 {
		r := copies[at]
		p := ref_part(s, r)
		c := cache if r.part == cache_part && p.mode != .Flat else nil
		if c != nil {
			cache_forget(c, r.slot)
		}
		attr: vfilter.Attribute
		if req.set_attr {
			made: bool
			if attr, made = part_make_attribute(s, p, req.attr); !made {
				return ch, failure(.Out_Of_Memory)
			}
		}
		dropped: bool
		if f, dropped = part_update(s, p, r.slot, vector, ef, sc, c); f.err != .None {
			part_discard_attribute(s, p, &attr)
			if dropped {
				ch.dropped = true
				drop_ref(s, p, r.slot, &ch)
			}
			return ch, f
		}
		if req.set_attr {
			part_replace_attribute(s, p, &p.elements[r.slot], attr)
		}
		return ch, {}
	}
	if vi := visible_other(a, s, copies); vi >= 0 {
		return ch, in_use(s, copies[vi])
	}
	p, created, err := part_for_write(s, a)
	if err != .None {
		return ch, failure(err)
	}
	attr: vfilter.Attribute
	if req.set_attr {
		made: bool
		if attr, made = part_make_attribute(s, p, req.attr, true); !made {
			if created {
				part_retire(s, p)
			}
			return ch, failure(.Out_Of_Memory)
		}
	}
	c := cache if p.id == cache_part && p.mode != .Flat else nil
	slot: u32
	if slot, f = part_insert(s, p, req.name, vector, attr, ef, sc, c); f.err != .None {
		part_discard_attribute(s, p, &attr)
		if created {
			part_retire(s, p)
		}
		return ch, f
	}
	if !names_add(s, req.name, Ref{slot = slot, part = p.id}) {
		part_graph_remove(p, slot, sc)
		part_drop(s, p, slot)
		if created {
			part_retire(s, p)
		}
		return ch, failure(.Out_Of_Memory)
	}
	if s.lab != nil {
		s.lab.total += 1
		part_maybe_graduate(s, p, sc)
	}
	ch.added = true
	ch.label_new = created
	return ch, {}
}

remove_at :: proc(s: Vset, a: ^Access, name: []u8, scratch: ^Scratch = nil) -> (ch: Change, f: Failure) {
	one: Ref
	copies := names_lookup(s, name, &one)
	at := exact_copy(a, s, copies)
	if at < 0 {
		if vi := visible_other(a, s, copies); vi >= 0 {
			return ch, in_use(s, copies[vi])
		}
		return ch, {}
	}
	r := copies[at]
	p := ref_part(s, r)
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	if err := part_graph_remove(p, r.slot, sc); err != .None {
		return ch, failure(err)
	}
	ch.found = true
	drop_ref(s, p, r.slot, &ch)
	return ch, {}
}

set_attribute_at :: proc(s: Vset, a: ^Access, name: []u8, text: []u8) -> (ch: Change, f: Failure) {
	one: Ref
	copies := names_lookup(s, name, &one)
	at := exact_copy(a, s, copies)
	if at < 0 {
		if vi := visible_other(a, s, copies); vi >= 0 {
			return ch, in_use(s, copies[vi])
		}
		return ch, {}
	}
	r := copies[at]
	p := ref_part(s, r)
	ch.found = true
	attr, made := part_make_attribute(s, p, text)
	if !made {
		return ch, failure(.Out_Of_Memory)
	}
	part_replace_attribute(s, p, &p.elements[r.slot], attr)
	return ch, {}
}

package vsettype

import "core:testing"
import lbl "../label"

trust_label :: proc(level: int, trust: int) -> lbl.Label {
	x := compartments_label(level)
	x.trust = u8(trust)
	return x
}

Exact_Want :: struct {
	name:  string,
	label: lbl.Id,
	owner: Owner,
}

expect_resolved :: proc(t: ^testing.T, s: Vset, a: ^Access, sc: ^Scratch, wants: []Exact_Want) -> bool {
	v, err := view_open(s, a, sc)
	ok := testing.expect_value(t, err, Error.None)
	for w in wants {
		r, found := view_find(&v, bytes_of(w.name))
		ok = testing.expectf(t, found && ref_label(s, r) == w.label && ref_owner(s, r) == w.owner, "reader %d/%d resolves %q to %v, want %d/%d", a.label, a.owner, w.name, ref_scope(s, r) if found else Scope{}, w.label, w.owner) && ok
	}
	return ok
}

reader_answers :: proc(s: Vset, a: ^Access, sc: ^Scratch, names: []string, out: ^[dynamic]Scope) -> (size: int, attrs: int, ranged: int) {
	clear(out)
	v, _ := view_open(s, a, sc)
	for name in names {
		r, found := view_find(&v, bytes_of(name))
		append(out, ref_scope(s, r) if found else Scope{label = lbl.ID_NONE})
	}
	refs := make([dynamic]Ref, context.temp_allocator)
	view_range(&v, {kind = .Min}, {kind = .Max}, -1, &refs)
	for r in refs {
		append(out, ref_scope(s, r))
	}
	top, ok := top_visible_scope(s, a)
	append(out, top if ok else Scope{label = lbl.ID_NONE})
	info := view_info(&v)
	return info.size, info.attributes_count, len(refs)
}

@(test)
shared_copy_at_the_readers_label_comes_first :: proc(t: ^testing.T) {
	l: Owner_Lattice
	owner_lattice_init(&l, {trust_label(0, 0), trust_label(0, 1)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	low_shared := owner_access(&l, 0, SHARED)
	high_shared := owner_access(&l, 1, SHARED)
	low_user := owner_access(&l, 0, 1)
	high_user := owner_access(&l, 1, 1)
	lo, hi := l.ids[0], l.ids[1]
	testing.expect(t, sees(&low_shared, hi) && !sees(&high_shared, lo))
	testing.expect(t, resolution_compare(&low_shared, hi, lo) > 0)
	s := new_labelled(t, &low_shared, 3)
	defer destroy(s)
	put :: proc(t: ^testing.T, s: Vset, a: ^Access, name: string, x: []f32, attr: string, sc: ^Scratch) {
		_, f := labelled_add(s, a, name, x, sc, .Q8, attr, len(attr) > 0)
		testing.expectf(t, f.err == .None, "write %q at %d/%d: %v", name, a.label, a.owner, f.err)
	}
	low_vec := []f32{1, 0, 0}
	high_vec := []f32{0, 1, 0}
	put(t, s, &low_shared, "x", low_vec, `{"a":1}`, &sc)
	put(t, s, &high_shared, "x", high_vec, "", &sc)
	put(t, s, &low_shared, "y", low_vec, `{"a":2}`, &sc)
	put(t, s, &high_user, "y", high_vec, "", &sc)
	put(t, s, &low_user, "z", low_vec, "", &sc)
	check_set(t, s)
	expect_resolved(t, s, &low_shared, &sc, {{"x", lo, SHARED}, {"y", lo, SHARED}})
	expect_resolved(t, s, &low_user, &sc, {{"x", lo, SHARED}, {"y", lo, SHARED}, {"z", lo, 1}})
	expect_resolved(t, s, &high_user, &sc, {{"x", hi, SHARED}, {"y", hi, 1}})
	v, _ := view_open(s, &low_user, &sc)
	info := view_info(&v)
	testing.expectf(t, info.size == 3 && info.attributes_count == 2, "low user view %d elements, %d attributes", info.size, info.attributes_count)
	refs := make([dynamic]Ref, context.temp_allocator)
	view_range(&v, {kind = .Min}, {kind = .Max}, -1, &refs)
	testing.expect_value(t, len(refs), 3)
	if len(refs) == 3 {
		testing.expect(t, ref_scope(s, refs[0]) == Scope{label = lo} && ref_scope(s, refs[1]) == Scope{label = lo} && ref_scope(s, refs[2]) == Scope{label = lo, owner = 1})
	}
	hits := make([dynamic]Hit, context.temp_allocator)
	req := Search_Request{kind = .Vector, vector = high_vec, count = 10, truth = true}
	sf := view_search(&v, &req, &sc, &hits)
	testing.expect_value(t, sf.err, Error.None)
	for h in hits {
		testing.expectf(t, part_by_id(s, h.part).label == lo, "search for the low user returns %q from %d/%d", string(hit_name(s, h)), part_by_id(s, h.part).label, part_by_id(s, h.part).owner)
	}
	top, ok := top_visible_scope(s, &low_user)
	testing.expectf(t, ok && top == Scope{label = lo, owner = 1}, "low user top scope %v", top)
	low_other := owner_access(&l, 0, 2)
	top, ok = top_visible_scope(s, &low_other)
	testing.expectf(t, ok && top == Scope{label = lo}, "other user top scope %v", top)
	expect_resolved(t, s, &low_other, &sc, {{"x", lo, SHARED}, {"y", lo, SHARED}})
	x := []f32{0.5, 0.5, 0.5}
	_, f := labelled_add(s, &low_user, "x", x, &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == lo && f.owner == SHARED, "INUSE for x names %d/%d", f.label, f.owner)
	_, f = labelled_add(s, &low_user, "y", x, &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == lo && f.owner == SHARED, "INUSE for y names %d/%d", f.label, f.owner)
	_, f = set_attribute_at(s, &low_user, bytes_of("y"), bytes_of(`{"a":3}`))
	testing.expectf(t, f.err == .Name_In_Use && f.label == lo && f.owner == SHARED, "attribute INUSE for y names %d/%d", f.label, f.owner)
	_, f = remove_at(s, &low_user, bytes_of("x"), &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == lo && f.owner == SHARED, "remove INUSE for x names %d/%d", f.label, f.owner)
	removed, ch := remove_owner(s, 1)
	testing.expect(t, removed == 2 && ch.found && !ch.emptied)
	check_set(t, s)
	names := []string{"x", "y", "z"}
	as_user := make([dynamic]Scope, context.temp_allocator)
	as_shared := make([dynamic]Scope, context.temp_allocator)
	us, ua, ur := reader_answers(s, &low_user, &sc, names, &as_user)
	ss, sa, sr := reader_answers(s, &low_shared, &sc, names, &as_shared)
	testing.expectf(t, us == ss && ua == sa && ur == sr, "after forget the user reads %d %d %d, shared %d %d %d", us, ua, ur, ss, sa, sr)
	same := len(as_user) == len(as_shared)
	for i in 0 ..< min(len(as_user), len(as_shared)) {
		same = same && as_user[i] == as_shared[i]
	}
	testing.expectf(t, same, "after forget the user resolves %v, shared %v", as_user[:], as_shared[:])
	free_all(context.temp_allocator)
}

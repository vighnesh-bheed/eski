package vsettype

import "core:testing"

hook_seen: [dynamic]Vset

hook_record :: proc(s: Vset) {
	append(&hook_seen, s)
}

hook_saw :: proc(s: Vset) -> bool {
	for x in hook_seen {
		if x == s {
			return true
		}
	}
	return false
}

hook_expect :: proc(t: ^testing.T, name: string, sets: ..Vset) {
	for s in sets {
		testing.expectf(t, hook_saw(s), "%s ran without calling the write hook first", name)
	}
	clear(&hook_seen)
}

@(test)
write_hook_runs_before_every_mutation :: proc(t: ^testing.T) {
	kept := write_hook
	write_hook = hook_record
	defer {
		write_hook = kept
		delete(hook_seen)
		hook_seen = nil
	}
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	x := []f32{0.1, 0.2, 0.3, 0.4}
	y := []f32{-0.4, 0.1, 0.3, 0.2}
	plain, _ := create(Params{quant = .Q8, dim = 4, m = 4, seed = 9})
	req := Add_Request{name = bytes_of("a"), vector = x, quant = .Q8, m = 4}
	add(plain, &req, &sc)
	hook_expect(t, "add", plain)
	set_attribute(plain, bytes_of("a"), bytes_of(`{"k":1}`))
	hook_expect(t, "set_attribute", plain)
	cas := Add_Request{name = bytes_of("b"), vector = y, quant = .Q8, m = 4}
	plan: Cas_Plan
	cas_prepare(plain, &cas, &plan, &sc)
	clear(&hook_seen)
	cas_commit(plain, &plan, &sc)
	cas_discard(&plan)
	hook_expect(t, "cas_commit", plain)
	remove(plain, bytes_of("b"), &sc)
	hook_expect(t, "remove", plain)
	make_labelled(plain)
	hook_expect(t, "make_labelled", plain)
	destroy(plain)
	hook_expect(t, "destroy", plain)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(1, 0)})
	defer lattice_destroy(&l.lattice)
	low := owner_access(&l, 0, SHARED)
	mid := owner_access(&l, 1, SHARED)
	high := owner_access(&l, 2, SHARED)
	mine := owner_access(&l, 1, 3)
	s := new_labelled(t, &low, 4)
	clear(&hook_seen)
	labelled_add(s, &low, "a", x, &sc)
	hook_expect(t, "add_at", s)
	req2 := Add_Request{name = bytes_of("c"), vector = y, quant = .Q8}
	apply_add_at(s, &mid, &req2, y, &sc, nil, PART_NONE)
	hook_expect(t, "apply_add_at", s)
	set_attribute_at(s, &low, bytes_of("a"), bytes_of(`{"k":2}`))
	hook_expect(t, "set_attribute_at", s)
	cas2 := Add_Request{name = bytes_of("d"), vector = x, quant = .Q8}
	plan2: Cas_Plan
	cas_prepare_at(s, &mid, &cas2, &plan2, &sc)
	clear(&hook_seen)
	cas_commit_at(s, &mid, &plan2, &sc)
	cas_discard(&plan2)
	hook_expect(t, "cas_commit_at", s)
	relabel_at(s, &mid, &high, bytes_of("d"), &sc)
	hook_expect(t, "relabel_at", s)
	labelled_add(s, &mine, "e", x, &sc)
	labelled_add(s, &mine, "f", y, &sc)
	clear(&hook_seen)
	remove_at(s, &mine, bytes_of("e"), &sc)
	hook_expect(t, "remove_at", s)
	part, _, _ := split_scope(s, mine.label, mine.owner)
	hook_expect(t, "split_scope", s)
	absorb(s, part)
	hook_expect(t, "absorb", s, part)
	destroy(part)
	clear(&hook_seen)
	split, _, _ := split_label(s, high.label)
	hook_expect(t, "split_label", s)
	destroy(split)
	clear(&hook_seen)
	labelled_add(s, &mine, "g", x, &sc)
	other := new_labelled(t, &low, 4)
	theirs := owner_access(&l, 2, 5)
	labelled_add(other, &theirs, "h", y, &sc)
	clear(&hook_seen)
	owners_absorb(s, other)
	hook_expect(t, "owners_absorb", s, other)
	destroy(other)
	clear(&hook_seen)
	remove_owner(s, 5)
	hook_expect(t, "remove_owner", s)
	remove_scope(s, mine.label, mine.owner)
	hook_expect(t, "remove_scope", s)
	remove_label(s, mid.label)
	hook_expect(t, "remove_label", s)
	destroy(s)
	hook_expect(t, "destroy of a labelled set", s)
	free_all(context.temp_allocator)
}

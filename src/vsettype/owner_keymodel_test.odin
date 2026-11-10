package vsettype

import "core:fmt"
import "core:strings"
import "core:testing"
import lbl "../label"
import "../rax"

@(test)
owner_scopes_answer_the_key_model :: proc(t: ^testing.T) {
	old := limits_set(12, 3)
	defer limits_restore(old)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(1, 0, 1)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x0E1}
	shared_a := owner_access(&l, 1, SHARED)
	shared_top := owner_access(&l, 3, SHARED)
	u1a := owner_access(&l, 1, 1)
	u1b := owner_access(&l, 2, 1)
	u2a := owner_access(&l, 1, 2)
	u1top := owner_access(&l, 3, 1)
	s := new_labelled(t, &shared_a, 4)
	x := make([]f32, 4)
	defer delete(x)
	for k in 0 ..< 10 {
		random_vector(&r, x)
		_, f := labelled_add(s, &shared_a, fmt.tprintf("s%d", k), x, &sc)
		testing.expect_value(t, f.err, Error.None)
	}
	label_only := memory_usage(s) - rax.memory(s.names)
	shared_only := shared_bytes(s) - rax.memory(s.names)
	label_a := label_memory(s, shared_a.label)
	shared_full := shared_bytes(s)
	testing.expect(t, s.lab.owners == nil && owner_bytes(s) == 0 && index_bytes(s) == 0)
	for k in 0 ..< 8 {
		random_vector(&r, x)
		ch, f := labelled_add(s, &u1a, fmt.tprintf("u%d", k), x, &sc)
		testing.expect(t, f.err == .None && ch.added && ch.label_new == (k == 0))
	}
	testing.expect(t, s.lab.owners != nil && owner_count(s) == 1)
	testing.expectf(t, shared_bytes(s) == shared_full && label_memory(s, shared_a.label) == label_a, "an owner write moved the shared charges: %d %d against %d %d", shared_bytes(s), label_memory(s, shared_a.label), shared_full, label_a)
	p := part_at_scope(s, u1a.label, 1)
	testing.expect(t, p != nil && p.kind == .Compact && p.mode == .Flat && p.owner == 1 && p.id >= OWNER_PART_BASE)
	testing.expect(t, has_scope(s, u1a.label, 1) && !has_scope(s, u1a.label, 2) && !has_scope(s, u1b.label, 1) && has_scope(s, shared_a.label, SHARED))
	testing.expect(t, scope_card(s, u1a.label, 1) == 8 && scope_card(s, shared_a.label, SHARED) == 10 && card(s) == 18)
	testing.expect(t, scope_memory(s, u1a.label, 1) == owner_memory(s, 1) && owner_memory(s, 1) == owner_bytes(s))
	random_vector(&r, x)
	_, f := labelled_add(s, &u1a, "s3", x, &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == shared_a.label && f.owner == SHARED, "a shared copy at the writer's own label: %v %d/%d", f.err, f.label, f.owner)
	_, f = labelled_add(s, &u1top, "u3", x, &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == u1a.label && f.owner == 1, "own copy at another label: %v %d/%d", f.err, f.label, f.owner)
	_, f = labelled_add(s, &u2a, "u3", x, &sc)
	testing.expectf(t, f.err == .None, "another owner sees the first owner's name: %v", f.err)
	_, f = labelled_add(s, &shared_top, "u3", x, &sc)
	testing.expectf(t, f.err == .None, "a shared writer sees a private name: %v", f.err)
	_, f = labelled_add(s, &u1top, "s4", x, &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == shared_a.label && f.owner == SHARED, "a shared copy must be named: %v %d/%d", f.err, f.label, f.owner)
	ch: Change
	ch, f = remove_at(s, &u1b, bytes_of("s5"), &sc)
	testing.expect(t, f.err == .None && !ch.found)
	ch, f = remove_at(s, &u1top, bytes_of("u3"), &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == shared_top.label && f.owner == SHARED, "the shared copy at top ranks above the own copy: %v %d/%d", f.err, f.label, f.owner)
	check_labelled(t, s)
	u1_before := owner_memory(s, 1)
	u2_before := owner_memory(s, 2)
	for k in 0 ..< 20 {
		random_vector(&r, x)
		labelled_add(s, &u2a, fmt.tprintf("w%d", k), x, &sc)
	}
	testing.expectf(t, owner_memory(s, 1) == u1_before && owner_memory(s, 2) > u2_before, "one owner's writes moved another owner's charge")
	testing.expect(t, part_at_scope(s, u2a.label, 2).mode == .Graph && part_at_scope(s, u2a.label, 2).kind == .Block)
	check_labelled(t, s)
	labels := make([dynamic]lbl.Id)
	defer delete(labels)
	owner_labels(s, 1, &labels)
	testing.expect(t, len(labels) == 1 && labels[0] == u1a.label)
	random_vector(&r, x)
	labelled_add(s, &u1b, "b0", x, &sc)
	clear(&labels)
	owner_labels(s, 1, &labels)
	testing.expect(t, len(labels) == 2 && owner_card(s, 1) == 9)
	testing.expect(t, scope_memory(s, u1a.label, 1) + scope_memory(s, u1b.label, 1) == owner_memory(s, 1))
	check_labelled(t, s)
	part, sch, err := split_scope(s, u1a.label, 1)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, sch.found && sch.label_gone && !sch.emptied)
	testing.expect(t, !has_scope(s, u1a.label, 1) && has_scope(s, u1b.label, 1) && has_scope(part, u1a.label, 1) && card(part) == 8)
	check_labelled(t, s)
	check_labelled(t, part)
	pv, _ := view_open(part, &u1a, &sc)
	testing.expect_value(t, view_size(&pv), 8)
	sv, _ := view_open(s, &u2a, &sc)
	_, seen := view_find(&sv, bytes_of("u0"))
	testing.expect(t, !seen)
	testing.expect_value(t, absorb(s, part), Error.None)
	testing.expect(t, card(part) == 0 && has_scope(s, u1a.label, 1))
	destroy(part)
	check_labelled(t, s)
	idx := s.lab.owners
	before_ids := idx.part_high
	removed, rc := remove_owner(s, 1, &labels)
	testing.expect(t, removed == 9 && rc.found && !rc.emptied && owner_count(s) == 1)
	testing.expect(t, !has_scope(s, u1a.label, 1) && !has_scope(s, u1b.label, 1) && owner_memory(s, 1) == 0)
	check_labelled(t, s)
	random_vector(&r, x)
	labelled_add(s, &u1a, "again", x, &sc)
	testing.expectf(t, s.lab.owners.part_high == before_ids, "partition ids are not reused: %d against %d", s.lab.owners.part_high, before_ids)
	check_labelled(t, s)
	testing.expect(t, codec_refuses(s) && serialized_size(s) == 0)
	blob, berr := serialize_bytes(s)
	testing.expect(t, blob == nil && berr != nil)
	removed, rc = remove_scope(s, u1a.label, 1)
	testing.expect(t, removed == 1 && rc.found && rc.label_gone && !rc.emptied)
	removed, rc = remove_scope(s, u2a.label, 2)
	testing.expect(t, removed == 21 && rc.label_gone && !rc.emptied)
	testing.expect(t, s.lab.owners == nil && owner_bytes(s) == 0 && index_bytes(s) == 0)
	removed, rc = remove_scope(s, shared_top.label, SHARED)
	testing.expect(t, removed == 1 && rc.label_gone)
	names_now := rax.memory(s.names)
	testing.expectf(t, memory_usage(s) - names_now == label_only && shared_bytes(s) - names_now == shared_only, "memory after every owner left: %d %d against %d %d", memory_usage(s) - names_now, shared_bytes(s) - names_now, label_only, shared_only)
	check_labelled(t, s)
	removed, rc = remove_scope(s, shared_a.label, SHARED)
	testing.expect(t, removed == 10 && rc.emptied)
	destroy(s)
	free_all(context.temp_allocator)
}

@(test)
owner_access_needs_a_stream_and_a_single_owner :: proc(t: ^testing.T) {
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	shared := owner_access(&l, 1, SHARED)
	s := new_labelled(t, &shared, 3)
	defer destroy(s)
	x := []f32{0.1, 0.2, 0.3}
	_, f := labelled_add(s, &shared, "a", x, &sc)
	testing.expect_value(t, f.err, Error.None)
	bare := owner_access(&l, 1, 5)
	bare.stream = nil
	_, f = labelled_add(s, &bare, "b", x, &sc)
	testing.expect_value(t, f.err, Error.Invalid_Parameter)
	_, err := view_open(s, &bare, &sc)
	testing.expect_value(t, err, Error.Invalid_Parameter)
	_, f = remove_at(s, &bare, bytes_of("a"), &sc)
	testing.expect_value(t, f.err, Error.Invalid_Parameter)
	every := owner_access(&l, 1, EVERY_OWNER)
	_, f = labelled_add(s, &every, "c", x, &sc)
	testing.expect_value(t, f.err, Error.Invalid_Parameter)
	_, err = view_open(s, &every, &sc)
	testing.expect_value(t, err, Error.Invalid_Parameter)
	plan: Cas_Plan
	req := Add_Request{name = bytes_of("d"), vector = x}
	testing.expect_value(t, cas_prepare_at(s, &bare, &req, &plan, &sc).err, Error.Invalid_Parameter)
	cas_discard(&plan)
	to := owner_access(&l, 1, 6)
	user := owner_access(&l, 1, 5)
	labelled_add(s, &user, "e", x, &sc)
	_, _, rf := relabel_at(s, &user, &to, bytes_of("e"), &sc)
	testing.expect_value(t, rf.err, Error.Invalid_Parameter)
	testing.expect(t, card(s) == 2 && s.lab.owners != nil)
	check_labelled(t, s)
}

@(test)
plain_sets_take_owner_writes_as_bottom_shared_data :: proc(t: ^testing.T) {
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x7A1}
	s := new_set(t, 5, .Q8)
	defer destroy(s)
	x := make([]f32, 5)
	defer delete(x)
	for i in 0 ..< 40 {
		random_vector(&r, x)
		add_values(t, s, fmt.tprintf("e%d", i), x, .Q8, "", false, &sc)
	}
	bottom_user := owner_access(&l, 0, 3)
	bottom := owner_access(&l, 0, SHARED)
	v, _ := view_open(s, &bottom_user, &sc)
	testing.expect_value(t, view_size(&v), 40)
	names := make([dynamic]string)
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	for i in 0 ..< 10 {
		append(&names, fmt.aprintf("e%d", i))
	}
	query := make([]f32, 5)
	defer delete(query)
	copy(query, x)
	queries := [][]f32{query}
	links: Links
	defer links_destroy(&links)
	before := strings.clone(view_digest(s, &bottom, names[:], queries, &sc, &links))
	defer delete(before)
	random_vector(&r, x)
	_, f := labelled_add(s, &bottom_user, "e3", x, &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == lbl.BOTTOM_ID && f.owner == SHARED, "an owner at the bottom label must not update shared data: %v", f.err)
	testing.expect(t, s.lab == nil)
	ch: Change
	ch, f = labelled_add(s, &bottom_user, "mine", x, &sc)
	testing.expect(t, f.err == .None && ch.added && ch.label_new && s.lab != nil)
	p := part_at_label(s, lbl.BOTTOM_ID)
	testing.expect(t, p != nil && p.mode == .Pinned && p.owner == SHARED && card(s) == 41)
	testing.expect(t, has_scope(s, lbl.BOTTOM_ID, 3) && scope_card(s, lbl.BOTTOM_ID, 3) == 1)
	check_labelled(t, s)
	after := view_digest(s, &bottom, names[:], queries, &sc, &links)
	testing.expectf(t, before == after, "an owner write changed the shared view\n%s", digest_difference(before, after))
	uv, _ := view_open(s, &bottom_user, &sc)
	testing.expect_value(t, view_size(&uv), 41)
	_, mine := view_find(&uv, bytes_of("mine"))
	testing.expect(t, mine)
	free_all(context.temp_allocator)
}

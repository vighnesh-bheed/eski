package vsettype

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import lbl "../label"

named_text :: proc(s: Vset, hits: []Hit) -> string {
	list := make([dynamic]Named_Hit, context.temp_allocator)
	for h in hits {
		append(&list, Named_Hit{score = h.score, name = hit_name(s, h), part = h.part, slot = h.slot})
	}
	slice.sort_by(list[:], named_better)
	b := strings.builder_make(context.temp_allocator)
	for h in list {
		fmt.sbprintf(&b, "%s/%x ", string(h.name), transmute(u64)h.score)
	}
	return strings.to_string(b)
}

@(test)
plain_sets_read_the_same_through_the_labelled_api :: proc(t: ^testing.T) {
	l: Lattice
	lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(1, 0)})
	defer lattice_destroy(&l)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x9A1}
	s := new_set(t, 6, .Q8)
	defer destroy(s)
	x := make([]f32, 6)
	defer delete(x)
	for i in 0 ..< 300 {
		random_vector(&r, x)
		add_values(t, s, fmt.tprintf("e%d", i), x, .Q8, fmt.tprintf(`{{"a":%d}}`, i % 4), i % 3 == 0, &sc)
	}
	bottom := lattice_access(&l, 0)
	v, _ := view_open(s, &bottom, &sc)
	testing.expect_value(t, view_size(&v), card(s))
	plain := info(s)
	seen := view_info(&v)
	testing.expect(t, seen.size == plain.size && seen.attributes_count == plain.attributes_count && seen.max_level == plain.max_level && seen.max_node_uid == plain.max_node_uid && seen.vset_uid == 0)
	for i in 0 ..< 300 {
		name := bytes_of(fmt.tprintf("e%d", i))
		slot, _ := find(s, name)
		ref, ok := view_find(&v, name)
		testing.expect(t, ok && ref == Ref{slot = slot, part = 0})
	}
	hits := make([dynamic]Hit)
	defer delete(hits)
	ours := make([dynamic]Hit)
	defer delete(ours)
	for round in 0 ..< 40 {
		random_vector(&r, x)
		req := Search_Request{kind = .Vector, vector = x, count = 1 + round % 20, truth = round % 2 == 0, filter = ".a > 1", use_filter = round % 3 == 0}
		clear(&hits)
		search(s, &req, &sc, &hits)
		clear(&ours)
		view_search(&v, &req, &sc, &ours)
		testing.expectf(t, named_text(s, hits[:]) == named_text(s, ours[:]), "round %d differs", round)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, view_memory(&v), VIEW_BASE_BYTES + PART_FIXED_BYTES + s.ledger.bytes - usable_size(s) + card(s) * NAME_INDEX_BYTES)
	top := lattice_access(&l, 2)
	top.top = true
	tv, _ := view_open(s, &top, &sc)
	testing.expect_value(t, view_memory(&tv), memory_usage(s))
	random_vector(&r, x)
	ch, f := labelled_add(s, &bottom, "fresh", x, &sc)
	testing.expect(t, f.err == .None && ch.added && !ch.label_new && s.lab == nil)
	check_invariants(t, s)
	testing.expect(t, serialized_size(s) > 0 && !codec_refuses(s))
	names := make([dynamic]string)
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	for i in 0 ..< 12 {
		append(&names, fmt.aprintf("e%d", i))
	}
	queries := [][]f32{x}
	links: Links
	defer links_destroy(&links)
	before := strings.clone(view_digest(s, &bottom, names[:], queries, &sc, &links))
	defer delete(before)
	upper := lattice_access(&l, 1)
	ch, f = labelled_add(s, &upper, "e3", x, &sc)
	testing.expect(t, f.err == .Name_In_Use && f.label == lbl.BOTTOM_ID)
	testing.expect(t, s.lab == nil)
	ch, f = labelled_add(s, &upper, "upper", x, &sc)
	testing.expect(t, f.err == .None && ch.added && ch.label_new && s.lab != nil)
	check_labelled(t, s)
	p := part_at_label(s, lbl.BOTTOM_ID)
	testing.expect(t, p != nil && p.mode == .Pinned && p.id == 0)
	after := view_digest(s, &bottom, names[:], queries, &sc, &links)
	testing.expectf(t, before == after, "conversion changed the bottom view\n%s", digest_difference(before, after))
	testing.expect(t, codec_refuses(s) && serialized_size(s) == 0)
	blob, berr := serialize_bytes(s)
	testing.expect(t, blob == nil && berr != nil)
	for i in 0 ..< 300 {
		remove_at(s, &bottom, bytes_of(fmt.tprintf("e%d", i)), &sc)
	}
	testing.expect(t, p.count == 1 && p.mode == .Pinned)
	check_labelled(t, s)
	ch, f = remove_at(s, &bottom, bytes_of("fresh"), &sc)
	testing.expect(t, ch.found && ch.label_gone && !ch.emptied)
	testing.expect(t, !has_label(s, lbl.BOTTOM_ID) && has_label(s, upper.label))
	check_labelled(t, s)
	testing.expect_value(t, shared_memory(s), memory_usage(s) - label_memory(s, upper.label))
	free_all(context.temp_allocator)
}

@(test)
existing_sets_become_bottom_data :: proc(t: ^testing.T) {
	l: Lattice
	lattice_init(&l, {compartments_label(0), compartments_label(0, 0)})
	defer lattice_destroy(&l)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x7B0}
	s := new_set(t, 4, .NOQUANT)
	defer destroy(s)
	x := make([]f32, 4)
	defer delete(x)
	for i in 0 ..< 50 {
		random_vector(&r, x)
		add_values(t, s, fmt.tprintf("e%d", i), x, .NOQUANT, `{"a":1}`, i % 2 == 0, &sc)
	}
	before := label_memory(s, lbl.BOTTOM_ID)
	shared := shared_memory(s)
	testing.expect_value(t, before + shared, memory_usage(s))
	plain := info(s)
	testing.expect_value(t, make_labelled(s), Error.None)
	check_labelled(t, s)
	testing.expect(t, s.lab != nil && card(s) == 50 && label_card(s, lbl.BOTTOM_ID) == 50)
	testing.expect_value(t, label_memory(s, lbl.BOTTOM_ID), before)
	testing.expect_value(t, label_memory(s, lbl.BOTTOM_ID) + shared_memory(s), memory_usage(s))
	bottom := lattice_access(&l, 0)
	v, _ := view_open(s, &bottom, &sc)
	seen := view_info(&v)
	testing.expect(t, seen.size == 50 && seen.max_node_uid == plain.max_node_uid && seen.max_level == plain.max_level && seen.attributes_count == plain.attributes_count)
	testing.expect_value(t, make_labelled(s), Error.None)
	plain_again := new_set(t, 4, .NOQUANT)
	defer destroy(plain_again)
	random_vector(&r, x)
	add_values(t, plain_again, "only", x, .NOQUANT, "", false, &sc)
	removed, ch := remove_label(plain_again, lbl.BOTTOM_ID)
	testing.expect(t, removed == 1 && ch.found && ch.label_gone && ch.emptied && card(plain_again) == 0)
	check_invariants(t, plain_again)
}

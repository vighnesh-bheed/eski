package vsettype

import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
owner_partitions_graduate_and_flatten_through_blocks :: proc(t: ^testing.T) {
	old := limits_set(32, 8)
	defer limits_restore(old)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(1, 0, 1)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x6E1}
	a := owner_access(&l, 1, 7)
	shared := owner_access(&l, 1, SHARED)
	s := new_labelled(t, &a, 8)
	defer destroy(s)
	x := make([]f32, 8)
	defer delete(x)
	for i in 0 ..< 5 {
		random_vector(&r, x)
		labelled_add(s, &shared, fmt.tprintf("s%d", i), x, &sc)
	}
	for i in 0 ..< 20 {
		random_vector(&r, x)
		labelled_add(s, &a, fmt.tprintf("e%d", i), x, &sc)
	}
	for i in 0 ..< 20 {
		if i % 4 == 1 {
			remove_at(s, &a, bytes_of(fmt.tprintf("e%d", i)), &sc)
		}
	}
	p := part_at_scope(s, a.label, 7)
	id := p.id
	testing.expect(t, p.kind == .Compact && p.mode == .Flat && p.count == 15)
	uid := part_uid(p)
	testing.expect_value(t, uid, 20)
	compact_bytes := owner_memory(s, 7)
	testing.expect_value(t, compact_bytes, owner_bytes(s))
	check_labelled(t, s)
	for i in 20 ..< 37 {
		random_vector(&r, x)
		labelled_add(s, &a, fmt.tprintf("e%d", i), x, &sc)
	}
	p = part_at_scope(s, a.label, 7)
	testing.expect(t, p.count == 32 && p.kind == .Compact)
	random_vector(&r, x)
	labelled_add(s, &a, "e37", x, &sc)
	p = part_at_scope(s, a.label, 7)
	testing.expect(t, p.kind == .Block && p.mode == .Graph && p.id == id && p.count == 33)
	testing.expect_value(t, part_uid(p), uid + 18)
	testing.expect(t, owner_memory(s, 7) == owner_bytes(s) && owner_memory(s, 7) > compact_bytes)
	check_labelled(t, s)
	v, _ := view_open(s, &a, &sc)
	hits := make([dynamic]Hit)
	defer delete(hits)
	exact := make([dynamic]Hit)
	defer delete(exact)
	agree := 0
	for _ in 0 ..< 50 {
		random_vector(&r, x)
		req := Search_Request{kind = .Vector, vector = x, count = 5}
		clear(&hits)
		view_search(&v, &req, &sc, &hits)
		req.truth = true
		clear(&exact)
		view_search(&v, &req, &sc, &exact)
		if hits_text(s, hits[:]) == hits_text(s, exact[:]) {
			agree += 1
		}
	}
	testing.expectf(t, agree >= 45, "graph partition agrees with the exact scan on %d of 50 queries", agree)
	for i in 0 ..< 38 {
		if part_at_scope(s, a.label, 7).count == 9 {
			break
		}
		ch, _ := remove_at(s, &a, bytes_of(fmt.tprintf("e%d", i)), &sc)
		testing.expect(t, ch.found || i % 4 == 1 && i < 20)
		testing.expect_value(t, part_at_scope(s, a.label, 7).mode, Part_Mode.Graph)
	}
	check_labelled(t, s)
	ch, _ := remove_at(s, &a, bytes_of("e37"), &sc)
	testing.expect(t, ch.found)
	p = part_at_scope(s, a.label, 7)
	testing.expect(t, p.kind == .Compact && p.mode == .Flat && p.count == 8 && p.id == id)
	testing.expect(t, owner_memory(s, 7) == owner_bytes(s))
	check_labelled(t, s)
	uid = part_uid(p)
	for i in 100 ..< 125 {
		random_vector(&r, x)
		labelled_add(s, &a, fmt.tprintf("e%d", i), x, &sc)
	}
	p = part_at_scope(s, a.label, 7)
	testing.expect(t, p.kind == .Block && p.mode == .Graph && part_uid(p) == uid + 25)
	check_labelled(t, s)
	sv, _ := view_open(s, &shared, &sc)
	testing.expect_value(t, view_size(&sv), 5)
	free_all(context.temp_allocator)
}

@(test)
owner_partitions_draw_levels_from_their_own_stream :: proc(t: ^testing.T) {
	old := limits_set(16, 4)
	defer limits_restore(old)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(1, 0, 1)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	build :: proc(t: ^testing.T, l: ^Owner_Lattice, sc: ^Scratch, noise: bool) -> (Vset, string) {
		owner_lattice_init_streams(l)
		a := owner_access(l, 1, 3)
		others := []Access{owner_access(l, 1, 4), owner_access(l, 2, 3), owner_access(l, 2, SHARED), owner_access(l, 3, 5)}
		s := new_labelled(t, &a, 6)
		r := Test_Rng{state = 0xAB}
		n := Test_Rng{state = 0xCD}
		x := make([]f32, 6, context.temp_allocator)
		for i in 0 ..< 200 {
			random_vector(&r, x)
			labelled_add(s, &a, fmt.tprintf("a%d", i % 70), x, sc)
			if i % 9 == 4 {
				remove_at(s, &a, bytes_of(fmt.tprintf("a%d", (i * 7) % 70)), sc)
			}
			if noise {
				for _ in 0 ..< 3 {
					w := &others[test_below(&n, len(others))]
					random_vector(&n, x)
					labelled_add(s, w, fmt.tprintf("a%d", test_below(&n, 90)), x, sc)
					if test_below(&n, 4) == 0 {
						remove_at(s, w, bytes_of(fmt.tprintf("a%d", test_below(&n, 90))), sc)
					}
				}
				if i % 50 == 20 {
					remove_owner(s, 4)
					remove_scope(s, others[1].label, 3)
				}
			}
		}
		check_labelled(t, s)
		return s, strings.clone(graph_text(s, part_full(part_at_scope(s, a.label, 3))))
	}
	quiet, qt := build(t, &l, &sc, false)
	defer destroy(quiet)
	defer delete(qt)
	noisy, nt := build(t, &l, &sc, true)
	defer destroy(noisy)
	defer delete(nt)
	testing.expect(t, part_at_scope(quiet, l.ids[1], 3).mode == .Graph)
	testing.expectf(t, qt == nt, "another scope's writes changed the owner's graph")
	testing.expect(t, owner_count(noisy) >= 2)
	free_all(context.temp_allocator)
}

owner_lattice_init_streams :: proc(l: ^Owner_Lattice) {
	for i in 0 ..< 8 {
		l.stream[i] = 0x1234 + u64(i)
		for j in 0 ..< 8 {
			l.streams[i][j] = u64(i * 8 + j + 1) * 0x2545F4914F6CDD1D
		}
	}
}

@(test)
owner_cas_matches_an_owner_add :: proc(t: ^testing.T) {
	old := limits_set(8, 2)
	defer limits_restore(old)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(1, 0)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	build :: proc(t: ^testing.T, l: ^Owner_Lattice, sc: ^Scratch, cas: bool) -> (Vset, string) {
		owner_lattice_init_streams(l)
		a := owner_access(l, 1, 6)
		s := new_labelled(t, &a, 5)
		r := Test_Rng{state = 0x77}
		x := make([]f32, 5, context.temp_allocator)
		for i in 0 ..< 60 {
			random_vector(&r, x)
			req := Add_Request{name = bytes_of(fmt.tprintf("c%d", i % 40)), vector = x}
			if cas {
				plan: Cas_Plan
				testing.expect_value(t, cas_prepare_at(s, &a, &req, &plan, sc).err, Error.None)
				_, f := cas_commit_at(s, &a, &plan, sc)
				testing.expect_value(t, f.err, Error.None)
				cas_discard(&plan)
			} else {
				_, f := add_at(s, &a, &req, sc)
				testing.expect_value(t, f.err, Error.None)
			}
		}
		check_labelled(t, s)
		return s, strings.clone(graph_text(s, part_full(part_at_scope(s, a.label, 6))))
	}
	plain, pt := build(t, &l, &sc, false)
	defer destroy(plain)
	defer delete(pt)
	cased, ct := build(t, &l, &sc, true)
	defer delete(ct)
	testing.expect(t, pt == ct)
	testing.expect(t, part_at_scope(cased, l.ids[1], 6).mode == .Graph && part_at_scope(cased, l.ids[1], 6).kind == .Block)
	upper := owner_access(&l, 2, 6)
	other := owner_access(&l, 2, 9)
	x := make([]f32, 5)
	defer delete(x)
	req := Add_Request{name = bytes_of("c3"), vector = x}
	plan: Cas_Plan
	testing.expect_value(t, cas_prepare_at(cased, &upper, &req, &plan, &sc).err, Error.None)
	_, f := cas_commit_at(cased, &upper, &plan, &sc)
	testing.expect(t, f.err == .Name_In_Use && f.label == l.ids[1] && f.owner == 6)
	cas_discard(&plan)
	testing.expect_value(t, cas_prepare_at(cased, &other, &req, &plan, &sc).err, Error.None)
	_, f = cas_commit_at(cased, &upper, &plan, &sc)
	testing.expect(t, f.err == .Name_In_Use && f.owner == 6)
	cas_discard(&plan)
	testing.expect_value(t, cas_prepare_at(cased, &other, &req, &plan, &sc).err, Error.None)
	ch: Change
	ch, f = cas_commit_at(cased, &other, &plan, &sc)
	testing.expect(t, f.err == .None && ch.added && ch.label_new && has_scope(cased, l.ids[2], 9))
	cas_discard(&plan)
	check_labelled(t, cased)
	destroy(cased)
	free_all(context.temp_allocator)
}

package vsettype

import "core:fmt"
import "core:strings"
import "core:testing"

graph_text :: proc(s: Vset, p: ^Partition) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "mode %v count %d max %d uid %d entry %d\n", p.mode, p.count, p.graph.max_level, p.graph.node_uid, p.graph.entry)
	buf := make([dynamic]u32, context.temp_allocator)
	for i in 0 ..< p.count {
		slot := p.order[i]
		fmt.sbprintf(&b, "%s:", string(part_element_name(p, slot)))
		if p.mode == .Flat {
			fmt.sbprintf(&b, "\n")
			continue
		}
		for layer in 0 ..< part_link_layers(p, slot) {
			fmt.sbprintf(&b, " [")
			for other in part_layer_links(p, slot, layer, &buf) {
				fmt.sbprintf(&b, "%s ", string(part_element_name(p, other)))
			}
			fmt.sbprintf(&b, "]")
		}
		fmt.sbprintf(&b, "\n")
	}
	return strings.to_string(b)
}

@(test)
partitions_graduate_and_shrink_with_hysteresis :: proc(t: ^testing.T) {
	old := limits_set(32, 8)
	defer limits_restore(old)
	l: Lattice
	lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(1, 0, 1)})
	defer lattice_destroy(&l)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x6E0}
	a := lattice_access(&l, 1)
	s := new_labelled(t, &a, 8)
	defer destroy(s)
	x := make([]f32, 8)
	defer delete(x)
	for i in 0 ..< 20 {
		random_vector(&r, x)
		labelled_add(s, &a, fmt.tprintf("e%d", i), x, &sc)
	}
	for i in 0 ..< 20 {
		if i % 4 == 1 {
			remove_at(s, &a, bytes_of(fmt.tprintf("e%d", i)), &sc)
		}
	}
	p := part_at_label(s, a.label)
	testing.expect_value(t, p.mode, Part_Mode.Flat)
	testing.expect_value(t, p.graph.slots, 0)
	check_labelled(t, s)
	uid := p.graph.node_uid
	for i in 20 ..< 37 {
		random_vector(&r, x)
		labelled_add(s, &a, fmt.tprintf("e%d", i), x, &sc)
	}
	testing.expect_value(t, p.count, 32)
	testing.expect_value(t, p.mode, Part_Mode.Flat)
	random_vector(&r, x)
	labelled_add(s, &a, "e37", x, &sc)
	testing.expect_value(t, p.mode, Part_Mode.Graph)
	testing.expect_value(t, p.graph.node_uid, uid + 18)
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
		if p.count == 9 {
			break
		}
		ch, _ := remove_at(s, &a, bytes_of(fmt.tprintf("e%d", i)), &sc)
		testing.expect(t, ch.found || i % 4 == 1 && i < 20)
		testing.expect_value(t, p.mode, Part_Mode.Graph)
	}
	testing.expect_value(t, p.count, 9)
	check_labelled(t, s)
	ch, _ := remove_at(s, &a, bytes_of("e37"), &sc)
	testing.expect(t, ch.found)
	testing.expect_value(t, p.count, 8)
	testing.expect_value(t, p.mode, Part_Mode.Flat)
	testing.expect_value(t, p.graph.slots, 0)
	check_labelled(t, s)
	for i in 100 ..< 125 {
		random_vector(&r, x)
		labelled_add(s, &a, fmt.tprintf("e%d", i), x, &sc)
	}
	testing.expect_value(t, p.mode, Part_Mode.Graph)
	check_labelled(t, s)
}

@(test)
each_partition_draws_levels_from_its_own_stream :: proc(t: ^testing.T) {
	old := limits_set(16, 4)
	defer limits_restore(old)
	l: Lattice
	lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(1, 0, 1)})
	defer lattice_destroy(&l)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	build :: proc(t: ^testing.T, l: ^Lattice, sc: ^Scratch, noise: bool) -> (Vset, string) {
		l.stream = {0x1234, 0x1235, 0x1236, 0x1237, 0, 0, 0, 0}
		a := lattice_access(l, 1)
		b := lattice_access(l, 2)
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
					random_vector(&n, x)
					labelled_add(s, &b, fmt.tprintf("a%d", test_below(&n, 90)), x, sc)
					if test_below(&n, 4) == 0 {
						remove_at(s, &b, bytes_of(fmt.tprintf("a%d", test_below(&n, 90))), sc)
					}
				}
				if i % 50 == 20 {
					remove_label(s, b.label)
				}
			}
		}
		check_labelled(t, s)
		return s, strings.clone(graph_text(s, part_at_label(s, a.label)))
	}
	quiet, qt := build(t, &l, &sc, false)
	defer destroy(quiet)
	defer delete(qt)
	noisy, nt := build(t, &l, &sc, true)
	defer destroy(noisy)
	defer delete(nt)
	testing.expect(t, part_at_label(quiet, l.ids[1]).mode == .Graph)
	testing.expect(t, qt == nt)
	testing.expect(t, has_label(noisy, l.ids[2]))
	free_all(context.temp_allocator)
}

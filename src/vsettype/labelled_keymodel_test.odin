package vsettype

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import lbl "../label"

@(test)
key_model_queries_split_and_absorb :: proc(t: ^testing.T) {
	old := limits_set(12, 3)
	defer limits_restore(old)
	l: Lattice
	lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(1, 0, 1)})
	defer lattice_destroy(&l)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x4E1}
	bottom := lattice_access(&l, 0)
	a := lattice_access(&l, 1)
	b := lattice_access(&l, 2)
	top := lattice_access(&l, 3)
	s := new_labelled(t, &a, 4)
	x := make([]f32, 4)
	defer delete(x)
	writers := []^Access{&a, &b, &top}
	prefixes := []string{"a", "b", "t"}
	for w, i in writers {
		for k in 0 ..< 20 {
			random_vector(&r, x)
			_, f := labelled_add(s, w, fmt.tprintf("%s%d", prefixes[i], k), x, &sc)
			testing.expect_value(t, f.err, Error.None)
		}
	}
	for w in writers[:2] {
		random_vector(&r, x)
		_, f := labelled_add(s, w, "x", x, &sc)
		testing.expect_value(t, f.err, Error.None)
	}
	random_vector(&r, x)
	_, refused := labelled_add(s, &top, "x", x, &sc)
	testing.expect(t, refused.err == .Name_In_Use)
	check_labelled(t, s)
	present := make([dynamic]lbl.Id)
	defer delete(present)
	labels_present(s, &present)
	testing.expect(t, len(present) == 3 && present[0] == a.label && present[1] == b.label && present[2] == top.label)
	testing.expect(t, !has_visible(s, &bottom) && has_visible(s, &a) && has_visible(s, &top))
	tl, ok := top_visible_label(s, &top)
	testing.expect(t, ok && tl == top.label)
	tl, ok = top_visible_label(s, &a)
	testing.expect(t, ok && tl == a.label)
	_, ok = top_visible_label(s, &bottom)
	testing.expect(t, !ok)
	testing.expect(t, label_card(s, a.label) == 21 && label_card(s, top.label) == 20 && label_memory(s, a.label) > PART_FIXED_BYTES)
	v, _ := view_open(s, &top, &sc)
	testing.expect_value(t, view_size(&v), 61)
	removed, rc := remove_label(s, top.label)
	testing.expect(t, removed == 20 && rc.found && rc.label_gone && !rc.emptied)
	shared := memory_usage(s) - label_memory(s, a.label) - label_memory(s, b.label)
	testing.expect_value(t, shared_memory(s), shared)
	testing.expect(t, shared > 0)
	tl, ok = top_visible_label(s, &top)
	testing.expect(t, ok && (tl == a.label || tl == b.label))
	again, _ := top_visible_label(s, &top)
	testing.expect(t, again == tl)
	check_labelled(t, s)
	names := make([dynamic]string)
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	for p in prefixes {
		for k in 0 ..< 20 {
			append(&names, fmt.aprintf("%s%d", p, k))
		}
	}
	append(&names, fmt.aprintf("x"))
	fixed := make([]f32, 4)
	defer delete(fixed)
	copy(fixed, x)
	queries := [][]f32{fixed}
	links: Links
	defer links_destroy(&links)
	before := strings.clone(view_digest(s, &top, names[:], queries, &sc, &links))
	defer delete(before)
	part, sch, err := split_label(s, b.label)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, sch.label_gone && !sch.emptied)
	testing.expect_value(t, shared_memory(part), memory_usage(part) - label_memory(part, b.label))
	check_labelled(t, s)
	check_labelled(t, part)
	testing.expect(t, card(s) == 21 && card(part) == 21 && has_label(part, b.label) && !has_label(s, b.label))
	pv, _ := view_open(part, &b, &sc)
	testing.expect_value(t, view_size(&pv), 21)
	sv, _ := view_open(s, &b, &sc)
	testing.expect_value(t, view_size(&sv), 0)
	_, ok = view_find(&pv, bytes_of("x"))
	testing.expect(t, ok)
	other := new_set(t, 5)
	testing.expect_value(t, absorb(s, other), Error.Invalid_Parameter)
	destroy(other)
	clash := new_labelled(t, &a, 4)
	random_vector(&r, x)
	labelled_add(clash, &a, "c", x, &sc)
	testing.expect_value(t, absorb(s, clash), Error.Name_In_Use)
	destroy(clash)
	testing.expect_value(t, absorb(s, part), Error.None)
	testing.expect_value(t, card(part), 0)
	destroy(part)
	check_labelled(t, s)
	after := view_digest(s, &top, names[:], queries, &sc, &links)
	testing.expectf(t, before == after, "split and absorb changed the view\n%s", digest_difference(before, after))
	req := Add_Request{vector = x, quant = .Q8}
	testing.expect(t, joinable(s, &req))
	wide := make([]f32, 5)
	defer delete(wide)
	req.vector = wide
	testing.expect(t, !joinable(s, &req))
	removed, rc = remove_label(s, a.label)
	testing.expect(t, removed == 21 && rc.label_gone && !rc.emptied)
	removed, rc = remove_label(s, b.label)
	testing.expect(t, removed == 21 && rc.label_gone && rc.emptied)
	removed, rc = remove_label(s, b.label)
	testing.expect(t, removed == 0 && !rc.found && !rc.label_gone && rc.emptied)
	check_labelled(t, s)
	destroy(s)
	free_all(context.temp_allocator)
}

@(test)
sampling_is_uniform_over_resolved_names :: proc(t: ^testing.T) {
	l: Lattice
	lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(1, 0, 1)})
	defer lattice_destroy(&l)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x5A3}
	a := lattice_access(&l, 1)
	b := lattice_access(&l, 2)
	top := lattice_access(&l, 3)
	s := new_labelled(t, &a, 3)
	defer destroy(s)
	x := make([]f32, 3)
	defer delete(x)
	for k in 0 ..< 12 {
		random_vector(&r, x)
		labelled_add(s, &a, fmt.tprintf("m%d", k), x, &sc)
	}
	for k in 6 ..< 18 {
		random_vector(&r, x)
		labelled_add(s, &b, fmt.tprintf("m%d", k), x, &sc)
	}
	for k in 15 ..< 20 {
		random_vector(&r, x)
		labelled_add(s, &top, fmt.tprintf("m%d", k), x, &sc)
	}
	v, _ := view_open(s, &top, &sc)
	n := view_size(&v)
	testing.expect_value(t, n, 20)
	shadowed := 0
	for vp in v.parts {
		shadowed += len(vp.shadow)
	}
	testing.expect_value(t, shadowed, 6)
	index :: proc(s: Vset, r: Ref) -> int {
		name := string(ref_name(s, r))
		v := 0
		for c in name[1:] {
			v = v * 10 + int(c - '0')
		}
		return v
	}
	chi :: proc(counts: []int, expected: f64) -> f64 {
		x := 0.0
		for c in counts {
			d := f64(c) - expected
			x += d * d / expected
		}
		return x
	}
	counts := make([]int, n)
	defer delete(counts)
	draws := 60000
	for _ in 0 ..< draws {
		ref, ok := view_random_member(&v)
		testing.expect(t, ok)
		counts[index(s, ref)] += 1
	}
	single := chi(counts, f64(draws) / f64(n))
	testing.expectf(t, single < 50, "single draws chi-square %v", single)
	for &c in counts {
		c = 0
	}
	out := make([dynamic]Ref)
	defer delete(out)
	rounds := 20000
	for _ in 0 ..< rounds {
		clear(&out)
		view_random_distinct(&v, 4, &out)
		for ref in out {
			counts[index(s, ref)] += 1
		}
	}
	spread := chi(counts, f64(rounds) * 4 / f64(n))
	testing.expectf(t, spread < 50 && !math.is_nan(spread), "distinct draws chi-square %v", spread)
}

@(test)
labelled_cas_matches_a_plain_labelled_add :: proc(t: ^testing.T) {
	old := limits_set(8, 2)
	defer limits_restore(old)
	l: Lattice
	lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(1, 0)})
	defer lattice_destroy(&l)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	build :: proc(t: ^testing.T, l: ^Lattice, sc: ^Scratch, cas: bool) -> (Vset, string) {
		l.stream = {1, 2, 3, 0, 0, 0, 0, 0}
		a := lattice_access(l, 1)
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
		return s, strings.clone(graph_text(s, part_at_label(s, a.label)))
	}
	plain, pt := build(t, &l, &sc, false)
	defer destroy(plain)
	defer delete(pt)
	cased, ct := build(t, &l, &sc, true)
	defer delete(ct)
	testing.expect(t, pt == ct)
	testing.expect(t, part_at_label(cased, l.ids[1]).mode == .Graph)
	upper := lattice_access(&l, 2)
	x := make([]f32, 5)
	defer delete(x)
	req := Add_Request{name = bytes_of("c3"), vector = x}
	plan: Cas_Plan
	testing.expect_value(t, cas_prepare_at(cased, &upper, &req, &plan, &sc).err, Error.None)
	_, f := cas_commit_at(cased, &upper, &plan, &sc)
	testing.expect(t, f.err == .Name_In_Use && f.label == l.ids[1])
	cas_discard(&plan)
	destroy(cased)
	free_all(context.temp_allocator)
}

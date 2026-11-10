package vsettype

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import "../hnsw"
import lbl "../label"

expected_nominal :: proc(n: int) -> int {
	if n <= 0 {
		return 0
	}
	return max(24, (n + 23) / 16 * 16 - 8)
}

expected_part_bytes :: proc(s: Vset, p: ^Part_Head) -> int {
	vector := s.dim
	switch quant(s) {
	case .NOQUANT:
		vector = 4 * s.dim
	case .BIN:
		vector = (s.dim + 63) / 64 * 8
	case .Q8:
		vector = s.dim + 4
	}
	n := 208 if p.kind == .Compact else 576
	n += p.count * (40 + 4 + 24 + 4 + vector)
	for i in 0 ..< p.count {
		e := &p.elements[p.order[i]]
		n += expected_nominal(int(e.len))
		if e.attr.blob != nil {
			n += expected_nominal(len(e.attr.blob))
		}
	}
	if p.kind == .Compact || p.mode == .Flat || p.count == 0 {
		return n
	}
	g := &(^Partition)(p).graph
	width := 2 if p.count <= 65_535 else 3 if p.count <= 16_777_215 else 4
	levels := 0
	for i in 0 ..< p.count {
		if slot := p.order[i]; !hnsw.is_twin(g, slot) {
			levels += int(g.levels[slot])
		}
	}
	n += 8 + p.count * (2 * g.m * width + 2 + 1 + 4) + levels * (g.m + 1) * width
	if g.twins > 0 {
		n += 4 * p.count
	}
	return n
}

expected_memory_of :: proc(v: ^View) -> int {
	if v.size == 0 {
		return 0
	}
	n := 616 + 56
	for &vp in v.parts {
		n += expected_part_bytes(v.set, view_head(v, &vp))
	}
	return n
}

expected_view_memory :: proc(s: Vset, a: ^Access, sc: ^Scratch) -> int {
	v, _ := view_open(s, a, sc)
	return expected_memory_of(&v)
}

observed_memory :: proc(s: Vset, a: ^Access, sc: ^Scratch) -> (memory: int, serialized: int) {
	if s == nil {
		return 0, 0
	}
	v, _ := view_open(s, a, sc)
	return view_memory(&v), view_serialized_size(&v)
}

perturb_charges :: proc(s: Vset, by: int) {
	if s.lab == nil {
		s.ledger.bytes += by
		return
	}
	for i in 0 ..< s.lab.sorted_len {
		c := part_charge(s, s.lab.sorted[i])
		c.bytes += by
		c.root.bytes += by
	}
	idx := s.lab.owners
	if idx == nil {
		return
	}
	for i in 0 ..< idx.slot_cap {
		sl := idx.slots[i]
		if sl.owner == SHARED {
			continue
		}
		for j in 0 ..< sl.scope.part_len {
			c := part_charge(s, sl.scope.parts[j])
			c.bytes += by
			c.root.bytes += by
		}
	}
}

@(test)
below_top_memory_is_the_documented_content_formula :: proc(t: ^testing.T) {
	old := limits_set(12, 3)
	defer limits_restore(old)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(1, 0)})
	defer lattice_destroy(&l.lattice)
	checked := 0
	graphs := 0
	compacts := 0
	for q in Quant {
		for dim in ([]int{3, 70}) {
			r := Test_Rng{state = 0xD6 + u64(dim) * 7 + u64(q)}
			x := make([]f32, dim)
			defer delete(x)
			writers := [?]Access{owner_access(&l, 0, SHARED), owner_access(&l, 1, SHARED), owner_access(&l, 2, SHARED), owner_access(&l, 0, 1), owner_access(&l, 1, 1), owner_access(&l, 2, 2)}
			s := new_labelled(t, &writers[0], dim, q)
			for i in 0 ..< 160 {
				w := &writers[test_below(&r, len(writers))]
				random_vector(&r, x)
				name := fmt.tprintf("%s%d", strings.repeat("n", test_below(&r, 40), context.temp_allocator), i % 70)
				switch test_below(&r, 8) {
				case 0 ..= 4:
					labelled_add(s, w, name, x, &sc, q, fmt.tprintf(`{{"a":%d,"pad":"%s"}}`, i, strings.repeat("p", test_below(&r, 60), context.temp_allocator)), test_below(&r, 3) != 0)
				case 5:
					remove_at(s, w, bytes_of(name), &sc)
				case:
					set_attribute_at(s, w, bytes_of(name), bytes_of(`{"b":1}`))
				}
				free_all(context.temp_allocator)
			}
			check_set(t, s)
			for i in 0 ..< s.lab.sorted_len {
				if s.lab.sorted[i].mode == .Graph {
					graphs += 1
				}
			}
			if idx := s.lab.owners; idx != nil {
				for i in 0 ..< idx.part_high {
					if p := idx.parts[i]; p != nil && p.kind == .Compact {
						compacts += 1
					}
				}
			}
			for reader in 0 ..< 3 {
				for o in ([]Owner{SHARED, 1, 2, 3}) {
					a := owner_access(&l, reader, o)
					top := owner_access(&l, reader, o, true)
					got, _ := observed_memory(s, &a, &sc)
					testing.expectf(t, got == expected_view_memory(s, &a, &sc), "%v dim %d reader %d/%d: memory %d, formula %d", q, dim, reader, o, got, expected_view_memory(s, &a, &sc))
					top_before, _ := observed_memory(s, &top, &sc)
					testing.expect_value(t, top_before, memory_usage(s))
					perturb_charges(s, 48)
					moved, _ := observed_memory(s, &a, &sc)
					top_after, _ := observed_memory(s, &top, &sc)
					perturb_charges(s, -48)
					testing.expectf(t, moved == got, "%v dim %d reader %d/%d: below-top memory moved with the allocator sizes, %d then %d", q, dim, reader, o, got, moved)
					testing.expectf(t, top_after > top_before, "%v dim %d reader %d/%d: the top figure no longer follows the real sizes", q, dim, reader, o)
					checked += 1
				}
			}
			destroy(s)
		}
	}
	testing.expect(t, checked == 72 && graphs > 0 && compacts > 0)
	log.infof("below-top memory: %d readers match the content formula and ignore allocator sizes, over %d shared graph partitions and %d compact owner blocks", checked, graphs, compacts)
}

@(test)
below_top_memory_stays_near_the_real_footprint :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	l: Lattice
	lattice_init(&l, {compartments_label(0), compartments_label(1)})
	defer lattice_destroy(&l)
	for q in Quant {
		for dim in ([]int{4, 64, 300}) {
			r := Test_Rng{state = 0xF0 + u64(dim)}
			s := new_set(t, dim, q)
			x := make([]f32, dim)
			defer delete(x)
			for i in 0 ..< 800 {
				random_vector(&r, x)
				add_values(t, s, fmt.tprintf("element-%d", i), x, q, fmt.tprintf(`{{"year":%d}}`, i), i % 2 == 0, &sc)
			}
			a := lattice_access(&l, 0)
			got, _ := observed_memory(s, &a, &sc)
			ratio := f64(got) / f64(memory_usage(s))
			testing.expectf(t, ratio > 0.75 && ratio < 1.1, "%v dim %d: below-top memory %d against the real %d", q, dim, got, memory_usage(s))
			destroy(s)
			free_all(context.temp_allocator)
		}
	}
}

History_Run :: struct {
	l:  Owner_Lattice,
	s:  Vset,
	sc: Scratch,
}

history_init :: proc(h: ^History_Run, labels: []lbl.Label) {
	owner_lattice_init(&h.l, labels)
	scratch_init(&h.sc)
}

history_destroy :: proc(h: ^History_Run) {
	if h.s != nil {
		destroy(h.s)
	}
	scratch_destroy(&h.sc)
	lattice_destroy(&h.l.lattice)
}

history_name :: proc(length: int, tag: string, step: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s%d.", tag, step)
	for strings.builder_len(b) < length {
		strings.write_byte(&b, 'x')
	}
	return strings.to_string(b)
}

history_write :: proc(h: ^History_Run, label: int, o: Owner, kind: int, name: string, x: []f32, attr: string) {
	a := owner_access(&h.l, label, o)
	if h.s == nil {
		if kind != 0 {
			return
		}
		req := Add_Request{vector = x}
		h.s, _ = create_at(&req, &a)
	}
	switch kind {
	case 0:
		labelled_add(h.s, &a, name, x, &h.sc, .Q8, attr, attr != "")
	case 1:
		remove_at(h.s, &a, bytes_of(name), &h.sc)
	case 2:
		set_attribute_at(h.s, &a, bytes_of(name), bytes_of(attr))
	case 3:
		remove_owner(h.s, o)
	case 4:
		remove_scope(h.s, a.label, o)
	}
	if card(h.s) == 0 {
		destroy(h.s)
		h.s = nil
	}
}

@(test)
hidden_allocation_history_never_moves_below_top_memory :: proc(t: ^testing.T) {
	old := limits_set(8, 2)
	defer limits_restore(old)
	labels := []lbl.Label{compartments_label(0), compartments_label(0, 0), compartments_label(1, 0)}
	quiet, busy: History_Run
	history_init(&quiet, labels)
	defer history_destroy(&quiet)
	history_init(&busy, labels)
	defer history_destroy(&busy)
	r := Test_Rng{state = 0xA110C}
	x := make([]f32, 4)
	defer delete(x)
	hidden_x := make([]f32, 4)
	defer delete(hidden_x)
	observers := [?]struct {
		label: int,
		owner: Owner,
	}{{0, 1}, {0, SHARED}, {1, 1}, {1, SHARED}}
	compared := 0
	different := 0
	for step in 0 ..< 360 {
		o := Owner(1) if step % 3 != 0 else SHARED
		length := 1040 + 16 * test_below(&r, 6) if test_below(&r, 4) != 0 else 1 + test_below(&r, 30)
		kind := 0 if test_below(&r, 10) < 7 else 1 + test_below(&r, 2)
		name := history_name(length, "v", test_below(&r, 40))
		attr := ""
		if kind == 2 || test_below(&r, 3) == 0 {
			attr = fmt.tprintf(`{{"pad":"%s"}}`, strings.repeat("a", 1032 + 16 * test_below(&r, 4), context.temp_allocator))
		}
		random_vector(&r, x)
		for k in 0 ..< 1 + test_below(&r, 3) {
			random_vector(&r, hidden_x)
			hidden := [?]struct {
				label: int,
				owner: Owner,
			}{{2, SHARED}, {0, 2}, {1, 3}, {2, 1}}
			hs := hidden[test_below(&r, len(hidden))]
			roll := test_below(&r, 40)
			switch {
			case roll == 0:
				history_write(&busy, hs.label, Owner(2 + test_below(&r, 2)), 3, "", hidden_x, "")
			case roll == 1:
				history_write(&busy, hs.label, hs.owner, 4, "", hidden_x, "")
			case roll < 6:
				for i in 0 ..< 12 {
					random_vector(&r, hidden_x)
					history_write(&busy, hs.label, hs.owner, 0, history_name(20, "g", i), hidden_x, "")
				}
				for i in 0 ..< 11 {
					history_write(&busy, hs.label, hs.owner, 1, history_name(20, "g", i), hidden_x, "")
				}
			case:
				bait := history_name(length + 16, "h", step * 4 + k)
				history_write(&busy, hs.label, hs.owner, 0, bait, hidden_x, "")
				history_write(&busy, hs.label, hs.owner, 0, history_name(3, "w", step * 4 + k), hidden_x, "")
				history_write(&busy, hs.label, hs.owner, 1, bait, hidden_x, "")
			}
		}
		history_write(&quiet, 0, o, kind, name, x, attr)
		history_write(&busy, 0, o, kind, name, x, attr)
		for ob in observers {
			qa := owner_access(&quiet.l, ob.label, ob.owner)
			ba := owner_access(&busy.l, ob.label, ob.owner)
			qm, qs := observed_memory(quiet.s, &qa, &quiet.sc)
			bm, bs := observed_memory(busy.s, &ba, &busy.sc)
			if qm != bm {
				different += 1
			}
			testing.expectf(t, qm == bm && qs == bs, "step %d observer %d/%d: memory %d and %d, serialized %d and %d", step, ob.label, ob.owner, qm, bm, qs, bs)
			compared += 1
		}
		free_all(context.temp_allocator)
	}
	testing.expect(t, compared == 360 * len(observers))
	testing.expect_value(t, different, 0)
	log.infof("allocation history: %d below-top MEMORY USAGE and serialized lengths compared between a quiet and a busy hidden history", compared)
}

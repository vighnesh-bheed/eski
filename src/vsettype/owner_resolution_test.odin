package vsettype

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import lbl "../label"

@(test)
owner_copies_win_only_at_the_same_rank :: proc(t: ^testing.T) {
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(1, 0, 1)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	a_shared := owner_access(&l, 1, SHARED)
	b_shared := owner_access(&l, 2, SHARED)
	top_shared := owner_access(&l, 3, SHARED)
	bottom_shared := owner_access(&l, 0, SHARED)
	a_user := owner_access(&l, 1, 1)
	b_user := owner_access(&l, 2, 1)
	top_user := owner_access(&l, 3, 1)
	bottom_user := owner_access(&l, 0, 1)
	top_other := owner_access(&l, 3, 2)
	s := new_labelled(t, &a_shared, 3)
	defer destroy(s)
	put :: proc(t: ^testing.T, s: Vset, a: ^Access, name: string, v: f32, sc: ^Scratch) {
		x := []f32{v, 1 - v, 0.25}
		_, f := labelled_add(s, a, name, x, sc)
		testing.expectf(t, f.err == .None, "write %q at %d/%d: %v", name, a.label, a.owner, f.err)
	}
	put(t, s, &a_shared, "tie", 0.1, &sc)
	put(t, s, &b_user, "tie", 0.2, &sc)
	put(t, s, &top_shared, "rank", 0.3, &sc)
	put(t, s, &a_user, "rank", 0.4, &sc)
	put(t, s, &top_user, "exact", 0.6, &sc)
	put(t, s, &top_shared, "exact", 0.5, &sc)
	put(t, s, &a_user, "older", 0.7, &sc)
	put(t, s, &b_user, "older", 0.8, &sc)
	put(t, s, &a_shared, "low", 0.9, &sc)
	put(t, s, &bottom_user, "low", 0.15, &sc)
	put(t, s, &a_shared, "pair", 0.35, &sc)
	put(t, s, &b_shared, "pair", 0.45, &sc)
	check_labelled(t, s)
	Want :: struct {
		name:  string,
		label: lbl.Id,
		owner: Owner,
	}
	expect_view :: proc(t: ^testing.T, s: Vset, a: ^Access, sc: ^Scratch, wants: []Want) {
		v, _ := view_open(s, a, sc)
		for w in wants {
			r, ok := view_find(&v, bytes_of(w.name))
			if w.label == lbl.ID_NONE {
				testing.expectf(t, !ok, "reader %d/%d finds %q", a.label, a.owner, w.name)
				continue
			}
			testing.expectf(t, ok && ref_label(s, r) == w.label && ref_owner(s, r) == w.owner, "reader %d/%d resolves %q to %v, want %d/%d", a.label, a.owner, w.name, ref_scope(s, r) if ok else Scope{}, w.label, w.owner)
		}
	}
	la, lb, lt, l0 := l.ids[1], l.ids[2], l.ids[3], l.ids[0]
	expect_view(t, s, &top_user, &sc, {{"tie", lb, 1}, {"rank", lt, SHARED}, {"exact", lt, 1}, {"older", la, 1}, {"low", la, SHARED}, {"pair", la, SHARED}})
	expect_view(t, s, &top_shared, &sc, {{"tie", la, SHARED}, {"rank", lt, SHARED}, {"exact", lt, SHARED}, {"older", lbl.ID_NONE, SHARED}, {"low", la, SHARED}, {"pair", la, SHARED}})
	expect_view(t, s, &top_other, &sc, {{"tie", la, SHARED}, {"rank", lt, SHARED}, {"exact", lt, SHARED}, {"older", lbl.ID_NONE, SHARED}, {"low", la, SHARED}})
	expect_view(t, s, &a_user, &sc, {{"tie", la, SHARED}, {"rank", la, 1}, {"exact", lbl.ID_NONE, SHARED}, {"older", la, 1}, {"low", la, SHARED}, {"pair", la, SHARED}})
	expect_view(t, s, &b_user, &sc, {{"tie", lb, 1}, {"rank", lbl.ID_NONE, SHARED}, {"older", lb, 1}, {"low", l0, 1}, {"pair", lb, SHARED}})
	expect_view(t, s, &bottom_user, &sc, {{"tie", lbl.ID_NONE, SHARED}, {"low", l0, 1}})
	expect_view(t, s, &bottom_shared, &sc, {{"low", lbl.ID_NONE, SHARED}})
	x := []f32{0.5, 0.5, 0.5}
	_, f := labelled_add(s, &top_user, "tie", x, &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == lb && f.owner == 1, "INUSE names the own copy at the tie: %v %d/%d", f.err, f.label, f.owner)
	_, f = labelled_add(s, &top_user, "rank", x, &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == lt && f.owner == SHARED, "INUSE names the higher shared copy: %v %d/%d", f.err, f.label, f.owner)
	_, f = labelled_add(s, &top_user, "older", x, &sc)
	testing.expectf(t, f.err == .Name_In_Use && f.label == la && f.owner == 1, "INUSE names the older own copy: %v %d/%d", f.err, f.label, f.owner)
	_, f = labelled_add(s, &top_other, "older", x, &sc)
	testing.expectf(t, f.err == .None, "another owner sees a private name: %v", f.err)
	top, ok := top_visible_scope(s, &top_user)
	testing.expect(t, ok && top == Scope{label = lt, owner = 1})
	ch: Change
	ch, f = remove_at(s, &top_user, bytes_of("exact"), &sc)
	testing.expect(t, f.err == .None && ch.found && ch.label_gone && !ch.emptied)
	expect_view(t, s, &top_user, &sc, {{"exact", lt, SHARED}})
	top, ok = top_visible_scope(s, &top_user)
	testing.expect(t, ok && top == Scope{label = lt, owner = SHARED})
	top, ok = top_visible_scope(s, &bottom_user)
	testing.expect(t, ok && top == Scope{label = l0, owner = 1})
	top, ok = top_visible_scope(s, &bottom_shared)
	testing.expect(t, !ok)
	free_all(context.temp_allocator)
}

Twin_Op :: struct {
	writer: int,
	owner:  Owner,
	kind:   int,
	name:   string,
	vector: []f32,
	attr:   string,
	set:    bool,
}

Twin :: struct {
	s:       Vset,
	scheme:  ^Scheme,
	streams: [dynamic][OWNERS_TESTED]u64,
	shared:  [dynamic]u64,
	sc:      Scratch,
}

twin_init :: proc(w: ^Twin, scheme: ^Scheme) {
	w.scheme = scheme
	for i in 0 ..< len(scheme.ids) {
		row: [OWNERS_TESTED]u64
		for k in 0 ..< OWNERS_TESTED {
			row[k] = stream_seed(scheme.ids[i]) ~ (u64(k + 3) * 0x5851F42D4C957F2D)
		}
		append(&w.streams, row)
		append(&w.shared, stream_seed(scheme.ids[i]) ~ 0x77)
	}
	scratch_init(&w.sc)
}

twin_destroy :: proc(w: ^Twin) {
	if w.s != nil {
		destroy(w.s)
	}
	delete(w.streams)
	delete(w.shared)
	scratch_destroy(&w.sc)
}

twin_access :: proc(w: ^Twin, i: int, o: Owner) -> Access {
	a := scheme_access(w.scheme, i)
	a.owner = o
	a.stream = &w.shared[i] if o == SHARED else &w.streams[i][int(o)]
	return a
}

twin_apply :: proc(w: ^Twin, op: ^Twin_Op, quant: Quant, dim: int) {
	a := twin_access(w, op.writer, op.owner)
	if w.s == nil {
		x := make([]f32, dim, context.temp_allocator)
		req := Add_Request{vector = x, quant = quant}
		w.s, _ = create_at(&req, &a)
	}
	switch op.kind {
	case 0 ..= 5:
		labelled_add(w.s, &a, op.name, op.vector, &w.sc, quant, op.attr, op.set)
	case 6, 7:
		remove_at(w.s, &a, bytes_of(op.name), &w.sc)
	case 8:
		set_attribute_at(w.s, &a, bytes_of(op.name), bytes_of(op.attr))
	case 9:
		req := Add_Request{name = bytes_of(op.name), vector = op.vector, quant = quant}
		plan: Cas_Plan
		if cas_prepare_at(w.s, &a, &req, &plan, &w.sc).err == .None {
			cas_commit_at(w.s, &a, &plan, &w.sc)
		}
		cas_discard(&plan)
	case 10:
		remove_scope(w.s, a.label, op.owner)
	case:
		if op.owner != SHARED {
			remove_owner(w.s, op.owner)
		}
	}
	if card(w.s) == 0 {
		destroy(w.s)
		w.s = nil
	}
}

twin_digest :: proc(w: ^Twin, reader: int, o: Owner, names: []string, queries: [][]f32, links: ^Links) -> string {
	a := twin_access(w, reader, o)
	stream: u64
	a.stream = &stream
	if w.s == nil || !has_visible(w.s, &a) {
		return "missing"
	}
	return strings.clone(strip_memory(view_digest(w.s, &a, names, queries, &w.sc, links)), context.temp_allocator)
}

twin_hidden :: proc(scheme: ^Scheme, reader: int, o: Owner, op: ^Twin_Op) -> bool {
	if op.owner != SHARED && op.owner != o {
		return true
	}
	if op.kind == 11 {
		return op.owner != o
	}
	return !scheme_sees(scheme, reader, scheme.ids[op.writer])
}

@(test)
other_owners_never_change_a_readers_replies :: proc(t: ^testing.T) {
	old := limits_set(8, 2)
	defer limits_restore(old)
	compared := 0
	sensitive := 0
	pairs := 0
	for seed in ([]u64{0x71, 0x72, 0x73}) {
		r := Test_Rng{state = seed}
		scheme: Scheme
		scheme_init(&scheme, &r, 3, 2, 6, 3)
		defer scheme_destroy(&scheme)
		quant := Quant(seed % 3)
		dim := 5
		names := make([dynamic]string)
		defer {
			for n in names {
				delete(n)
			}
			delete(names)
		}
		for i in 0 ..< 24 {
			append(&names, fmt.aprintf("n%d", i))
		}
		queries := make([][]f32, 2)
		defer {
			for q in queries {
				delete(q)
			}
			delete(queries)
		}
		for &q in queries {
			q = make([]f32, dim)
			random_vector(&r, q)
		}
		ops := make([dynamic]Twin_Op)
		defer {
			for op in ops {
				delete(op.vector)
				delete(op.attr)
			}
			delete(ops)
		}
		for _ in 0 ..< 700 {
			op := Twin_Op{writer = test_below(&r, len(scheme.ids)), owner = pick_owner(&r), kind = test_below(&r, 12), name = names[test_below(&r, len(names))], set = test_below(&r, 2) == 0}
			op.vector = make([]f32, dim)
			random_vector(&r, op.vector)
			op.attr = fmt.aprintf(`{{"a":%d}}`, test_below(&r, 4))
			if op.kind >= 10 && test_below(&r, 3) != 0 {
				op.kind = 0
			}
			append(&ops, op)
		}
		for reader in 0 ..< len(scheme.ids) {
			for k in 0 ..< OWNERS_TESTED {
				o := Owner(k)
				full, purged: Twin
				twin_init(&full, &scheme)
				twin_init(&purged, &scheme)
				links: Links
				for &op, i in ops {
					twin_apply(&full, &op, quant, dim)
					if !twin_hidden(&scheme, reader, o, &op) {
						twin_apply(&purged, &op, quant, dim)
					}
					if i % 70 == 69 {
						if full.s != nil {
							check_set(t, full.s)
						}
						a := twin_digest(&full, reader, o, names[:], queries, &links)
						b := twin_digest(&purged, reader, o, names[:], queries, &links)
						if !testing.expectf(t, a == b, "seed %x reader %d/%d differs after %d commands\n%s", seed, reader, o, i + 1, digest_difference(a, b)) {
							break
						}
						compared += 1
					}
					free_all(context.temp_allocator)
				}
				probe := Twin_Op{writer = reader, owner = SHARED, kind = 0, name = "probe", vector = queries[0]}
				twin_apply(&purged, &probe, quant, dim)
				a := twin_digest(&full, reader, o, names[:], queries, &links)
				b := twin_digest(&purged, reader, o, names[:], queries, &links)
				if a != b {
					sensitive += 1
				}
				pairs += 1
				links_destroy(&links)
				twin_destroy(&full)
				twin_destroy(&purged)
				free_all(context.temp_allocator)
			}
		}
	}
	testing.expectf(t, sensitive == pairs && compared == 10 * pairs, "a visible shared write changed %d of %d final digests, %d compared", sensitive, pairs, compared)
	log.infof("owner twins: %d digests compared between full and purged histories; a visible shared write changed all %d final digests", compared, sensitive)
}

strip_memory :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		if at := strings.index(line, " memory "); at >= 0 {
			rest := line[at + len(" memory "):]
			stop := strings.index_byte(rest, ' ')
			fmt.sbprintf(&b, "%s memory _%s\n", line[:at], rest[stop:] if stop >= 0 else "")
			continue
		}
		fmt.sbprintf(&b, "%s\n", line)
	}
	return strings.to_string(b)
}

@(test)
one_owner_alone_reads_like_shared_data :: proc(t: ^testing.T) {
	old := limits_set(10, 3)
	defer limits_restore(old)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(1, 0)})
	defer lattice_destroy(&l.lattice)
	names := make([dynamic]string)
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	for i in 0 ..< 30 {
		append(&names, fmt.aprintf("n%d", i))
	}
	build :: proc(t: ^testing.T, l: ^Owner_Lattice, o: Owner, names: []string, sc: ^Scratch) -> Vset {
		r := Test_Rng{state = 0xA1}
		state := [3]u64{11, 22, 33}
		x := make([]f32, 4, context.temp_allocator)
		s: Vset
		for _ in 0 ..< 400 {
			w := 1 + test_below(&r, 2)
			a := owner_access(l, w, o)
			a.stream = &state[w]
			random_vector(&r, x)
			name := names[test_below(&r, len(names))]
			if s == nil {
				req := Add_Request{vector = x}
				s, _ = create_at(&req, &a)
			}
			switch test_below(&r, 6) {
			case 0 ..= 3:
				labelled_add(s, &a, name, x, sc, .Q8, fmt.tprintf(`{{"a":%d}}`, test_below(&r, 3)), test_below(&r, 2) == 0)
			case 4:
				remove_at(s, &a, bytes_of(name), sc)
			case:
				set_attribute_at(s, &a, bytes_of(name), bytes_of(`{"a":2}`))
			}
			if card(s) == 0 {
				destroy(s)
				s = nil
			}
		}
		check_set(t, s)
		return s
	}
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	shared := build(t, &l, SHARED, names[:], &sc)
	defer destroy(shared)
	owned := build(t, &l, 4, names[:], &sc)
	defer destroy(owned)
	testing.expect(t, owner_count(owned) == 1 && owned.lab.sorted_len == 0)
	graphs := 0
	for i in 0 ..< shared.lab.sorted_len {
		if shared.lab.sorted[i].mode == .Graph {
			graphs += 1
		}
	}
	testing.expect(t, graphs > 0)
	query := []f32{0.3, -0.2, 0.9, 0.1}
	queries := [][]f32{query}
	links: Links
	defer links_destroy(&links)
	for reader in 1 ..< 3 {
		sa := owner_access(&l, reader, SHARED)
		oa := owner_access(&l, reader, 4)
		a := strip_memory(view_digest(shared, &sa, names[:], queries, &sc, &links))
		a = strings.clone(a, context.temp_allocator)
		b := strip_memory(view_digest(owned, &oa, names[:], queries, &sc, &links))
		testing.expectf(t, a == b, "reader %d: one owner alone differs from shared data\n%s", reader, digest_difference(a, b))
	}
	free_all(context.temp_allocator)
}

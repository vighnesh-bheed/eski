package vsettype

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import lbl "../label"

Saved_Part :: struct {
	scope: Scope,
	data:  []u8,
}

set_scopes :: proc(s: Vset, out: ^[dynamic]Scope) {
	clear(out)
	for i in 0 ..< s.lab.sorted_len {
		append(out, Scope{label = s.lab.sorted[i].label})
	}
	if idx := s.lab.owners; idx != nil {
		for i in 0 ..< idx.slot_cap {
			sl := idx.slots[i]
			if sl.owner == SHARED {
				continue
			}
			for j in 0 ..< sl.scope.part_len {
				append(out, Scope{label = sl.scope.parts[j].label, owner = sl.owner})
			}
		}
	}
}

save_parts :: proc(s: Vset, ctx: ^Save_Context, out: ^[dynamic]Saved_Part) {
	scopes: [dynamic]Scope
	defer delete(scopes)
	set_scopes(s, &scopes)
	object := save_object(ctx, s)
	for sc in scopes {
		plan, ok := scoped_plan(s, sc, object)
		if !ok {
			continue
		}
		buf := make([]u8, plan.size)
		b := Byte_Sink{out = buf}
		scoped_write(s, sc, &plan, Sink{ctx = &b, write = byte_sink_write})
		append(out, Saved_Part{scope = sc, data = buf})
	}
}

saved_destroy :: proc(parts: ^[dynamic]Saved_Part) {
	for p in parts {
		delete(p.data)
	}
	delete(parts^)
}

load_parts :: proc(t: ^testing.T, parts: []Saved_Part, drop: int = -1) -> (s: Vset, err: Decode_Error) {
	ctx: Load_Context
	defer load_context_destroy(&ctx)
	for p, i in parts {
		got, fresh, e := load_part(&ctx, p.data, 0, bytes_of("key"), p.scope, i != drop)
		if e != .None {
			if s != nil {
				destroy(s)
			}
			return nil, e
		}
		if fresh {
			s = got
		}
	}
	if err = load_finish(&ctx); err != .None && s != nil {
		destroy(s)
		s = nil
	}
	return
}

copies_text :: proc(s: Vset) -> string {
	b := strings.builder_make(context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	emit :: proc(s: Vset, lines: ^[dynamic]string, set: ^Name_Set, o: Owner) {
		for m in 0 ..< set.multi_len {
			c := set.multis[m]
			e := copies_entries(c)[:c.count]
			line := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&line, "%d %q:", o, string(ref_name(s, e[0])))
			for r in e {
				p := ref_part(s, r)
				fmt.sbprintf(&line, " %d/%d", p.label, p.owner)
			}
			append(lines, strings.to_string(line))
		}
	}
	emit(s, &lines, &s.lab.names, SHARED)
	if idx := s.lab.owners; idx != nil {
		for i in 0 ..< idx.slot_cap {
			if sl := idx.slots[i]; sl.owner != SHARED {
				emit(s, &lines, &sl.scope.own, sl.owner)
			}
		}
	}
	slice.sort(lines[:])
	for l in lines {
		fmt.sbprintf(&b, "%s\n", l)
	}
	return strings.to_string(b)
}

Scoped_World :: struct {
	l:     Owner_Lattice,
	names: [dynamic]string,
	limit: Limits,
}

SCOPED_OWNERS :: [3]Owner{SHARED, 3, 5}

world_init :: proc(w: ^Scoped_World) {
	owner_lattice_init(&w.l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(1, 0), compartments_label(1, 0, 1)})
	for i in 0 ..< 70 {
		append(&w.names, fmt.aprintf("n%d", i))
	}
	w.limit = limits_set(24, 8)
}

world_destroy :: proc(w: ^Scoped_World) {
	limits_restore(w.limit)
	for n in w.names {
		delete(n)
	}
	delete(w.names)
	lattice_destroy(&w.l.lattice)
}

world_writes :: proc(w: ^Scoped_World, s: ^Vset, r: ^Test_Rng, n: int, sc: ^Scratch) {
	x := make([]f32, 4, context.temp_allocator)
	owners := SCOPED_OWNERS
	for _ in 0 ..< n {
		li := test_below(r, w.l.n)
		o := owners[test_below(r, len(owners))]
		a := owner_access(&w.l, li, o)
		random_vector(r, x)
		name := w.names[test_below(r, len(w.names))]
		if s^ == nil {
			req := Add_Request{vector = x}
			s^, _ = create_at(&req, &a)
		}
		switch test_below(r, 8) {
		case 0 ..= 5:
			labelled_add(s^, &a, name, x, sc, .Q8, fmt.tprintf(`{{"a":%d}}`, test_below(r, 3)), test_below(r, 2) == 0)
		case 6:
			remove_at(s^, &a, bytes_of(name), sc)
		case:
			set_attribute_at(s^, &a, bytes_of(name), bytes_of(`{"a":2}`))
		}
		if card(s^) == 0 {
			destroy(s^)
			s^ = nil
		}
	}
	free_all(context.temp_allocator)
}

world_digest :: proc(w: ^Scoped_World, s: Vset, sc: ^Scratch) -> string {
	b := strings.builder_make(context.temp_allocator)
	queries := [][]f32{{0.3, -0.2, 0.9, 0.1}, {-0.5, 0.5, 0.1, 0.0}}
	links: Links
	defer links_destroy(&links)
	owners := SCOPED_OWNERS
	for li in 0 ..< w.l.n {
		for o in owners {
			a := owner_access(&w.l, li, o)
			stream := u64(0)
			if a.stream == nil {
				a.stream = &stream
			}
			fmt.sbprintf(&b, "reader %d/%d\n%s", li, o, view_digest(s, &a, w.names[:], queries, sc, &links))
		}
	}
	return strings.to_string(b)
}

world_modes :: proc(s: Vset) -> (flat: int, graph: int) {
	scopes: [dynamic]Scope
	defer delete(scopes)
	set_scopes(s, &scopes)
	for x in scopes {
		p := part_at_scope(s, x.label, x.owner)
		switch p.mode {
		case .Flat:
			flat += 1
		case .Graph:
			graph += 1
		case .Pinned:
		}
	}
	return
}

@(test)
scoped_payloads_reload_every_view :: proc(t: ^testing.T) {
	w: Scoped_World
	world_init(&w)
	defer world_destroy(&w)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x5C0FE}
	s: Vset
	world_writes(&w, &s, &r, 1500, &sc)
	defer destroy(s)
	flat, graph := world_modes(s)
	testing.expectf(t, flat > 0 && graph > 0, "both partition kinds are present: %d flat, %d graph", flat, graph)
	testing.expect(t, s.lab.multi_len > 0, "names are held by several copies")
	ctx: Save_Context
	parts: [dynamic]Saved_Part
	save_parts(s, &ctx, &parts)
	save_context_destroy(&ctx)
	defer saved_destroy(&parts)
	before := strings.clone(world_digest(&w, s, &sc))
	defer delete(before)
	copies := strings.clone(copies_text(s))
	defer delete(copies)
	rr := Test_Rng{state = 0xAB}
	for round in 0 ..< 2 {
		order := slice.clone(parts[:])
		defer delete(order)
		if round == 1 {
			for i := len(order) - 1; i > 0; i -= 1 {
				j := test_below(&rr, i + 1)
				order[i], order[j] = order[j], order[i]
			}
		}
		back, err := load_parts(t, order)
		if !testing.expectf(t, err == .None, "round %d: load failed with %v", round, err) {
			continue
		}
		testing.expect(t, check_set(t, back))
		after := world_digest(&w, back, &sc)
		testing.expectf(t, after == before, "round %d: a reader's view differs after the reload\n%s", round, digest_difference(before, after))
		testing.expectf(t, copies_text(back) == copies, "round %d: the order of copies changed\n%s\n%s", round, copies, copies_text(back))
		if round == 0 {
			a := Test_Rng{state = 0x777}
			b := a
			s2 := s
			world_writes(&w, &s2, &a, 400, &sc)
			world_writes(&w, &back, &b, 400, &sc)
			x := strings.clone(world_digest(&w, s2, &sc))
			y := world_digest(&w, back, &sc)
			testing.expectf(t, x == y, "views differ after the same further writes\n%s", digest_difference(x, y))
			delete(x)
			s = s2
			free_all(context.temp_allocator)
			ctx2: Save_Context
			again: [dynamic]Saved_Part
			save_parts(back, &ctx2, &again)
			save_context_destroy(&ctx2)
			mine: [dynamic]Saved_Part
			ctx3: Save_Context
			save_parts(s, &ctx3, &mine)
			save_context_destroy(&ctx3)
			testing.expect_value(t, len(again), len(mine))
			for i in 0 ..< min(len(again), len(mine)) {
				testing.expectf(t, again[i].scope == mine[i].scope && string(again[i].data) == string(mine[i].data), "partition %v encodes differently after the same writes", mine[i].scope)
			}
			saved_destroy(&again)
			saved_destroy(&mine)
		}
		destroy(back)
		free_all(context.temp_allocator)
	}
}

@(test)
scoped_payloads_discard_a_dropped_partition :: proc(t: ^testing.T) {
	w: Scoped_World
	world_init(&w)
	defer world_destroy(&w)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0xD15C}
	s: Vset
	world_writes(&w, &s, &r, 1200, &sc)
	defer destroy(s)
	ctx: Save_Context
	parts: [dynamic]Saved_Part
	save_parts(s, &ctx, &parts)
	save_context_destroy(&ctx)
	defer saved_destroy(&parts)
	tried := 0
	for drop in 0 ..< len(parts) {
		gone := parts[drop].scope
		back, err := load_parts(t, parts[:], drop)
		if !testing.expectf(t, err == .None, "dropping %v: load failed with %v", gone, err) {
			continue
		}
		reference: Vset
		reference, err = load_parts(t, parts[:])
		testing.expect_value(t, err, Decode_Error.None)
		remove_scope(reference, gone.label, gone.owner)
		testing.expect(t, part_at_scope(back, gone.label, gone.owner) == nil)
		x := strings.clone(world_digest(&w, reference, &sc))
		y := world_digest(&w, back, &sc)
		testing.expectf(t, x == y, "dropping %v leaves a different state than removing it\n%s", gone, digest_difference(x, y))
		testing.expect(t, copies_text(back) == copies_text(reference))
		delete(x)
		destroy(back)
		destroy(reference)
		free_all(context.temp_allocator)
		tried += 1
	}
	testing.expect(t, tried > 3)
}

scoped_case :: proc(t: ^testing.T, name: string, parts: []Saved_Part, want: Decode_Error) {
	live := blocks_live
	back, err := load_parts(t, parts)
	if back != nil {
		destroy(back)
	}
	testing.expectf(t, err == want, "%s: got %v, wanted %v", name, err, want)
	testing.expectf(t, blocks_live == live, "%s: %d blocks of the set's own allocator left behind", name, blocks_live - live)
}

@(test)
scoped_payloads_refuse_what_does_not_belong :: proc(t: ^testing.T) {
	w: Scoped_World
	world_init(&w)
	defer world_destroy(&w)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0xBAD5}
	s: Vset
	world_writes(&w, &s, &r, 1500, &sc)
	defer destroy(s)
	ctx: Save_Context
	parts: [dynamic]Saved_Part
	save_parts(s, &ctx, &parts)
	save_context_destroy(&ctx)
	defer saved_destroy(&parts)
	twice := slice.clone(parts[:])
	defer delete(twice)
	twice[1] = twice[0]
	scoped_case(t, "a partition twice", twice, .Bad_Scope)
	ranked := -1
	flat_at, graph_at := -1, -1
	for p, i in parts {
		c := craft_parse(p.data)
		if c.flags & CODEC_RANKS != 0 && ranked < 0 {
			ranked = i
		}
		if c.mode == 1 && flat_at < 0 {
			flat_at = i
		}
		if c.mode == 2 && graph_at < 0 {
			graph_at = i
		}
		craft_destroy(&c)
	}
	testing.expect(t, ranked >= 0 && flat_at >= 0 && graph_at >= 0)
	mutate :: proc(t: ^testing.T, parts: []Saved_Part, at: int, name: string, want: Decode_Error, change: proc(c: ^Craft) -> bool) {
		c := craft_parse(parts[at].data)
		defer craft_destroy(&c)
		if !testing.expectf(t, change(&c), "%s: no place for the change", name) {
			return
		}
		copy_parts := slice.clone(parts)
		defer delete(copy_parts)
		data := craft_emit(&c)
		defer delete(data)
		copy_parts[at].data = data
		scoped_case(t, name, copy_parts, want)
	}
	mutate(t, parts[:], 0, "object number beyond the next", .Bad_Object, proc(c: ^Craft) -> bool {c.object = 5; return true})
	mutate(t, parts[:], len(parts) - 1, "another object's parameters", .Bad_Object, proc(c: ^Craft) -> bool {c.m += 1; return true})
	mutate(t, parts[:], ranked, "a rank out of order", .Bad_Rank, proc(c: ^Craft) -> bool {
		for &e in c.elements {
			if e.copies > 1 {
				e.rank = (e.rank + 1) % e.copies
				return true
			}
		}
		return false
	})
	mutate(t, parts[:], ranked, "a copy count that does not match", .Bad_Rank, proc(c: ^Craft) -> bool {
		for &e in c.elements {
			if e.copies > 1 {
				e.copies += 1
				return true
			}
		}
		return false
	})
	mutate(t, parts[:], ranked, "a copy that claims to be alone", .Bad_Rank, proc(c: ^Craft) -> bool {
		for &e in c.elements {
			if e.copies > 1 {
				e.copies = 1
				e.rank = 0
				return true
			}
		}
		return false
	})
	mutate(t, parts[:], ranked, "ranks without their flag", .Bad_Rank, proc(c: ^Craft) -> bool {
		c.flags &~= CODEC_RANKS
		return true
	})
	mutate(t, parts[:], 0, "an unscoped payload", .Bad_Scope, proc(c: ^Craft) -> bool {c.flags &~= CODEC_SCOPED; return true})
	keyed := slice.clone(parts[:])
	defer delete(keyed)
	ctx2: Load_Context
	_, _, e1 := load_part(&ctx2, keyed[0].data, 0, bytes_of("key"), keyed[0].scope, true)
	_, _, e2 := load_part(&ctx2, keyed[1].data, 0, bytes_of("other"), keyed[1].scope, true)
	testing.expect(t, e1 == .None && e2 == .Bad_Object, "a partition under another key name is refused")
	for &o in ctx2.objects {
		if o.set != nil {
			destroy(o.set)
		}
	}
	load_context_destroy(&ctx2)
	ctx3: Load_Context
	_, _, e3 := load_part(&ctx3, keyed[0].data, 0, bytes_of("key"), keyed[0].scope, true)
	_, _, e4 := load_part(&ctx3, keyed[1].data, 1, bytes_of("key"), keyed[1].scope, true)
	testing.expect(t, e3 == .None && e4 == .Bad_Object, "a partition in another database is refused")
	for &o in ctx3.objects {
		if o.set != nil {
			destroy(o.set)
		}
	}
	load_context_destroy(&ctx3)
	_, err := deserialize(parts[0].data, &sc)
	testing.expect_value(t, err, Decode_Error.Bad_Scope)
	old := limits_set(flat_limit, shrink_limit)
	fc := craft_parse(parts[flat_at].data)
	flat_limit = int(fc.count) - 1
	craft_destroy(&fc)
	scoped_case(t, "a flat partition above the flat limit", parts[:], .None)
	limits_restore(old)
	gc := craft_parse(parts[graph_at].data)
	shrink_limit = int(gc.count)
	craft_destroy(&gc)
	scoped_case(t, "a graph partition at the shrink limit", parts[:], .None)
	limits_restore(old)
	mutate(t, parts[:], flat_at, "a name repeated inside one partition", .Duplicate_Name, proc(c: ^Craft) -> bool {
		if len(c.elements) < 2 {return false}
		clear(&c.elements[1].name)
		append(&c.elements[1].name, ..c.elements[0].name[:])
		return true
	})
	mutate(t, parts[:], 0, "a name repeated inside the first partition of the set", .Duplicate_Name, proc(c: ^Craft) -> bool {
		if len(c.elements) < 2 {return false}
		clear(&c.elements[1].name)
		append(&c.elements[1].name, ..c.elements[0].name[:])
		return true
	})
	bottom := -1
	for p, i in parts {
		pc := craft_parse(p.data)
		mode := pc.mode
		craft_destroy(&pc)
		if p.scope.label != lbl.BOTTOM_ID && mode == 2 {
			bottom = i
			break
		}
	}
	testing.expect(t, bottom >= 0)
	mutate(t, parts[:], bottom, "a pinned partition above the bottom label", .Bad_Scope, proc(c: ^Craft) -> bool {
		if c.mode != 2 {return false}
		c.mode = 0
		return true
	})
}

@(test)
view_payloads_restore_at_another_scope :: proc(t: ^testing.T) {
	w: Scoped_World
	world_init(&w)
	defer world_destroy(&w)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x7E1}
	s: Vset
	world_writes(&w, &s, &r, 1200, &sc)
	defer destroy(s)
	reader := owner_access(&w.l, 4, 3)
	v, _ := view_open(s, &reader, &sc)
	want := make([dynamic]string, context.temp_allocator)
	for &vp in v.parts {
		for i in 0 ..< vp.part.count {
			slot := vp.part.order[i]
			if len(vp.shadow) > 0 && slot_shadowed(vp.shadow, slot) {
				continue
			}
			raw := part_raw_embedding(vp.part, slot)
			text, has := part_element_attribute(vp.part, slot)
			append(&want, fmt.tprintf("%s %x %x %v %s", string(part_element_name(vp.part, slot)), raw.data, transmute(u32)raw.norm, has, text))
		}
	}
	payload, ok := view_serialize_bytes(&v)
	testing.expect(t, ok)
	testing.expect_value(t, len(payload), view_serialized_size(&v))
	defer delete(payload)
	c := craft_parse(payload)
	testing.expect(t, c.mode == 1 && c.flags == 0 && int(c.count) == len(want) && c.rng == 0)
	craft_destroy(&c)
	plain, err := deserialize(payload, &sc, 0x1234)
	if testing.expect_value(t, err, Decode_Error.None) {
		testing.expect(t, check_invariants(t, plain))
		got := make([dynamic]string, context.temp_allocator)
		for i in 0 ..< plain.count {
			slot := plain.order[i]
			raw := raw_embedding(plain, slot)
			text, has := element_attribute(plain, slot)
			append(&got, fmt.tprintf("%s %x %x %v %s", string(element_name(plain, slot)), raw.data, transmute(u32)raw.norm, has, text))
		}
		testing.expect(t, slice.equal(got[:], want[:]), "a view restored without labels holds the view's elements in view order")
		destroy(plain)
	}
	for target in ([][2]int{{0, 0}, {1, 5}, {3, 0}}) {
		a := owner_access(&w.l, target[0], Owner(target[1]))
		stream: u64
		if a.stream == nil {
			a.stream = &stream
		}
		at, aerr := deserialize_at(payload, &a, &sc)
		if !testing.expectf(t, aerr == .None, "restoring the view at %v failed with %v", target, aerr) {
			continue
		}
		testing.expect(t, check_set(t, at))
		testing.expect_value(t, card(at), len(want))
		p := part_at_scope(at, a.label, a.owner)
		testing.expect(t, p != nil && p.count == len(want))
		vv, _ := view_open(at, &a, &sc)
		testing.expect_value(t, vv.size, len(want))
		destroy(at)
	}
	free_all(context.temp_allocator)
}

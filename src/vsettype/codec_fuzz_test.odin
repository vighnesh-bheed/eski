package vsettype

import "core:fmt"
import "core:testing"

FUZZ_ROUNDS :: #config(VSET_FUZZ_ROUNDS, 3000)

fuzz_edit :: proc(r: ^Test_Rng, src: []u8, out: ^[dynamic]u8) {
	clear(out)
	append(out, ..src)
	n := len(out)
	switch test_below(r, 7) {
	case 0:
		at := test_below(r, n)
		out[at] ~= u8(1) << uint(test_below(r, 8))
	case 1:
		for _ in 0 ..< 1 + test_below(r, 8) {
			out[test_below(r, n)] = u8(test_next(r))
		}
	case 2:
		specials := []u8{0, 1, 0x7F, 0x80, 0xFD, 0xFE, 0xFF}
		out[test_below(r, n)] = specials[test_below(r, len(specials))]
	case 3:
		at := test_below(r, n)
		inject_at(out, at, u8(test_next(r)))
	case 4:
		at := test_below(r, n)
		ordered_remove(out, at)
	case 5:
		at := test_below(r, n)
		span := 1 + test_below(r, 12)
		for i in at ..< min(len(out), at + span) {
			out[i] = 0xFF
		}
	case 6:
		a := test_below(r, n)
		b := test_below(r, n)
		out[a], out[b] = out[b], out[a]
	}
}

write_back_core :: proc(t: ^testing.T, s: Vset, r: ^Test_Rng, sc: ^Scratch, what: string) {
	g := G_Rng{s = test_next(r)}
	for _ in 0 ..< 24 {
		g_write(s, &g, sc, 64)
	}
	free_all(context.temp_allocator)
	if card(s) == 0 {
		return
	}
	again := g_bytes(s)
	defer delete(again)
	back, err := deserialize(again, sc)
	testing.expectf(t, err == .None, "%s: after an accepted decode and ordinary writes, the set's own payload decodes with %v", what, err)
	if back != nil {
		testing.expect_value(t, card(back), card(s))
		destroy(back)
	}
}

reload_scoped :: proc(t: ^testing.T, s: Vset, what: string) {
	ctx: Save_Context
	parts: [dynamic]Saved_Part
	save_parts(s, &ctx, &parts)
	save_context_destroy(&ctx)
	defer saved_destroy(&parts)
	back, err := load_parts(t, parts[:])
	testing.expectf(t, err == .None, "%s: right after an accepted load, the set's own partitions load with %v", what, err)
	if back != nil {
		destroy(back)
	}
}

write_back_scoped :: proc(t: ^testing.T, w: ^Scoped_World, s: ^Vset, r: ^Test_Rng, sc: ^Scratch, what: string) {
	reload_scoped(t, s^, what)
	world_writes(w, s, r, 40, sc)
	if s^ == nil {
		return
	}
	ctx: Save_Context
	parts: [dynamic]Saved_Part
	save_parts(s^, &ctx, &parts)
	save_context_destroy(&ctx)
	defer saved_destroy(&parts)
	back, err := load_parts(t, parts[:])
	testing.expectf(t, err == .None, "%s: after an accepted load and ordinary writes, the set's own partitions load with %v", what, err)
	if back != nil {
		destroy(back)
	}
}

fuzz_accept_core :: proc(t: ^testing.T, data: []u8, r: ^Test_Rng, sc: ^Scratch, what: string) -> bool {
	live := blocks_live
	s, err := deserialize(data, sc, 3)
	if err != .None {
		testing.expect(t, s == nil)
		testing.expectf(t, blocks_live == live, "%s: a refused decode left %d blocks behind", what, blocks_live - live)
		return false
	}
	testing.expect(t, check_invariants(t, s))
	reencode_decodes(t, s, sc, what)
	x := Search_Request{kind = .Element, element = element_name(s, s.order[0]), count = 5}
	hits: [dynamic]Hit
	search(s, &x, sc, &hits)
	delete(hits)
	write_back_core(t, s, r, sc, what)
	destroy(s)
	return true
}

@(test)
graph_payload_fuzz_never_crashes :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	shapes := []G_Shape{{.BIN, 8, 4, 160, 0}, {.Q8, 5, 6, 140, 0}, {.NOQUANT, 3, 4, 120, 0}, {.Q8, 4, 4, 90, 9}}
	r := Test_Rng{state = 0xF0221}
	buf: [dynamic]u8
	defer delete(buf)
	accepted, rejected := 0, 0
	for shape, si in shapes {
		s := g_build(t, shape, 0x900 + u64(si), &sc)
		craft_holes(s, &sc)
		for form in 0 ..< 4 {
			blob: []u8
			switch form {
			case 0:
				blob = g_bytes(s)
			case 1:
				blob, _ = serialize_v1_bytes(s)
			case 2:
				plain := g_bytes(s)
				c := craft_parse(plain)
				c.node_uid = CODEC_UID_LIMIT - 6
				blob = craft_emit(&c)
				craft_destroy(&c)
				delete(plain)
			case 3:
				plain, _ := serialize_v1_bytes(s)
				blob = v1_rewrite(plain, u64(s.graph.m), CODEC_UID_LIMIT - 6)
				delete(plain)
			}
			names := [4]string{"version 2 core", "version 1", "version 2 core near the counter limit", "version 1 near the counter limit"}
			what := names[form]
			for _ in 0 ..< FUZZ_ROUNDS / 4 {
				fuzz_edit(&r, blob, &buf)
				if fuzz_accept_core(t, buf[:], &r, &sc, what) {
					accepted += 1
				} else {
					rejected += 1
				}
			}
			delete(blob)
		}
		destroy(s)
		free_all(context.temp_allocator)
	}
	testing.expect(t, rejected > accepted && accepted > 0)
}

@(test)
view_payload_fuzz_never_crashes :: proc(t: ^testing.T) {
	w: Scoped_World
	world_init(&w)
	defer world_destroy(&w)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x7F022}
	s: Vset
	world_writes(&w, &s, &r, 700, &sc)
	defer destroy(s)
	reader := owner_access(&w.l, 4, 3)
	v, _ := view_open(s, &reader, &sc)
	payload, ok := view_serialize_bytes(&v)
	testing.expect(t, ok)
	defer delete(payload)
	buf: [dynamic]u8
	defer delete(buf)
	accepted := 0
	for round in 0 ..< FUZZ_ROUNDS / 3 {
		fuzz_edit(&r, payload, &buf)
		if fuzz_accept_core(t, buf[:], &r, &sc, "flat view restored without labels") {
			accepted += 1
		}
		a := owner_access(&w.l, round % w.l.n, Owner(5 * (round % 2)))
		stream: u64
		if a.stream == nil {
			a.stream = &stream
		}
		live := blocks_live
		at, err := deserialize_at(buf[:], &a, &sc)
		if err != .None {
			testing.expectf(t, blocks_live == live, "a refused scoped restore left %d blocks behind", blocks_live - live)
			continue
		}
		testing.expect(t, check_set(t, at))
		x := []f32{0.2, -0.1, 0.4, 0.3}
		for k in 0 ..< 6 {
			labelled_add(at, &a, fmt.tprintf("late%d", k), x, &sc)
		}
		ctx: Save_Context
		parts: [dynamic]Saved_Part
		save_parts(at, &ctx, &parts)
		save_context_destroy(&ctx)
		back, berr := load_parts(t, parts[:])
		testing.expectf(t, berr == .None, "a view restored at a scope and written to saves partitions that load with %v", berr)
		if back != nil {
			destroy(back)
		}
		saved_destroy(&parts)
		destroy(at)
		free_all(context.temp_allocator)
	}
	testing.expect(t, accepted > 0)
}

@(test)
scoped_payload_fuzz_never_crashes :: proc(t: ^testing.T) {
	w: Scoped_World
	world_init(&w)
	defer world_destroy(&w)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x5F022}
	s: Vset
	world_writes(&w, &s, &r, 900, &sc)
	defer destroy(s)
	ctx: Save_Context
	parts: [dynamic]Saved_Part
	save_parts(s, &ctx, &parts)
	save_context_destroy(&ctx)
	defer saved_destroy(&parts)
	buf: [dynamic]u8
	defer delete(buf)
	edited := make([]Saved_Part, len(parts))
	defer delete(edited)
	accepted := 0
	for round in 0 ..< FUZZ_ROUNDS / 3 {
		copy(edited, parts[:])
		at := test_below(&r, len(parts))
		fuzz_edit(&r, parts[at].data, &buf)
		edited[at].data = buf[:]
		live := blocks_live
		back, err := load_parts(t, edited, round % 5 == 0 ? test_below(&r, len(parts)) : -1)
		if err == .None {
			testing.expect(t, back != nil && check_set(t, back))
			if back != nil {
				accepted += 1
				write_back_scoped(t, &w, &back, &r, &sc, "scoped partitions")
				if back != nil {
					destroy(back)
				}
			}
		} else {
			testing.expectf(t, blocks_live == live, "a refused partition load left %d blocks behind", blocks_live - live)
		}
		free_all(context.temp_allocator)
	}
	testing.expect(t, accepted > 0)
}

@(test)
partition_seeds_leave_the_scope_stream_alone :: proc(t: ^testing.T) {
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	x := []f32{0.5, 0.1, -0.2, 0.3}
	shared := owner_access(&l, 1, SHARED)
	mine := owner_access(&l, 1, 4)
	before := [2]u64{shared.stream^, mine.stream^}
	s := new_labelled(t, &shared, 4)
	defer destroy(s)
	labelled_add(s, &shared, "a", x, &sc)
	labelled_add(s, &mine, "b", x, &sc)
	testing.expect(t, shared.stream^ == before[0] && mine.stream^ == before[1], "creating partitions draws nothing from the scope streams")
	p := part_at_scope(s, shared.label, SHARED)
	q := part_at_scope(s, mine.label, mine.owner)
	testing.expect_value(t, part_rng(p), scope_seed(shared.label, SHARED))
	testing.expect_value(t, part_rng(q), scope_seed(mine.label, mine.owner))
	kept := seed_hook
	seed_hook = proc(a: ^Access) -> u64 {
		return 0x1000 + u64(len(a.key)) * 16 + u64(a.owner)
	}
	defer seed_hook = kept
	other := owner_access(&l, 0, 6)
	other.key = bytes_of("abc")
	labelled_add(s, &other, "c", x, &sc)
	testing.expect_value(t, part_rng(part_at_scope(s, other.label, other.owner)), u64(0x1000 + 3 * 16 + 6))
}

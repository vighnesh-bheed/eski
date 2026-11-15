package vsettype

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

reencode_decodes :: proc(t: ^testing.T, s: Vset, sc: ^Scratch, what: string) -> bool {
	again := g_bytes(s)
	defer delete(again)
	back, err := deserialize(again, sc)
	if back != nil {
		testing.expect_value(t, card(back), card(s))
		destroy(back)
	}
	return testing.expectf(t, err == .None, "%s: the set's own payload decodes with %v", what, err)
}

v1_rewrite :: proc(blob: []u8, m: u64, uid: u64) -> []u8 {
	d := Decoder{data = blob, at = 5}
	dim, _ := decoder_varint(&d)
	input, _ := decoder_varint(&d)
	decoder_varint(&d)
	count, _ := decoder_varint(&d)
	decoder_varint(&d)
	b: [dynamic]u8
	append(&b, ..blob[:5])
	cw_var(&b, dim)
	cw_var(&b, input)
	cw_var(&b, m)
	cw_var(&b, count)
	cw_var(&b, uid)
	append(&b, ..blob[d.at:])
	return b[:]
}

v1_counter :: proc(blob: []u8) -> u64 {
	d := Decoder{data = blob, at = 5}
	for _ in 0 ..< 4 {
		decoder_varint(&d)
	}
	uid, _ := decoder_varint(&d)
	return uid
}

v1_second_sequence_copies_first :: proc(blob: []u8, s: Vset) -> []u8 {
	d := Decoder{data = blob, at = 5}
	for _ in 0 ..< 5 {
		decoder_varint(&d)
	}
	ranged := s.arena.elem == .Int8
	spans: [2][2]int
	for i in 0 ..< 2 {
		spans[i][0] = d.at
		decoder_varint(&d)
		spans[i][1] = d.at
		n, _ := decoder_varint(&d)
		decoder_take(&d, int(n))
		decoder_take(&d, s.arena.stride)
		decoder_take(&d, 4)
		if ranged {
			decoder_take(&d, 4)
		}
		code, _ := decoder_varint(&d)
		if code > 0 {
			decoder_take(&d, int(code) - 1)
		}
	}
	b: [dynamic]u8
	append(&b, ..blob[:spans[1][0]])
	append(&b, ..blob[spans[0][0]:spans[0][1]])
	append(&b, ..blob[spans[1][1]:])
	return b[:]
}

refuses_with :: proc(t: ^testing.T, what: string, data: []u8, want: Decode_Error, sc: ^Scratch) {
	live := blocks_live
	back, err := deserialize(data, sc)
	if back != nil {
		destroy(back)
	}
	testing.expectf(t, err == want, "%s: decoded with %v, wanted %v", what, err, want)
	testing.expectf(t, blocks_live == live, "%s: %d blocks of the set's own allocator left behind", what, blocks_live - live)
}

@(test)
node_counter_stays_below_the_limit_in_the_core_codec :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	s := g_build(t, G_Shape{.Q8, 6, 4, 80, 0}, 0xC01, &sc)
	defer destroy(s)
	blob := g_bytes(s)
	defer delete(blob)
	v1, _ := serialize_v1_bytes(s)
	defer delete(v1)
	for v in ([]u64{CODEC_UID_LIMIT, CODEC_UID_LIMIT + 1, max(u64)}) {
		c := craft_parse(blob)
		c.node_uid = v
		data := craft_emit(&c)
		refuses_with(t, fmt.tprintf("version 2 with the counter at %d", v), data, .Bad_Header, &sc)
		delete(data)
		craft_destroy(&c)
		old := v1_rewrite(v1, 4, v)
		refuses_with(t, fmt.tprintf("version 1 with the counter at %d", v), old, .Bad_Header, &sc)
		delete(old)
	}
	free_all(context.temp_allocator)
}

@(test)
node_counter_cannot_be_driven_past_the_limit_by_writes :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	s := g_build(t, G_Shape{.Q8, 6, 4, 80, 0}, 0xC02, &sc)
	defer destroy(s)
	blob := g_bytes(s)
	defer delete(blob)
	v1, _ := serialize_v1_bytes(s)
	defer delete(v1)
	forms := [2][]u8{blob, nil}
	c := craft_parse(blob)
	c.node_uid = CODEC_UID_LIMIT - 3
	forms[0] = craft_emit(&c)
	craft_destroy(&c)
	forms[1] = v1_rewrite(v1, 4, CODEC_UID_LIMIT - 3)
	defer delete(forms[0])
	defer delete(forms[1])
	for data, form in forms {
		what := "version 2" if form == 0 else "version 1"
		back, err := deserialize(data, &sc)
		if !testing.expectf(t, err == .None, "%s: the counter just below the limit is accepted, got %v", what, err) {
			continue
		}
		accepted, refused := 0, 0
		x := make([]f32, 6, context.temp_allocator)
		names: [dynamic]string
		defer delete(names)
		for i in 0 ..< 6 {
			for &v, k in x {
				v = f32((i * 7 + k * 3) % 11) / 10 - 0.5
			}
			name := fmt.aprintf("late%d", i)
			append(&names, name)
			req := Add_Request{name = transmute([]u8)name, vector = x, quant = .Q8, m = 4}
			_, f := add(back, &req, &sc)
			if f.err == .None {
				accepted += 1
			} else {
				testing.expect_value(t, f.err, Error.Out_Of_Memory)
				refused += 1
			}
			existing := element_name(back, back.order[0])
			again := Add_Request{name = existing, vector = x, quant = .Q8, m = 4}
			_, uf := add(back, &again, &sc)
			if uf.err != .None {
				testing.expect_value(t, uf.err, Error.Out_Of_Memory)
			}
			reencode_decodes(t, back, &sc, fmt.tprintf("%s after write %d", what, i))
			testing.expectf(t, part_uid(&back.core) < CODEC_UID_LIMIT, "%s: the counter reached %d", what, part_uid(&back.core))
		}
		testing.expectf(t, accepted > 0 && refused > 0, "%s: %d writes accepted, %d refused", what, accepted, refused)
		for n in names {
			delete(n)
		}
		clear(&names)
		destroy(back)
		free_all(context.temp_allocator)
	}
}

@(test)
node_counter_of_an_owner_block_cannot_pass_the_limit :: proc(t: ^testing.T) {
	w: Scoped_World
	world_init(&w)
	defer world_destroy(&w)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0xB10C}
	s: Vset
	world_writes(&w, &s, &r, 700, &sc)
	defer destroy(s)
	ctx: Save_Context
	parts: [dynamic]Saved_Part
	save_parts(s, &ctx, &parts)
	save_context_destroy(&ctx)
	defer saved_destroy(&parts)
	at := -1
	for p, i in parts {
		c := craft_parse(p.data)
		if p.scope.owner != SHARED && c.mode == 1 && at < 0 {
			at = i
		}
		craft_destroy(&c)
	}
	if !testing.expect(t, at >= 0, "an owner partition in flat form exists") {
		return
	}
	scope := parts[at].scope
	c := craft_parse(parts[at].data)
	c.node_uid = CODEC_UID_LIMIT - 3
	edited := slice.clone(parts[:])
	defer delete(edited)
	edited[at].data = craft_emit(&c)
	defer delete(edited[at].data)
	craft_destroy(&c)
	back, err := load_parts(t, edited)
	if !testing.expect_value(t, err, Decode_Error.None) {
		return
	}
	defer destroy(back)
	p := part_at_scope(back, scope.label, scope.owner)
	testing.expect_value(t, p.kind, Part_Kind.Compact)
	a := owner_access(&w.l, int(scope.label), scope.owner)
	testing.expect_value(t, a.label, scope.label)
	x := []f32{0.2, 0.4, -0.1, 0.3}
	accepted, refused := 0, 0
	for i in 0 ..< 6 {
		_, f := labelled_add(back, &a, fmt.tprintf("late%d", i), x, &sc)
		if f.err == .None {
			accepted += 1
		} else {
			testing.expect_value(t, f.err, Error.Out_Of_Memory)
			refused += 1
		}
		ctx2: Save_Context
		again: [dynamic]Saved_Part
		save_parts(back, &ctx2, &again)
		save_context_destroy(&ctx2)
		reloaded, rerr := load_parts(t, again[:])
		testing.expectf(t, rerr == .None, "after write %d the owner block's partitions load with %v", i, rerr)
		if reloaded != nil {
			destroy(reloaded)
		}
		saved_destroy(&again)
		free_all(context.temp_allocator)
	}
	testing.expectf(t, accepted > 0 && refused > 0, "%d writes accepted, %d refused", accepted, refused)
	testing.expect(t, part_uid(p) < CODEC_UID_LIMIT)
}

@(test)
version_one_reader_is_held_to_the_version_two_rules :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	for shape, si in ([]G_Shape{{.Q8, 6, 4, 60, 0}, {.NOQUANT, 4, 4, 60, 0}, {.BIN, 8, 4, 60, 0}}) {
		s := g_build(t, shape, 0xD00 + u64(si), &sc)
		defer destroy(s)
		v1, _ := serialize_v1_bytes(s)
		defer delete(v1)
		for m in ([]u64{CODEC_M_LIMIT + 1, 5000, 32767}) {
			data := v1_rewrite(v1, m, v1_counter(v1))
			refuses_with(t, fmt.tprintf("%v: M %d", shape.q, m), data, .Bad_Header, &sc)
			delete(data)
		}
		top := v1_rewrite(v1, CODEC_M_LIMIT, v1_counter(v1))
		back, err := deserialize(top, &sc)
		testing.expectf(t, err == .None, "%v: M at the limit is accepted, got %v", shape.q, err)
		if back != nil {
			reencode_decodes(t, back, &sc, fmt.tprintf("%v: M at the limit", shape.q))
			destroy(back)
		}
		delete(top)
		twice := v1_second_sequence_copies_first(v1, s)
		refuses_with(t, fmt.tprintf("%v: a repeated sequence", shape.q), twice, .Bad_Sequence, &sc)
		delete(twice)
		clean, cerr := deserialize(v1, &sc)
		testing.expect_value(t, cerr, Decode_Error.None)
		if clean != nil {
			reencode_decodes(t, clean, &sc, fmt.tprintf("%v: the plain payload", shape.q))
			destroy(clean)
		}
		free_all(context.temp_allocator)
	}
}

@(test)
version_one_fixtures_re_encode_to_version_two :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	for file in GOLDEN_V1 {
		dump := golden_read(t, file)
		defer delete(dump)
		if len(dump) < 20 {
			continue
		}
		_, payload := dump_module_payload(dump)
		back, err := deserialize(payload, &sc, 0x60D)
		if !testing.expectf(t, err == .None, "%s: decodes with %v", file, err) {
			continue
		}
		reencode_decodes(t, back, &sc, file)
		again := g_bytes(back)
		testing.expectf(t, len(again) > 4 && again[3] == CODEC_VERSION, "%s: the set writes a version 2 payload", file)
		delete(again)
		destroy(back)
	}
}

oversized_write :: proc(w: ^Scoped_World, s: ^Vset, a: ^Access, r: ^Test_Rng, from: int, to: int, sc: ^Scratch) {
	x := make([]f32, 4, context.temp_allocator)
	for i in from ..< to {
		random_vector(r, x)
		if s^ == nil {
			req := Add_Request{vector = x}
			s^, _ = create_at(&req, a)
		}
		labelled_add(s^, a, w.names[i], x, sc)
	}
}

@(test)
oversized_partitions_survive_a_save_and_a_load :: proc(t: ^testing.T) {
	w: Scoped_World
	world_init(&w)
	defer world_destroy(&w)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	for owner in ([]Owner{SHARED, 3}) {
		big := owner_access(&w.l, 1, owner)
		small := owner_access(&w.l, 2, owner)
		r := Test_Rng{state = 0x51E + u64(owner)}
		s: Vset
		oversized_write(&w, &s, &big, &r, 0, 40, &sc)
		for i in 0 ..< 24 {
			if i % 3 != 0 {
				remove_at(s, &big, bytes_of(w.names[i]), &sc)
			}
		}
		oversized_write(&w, &s, &small, &r, 40, 60, &sc)
		old := limits_set(12, 30)
		defer limits_restore(old)
		graph_part := part_at_scope(s, big.label, owner)
		flat_part := part_at_scope(s, small.label, owner)
		testing.expect_value(t, graph_part.mode, Part_Mode.Graph)
		testing.expect_value(t, flat_part.mode, Part_Mode.Flat)
		testing.expectf(t, graph_part.count <= shrink_limit && flat_part.count > flat_limit, "owner %d: the partitions are outside the limits: %d graph, %d flat", owner, graph_part.count, flat_part.count)
		ctx: Save_Context
		parts: [dynamic]Saved_Part
		save_parts(s, &ctx, &parts)
		save_context_destroy(&ctx)
		before := strings.clone(world_digest(&w, s, &sc))
		back, err := load_parts(t, parts[:])
		saved_destroy(&parts)
		if !testing.expectf(t, err == .None, "owner %d: the saved partitions load with %v", owner, err) {
			delete(before)
			destroy(s)
			continue
		}
		testing.expect(t, check_set(t, back))
		testing.expect_value(t, part_at_scope(back, big.label, owner).mode, Part_Mode.Graph)
		testing.expect_value(t, part_at_scope(back, small.label, owner).mode, Part_Mode.Flat)
		after := world_digest(&w, back, &sc)
		testing.expectf(t, after == before, "owner %d: a reader's view differs after the reload\n%s", owner, digest_difference(before, after))
		for target in ([]^Vset{&s, &back}) {
			again := r
			remove_at(target^, &big, bytes_of(w.names[0]), &sc)
			oversized_write(&w, target, &small, &again, 60, 61, &sc)
		}
		for target in ([]Vset{s, back}) {
			testing.expect_value(t, part_at_scope(target, big.label, owner).mode, Part_Mode.Flat)
			testing.expect_value(t, part_at_scope(target, small.label, owner).mode, Part_Mode.Graph)
		}
		x := strings.clone(world_digest(&w, s, &sc))
		y := world_digest(&w, back, &sc)
		testing.expectf(t, x == y, "owner %d: views differ after the same next writes\n%s", owner, digest_difference(x, y))
		delete(x)
		ctx2, ctx3: Save_Context
		mine, theirs: [dynamic]Saved_Part
		save_parts(s, &ctx2, &mine)
		save_parts(back, &ctx3, &theirs)
		save_context_destroy(&ctx2)
		save_context_destroy(&ctx3)
		testing.expect_value(t, len(mine), len(theirs))
		for i in 0 ..< min(len(mine), len(theirs)) {
			testing.expectf(t, mine[i].scope == theirs[i].scope && string(mine[i].data) == string(theirs[i].data), "owner %d: partition %v encodes differently after the same next writes", owner, mine[i].scope)
		}
		saved_destroy(&mine)
		saved_destroy(&theirs)
		delete(before)
		destroy(back)
		destroy(s)
		limits_restore(old)
		free_all(context.temp_allocator)
	}
}

@(test)
reserve_formula_survives_larger_costs :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	payloads: [dynamic][]u8
	defer {
		for p in payloads {
			delete(p)
		}
		delete(payloads)
	}
	golden := GOLDEN_CORE
	for g in golden {
		append(&payloads, golden_read(t, g.file))
	}
	for p in GOLDEN_PARTS {
		append(&payloads, golden_read(t, p.file))
	}
	padded := 0
	for shape, si in ([]G_Shape{{.NOQUANT, 128, 16, 40, 0}, {.Q8, 64, 8, 40, 0}, {.BIN, 128, 4, 40, 0}}) {
		s, err := create(Params{quant = shape.q, dim = shape.dim, m = shape.m, seed = 0x77 + u64(si)})
		testing.expect_value(t, err, Error.None)
		x := make([]f32, shape.dim, context.temp_allocator)
		r := Test_Rng{state = 0xA0 + u64(si)}
		for i in 0 ..< 700 {
			random_vector(&r, x)
			name := fmt.tprintf("w%d", i)
			req := Add_Request{name = transmute([]u8)name, vector = x, quant = shape.q, m = shape.m}
			add(s, &req, &sc)
		}
		for i in 0 ..< 690 {
			remove(s, transmute([]u8)fmt.tprintf("w%d", i), &sc)
		}
		blob := g_bytes(s)
		c := craft_parse(blob)
		if len(c.pad) > 0 {
			padded += 1
		}
		craft_destroy(&c)
		append(&payloads, blob)
		destroy(s)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, padded, 3)
	checked := 0
	for data in payloads {
		if len(data) < 6 {
			continue
		}
		d := Decoder{data = data}
		sh: Shape
		if !testing.expect_value(t, shape_read(&d, &sh), Decode_Error.None) {
			continue
		}
		for bump in 0 ..= 24 {
			k := Reserve_Costs{slot = RESERVE_SLOT_BYTES + bump, element = RESERVE_ELEMENT_BYTES + bump, node = RESERVE_NODE_BYTES + bump, pool = RESERVE_POOL_WORDS + bump}
			testing.expectf(t, reserve_admitted_with(&sh, len(data), k), "a payload of %d bytes is refused when every cost is %d larger", len(data), bump)
		}
		checked += 1
	}
	testing.expect(t, checked >= len(payloads) - 1)
}

Dup_World :: struct {
	l: Owner_Lattice,
}

dup_world_init :: proc(w: ^Dup_World) {
	owner_lattice_init(&w.l, {compartments_label(0, 0), compartments_label(0, 1), compartments_label(0, 2)})
}

dup_world_build :: proc(t: ^testing.T, w: ^Dup_World, sc: ^Scratch, holders: int) -> Vset {
	x := []f32{0.3, -0.2, 0.5, 0.1}
	first := owner_access(&w.l, 0, SHARED)
	req := Add_Request{vector = x}
	s, _ := create_at(&req, &first)
	for li in 0 ..< 3 {
		a := owner_access(&w.l, li, SHARED)
		for k in 0 ..< 6 {
			y := []f32{0.1 * f32(k + 1), 0.2, -0.3 * f32(li + 1), 0.4}
			labelled_add(s, &a, fmt.tprintf("only%d_%d", li, k), y, sc)
		}
		if li < holders {
			_, f := labelled_add(s, &a, "dup", x, sc)
			testing.expect_value(t, f.err, Error.None)
		}
	}
	return s
}

load_parts_dropping :: proc(parts: []Saved_Part, drops: []int) -> (s: Vset, err: Decode_Error) {
	ctx: Load_Context
	defer load_context_destroy(&ctx)
	for p, i in parts {
		keep := !slice.contains(drops, i)
		got, fresh, e := load_part(&ctx, p.data, 0, bytes_of("key"), p.scope, keep)
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

dup_parts :: proc(t: ^testing.T, w: ^Dup_World, sc: ^Scratch, holders: int, parts: ^[dynamic]Saved_Part, crafts: ^[dynamic]Craft) {
	s := dup_world_build(t, w, sc, holders)
	defer destroy(s)
	ctx: Save_Context
	save_parts(s, &ctx, parts)
	save_context_destroy(&ctx)
	for p in parts {
		append(crafts, craft_parse(p.data))
	}
}

dup_element :: proc(c: ^Craft) -> ^C_Element {
	for &e in c.elements {
		if string(e.name[:]) == "dup" {
			return &e
		}
	}
	return nil
}

dup_emit :: proc(parts: []Saved_Part, crafts: []Craft) -> []Saved_Part {
	out := slice.clone(parts)
	for &c, i in crafts {
		out[i].data = craft_emit(&c)
	}
	return out
}

dup_free :: proc(edited: []Saved_Part, crafts: ^[dynamic]Craft, parts: ^[dynamic]Saved_Part) {
	for p in edited {
		delete(p.data)
	}
	delete(edited)
	for &c in crafts {
		craft_destroy(&c)
	}
	delete(crafts^)
	saved_destroy(parts)
}

@(test)
copies_that_all_claim_to_be_alone_are_refused :: proc(t: ^testing.T) {
	w: Dup_World
	dup_world_init(&w)
	defer lattice_destroy(&w.l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	parts: [dynamic]Saved_Part
	crafts: [dynamic]Craft
	dup_parts(t, &w, &sc, 2, &parts, &crafts)
	back, err := load_parts_dropping(parts[:], nil)
	testing.expect_value(t, err, Decode_Error.None)
	if back != nil {
		testing.expect_value(t, back.lab.multi_len, 1)
		destroy(back)
	}
	holders := 0
	for &c in crafts {
		if e := dup_element(&c); e != nil {
			testing.expect_value(t, e.copies, u64(2))
			e.copies, e.rank = 1, 0
			holders += 1
		}
	}
	testing.expect_value(t, holders, 2)
	edited := dup_emit(parts[:], crafts[:])
	live := blocks_live
	back, err = load_parts_dropping(edited, nil)
	if back != nil {
		destroy(back)
	}
	testing.expect_value(t, err, Decode_Error.Bad_Rank)
	testing.expectf(t, blocks_live == live, "%d blocks of the set's own allocator left behind", blocks_live - live)
	dup_free(edited, &crafts, &parts)
	free_all(context.temp_allocator)
}

@(test)
copies_that_a_dropped_pair_does_not_account_for_are_refused :: proc(t: ^testing.T) {
	w: Dup_World
	dup_world_init(&w)
	defer lattice_destroy(&w.l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	parts: [dynamic]Saved_Part
	crafts: [dynamic]Craft
	dup_parts(t, &w, &sc, 3, &parts, &crafts)
	holder := make([dynamic]int)
	defer delete(holder)
	for &c, i in crafts {
		if e := dup_element(&c); e != nil {
			testing.expect_value(t, e.copies, u64(3))
			append(&holder, i)
		}
	}
	if !testing.expect_value(t, len(holder), 3) {
		dup_free(nil, &crafts, &parts)
		return
	}
	drops := []int{holder[0], holder[1]}
	back, err := load_parts_dropping(parts[:], drops)
	testing.expect_value(t, err, Decode_Error.None)
	if back != nil {
		destroy(back)
	}
	for k in 0 ..< 3 {
		e := dup_element(&crafts[holder[k]])
		if k < 2 {
			e.copies, e.rank = 2, u64(k)
		} else {
			e.copies, e.rank = 1, 0
		}
	}
	edited := dup_emit(parts[:], crafts[:])
	live := blocks_live
	back, err = load_parts_dropping(edited, drops)
	if back != nil {
		destroy(back)
	}
	testing.expect_value(t, err, Decode_Error.Bad_Rank)
	testing.expectf(t, blocks_live == live, "%d blocks of the set's own allocator left behind", blocks_live - live)
	dup_free(edited, &crafts, &parts)
	free_all(context.temp_allocator)
}

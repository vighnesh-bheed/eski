package vsettype

import "core:fmt"
import "core:testing"
import "../hnsw"

G_Rng :: struct {
	s: u64,
}

g_next :: proc(r: ^G_Rng) -> u64 {
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

g_below :: proc(r: ^G_Rng, n: int) -> int {
	return int(g_next(r) % u64(n))
}

g_vector :: proc(r: ^G_Rng, out: []f32, coarse: bool) {
	for &x in out {
		if coarse {
			x = f32(g_below(r, 3)) - 1
		} else {
			x = f32(i64(g_next(r) % 2001) - 1000) / 1000
		}
	}
}

g_write :: proc(s: Vset, r: ^G_Rng, sc: ^Scratch, names: int) {
	x := make([]f32, s.input_dim if s.input_dim > 0 else s.dim, context.temp_allocator)
	coarse := quant(s) == .BIN
	k := g_below(r, 10)
	switch {
	case k < 5:
		g_vector(r, x, coarse)
		name := fmt.tprintf("n%d", g_below(r, names))
		attr := fmt.tprintf("{{\"g\":%d}}", g_below(r, 3))
		req := Add_Request{name = transmute([]u8)name, vector = x, quant = quant(s), m = s.graph.m, reduce = s.dim if s.input_dim > 0 else 0, attr = transmute([]u8)attr, set_attr = g_below(r, 2) == 0}
		add(s, &req, sc)
	case k < 8:
		if s.count > 1 {
			owned := fmt.tprintf("%s", string(element_name(s, s.order[g_below(r, s.count)])))
			remove(s, transmute([]u8)owned, sc)
		}
	case:
		if s.count > 0 {
			owned := fmt.tprintf("%s", string(element_name(s, s.order[g_below(r, s.count)])))
			set_attribute(s, transmute([]u8)owned, transmute([]u8)fmt.tprintf("{{\"g\":%d}}", g_below(r, 3)))
		}
	}
}

g_hits_equal :: proc(x, y: []Hit) -> bool {
	if len(x) != len(y) {
		return false
	}
	for i in 0 ..< len(x) {
		if transmute(u64)x[i].score != transmute(u64)y[i].score || x[i].seq != y[i].seq || x[i].slot != y[i].slot {
			return false
		}
	}
	return true
}

g_compare :: proc(a, b: Vset, r: ^G_Rng, sc: ^Scratch, rounds: int) -> (differ: int) {
	ha, hb: [dynamic]Hit
	defer delete(ha)
	defer delete(hb)
	x := make([]f32, a.input_dim if a.input_dim > 0 else a.dim)
	defer delete(x)
	coarse := quant(a) == .BIN
	for _ in 0 ..< rounds {
		req := Search_Request{}
		if g_below(r, 4) == 0 && a.count > 0 {
			req.kind = .Element
			req.element = element_name(a, a.order[g_below(r, a.count)])
		} else {
			req.kind = .Vector
			g_vector(r, x, coarse)
			req.vector = x
		}
		counts := [4]int{1, 5, 10, 50}
		efs := [4]int{0, 10, 40, 200}
		req.count = counts[g_below(r, 4)]
		req.ef = efs[g_below(r, 4)]
		req.truth = g_below(r, 6) == 0
		if g_below(r, 3) == 0 {
			req.use_filter = true
			req.filter = ".g == 1"
			fefs := [3]int{0, 5, 30}
			req.filter_ef = fefs[g_below(r, 3)]
		}
		if g_below(r, 5) == 0 {
			req.use_epsilon = true
			req.epsilon = 0.3
		}
		clear(&ha)
		clear(&hb)
		fa := search(a, &req, sc, &ha)
		fb := search(b, &req, sc, &hb)
		if fa.err != fb.err || !g_hits_equal(ha[:], hb[:]) {
			differ += 1
		}
	}
	return
}

g_links_equal :: proc(a, b: Vset) -> bool {
	ga := &a.core.graph
	gb := &b.core.graph
	if ga.slots != gb.slots || ga.entry != gb.entry || ga.max_level != gb.max_level || ga.live != gb.live || ga.twins != gb.twins || ga.rng != gb.rng || ga.node_uid != gb.node_uid || ga.cap != gb.cap {
		return false
	}
	for slot in 0 ..< ga.slots {
		if ga.levels[slot] != gb.levels[slot] {
			return false
		}
		lv := ga.levels[slot]
		if lv == hnsw.LEVEL_TWIN && hnsw.twin_prev(ga, u32(slot)) != hnsw.twin_prev(gb, u32(slot)) {
			return false
		}
		if hnsw.next_twin(ga, u32(slot)) != hnsw.next_twin(gb, u32(slot)) {
			return false
		}
		if int(lv) <= hnsw.LEVEL_CAP {
			for layer in 0 ..= int(lv) {
				la := hnsw.list_get(ga, u32(slot), layer)
				lb := hnsw.list_get(gb, u32(slot), layer)
				if la.count != lb.count {
					return false
				}
				for k in 0 ..< la.count {
					if hnsw.list_id(ga, la, k) != hnsw.list_id(gb, lb, k) {
						return false
					}
				}
			}
		}
	}
	return true
}

g_bytes :: proc(s: Vset) -> []u8 {
	out, _ := serialize_bytes(s)
	return out
}

G_Shape :: struct {
	q:      Quant,
	dim:    int,
	m:      int,
	n:      int,
	reduce: int,
}

G_SHAPES := [?]G_Shape{{.Q8, 16, 16, 900, 0}, {.NOQUANT, 12, 8, 900, 0}, {.BIN, 8, 4, 900, 0}, {.BIN, 16, 16, 700, 0}, {.Q8, 3, 4, 600, 0}, {.NOQUANT, 32, 32, 400, 0}, {.Q8, 6, 6, 500, 12}}

g_build :: proc(t: ^testing.T, shape: G_Shape, seed: u64, sc: ^Scratch) -> Vset {
	input := shape.dim
	if shape.reduce > 0 {
		input = shape.reduce
	}
	s, err := create(Params{quant = shape.q, dim = shape.dim, input_dim = shape.reduce, m = shape.m, seed = seed})
	testing.expect_value(t, err, Error.None)
	_ = input
	r := G_Rng{s = seed ~ 0xA11CE}
	for _ in 0 ..< shape.n * 2 {
		g_write(s, &r, sc, shape.n)
		free_all(context.temp_allocator)
	}
	return s
}

@(test)
graph_payload_reloads_the_same_graph :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	for shape, si in G_SHAPES {
		s := g_build(t, shape, 0x1234 + u64(si), &sc)
		blob := g_bytes(s)
		testing.expect_value(t, len(blob), serialized_size(s))
		back, err := deserialize(blob, &sc)
		if !testing.expectf(t, err == .None, "shape %v: decode failed with %v", shape, err) {
			delete(blob)
			destroy(s)
			continue
		}
		testing.expect(t, s.count > 100 && int(s.arena.high) > s.count, "the set has holes")
		testing.expect(t, check_invariants(t, back))
		cr := G_Rng{s = 0xC0FFEE + u64(si)}
		testing.expectf(t, g_compare(s, back, &cr, &sc, 400) == 0, "shape %v: searches differ after the reload", shape)
		testing.expectf(t, g_links_equal(s, back), "shape %v: links differ after the reload", shape)
		again := g_bytes(back)
		testing.expectf(t, string(again) == string(blob), "shape %v: the reloaded set encodes differently", shape)
		a1 := G_Rng{s = 0xBEEF + u64(si)}
		a2 := a1
		for _ in 0 ..< 300 {
			g_write(s, &a1, &sc, shape.n)
			g_write(back, &a2, &sc, shape.n)
			free_all(context.temp_allocator)
		}
		cr2 := G_Rng{s = 0xD00D + u64(si)}
		testing.expectf(t, g_compare(s, back, &cr2, &sc, 400) == 0, "shape %v: searches differ after further writes", shape)
		testing.expectf(t, g_links_equal(s, back), "shape %v: links differ after further writes", shape)
		x := g_bytes(s)
		y := g_bytes(back)
		testing.expectf(t, string(x) == string(y), "shape %v: states differ after further writes", shape)
		delete(x)
		delete(y)
		delete(again)
		delete(blob)
		destroy(back)
		destroy(s)
	}
}

@(test)
version_one_payloads_still_rebuild :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	s := g_build(t, G_SHAPES[0], 77, &sc)
	defer destroy(s)
	blob, _ := serialize_v1_bytes(s)
	defer delete(blob)
	back, err := deserialize(blob, &sc, 0x5EED)
	testing.expect_value(t, err, Decode_Error.None)
	if back != nil {
		testing.expect_value(t, back.count, s.count)
		testing.expect(t, check_invariants(t, back))
		testing.expect_value(t, back.graph.rng != 0, true)
		destroy(back)
	}
}

g_add_name :: proc(s: Vset, name: string, r: ^G_Rng, sc: ^Scratch) {
	x: [2]f32
	g_vector(r, x[:], false)
	req := Add_Request{name = transmute([]u8)name, vector = x[:], quant = .Q8, m = 4, ef = 1}
	add(s, &req, sc)
}

g_wide_check :: proc(t: ^testing.T, s: Vset, width: int, sc: ^Scratch) {
	blob := g_bytes(s)
	defer delete(blob)
	c := craft_parse(blob)
	testing.expectf(t, c.width == width, "%d slots are written with %d byte ids, wanted %d", int(c.slot_high), c.width, width)
	craft_destroy(&c)
	back, err := deserialize(blob, sc)
	if !testing.expectf(t, err == .None, "a graph of %d slots decodes, got %v", int(s.arena.high), err) {
		return
	}
	defer destroy(back)
	testing.expect(t, g_links_equal(s, back))
	again := g_bytes(back)
	testing.expect(t, string(again) == string(blob))
	delete(again)
	cr := G_Rng{s = 0x77}
	testing.expect_value(t, g_compare(s, back, &cr, sc, 40), 0)
	a := G_Rng{s = 0x99}
	b := a
	for i in 0 ..< 40 {
		g_add_name(s, fmt.tprintf("late%d", i), &a, sc)
		g_add_name(back, fmt.tprintf("late%d", i), &b, sc)
	}
	free_all(context.temp_allocator)
	testing.expect(t, g_links_equal(s, back), "further writes after the reload build the same graph")
}

g_wide_set :: proc(t: ^testing.T, n: int, sc: ^Scratch) -> Vset {
	s, _ := create(Params{quant = .Q8, dim = 2, m = 4, seed = 0xABC})
	r := G_Rng{s = 0x31}
	for i in 0 ..< n {
		g_add_name(s, fmt.tprintf("w%d", i), &r, sc)
		if i & 1023 == 0 {
			free_all(context.temp_allocator)
		}
	}
	free_all(context.temp_allocator)
	testing.expect_value(t, int(s.arena.high), n)
	return s
}

@(test)
graph_payload_link_width_boundaries :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	narrow := g_wide_set(t, 65_535, &sc)
	defer destroy(narrow)
	g_wide_check(t, narrow, 2, &sc)
	wide := g_wide_set(t, 65_536, &sc)
	defer destroy(wide)
	for name in ([]string{"w65535", "w100", "w65534"}) {
		remove(wide, transmute([]u8)name, &sc)
	}
	testing.expect_value(t, int(wide.arena.high), 65_536)
	testing.expect_value(t, wide.arena.free, u32(65_534))
	g_wide_check(t, wide, 3, &sc)
}

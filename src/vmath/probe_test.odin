package vmath

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"

Probe_Op :: enum u8 {
	Raw,
	Emb,
	Sim,
	Ele,
	Links,
	Rem,
}

Probe_Input :: struct {
	name:   string,
	seed:   u64,
	text:   []string,
	bits:   []u32,
	negate: bool,
	dim:    int,
}

Probe_Set :: struct {
	name:      string,
	port:      int,
	elem:      Elem,
	input_dim: int,
	reduce:    int,
	m:         int,
	inputs:    []Probe_Input,
}

Probe_Case :: struct {
	id:      int,
	section: string,
	set:     int,
	op:      Probe_Op,
	target:  string,
	query:   Probe_Input,
	leaves:  []string,
}

Probe_Built :: struct {
	arena:      Arena,
	projection: Projection,
	ready:      bool,
}

probe_vector :: proc(seed: u64, dim: int) -> []f32 {
	r: Rng
	rng_seed(&r, seed)
	out := make([]f32, dim, context.temp_allocator)
	for &v in out {
		v = f32(i64(rng_next(&r) >> 40) - (1 << 23)) / (1 << 23)
	}
	return out
}

probe_values :: proc(inp: Probe_Input, dim: int) -> []f32 {
	out: []f32
	if len(inp.text) > 0 {
		out = make([]f32, len(inp.text), context.temp_allocator)
		for s, i in inp.text {
			v, ok := strconv.parse_f64(s)
			assert(ok)
			out[i] = f32(v)
		}
	} else if len(inp.bits) > 0 {
		out = make([]f32, len(inp.bits), context.temp_allocator)
		for b, i in inp.bits {
			out[i] = transmute(f32)b
		}
	} else {
		out = probe_vector(inp.seed, dim)
	}
	if inp.negate {
		for &v in out {
			v = -v
		}
	}
	return out
}

probe_build :: proc(t: ^testing.T, s: Probe_Set, b: ^Probe_Built) {
	if b.ready {
		return
	}
	dim := s.reduce if s.reduce > 0 else s.input_dim
	testing.expect_value(t, arena_init(&b.arena, s.elem, .Cosine, dim), nil)
	if s.reduce > 0 {
		testing.expect_value(t, projection_init(&b.projection, s.input_dim, s.reduce), nil)
	}
	for inp in s.inputs {
		x := probe_values(inp, s.input_dim)
		if s.reduce > 0 {
			y := make([]f32, s.reduce, context.temp_allocator)
			projection_project(&b.projection, x, y)
			x = y
		}
		_, err := arena_insert(&b.arena, x)
		testing.expect_value(t, err, nil)
	}
	b.ready = true
}

probe_slot :: proc(s: Probe_Set, name: string) -> u32 {
	for inp, i in s.inputs {
		if inp.name == name {
			return u32(i)
		}
	}
	return NIL_SLOT
}

fnv1a64 :: proc(b: []u8) -> u64 {
	h := u64(0xcbf29ce484222325)
	for c in b {
		h ~= u64(c)
		h *= 0x100000001b3
	}
	return h
}

probe_bytes_match :: proc(ours: []u8, leaf: string) -> bool {
	if len(leaf) > 0 && leaf[0] == '#' {
		return leaf == fmt.tprintf("#%016x:%d", fnv1a64(ours), len(ours))
	}
	return string(ours) == leaf
}

probe_number :: proc(t: ^testing.T, leaf: string) -> f64 {
	v, ok := strconv.parse_f64(leaf)
	testing.expectf(t, ok, "reply number %q does not parse", leaf)
	return v
}

probe_same :: proc(a: f64, b: f64) -> bool {
	if math.is_nan(a) && math.is_nan(b) {
		return true
	}
	return transmute(u64)a == transmute(u64)b
}

probe_check :: proc(t: ^testing.T, c: Probe_Case, s: Probe_Set, b: ^Probe_Built) -> bool {
	a := &b.arena
	lv := c.leaves
	switch c.op {
	case .Rem:
		return len(lv) == 1 && lv[0] == "1" && probe_slot(s, c.target) != NIL_SLOT
	case .Raw:
		slot := probe_slot(s, c.target)
		want := 4 if s.elem == .Int8 else 3
		if len(lv) != want || lv[0] != elem_name(s.elem) || !probe_bytes_match(arena_bytes(a, slot), lv[1]) {
			return false
		}
		if !probe_same(f64(arena_norm(a, slot)), probe_number(t, lv[2])) {
			return false
		}
		return s.elem != .Int8 || probe_same(f64(arena_range(a, slot)), probe_number(t, lv[3]))
	case .Emb:
		out := make([]f32, a.dim, context.temp_allocator)
		arena_decode(a, probe_slot(s, c.target), out)
		if len(lv) != len(out) {
			return false
		}
		for v, i in out {
			if !probe_same(f64(v), probe_number(t, lv[i])) {
				return false
			}
		}
		return true
	case .Sim, .Ele, .Links:
		q: Query
		ok := true
		buf, _ := query_alloc(a, context.temp_allocator)
		switch c.op {
		case .Sim:
			qdim := c.query.dim
			if len(c.query.text) > 0 {
				qdim = len(c.query.text)
			} else if len(c.query.bits) > 0 {
				qdim = len(c.query.bits)
			}
			x := probe_values(c.query, qdim)
			if s.reduce > 0 && qdim == s.input_dim {
				y := make([]f32, s.reduce, context.temp_allocator)
				projection_project(&b.projection, x, y)
				x = y
			}
			q, ok = query_encode(a, x, buf)
		case .Ele:
			scratch := make([]f32, a.dim, context.temp_allocator)
			q, ok = query_rebuild(a, probe_slot(s, c.target), scratch, buf)
		case .Raw, .Emb, .Links, .Rem:
			q = query_slot(a, probe_slot(s, c.target))
		}
		if !ok || len(lv) % 2 != 0 {
			return false
		}
		for i := 0; i + 1 < len(lv); i += 2 {
			slot := probe_slot(s, lv[i])
			if slot == NIL_SLOT {
				return false
			}
			score := arena_query_score(a, q, slot)
			if c.op == .Links {
				score = f64(edge_score(score))
			}
			if !probe_same(score, probe_number(t, lv[i + 1])) {
				return false
			}
		}
		return true
	}
	return false
}

probe_run :: proc(t: ^testing.T, section: string) -> (cases: int) {
	return probe_run_table(t, PROBE_SETS[:], PROBE_CASES[:], section)
}

probe_run_table :: proc(t: ^testing.T, sets: []Probe_Set, table: []Probe_Case, section: string) -> (cases: int) {
	built := make([]Probe_Built, len(sets), context.temp_allocator)
	for c in table {
		if c.section != section {
			continue
		}
		s := sets[c.set]
		probe_build(t, s, &built[c.set])
		testing.expectf(t, probe_check(t, c, s, &built[c.set]), "probe case %d (%s %v %s on %s) differs from the reference", c.id, c.section, c.op, c.target, s.name)
		cases += 1
	}
	for &b in built {
		if b.ready {
			arena_destroy(&b.arena)
			projection_destroy(&b.projection)
		}
	}
	return
}

@(test)
probe_table_is_complete :: proc(t: ^testing.T) {
	testing.expect_value(t, len(PROBE_CASES), PROBE_CASE_COUNT)
	testing.expect(t, strings.has_prefix(PROBE_DIGEST, "sha256:f245f4c8"))
	testing.expect_value(t, PROBE_CAPTURED_ON, "2026-11-06")
	testing.expect_value(t, PROBE_IMAGE, "docker.io/library/redis:8")
	sections := []string{"accumulation", "parse", "ties", "binary", "clamp", "degenerate", "int8", "reduce_identity", "reduce_basis", "reduce_scale", "reduce_general", "links", "links_repair"}
	total := 0
	for c in PROBE_CASES {
		for s in sections {
			if c.section == s {
				total += 1
			}
		}
	}
	testing.expect_value(t, total, PROBE_CASE_COUNT)
}

@(test)
probe_accumulation :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_run(t, "accumulation"), 397)
}

@(test)
probe_parse :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_run(t, "parse"), 72)
}

@(test)
probe_ties :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_run(t, "ties"), 48)
}

@(test)
probe_binary :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_run(t, "binary"), 45)
}

@(test)
probe_clamp :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_run(t, "clamp"), 112)
}

@(test)
probe_degenerate :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_run(t, "degenerate"), 36)
}

@(test)
probe_int8 :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_run(t, "int8"), 150)
}

@(test)
probe_reduce :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_run(t, "reduce_identity"), 24)
	testing.expect_value(t, probe_run(t, "reduce_basis"), 104)
	testing.expect_value(t, probe_run(t, "reduce_scale"), 8)
	testing.expect_value(t, probe_run(t, "reduce_general"), 154)
}

@(test)
probe_links :: proc(t: ^testing.T) {
	testing.expect_value(t, probe_run(t, "links"), 672)
	testing.expect_value(t, probe_run(t, "links_repair"), 60)
}

@(test)
probe_edge_inputs :: proc(t: ^testing.T) {
	testing.expect_value(t, len(PROBE_EDGE_CASES), PROBE_EDGE_CASE_COUNT)
	testing.expect_value(t, PROBE_EDGE_DIGEST, PROBE_DIGEST)
	testing.expect_value(t, PROBE_EDGE_CAPTURED_ON, "2026-11-06")
	testing.expect_value(t, probe_run_table(t, PROBE_EDGE_SETS[:], PROBE_EDGE_CASES[:], "subnormal"), 138)
	testing.expect_value(t, probe_run_table(t, PROBE_EDGE_SETS[:], PROBE_EDGE_CASES[:], "nan_inputs"), 48)
}

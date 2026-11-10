package vsettype

import "core:testing"
import "../hnsw"
import "../rax"
import "../vmath"

bytes_of :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

Test_Rng :: struct {
	state: u64,
}

test_next :: proc(r: ^Test_Rng) -> u64 {
	r.state += GOLDEN_GAMMA
	return mix64(r.state)
}

test_below :: proc(r: ^Test_Rng, n: int) -> int {
	return int(test_next(r) % u64(max(n, 1)))
}

test_unit :: proc(r: ^Test_Rng) -> f32 {
	return f32(f64(test_next(r) >> 11) * (1.0 / 9007199254740992.0)) * 2 - 1
}

random_vector :: proc(r: ^Test_Rng, out: []f32) {
	for &v in out {
		v = test_unit(r)
	}
}

add_values :: proc(t: ^testing.T, s: Vset, name: string, values: []f32, quant := Quant.Q8, attr := "", set_attr := false, sc: ^Scratch = nil, m := 0, reduce := 0) -> bool {
	req := Add_Request{name = bytes_of(name), vector = values, quant = quant, attr = bytes_of(attr), set_attr = set_attr, m = m, reduce = reduce}
	added, f := add(s, &req, sc)
	testing.expectf(t, f.err == .None, "add %s failed with %v", name, f.err)
	return added
}

new_set :: proc(t: ^testing.T, dim: int, quant := Quant.Q8, m := 0, reduce := 0, seed: u64 = 0) -> Vset {
	p := Params{quant = quant, dim = reduce if reduce > 0 else dim, input_dim = dim if reduce > 0 else 0, m = m if m > 0 else M_DEFAULT, seed = seed}
	s, err := create(p)
	testing.expect_value(t, err, Error.None)
	return s
}

name_text :: proc(s: Vset, slot: u32) -> string {
	return string(element_name(s, slot))
}

check_invariants :: proc(t: ^testing.T, s: Vset) -> bool {
	ok := true
	if int(s.names.stored) != s.count {
		testing.expectf(t, false, "rax holds %d names, set holds %d", s.names.stored, s.count)
		ok = false
	}
	if hnsw.size(&s.graph) != s.count || int(s.arena.live) != s.count {
		testing.expectf(t, false, "graph %d arena %d count %d", hnsw.size(&s.graph), s.arena.live, s.count)
		ok = false
	}
	if int(s.arena.high) != s.graph.slots {
		testing.expectf(t, false, "arena high %d graph slots %d", s.arena.high, s.graph.slots)
		ok = false
	}
	a := s.arena.free
	g := s.graph.free_head
	for a != vmath.NIL_SLOT || g != hnsw.NONE {
		if a != g {
			testing.expectf(t, false, "free lists diverge at %d against %d", a, g)
			return false
		}
		a = vmath.free_next(s.arena.norms[a])
		next := hnsw.word_get(s.graph.links0[int(g) * s.graph.row:], 0, s.graph.width)
		g = hnsw.NONE if next == hnsw.width_none(s.graph.width) else next
	}
	attrs := 0
	for i in 0 ..< s.count {
		slot := s.order[i]
		e := &s.elements[slot]
		if int(e.pos) != i {
			testing.expectf(t, false, "slot %d records position %d at %d", slot, e.pos, i)
			ok = false
		}
		if !vmath.arena_is_live(&s.arena, slot) || !hnsw.is_live(&s.graph, slot) {
			testing.expectf(t, false, "slot %d is not live", slot)
			ok = false
		}
		v, found := rax.find(s.names, e.name[:e.len])
		if !found || u32(uintptr(v) - 1) != slot {
			testing.expectf(t, false, "name of slot %d does not map back", slot)
			ok = false
		}
		if e.attr.blob != nil {
			attrs += 1
		}
	}
	if attrs != int(s.attributes) {
		testing.expectf(t, false, "attributes %d counted %d", s.attributes, attrs)
		ok = false
	}
	if ledger_balance(s) != 0 {
		testing.expectf(t, false, "ledger is off by %d bytes", ledger_balance(s))
		ok = false
	}
	return ok
}

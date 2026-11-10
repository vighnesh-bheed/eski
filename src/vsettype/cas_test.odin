package vsettype

import "core:fmt"
import "core:testing"

same_graph :: proc(t: ^testing.T, a: Vset, b: Vset) -> bool {
	if !testing.expect_value(t, card(b), card(a)) {
		return false
	}
	la, lb: [dynamic]u32
	defer delete(la)
	defer delete(lb)
	it := element_iterator(a)
	for slot in next_element(&it) {
		other, ok := find(b, element_name(a, slot))
		if !testing.expect(t, ok && other == slot) {
			return false
		}
		if !testing.expect_value(t, link_layers(b, other), link_layers(a, slot)) {
			return false
		}
		for i in 0 ..< link_layers(a, slot) {
			x := layer_links(a, slot, i, &la)
			y := layer_links(b, other, i, &lb)
			if !testing.expect_value(t, len(y), len(x)) {
				return false
			}
			for v, j in x {
				if !testing.expect_value(t, y[j], v) {
					return false
				}
			}
		}
	}
	return true
}

@(test)
cas_builds_the_same_graph_as_a_plain_insert :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	for quant in Quant {
		plain := new_set(t, 12, quant, 8, 0, 0xCA5)
		cased := new_set(t, 12, quant, 8, 0, 0xCA5)
		r := Test_Rng{state = 0xCA5 + u64(quant)}
		x := make([]f32, 12)
		hits, misses := 0, 0
		for i in 0 ..< 400 {
			random_vector(&r, x)
			name := fmt.tprintf("e%d", test_below(&r, 300))
			req := Add_Request{name = bytes_of(name), vector = x, quant = quant, m = 8}
			pa, pf := add(plain, &req, &sc)
			testing.expect_value(t, pf.err, Error.None)
			plan: Cas_Plan
			testing.expect_value(t, cas_prepare(cased, &req, &plan, &sc).err, Error.None)
			before_hits, before_misses := plan.cache.hits, plan.cache.misses
			ca, cf := cas_commit(cased, &plan, &sc)
			hits += plan.cache.hits - before_hits
			misses += plan.cache.misses - before_misses
			cas_discard(&plan)
			testing.expect_value(t, cf.err, Error.None)
			testing.expect_value(t, ca, pa)
			if i % 50 == 49 {
				remove(plain, bytes_of(fmt.tprintf("e%d", i % 300)), &sc)
				remove(cased, bytes_of(fmt.tprintf("e%d", i % 300)), &sc)
			}
			free_all(context.temp_allocator)
		}
		same_graph(t, plain, cased)
		testing.expect_value(t, info(cased).max_node_uid, info(plain).max_node_uid)
		testing.expect_value(t, info(cased).max_level, info(plain).max_level)
		testing.expectf(t, hits > 4 * misses, "%v: cache hits %d misses %d", quant, hits, misses)
		check_invariants(t, cased)
		delete(x)
		destroy(plain)
		destroy(cased)
	}
}

@(test)
cas_commit_revalidates_after_intervening_writes :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0xBEEF}
	s := build_random_set(t, &r, 120, 6, .Q8, &sc)
	defer destroy(s)
	x := []f32{0.3, -0.1, 0.5, 0.2, 0.9, -0.4}
	req := Add_Request{name = bytes_of("fresh"), vector = x}
	plan: Cas_Plan
	testing.expect_value(t, cas_prepare(s, &req, &plan, &sc).err, Error.None)
	for i in 0 ..< 30 {
		remove(s, bytes_of(fmt.tprintf("e%d", i)), &sc)
	}
	y := make([]f32, 6)
	defer delete(y)
	for i in 0 ..< 30 {
		random_vector(&r, y)
		req2 := Add_Request{name = bytes_of(fmt.tprintf("n%d", i)), vector = y}
		add(s, &req2, &sc)
	}
	before_misses := plan.cache.misses
	added, f := cas_commit(s, &plan, &sc)
	testing.expect(t, added && f.err == .None)
	testing.expect(t, plan.cache.misses > before_misses)
	testing.expect_value(t, plan.cache.hits, 0)
	cas_discard(&plan)
	check_invariants(t, s)
	update := Add_Request{name = bytes_of("fresh"), vector = y, set_attr = true, attr = bytes_of(`{"u":1}`)}
	testing.expect_value(t, cas_prepare(s, &update, &plan, &sc).err, Error.None)
	added, f = cas_commit(s, &plan, &sc)
	testing.expect(t, !added && f.err == .None)
	cas_discard(&plan)
	text, has := get_attribute(s, bytes_of("fresh"))
	testing.expect(t, has && text == `{"u":1}`)
	slot, _ := find(s, bytes_of("fresh"))
	want := make([]u8, 6)
	defer delete(want)
	got := raw_embedding(s, slot)
	other := new_set(t, 6)
	defer destroy(other)
	add_values(t, other, "fresh", y)
	oslot, _ := find(other, bytes_of("fresh"))
	testing.expect_value(t, string(got.data), string(raw_embedding(other, oslot).data))
	check_invariants(t, s)
	bad := Add_Request{name = bytes_of("q"), vector = y, quant = .BIN}
	testing.expect_value(t, cas_prepare(s, &bad, &plan, &sc).err, Error.Quantization_Mismatch)
	cas_discard(&plan)
}

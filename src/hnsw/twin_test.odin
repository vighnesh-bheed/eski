package hnsw

import "core:testing"

same_vector :: proc(p: ^Points, a, b: u32) -> bool {
	va := points_get(p, a)
	vb := points_get(p, b)
	for x, i in va {
		if transmute(u32)x != transmute(u32)vb[i] {
			return false
		}
	}
	return true
}

expect_twin_heads_match :: proc(t: ^testing.T, ix: ^Index, p: ^Points) {
	for i in 0 ..< ix.slots {
		slot := u32(i)
		if is_twin(ix, slot) {
			head := twin_head(ix, slot)
			testing.expectf(t, is_node(ix, head) && same_vector(p, slot, head), "twin %d hangs off graph node %d holding the same vector", slot, head)
		}
	}
}

copies_of :: proc(ix: ^Index, p: ^Points, v: []f32, out: ^[dynamic]u32) {
	clear(out)
	for i in 0 ..< ix.slots {
		slot := u32(i)
		if !is_live(ix, slot) {
			continue
		}
		w := points_get(p, slot)
		same := true
		for x, j in w {
			if transmute(u32)x != transmute(u32)v[j] {
				same = false
				break
			}
		}
		if same {
			append(out, slot)
		}
	}
}

holds_all :: proc(found: []Candidate, want: []u32) -> bool {
	for w in want {
		hit := false
		for c in found {
			if c.id == w {
				hit = true
				break
			}
		}
		if !hit {
			return false
		}
	}
	return true
}

sorted_without_repeats :: proc(found: []Candidate) -> bool {
	for i in 1 ..< len(found) {
		if !closer(found[i - 1], found[i]) {
			return false
		}
	}
	return true
}

expect_copies_found :: proc(t: ^testing.T, ix: ^Index, s: ^Scratch, p: ^Points, v: []f32, what: string) {
	copies := make([dynamic]u32)
	defer delete(copies)
	copies_of(ix, p, v, &copies)
	out := make([]Candidate, len(copies) + 10)
	defer delete(out)
	pq := Point_Query{p, v}
	n, err := search(ix, s, point_query_distance, &pq, len(out), 60, out)
	testing.expect_value(t, err, Error.None)
	testing.expectf(t, n == min(len(out), ix.live), "%s: %d results for %d live", what, n, ix.live)
	testing.expectf(t, holds_all(out[:len(copies)], copies[:]), "%s: the %d copies of the query vector come first", what, len(copies))
	testing.expect(t, sorted_without_repeats(out[:n]), "results are sorted by distance and id without repeats")
}

@(test)
twins_follow_their_head_through_searches_and_deletes :: proc(t: ^testing.T) {
	dim :: 8
	p: Points
	points_init(&p, dim, true, 400)
	defer points_destroy(&p)
	params := test_params(4, 40, 0x7A1)
	params.promotion = 1e-12
	testing.expect(t, params_default().twins, "copies beyond the coincident limit become twins by default")
	ix: Index
	testing.expect_value(t, init(&ix, params, points_distance, &p, context.allocator), Error.None)
	defer destroy(&ix)
	testing.expect_value(t, ix.coincident, 2)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	state := u64(0x7A1)
	a := make([]f32, dim)
	defer delete(a)
	b := make([]f32, dim)
	defer delete(b)
	v := make([]f32, dim)
	defer delete(v)
	random_unit(&state, a)
	random_unit(&state, b)
	first := add_point(t, &ix, &s, &p, a)
	for i in 0 ..< 200 {
		random_unit(&state, v)
		add_point(t, &ix, &s, &p, v)
		if i % 10 == 0 {
			add_point(t, &ix, &s, &p, b)
		}
		if i % 7 == 0 {
			add_point(t, &ix, &s, &p, a)
		}
	}
	testing.expect_value(t, ix.entry, first)
	testing.expect_value(t, ix.live, 250)
	check_graph(t, &ix)
	expect_reachable(t, &ix, "after the build")
	expect_twin_heads_match(t, &ix, &p)
	copies := make([dynamic]u32)
	defer delete(copies)
	copies_of(&ix, &p, a, &copies)
	testing.expect_value(t, len(copies), 30)
	in_graph := 0
	for c in copies {
		if is_node(&ix, c) {
			in_graph += 1
		} else {
			testing.expect_value(t, twin_head(&ix, c), first)
			testing.expect_value(t, node_level(&ix, c), 0)
			testing.expect_value(t, len(layer_links(&ix, c, 0, make([]u32, 8, context.temp_allocator))), 0)
		}
	}
	testing.expect_value(t, in_graph, 2)
	testing.expect_value(t, ix.twins, 28 + 18)
	testing.expect_value(t, info(&ix).twins, ix.twins)
	testing.expect_value(t, twin_head(&ix, first), NONE)
	testing.expect(t, is_twin(&ix, next_twin(&ix, first)), "the first copy holds the list of its twins")
	expect_copies_found(t, &ix, &s, &p, a, "plain search")
	pq := Point_Query{&p, a}
	out := make([]Candidate, 40)
	defer delete(out)
	n, _ := search(&ix, &s, point_query_distance, &pq, 10, 10, out)
	testing.expect_value(t, n, 10)
	for c in out[:n] {
		testing.expect(t, same_vector(&p, c.id, first), "a narrow search returns only copies of the query vector")
	}
	accepted := make([dynamic]u32)
	defer delete(accepted)
	for c in copies {
		if mix_slot(c) % 2 == 0 {
			append(&accepted, c)
		}
	}
	half := Accept_Mod{modulus = 2}
	nf, inspected, ferr := search_filtered(&ix, &s, point_query_distance, &pq, 40, 60, accept_mod, &half, 0, out)
	testing.expect_value(t, ferr, Error.None)
	testing.expect_value(t, inspected, half.calls)
	testing.expect(t, holds_all(out[:nf], accepted[:]), "filtered search finds every accepted copy, twins included")
	for c in out[:nf] {
		testing.expect(t, mix_slot(c.id) % 2 == 0, "filtered search returns only accepted nodes")
	}
	testing.expect(t, sorted_without_repeats(out[:nf]), "filtered results are sorted without repeats")
	for budget in ([]int{1, 3, 7, 20}) {
		tight := Accept_Mod{modulus = 2}
		_, used, _ := search_filtered(&ix, &s, point_query_distance, &pq, 10, 60, accept_mod, &tight, budget, out)
		testing.expectf(t, used <= budget && used == tight.calls, "budget %d bounds the filter calls (%d)", budget, used)
	}
	found := make([dynamic]Candidate)
	defer delete(found)
	exact := make([dynamic]Candidate)
	defer delete(exact)
	radius := max(out[0].dist, 0) + 1e-4
	nr, rerr := search_range(&ix, &s, point_query_distance, &pq, range_default(radius), 20, &found)
	testing.expect_value(t, rerr, Error.None)
	brute_force_range(&ix, &s, point_query_distance, &pq, range_default(radius), &exact)
	testing.expect_value(t, len(exact), 30)
	testing.expect_value(t, nr, 30)
	testing.expect(t, slices_equal(found[:], exact[:]), "radius search returns every copy, twins included")
	before := make([]Candidate, 40)
	defer delete(before)
	nb, _ := search(&ix, &s, point_query_distance, &pq, 40, 60, before)
	testing.expect_value(t, reencode(&ix, ix.cap, 4), Error.None)
	check_graph(t, &ix)
	nw, _ := search(&ix, &s, point_query_distance, &pq, 40, 60, out)
	testing.expect(t, nb == nw && slices_equal(before[:nb], out[:nw]), "wider ids keep twins and results")
	expect_twin_heads_match(t, &ix, &p)
	testing.expect_value(t, remove(&ix, &s, first), Error.None)
	testing.expect(t, ix.entry != first && is_node(&ix, ix.entry) && same_vector(&p, ix.entry, first), "the entry passes to a former twin")
	testing.expect_value(t, remove(&ix, &s, first), Error.Not_Found)
	check_graph(t, &ix)
	expect_reachable(t, &ix, "after removing the entry")
	expect_twin_heads_match(t, &ix, &p)
	expect_copies_found(t, &ix, &s, &p, a, "after removing the entry")
	copies_of(&ix, &p, a, &copies)
	for len(copies) > 0 {
		at := int(rng_next(&state) % u64(len(copies)))
		victim := copies[at]
		was_twin := is_twin(&ix, victim)
		testing.expect_value(t, remove(&ix, &s, victim), Error.None)
		testing.expect_value(t, insert(&ix, &s, victim), Error.Not_Reserved)
		if was_twin {
			testing.expect_value(t, remove(&ix, &s, victim), Error.Not_Found)
		}
		copies_of(&ix, &p, a, &copies)
		check_graph(t, &ix)
		expect_reachable(t, &ix, "while removing copies")
		expect_twin_heads_match(t, &ix, &p)
		if len(copies) > 0 {
			expect_copies_found(t, &ix, &s, &p, a, "while removing copies")
		}
	}
	testing.expect_value(t, ix.twins, 18)
	for _ in 0 ..< 5 {
		add_point(t, &ix, &s, &p, a)
	}
	copies_of(&ix, &p, a, &copies)
	in_graph = 0
	for c in copies {
		if is_node(&ix, c) {
			in_graph += 1
		}
	}
	testing.expect_value(t, in_graph, 2)
	testing.expect_value(t, ix.twins, 18 + 3)
	check_graph(t, &ix)
	expect_copies_found(t, &ix, &s, &p, a, "after adding copies again")
	expect_copies_found(t, &ix, &s, &p, b, "copies of the second vector")
	free_all(context.temp_allocator)
}

@(test)
zero_vectors_never_hang_off_a_different_vector :: proc(t: ^testing.T) {
	dim :: 8
	c: Churn
	churn_init(t, &c, dim, test_params(4, 40, 0x2E20), 400)
	defer churn_destroy(&c)
	state := u64(0x2E20)
	v := make([]f32, dim)
	defer delete(v)
	zero := make([]f32, dim)
	defer delete(zero)
	for i in 0 ..< 300 {
		random_unit(&state, v)
		churn_insert(t, &c, v)
		if i % 3 == 0 {
			churn_insert(t, &c, zero)
		}
		if i % 50 == 49 {
			churn_delete(t, &c, int(rng_next(&state) % u64(len(c.live))))
		}
	}
	check_graph(t, &c.ix)
	expect_reachable(t, &c.ix, "zero vectors")
	expect_twin_heads_match(t, &c.ix, &c.p)
}

@(test)
twins_can_be_turned_off :: proc(t: ^testing.T) {
	dim :: 8
	params := test_params(4, 40, 0x0FF)
	params.twins = false
	c: Churn
	churn_init(t, &c, dim, params, 400)
	defer churn_destroy(&c)
	testing.expect_value(t, c.ix.coincident, 0)
	state := u64(0x0FF)
	base := make([]f32, 10 * dim)
	defer delete(base)
	for i in 0 ..< 10 {
		random_unit(&state, base[i * dim:(i + 1) * dim])
	}
	for i in 0 ..< 200 {
		at := i % 10
		churn_insert(t, &c, base[at * dim:(at + 1) * dim])
	}
	testing.expect_value(t, c.ix.twins, 0)
	testing.expect(t, c.ix.twin_link == nil, "no twin list is allocated")
	check_graph(t, &c.ix)
}

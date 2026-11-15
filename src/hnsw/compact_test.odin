package hnsw

import "core:log"
import "core:testing"

graphs_equal :: proc(t: ^testing.T, a: ^Index, b: ^Index, label: string) -> bool {
	if a.slots != b.slots || a.live != b.live || a.entry != b.entry || a.max_level != b.max_level || a.rng != b.rng || a.node_uid != b.node_uid || a.free_head != b.free_head {
		testing.expectf(t, false, "%s: slots %d/%d live %d/%d entry %d/%d top %d/%d", label, a.slots, b.slots, a.live, b.live, a.entry, b.entry, a.max_level, b.max_level)
		return false
	}
	x := make([]u32, a.m0)
	defer delete(x)
	y := make([]u32, a.m0)
	defer delete(y)
	for i in 0 ..< a.slots {
		slot := u32(i)
		if a.levels[slot] != b.levels[slot] {
			testing.expectf(t, false, "%s: slot %d level %d against %d", label, slot, a.levels[slot], b.levels[slot])
			return false
		}
		if !is_node(a, slot) {
			continue
		}
		for layer in 0 ..= int(a.levels[slot]) {
			la := layer_links(a, slot, layer, x)
			lb := layer_links(b, slot, layer, y)
			if len(la) != len(lb) {
				testing.expectf(t, false, "%s: slot %d layer %d holds %d links against %d", label, slot, layer, len(la), len(lb))
				return false
			}
			for id, k in la {
				if id != lb[k] {
					testing.expectf(t, false, "%s: slot %d layer %d link %d is %d against %d", label, slot, layer, k, id, lb[k])
					return false
				}
			}
		}
	}
	return true
}

searches_equal :: proc(t: ^testing.T, a: ^Churn, b: ^Churn, queries: []f32, label: string) {
	k :: 10
	ra: [k]Candidate
	rb: [k]Candidate
	dim := a.p.dim
	for qi in 0 ..< len(queries) / dim {
		qa := Point_Query{&a.p, queries[qi * dim:(qi + 1) * dim]}
		qb := Point_Query{&b.p, queries[qi * dim:(qi + 1) * dim]}
		na, _ := search(&a.ix, &a.s, point_query_distance, &qa, k, 60, ra[:])
		nb, _ := search(&b.ix, &b.s, point_query_distance, &qb, k, 60, rb[:])
		testing.expectf(t, na == nb && ra == rb, "%s: query %d answers differ", label, qi)
	}
}

pool_packed :: proc(t: ^testing.T, ix: ^Index, label: string) {
	live := upper_lists(ix) * (ix.m + 1)
	testing.expectf(t, ix.upper_len == live && ix.upper_cap == live, "%s: the pool holds %d of %d words for %d live words", label, ix.upper_len, ix.upper_cap, live)
	for at in ix.upper_free {
		testing.expectf(t, at == NONE, "%s: a free block is left", label)
	}
	next := 0
	for i in 0 ..< ix.slots {
		lv := ix.levels[i]
		if lv == 0 || lv > LEVEL_CAP {
			continue
		}
		testing.expectf(t, int(ix.upper_at[i]) == next, "%s: slot %d sits at %d, in slot order it sits at %d", label, i, ix.upper_at[i], next)
		next += upper_words(ix, int(lv))
	}
}

@(test)
compacting_the_upper_pool_changes_no_list_and_no_answer :: proc(t: ^testing.T) {
	dim :: 12
	for m in ([]int{4, 16}) {
		plain, packed: Churn
		churn_init(t, &plain, dim, test_params(m, 60, 0xC0A9), 4000)
		defer churn_destroy(&plain)
		churn_init(t, &packed, dim, test_params(m, 60, 0xC0A9), 4000)
		defer churn_destroy(&packed)
		sa := u64(0x7001 + u64(m))
		sb := sa
		qs := u64(0x9001)
		queries := make_queries(&qs, 40, dim)
		defer delete(queries)
		compactions := 0
		rounds := [?][2]int{{1500, 0}, {300, 900}, {700, 200}, {0, 700}, {900, 400}, {50, 900}, {400, 0}}
		for round, i in rounds {
			churn_run(t, &plain, &sa, round[0], round[1])
			churn_run(t, &packed, &sb, round[0], round[1])
			before := packed.ix.upper_len
			testing.expect(t, upper_compact(&packed.ix))
			if packed.ix.upper_len < before {
				compactions += 1
			}
			pool_packed(t, &packed.ix, "after a round")
			testing.expect(t, check_graph(t, &packed.ix))
			if !graphs_equal(t, &plain.ix, &packed.ix, "after a round") {
				return
			}
			searches_equal(t, &plain, &packed, queries, "after a round")
			testing.expectf(t, i == 0 || plain.ix.upper_len >= packed.ix.upper_len, "the packed pool is larger than the plain one")
		}
		testing.expect(t, compactions >= 3)
		testing.expect(t, upper_compact(&packed.ix))
		pool_packed(t, &packed.ix, "compacted twice")
		log.infof("upper pool m %d: %d rounds of inserts and deletes, %d compactions moved lists; plain pool %d words, packed pool %d words; lists and answers equal throughout", m, len(rounds), compactions, plain.ix.upper_len, packed.ix.upper_len)
	}
}

@(test)
compacting_an_empty_or_flat_pool_is_harmless :: proc(t: ^testing.T) {
	c: Churn
	churn_init(t, &c, 4, test_params(4, 20, 3), 64)
	defer churn_destroy(&c)
	testing.expect(t, upper_compact(&c.ix))
	testing.expect(t, c.ix.upper == nil && c.ix.upper_cap == 0 && c.ix.upper_len == 0)
	state := u64(5)
	churn_run(t, &c, &state, 200, 0)
	for len(c.live) > 1 {
		churn_delete(t, &c, 0)
	}
	slot := c.live[0]
	for node_level(&c.ix, slot) != 0 {
		testing.expect_value(t, remove(&c.ix, &c.s, slot), Error.None)
		again, err := reserve(&c.ix)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, again, slot)
		testing.expect_value(t, insert(&c.ix, &c.s, slot), Error.None)
	}
	testing.expect(t, c.ix.upper_len > 0)
	testing.expect(t, upper_compact(&c.ix))
	testing.expect(t, c.ix.upper == nil && c.ix.upper_cap == 0 && c.ix.upper_len == 0)
	churn_run(t, &c, &state, 300, 100)
	testing.expect(t, check_graph(t, &c.ix))
	testing.expect(t, upper_compact(&c.ix))
	pool_packed(t, &c.ix, "after the pool was dropped and grew again")
}

level_adversary :: proc(t: ^testing.T, m: int, trim: bool) -> (worst_cap: int, worst_bound: int, compactions: int, writes: int) {
	dim :: 6
	c: Churn
	churn_init(t, &c, dim, test_params(m, 40, 0xAD7 + u64(m)), 400)
	defer churn_destroy(&c)
	state := u64(0x51 + u64(m))
	churn_run(t, &c, &state, 120, 0)
	ix := &c.ix
	v: [dim]f32
	for target in ([]int{1, 2, 0, 1, 3, 0}) {
		for slot in c.live {
			for node_level(ix, slot) != target {
				testing.expect_value(t, remove(ix, &c.s, slot), Error.None)
				again, err := reserve(ix)
				testing.expect_value(t, err, Error.None)
				testing.expect_value(t, again, slot)
				random_unit(&state, v[:])
				points_set(&c.p, slot, v[:])
				testing.expect_value(t, insert(ix, &c.s, slot), Error.None)
				writes += 1
				live := upper_lists(ix) * (m + 1)
				if trim && ix.upper_len > upper_room(ix, live) {
					testing.expect(t, upper_compact(ix))
					compactions += 1
				}
				if writes == 1 || ix.upper_cap - upper_bound(ix, live) > worst_cap - worst_bound {
					worst_cap = ix.upper_cap
					worst_bound = upper_bound(ix, live)
				}
				if trim && ix.upper_cap > upper_bound(ix, live) {
					testing.expectf(t, false, "m %d: the pool holds %d words against a bound of %d for %d live words", m, ix.upper_cap, upper_bound(ix, live), live)
					return
				}
			}
		}
	}
	testing.expect(t, check_graph(t, ix))
	return
}

@(test)
a_trimmed_upper_pool_stays_inside_its_bound_under_level_selection :: proc(t: ^testing.T) {
	for m in ([]int{4, 16, 48}) {
		cap, bound, compactions, writes := level_adversary(t, m, true)
		testing.expectf(t, compactions > 0, "m %d: the level selection never forced a compaction", m)
		loose_cap, loose_bound, _, _ := level_adversary(t, m, false)
		testing.expectf(t, loose_cap > loose_bound, "m %d: without trimming the pool stayed inside its bound, so the selection proves nothing", m)
		log.infof("upper pool m %d: %d writes that select levels; trimmed, the pool came closest to its bound at %d of %d words after %d compactions; untrimmed it reached %d words against a bound of %d", m, writes, cap, bound, compactions, loose_cap, loose_bound)
	}
}

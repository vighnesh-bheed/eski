package hnsw

import "core:log"
import "core:testing"

@(test)
filtered_search_returns_only_accepted_nodes_within_budget :: proc(t: ^testing.T) {
	dim :: 32
	count :: 10_000
	p: Points
	points_init(&p, dim, true, count)
	defer points_destroy(&p)
	ix: Index
	testing.expect_value(t, init(&ix, test_params(16, 200, 0xF117E2), points_distance, &p, context.allocator), Error.None)
	defer destroy(&ix)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	state := u64(0xF1)
	build_unit(t, &ix, &s, &p, &state, count)
	accepted := 0
	for i in 0 ..< count {
		if mix_slot(u32(i)) % 10 == 0 {
			accepted += 1
		}
	}
	testing.expectf(t, accepted > 900 && accepted < 1100, "accept rate %d of %d", accepted, count)
	queries := make_queries(&state, 100, dim)
	defer delete(queries)
	out: [RECALL_K]Candidate
	truth: [RECALL_K]Candidate
	hits := 0
	total := 0
	for budget in ([]int{1, 50, 300, 1000, 0}) {
		for qi in 0 ..< 100 {
			pq := Point_Query{&p, queries[qi * dim:(qi + 1) * dim]}
			a := Accept_Mod{modulus = 10}
			n, inspected, err := search_filtered(&ix, &s, point_query_distance, &pq, RECALL_K, RECALL_EF, accept_mod, &a, budget, out[:])
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, inspected, a.calls)
			if budget > 0 {
				testing.expectf(t, inspected <= budget, "inspected %d over budget %d", inspected, budget)
			} else {
				testing.expect_value(t, n, RECALL_K)
			}
			for c in out[:n] {
				testing.expect(t, mix_slot(c.id) % 10 == 0, "only accepted nodes are returned")
			}
			for i in 1 ..< n {
				testing.expect(t, closer(out[i - 1], out[i]))
			}
			if budget == 0 {
				b := Accept_Mod{modulus = 10}
				m, _ := brute_force(&ix, &s, point_query_distance, &pq, RECALL_K, truth[:], accept_mod, &b)
				total += m
				for i in 0 ..< n {
					for j in 0 ..< m {
						if out[i].id == truth[j].id {
							hits += 1
							break
						}
					}
				}
			}
		}
	}
	recall := f64(hits) / f64(total)
	log.infof("filtered search, 10 percent accepted, unbounded budget: recall@10 %.4f against filtered brute force", recall)
	testing.expectf(t, recall > 0.9, "filtered recall %.4f", recall)
	pq := Point_Query{&p, queries[:dim]}
	none := Accept_Mod{modulus = 1 << 30}
	n, inspected, _ := search_filtered(&ix, &s, point_query_distance, &pq, RECALL_K, RECALL_EF, accept_mod, &none, 0, out[:])
	testing.expect_value(t, n, 1)
	testing.expect(t, inspected <= count)
	n, inspected, _ = search_filtered(&ix, &s, point_query_distance, &pq, RECALL_K, RECALL_EF, nil, nil, 5, out[:])
	testing.expect_value(t, n, RECALL_K)
	testing.expect_value(t, inspected, 0)
}

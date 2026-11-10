package hnsw

import "core:log"
import "core:testing"

Dup_Shape :: enum {
	Forty_By_Fifty,
	Fifth_Duplicated,
	One_Vector_Thousand,
}

DUP_EFS :: [4]int{10, 50, 100, 400}

DUP_STORED :: 200

DUP_FRESH :: 100

DUP_CENTERS :: 64

DUP_SIGMA :: 0.08

dup_vector :: proc(state: ^u64, centers: []f32, v: []f32) {
	random_clustered(state, centers, len(v), DUP_SIGMA, v)
	normalize(v)
}

Dup_Floor :: struct {
	stored: [4]f64,
	fresh:  [4]f64,
}

dup_floor :: proc(shape: Dup_Shape) -> Dup_Floor {
	switch shape {
	case .Forty_By_Fifty:
		return Dup_Floor{{1, 1, 1, 1}, {0.86, 0.86, 0.92, 0.99}}
	case .Fifth_Duplicated:
		return Dup_Floor{{0.9925, 1, 1, 1}, {0.889, 0.99, 0.997, 1}}
	case .One_Vector_Thousand:
		return Dup_Floor{{0.9905, 0.999, 0.999, 1}, {0.935, 1, 1, 1}}
	}
	return {}
}

shuffle_ints :: proc(state: ^u64, a: []int) {
	for i := len(a) - 1; i > 0; i -= 1 {
		j := int(rng_next(state) % u64(i + 1))
		a[i], a[j] = a[j], a[i]
	}
}

dup_layout :: proc(shape: Dup_Shape, state: ^u64) -> (kinds: int, order: [dynamic]int) {
	switch shape {
	case .Forty_By_Fifty:
		kinds = 40
		for i in 0 ..< kinds {
			for _ in 0 ..< 50 {
				append(&order, i)
			}
		}
	case .Fifth_Duplicated:
		kinds = 2_000
		picks := make([]int, kinds)
		defer delete(picks)
		for i in 0 ..< kinds {
			picks[i] = i
		}
		shuffle_ints(state, picks)
		times := make([]int, kinds)
		defer delete(times)
		for &x in times {
			x = 1
		}
		for i in picks[:kinds / 5] {
			times[i] = 2 + int(rng_next(state) % 19)
		}
		for i in 0 ..< kinds {
			for _ in 0 ..< times[i] {
				append(&order, i)
			}
		}
	case .One_Vector_Thousand:
		kinds = 9_001
		for i in 0 ..< 9_000 {
			append(&order, i)
		}
		for _ in 0 ..< 1_000 {
			append(&order, 9_000)
		}
	}
	shuffle_ints(state, order[:])
	return
}

Dup_Case :: struct {
	c:        Churn,
	vectors:  []f32,
	order:    [dynamic]int,
	stored:   []f32,
	fresh:    []f32,
}

dup_case_build :: proc(t: ^testing.T, d: ^Dup_Case, shape: Dup_Shape, m: int, dim: int, seed: u64) {
	state := seed
	count: int
	count, d.order = dup_layout(shape, &state)
	centers := make([]f32, DUP_CENTERS * dim)
	defer delete(centers)
	for i in 0 ..< DUP_CENTERS {
		random_unit(&state, centers[i * dim:(i + 1) * dim])
	}
	d.vectors = make([]f32, count * dim)
	for i in 0 ..< count {
		dup_vector(&state, centers, d.vectors[i * dim:(i + 1) * dim])
	}
	churn_init(t, &d.c, dim, test_params(m, 100, seed), len(d.order))
	for at in d.order {
		churn_insert(t, &d.c, d.vectors[at * dim:(at + 1) * dim])
	}
	d.stored = make([]f32, DUP_STORED * dim)
	for i in 0 ..< DUP_STORED {
		at := d.order[int(rng_next(&state) % u64(len(d.order)))]
		copy(d.stored[i * dim:(i + 1) * dim], d.vectors[at * dim:(at + 1) * dim])
	}
	d.fresh = make([]f32, DUP_FRESH * dim)
	for i in 0 ..< DUP_FRESH {
		dup_vector(&state, centers, d.fresh[i * dim:(i + 1) * dim])
	}
}

dup_case_destroy :: proc(d: ^Dup_Case) {
	churn_destroy(&d.c)
	delete(d.vectors)
	delete(d.order)
	delete(d.stored)
	delete(d.fresh)
}

tie_recall :: proc(ix: ^Index, s: ^Scratch, p: ^Points, queries: []f32, k: int, ef: int) -> (recall: f64, empty: int) {
	ann := make([]Candidate, k)
	defer delete(ann)
	truth := make([]Candidate, k)
	defer delete(truth)
	hits := 0
	total := 0
	for qi in 0 ..< len(queries) / p.dim {
		pq := Point_Query{p, queries[qi * p.dim:(qi + 1) * p.dim]}
		n, _ := search(ix, s, point_query_distance, &pq, k, ef, ann)
		m, _ := brute_force(ix, s, point_query_distance, &pq, k, truth)
		if m == 0 {
			continue
		}
		good := 0
		for c in ann[:n] {
			if c.dist <= truth[m - 1].dist {
				good += 1
			}
		}
		good = min(good, m)
		hits += good
		total += m
		if good == 0 {
			empty += 1
		}
	}
	return f64(hits) / f64(max(total, 1)), empty
}

expect_reachable :: proc(t: ^testing.T, ix: ^Index, what: string) -> bool {
	ok := true
	for l in 0 ..= ix.max_level {
		reached, present := reachable_at(ix, l)
		if reached != present {
			ok = false
			testing.expectf(t, false, "%s: layer %d has %d of %d live nodes reachable from the entry point", what, l, reached, present)
		}
	}
	return ok
}

dup_recall_check :: proc(t: ^testing.T, d: ^Dup_Case, shape: Dup_Shape, m: int, phase: string, enforce: bool) {
	floor := dup_floor(shape)
	efs := DUP_EFS
	for ef, i in efs {
		rs, es := tie_recall(&d.c.ix, &d.c.s, &d.c.p, d.stored, 10, ef)
		rf, ef_empty := tie_recall(&d.c.ix, &d.c.s, &d.c.p, d.fresh, 10, ef)
		log.infof("%v M %d %s: %d live, %d twins, ef %d recall@10 with ties %.4f stored (%d empty) %.4f fresh (%d empty)", shape, m, phase, d.c.ix.live, d.c.ix.twins, ef, rs, es, rf, ef_empty)
		if enforce {
			testing.expectf(t, rs >= floor.stored[i], "%v M %d %s ef %d: stored recall %.4f below the reference's %.4f", shape, m, phase, ef, rs, floor.stored[i])
			testing.expectf(t, rf >= floor.fresh[i], "%v M %d %s ef %d: fresh recall %.4f below the reference's %.4f", shape, m, phase, ef, rf, floor.fresh[i])
		}
	}
}

dup_churn_round :: proc(t: ^testing.T, d: ^Dup_Case, state: ^u64) {
	c := &d.c
	dim := c.p.dim
	cut := len(c.live) / 5
	saved := make([]f32, cut * dim)
	defer delete(saved)
	for i in 0 ..< cut {
		at := int(rng_next(state) % u64(len(c.live)))
		copy(saved[i * dim:(i + 1) * dim], points_get(&c.p, c.live[at]))
		churn_delete(t, c, at)
	}
	for i in 0 ..< cut {
		churn_insert(t, c, saved[i * dim:(i + 1) * dim])
	}
}

dup_shape_run :: proc(t: ^testing.T, shape: Dup_Shape, ms: []int) {
	for m in ms {
		d: Dup_Case
		dup_case_build(t, &d, shape, m, 16, 0xD0B5 + u64(shape) * 7 + u64(m))
		defer dup_case_destroy(&d)
		check_graph(t, &d.c.ix)
		expect_reachable(t, &d.c.ix, "after the build")
		testing.expectf(t, d.c.ix.twins > 0, "%v M %d keeps copies beyond the coincident limit off the graph", shape, m)
		dup_recall_check(t, &d, shape, m, "built", m == 16)
		state := u64(0xC4021) + u64(m)
		for round in 0 ..< 3 {
			dup_churn_round(t, &d, &state)
			check_graph(t, &d.c.ix)
			expect_reachable(t, &d.c.ix, "after a churn round")
			testing.expect_value(t, d.c.ix.live, len(d.order))
			_ = round
		}
		dup_recall_check(t, &d, shape, m, "after three rounds of deleting and reinserting a fifth", m == 16)
	}
}

@(test)
forty_vectors_fifty_times_each_stay_reachable_and_findable :: proc(t: ^testing.T) {
	dup_shape_run(t, .Forty_By_Fifty, []int{4, 8, 16})
}

@(test)
a_fifth_duplicated_up_to_twenty_times_stays_reachable_and_findable :: proc(t: ^testing.T) {
	dup_shape_run(t, .Fifth_Duplicated, []int{4, 16})
}

@(test)
a_thousand_copies_of_one_vector_stay_reachable_and_findable :: proc(t: ^testing.T) {
	dup_shape_run(t, .One_Vector_Thousand, []int{16})
}

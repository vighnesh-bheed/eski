package retrieve

import "core:math"
import "core:slice"
import "core:testing"

before :: proc(a, b: Ranked) -> bool {
	return ranks_before(a, b)
}

Toy :: struct {
	begun:  int,
	max_or: bool,
}

toy_scorer :: proc(toy: ^Toy) -> Scorer {
	return Scorer {
		ctx = toy,
		begin = proc(ctx: rawptr, collection: Collection) {
			(^Toy)(ctx).begun += 1
		},
		prepare = proc(ctx: rawptr, term: Term_Statistics) -> f64 {
			return f64(term.containing)
		},
		term = proc(ctx: rawptr, l: ^Leaf, hit: Hit, doc: ^Document) -> f64 {
			return l.weight * f64(hit.frequency) + l.prepared / 1000
		},
		combine = proc(ctx: rawptr, node: Node_Kind, total, child: f64) -> f64 {
			if (^Toy)(ctx).max_or && node == .Union {
				return max(total, child)
			}
			return total + child
		},
		finish = proc(ctx: rawptr, total: f64, doc: ^Document, root: ^Cursor) -> f64 {
			return total * f64(doc.score)
		},
	}
}

@(test)
tree_scores_fold_children_in_their_order :: proc(t: ^testing.T) {
	c: Corpus
	corpus_init(&c)
	defer corpus_destroy(&c)
	corpus_add(&c, 1, {{field = 0, text = "fox fox dog"}})
	corpus_add(&c, 2, {{field = 0, text = "dog cat"}})
	corpus_add(&c, 3, {{field = 0, text = "fox cat cat cat"}})
	toy: Toy
	s := toy_scorer(&toy)
	begin(&s, Collection{documents = 3, total_length = 9})
	testing.expect_value(t, toy.begun, 1)
	pool: Term_Pool
	defer pool_destroy(&pool)
	fox := pool_term(&pool, &c, "fox", nil, 2)
	dog := pool_term(&pool, &c, "dog", nil)
	cat := pool_term(&pool, &c, "cat", nil)
	for cur in ([?]^Cursor{fox, dog, cat}) {
		tc := (^Term_Cursor)(cur)
		prepare(&s, &tc.leaf, tc.cost)
	}
	u: Union
	union_init(&u, {fox, dog, cat}, 0.5)
	defer union_destroy(&u)
	top: Top_K
	top_k_init(&top, 10)
	defer top_k_destroy(&top)
	col := top_k_collector(&top)
	docs := proc(ctx: rawptr, id: u32) -> (Document, bool) {
		return Document{id = id, length = 3, score = 0.5 if id == 2 else 1}, true
	}
	matched, err := run(&u, &s, docs, nil, &col)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, matched, 3)
	out := make([dynamic]Ranked)
	defer delete(out)
	top_k_results(&top, &out)
	want := [4]f64{0, 0.5 * ((2 * 2 + 0.002) + (1 + 0.002)), 0.5 * 0.5 * ((1 + 0.002) + (1 + 0.002)), 0.5 * ((2 * 1 + 0.002) + (3 + 0.002))}
	testing.expect_value(t, len(out), 3)
	for r in out {
		testing.expectf(t, r.score == want[r.doc], "doc %d scored %v want %v", r.doc, r.score, want[r.doc])
	}
	order := [?]Ranked{{doc = 1, score = want[1]}, {doc = 2, score = want[2]}, {doc = 3, score = want[3]}}
	slice.sort_by(order[:], before)
	for i in 0 ..< 3 {
		testing.expect_value(t, out[i].doc, order[i].doc)
	}
	toy.max_or = true
	first: Union
	fox2 := pool_term(&pool, &c, "fox", nil, 2)
	cat2 := pool_term(&pool, &c, "cat", nil)
	union_init(&first, {cat2, fox2}, 1, .First)
	defer union_destroy(&first)
	sc := Scoring{scorer = &s, doc = Document{id = 3, score = 1}}
	testing.expect_value(t, advance(&first, 3), 3)
	testing.expect_value(t, score(&first, &sc), 3.0)
	maxed: Union
	fox3 := pool_term(&pool, &c, "fox", nil, 2)
	cat3 := pool_term(&pool, &c, "cat", nil)
	union_init(&maxed, {fox3, cat3})
	defer union_destroy(&maxed)
	testing.expect_value(t, advance(&maxed, 3), 3)
	testing.expect_value(t, score(&maxed, &sc), 3.0)
	ix: Intersection
	fox4 := pool_term(&pool, &c, "fox", nil, 2)
	cat4 := pool_term(&pool, &c, "cat", nil)
	intersection_init(&ix, {fox4, cat4}, nil, 3)
	defer intersection_destroy(&ix)
	testing.expect_value(t, next(&ix), 3)
	testing.expect_value(t, score(&ix, &sc), 15.0)
	filt := Leaf{kind = .Filter, weight = 9}
	prepare(&s, &filt, 99)
	testing.expect_value(t, filt.prepared, 0.0)
	testing.expect_value(t, leaf_score(&sc, &filt, Hit{frequency = 4}), 0.0)
	_, has := upper_bound(&s, &filt, 1, 1)
	testing.expect(t, !has)
}

@(test)
top_k_keeps_the_best_in_rank_order :: proc(t: ^testing.T) {
	r := Rng{0x70_9C}
	for round in 0 ..< 300 {
		n := rng_below(&r, 400)
		k := rng_below(&r, 50)
		items := make([dynamic]Ranked, context.temp_allocator)
		top: Top_K
		top_k_init(&top, k)
		for i in 0 ..< n {
			s := f64(rng_below(&r, 20)) / 4
			if rng_below(&r, 40) == 0 {
				s = math.nan_f64()
			}
			d := u32(i * 3 + 1)
			append(&items, Ranked{doc = d, score = s})
			top_k_push(&top, d, s)
		}
		slice.sort_by(items[:], before)
		got := make([dynamic]Ranked, context.temp_allocator)
		top_k_results(&top, &got)
		testing.expect_value(t, top.total, u64(n))
		want := items[:min(k, len(items))]
		ok := len(got) == len(want)
		for i in 0 ..< min(len(got), len(want)) {
			same := got[i].doc == want[i].doc && (got[i].score == want[i].score || (got[i].score != got[i].score && want[i].score != want[i].score))
			ok = ok && same
		}
		if !testing.expectf(t, ok, "round %d n %d k %d", round, n, k) {
			top_k_destroy(&top)
			return
		}
		if k > 0 && n >= k {
			testing.expect(t, top_k_threshold(&top) == want[k - 1].score || want[k - 1].score != want[k - 1].score)
		}
		top_k_destroy(&top)
		free_all(context.temp_allocator)
	}
	edge: Top_K
	top_k_init(&edge, 2)
	defer top_k_destroy(&edge)
	testing.expect_value(t, top_k_threshold(&edge), math.inf_f64(-1))
	top_k_push(&edge, 9, 1)
	top_k_push(&edge, 4, 1)
	top_k_push(&edge, 2, 1)
	out := make([dynamic]Ranked)
	defer delete(out)
	top_k_results(&edge, &out)
	testing.expect(t, out[0].doc == 2 && out[1].doc == 4)
}

@(test)
merge_of_partitions_equals_a_global_sort :: proc(t: ^testing.T) {
	r := Rng{0x3E26}
	for round in 0 ..< 200 {
		parts := 1 + rng_below(&r, 6)
		lists := make([][dynamic]Ranked, parts, context.temp_allocator)
		all := make([dynamic]Ranked, context.temp_allocator)
		for i in 0 ..< parts {
			lists[i] = make([dynamic]Ranked, context.temp_allocator)
		}
		for d in 1 ..= rng_below(&r, 300) {
			x := Ranked{doc = u32(d), score = f64(rng_below(&r, 30)) / 3}
			p := rng_below(&r, parts)
			append(&lists[p], x)
			append(&all, x)
		}
		views := make([][]Ranked, parts, context.temp_allocator)
		for i in 0 ..< parts {
			slice.sort_by(lists[i][:], before)
			views[i] = lists[i][:]
		}
		slice.sort_by(all[:], before)
		k := rng_below(&r, 80)
		got := make([dynamic]Ranked, context.temp_allocator)
		testing.expect_value(t, merge(views, k, &got), Error.None)
		want := all[:min(k, len(all))]
		if !testing.expectf(t, slice.equal(got[:], want), "round %d", round) {
			return
		}
		free_all(context.temp_allocator)
	}
}

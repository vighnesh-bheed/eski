package retrieve

import "core:strings"
import "core:slice"
import "core:testing"
import "../roaring"
import "../sorted"

VOCABULARY := [?]string{"fox", "dog", "cat", "owl", "sun", "sea", "sky", "elk", "ant", "bee", "cow", "pig", "hen", "yak", "eel", "jay"}

random_corpus :: proc(r: ^Rng, c: ^Corpus, docs: int, longest: int) {
	corpus_init(c)
	id := u32(0)
	for _ in 0 ..< docs {
		id += 1 + u32(rng_below(r, 4))
		n := 1 + rng_below(r, longest)
		words := make([dynamic]string, context.temp_allocator)
		for _ in 0 ..< n {
			k := rng_below(r, len(VOCABULARY))
			if rng_below(r, 2) == 0 {
				k = rng_below(r, 4)
			}
			append(&words, VOCABULARY[k])
		}
		text := strings.join(words[:], " ", context.temp_allocator)
		corpus_add(c, id, {{field = 0, text = text}})
	}
}

brute_and :: proc(a, b: []u32) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	for x in a {
		if _, found := slice.binary_search(b, x); found {
			append(&out, x)
		}
	}
	return out[:]
}

brute_or :: proc(a, b: []u32) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	append(&out, ..a)
	append(&out, ..b)
	slice.sort(out[:])
	return slice.unique(out[:])
}

brute_not :: proc(a, b: []u32) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	for x in a {
		if _, found := slice.binary_search(b, x); !found {
			append(&out, x)
		}
	}
	return out[:]
}

pick :: proc(r: ^Rng) -> string {
	if rng_below(r, 10) == 0 {
		return "absent"
	}
	return VOCABULARY[rng_below(r, len(VOCABULARY))]
}

@(test)
algebra_matches_brute_force :: proc(t: ^testing.T) {
	r := Rng{0xA16E}
	c: Corpus
	random_corpus(&r, &c, 900, 14)
	defer corpus_destroy(&c)
	deleted: roaring.Bitmap
	roaring.init(&deleted)
	defer roaring.destroy(&deleted)
	for id in c.ids {
		if rng_below(&r, 6) == 0 {
			roaring.add(&deleted, id)
		}
	}
	for round in 0 ..< 300 {
		del := &deleted if round % 2 == 0 else nil
		pool: Term_Pool
		a, b, x, y := pick(&r), pick(&r), pick(&r), pick(&r)
		da, db, dx, dy := term_docs(&c, a, del), term_docs(&c, b, del), term_docs(&c, x, del), term_docs(&c, y, del)
		for strategy in Strategy {
			ix: Intersection
			intersection_init(&ix, {pool_term(&pool, &c, a, del), pool_term(&pool, &c, b, del)}, nil, 1, strategy)
			got := drain(&ix)
			if !testing.expectf(t, same_docs(got, brute_and(da, db)), "round %d %v: %s AND %s", round, strategy, a, b) {
				return
			}
			intersection_destroy(&ix)
		}
		for mode in Union_Mode {
			u: Union
			union_init(&u, {pool_term(&pool, &c, a, del), pool_term(&pool, &c, b, del), pool_term(&pool, &c, x, del)}, 1, mode)
			testing.expect(t, same_docs(drain(&u), brute_or(brute_or(da, db), dx)))
			union_destroy(&u)
		}
		diff: Difference
		difference_init(&diff, pool_term(&pool, &c, a, del), pool_term(&pool, &c, b, del))
		testing.expect(t, same_docs(drain(&diff), brute_not(da, db)))
		inner: Union
		union_init(&inner, {pool_term(&pool, &c, a, del), pool_term(&pool, &c, b, del)})
		nested: Intersection
		intersection_init(&nested, {&inner, pool_term(&pool, &c, x, del)})
		testing.expect(t, same_docs(drain(&nested), brute_and(brute_or(da, db), dx)))
		intersection_destroy(&nested)
		union_destroy(&inner)
		inner2: Union
		union_init(&inner2, {pool_term(&pool, &c, a, del), pool_term(&pool, &c, b, del)})
		both: Intersection
		intersection_init(&both, {pool_term(&pool, &c, x, del), pool_term(&pool, &c, y, del)})
		outer: Difference
		difference_init(&outer, &inner2, &both)
		testing.expect(t, same_docs(drain(&outer), brute_not(brute_or(da, db), brute_and(dx, dy))))
		union_destroy(&inner2)
		intersection_destroy(&both)
		opt: Intersection
		intersection_init(&opt, {pool_term(&pool, &c, a, del)}, {pool_term(&pool, &c, b, del)})
		testing.expect(t, same_docs(drain(&opt), da))
		intersection_destroy(&opt)
		subset: roaring.Bitmap
		roaring.init(&subset)
		for id in c.ids {
			if rng_below(&r, 3) == 0 {
				roaring.add(&subset, id)
			}
		}
		bc: Bitmap_Cursor
		bitmap_cursor_init(&bc, &subset, del, leaf(.Tag))
		arr := make([dynamic]u32, context.temp_allocator)
		for id in c.ids {
			if rng_below(&r, 2) == 0 {
				append(&arr, id)
			}
		}
		ac: Array_Cursor
		array_cursor_init(&ac, arr[:], del, leaf(.Filter))
		mixed: Intersection
		intersection_init(&mixed, {pool_term(&pool, &c, a, del), &bc, &ac})
		subset_docs := make([dynamic]u32, context.temp_allocator)
		for id in c.ids {
			if roaring.contains(&subset, id) && (del == nil || !roaring.contains(del, id)) {
				append(&subset_docs, id)
			}
		}
		arr_docs := brute_not(arr[:], term_docs(&c, "never", nil))
		if del != nil {
			live := make([dynamic]u32, context.temp_allocator)
			for id in arr_docs {
				if !roaring.contains(del, id) {
					append(&live, id)
				}
			}
			arr_docs = live[:]
		}
		testing.expect(t, same_docs(drain(&mixed), brute_and(brute_and(da, subset_docs[:]), arr_docs)))
		intersection_destroy(&mixed)
		roaring.destroy(&subset)
		pool_destroy(&pool)
		free_all(context.temp_allocator)
	}
}

@(test)
advance_on_composites_matches_brute_force :: proc(t: ^testing.T) {
	r := Rng{0xAD7C}
	c: Corpus
	random_corpus(&r, &c, 1500, 10)
	defer corpus_destroy(&c)
	for round in 0 ..< 120 {
		pool: Term_Pool
		a, b, x := pick(&r), pick(&r), pick(&r)
		da, db, dx := term_docs(&c, a, nil), term_docs(&c, b, nil), term_docs(&c, x, nil)
		u: Union
		union_init(&u, {pool_term(&pool, &c, a, nil), pool_term(&pool, &c, b, nil)})
		ix: Intersection
		intersection_init(&ix, {&u, pool_term(&pool, &c, x, nil)}, nil, 1, Strategy(round % 3))
		want := brute_and(brute_or(da, db), dx)
		target := u32(0)
		pos := 0
		for {
			target += u32(rng_below(&r, 40))
			for pos < len(want) && want[pos] < target {
				pos += 1
			}
			d := advance(&ix, target)
			if pos == len(want) {
				testing.expect_value(t, d, END)
				break
			}
			if !testing.expect_value(t, d, want[pos]) {
				break
			}
			if rng_below(&r, 2) == 0 {
				d = next(&ix)
				pos += 1
				if pos == len(want) {
					testing.expect_value(t, d, END)
					break
				}
				testing.expect_value(t, d, want[pos])
				target = d
			}
		}
		intersection_destroy(&ix)
		union_destroy(&u)
		pool_destroy(&pool)
		free_all(context.temp_allocator)
	}
}

@(test)
block_merge_and_galloping_agree_with_the_scalar_kernel :: proc(t: ^testing.T) {
	r := Rng{0xB10C}
	c: Corpus
	random_corpus(&r, &c, 12_000, 6)
	defer corpus_destroy(&c)
	for i in 0 ..< 4 {
		for j in 0 ..< 6 {
			a, b := VOCABULARY[i], VOCABULARY[j]
			da, db := term_docs(&c, a, nil), term_docs(&c, b, nil)
			ref := make([]u32, min(len(da), len(db)), context.temp_allocator)
			n := sorted.intersect_reference(da, db, ref)
			for strategy in ([?]Strategy{.Leapfrog, .Block}) {
				pool: Term_Pool
				ix: Intersection
				intersection_init(&ix, {pool_term(&pool, &c, a, nil), pool_term(&pool, &c, b, nil)}, nil, 1, strategy)
				testing.expect_value(t, ix.strategy, strategy)
				testing.expect(t, same_docs(drain(&ix), ref[:n]))
				intersection_destroy(&ix)
				pool_destroy(&pool)
			}
		}
	}
	free_all(context.temp_allocator)
}

@(test)
block_strategy_handles_long_array_windows :: proc(t: ^testing.T) {
	a := make([]u32, 5000)
	defer delete(a)
	b := make([]u32, 4000)
	defer delete(b)
	for i in 0 ..< len(a) {
		a[i] = u32(2 * i + 2)
	}
	for i in 0 ..< len(b) {
		b[i] = u32(3 * i + 3)
	}
	ref := make([]u32, len(b))
	defer delete(ref)
	n := sorted.intersect_reference(a, b, ref)
	ca, cb: Array_Cursor
	array_cursor_init(&ca, a, nil, leaf(.Filter))
	array_cursor_init(&cb, b, nil, leaf(.Filter))
	ix: Intersection
	intersection_init(&ix, {&ca, &cb}, nil, 1, .Block)
	defer intersection_destroy(&ix)
	testing.expect_value(t, ix.strategy, Strategy.Block)
	testing.expect(t, same_docs(drain(&ix), ref[:n]))
	free_all(context.temp_allocator)
}

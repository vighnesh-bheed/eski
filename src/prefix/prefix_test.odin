package prefix

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../bm25std"
import "../postings"
import "../retrieve"
import "../termdict"

Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ z >> 30) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ z >> 27) * 0x94D0_49BB_1331_11EB
	return z ~ z >> 31
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	return int(rng_next(r) % u64(n))
}

docs_of :: proc(d: ^termdict.Dictionary, ids: []termdict.Id, terms: []string) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for id in ids {
		text, _ := termdict.text(d, id)
		for t, i in terms {
			if t == text {
				append(&out, i)
			}
		}
	}
	slice.sort(out[:])
	return out[:]
}

@(test)
expansion_follows_the_recorded_order_and_limit :: proc(t: ^testing.T) {
	d: termdict.Dictionary
	termdict.init(&d)
	defer termdict.destroy(&d)
	for term in PREFIX_TERMS {
		termdict.insert(&d, term)
	}
	p := params_default()
	m := matcher(&p)
	ids := make([dynamic]termdict.Id)
	defer delete(ids)
	truncated, err := termdict.expand(&m, &d, "ab", LIMIT, &ids)
	testing.expect_value(t, err, termdict.Error.None)
	testing.expect(t, truncated)
	testing.expect_value(t, len(ids), PREFIX_LIMIT_TOTAL)
	testing.expect(t, slice.equal(docs_of(&d, ids[:], PREFIX_TERMS[:]), PREFIX_LIMIT_DOCS[:]))
	for i in 1 ..< len(ids) {
		a, _ := termdict.text(&d, ids[i - 1])
		b, _ := termdict.text(&d, ids[i])
		testing.expect(t, a < b)
	}
	clear(&ids)
	truncated, err = termdict.expand(&m, &d, "abc", LIMIT, &ids)
	testing.expect(t, !truncated && err == .None)
	testing.expect(t, slice.equal(docs_of(&d, ids[:], PREFIX_TERMS[:]), PREFIX_ABC_DOCS[:]))
	clear(&ids)
	truncated, _ = termdict.expand(&m, &d, "a", LIMIT, &ids)
	testing.expect(t, !truncated && len(ids) == 0)
	clear(&ids)
	termdict.insert(&d, "éa")
	termdict.insert(&d, "éb")
	termdict.expand(&m, &d, "é", LIMIT, &ids)
	testing.expect_value(t, len(ids), 0)
	termdict.expand(&m, &d, "éa", LIMIT, &ids)
	testing.expect_value(t, len(ids), 1)
	clear(&ids)
	truncated, _ = termdict.expand(&m, &d, "ab", 0, &ids)
	testing.expect(t, truncated && len(ids) == 0)
	truncated, _ = termdict.expand(&m, &d, "ab", -1, &ids)
	testing.expect(t, !truncated && len(ids) == len(PREFIX_TERMS))
}

@(test)
expansion_agrees_with_a_sorted_scan :: proc(t: ^testing.T) {
	r := Rng{0x9F1}
	d: termdict.Dictionary
	termdict.init(&d)
	defer termdict.destroy(&d)
	all := make([dynamic]string)
	defer {
		for s in all {
			delete(s)
		}
		delete(all)
	}
	alphabet := "abc+"
	for _ in 0 ..< 3000 {
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< 1 + rng_below(&r, 6) {
			strings.write_byte(&b, alphabet[rng_below(&r, len(alphabet))])
		}
		s := strings.to_string(b)
		if _, inserted, _ := termdict.insert(&d, s); inserted {
			append(&all, strings.clone(s))
		}
	}
	slice.sort(all[:])
	p := params_default()
	m := matcher(&p)
	for _ in 0 ..< 400 {
		pattern := all[rng_below(&r, len(all))]
		pattern = pattern[:min(len(pattern), 1 + rng_below(&r, 3))]
		limit := rng_below(&r, 60)
		want := make([dynamic]string, context.temp_allocator)
		if len(pattern) >= MIN_LENGTH {
			for s in all {
				if strings.has_prefix(s, pattern) {
					append(&want, s)
				}
			}
		}
		ids := make([dynamic]termdict.Id, context.temp_allocator)
		truncated, _ := termdict.expand(&m, &d, pattern, limit, &ids)
		testing.expect_value(t, truncated, len(want) > limit)
		testing.expect_value(t, len(ids), min(limit, len(want)))
		for id, i in ids {
			text, _ := termdict.text(&d, id)
			testing.expect_value(t, text, want[i])
		}
		free_all(context.temp_allocator)
	}
}

score_prefix_probe :: proc(t: ^testing.T, docs: []string, prefix_key: string, want: []Scored) {
	d: termdict.Dictionary
	termdict.init(&d)
	defer termdict.destroy(&d)
	lists := make([dynamic]postings.List)
	defer {
		for &l in lists {
			postings.destroy(&l)
		}
		delete(lists)
	}
	total := u64(0)
	lengths := make([]u32, len(docs))
	defer delete(lengths)
	for text, i in docs {
		words := strings.fields(text, context.temp_allocator)
		lengths[i] = u32(len(words))
		total += u64(len(words))
		for w, k in words {
			id, inserted, _ := termdict.insert(&d, w)
			if inserted {
				l: postings.List
				postings.init(&l, postings.Layout{field_words = 1, positions = true})
				append(&lists, l)
			}
			assert(int(id) < len(lists))
			e := postings.append_posting(&lists[id], postings.Posting{doc = u32(i + 1), frequency = 1, fields = 1, counts = {1}, positions = {u32(k + 1)}})
			assert(e == .None)
		}
	}
	p := params_default()
	m := matcher(&p)
	ids := make([dynamic]termdict.Id, context.temp_allocator)
	termdict.expand(&m, &d, "ab", LIMIT, &ids)
	bp := bm25std.params_default()
	s := bm25std.scorer(&bp)
	retrieve.begin(&s, retrieve.Collection{documents = u64(len(docs)), total_length = total})
	kids := make([dynamic]^retrieve.Cursor, context.temp_allocator)
	for id in ids {
		tc := new(retrieve.Term_Cursor, context.temp_allocator)
		retrieve.term_cursor_init(tc, &lists[id], nil, 0, retrieve.leaf(.Term), postings.ALL_FIELDS, context.temp_allocator)
		retrieve.prepare(&s, &tc.leaf, tc.cost)
		append(&kids, tc)
	}
	u: retrieve.Union
	retrieve.union_init(&u, kids[:], 1, .First, context.temp_allocator)
	top: retrieve.Top_K
	retrieve.top_k_init(&top, 10, context.temp_allocator)
	col := retrieve.top_k_collector(&top)
	Ctx :: struct {
		lengths: []u32,
	}
	ctx := Ctx{lengths}
	lookup := proc(c: rawptr, id: u32) -> (retrieve.Document, bool) {
		x := (^Ctx)(c)
		return retrieve.Document{id = id, length = x.lengths[id - 1], score = 1}, true
	}
	retrieve.run(&u, &s, lookup, &ctx, &col)
	out := make([dynamic]retrieve.Ranked, context.temp_allocator)
	retrieve.top_k_results(&top, &out)
	testing.expect_value(t, len(out), len(want))
	for w, i in want {
		v, _ := strconv.parse_f64(w.score)
		key := fmt.tprintf("%s:%s%d", prefix_key[:2], prefix_key[2:], out[i].doc - 1)
		testing.expectf(t, key == w.key && out[i].score == v, "rank %d: %s %.17g, want %s %s", i, key, out[i].score, w.key, w.score)
	}
	free_all(context.temp_allocator)
}

@(test)
first_match_unions_reproduce_recorded_prefix_scores :: proc(t: ^testing.T) {
	score_prefix_probe(t, PY_DOCS[:], "pym", PY_RESULTS[:])
	score_prefix_probe(t, PV_DOCS[:], "pv", PV_RESULTS[:])
}

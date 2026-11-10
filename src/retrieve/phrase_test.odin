package retrieve

import "core:slice"
import "core:strings"
import "core:testing"
import "../postings"

build_phrase_corpus :: proc(c: ^Corpus, docs: []Phrase_Doc) {
	corpus_init(c)
	for d in docs {
		parts := make([dynamic]Field_Text, context.temp_allocator)
		for text, f in d.fields {
			append(&parts, Field_Text{field = f, text = text})
		}
		corpus_add(c, u32(d.key + 1), parts[:])
	}
}

phrase_corpus :: proc(name: string) -> []Phrase_Doc {
	for pc in PHRASE_CORPORA {
		if pc.name == name {
			return pc.docs
		}
	}
	return nil
}

field_mask :: proc(field: string) -> postings.Fields {
	m := postings.Fields(0)
	for name in strings.split(field, "|", context.temp_allocator) {
		switch name {
		case "t":
			m |= 1
		case "u":
			m |= 2
		}
	}
	return m
}

@(test)
phrases_reproduce_the_recorded_reference_cases :: proc(t: ^testing.T) {
	for pc, n in PHRASE_CASES {
		c: Corpus
		build_phrase_corpus(&c, phrase_corpus(pc.corpus))
		required := field_mask(pc.field)
		cursors := make([dynamic]^Cursor, context.temp_allocator)
		terms := make([dynamic]^Term_Cursor, context.temp_allocator)
		missing := false
		for w in pc.words {
			list := corpus_list(&c, w)
			if list == nil {
				missing = true
				break
			}
			tc := new(Term_Cursor, context.temp_allocator)
			term_cursor_init(tc, list, nil, required, leaf(.Term))
			append(&terms, tc)
			append(&cursors, tc)
		}
		got := make([dynamic]int, context.temp_allocator)
		if !missing {
			p: Phrase
			testing.expect_value(t, phrase_init(&p, cursors[:], pc.slop, pc.in_order), Error.None)
			for d := next(&p); d != END; d = next(&p) {
				append(&got, int(d) - 1)
			}
			phrase_destroy(&p)
		}
		testing.expectf(t, slice.equal(got[:], pc.docs), "case %d %s %v slop %d in order %v: got %v want %v", n, pc.field, pc.words, pc.slop, pc.in_order, got[:], pc.docs)
		for tc in terms {
			term_cursor_destroy(tc)
		}
		corpus_destroy(&c)
		free_all(context.temp_allocator)
	}
}

oracle_ordered :: proc(lists: [][]u32, slop: int, at: int, first: u32, prev: u32) -> bool {
	if at == len(lists) {
		return slop < 0 || int(prev) - int(first) - (len(lists) - 1) <= slop
	}
	for p in lists[at] {
		if at > 0 && p < prev {
			continue
		}
		f := first if at > 0 else p
		if oracle_ordered(lists, slop, at + 1, f, p) {
			return true
		}
	}
	return false
}

oracle_unordered :: proc(lists: [][]u32, slop: int, at: int, lo, hi: u32) -> bool {
	if at == len(lists) {
		return hi > lo && int(hi) - int(lo) - (len(lists) - 1) <= slop
	}
	for p in lists[at] {
		l := min(lo, p) if at > 0 else p
		h := max(hi, p) if at > 0 else p
		if oracle_unordered(lists, slop, at + 1, l, h) {
			return true
		}
	}
	return false
}

@(test)
phrases_match_a_declarative_oracle_for_distinct_terms :: proc(t: ^testing.T) {
	r := Rng{0xF4A5}
	c: Corpus
	corpus_init(&c)
	defer corpus_destroy(&c)
	small := [?]string{"fox", "dog", "cat", "owl", "sun", "sea"}
	for id in 1 ..= 500 {
		words := make([dynamic]string, context.temp_allocator)
		for _ in 0 ..< 1 + rng_below(&r, 12) {
			append(&words, small[rng_below(&r, len(small))])
		}
		corpus_add(&c, u32(id), {{field = 0, text = strings.join(words[:], " ", context.temp_allocator)}})
	}
	for round in 0 ..< 200 {
		k := 2 + rng_below(&r, 2)
		chosen := make([dynamic]string, context.temp_allocator)
		for len(chosen) < k {
			w := small[rng_below(&r, len(small))]
			if !slice.contains(chosen[:], w) {
				append(&chosen, w)
			}
		}
		slop := rng_below(&r, 5) - 1
		in_order := rng_below(&r, 2) == 0
		want := make([dynamic]u32, context.temp_allocator)
		for doc, di in c.docs {
			_ = doc
			lists := make([][]u32, k, context.temp_allocator)
			ok := true
			for w, i in chosen {
				lists[i] = doc_positions(&c, di, w)
				if len(lists[i]) == 0 {
					ok = false
				}
			}
			if !ok {
				continue
			}
			match := false
			if in_order {
				match = oracle_ordered(lists, slop, 0, 0, 0)
			} else {
				match = slop < 0 || oracle_unordered(lists, slop, 0, 0, 0)
			}
			if match {
				append(&want, c.ids[di])
			}
		}
		pool: Term_Pool
		cursors := make([dynamic]^Cursor, context.temp_allocator)
		for w in chosen {
			append(&cursors, pool_term(&pool, &c, w, nil))
		}
		p: Phrase
		phrase_init(&p, cursors[:], slop, in_order)
		got := drain(&p)
		if !testing.expectf(t, same_docs(got, want[:]), "round %d %v slop %d in order %v", round, chosen[:], slop, in_order) {
			phrase_destroy(&p)
			pool_destroy(&pool)
			return
		}
		phrase_destroy(&p)
		pool_destroy(&pool)
		free_all(context.temp_allocator)
	}
}

@(test)
phrase_windows_follow_the_reference_rules :: proc(t: ^testing.T) {
	heads: [4]int
	testing.expect(t, ordered_window({{1}, {1}}, 0))
	testing.expect(t, !ordered_window({{2}, {1}}, -1))
	testing.expect(t, ordered_window({{1, 9}, {4, 10}}, 0))
	testing.expect(t, !ordered_window({{1}, {4}}, 1))
	testing.expect(t, ordered_window({{1}, {4}}, 2))
	testing.expect(t, ordered_window({{1}, {4}}, -1))
	testing.expect(t, !unordered_window({{3}, {3}}, 0, heads[:]))
	testing.expect(t, unordered_window({{2, 3}, {2, 3}}, 0, heads[:]))
	testing.expect(t, unordered_window({{3}, {3}, {1, 4}}, 0, heads[:]))
	testing.expect(t, !unordered_window({{1}, {4}, {1}}, 0, heads[:]))
	testing.expect(t, unordered_window({{4}, {1, 6}}, 1, heads[:]))
	testing.expect(t, !unordered_window({{4}, {1, 6}}, 0, heads[:]))
}

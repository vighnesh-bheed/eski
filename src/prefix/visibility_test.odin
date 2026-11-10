package prefix

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "../label"
import "../termdict"
import "../termstats"

Labelled :: struct {
	dict:    termdict.Dictionary,
	stats:   termstats.Stats,
	table:   label.Table,
	open:    label.Id,
	secret:  label.Id,
	reader:  label.Visibility,
	cleared: label.Visibility,
	terms:   [dynamic]string,
	labels:  [dynamic]label.Id,
}

labelled_init :: proc(l: ^Labelled) {
	termdict.init(&l.dict)
	termstats.init(&l.stats)
	label.table_init(&l.table)
	low, _ := label.label_make(0)
	high, _ := label.label_make(2, 1)
	l.open, _ = label.table_intern(&l.table, low)
	l.secret, _ = label.table_intern(&l.table, high)
	label.visibility_build(&l.reader, &l.table, low)
	label.visibility_build(&l.cleared, &l.table, high)
	l.terms = make([dynamic]string)
	l.labels = make([dynamic]label.Id)
}

labelled_destroy :: proc(l: ^Labelled) {
	termdict.destroy(&l.dict)
	termstats.destroy(&l.stats)
	label.visibility_destroy(&l.reader)
	label.visibility_destroy(&l.cleared)
	label.table_destroy(&l.table)
	for s in l.terms {
		delete(s)
	}
	delete(l.terms)
	delete(l.labels)
}

labelled_add :: proc(l: ^Labelled, term: string, id: label.Id, documents := 1) {
	tid, inserted, _ := termdict.insert(&l.dict, term)
	if inserted {
		append(&l.terms, strings.clone(term))
		append(&l.labels, id)
	}
	for _ in 0 ..< documents {
		termstats.term_add(&l.stats, u32(tid), id)
	}
}

expand_texts :: proc(l: ^Labelled, p: ^Params, pattern: string, limit: int) -> (texts: []string, truncated: bool) {
	m := matcher(p)
	ids := make([dynamic]termdict.Id, context.temp_allocator)
	truncated, _ = termdict.expand(&m, &l.dict, pattern, limit, &ids)
	out := make([]string, len(ids), context.temp_allocator)
	for id, i in ids {
		out[i], _ = termdict.text(&l.dict, id)
	}
	return out, truncated
}

numbered :: proc(prefix: string, i: int) -> string {
	return fmt.tprintf("%s%03d", prefix, i)
}

@(test)
hidden_terms_before_a_visible_one_do_not_push_it_out :: proc(t: ^testing.T) {
	l: Labelled
	labelled_init(&l)
	defer labelled_destroy(&l)
	for i in 0 ..< LIMIT {
		labelled_add(&l, numbered("ab", i), l.secret)
	}
	labelled_add(&l, numbered("ab", LIMIT), l.open)
	for i in LIMIT + 1 ..< LIMIT + 40 {
		labelled_add(&l, numbered("ab", i), l.secret)
	}
	off := params_default()
	texts, truncated := expand_texts(&l, &off, "ab", LIMIT)
	testing.expect_value(t, len(texts), LIMIT)
	testing.expect(t, truncated)
	testing.expect_value(t, texts[0], "ab000")
	on := params_visible(&l.stats, &l.reader)
	texts, truncated = expand_texts(&l, &on, "ab", LIMIT)
	testing.expect_value(t, len(texts), 1)
	testing.expect_value(t, texts[0], numbered("ab", LIMIT))
	testing.expect(t, !truncated, "hidden terms after the visible one must not set truncated")
	all := params_visible(&l.stats, &l.cleared)
	texts, truncated = expand_texts(&l, &all, "ab", LIMIT)
	testing.expect_value(t, len(texts), LIMIT)
	testing.expect(t, truncated)
	free_all(context.temp_allocator)
}

@(test)
hidden_terms_after_the_limit_never_set_truncated :: proc(t: ^testing.T) {
	l: Labelled
	labelled_init(&l)
	defer labelled_destroy(&l)
	for i in 0 ..< 2 * LIMIT {
		labelled_add(&l, numbered("cd", i), l.open if i % 2 == 0 else l.secret)
	}
	for i in 2 * LIMIT ..< 2 * LIMIT + 30 {
		labelled_add(&l, numbered("cd", i), l.secret)
	}
	on := params_visible(&l.stats, &l.reader)
	texts, truncated := expand_texts(&l, &on, "cd", LIMIT)
	testing.expect_value(t, len(texts), LIMIT)
	testing.expect(t, !truncated, "exactly the limit of visible terms, the rest hidden")
	for s, i in texts {
		testing.expect_value(t, s, numbered("cd", 2 * i))
	}
	labelled_add(&l, numbered("cd", 2 * LIMIT + 30), l.open)
	texts, truncated = expand_texts(&l, &on, "cd", LIMIT)
	testing.expect_value(t, len(texts), LIMIT)
	testing.expect(t, truncated, "one more visible term beyond the limit")
	texts, truncated = expand_texts(&l, &on, "cd", LIMIT - 1)
	testing.expect_value(t, len(texts), LIMIT - 1)
	testing.expect(t, truncated)
	texts, truncated = expand_texts(&l, &on, "cd", 0)
	testing.expect_value(t, len(texts), 0)
	testing.expect(t, truncated)
	free_all(context.temp_allocator)
}

@(test)
terms_whose_documents_left_are_skipped_and_visibility_without_stats_fails_closed :: proc(t: ^testing.T) {
	l: Labelled
	labelled_init(&l)
	defer labelled_destroy(&l)
	labelled_add(&l, "efa", l.open)
	labelled_add(&l, "efb", l.open)
	labelled_add(&l, "efc", l.secret)
	tid, _ := termdict.lookup(&l.dict, "efa")
	termstats.term_remove(&l.stats, u32(tid), l.open)
	on := params_visible(&l.stats, &l.reader)
	texts, truncated := expand_texts(&l, &on, "ef", LIMIT)
	testing.expect(t, slice.equal(texts, []string{"efb"}))
	testing.expect(t, !truncated)
	broken := Params{min_length = MIN_LENGTH, visibility = &l.reader}
	texts, truncated = expand_texts(&l, &broken, "ef", LIMIT)
	testing.expect_value(t, len(texts), 0)
	testing.expect(t, !truncated)
	short := params_visible(&l.stats, &l.reader)
	texts, _ = expand_texts(&l, &short, "e", LIMIT)
	testing.expect_value(t, len(texts), 0)
	free_all(context.temp_allocator)
}

@(test)
visible_expansion_agrees_with_a_filtered_scan :: proc(t: ^testing.T) {
	r := Rng{0xA11CE}
	l: Labelled
	labelled_init(&l)
	defer labelled_destroy(&l)
	alphabet := "abz"
	for _ in 0 ..< 1500 {
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< 1 + rng_below(&r, 5) {
			strings.write_byte(&b, alphabet[rng_below(&r, len(alphabet))])
		}
		id := l.open if rng_below(&r, 4) == 0 else l.secret
		labelled_add(&l, strings.to_string(b), id, 1 + rng_below(&r, 2))
	}
	sorted_terms := make([]string, len(l.terms))
	defer delete(sorted_terms)
	copy(sorted_terms, l.terms[:])
	slice.sort(sorted_terms)
	for _ in 0 ..< 300 {
		pattern := sorted_terms[rng_below(&r, len(sorted_terms))]
		pattern = pattern[:min(len(pattern), 1 + rng_below(&r, 3))]
		limit := rng_below(&r, 40)
		reader := &l.reader if rng_below(&r, 2) == 0 else &l.cleared
		want := make([dynamic]string, context.temp_allocator)
		visible_total := 0
		if len(pattern) >= MIN_LENGTH {
			for s in sorted_terms {
				if !strings.has_prefix(s, pattern) {
					continue
				}
				tid, _ := termdict.lookup(&l.dict, s)
				if termstats.term_visible(&l.stats, u32(tid), reader) == 0 {
					continue
				}
				visible_total += 1
				if len(want) < limit {
					append(&want, s)
				}
			}
		}
		p := params_visible(&l.stats, reader)
		texts, truncated := expand_texts(&l, &p, pattern, limit)
		testing.expect(t, slice.equal(texts, want[:]))
		testing.expect_value(t, truncated, visible_total > limit)
		free_all(context.temp_allocator)
	}
}

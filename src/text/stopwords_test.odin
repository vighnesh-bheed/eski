package text

import "core:slice"
import "core:testing"

@(test)
default_stop_words :: proc(t: ^testing.T) {
	sw: Stop_Words
	testing.expect_value(t, stop_words_default(&sw), Error.None)
	defer stop_words_destroy(&sw)
	testing.expect_value(t, len(stop_words_list(&sw)), 33)
	testing.expect(t, slice.is_sorted(stop_words_list(&sw)))
	testing.expect(t, !stop_words_reported(&sw))
	for w in DEFAULT_STOP_WORDS {
		testing.expectf(t, is_stop_word(&sw, transmute([]u8)w), "%q is a default stop word", w)
	}
	for w in ([?]string{"", "i", "you", "fox", "The", "thes", "th", "wit", "withs", "it's", "s", "t"}) {
		testing.expectf(t, !is_stop_word(&sw, transmute([]u8)w), "%q is not a default stop word", w)
	}
	testing.expect(t, !is_stop_word(nil, transmute([]u8)string("the")))
}

@(test)
no_stop_words :: proc(t: ^testing.T) {
	sw: Stop_Words
	testing.expect_value(t, stop_words_none(&sw), Error.None)
	defer stop_words_destroy(&sw)
	testing.expect_value(t, len(stop_words_list(&sw)), 0)
	testing.expect(t, stop_words_reported(&sw))
	testing.expect(t, !is_stop_word(&sw, transmute([]u8)string("the")))
	empty: Stop_Words
	testing.expect_value(t, stop_words_custom(&empty, nil), Error.None)
	testing.expect_value(t, empty.mode, Stop_Mode.None)
	stop_words_destroy(&empty)
}

@(test)
probe_custom_stop_lists :: proc(t: ^testing.T) {
	for p in PROBE_STOP_LISTS {
		f: Fixture
		fixture_init(&f, .Custom, p.words)
		testing.expect(t, stop_words_reported(&f.stop))
		expect_strings(t, "stopwords_list", stop_words_list(&f.stop), p.list)
		fixture_run(&f, PROBE_STOP_DOC, Field{stem = false})
		expect_strings(t, escaped_list(p.words), dump_terms(&f), p.terms)
		fixture_destroy(&f)
	}
	testing.expect_value(t, len(PROBE_STOP_LISTS), 11)
}

@(test)
probe_folded_stop_words :: proc(t: ^testing.T) {
	for p in PROBE_STOP_SINGLE {
		f: Fixture
		fixture_init(&f, .Custom, {p.word})
		list := stop_words_list(&f.stop)
		testing.expectf(t, len(list) == 1 && list[0] == p.list, "%q: list %v, reference %q", p.word, escaped_list(list), p.list)
		fixture_run(&f, p.doc, Field{stem = false})
		expect_strings(t, p.word, dump_terms(&f), p.terms)
		fixture_destroy(&f)
	}
}

@(test)
stop_words_leave_no_position :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, .Default)
	defer fixture_destroy(&f)
	last := fixture_run(&f, "the fox jumped over the lazy dog", Field{stem = false})
	testing.expect_value(t, last, 5)
	want := [?]string{"fox", "jumped", "over", "lazy", "dog"}
	for term, i in f.terms.list {
		testing.expect_value(t, term_string(&f.terms, term), want[i])
		testing.expect_value(t, term.position, u32(i + 1))
	}
	terms_clear(&f.terms)
	last = fixture_run(&f, "THE And tHiS", Field{stem = false})
	testing.expect_value(t, last, 0)
	testing.expect_value(t, len(f.terms.list), 0)
}

@(test)
empty_stop_word_keeps_empty_terms :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, .Custom, {""})
	defer fixture_destroy(&f)
	last := fixture_run(&f, "aaa \x80\x80 ccc", Field{stem = false})
	testing.expect_value(t, last, 3)
	testing.expect_value(t, len(f.terms.list), 3)
	testing.expect_value(t, f.terms.list[1].length, 0)
	testing.expect_value(t, f.terms.list[2].position, 3)
}

@(test)
query_stop_word_rules :: proc(t: ^testing.T) {
	sw: Stop_Words
	stop_words_default(&sw)
	defer stop_words_destroy(&sw)
	the := transmute([]u8)string("the")
	fox := transmute([]u8)string("fox")
	testing.expect(t, query_drops_term(&sw, the, .Plain, false))
	testing.expect(t, !query_drops_term(&sw, fox, .Plain, false))
	testing.expect(t, !query_drops_term(&sw, the, .Plain, true))
	for kind in Query_Term_Kind {
		if kind == .Plain {
			continue
		}
		testing.expectf(t, !query_drops_term(&sw, the, kind, false), "%v keeps stop words", kind)
	}
	none: Stop_Words
	stop_words_none(&none)
	defer stop_words_destroy(&none)
	testing.expect(t, !query_drops_term(&none, the, .Plain, false))
}

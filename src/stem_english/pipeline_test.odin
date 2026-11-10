package stem_english

import "core:slice"
import "core:strings"
import "core:testing"
import tx "../text"

Fixture :: struct {
	analyzer: tx.Analyzer,
	stop:     tx.Stop_Words,
	stemmers: tx.Stemmers,
	terms:    tx.Terms,
}

fixture_init :: proc(f: ^Fixture, mode: tx.Stop_Mode, custom: []string = nil) {
	switch mode {
	case .Default:
		tx.stop_words_default(&f.stop)
	case .None:
		tx.stop_words_none(&f.stop)
	case .Custom:
		words := make([][]u8, len(custom), context.temp_allocator)
		for w, i in custom {
			words[i] = transmute([]u8)w
		}
		tx.stop_words_custom(&f.stop, words)
	}
	f.stemmers[.English] = stem
	tx.analyzer_init(&f.analyzer, &f.stop, &f.stemmers)
	tx.terms_init(&f.terms)
}

fixture_destroy :: proc(f: ^Fixture) {
	tx.analyzer_destroy(&f.analyzer)
	tx.stop_words_destroy(&f.stop)
	tx.terms_destroy(&f.terms)
}

fixture_run :: proc(f: ^Fixture, doc: string, field := tx.DEFAULT_FIELD) -> u32 {
	return tx.analyze(&f.analyzer, transmute([]u8)doc, field, &f.terms)
}

dump_terms :: proc(f: ^Fixture, allocator := context.temp_allocator) -> []string {
	seen := make([dynamic]string, 0, len(f.terms.list), allocator)
	buf := make([dynamic]u8, 0, 64, context.temp_allocator)
	for term in f.terms.list {
		clear(&buf)
		if !tx.trie_form(tx.term_bytes(&f.terms, term), &buf) || len(buf) == 0 {
			continue
		}
		append(&seen, strings.clone(string(buf[:]), allocator))
	}
	slice.sort(seen[:])
	unique := 0
	for s in seen {
		if unique == 0 || seen[unique - 1] != s {
			seen[unique] = s
			unique += 1
		}
	}
	return seen[:unique]
}

expect_terms :: proc(t: ^testing.T, label: string, got: []string, want: []string) {
	if slice.equal(got, want) {
		return
	}
	missing := make([dynamic]string, context.temp_allocator)
	extra := make([dynamic]string, context.temp_allocator)
	for w in want {
		if !slice.contains(got, w) {
			append(&missing, w)
		}
	}
	for g in got {
		if !slice.contains(want, g) {
			append(&extra, g)
		}
	}
	testing.expectf(t, false, "%s: %d terms, want %d; missing %q, extra %q", label, len(got), len(want), missing[:], extra[:])
}

@(test)
recorded_tokenization_index_with_stems :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, .Default)
	defer fixture_destroy(&f)
	for doc in RECORDED_TK_DOCS {
		fixture_run(&f, doc)
	}
	expect_terms(t, "tk", dump_terms(&f), RECORDED_DUMP_TK[:])
	testing.expect_value(t, len(RECORDED_DUMP_TK), 122)
}

@(test)
recorded_stem_index :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, .Default)
	defer fixture_destroy(&f)
	for w in RECORDED_STEM_WORDS {
		fixture_run(&f, w, tx.Field{language = .English, stem = true})
		fixture_run(&f, w, tx.Field{language = .English, stem = false})
	}
	expect_terms(t, "st", dump_terms(&f), RECORDED_DUMP_ST[:])
	testing.expect_value(t, len(RECORDED_DUMP_ST), 82)
}

@(test)
recorded_stop_word_indexes_with_stems :: proc(t: ^testing.T) {
	cases := [?]struct {
		mode:   tx.Stop_Mode,
		custom: []string,
		want:   []string,
		name:   string,
	} {
		{.Default, nil, RECORDED_DUMP_SW[:], "sw"},
		{.None, nil, RECORDED_DUMP_SW0[:], "sw0"},
		{.Custom, {"fox", "Dog"}, RECORDED_DUMP_SWC[:], "swc"},
	}
	for c in cases {
		f: Fixture
		fixture_init(&f, c.mode, c.custom)
		for doc in RECORDED_SW_DOCS {
			fixture_run(&f, doc)
		}
		expect_terms(t, c.name, dump_terms(&f), c.want)
		fixture_destroy(&f)
	}
}

@(test)
probe_minimum_stem_length :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, .None)
	defer fixture_destroy(&f)
	for doc in PROBE_MINSTEM.docs {
		fixture_run(&f, doc)
	}
	expect_terms(t, "minimum stem length index", dump_terms(&f), PROBE_MINSTEM.terms)
	for p in PROBE_MINSTEM_SINGLE {
		g: Fixture
		fixture_init(&g, .None)
		for doc in p.docs {
			fixture_run(&g, doc)
		}
		expect_terms(t, p.docs[0], dump_terms(&g), p.terms)
		fixture_destroy(&g)
	}
}

@(test)
probe_escaped_and_supplementary_stems :: proc(t: ^testing.T) {
	for p in ([?]Probe_Index{PROBE_ESCAPED_STEMS, PROBE_SUPPLEMENTARY_STEMS}) {
		f: Fixture
		fixture_init(&f, .None)
		for doc in p.docs {
			fixture_run(&f, doc)
		}
		expect_terms(t, p.docs[0], dump_terms(&f), p.terms)
		fixture_destroy(&f)
	}
}

@(test)
stems_share_positions :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, .Default)
	defer fixture_destroy(&f)
	last := fixture_run(&f, "The runners were running and the dogs ran")
	testing.expect_value(t, last, 5)
	Want :: struct {
		text:     string,
		position: u32,
	}
	want := [?]Want{{"runners", 1}, {"+runner", 1}, {"were", 2}, {"running", 3}, {"+run", 3}, {"dogs", 4}, {"+dog", 4}, {"ran", 5}}
	testing.expect_value(t, len(f.terms.list), len(want))
	for term, i in f.terms.list {
		if i >= len(want) {
			break
		}
		testing.expect_value(t, tx.term_string(&f.terms, term), want[i].text)
		testing.expect_value(t, term.position, want[i].position)
	}
}

package text

import "core:testing"

FUZZ_DOCS :: 20_000

FUZZ_MAX_LEN :: 96

@(rodata)
FUZZ_ALPHABET := [?]u8{'a', 'b', 'Z', 'y', '_', '0', ' ', '\t', '\n', ',', '-', '\\', '\'', 0x00, 0x01, 0x7F, 0x80, 0xBF, 0xC3, 0xA9, 0xC4, 0xB0, 0xE2, 0x84, 0xAA, 0xF0, 0x9F, 0x98, 0xF8, 0xFF, 0xED, 0xA0}

fuzz_doc :: proc(r: ^Rng, out: ^[dynamic]u8) {
	clear(out)
	n := rng_below(r, FUZZ_MAX_LEN + 1)
	mode := rng_below(r, 3)
	for _ in 0 ..< n {
		switch mode {
		case 0:
			append(out, u8(rng_next(r)))
		case 1:
			append(out, FUZZ_ALPHABET[rng_below(r, len(FUZZ_ALPHABET))])
		case:
			if rng_below(r, 4) == 0 {
				append(out, u8(rng_next(r)))
			} else {
				append(out, FUZZ_ALPHABET[rng_below(r, 12)])
			}
		}
	}
}

well_formed :: proc(b: []u8) -> bool {
	i := 0
	for i < len(b) {
		c := b[i]
		need := 0
		switch {
		case c < 0x80:
			need = 0
		case c >= 0xC0 && c < 0xE0:
			need = 1
		case c >= 0xE0 && c < 0xF0:
			need = 2
		case c >= 0xF0 && c < 0xF8:
			need = 3
		case:
			return false
		}
		if i + need >= len(b) && need > 0 {
			return false
		}
		for k in 1 ..= need {
			if b[i + k] & 0xC0 != 0x80 {
				return false
			}
		}
		i += need + 1
	}
	return true
}

snapshot :: proc(f: ^Fixture, allocator := context.temp_allocator) -> []string {
	return term_list(f, allocator)
}

@(test)
fuzz_documents_are_safe_and_deterministic :: proc(t: ^testing.T) {
	stemmers: Stemmers
	stemmers[.English] = strip_s
	a: Fixture
	b: Fixture
	fixture_init(&a, .Default, nil, &stemmers)
	fixture_init(&b, .Default, nil, &stemmers)
	defer fixture_destroy(&a)
	defer fixture_destroy(&b)
	r := Rng{0x7E47_0000_0000_0001}
	doc := make([dynamic]u8, 0, FUZZ_MAX_LEN)
	defer delete(doc)
	trie := make([dynamic]u8, 0, 64)
	defer delete(trie)
	again := make([dynamic]u8, 0, 64)
	defer delete(again)
	terms := 0
	for _ in 0 ..< FUZZ_DOCS {
		fuzz_doc(&r, &doc)
		terms_clear(&a.terms)
		terms_clear(&b.terms)
		last := analyze(&a.analyzer, doc[:], DEFAULT_FIELD, &a.terms)
		analyze(&b.analyzer, doc[:], DEFAULT_FIELD, &b.terms)
		first := snapshot(&a)
		second := snapshot(&b)
		if !expect_strings(t, "determinism", first, second) {
			break
		}
		limit := u32(text_limit(doc[:]))
		previous := u32(0)
		for term, i in a.terms.list {
			testing.expect(t, term.start < term.end)
			testing.expect(t, term.end <= limit)
			testing.expect(t, term.position >= previous)
			testing.expect(t, term.position <= last)
			if term.kind == .Stem {
				testing.expect(t, i > 0 && a.terms.list[i - 1].position == term.position)
				testing.expect(t, term_bytes(&a.terms, term)[0] == STEM_PREFIX)
			} else {
				testing.expect(t, term.position == previous + 1)
				body := term_bytes(&a.terms, term)
				testing.expectf(t, well_formed(body), "term %x of %x is not well formed", body, doc[:])
				clear(&again)
				fold(body, nil, &again)
				testing.expectf(t, string(again[:]) == string(body), "fold of %x is not stable: %x", body, again[:])
				clear(&trie)
				trie_form(body, &trie)
			}
			previous = term.position
			terms += 1
		}
		free_all(context.temp_allocator)
	}
	testing.expect(t, terms > 0)
}

@(test)
fuzz_fold_with_tails :: proc(t: ^testing.T) {
	r := Rng{0xF01D_0000_0000_0002}
	text := make([dynamic]u8, 0, 32)
	defer delete(text)
	tail := make([dynamic]u8, 0, 8)
	defer delete(tail)
	one := make([dynamic]u8, 0, 64)
	defer delete(one)
	two := make([dynamic]u8, 0, 64)
	defer delete(two)
	for _ in 0 ..< 50_000 {
		fuzz_doc(&r, &text)
		clear(&tail)
		for _ in 0 ..< rng_below(&r, 5) {
			append(&tail, u8(rng_next(&r)))
		}
		clear(&one)
		clear(&two)
		fold(text[:], tail[:], &one)
		fold(text[:], tail[:], &two)
		testing.expect(t, string(one[:]) == string(two[:]))
		testing.expect(t, len(one) <= 4 * len(text) + 4)
	}
}

@(test)
fuzz_custom_stop_lists :: proc(t: ^testing.T) {
	r := Rng{0x5709_0000_0000_0003}
	pool := make([dynamic][dynamic]u8, 0, 16)
	defer {
		for &w in pool {
			delete(w)
		}
		delete(pool)
	}
	for _ in 0 ..< 200 {
		for &w in pool {
			delete(w)
		}
		clear(&pool)
		count := rng_below(&r, 12)
		views := make([][]u8, count, context.temp_allocator)
		for i in 0 ..< count {
			w := make([dynamic]u8, 0, 8)
			fuzz_doc(&r, &w)
			if len(w) > 12 {
				resize(&w, 12)
			}
			append(&pool, w)
			views[i] = w[:]
		}
		sw: Stop_Words
		testing.expect_value(t, stop_words_custom(&sw, views), Error.None)
		folded := make([dynamic]u8, 0, 16, context.temp_allocator)
		for v in views {
			clear(&folded)
			fold(v, nil, &folded)
			testing.expect(t, is_stop_word(&sw, folded[:]))
		}
		list := stop_words_list(&sw)
		for i in 1 ..< len(list) {
			testing.expect(t, list[i - 1] < list[i])
		}
		stop_words_destroy(&sw)
		free_all(context.temp_allocator)
	}
}

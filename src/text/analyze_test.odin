package text

import "core:testing"

strip_s :: proc "contextless" (word: []u8, out: []u8) -> (stem: []u8, ok: bool) {
	if len(out) < len(word) {
		return nil, false
	}
	copy(out, word)
	n := len(word)
	if n > 1 && word[n - 1] == 's' {
		n -= 1
	}
	return out[:n], true
}

greedy_calls: int

greedy :: proc "contextless" (word: []u8, out: []u8) -> (stem: []u8, ok: bool) {
	greedy_calls += 1
	if len(out) < 4 * len(word) + 64 {
		return nil, false
	}
	n := 0
	for _ in 0 ..< 4 {
		copy(out[n:], word)
		n += len(word)
	}
	return out[:n], true
}

@(test)
stem_slot_and_positions :: proc(t: ^testing.T) {
	stemmers: Stemmers
	stemmers[.English] = strip_s
	f: Fixture
	fixture_init(&f, .Default, nil, &stemmers)
	defer fixture_destroy(&f)
	last := fixture_run(&f, "Cats and dogs ran past THE trees", DEFAULT_FIELD)
	testing.expect_value(t, last, 5)
	Want :: struct {
		text:     string,
		position: u32,
		kind:     Term_Kind,
	}
	want := [?]Want {
		{"cats", 1, .Original},
		{"+cat", 1, .Stem},
		{"dogs", 2, .Original},
		{"+dog", 2, .Stem},
		{"ran", 3, .Original},
		{"past", 4, .Original},
		{"trees", 5, .Original},
		{"+tree", 5, .Stem},
	}
	testing.expect_value(t, len(f.terms.list), len(want))
	for term, i in f.terms.list {
		if i >= len(want) {
			break
		}
		testing.expect_value(t, term_string(&f.terms, term), want[i].text)
		testing.expect_value(t, term.position, want[i].position)
		testing.expect_value(t, term.kind, want[i].kind)
	}
	testing.expect_value(t, f.terms.list[0].start, 0)
	testing.expect_value(t, f.terms.list[0].end, 4)
	testing.expect_value(t, f.terms.list[1].start, 0)
	testing.expect_value(t, f.terms.list[1].end, 4)
}

@(test)
minimum_stem_length_counts_folded_bytes :: proc(t: ^testing.T) {
	stemmers: Stemmers
	stemmers[.English] = strip_s
	f: Fixture
	fixture_init(&f, .None, nil, &stemmers)
	defer fixture_destroy(&f)
	fixture_run(&f, "its \xc3\xa9s \xc4\xb0s a\xe2\x84\xaas abcs", DEFAULT_FIELD)
	got := term_list(&f)
	expect_strings(t, "minimum stem length", got, {"its", "\xc3\xa9s", "i\xcc\x87s", "+i\xcc\x87", "aks", "abcs", "+abc"})
	terms_clear(&f.terms)
	f.analyzer.min_stem = 2
	fixture_run(&f, "is as", DEFAULT_FIELD)
	expect_strings(t, "minimum stem length 2", term_list(&f), {"is", "+i", "as", "+a"})
}

@(test)
no_stem_fields_and_languages :: proc(t: ^testing.T) {
	stemmers: Stemmers
	stemmers[.English] = strip_s
	f: Fixture
	fixture_init(&f, .None, nil, &stemmers)
	defer fixture_destroy(&f)
	fixture_run(&f, "cats dogs", Field{language = .English, stem = false})
	expect_strings(t, "no stem", term_list(&f), {"cats", "dogs"})
	terms_clear(&f.terms)
	fixture_run(&f, "cats dogs", Field{language = .German, stem = true})
	expect_strings(t, "language without a stemmer", term_list(&f), {"cats", "dogs"})
	terms_clear(&f.terms)
	last := fixture_run(&f, "cats", Field{language = .English, stem = true, base = 100})
	testing.expect_value(t, last, 101)
	testing.expect_value(t, f.terms.list[0].position, 101)
	testing.expect_value(t, f.terms.list[1].position, 101)
	plain: Fixture
	fixture_init(&plain, .None)
	defer fixture_destroy(&plain)
	fixture_run(&plain, "cats", DEFAULT_FIELD)
	expect_strings(t, "no stemmer table", term_list(&plain), {"cats"})
}

@(test)
stemmer_buffer_grows :: proc(t: ^testing.T) {
	stemmers: Stemmers
	stemmers[.English] = greedy
	f: Fixture
	fixture_init(&f, .None, nil, &stemmers)
	defer fixture_destroy(&f)
	greedy_calls = 0
	fixture_run(&f, "abcdefgh", DEFAULT_FIELD)
	testing.expect(t, greedy_calls >= 2)
	got := term_list(&f)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[1], "+abcdefghabcdefghabcdefghabcdefgh")
}

@(test)
positions_of_unusual_tokens :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, .None)
	defer fixture_destroy(&f)
	cases := [?]struct {
		doc:   string,
		last:  u32,
		count: int,
	} {
		{"ddd \x01\x02 eee", 2, 2},
		{"aaa \x80\x80 ccc", 3, 3},
		{"hhh \xf0\x90\x80\x80 iii", 3, 3},
		{"\\\x01 \\ x", 1, 1},
	}
	for c in cases {
		terms_clear(&f.terms)
		last := fixture_run(&f, c.doc, Field{stem = false})
		testing.expectf(t, last == c.last && len(f.terms.list) == c.count, "%q: last position %d with %d terms, want %d with %d", c.doc, last, len(f.terms.list), c.last, c.count)
	}
	b := make([dynamic]u8, 0, 320)
	defer delete(b)
	append(&b, "aaa ")
	for _ in 0 ..< 300 {
		append(&b, 'b')
	}
	append(&b, " ccc")
	terms_clear(&f.terms)
	last := fixture_run(&f, string(b[:]), Field{stem = false})
	testing.expect_value(t, last, 3)
	testing.expect_value(t, f.terms.list[1].length, 300)
	testing.expect_value(t, len(dump_terms(&f)), 2)
}

@(test)
custom_normalizer_and_tokenizer :: proc(t: ^testing.T) {
	Pairs :: struct {
		src: []u8,
		pos: int,
	}
	reset :: proc(data: rawptr, text: []u8) {
		p := (^Pairs)(data)
		p.src = text
		p.pos = 0
	}
	next :: proc(data: rawptr, token: ^Token) -> bool {
		p := (^Pairs)(data)
		if p.pos + 2 > len(p.src) {
			return false
		}
		token.text = p.src[p.pos:][:2]
		token.tail = nil
		token.start = p.pos
		token.end = p.pos + 2
		p.pos += 2
		return true
	}
	upper :: proc(text: []u8, tail: []u8, out: ^[dynamic]u8) {
		for b in text {
			append(out, b - 32 if b >= 'a' && b <= 'z' else b)
		}
	}
	state: Pairs
	f: Fixture
	fixture_init(&f, .None)
	defer fixture_destroy(&f)
	f.analyzer.tokenizer = Tokenizer{data = &state, reset = reset, next = next}
	f.analyzer.normalize = upper
	last := fixture_run(&f, "abcdef", Field{stem = false})
	testing.expect_value(t, last, 3)
	expect_strings(t, "pairs", term_list(&f), {"AB", "CD", "EF"})
	testing.expect_value(t, f.terms.list[2].start, 4)
}

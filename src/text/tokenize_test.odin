package text

import "core:strings"
import "core:testing"

Expected_Token :: struct {
	text:  string,
	start: int,
	end:   int,
}

collect_tokens :: proc(doc: string, allocator := context.temp_allocator) -> []Expected_Token {
	t: Doc_Tokenizer
	doc_tokenizer_init(&t)
	defer doc_tokenizer_destroy(&t)
	doc_tokenizer_reset(&t, transmute([]u8)doc)
	out := make([dynamic]Expected_Token, 0, 8, allocator)
	tok: Token
	for doc_tokenizer_next(&t, &tok) {
		append(&out, Expected_Token{strings.clone(string(tok.text), allocator), tok.start, tok.end})
	}
	return out[:]
}

@(test)
recorded_tokenization_index :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, .Default)
	defer fixture_destroy(&f)
	for doc in RECORDED_TK_DOCS {
		fixture_run(&f, doc)
	}
	expect_strings(t, "tk", dump_terms(&f), without_stems(RECORDED_DUMP_TK[:]))
	testing.expect_value(t, len(RECORDED_DUMP_TK) - len(without_stems(RECORDED_DUMP_TK[:])), 6)
}

@(test)
recorded_stop_word_indexes :: proc(t: ^testing.T) {
	cases := [?]struct {
		mode:   Stop_Mode,
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
		expect_strings(t, c.name, dump_terms(&f), without_stems(c.want))
		fixture_destroy(&f)
	}
}

@(test)
recorded_stem_index_without_stemmer :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f, .Default)
	defer fixture_destroy(&f)
	for w in RECORDED_STEM_WORDS {
		fixture_run(&f, w)
	}
	expect_strings(t, "st", dump_terms(&f), without_stems(RECORDED_DUMP_ST[:]))
}

@(test)
probe_escape_documents :: proc(t: ^testing.T) {
	for p in PROBE_ESCAPES {
		f: Fixture
		fixture_init(&f)
		fixture_run(&f, p.doc, Field{stem = false})
		expect_strings(t, p.doc, dump_terms(&f), p.terms)
		fixture_destroy(&f)
	}
	testing.expect_value(t, len(PROBE_ESCAPES), 22)
}

@(test)
probe_nul_documents :: proc(t: ^testing.T) {
	for p in PROBE_NUL {
		f: Fixture
		fixture_init(&f)
		fixture_run(&f, p.doc, Field{stem = false})
		expect_strings(t, p.doc, dump_terms(&f), p.terms)
		fixture_destroy(&f)
	}
}

long_doc :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "zz ")
	count := 0
	rest := ""
	switch name {
	case "a254_I":
		count, rest = 254, "İ"
	case "a253_I":
		count, rest = 253, "İ"
	case "a253_K":
		count, rest = 253, "K"
	case "a252_K":
		count, rest = 252, "K"
	case "a255_esc_b":
		count, rest = 255, "\\b"
	case "a254_esc_b":
		count, rest = 254, "\\b"
	case "a254_ctl_b":
		count, rest = 254, "\x01b"
	case "a255_ctl_b":
		count, rest = 255, "\x01b"
	case "a255":
		count = 255
	case "a256":
		count = 256
	case "a250_emoji":
		count, rest = 250, "\U0001F600b"
	case "a251_emoji":
		count, rest = 251, "\U0001F600b"
	case "a252_emoji":
		count, rest = 252, "\U0001F600"
	}
	for _ in 0 ..< count {
		strings.write_byte(&b, 'a')
	}
	strings.write_string(&b, rest)
	strings.write_string(&b, " yy")
	return strings.to_string(b)
}

@(test)
probe_long_tokens :: proc(t: ^testing.T) {
	for p in PROBE_LONG_TOKENS {
		f: Fixture
		fixture_init(&f)
		doc := long_doc(p.name)
		fixture_run(&f, doc, Field{stem = false})
		dumped := dump_terms(&f)
		lengths := make([dynamic]int, 0, 4, context.temp_allocator)
		for s in dumped {
			append(&lengths, len(s))
		}
		sorted := lengths[:]
		for i in 1 ..< len(sorted) {
			for k := i; k > 0 && sorted[k - 1] > sorted[k]; k -= 1 {
				sorted[k - 1], sorted[k] = sorted[k], sorted[k - 1]
			}
		}
		testing.expectf(t, len(sorted) == len(p.lengths), "%s: dictionary lengths %v, reference %v", p.name, sorted, p.lengths)
		if len(sorted) == len(p.lengths) {
			for x, i in sorted {
				testing.expectf(t, x == p.lengths[i], "%s: dictionary lengths %v, reference %v", p.name, sorted, p.lengths)
			}
		}
		testing.expect_value(t, len(f.terms.list), 3)
		fixture_destroy(&f)
	}
	testing.expect_value(t, len(PROBE_LONG_TOKENS), 13)
}

@(test)
token_spans :: proc(t: ^testing.T) {
	cases := [?]struct {
		doc:  string,
		want: []Expected_Token,
	} {
		{"Hello, World!", {{"Hello", 0, 5}, {"World", 7, 12}}},
		{"esc\\-aped x", {{"esc-aped", 0, 9}, {"x", 10, 11}}},
		{"  a\x01b  ", {{"ab", 2, 5}}},
		{"\x01\x02 b", {{"b", 3, 4}}},
		{"tail\\", {{"tail", 0, 5}}},
		{"\\ lead", {{" lead", 0, 6}}},
		{"a\x00b c", {{"a", 0, 1}}},
		{"under_score 123", {{"under_score", 0, 11}, {"123", 12, 15}}},
		{"caf\xc3\xa9-\xe6\x9d\xb1", {{"caf\xc3\xa9", 0, 5}, {"\xe6\x9d\xb1", 6, 9}}},
		{"x\\\ty", {{"xy", 0, 4}}},
		{"", {}},
		{" \t,.;", {}},
	}
	for c in cases {
		got := collect_tokens(c.doc)
		ok := len(got) == len(c.want)
		if ok {
			for g, i in got {
				ok = ok && g == c.want[i]
			}
		}
		testing.expectf(t, ok, "%q: tokens %v, want %v", c.doc, got, c.want)
	}
}

@(test)
token_tails_follow_compaction :: proc(t: ^testing.T) {
	td: Doc_Tokenizer
	doc_tokenizer_init(&td)
	defer doc_tokenizer_destroy(&td)
	doc := "a\\-b\xc3,x"
	doc_tokenizer_reset(&td, transmute([]u8)doc)
	tok: Token
	testing.expect(t, doc_tokenizer_next(&td, &tok))
	testing.expect_value(t, string(tok.text), "a-b\xc3")
	testing.expect_value(t, string(tok.tail), "\xc3,x")
	testing.expect(t, doc_tokenizer_next(&td, &tok))
	testing.expect_value(t, string(tok.text), "x")
	testing.expect_value(t, len(tok.tail), 0)
	testing.expect(t, !doc_tokenizer_next(&td, &tok))
	doc = "ab\xc3\x00\xa9"
	doc_tokenizer_reset(&td, transmute([]u8)doc)
	testing.expect(t, doc_tokenizer_next(&td, &tok))
	testing.expect_value(t, string(tok.text), "ab\xc3")
	testing.expect_value(t, string(tok.tail), "\x00\xa9")
	testing.expect(t, !doc_tokenizer_next(&td, &tok))
}

@(test)
byte_class_table :: proc(t: ^testing.T) {
	separators := 0
	dropped := 0
	spaces := 0
	for b in 0 ..< 256 {
		c := byte_classes(u8(b))
		if .Separator in c {
			separators += 1
		}
		if .Dropped in c {
			dropped += 1
		}
		if .Tag_Space in c {
			spaces += 1
		}
		if b >= 0x80 {
			testing.expect_value(t, c, Classes{.Term})
		}
		testing.expectf(t, c != {}, "byte %02x has no class", b)
	}
	testing.expect_value(t, separators, len(PROBE_SEPARATORS) - 1)
	testing.expect_value(t, dropped, len(PROBE_DROPPED) - 1)
	testing.expect_value(t, spaces, 6)
	testing.expect(t, is_doc_separator('-'))
	testing.expect(t, !is_doc_separator('_'))
	testing.expect(t, is_doc_dropped('\n'))
	testing.expect(t, is_tag_space('\v'))
	testing.expect(t, !is_tag_space(0xA0))
	testing.expect(t, is_query_break('\n'))
	testing.expect(t, !is_query_break('_'))
}

@(test)
wide_scan_matches_scalar :: proc(t: ^testing.T) {
	r := Rng{0x5CA7_0000_0000_0005}
	buf := make([]u8, 200)
	defer delete(buf)
	failures := 0
	pool := "abcXYZ019_\x80\xff\xc3"
	for round in 0 ..< 200_000 {
		n := rng_below(&r, len(buf) + 1)
		plainish := round % 3 != 0
		for i in 0 ..< n {
			if plainish && rng_below(&r, 12) != 0 {
				buf[i] = pool[rng_below(&r, len(pool))]
			} else {
				buf[i] = u8(rng_next(&r))
			}
		}
		from := rng_below(&r, n + 1)
		limit := from + rng_below(&r, n - from + 1)
		a := scan_plain_scalar(buf[:n], from, limit)
		b := scan_plain(buf[:n], from, limit)
		if a != b {
			failures += 1
		}
	}
	testing.expect_value(t, failures, 0)
	for b in 0 ..< 256 {
		one := [16]u8{}
		for &x in one {
			x = 'a'
		}
		one[7] = u8(b)
		want := scan_plain_scalar(one[:], 0, 16)
		testing.expect_value(t, scan_plain(one[:], 0, 16), want)
	}
}

@(test)
probe_query_term_breaks :: proc(t: ^testing.T) {
	for split, b in PROBE_QUERY_SPLITS {
		if b == 0 {
			testing.expect(t, split)
			testing.expect(t, .End in byte_classes(0))
			continue
		}
		testing.expectf(t, is_query_break(u8(b)) == split, "byte %02x: query break %v, reference %v", b, is_query_break(u8(b)), split)
	}
}

package text

import "core:slice"
import "core:strings"
import "core:testing"

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

utf8_of :: proc(cp: u32, out: ^[dynamic]u8) {
	buf: [4]u8
	w := encode_unit(cp, &buf)
	append(out, ..buf[:w])
}

Fixture :: struct {
	analyzer: Analyzer,
	stop:     Stop_Words,
	terms:    Terms,
}

fixture_init :: proc(f: ^Fixture, mode: Stop_Mode = .None, custom: []string = nil, stemmers: ^Stemmers = nil) {
	switch mode {
	case .Default:
		stop_words_default(&f.stop)
	case .None:
		stop_words_none(&f.stop)
	case .Custom:
		words := make([][]u8, len(custom), context.temp_allocator)
		for w, i in custom {
			words[i] = transmute([]u8)w
		}
		stop_words_custom(&f.stop, words)
	}
	analyzer_init(&f.analyzer, &f.stop, stemmers)
	terms_init(&f.terms)
}

fixture_destroy :: proc(f: ^Fixture) {
	analyzer_destroy(&f.analyzer)
	stop_words_destroy(&f.stop)
	terms_destroy(&f.terms)
}

fixture_run :: proc(f: ^Fixture, doc: string, field := DEFAULT_FIELD) -> u32 {
	return analyze(&f.analyzer, transmute([]u8)doc, field, &f.terms)
}

dump_terms :: proc(f: ^Fixture, allocator := context.temp_allocator) -> []string {
	seen := make([dynamic]string, 0, len(f.terms.list), allocator)
	buf := make([dynamic]u8, 0, 64, context.temp_allocator)
	for term in f.terms.list {
		clear(&buf)
		if !trie_form(term_bytes(&f.terms, term), &buf) {
			continue
		}
		if len(buf) == 0 {
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

term_list :: proc(f: ^Fixture, allocator := context.temp_allocator) -> []string {
	out := make([]string, len(f.terms.list), allocator)
	for term, i in f.terms.list {
		out[i] = term_string(&f.terms, term)
	}
	return out
}

expect_strings :: proc(t: ^testing.T, label: string, got: []string, want: []string) -> bool {
	if slice.equal(got, want) {
		return true
	}
	testing.expectf(t, false, "%s: got %d terms %v, want %d terms %v", label, len(got), escaped_list(got), len(want), escaped_list(want))
	return false
}

escaped_list :: proc(list: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for s, i in list {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_quoted_string(&b, s)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

without_stems :: proc(list: []string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(list), allocator)
	for s in list {
		if len(s) > 0 && s[0] == STEM_PREFIX {
			continue
		}
		append(&out, s)
	}
	return out[:]
}

hex_into :: proc(out: ^[dynamic]u8, value: u32, width: int) {
	digits := "0123456789abcdef"
	for i := width - 1; i >= 0; i -= 1 {
		append(out, digits[value >> uint(4 * i) & 0xF])
	}
}

probe_prefix :: proc(out: ^[dynamic]u8, lead: u8, cp: u32, width: int) {
	append(out, lead)
	hex_into(out, cp, width)
	append(out, 'x')
}

probe_token :: proc(out: ^[dynamic]u8, lead: u8, cp: u32, width: int) {
	probe_prefix(out, lead, cp, width)
	utf8_of(cp, out)
	append(out, 'x')
}

append_decimal :: proc(out: ^[dynamic]u8, value: int) {
	if value >= 10 {
		append_decimal(out, value / 10)
	}
	append(out, u8('0' + value % 10))
}

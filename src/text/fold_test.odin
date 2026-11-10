package text

import "core:slice"
import "core:testing"

Expected_Kind :: enum u8 {
	Identity,
	Mapped,
	Separator,
	Dropped,
}

bmp_expectation :: proc(cp: u32) -> (kind: Expected_Kind, mapped: string) {
	if _, found := slice.binary_search(PROBE_SEPARATORS[:], cp); found {
		return .Separator, ""
	}
	if _, found := slice.binary_search(PROBE_DROPPED[:], cp); found {
		return .Dropped, ""
	}
	index, found := slice.binary_search_by(PROBE_MAPPED[:], cp, proc(m: Probe_Mapped, key: u32) -> slice.Ordering {
		return slice.cmp(m.cp, key)
	})
	if found {
		return .Mapped, PROBE_MAPPED[index].term
	}
	return .Identity, ""
}

@(test)
probe_bmp_text_terms :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	doc := make([dynamic]u8, 0, 32)
	defer delete(doc)
	want := make([dynamic]u8, 0, 32)
	defer delete(want)
	compared := 0
	failures := 0
	for cp in u32(0) ..< 0x10000 {
		if cp >= 0xD800 && cp <= 0xDFFF {
			continue
		}
		clear(&doc)
		probe_token(&doc, 'k', cp, 4)
		terms_clear(&f.terms)
		fixture_run(&f, string(doc[:]), Field{stem = false})
		got := term_list(&f)
		clear(&want)
		probe_prefix(&want, 'k', cp, 4)
		kind, mapped := bmp_expectation(cp)
		ok := false
		switch kind {
		case .Separator:
			if cp == 0 {
				ok = len(got) == 1 && got[0] == string(want[:])
			} else {
				ok = len(got) == 2 && got[0] == string(want[:]) && got[1] == "x"
			}
		case .Dropped:
			append(&want, 'x')
			ok = len(got) == 1 && got[0] == string(want[:])
		case .Mapped:
			append(&want, mapped)
			append(&want, 'x')
			ok = len(got) == 1 && got[0] == string(want[:])
		case .Identity:
			utf8_of(cp, &want)
			append(&want, 'x')
			ok = len(got) == 1 && got[0] == string(want[:])
		}
		compared += 1
		if !ok {
			failures += 1
			if failures < 20 {
				testing.expectf(t, false, "U+%04X (%v): terms %v", cp, kind, escaped_list(got))
			}
		}
	}
	testing.expect_value(t, compared, PROBE_BMP_CODE_POINTS)
	testing.expect_value(t, failures, 0)
}

@(test)
probe_bmp_tag_values :: proc(t: ^testing.T) {
	value := make([dynamic]u8, 0, 32)
	defer delete(value)
	got := make([dynamic]u8, 0, 32)
	defer delete(got)
	want := make([dynamic]u8, 0, 32)
	defer delete(want)
	differences := make(map[u32]Probe_Tag)
	defer delete(differences)
	for d in PROBE_TAG_DIFFERENCES {
		differences[d.cp] = d
	}
	failures := 0
	for cp in u32(0) ..< 0x10000 {
		if cp >= 0xD800 && cp <= 0xDFFF {
			continue
		}
		clear(&want)
		probe_prefix(&want, 'k', cp, 4)
		if d, found := differences[cp]; found {
			if d.split {
				testing.expect(t, cp == 0 || cp == ',')
				continue
			}
			append(&want, d.value)
		} else {
			kind, mapped := bmp_expectation(cp)
			#partial switch kind {
			case .Mapped:
				append(&want, mapped)
			case:
				utf8_of(cp, &want)
			}
		}
		append(&want, 'x')
		clear(&value)
		probe_token(&value, 'k', cp, 4)
		clear(&got)
		fold(value[:], nil, &got)
		if string(got[:]) != string(want[:]) {
			failures += 1
			if failures < 20 {
				testing.expectf(t, false, "tag U+%04X: %q want %q", cp, string(got[:]), string(want[:]))
			}
		}
	}
	testing.expect_value(t, failures, 0)
}

@(test)
probe_supplementary_planes :: proc(t: ^testing.T) {
	token := make([dynamic]u8, 0, 32)
	defer delete(token)
	folded := make([dynamic]u8, 0, 32)
	defer delete(folded)
	trie := make([dynamic]u8, 0, 32)
	defer delete(trie)
	want := make([dynamic]u8, 0, 32)
	defer delete(want)
	for p in PROBE_SUPPLEMENTARY {
		clear(&token)
		probe_token(&token, 'q', p.cp, 6)
		clear(&folded)
		fold(token[:], nil, &folded)
		clear(&want)
		probe_prefix(&want, 'q', p.cp, 6)
		append(&want, p.tag)
		testing.expectf(t, string(folded[:]) == string(want[:]), "U+%06X folds to %q, reference %q", p.cp, string(folded[:]), string(want[:]))
		clear(&trie)
		testing.expect(t, trie_form(folded[:], &trie))
		clear(&want)
		probe_prefix(&want, 'q', p.cp, 6)
		append(&want, p.trie)
		testing.expectf(t, string(trie[:]) == string(want[:]), "U+%06X dictionary form %q, reference %q", p.cp, string(trie[:]), string(want[:]))
	}
	testing.expect_value(t, len(PROBE_SUPPLEMENTARY), 1851)
}

@(test)
probe_invalid_utf8 :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	tok := make([dynamic]u8, 0, 32)
	defer delete(tok)
	doc := make([dynamic]u8, 0, 64)
	defer delete(doc)
	field := make([dynamic]u8, 0, 64)
	defer delete(field)
	tail := make([dynamic]u8, 0, 64)
	defer delete(tail)
	trie := make([dynamic]u8, 0, 32)
	defer delete(trie)
	tag := make([dynamic]u8, 0, 32)
	defer delete(tag)
	for p, i in PROBE_INVALID {
		clear(&tok)
		append(&tok, 'w', u8('0' + i / 100), u8('0' + i / 10 % 10), u8('0' + i % 10), 'x')
		append(&tok, p.input)
		append(&tok, 'x')
		clear(&doc)
		append(&doc, ..tok[:])
		append(&doc, " zend")
		append_decimal(&doc, i)
		terms_clear(&f.terms)
		fixture_run(&f, string(doc[:]), Field{stem = false})
		found := false
		for term in f.terms.list {
			b := term_bytes(&f.terms, term)
			if len(b) < 5 || string(b[:5]) != string(tok[:5]) {
				continue
			}
			found = true
			clear(&trie)
			trie_form(b, &trie)
			testing.expectf(t, string(trie[5:]) == p.trie, "case %d %x: dictionary form %x, reference %x", i, transmute([]u8)p.input, trie[5:], transmute([]u8)p.trie)
		}
		testing.expectf(t, found, "case %d: no term starts with the case prefix", i)
		clear(&field)
		append(&field, ..tok[:])
		append(&field, ",zend")
		append_decimal(&field, i)
		cut := len(field)
		for b, k in field {
			if b == ',' || b == 0 {
				cut = k
				break
			}
		}
		clear(&tail)
		append(&tail, 0)
		if cut + 1 < len(field) {
			append(&tail, ..field[cut + 1:])
		}
		clear(&tag)
		fold(field[:cut], tail[:], &tag)
		testing.expectf(t, string(tag[5:]) == p.tag, "case %d %x: tag value %x, reference %x", i, transmute([]u8)p.input, tag[5:], transmute([]u8)p.tag)
	}
	testing.expect_value(t, len(PROBE_INVALID), 63)
}

@(test)
probe_overread_documents :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	for p in PROBE_OVERREAD {
		terms_clear(&f.terms)
		fixture_run(&f, p.doc, Field{stem = false})
		got := dump_terms(&f)
		if p.undefined {
			again: Fixture
			fixture_init(&again)
			fixture_run(&again, p.doc, Field{stem = false})
			expect_strings(t, p.doc, dump_terms(&again), got)
			fixture_destroy(&again)
			continue
		}
		expect_strings(t, p.doc, got, p.terms)
	}
}

@(test)
fold_is_idempotent :: proc(t: ^testing.T) {
	once := make([dynamic]u8, 0, 16)
	defer delete(once)
	twice := make([dynamic]u8, 0, 16)
	defer delete(twice)
	raw := make([dynamic]u8, 0, 8)
	defer delete(raw)
	failures := 0
	for cp in u32(1) ..< 0x110000 {
		clear(&raw)
		utf8_of(cp, &raw)
		clear(&once)
		fold(raw[:], nil, &once)
		clear(&twice)
		fold(once[:], nil, &twice)
		if string(once[:]) != string(twice[:]) {
			failures += 1
			if failures < 10 {
				testing.expectf(t, false, "U+%04X: fold %x then %x", cp, once[:], twice[:])
			}
		}
	}
	testing.expect_value(t, failures, 0)
}

@(test)
lower_table_shape :: proc(t: ^testing.T) {
	mapped := 0
	seq: [3]u32
	for cp in u32(0) ..< 0x110000 {
		n := lower_full(cp, &seq)
		if n != 1 || seq[0] != cp {
			mapped += 1
		}
	}
	testing.expect_value(t, mapped, LOWER_MAPPED)
	testing.expect_value(t, UNICODE_VERSION, "17.0.0")
	n := lower_full(0x130, &seq)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, seq[0], 0x69)
	testing.expect_value(t, seq[1], 0x307)
	testing.expect_value(t, lower_simple(0x3A3), 0x3C3)
	testing.expect_value(t, lower_simple(0x3C2), 0x3C2)
	testing.expect_value(t, lower_simple(0xDF), 0xDF)
	testing.expect_value(t, lower_simple(0x1E9E), 0xDF)
	testing.expect_value(t, lower_simple(0x1C5), 0x1C6)
	testing.expect_value(t, lower_simple(0x212A), 'k')
	testing.expect_value(t, lower_simple(0x10400), 0x10428)
	testing.expect_value(t, lower_simple(0x1E900), 0x1E922)
	testing.expect_value(t, lower_simple(0x13A0), 0xAB70)
	testing.expect_value(t, lower_simple(0xAB70), 0xAB70)
	testing.expect_value(t, lower_simple(0x1C90), 0x10D0)
	testing.expect_value(t, lower_simple(0xA7CB), 0x0264)
	testing.expect_value(t, lower_simple(0x10FFFF), 0x10FFFF)
	testing.expect_value(t, lower_simple(0x1FFFFF), 0x1FFFFF)
}

@(test)
decoder_round_trip :: proc(t: ^testing.T) {
	buf: [4]u8
	failures := 0
	for cp in u32(0) ..< CP_LIMIT {
		w := encode_unit(cp, &buf)
		got, next := decode_unit(buf[:w], nil, 0)
		if got != cp || next != w {
			failures += 1
		}
	}
	testing.expect_value(t, failures, 0)
}

@(test)
decoder_reads_past_the_token :: proc(t: ^testing.T) {
	cp, next := decode_unit([]u8{0xC3}, []u8{','}, 0)
	testing.expect_value(t, cp, 0xEC)
	testing.expect_value(t, next, 2)
	cp, next = decode_unit([]u8{0xF0}, []u8{'x'}, 0)
	testing.expect_value(t, cp, 0x38000)
	testing.expect_value(t, next, 4)
	cp, next = decode_unit([]u8{0x80, 0x80}, nil, 0)
	testing.expect_value(t, cp, 0)
	cp, _ = decode_unit([]u8{0xFF, 0xBF, 0xBF, 0xBF}, nil, 0)
	testing.expect_value(t, cp, 0x1FFFFF)
	out := make([dynamic]u8)
	defer delete(out)
	fold(transmute([]u8)string("w\x80\x80x"), nil, &out)
	testing.expect_value(t, string(out[:]), "w")
	clear(&out)
	fold(transmute([]u8)string("pre\xf0\x90\x80\x80post"), nil, &out)
	testing.expect_value(t, string(out[:]), "pre\xf0\x90\x80\x80post")
	trie := make([dynamic]u8)
	defer delete(trie)
	testing.expect(t, trie_form(out[:], &trie))
	testing.expect_value(t, string(trie[:]), "pre")
}

@(test)
dictionary_unit_limit :: proc(t: ^testing.T) {
	word := make([dynamic]u8)
	defer delete(word)
	out := make([dynamic]u8)
	defer delete(out)
	for _ in 0 ..< TRIE_UNIT_LIMIT {
		append(&word, 'a')
	}
	testing.expect(t, trie_form(word[:], &out))
	append(&word, 'a')
	clear(&out)
	testing.expect(t, !trie_form(word[:], &out))
	testing.expect_value(t, unit_count(word[:]), TRIE_UNIT_LIMIT + 1)
}

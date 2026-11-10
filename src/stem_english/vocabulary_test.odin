package stem_english

import "core:strings"
import "core:testing"

VOCABULARY :: #load("testdata/voc.txt", string)

EXPECTED :: #load("testdata/output.txt", string)

REFERENCE :: #load("testdata/reference.txt", string)

VOCABULARY_WORDS :: 42_603

REFERENCE_WORDS :: 5_089

stem_text :: proc(word: string, buf: ^[dynamic]u8) -> string {
	if len(buf) < len(word) {
		resize(buf, len(word))
	}
	s, ok := stem(transmute([]u8)word, buf[:])
	if !ok {
		return "<no room>"
	}
	return string(s)
}

@(test)
snowball_vocabulary :: proc(t: ^testing.T) {
	words := VOCABULARY
	stems := EXPECTED
	buf := make([dynamic]u8, 64)
	defer delete(buf)
	count := 0
	agree := 0
	reported := 0
	for word in strings.split_lines_iterator(&words) {
		want, ok := strings.split_lines_iterator(&stems)
		if !ok {
			testing.expectf(t, false, "output list ends before word %q", word)
			break
		}
		count += 1
		got := stem_text(word, &buf)
		if got == want {
			agree += 1
		} else if reported < 40 {
			reported += 1
			testing.expectf(t, false, "%q: stem %q, want %q", word, got, want)
		}
	}
	testing.expect_value(t, count, VOCABULARY_WORDS)
	testing.expect_value(t, agree, count)
}

@(test)
reference_stems :: proc(t: ^testing.T) {
	lines := REFERENCE
	buf := make([dynamic]u8, 64)
	defer delete(buf)
	count := 0
	agree := 0
	for line in strings.split_lines_iterator(&lines) {
		space := strings.index_byte(line, ' ')
		if !testing.expectf(t, space > 0, "malformed reference line %q", line) {
			continue
		}
		word := line[:space]
		want := line[space + 1:]
		count += 1
		got := stem_text(word, &buf)
		if testing.expectf(t, got == want, "%q: stem %q, reference %q", word, got, want) {
			agree += 1
		}
	}
	testing.expect_value(t, count, REFERENCE_WORDS)
	testing.expect_value(t, agree, count)
}

package glob

import "core:testing"

@(test)
nocase_all_byte_pairs :: proc(t: ^testing.T) {
	for first in 0..<256 {
		for second in 0..<256 {
			a, b := u8(first), u8(second)
			if a >= 'A' && a <= 'Z' {
				a += 'a' - 'A'
			}
			if b >= 'A' && b <= 'Z' {
				b += 'a' - 'A'
			}
			testing.expect(t, glob_byte_equal(u8(first), u8(second), true) == (a == b))
		}
	}
}

@(test)
oracle_regressions :: proc(t: ^testing.T) {
	fixtures := []struct {
		pattern, text: string,
		matched, nocase: bool,
	}{
		{"", "", true, true},
		{"", "a", false, false},
		{"*", "", false, false},
		{"**", "", false, false},
		{"a*", "a", true, true},
		{"a**", "a", true, true},
		{"*a", "a", true, true},
		{"*?", "a", true, true},
		{"?", "\x00", true, true},
		{"\x00", "\x00", true, true},
		{"a\x00b", "a\x00b", true, true},
		{"*\x00*", "a\x00b", true, true},
		{"[", "a", false, false},
		{"[]", "a", false, false},
		{"[^]", "\x00", true, true},
		{"[^", "\xff", true, true},
		{"[a", "a", true, true},
		{"[a", "A", false, true},
		{"[a-", "-", true, true},
		{"[a-]", "^", true, true},
		{"[a-]", "A", false, true},
		{"[!a]", "!", true, true},
		{"[!a]", "b", false, false},
		{"[\\a]", "A", false, false},
		{"[\\a]", "a", true, true},
		{"[\\A]", "a", false, false},
		{"[\\A]", "A", true, true},
		{"[\\]", "]", true, true},
		{"[\\", "\\", true, true},
		{"\\", "\\", true, true},
		{"\\a", "A", false, true},
		{"[a-Z]", "a", true, false},
		{"[A-z]", "_", true, false},
		{"[a-\\c]", "^", true, true},
		{"[a\\]x]Z", "]Z", true, true},
		{"[a\\]x]Z", "ax]Z", false, false},
		{"\xff", "\xff", true, true},
		{"[\xff]", "\xff", true, true},
		{"[\x00-\xff]", "\x00", true, false},
		{"[\x00-\xff]", "\xff", true, false},
		{"[\x00-\xff]", "\x80", false, false},
		{"[\x80-\x81]", "\x80", true, true},
		{"[\x7f-\x80]", "\x40", true, false},
		{"[\x80-\xff]", "\xfe", true, true},
		{"[\x80-\xff]", "\x00", false, false},
	}
	for fixture in fixtures {
		pattern := transmute([]u8)fixture.pattern
		text := transmute([]u8)fixture.text
		testing.expect(t, glob_match(pattern, text, false) == fixture.matched)
		testing.expect(t, glob_match(pattern, text, true) == fixture.nocase)
	}
}

@(test)
star_run_cutoff :: proc(t: ^testing.T) {
	pattern: [2003]u8
	text: [1001]u8
	for index in 0..<len(text) {
		pattern[index * 2] = '*'
		pattern[index * 2 + 1] = 'a'
		text[index] = 'a'
	}
	for count in 999..=1001 {
		expected := count <= 1000
		testing.expect(t, glob_match(pattern[:count * 2], text[:count], false) == expected)
		testing.expect(t, glob_match(pattern[:count * 2], text[:count], true) == expected)
		pattern[count * 2] = '*'
		testing.expect(t, glob_match(pattern[:count * 2 + 1], text[:count], false) == expected)
		testing.expect(t, glob_match(pattern[:count * 2 + 1], text[:count], true) == expected)
	}
}

@(test)
fixed_prefix_handoff_regressions :: proc(t: ^testing.T) {
	fixtures := []struct {
		pattern, text: string,
		matched: bool,
	}{
		{"[a]b*c", "abxxc", true},
		{"[a]b*c", "xbac", false},
		{"[a]*b*c", "axybzzc", true},
		{"[a]*b*c", "axybzzz", false},
		{"[a]\\?*a*b", "a?aaab", true},
		{"X[a]\\?*a*b", "Xa?aaab", true},
		{"?[a]***", "ba", true},
		{"?[a]***", "bx", false},
		{"[a]\\*", "a*", true},
		{"[a]\\", "a\\", true},
		{"[^x]?\\A*Z", "a?AhelloZ", true},
	}
	for fixture in fixtures {
		pattern := transmute([]u8)fixture.pattern
		text := transmute([]u8)fixture.text
		testing.expect(t, glob_match(pattern, text, false) == fixture.matched)
		testing.expect(t, glob_match(pattern, text, true) == fixture.matched)
	}
	pattern: [2006]u8
	text: [1002]u8
	pattern[0] = '['
	pattern[1] = 'b'
	pattern[2] = ']'
	text[0] = 'b'
	for index in 0..<1001 {
		pattern[index * 2 + 3] = '*'
		pattern[index * 2 + 4] = 'a'
		text[index + 1] = 'a'
	}
	for count in 999..=1001 {
		expected := count <= 1000
		testing.expect(t, glob_match(pattern[:count * 2 + 3], text[:count + 1], false) == expected)
		testing.expect(t, glob_match(pattern[:count * 2 + 3], text[:count + 1], true) == expected)
	}
}

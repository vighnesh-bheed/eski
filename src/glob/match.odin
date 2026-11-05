package glob

glob_ascii_fold :: #force_inline proc "contextless" (value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' {
		return value | 0x20
	}
	return value
}

glob_byte_equal :: #force_inline proc "contextless" (a, b: u8, $nocase: bool) -> bool {
	when nocase {
		return glob_ascii_fold(a) == glob_ascii_fold(b)
	}
	return a == b
}

glob_signed_byte :: #force_inline proc "contextless" (value: u8) -> i16 {
	return i16(i8(value))
}

glob_class_match :: proc "contextless" (pattern: []u8, offset: int, value: u8, $nocase: bool) -> (matched: bool, next: int) #no_bounds_check {
	cursor := offset + 1
	negated := false
	if cursor < len(pattern) && pattern[cursor] == '^' {
		negated = true
		cursor += 1
	}
	found := false
	for cursor < len(pattern) {
		member := pattern[cursor]
		remaining := len(pattern) - cursor
		if member == '\\' && remaining >= 2 {
			found = found || pattern[cursor + 1] == value
			cursor += 2
		} else if member == ']' {
			return found != negated, cursor + 1
		} else if remaining >= 3 && pattern[cursor + 1] == '-' {
			lower := member
			upper := pattern[cursor + 2]
			if glob_signed_byte(lower) > glob_signed_byte(upper) {
				lower, upper = upper, lower
			}
			when nocase {
				folded := glob_ascii_fold(value)
				found = found || (glob_ascii_fold(lower) <= folded && folded <= glob_ascii_fold(upper))
			} else {
				signed := glob_signed_byte(value)
				found = found || (glob_signed_byte(lower) <= signed && signed <= glob_signed_byte(upper))
			}
			cursor += 3
		} else {
			found = found || glob_byte_equal(member, value, nocase)
			cursor += 1
		}
	}
	return found != negated, cursor
}


glob_is_special :: #force_inline proc "contextless" (value: u8) -> bool {
	switch value {
	case '*', '?', '[', '\\':
		return true
	case:
		return false
	}
}

glob_match_retry :: #force_no_inline proc "contextless" (pattern: []u8, text: []u8, $nocase: bool) -> bool #no_bounds_check {
	if len(text) == 0 {
		return len(pattern) == 0
	}
	pattern_offset := 0
	text_offset := 0
	star_pattern := -1
	star_text := 0
	star_count := 0
	for {
		for pattern_offset < len(pattern) && text_offset < len(text) {
			member := pattern[pattern_offset]
			if glob_is_special(member) {
				break
			}
			if !glob_byte_equal(member, text[text_offset], nocase) {
				break
			}
			pattern_offset += 1
			text_offset += 1
		}
		if text_offset == len(text) {
			for pattern_offset < len(pattern) && pattern[pattern_offset] == '*' {
				pattern_offset += 1
			}
			return pattern_offset == len(pattern)
		}
		if pattern_offset < len(pattern) {
			switch pattern[pattern_offset] {
			case '*':
				for pattern_offset < len(pattern) && pattern[pattern_offset] == '*' {
					pattern_offset += 1
				}
				if pattern_offset == len(pattern) {
					return true
				}
				star_count += 1
				if star_count > 1000 {
					return false
				}
				star_pattern = pattern_offset
				star_text = text_offset
				continue
			case '?':
				pattern_offset += 1
				text_offset += 1
				continue
			case '[':
				matched, next := glob_class_match(pattern, pattern_offset, text[text_offset], nocase)
				if matched {
					pattern_offset = next
					text_offset += 1
					continue
				}
			case '\\':
				next := pattern_offset + 1
				literal := u8('\\')
				if next < len(pattern) {
					literal = pattern[next]
					next += 1
				}
				if glob_byte_equal(literal, text[text_offset], nocase) {
					pattern_offset = next
					text_offset += 1
					continue
				}
			}
		}
		if star_pattern < 0 || star_text == len(text) {
			return false
		}
		star_text += 1
		text_offset = star_text
		pattern_offset = star_pattern
	}
}

glob_match_fixed_prefix :: #force_no_inline proc "contextless" (pattern: []u8, text: []u8, $nocase: bool) -> bool #no_bounds_check {
	if len(text) == 0 {
		return len(pattern) == 0
	}
	pattern_offset := 0
	text_offset := 0
	for pattern_offset < len(pattern) && text_offset < len(text) {
		switch pattern[pattern_offset] {
		case '*':
			next := pattern_offset + 1
			for next < len(pattern) && pattern[next] == '*' {
				next += 1
			}
			if next == len(pattern) {
				return true
			}
			return glob_match_retry(pattern[pattern_offset:], text[text_offset:], nocase)
		case '?':
			pattern_offset += 1
		case '[':
			matched, next := glob_class_match(pattern, pattern_offset, text[text_offset], nocase)
			if !matched {
				return false
			}
			pattern_offset = next
		case '\\':
			pattern_offset += 1
			literal := u8('\\')
			if pattern_offset < len(pattern) {
				literal = pattern[pattern_offset]
				pattern_offset += 1
			}
			if !glob_byte_equal(literal, text[text_offset], nocase) {
				return false
			}
		case:
			if !glob_byte_equal(pattern[pattern_offset], text[text_offset], nocase) {
				return false
			}
			pattern_offset += 1
		}
		text_offset += 1
	}
	if text_offset == len(text) {
		for pattern_offset < len(pattern) && pattern[pattern_offset] == '*' {
			pattern_offset += 1
		}
		return pattern_offset == len(pattern)
	}
	return false
}

glob_match_mode :: #force_no_inline proc "contextless" (pattern: []u8, text: []u8, $nocase: bool) -> bool #no_bounds_check {
	if len(pattern) != 0 && pattern[0] != '*' {
		return glob_match_fixed_prefix(pattern, text, nocase)
	}
	return glob_match_retry(pattern, text, nocase)
}

glob_match_prefix :: proc "contextless" (pattern: []u8, text: []u8, $nocase: bool) -> bool #no_bounds_check {
	if len(text) == 0 {
		return len(pattern) == 0
	}
	limit := min(len(pattern), len(text))
	offset := 0
	for offset < limit {
		member := pattern[offset]
		if glob_is_special(member) {
			break
		}
		if !glob_byte_equal(member, text[offset], nocase) {
			return false
		}
		offset += 1
	}
	if offset == len(text) {
		for offset < len(pattern) && pattern[offset] == '*' {
			offset += 1
		}
		return offset == len(pattern)
	}
	if offset == len(pattern) {
		return false
	}
	if pattern[offset] == '*' {
		next := offset + 1
		for next < len(pattern) && pattern[next] == '*' {
			next += 1
		}
		if next == len(pattern) {
			return true
		}
	}
	return glob_match_mode(pattern[offset:], text[offset:], nocase)
}

glob_match :: #force_inline proc "contextless" (pattern: []u8, text: []u8, nocase: bool) -> bool {
	if nocase {
		return glob_match_prefix(pattern, text, true)
	}
	return glob_match_prefix(pattern, text, false)
}

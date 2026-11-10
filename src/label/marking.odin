package label

import "core:strings"

Parse_Error :: enum u8 {
	None,
	Empty,
	Too_Long,
	Invalid_Byte,
	Empty_Level,
	Unknown_Level,
	Bad_Separator,
	Empty_Compartment,
	Unknown_Compartment,
	Duplicate_Compartment,
}

Parse_Failure :: struct {
	error:  Parse_Error,
	offset: int,
	length: int,
}

marking_byte :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == '\t' || b >= 0x20 && b <= 0x7E
}

slash_from :: proc "contextless" (text: string, from: int) -> int {
	for i in from ..< len(text) {
		if text[i] == '/' {
			return i
		}
	}
	return len(text)
}

trimmed :: proc "contextless" (text: string, from, to: int) -> (at: int, length: int) {
	first := from
	for first < to && is_space(text[first]) {
		first += 1
	}
	if first == to {
		return from, 0
	}
	last := to
	for is_space(text[last - 1]) {
		last -= 1
	}
	return first, last - first
}

parse :: proc "contextless" (c: ^Config, text: string) -> (l: Label, failure: Parse_Failure) {
	if len(text) > MARKING_MAX {
		return {}, {.Too_Long, MARKING_MAX, len(text) - MARKING_MAX}
	}
	for i in 0 ..< len(text) {
		if !marking_byte(text[i]) {
			return {}, {.Invalid_Byte, i, 1}
		}
	}
	slash := slash_from(text, 0)
	at, n := trimmed(text, 0, slash)
	if n == 0 {
		if slash == len(text) {
			return {}, {.Empty, 0, 0}
		}
		return {}, {.Empty_Level, at, 0}
	}
	level, found := config_find_level(c, text[:slash])
	if !found {
		return {}, {.Unknown_Level, at, n}
	}
	l.level = u8(level)
	if slash == len(text) {
		return l, {}
	}
	if slash + 1 == len(text) || text[slash + 1] != '/' {
		return {}, {.Bad_Separator, slash, 1}
	}
	start := slash + 2
	for {
		end := slash_from(text, start)
		at, n = trimmed(text, start, end)
		if n == 0 {
			return {}, {.Empty_Compartment, at, 0}
		}
		compartment, known := config_find_compartment(c, text[start:end])
		if !known {
			return {}, {.Unknown_Compartment, at, n}
		}
		if compartment_has(l, compartment) {
			return {}, {.Duplicate_Compartment, at, n}
		}
		compartment_add(&l, compartment)
		if end == len(text) {
			return l, {}
		}
		start = end + 1
	}
}

format_length :: proc "contextless" (c: ^Config, l: Label) -> int {
	if !config_valid(c, l) {
		return -1
	}
	n := int(c.levels[l.level].length)
	count := 0
	for i := compartment_next(l, 0); i < COMPARTMENT_LIMIT; i = compartment_next(l, i + 1) {
		n += int(c.compartments[i].length) + (2 if count == 0 else 1)
		count += 1
	}
	return n
}

format_builder :: proc(b: ^strings.Builder, c: ^Config, l: Label) -> bool {
	if !config_valid(c, l) {
		return false
	}
	strings.write_string(b, config_name(c, c.levels[l.level]))
	count := 0
	for i := compartment_next(l, 0); i < COMPARTMENT_LIMIT; i = compartment_next(l, i + 1) {
		strings.write_string(b, "//" if count == 0 else "/")
		strings.write_string(b, config_name(c, c.compartments[i]))
		count += 1
	}
	return true
}

format :: proc(c: ^Config, l: Label, allocator := context.allocator) -> (text: string, ok: bool) {
	n := format_length(c, l)
	if n < 0 {
		return "", false
	}
	b, err := strings.builder_make_len_cap(0, n, allocator)
	if err != nil {
		return "", false
	}
	format_builder(&b, c, l)
	return strings.to_string(b), true
}

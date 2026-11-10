package ftindex

import "core:c"
import "core:c/libc"
import "core:math"
import "../doctable"
import "../numindex"
import "../stem_english"
import "../text"

NUMBER_TEXT_MAX :: 1024

FAST_DIGITS :: 19

FAST_EXPONENT_MAX :: 308

FAST_EXPONENT_MIN :: -342

EXPONENT_CLAMP :: 1_000_000

Decimal_Shape :: struct {
	decimal:     bool,
	significant: int,
	exponent:    int,
	nonzero:     bool,
}

decimal_shape :: proc "contextless" (s: string) -> (shape: Decimal_Shape) {
	i := 0
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i += 1
	}
	if i + 1 < len(s) && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X') {
		return
	}
	digits := 0
	leading := true
	fraction := 0
	seen_point := false
	for i < len(s) {
		ch := s[i]
		if ch == '.' {
			if seen_point {
				return
			}
			seen_point = true
			i += 1
			continue
		}
		if ch < '0' || ch > '9' {
			break
		}
		digits += 1
		if seen_point {
			fraction += 1
		}
		if ch != '0' {
			leading = false
			shape.nonzero = true
		}
		if !leading {
			shape.significant += 1
		}
		i += 1
	}
	if digits == 0 {
		return
	}
	exponent := 0
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		negative := false
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			negative = s[i] == '-'
			i += 1
		}
		any := false
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			exponent = min(exponent * 10 + int(s[i] - '0'), EXPONENT_CLAMP)
			any = true
			i += 1
		}
		if !any {
			return
		}
		if negative {
			exponent = -exponent
		}
	}
	if i != len(s) {
		return
	}
	shape.decimal = true
	shape.exponent = exponent - fraction
	return
}

is_c_space :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == ' ' || (b >= '\t' && b <= '\r')
}

number_parse :: proc(value: string) -> (number: f64, ok: bool) {
	if len(value) == 0 || len(value) >= NUMBER_TEXT_MAX || is_c_space(value[0]) {
		return 0, false
	}
	buf: [NUMBER_TEXT_MAX]u8
	copy(buf[:], value)
	buf[len(value)] = 0
	cs := cstring(raw_data(buf[:]))
	end: [^]c.char
	libc.errno()^ = 0
	v := f64(libc.strtod(cs, &end))
	range_error := libc.errno()^ == libc.ERANGE
	consumed := int(uintptr(rawptr(end)) - uintptr(rawptr(cs)))
	if consumed != len(value) || math.is_nan(v) {
		return 0, false
	}
	if !range_error {
		return v, true
	}
	shape := decimal_shape(value)
	if !shape.decimal {
		return 0, false
	}
	effective := shape.exponent + max(0, shape.significant - FAST_DIGITS)
	if math.is_inf(v) {
		return v, shape.significant <= FAST_DIGITS && shape.exponent <= FAST_EXPONENT_MAX
	}
	if shape.nonzero && effective < FAST_EXPONENT_MIN {
		return 0, false
	}
	return v, true
}

document_score :: proc(value: string, present: bool, fallback: f32) -> f32 {
	if !present {
		return fallback
	}
	v, ok := number_parse(value)
	if !ok {
		return fallback
	}
	return f32(v)
}

frequency_weight :: proc "contextless" (weight: f64) -> u32 {
	return doctable.frequency_weight(weight)
}

value_limit :: proc "contextless" (value: []u8) -> int {
	for b, i in value {
		if b == 0 {
			return i
		}
	}
	return len(value)
}

Tag_Pieces :: struct {
	bytes: [dynamic]u8,
	ends:  [dynamic]int,
	work:  [dynamic]u8,
}

tag_pieces_init :: proc(t: ^Tag_Pieces, allocator := context.allocator) {
	t.bytes = make([dynamic]u8, allocator)
	t.ends = make([dynamic]int, allocator)
	t.work = make([dynamic]u8, allocator)
}

tag_pieces_destroy :: proc(t: ^Tag_Pieces) {
	delete(t.bytes)
	delete(t.ends)
	delete(t.work)
	t^ = {}
}

tag_pieces_clear :: proc(t: ^Tag_Pieces) {
	clear(&t.bytes)
	clear(&t.ends)
}

tag_piece :: proc "contextless" (t: ^Tag_Pieces, i: int) -> string {
	start := 0 if i == 0 else t.ends[i - 1]
	return string(t.bytes[start:t.ends[i]])
}

tag_piece_count :: proc "contextless" (t: ^Tag_Pieces) -> int {
	return len(t.ends)
}

tag_has :: proc(t: ^Tag_Pieces, piece: string) -> bool {
	for i in 0 ..< len(t.ends) {
		if tag_piece(t, i) == piece {
			return true
		}
	}
	return false
}

tag_split :: proc(t: ^Tag_Pieces, value: []u8, separator: u8, case_sensitive: bool, index_empty: bool) {
	n := value_limit(value)
	resize(&t.work, n)
	work := t.work[:]
	copy(work, value[:n])
	for &b in work {
		if b == separator {
			b = 0
		}
	}
	start := 0
	for i in 0 ..= n {
		if i < n && work[i] != 0 {
			continue
		}
		lo, hi := start, i
		start = i + 1
		for lo < hi && text.is_tag_space(work[lo]) {
			lo += 1
		}
		for hi > lo && text.is_tag_space(work[hi - 1]) {
			hi -= 1
		}
		if hi == lo && !index_empty {
			continue
		}
		mark := len(t.bytes)
		if case_sensitive {
			append(&t.bytes, ..work[lo:hi])
		} else {
			text.fold(work[lo:hi], work[hi:], &t.bytes)
		}
		piece := string(t.bytes[mark:])
		if tag_has(t, piece) {
			resize(&t.bytes, mark)
			continue
		}
		append(&t.ends, len(t.bytes))
	}
}

range_bounds :: proc "contextless" (min_value, max_value: f64, min_open, max_open: bool) -> (lo, hi: numindex.Bound) {
	lo = numindex.Bound{value = min_value, exclusive = min_open}
	hi = numindex.Bound{value = max_value, exclusive = max_open}
	return
}

install_stemmers :: proc "contextless" (s: ^text.Stemmers) {
	s^ = {}
	s[.English] = stem_english.stem
}

document_language :: proc "contextless" (value: string, present: bool, fallback: text.Language) -> text.Language {
	if !present {
		return fallback
	}
	return text.document_language(transmute([]u8)value, fallback)
}

package rdb

import "base:intrinsics"
import "base:runtime"
import "core:strconv"

parse_double :: proc "contextless" (s: []u8) -> (f64, bool) {
	if len(s) == 0 || len(s) > 512 {
		return 0, false
	}
	for c in s {
		switch c {
		case '0' ..= '9', '.', '+', '-', 'e', 'E':
		case 'i', 'I', 'n', 'N', 'f', 'F', 't', 'T', 'y', 'Y', 'a', 'A':
		case:
			return 0, false
		}
	}
	context = runtime.default_context()
	value, good := strconv.parse_f64(string(s))
	if !good {
		return 0, false
	}
	return value, true
}

@(private)
is_c_space :: proc "contextless" (c: u8) -> bool {
	switch c {
	case ' ', '\t', '\n', '\v', '\f', '\r':
		return true
	}
	return false
}

@(private)
is_decimal_digit :: #force_inline proc "contextless" (c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
hex_digit_value :: proc "contextless" (c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

@(private)
match_word :: proc "contextless" (s: []u8, word: string) -> bool {
	if len(s) < len(word) {
		return false
	}
	for i in 0 ..< len(word) {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != word[i] {
			return false
		}
	}
	return true
}

@(private)
exponent_value :: proc "contextless" (s: []u8) -> (value: int, used: int) {
	i := 0
	negative := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		negative = s[i] == '-'
		i += 1
	}
	start := i
	for i < len(s) && is_decimal_digit(s[i]) {
		if value < 100000 {
			value = value * 10 + int(s[i] - '0')
		}
		i += 1
	}
	if i == start {
		return 0, 0
	}
	if negative {
		value = -value
	}
	return value, i
}

@(private)
compose_float :: proc "contextless" (mantissa: u64, sticky: bool, exponent: int) -> f64 {
	if mantissa == 0 {
		return 0
	}
	lead := int(intrinsics.count_leading_zeros(mantissa))
	top := mantissa << uint(lead)
	e := exponent - lead + 63
	if e > 1023 {
		return transmute(f64)u64(0x7FF0000000000000)
	}
	keep := 53
	if e < -1022 {
		keep = 1075 + e
	}
	if keep < 0 {
		return 0
	}
	drop := uint(64 - keep)
	wide := u128(top)
	q := u64(wide >> drop)
	rest := wide & ((u128(1) << drop) - 1)
	half := u128(1) << (drop - 1)
	if rest > half || (rest == half && (sticky || q & 1 == 1)) {
		q += 1
	}
	if e < -1022 {
		return transmute(f64)q
	}
	if q == 1 << 53 {
		q >>= 1
		e += 1
	}
	if e > 1023 {
		return transmute(f64)u64(0x7FF0000000000000)
	}
	return transmute(f64)(u64(e + 1023) << 52 | q & (1 << 52 - 1))
}

@(private)
parse_hex_magnitude :: proc "contextless" (s: []u8) -> (f64, bool) {
	i := 0
	mantissa: u64
	sticky := false
	exponent := 0
	digits := 0
	for i < len(s) {
		d := hex_digit_value(s[i])
		if d < 0 {
			break
		}
		digits += 1
		if mantissa >> 60 == 0 {
			mantissa = mantissa << 4 | u64(d)
		} else {
			if d != 0 {
				sticky = true
			}
			exponent += 4
		}
		i += 1
	}
	if i < len(s) && s[i] == '.' {
		j := i + 1
		fraction := 0
		for j < len(s) {
			d := hex_digit_value(s[j])
			if d < 0 {
				break
			}
			fraction += 1
			if mantissa >> 60 == 0 {
				mantissa = mantissa << 4 | u64(d)
				exponent -= 4
			} else if d != 0 {
				sticky = true
			}
			j += 1
		}
		if digits + fraction > 0 {
			i = j
		}
		digits += fraction
	}
	if digits == 0 {
		return 0, false
	}
	if i < len(s) && (s[i] == 'p' || s[i] == 'P') {
		value, used := exponent_value(s[i + 1:])
		if used > 0 {
			exponent += value
		}
	}
	return compose_float(mantissa, sticky, exponent), true
}

@(private)
parse_decimal_magnitude :: proc "contextless" (s: []u8) -> (f64, bool) {
	whole := 0
	for whole < len(s) && is_decimal_digit(s[whole]) {
		whole += 1
	}
	i := whole
	fraction_start := i
	fraction_end := i
	if i < len(s) && s[i] == '.' {
		fraction_start = i + 1
		fraction_end = fraction_start
		for fraction_end < len(s) && is_decimal_digit(s[fraction_end]) {
			fraction_end += 1
		}
		if whole + fraction_end - fraction_start > 0 {
			i = fraction_end
		}
	}
	if whole + fraction_end - fraction_start == 0 {
		return 0, false
	}
	exponent := 0
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		value, used := exponent_value(s[i + 1:])
		if used > 0 {
			exponent = value
		}
	}
	buf: [640]u8
	if whole + fraction_end - fraction_start + 16 > len(buf) {
		return 0, false
	}
	n := 0
	if whole == 0 {
		buf[n] = '0'
		n += 1
	}
	n += copy(buf[n:], s[:whole])
	buf[n] = '.'
	n += 1
	if fraction_end == fraction_start {
		buf[n] = '0'
		n += 1
	}
	n += copy(buf[n:], s[fraction_start:fraction_end])
	buf[n] = 'e'
	n += 1
	if exponent < 0 {
		buf[n] = '-'
		n += 1
		exponent = -exponent
	}
	digits: [8]u8
	count := 0
	for {
		digits[count] = u8('0' + exponent % 10)
		count += 1
		exponent /= 10
		if exponent == 0 {
			break
		}
	}
	for count > 0 {
		count -= 1
		buf[n] = digits[count]
		n += 1
	}
	context = runtime.default_context()
	value, _, good := strconv.parse_f64_prefix(string(buf[:n]))
	if !good {
		return transmute(f64)u64(0x7FF0000000000000), true
	}
	return value, true
}

@(private)
parse_text_score :: proc "contextless" (s: []u8) -> (f64, bool) {
	i := 0
	for i < len(s) && is_c_space(s[i]) {
		i += 1
	}
	negative := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		negative = s[i] == '-'
		i += 1
	}
	rest := s[i:]
	magnitude: f64
	switch {
	case match_word(rest, "inf"):
		if len(rest) > 3 && (rest[3] == 'i' || rest[3] == 'I') && !match_word(rest, "infinity") {
			return 0, false
		}
		magnitude = transmute(f64)u64(0x7FF0000000000000)
	case match_word(rest, "nan"):
		return transmute(f64)u64(0x7FF8000000000000), true
	case:
		got := false
		if len(rest) >= 2 && rest[0] == '0' && (rest[1] == 'x' || rest[1] == 'X') {
			magnitude, got = parse_hex_magnitude(rest[2:])
			if !got && (len(rest) < 3 || rest[2] != '.') {
				return 0, false
			}
		}
		if !got {
			magnitude, got = parse_decimal_magnitude(rest)
			if !got {
				return 0, false
			}
		}
	}
	if negative {
		return -magnitude, true
	}
	return magnitude, true
}

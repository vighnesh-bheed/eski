package vfilter

import "core:math"
import "core:strconv"

is_digit :: #force_inline proc "contextless" (c: u8) -> bool {
	return c >= '0' && c <= '9'
}

is_c_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || (c >= '\t' && c <= '\r')
}

hex_digit :: #force_inline proc "contextless" (c: u8) -> int {
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

fold_prefix :: proc "contextless" (text: string, at: int, word: string) -> bool {
	if len(text) - at < len(word) {
		return false
	}
	for i in 0 ..< len(word) {
		if text[at + i] | 0x20 != word[i] {
			return false
		}
	}
	return true
}

is_nan_char :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_digit(c) || (c | 0x20 >= 'a' && c | 0x20 <= 'z') || c == '_'
}

c_strtod_hex :: proc "contextless" (text: string, start: int, negative: bool) -> (value: f64, end: int) {
	i := start + 2
	mantissa: u64
	exponent := 0
	digits := 0
	seen_point := false
	for i < len(text) {
		c := text[i]
		if c == '.' && !seen_point {
			seen_point = true
			i += 1
			continue
		}
		d := hex_digit(c)
		if d < 0 {
			break
		}
		digits += 1
		if mantissa < 1 << 60 {
			mantissa = mantissa * 16 + u64(d)
			if seen_point {
				exponent -= 4
			}
		} else {
			if d != 0 {
				mantissa |= 1
			}
			if !seen_point {
				exponent += 4
			}
		}
		i += 1
	}
	if digits == 0 {
		return 0, start + 1
	}
	if i < len(text) && text[i] | 0x20 == 'p' {
		j := i + 1
		sign := 1
		if j < len(text) && (text[j] == '+' || text[j] == '-') {
			if text[j] == '-' {
				sign = -1
			}
			j += 1
		}
		if j < len(text) && is_digit(text[j]) {
			power := 0
			for j < len(text) && is_digit(text[j]) {
				if power < 100000 {
					power = power * 10 + int(text[j] - '0')
				}
				j += 1
			}
			exponent += sign * power
			i = j
		}
	}
	value = math.ldexp(f64(mantissa), exponent)
	if negative {
		value = -value
	}
	return value, i
}

c_strtod :: proc(text: string) -> (value: f64, end: int) {
	i := 0
	for i < len(text) && is_c_space(text[i]) {
		i += 1
	}
	sign_at := i
	negative := false
	if i < len(text) && (text[i] == '+' || text[i] == '-') {
		negative = text[i] == '-'
		i += 1
	}
	if i >= len(text) {
		return 0, 0
	}
	switch text[i] | 0x20 {
	case 'i':
		if fold_prefix(text, i, "infinity") {
			return -math.inf_f64(1) if negative else math.inf_f64(1), i + 8
		}
		if fold_prefix(text, i, "inf") {
			return -math.inf_f64(1) if negative else math.inf_f64(1), i + 3
		}
		return 0, 0
	case 'n':
		if !fold_prefix(text, i, "nan") {
			return 0, 0
		}
		i += 3
		if i < len(text) && text[i] == '(' {
			j := i + 1
			for j < len(text) && is_nan_char(text[j]) {
				j += 1
			}
			if j < len(text) && text[j] == ')' {
				i = j + 1
			}
		}
		return math.nan_f64(), i
	}
	if text[i] == '0' && i + 1 < len(text) && text[i + 1] | 0x20 == 'x' {
		return c_strtod_hex(text, i, negative)
	}
	digits := 0
	for i < len(text) && is_digit(text[i]) {
		i += 1
		digits += 1
	}
	if i < len(text) && text[i] == '.' {
		i += 1
		for i < len(text) && is_digit(text[i]) {
			i += 1
			digits += 1
		}
	}
	if digits == 0 {
		return 0, 0
	}
	if i < len(text) && text[i] | 0x20 == 'e' {
		j := i + 1
		if j < len(text) && (text[j] == '+' || text[j] == '-') {
			j += 1
		}
		if j < len(text) && is_digit(text[j]) {
			for j < len(text) && is_digit(text[j]) {
				j += 1
			}
			i = j
		}
	}
	value, _ = strconv.parse_f64(text[sign_at:i])
	return value, i
}

string_number :: proc(text: string) -> f64 {
	value, end := c_strtod(text)
	if end != len(text) {
		return 0
	}
	return value
}

run_number :: proc(text: string) -> (value: f64, ok: bool) {
	value_read, end := c_strtod(text)
	if end != len(text) || len(text) == 0 {
		return 0, false
	}
	return value_read, true
}

package vsetargs

import "base:intrinsics"
import "core:strconv"
import "../integer"

SIGNIFICANT_DIGITS :: 19
SMALLEST_POWER_OF_TEN :: -342
LARGEST_POWER_OF_TEN :: 308
EXACT_DIGITS :: 384
LONG_DIGITS :: 780
EXPONENT_CAP :: 1_000_000_000
LC_NUMERIC_MASK :: 2

F64_SIGN_BIT :: u64(0x8000_0000_0000_0000)
F64_INF_BITS :: u64(0x7FF0_0000_0000_0000)
F64_MANTISSA_MASK :: u64(0x000F_FFFF_FFFF_FFFF)

foreign import vsetargs_libc "system:c"

@(default_calling_convention = "c")
foreign vsetargs_libc {
	@(link_name = "strtod_l")
	libc_strtod_l :: proc(s: cstring, end: ^cstring, locale: rawptr) -> f64 ---
	@(link_name = "newlocale")
	libc_newlocale :: proc(mask: i32, name: cstring, base: rawptr) -> rawptr ---
	@(link_name = "freelocale")
	libc_freelocale :: proc(locale: rawptr) ---
}

parse_i64 :: proc "contextless" (s: []u8) -> (i64, bool) {
	return integer.parse_i64(s)
}

is_digit :: #force_inline proc "contextless" (c: u8) -> bool {
	return c >= '0' && c <= '9'
}

is_c_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || (c >= '\t' && c <= '\r')
}

hex_value :: #force_inline proc "contextless" (c: u8) -> int {
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

is_inf :: #force_inline proc "contextless" (v: f64) -> bool {
	return transmute(u64)v & ~F64_SIGN_BIT == F64_INF_BITS
}

signed :: #force_inline proc "contextless" (magnitude: f64, negative: bool) -> f64 {
	bits := transmute(u64)magnitude
	if negative {
		bits |= F64_SIGN_BIT
	}
	return transmute(f64)bits
}

fold_equal :: proc "contextless" (arg: []u8, word: string) -> bool {
	if len(arg) != len(word) {
		return false
	}
	for i in 0 ..< len(word) {
		if arg[i] | 0x20 != word[i] {
			return false
		}
	}
	return true
}

parse_double :: proc(s: []u8) -> (value: f64, ok: bool) {
	if len(s) == 0 || is_c_space(s[0]) {
		return 0, false
	}
	at := 0
	negative := false
	if s[0] == '+' || s[0] == '-' {
		negative = s[0] == '-'
		at = 1
	}
	if at == len(s) {
		return 0, false
	}
	switch s[at] | 0x20 {
	case 'i':
		if fold_equal(s[at:], "inf") || fold_equal(s[at:], "infinity") {
			return signed(transmute(f64)F64_INF_BITS, negative), true
		}
		return 0, false
	case 'n':
		return 0, false
	}
	if s[at] == '0' && at + 1 < len(s) && s[at + 1] | 0x20 == 'x' {
		return parse_hex(s, at + 2, negative)
	}
	return parse_decimal(s, at, negative)
}

parse_decimal :: proc(s: []u8, at: int, negative: bool) -> (value: f64, ok: bool) {
	i := at
	for i < len(s) && is_digit(s[i]) {
		i += 1
	}
	whole := i - at
	fraction := 0
	if i < len(s) && s[i] == '.' {
		i += 1
		start := i
		for i < len(s) && is_digit(s[i]) {
			i += 1
		}
		fraction = i - start
	}
	if whole + fraction == 0 {
		return 0, false
	}
	mantissa_end := i
	exponent: i64
	if i < len(s) && s[i] | 0x20 == 'e' {
		j := i + 1
		minus := false
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			minus = s[j] == '-'
			j += 1
		}
		if j < len(s) && is_digit(s[j]) {
			for j < len(s) && is_digit(s[j]) {
				if exponent < EXPONENT_CAP {
					exponent = exponent * 10 + i64(s[j] - '0')
				}
				j += 1
			}
			if minus {
				exponent = -exponent
			}
			i = j
		}
	}
	if i != len(s) {
		return 0, false
	}
	first := at
	for first < mantissa_end && (s[first] == '0' || s[first] == '.') {
		first += 1
	}
	if first == mantissa_end {
		return signed(0, negative), true
	}
	digits := 0
	for k in first ..< mantissa_end {
		if s[k] != '.' {
			digits += 1
		}
	}
	scale := exponent - i64(fraction)
	if digits <= SIGNIFICANT_DIGITS {
		if scale < SMALLEST_POWER_OF_TEN || scale > LARGEST_POWER_OF_TEN {
			return 0, false
		}
		return signed(convert_exact(s[first:mantissa_end], scale), negative), true
	}
	truncated := scale + i64(digits - SIGNIFICANT_DIGITS)
	if truncated < SMALLEST_POWER_OF_TEN || truncated > LARGEST_POWER_OF_TEN {
		return 0, false
	}
	magnitude: f64
	if digits <= EXACT_DIGITS {
		magnitude = convert_exact(s[first:mantissa_end], scale)
	} else {
		magnitude = convert_long(s[first:mantissa_end], digits, scale)
	}
	if magnitude == 0 || is_inf(magnitude) {
		return 0, false
	}
	return signed(magnitude, negative), true
}

write_exponent :: proc "contextless" (out: []u8, at: int, exponent: i64) -> int {
	n := at
	out[n] = 'e'
	n += 1
	magnitude := u64(exponent)
	if exponent < 0 {
		out[n] = '-'
		n += 1
		magnitude = u64(-exponent)
	}
	scratch: [24]u8
	count := 0
	for {
		scratch[count] = u8('0' + magnitude % 10)
		count += 1
		magnitude /= 10
		if magnitude == 0 {
			break
		}
	}
	for count > 0 {
		count -= 1
		out[n] = scratch[count]
		n += 1
	}
	return n
}

convert_exact :: proc(mantissa: []u8, scale: i64) -> f64 {
	buffer: [EXACT_DIGITS + 32]u8
	n := 0
	for c in mantissa {
		if c != '.' {
			buffer[n] = c
			n += 1
		}
	}
	n = write_exponent(buffer[:], n, scale)
	value, _ := strconv.parse_f64(string(buffer[:n]))
	return value
}

convert_long :: proc(mantissa: []u8, digits: int, scale: i64) -> f64 {
	buffer: [LONG_DIGITS + 40]u8
	n := 0
	kept := 0
	sticky := false
	for c in mantissa {
		if c == '.' {
			continue
		}
		if kept < LONG_DIGITS {
			buffer[n] = c
			n += 1
			kept += 1
		} else if c != '0' {
			sticky = true
			break
		}
	}
	exponent := scale + i64(digits - kept)
	if sticky {
		buffer[n] = '1'
		n += 1
		exponent -= 1
	}
	n = write_exponent(buffer[:], n, exponent)
	buffer[n] = 0
	locale := libc_newlocale(LC_NUMERIC_MASK, "C", nil)
	if locale == nil {
		value, _ := strconv.parse_f64(string(buffer[:n]))
		return value
	}
	value := libc_strtod_l(cstring(raw_data(buffer[:])), nil, locale)
	libc_freelocale(locale)
	return value
}

parse_hex :: proc "contextless" (s: []u8, at: int, negative: bool) -> (value: f64, ok: bool) {
	i := at
	mantissa: u64
	kept := 0
	dropped: i64
	fraction: i64
	sticky := false
	any_digit := false
	significant := false
	point := false
	for i < len(s) {
		c := s[i]
		if c == '.' {
			if point {
				break
			}
			point = true
			i += 1
			continue
		}
		d := hex_value(c)
		if d < 0 {
			break
		}
		any_digit = true
		if point {
			fraction += 1
		}
		i += 1
		if !significant && d == 0 {
			continue
		}
		significant = true
		if kept < 16 {
			mantissa = mantissa << 4 | u64(d)
			kept += 1
		} else {
			dropped += 1
			if d != 0 {
				sticky = true
			}
		}
	}
	if !any_digit {
		return 0, false
	}
	power: i64
	if i < len(s) && s[i] | 0x20 == 'p' {
		j := i + 1
		minus := false
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			minus = s[j] == '-'
			j += 1
		}
		if j < len(s) && is_digit(s[j]) {
			for j < len(s) && is_digit(s[j]) {
				if power < EXPONENT_CAP {
					power = power * 10 + i64(s[j] - '0')
				}
				j += 1
			}
			if minus {
				power = -power
			}
			i = j
		}
	}
	if i != len(s) {
		return 0, false
	}
	if !significant {
		return signed(0, negative), true
	}
	exponent := 4 * dropped + power - 4 * fraction
	bits, in_range := round_binary(mantissa, exponent, sticky)
	if !in_range {
		return 0, false
	}
	return signed(transmute(f64)bits, negative), true
}

round_binary :: proc "contextless" (mantissa: u64, exponent: i64, sticky: bool) -> (bits: u64, ok: bool) {
	shift_in := i64(intrinsics.count_leading_zeros(mantissa))
	m := mantissa << u64(shift_in)
	e := exponent - shift_in
	top := e + 63
	if top > 1023 {
		return 0, false
	}
	ulp := max(top - 52, -1074)
	shift := ulp - e
	n: u64
	switch {
	case shift > 64:
		n = 0
	case shift == 64:
		half := u64(1) << 63
		if m > half || (m == half && sticky) {
			n = 1
		}
	case:
		n = m >> u64(shift)
		rem := m & ((u64(1) << u64(shift)) - 1)
		half := u64(1) << u64(shift - 1)
		if rem > half || (rem == half && (sticky || n & 1 == 1)) {
			n += 1
		}
	}
	if n == 0 {
		return 0, false
	}
	if n == u64(1) << 53 {
		n = u64(1) << 52
		ulp += 1
	}
	if n < u64(1) << 52 {
		return n, true
	}
	biased := ulp + 52 + 1023
	if biased >= 2047 {
		return 0, false
	}
	return u64(biased) << 52 | (n & F64_MANTISSA_MASK), true
}

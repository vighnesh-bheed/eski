package fpconv

@(private = "file")
EXACT_INTEGER_BOUND :: f64(4611686018427387904.0)

@(private = "file")
PLAIN_ZEROS_MAX :: 7

@(private = "file")
PLAIN_FRACTION_MIN :: -6

@(private = "file")
PLAIN_LEAD_MAX :: 3

@(private = "file")
put_exponent :: proc "contextless" (dst: []u8, at: int, p: int) -> int #no_bounds_check {
	pos := at
	dst[pos] = 'e'
	pos += 1
	mag := p
	if p < 0 {
		dst[pos] = '-'
		mag = -p
	} else {
		dst[pos] = '+'
	}
	pos += 1
	if mag >= 100 {
		dst[pos] = u8('0' + mag / 100)
		pos += 1
	}
	if mag >= 10 {
		dst[pos] = u8('0' + mag / 10 % 10)
		pos += 1
	}
	dst[pos] = u8('0' + mag % 10)
	return pos + 1
}

@(private = "file")
lay_out :: proc "contextless" (dst: []u8, digits: []u8, scale: int) -> int #no_bounds_check {
	n := len(digits)
	point := scale + n
	lead := point - 1
	if scale >= 0 && scale <= PLAIN_ZEROS_MAX {
		copy(dst, digits)
		for i in 0 ..< scale {
			dst[n + i] = '0'
		}
		return n + scale
	}
	if scale < 0 && (scale >= PLAIN_FRACTION_MIN || abs(lead) <= PLAIN_LEAD_MAX) {
		if point <= 0 {
			dst[0] = '0'
			dst[1] = '.'
			pos := 2
			for _ in 0 ..< -point {
				dst[pos] = '0'
				pos += 1
			}
			copy(dst[pos:], digits)
			return pos + n
		}
		copy(dst, digits[:point])
		dst[point] = '.'
		copy(dst[point + 1:], digits[point:])
		return n + 1
	}
	dst[0] = digits[0]
	pos := 1
	if n > 1 {
		dst[pos] = '.'
		pos += 1
		copy(dst[pos:], digits[1:])
		pos += n - 1
	}
	return put_exponent(dst, pos, lead)
}

format_double :: proc "contextless" (dst: []u8, v: f64) -> int #no_bounds_check {
	bits := transmute(u64)v
	mag := bits & 0x7FFF_FFFF_FFFF_FFFF
	if mag > 0x7FF0_0000_0000_0000 {
		copy(dst, "nan")
		return 3
	}
	pos := 0
	if bits >> 63 != 0 {
		dst[0] = '-'
		pos = 1
	}
	if mag == 0x7FF0_0000_0000_0000 {
		copy(dst[pos:], "inf")
		return pos + 3
	}
	if mag == 0 {
		dst[pos] = '0'
		return pos + 1
	}
	a := transmute(f64)mag
	if a <= EXACT_INTEGER_BOUND {
		whole := i64(a)
		if f64(whole) == a {
			return pos + format_i64(raw_data(dst[pos:]), whole)
		}
	}
	digits: [24]u8
	scale := 0
	n := grisu2(mag, digits[:], &scale)
	return pos + lay_out(dst[pos:], digits[:n], scale)
}

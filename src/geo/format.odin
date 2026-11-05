package geo

HUMAN_MAX :: 64

DISTANCE_MAX :: 32

@(private = "file")
FIXED_TEXT_MAX :: 360

@(private = "file")
WIDE_LIMBS :: 36

@(private = "file")
Wide :: struct {
	n:     int,
	limbs: [WIDE_LIMBS]u32,
}

@(private = "file")
POWERS_OF_TEN := [18]u64 {
	1,
	10,
	100,
	1_000,
	10_000,
	100_000,
	1_000_000,
	10_000_000,
	100_000_000,
	1_000_000_000,
	10_000_000_000,
	100_000_000_000,
	1_000_000_000_000,
	10_000_000_000_000,
	100_000_000_000_000,
	1_000_000_000_000_000,
	10_000_000_000_000_000,
	100_000_000_000_000_000,
}

@(private = "file")
put_text :: proc "contextless" (out: []u8, at: int, s: string) -> int {
	for i in 0 ..< len(s) {
		out[at + i] = s[i]
	}
	return at + len(s)
}

@(private = "file")
put_u128 :: proc "contextless" (out: []u8, at: int, v: u128) -> int {
	rev: [40]u8
	n := 0
	rest := v
	for {
		rev[n] = u8('0' + rest % 10)
		n += 1
		rest /= 10
		if rest == 0 {
			break
		}
	}
	for i in 0 ..< n {
		out[at + i] = rev[n - 1 - i]
	}
	return at + n
}

@(private = "file")
put_padded :: proc "contextless" (out: []u8, at: int, v: u64, width: int) -> int {
	rest := v
	for i := width - 1; i >= 0; i -= 1 {
		out[at + i] = u8('0' + rest % 10)
		rest /= 10
	}
	return at + width
}

@(private = "file")
wide_from_shifted :: proc "contextless" (w: ^Wide, m: u64, shift: int) {
	w^ = {}
	word := shift / 32
	bit := uint(shift % 32)
	wide := u128(m) << bit
	for i in 0 ..< 4 {
		w.limbs[word + i] = u32(wide >> uint(32 * i))
	}
	w.n = word + 4
	for w.n > 0 && w.limbs[w.n - 1] == 0 {
		w.n -= 1
	}
}

@(private = "file")
wide_div_small :: proc "contextless" (w: ^Wide, d: u32) -> u32 {
	rem: u64 = 0
	for i := w.n - 1; i >= 0; i -= 1 {
		cur := (rem << 32) | u64(w.limbs[i])
		w.limbs[i] = u32(cur / u64(d))
		rem = cur % u64(d)
	}
	for w.n > 0 && w.limbs[w.n - 1] == 0 {
		w.n -= 1
	}
	return u32(rem)
}

@(private = "file")
put_wide :: proc "contextless" (out: []u8, at: int, w: ^Wide) -> int {
	groups: [WIDE_LIMBS * 2]u32
	count := 0
	for w.n > 0 {
		groups[count] = wide_div_small(w, 1_000_000_000)
		count += 1
	}
	if count == 0 {
		out[at] = '0'
		return at + 1
	}
	pos := put_u128(out, at, u128(groups[count - 1]))
	for g := count - 2; g >= 0; g -= 1 {
		pos = put_padded(out, pos, u64(groups[g]), 9)
	}
	return pos
}

@(private = "file")
fixed_text :: proc "contextless" (out: []u8, v: f64, decimals: int, trim: bool) -> int {
	raw := transmute(u64)v
	negative := raw >> 63 != 0
	biased := int((raw >> 52) & 0x7ff)
	fraction := raw & ((u64(1) << 52) - 1)
	pos := 0
	if biased == 0x7ff {
		if fraction != 0 {
			return put_text(out, 0, "-nan" if negative else "nan")
		}
		return put_text(out, 0, "-inf" if negative else "inf")
	}
	mantissa := fraction
	exponent := -1074
	if biased != 0 {
		mantissa |= u64(1) << 52
		exponent = biased - 1075
	}
	if negative {
		out[0] = '-'
		pos = 1
	}
	scale := POWERS_OF_TEN[decimals]
	whole: u128
	part: u64
	if mantissa == 0 {
		pos = put_u128(out, pos, 0)
	} else if exponent >= 0 {
		if exponent <= 74 {
			pos = put_u128(out, pos, u128(mantissa) << uint(exponent))
		} else {
			w: Wide
			wide_from_shifted(&w, mantissa, exponent)
			pos = put_wide(out, pos, &w)
		}
	} else {
		shift := -exponent
		scaled := u128(mantissa) * u128(scale)
		rounded: u128 = 0
		if shift < 128 {
			rounded = scaled >> uint(shift)
			rem := scaled & ((u128(1) << uint(shift)) - 1)
			half := u128(1) << uint(shift - 1)
			if rem > half || (rem == half && rounded & 1 == 1) {
				rounded += 1
			}
		}
		whole = rounded / u128(scale)
		part = u64(rounded % u128(scale))
		pos = put_u128(out, pos, whole)
	}
	if decimals > 0 {
		out[pos] = '.'
		pos = put_padded(out, pos + 1, part, decimals)
	}
	if trim && decimals > 0 {
		for out[pos - 1] == '0' {
			pos -= 1
		}
		if out[pos - 1] == '.' {
			pos -= 1
		}
		if pos == 2 && out[0] == '-' && out[1] == '0' {
			out[0] = '0'
			pos = 1
		}
	}
	return pos
}

@(private = "file")
fixed_into :: proc "contextless" (dst: []u8, v: f64, decimals: int, trim: bool) -> int {
	text: [FIXED_TEXT_MAX]u8
	n := fixed_text(text[:], v, decimals, trim)
	n = min(n, len(dst))
	for i in 0 ..< n {
		dst[i] = text[i]
	}
	return n
}

format_f6 :: proc "contextless" (dst: []u8, v: f64) -> int {
	return fixed_into(dst, v, 6, false)
}

format_distance :: proc "contextless" (dst: []u8, d: f64) -> int {
	scaled := d * 10000
	if !(abs(scaled) < 1e18) {
		return fixed_into(dst, d, 4, false)
	}
	magnitude := abs(scaled)
	whole := u64(magnitude)
	rest := magnitude - f64(whole)
	if rest > 0.5 || (rest == 0.5 && whole & 1 == 1) {
		whole += 1
	}
	text: [32]u8
	pos := 0
	if scaled < 0 && whole != 0 {
		text[0] = '-'
		pos = 1
	}
	pos = put_u128(text[:], pos, u128(whole / 10000))
	text[pos] = '.'
	pos = put_padded(text[:], pos + 1, whole % 10000, 4)
	n := min(pos, len(dst))
	for i in 0 ..< n {
		dst[i] = text[i]
	}
	return n
}

format_human :: proc "contextless" (dst: []u8, v: f64) -> int {
	return fixed_into(dst, v, 17, true)
}

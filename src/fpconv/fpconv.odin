package fpconv

import "base:intrinsics"

DOUBLE_STR_MAX :: 32

@(private = "file")
Fp :: struct {
	frac: u64,
	exp:  int,
}

@(private = "file")
FRAC_MASK :: u64(0x000FFFFFFFFFFFFF)
@(private = "file")
EXP_MASK :: u64(0x7FF0000000000000)
@(private = "file")
HIDDEN_BIT :: u64(0x0010000000000000)
@(private = "file")
SIGN_MASK :: u64(0x8000000000000000)
@(private = "file")
EXP_BIAS :: 1023 + 52
@(private = "file")
POW10_FIRST :: -348
@(private = "file")
POW10_STEP :: 8
@(private = "file")
POW10_COUNT :: 87
@(private = "file")
SCALED_EXP_MIN :: -60
@(private = "file")
SCALED_EXP_MAX :: -32

@(private = "file")
pow10_cache := [POW10_COUNT]Fp {
	{0xfa8fd5a0081c0288, -1220},
	{0xbaaee17fa23ebf76, -1193},
	{0x8b16fb203055ac76, -1166},
	{0xcf42894a5dce35ea, -1140},
	{0x9a6bb0aa55653b2d, -1113},
	{0xe61acf033d1a45df, -1087},
	{0xab70fe17c79ac6ca, -1060},
	{0xff77b1fcbebcdc4f, -1034},
	{0xbe5691ef416bd60c, -1007},
	{0x8dd01fad907ffc3c, -980},
	{0xd3515c2831559a83, -954},
	{0x9d71ac8fada6c9b5, -927},
	{0xea9c227723ee8bcb, -901},
	{0xaecc49914078536d, -874},
	{0x823c12795db6ce57, -847},
	{0xc21094364dfb5637, -821},
	{0x9096ea6f3848984f, -794},
	{0xd77485cb25823ac7, -768},
	{0xa086cfcd97bf97f4, -741},
	{0xef340a98172aace5, -715},
	{0xb23867fb2a35b28e, -688},
	{0x84c8d4dfd2c63f3b, -661},
	{0xc5dd44271ad3cdba, -635},
	{0x936b9fcebb25c996, -608},
	{0xdbac6c247d62a584, -582},
	{0xa3ab66580d5fdaf6, -555},
	{0xf3e2f893dec3f126, -529},
	{0xb5b5ada8aaff80b8, -502},
	{0x87625f056c7c4a8b, -475},
	{0xc9bcff6034c13053, -449},
	{0x964e858c91ba2655, -422},
	{0xdff9772470297ebd, -396},
	{0xa6dfbd9fb8e5b88f, -369},
	{0xf8a95fcf88747d94, -343},
	{0xb94470938fa89bcf, -316},
	{0x8a08f0f8bf0f156b, -289},
	{0xcdb02555653131b6, -263},
	{0x993fe2c6d07b7fac, -236},
	{0xe45c10c42a2b3b06, -210},
	{0xaa242499697392d3, -183},
	{0xfd87b5f28300ca0e, -157},
	{0xbce5086492111aeb, -130},
	{0x8cbccc096f5088cc, -103},
	{0xd1b71758e219652c, -77},
	{0x9c40000000000000, -50},
	{0xe8d4a51000000000, -24},
	{0xad78ebc5ac620000, 3},
	{0x813f3978f8940984, 30},
	{0xc097ce7bc90715b3, 56},
	{0x8f7e32ce7bea5c70, 83},
	{0xd5d238a4abe98068, 109},
	{0x9f4f2726179a2245, 136},
	{0xed63a231d4c4fb27, 162},
	{0xb0de65388cc8ada8, 189},
	{0x83c7088e1aab65db, 216},
	{0xc45d1df942711d9a, 242},
	{0x924d692ca61be758, 269},
	{0xda01ee641a708dea, 295},
	{0xa26da3999aef774a, 322},
	{0xf209787bb47d6b85, 348},
	{0xb454e4a179dd1877, 375},
	{0x865b86925b9bc5c2, 402},
	{0xc83553c5c8965d3d, 428},
	{0x952ab45cfa97a0b3, 455},
	{0xde469fbd99a05fe3, 481},
	{0xa59bc234db398c25, 508},
	{0xf6c69a72a3989f5c, 534},
	{0xb7dcbf5354e9bece, 561},
	{0x88fcf317f22241e2, 588},
	{0xcc20ce9bd35c78a5, 614},
	{0x98165af37b2153df, 641},
	{0xe2a0b5dc971f303a, 667},
	{0xa8d9d1535ce3b396, 694},
	{0xfb9b7cd9a4a7443c, 720},
	{0xbb764c4ca7a44410, 747},
	{0x8bab8eefb6409c1a, 774},
	{0xd01fef10a657842c, 800},
	{0x9b10a4e5e9913129, 827},
	{0xe7109bfba19c0c9d, 853},
	{0xac2820d9623bf429, 880},
	{0x80444b5e7aa7cf85, 907},
	{0xbf21e44003acdd2d, 933},
	{0x8e679c2f5e44ff8f, 960},
	{0xd433179d9c8cb841, 986},
	{0x9e19db92b4e31ba9, 1013},
	{0xeb96bf6ebadf77d9, 1039},
	{0xaf87023b9bf0ee6b, 1066},
}

@(private = "file")
tens := [20]u64 {
	10000000000000000000,
	1000000000000000000,
	100000000000000000,
	10000000000000000,
	1000000000000000,
	100000000000000,
	10000000000000,
	1000000000000,
	100000000000,
	10000000000,
	1000000000,
	100000000,
	10000000,
	1000000,
	100000,
	10000,
	1000,
	100,
	10,
	1,
}

@(private = "file")
fp_from_bits :: proc "contextless" (bits: u64) -> Fp {
	fp := Fp{bits & FRAC_MASK, int((bits & EXP_MASK) >> 52)}
	if fp.exp != 0 {
		fp.frac += HIDDEN_BIT
		fp.exp -= EXP_BIAS
	} else {
		fp.exp = -EXP_BIAS + 1
	}
	return fp
}

@(private = "file")
fp_normalize :: proc "contextless" (fp: ^Fp) {
	for fp.frac & HIDDEN_BIT == 0 {
		fp.frac <<= 1
		fp.exp -= 1
	}
	fp.frac <<= 11
	fp.exp -= 11
}

@(private = "file")
fp_boundaries :: proc "contextless" (fp: Fp) -> (lower: Fp, upper: Fp) {
	upper.frac = (fp.frac << 1) + 1
	upper.exp = fp.exp - 1
	for upper.frac & (HIDDEN_BIT << 1) == 0 {
		upper.frac <<= 1
		upper.exp -= 1
	}
	upper.frac <<= 10
	upper.exp -= 10
	l_shift := 2 if fp.frac == HIDDEN_BIT else 1
	lower.frac = (fp.frac << uint(l_shift)) - 1
	lower.exp = fp.exp - l_shift
	lower.frac <<= uint(lower.exp - upper.exp)
	lower.exp = upper.exp
	return
}

@(private = "file")
fp_multiply :: proc "contextless" (a: Fp, b: Fp) -> Fp {
	LO :: u64(0x00000000FFFFFFFF)
	ah_bl := (a.frac >> 32) * (b.frac & LO)
	al_bh := (a.frac & LO) * (b.frac >> 32)
	al_bl := (a.frac & LO) * (b.frac & LO)
	ah_bh := (a.frac >> 32) * (b.frac >> 32)
	tmp := (ah_bl & LO) + (al_bh & LO) + (al_bl >> 32)
	tmp += u64(1) << 31
	return Fp{ah_bh + (ah_bl >> 32) + (al_bh >> 32) + (tmp >> 32), a.exp + b.exp + 64}
}

@(private = "file")
cached_pow10 :: proc "contextless" (exp: int) -> (Fp, int) #no_bounds_check {
	approx := int(f64(-(exp + POW10_COUNT)) * 0.30102999566398114)
	idx := (approx - POW10_FIRST) / POW10_STEP
	for {
		current := exp + pow10_cache[idx].exp + 64
		if current < SCALED_EXP_MIN {
			idx += 1
			continue
		}
		if current > SCALED_EXP_MAX {
			idx -= 1
			continue
		}
		return pow10_cache[idx], POW10_FIRST + idx * POW10_STEP
	}
}

@(private = "file")
round_digit :: proc "contextless" (digits: []u8, ndigits: int, delta: u64, rem: u64, kappa: u64, frac: u64) #no_bounds_check {
	rem := rem
	for rem < frac && delta - rem >= kappa && (rem + kappa < frac || frac - rem > rem + kappa - frac) {
		digits[ndigits - 1] -= 1
		rem += kappa
	}
}

@(private = "file")
generate_digits :: proc "contextless" (fp: Fp, upper: Fp, lower: Fp, digits: []u8, K: ^int) -> int #no_bounds_check {
	wfrac := upper.frac - fp.frac
	delta := upper.frac - lower.frac
	shift := uint(-upper.exp)
	one := u64(1) << shift
	part1 := upper.frac >> shift
	part2 := upper.frac & (one - 1)
	idx := 0
	kappa := 10
	for di := 10; kappa > 0; di += 1 {
		div := tens[di]
		digit := part1 / div
		if digit != 0 || idx != 0 {
			digits[idx] = u8(digit) + '0'
			idx += 1
		}
		part1 -= digit * div
		kappa -= 1
		tmp := (part1 << shift) + part2
		if tmp <= delta {
			K^ += kappa
			round_digit(digits, idx, delta, tmp, div << shift, wfrac)
			return idx
		}
	}
	unit := 18
	for {
		part2 *= 10
		delta *= 10
		kappa -= 1
		digit := part2 >> shift
		if digit != 0 || idx != 0 {
			digits[idx] = u8(digit) + '0'
			idx += 1
		}
		part2 &= one - 1
		if part2 < delta {
			K^ += kappa
			round_digit(digits, idx, delta, part2, one, wfrac * tens[unit])
			return idx
		}
		unit -= 1
	}
}

@(private)
grisu2 :: proc "contextless" (bits: u64, digits: []u8, K: ^int) -> int {
	w := fp_from_bits(bits)
	lower, upper := fp_boundaries(w)
	fp_normalize(&w)
	cp, k := cached_pow10(upper.exp)
	w = fp_multiply(w, cp)
	upper = fp_multiply(upper, cp)
	lower = fp_multiply(lower, cp)
	lower.frac += 1
	upper.frac -= 1
	K^ = -k
	return generate_digits(w, upper, lower, digits, K)
}

@(private = "file")
emit_digits :: proc "contextless" (digits: []u8, ndigits: int, dest: []u8, K: int, neg: bool) -> int #no_bounds_check {
	ndigits := ndigits
	exp := abs(K + ndigits - 1)
	if K >= 0 && exp < ndigits + 7 {
		copy(dest, digits[:ndigits])
		for i in 0 ..< K {
			dest[ndigits + i] = '0'
		}
		return ndigits + K
	}
	if K < 0 && (K > -7 || exp < 4) {
		offset := ndigits - abs(K)
		if offset <= 0 {
			offset = -offset
			dest[0] = '0'
			dest[1] = '.'
			for i in 0 ..< offset {
				dest[2 + i] = '0'
			}
			copy(dest[offset + 2:], digits[:ndigits])
			return ndigits + 2 + offset
		}
		copy(dest, digits[:offset])
		dest[offset] = '.'
		copy(dest[offset + 1:], digits[offset:ndigits])
		return ndigits + 1
	}
	ndigits = min(ndigits, 18 - (1 if neg else 0))
	idx := 0
	dest[idx] = digits[0]
	idx += 1
	if ndigits > 1 {
		dest[idx] = '.'
		idx += 1
		copy(dest[idx:], digits[1:ndigits])
		idx += ndigits - 1
	}
	dest[idx] = 'e'
	idx += 1
	dest[idx] = '-' if K + ndigits - 1 < 0 else '+'
	idx += 1
	cent := 0
	if exp > 99 {
		cent = exp / 100
		dest[idx] = u8(cent) + '0'
		idx += 1
		exp -= cent * 100
	}
	if exp > 9 {
		dec := exp / 10
		dest[idx] = u8(dec) + '0'
		idx += 1
		exp -= dec * 10
	} else if cent != 0 {
		dest[idx] = '0'
		idx += 1
	}
	dest[idx] = u8(exp % 10) + '0'
	idx += 1
	return idx
}

format_i64 :: proc "contextless" (dst: [^]u8, v: i64) -> int #no_bounds_check {
	tmp: [20]u8
	u: u64
	neg := v < 0
	if neg {
		u = 0 - cast(u64)v
	} else {
		u = u64(v)
	}
	i := 20
	for {
		i -= 1
		tmp[i] = u8('0' + u % 10)
		u /= 10
		if u == 0 {
			break
		}
	}
	n := 0
	if neg {
		dst[0] = '-'
		n = 1
	}
	l := 20 - i
	intrinsics.mem_copy_non_overlapping(&dst[n], &tmp[i], l)
	return n + l
}

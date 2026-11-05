package ldfloat

import "base:intrinsics"

MAX_LONG_DOUBLE_CHARS :: 5 * 1024

EXP_MIN :: -16445
EXP_MAX :: 16320

POW10_17 :: u128(100000000000000000)

Class :: enum u8 {
	Zero,
	Finite,
	Inf,
	NaN,
}

F80 :: struct {
	mant:  u64,
	exp:   i32,
	neg:   bool,
	class: Class,
}

zero :: #force_inline proc "contextless" (neg: bool) -> F80 {
	return F80{neg = neg, class = .Zero}
}

infinity :: #force_inline proc "contextless" (neg: bool) -> F80 {
	return F80{neg = neg, class = .Inf}
}

nan :: #force_inline proc "contextless" () -> F80 {
	return F80{class = .NaN}
}

is_nan :: #force_inline proc "contextless" (v: F80) -> bool {
	return v.class == .NaN
}

is_inf :: #force_inline proc "contextless" (v: F80) -> bool {
	return v.class == .Inf
}

is_finite :: #force_inline proc "contextless" (v: F80) -> bool {
	return v.class == .Zero || v.class == .Finite
}

from_i64 :: proc "contextless" (v: i64) -> F80 {
	if v == 0 {
		return zero(false)
	}
	neg := v < 0
	mag := u64(0) - u64(v) if neg else u64(v)
	lz := intrinsics.count_leading_zeros(mag)
	return F80{mant = mag << lz, exp = -i32(lz), neg = neg, class = .Finite}
}

round_bits :: proc "contextless" (neg: bool, m: u128, e2: int, sticky: bool) -> F80 {
	if m == 0 {
		return zero(neg)
	}
	bl := 128 - int(intrinsics.count_leading_zeros(m))
	shift := bl - 64
	e := e2 + shift
	if e < EXP_MIN {
		shift += EXP_MIN - e
		e = EXP_MIN
	}
	mant: u64
	if shift <= 0 {
		mant = u64(m << uint(-shift))
	} else if shift > 128 {
		return zero(neg)
	} else if shift == 128 {
		half := u128(1) << 127
		if m > half || (m == half && sticky) {
			mant = 1
		} else {
			return zero(neg)
		}
	} else {
		mant = u64(m >> uint(shift))
		rem := m & ((u128(1) << uint(shift)) - 1)
		half := u128(1) << uint(shift - 1)
		if rem > half || (rem == half && (sticky || (mant & 1) == 1)) {
			mant += 1
			if mant == 0 {
				mant = u64(1) << 63
				e += 1
			}
		}
	}
	if mant == 0 {
		return zero(neg)
	}
	if e > EXP_MAX {
		return infinity(neg)
	}
	return F80{mant = mant, exp = i32(e), neg = neg, class = .Finite}
}

add :: proc "contextless" (a, b: F80) -> F80 {
	if a.class == .NaN || b.class == .NaN {
		return nan()
	}
	if a.class == .Inf {
		if b.class == .Inf && a.neg != b.neg {
			return nan()
		}
		return a
	}
	if b.class == .Inf {
		return b
	}
	if a.class == .Zero {
		if b.class == .Zero {
			return zero(a.neg && b.neg)
		}
		return b
	}
	if b.class == .Zero {
		return a
	}
	x, y := a, b
	if y.exp > x.exp || (y.exp == x.exp && y.mant > x.mant) {
		x, y = y, x
	}
	big_x := u128(x.mant) << 63
	d := int(x.exp) - int(y.exp)
	big_y: u128
	sticky := false
	if d == 0 {
		big_y = u128(y.mant) << 63
	} else if d < 127 {
		full := u128(y.mant) << 63
		big_y = full >> uint(d)
		sticky = (full & ((u128(1) << uint(d)) - 1)) != 0
	} else {
		big_y = 0
		sticky = true
	}
	e2 := int(x.exp) - 63
	if x.neg == y.neg {
		return round_bits(x.neg, big_x + big_y, e2, sticky)
	}
	if big_x == big_y && !sticky {
		return zero(false)
	}
	s := big_x - big_y
	if sticky {
		s -= 1
	}
	return round_bits(x.neg, s, e2, sticky)
}

@(private)
is_c_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'
}

@(private)
lower :: #force_inline proc "contextless" (c: u8) -> u8 {
	return c + 32 if c >= 'A' && c <= 'Z' else c
}

@(private)
eq_fold :: proc "contextless" (s: []u8, lit: string) -> bool {
	if len(s) != len(lit) {
		return false
	}
	for i in 0 ..< len(s) {
		if lower(s[i]) != lit[i] {
			return false
		}
	}
	return true
}

@(private)
hex_val :: #force_inline proc "contextless" (c: u8) -> int {
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
parse_exp_digits :: proc "contextless" (s: []u8, i: ^int) -> (value: int, ok: bool) {
	j := i^
	n := len(s)
	if j >= n {
		return 0, false
	}
	eneg := false
	if s[j] == '+' || s[j] == '-' {
		eneg = s[j] == '-'
		j += 1
	}
	start := j
	v := 0
	for j < n && s[j] >= '0' && s[j] <= '9' {
		if v < 1_000_000_000 {
			v = v * 10 + int(s[j] - '0')
		}
		j += 1
	}
	if j == start {
		return 0, false
	}
	i^ = j
	return -v if eneg else v, true
}

parse :: proc "contextless" (s: []u8) -> (F80, bool) {
	n := len(s)
	if n == 0 || n >= MAX_LONG_DOUBLE_CHARS {
		return {}, false
	}
	if is_c_space(s[0]) {
		return {}, false
	}
	i := 0
	neg := false
	if s[0] == '+' || s[0] == '-' {
		neg = s[0] == '-'
		i = 1
	}
	if i >= n {
		return {}, false
	}
	rest := s[i:]
	if eq_fold(rest, "inf") || eq_fold(rest, "infinity") {
		return infinity(neg), true
	}
	if len(rest) >= 2 && rest[0] == '0' && (rest[1] == 'x' || rest[1] == 'X') {
		return parse_hex(neg, rest[2:])
	}
	return parse_dec(neg, rest)
}

@(private)
parse_dec :: proc "contextless" (neg: bool, s: []u8) -> (F80, bool) {
	n := len(s)
	i := 0
	int_start := i
	for i < n && s[i] >= '0' && s[i] <= '9' {
		i += 1
	}
	int_end := i
	frac_start, frac_end := i, i
	if i < n && s[i] == '.' {
		i += 1
		frac_start = i
		for i < n && s[i] >= '0' && s[i] <= '9' {
			i += 1
		}
		frac_end = i
	}
	if int_end == int_start && frac_end == frac_start {
		return {}, false
	}
	exp10 := 0
	if i < n && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		v, ok := parse_exp_digits(s, &j)
		if !ok {
			return {}, false
		}
		exp10 = v
		i = j
	}
	if i != n {
		return {}, false
	}
	digits: [MAX_LONG_DOUBLE_CHARS]u8
	nd := 0
	for k in int_start ..< int_end {
		if nd == 0 && s[k] == '0' {
			continue
		}
		digits[nd] = s[k]
		nd += 1
	}
	e10 := exp10
	for k in frac_start ..< frac_end {
		e10 -= 1
		if nd == 0 && s[k] == '0' {
			continue
		}
		digits[nd] = s[k]
		nd += 1
	}
	for nd > 0 && digits[nd - 1] == '0' {
		nd -= 1
		e10 += 1
	}
	if nd == 0 {
		return zero(neg), true
	}
	mag10 := nd + e10
	if mag10 > 4934 || mag10 < -4960 {
		return {}, false
	}
	d: Big
	k := 0
	for k < nd {
		chunk: u32 = 0
		mul: u32 = 1
		for c := 0; c < 9 && k < nd; c += 1 {
			chunk = chunk * 10 + u32(digits[k] - '0')
			mul *= 10
			k += 1
		}
		big_mul_small(&d, mul)
		big_add_small(&d, chunk)
	}
	r: F80
	if e10 >= 0 {
		big_mul_pow5(&d, e10)
		top, sh, sticky := big_top128(&d)
		r = round_bits(neg, top, e10 + sh, sticky)
	} else {
		n5 := -e10
		b: Big
		big_set_u64(&b, 1)
		big_mul_pow5(&b, n5)
		bd := big_bitlen(&d)
		bb := big_bitlen(&b)
		sh := bb - bd + 68
		if sh >= 0 {
			big_shl(&d, sh)
		} else {
			big_shl(&b, -sh)
		}
		big_shl(&b, 69)
		q: u128 = 0
		for bit := 69; bit >= 0; bit -= 1 {
			if big_cmp(&d, &b) >= 0 {
				big_sub(&d, &b)
				q |= u128(1) << uint(bit)
			}
			big_shr1(&b)
		}
		sticky := !big_is_zero(&d)
		r = round_bits(neg, q, -sh - n5, sticky)
	}
	if r.class != .Finite {
		return {}, false
	}
	return r, true
}

@(private)
parse_hex :: proc "contextless" (neg: bool, s: []u8) -> (F80, bool) {
	n := len(s)
	i := 0
	int_start := i
	for i < n && hex_val(s[i]) >= 0 {
		i += 1
	}
	int_end := i
	frac_start, frac_end := i, i
	if i < n && s[i] == '.' {
		i += 1
		frac_start = i
		for i < n && hex_val(s[i]) >= 0 {
			i += 1
		}
		frac_end = i
	}
	if int_end == int_start && frac_end == frac_start {
		return {}, false
	}
	exp2 := 0
	if i < n && (s[i] == 'p' || s[i] == 'P') {
		j := i + 1
		v, ok := parse_exp_digits(s, &j)
		if !ok {
			return {}, false
		}
		exp2 = v
		i = j
	}
	if i != n {
		return {}, false
	}
	nibbles: [MAX_LONG_DOUBLE_CHARS]u8
	nd := 0
	for k in int_start ..< int_end {
		v := u8(hex_val(s[k]))
		if nd == 0 && v == 0 {
			continue
		}
		nibbles[nd] = v
		nd += 1
	}
	e2 := exp2
	for k in frac_start ..< frac_end {
		e2 -= 4
		v := u8(hex_val(s[k]))
		if nd == 0 && v == 0 {
			continue
		}
		nibbles[nd] = v
		nd += 1
	}
	for nd > 0 && nibbles[nd - 1] == 0 {
		nd -= 1
		e2 += 4
	}
	if nd == 0 {
		return zero(neg), true
	}
	mag2 := nd * 4 + e2
	if mag2 > 16400 || mag2 < -16500 {
		return {}, false
	}
	h: Big
	for k in 0 ..< nd {
		big_mul_small(&h, 16)
		big_add_small(&h, u32(nibbles[k]))
	}
	top, sh, sticky := big_top128(&h)
	r := round_bits(neg, top, e2 + sh, sticky)
	if r.class != .Finite {
		return {}, false
	}
	return r, true
}

@(private)
write_u128 :: proc "contextless" (buf: []u8, v: u128) -> int {
	tmp: [40]u8
	n := 0
	v := v
	for {
		tmp[n] = u8('0' + v % 10)
		n += 1
		v /= 10
		if v == 0 {
			break
		}
	}
	for i in 0 ..< n {
		buf[i] = tmp[n - 1 - i]
	}
	return n
}

@(private)
write_big :: proc "contextless" (buf: []u8, b: ^Big) -> int {
	chunks: [BIG_LIMBS * 2]u32
	nc := 0
	for !big_is_zero(b) {
		chunks[nc] = big_divmod_small(b, 1_000_000_000)
		nc += 1
	}
	if nc == 0 {
		buf[0] = '0'
		return 1
	}
	pos := write_u128(buf, u128(chunks[nc - 1]))
	for c := nc - 2; c >= 0; c -= 1 {
		v := chunks[c]
		for k := 8; k >= 0; k -= 1 {
			buf[pos + k] = u8('0' + v % 10)
			v /= 10
		}
		pos += 9
	}
	return pos
}

format_human :: proc "contextless" (v: F80, buf: []u8) -> int {
	switch v.class {
	case .NaN:
		copy(buf, "nan")
		return 3
	case .Inf:
		if v.neg {
			copy(buf, "-inf")
			return 4
		}
		copy(buf, "inf")
		return 3
	case .Zero:
		buf[0] = '0'
		return 1
	case .Finite:
	}
	pos := 0
	if v.neg {
		buf[0] = '-'
		pos = 1
	}
	if v.exp >= 0 {
		if v.exp < 64 {
			pos += write_u128(buf[pos:], u128(v.mant) << uint(v.exp))
		} else {
			b: Big
			big_set_u64(&b, v.mant)
			big_shl(&b, int(v.exp))
			pos += write_big(buf[pos:], &b)
		}
		return pos
	}
	sh := -int(v.exp)
	big_n := u128(v.mant) * POW10_17
	r: u128 = 0
	if sh < 128 {
		r = big_n >> uint(sh)
		rem := big_n & ((u128(1) << uint(sh)) - 1)
		half := u128(1) << uint(sh - 1)
		if rem > half || (rem == half && (r & 1) == 1) {
			r += 1
		}
	}
	ip := r / POW10_17
	fp := u64(r % POW10_17)
	pos += write_u128(buf[pos:], ip)
	buf[pos] = '.'
	pos += 1
	for k := 16; k >= 0; k -= 1 {
		buf[pos + k] = u8('0' + fp % 10)
		fp /= 10
	}
	pos += 17
	for buf[pos - 1] == '0' {
		pos -= 1
	}
	if buf[pos - 1] == '.' {
		pos -= 1
	}
	if pos == 2 && buf[0] == '-' && buf[1] == '0' {
		buf[0] = '0'
		pos = 1
	}
	return pos
}

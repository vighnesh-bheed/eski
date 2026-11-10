package vmath

import "base:intrinsics"
import "core:math"
import "core:simd"

F16_SUB_SCALE :: f32(1.0 / 16777216.0)

f16_to_f32 :: proc "contextless" (h: u16) -> f32 {
	sign := u32(h & 0x8000) << 16
	e := u32(h >> 10) & 0x1F
	m := u32(h) & 0x3FF
	if e == 0x1F {
		if m == 0 {
			return transmute(f32)(sign | 0x7F800000)
		}
		return transmute(f32)(sign | 0x7FC00000 | (m << 13))
	}
	if e == 0 {
		v := f32(m) * F16_SUB_SCALE
		return -v if sign != 0 else v
	}
	return transmute(f32)(sign | ((e + 112) << 23) | (m << 13))
}

f32_to_f16_away :: proc "contextless" (x: f32) -> u16 {
	b := transmute(u32)x
	sign := u16((b >> 16) & 0x8000)
	e := i32((b >> 23) & 0xFF)
	m := b & 0x7FFFFF
	if e == 0xFF {
		if m == 0 {
			return sign | 0x7C00
		}
		return sign | 0x7E00 | u16(m >> 13)
	}
	if e == 0 {
		return sign
	}
	full := m | 0x800000
	exp := e - 127
	if exp >= 16 {
		return sign | 0x7C00
	}
	shift: u32 = 13
	hexp: u32 = u32(exp + 15)
	if exp < -14 {
		extra := u32(-14 - exp)
		if extra > 11 {
			return sign
		}
		shift += extra
		hexp = 0
	}
	q := full >> shift
	rem := full & ((u32(1) << shift) - 1)
	up: u32 = 1 if rem >= (u32(1) << (shift - 1)) else 0
	if hexp == 0 {
		return sign | u16(q + up)
	}
	v := ((hexp << 10) | (q & 0x3FF)) + up
	if v >= 0x7C00 {
		return sign | 0x7C00
	}
	return sign | u16(v)
}

bf16_to_f32 :: #force_inline proc "contextless" (h: u16) -> f32 {
	return transmute(f32)(u32(h) << 16)
}

f32_to_bf16_rne :: proc "contextless" (x: f32) -> u16 {
	b := transmute(u32)x
	if b & 0x7F800000 == 0x7F800000 && b & 0x7FFFFF != 0 {
		return u16((b | 0x400000) >> 16)
	}
	b += 0x7FFF + ((b >> 16) & 1)
	return u16(b >> 16)
}

search_norm_f32 :: proc "contextless" (x: []f32) -> f32 {
	s: f64
	for v in x {
		s += f64(v) * f64(v)
	}
	return f32(math.sqrt(s))
}

search_norm_f64 :: proc "contextless" (x: []f64) -> f64 {
	s: f64
	for v in x {
		s += v * v
	}
	return math.sqrt(s)
}

search_norm_half :: proc "contextless" (x: []u16, bf: bool) -> f32 {
	s: f32
	for h in x {
		v := bf16_to_f32(h) if bf else f16_to_f32(h)
		s = s + v * v
	}
	return math.sqrt(s)
}

search_norm_int :: proc "contextless" (x: []u8, signed: bool) -> f32 {
	s: i64
	for b in x {
		v := i64(i8(b)) if signed else i64(b)
		s += v * v
	}
	return f32(math.sqrt(f64(s)))
}

search_encode :: proc "contextless" (elem: Elem, metric: Metric, blob: []u8, out: []u8) -> (aux: f32) {
	if metric != .Cosine {
		copy(out, blob)
		return
	}
	switch elem {
	case .F32:
		x := f32_view(blob)
		o := f32_view(out)
		n := search_norm_f32(x)
		for v, i in x {
			o[i] = v / n
		}
	case .F64:
		x := f64_view(blob)
		o := f64_view(out)
		n := search_norm_f64(x)
		for v, i in x {
			o[i] = v / n
		}
	case .F16:
		x := u16_view(blob)
		o := u16_view(out)
		n := search_norm_half(x, false)
		for h, i in x {
			o[i] = f32_to_f16_away(f16_to_f32(h) / n)
		}
	case .BF16:
		x := u16_view(blob)
		o := u16_view(out)
		n := search_norm_half(x, true)
		for h, i in x {
			o[i] = f32_to_bf16_rne(bf16_to_f32(h) / n)
		}
	case .Int8, .U8:
		copy(out, blob)
		aux = search_norm_int(blob, elem == .Int8)
	case .Bin:
	}
	return
}

f16x8_soft :: #force_inline proc "contextless" (v: U16x8) -> F32x8 {
	h := cast(U32x8)v
	sign := simd.shl(h & U32x8(0x8000), U32x8(16))
	em := h & U32x8(0x7FFF)
	normal := simd.shl(em, U32x8(13)) + U32x8(112 << 23)
	special := simd.shl(em, U32x8(13)) | U32x8(0x7F800000)
	special = simd.select(simd.lanes_gt(em, U32x8(0x7C00)), special | U32x8(0x400000), special)
	tiny := transmute(U32x8)(cast(F32x8)em * F32x8(F16_SUB_SCALE))
	out := simd.select(simd.lanes_ge(em, U32x8(0x7C00)), special, normal)
	out = simd.select(simd.lanes_lt(em, U32x8(0x0400)), tiny, out)
	return transmute(F32x8)(out | sign)
}

f16x8_hard :: #force_inline proc "contextless" (v: U16x8) -> F32x8 {
	return cast(F32x8)transmute(#simd[8]f16)v
}

f32x8_load :: #force_inline proc "contextless" (p: [^]f32) -> F32x8 {
	return intrinsics.unaligned_load((^F32x8)(p))
}

lane_sum8 :: #force_inline proc "contextless" (v: F32x8) -> f32 {
	s := simd.extract(v, 0)
	s = s + simd.extract(v, 1)
	s = s + simd.extract(v, 2)
	s = s + simd.extract(v, 3)
	s = s + simd.extract(v, 4)
	s = s + simd.extract(v, 5)
	s = s + simd.extract(v, 6)
	s = s + simd.extract(v, 7)
	return s
}

qe_f32_term :: #force_inline proc "contextless" (x: F32x8, y: F32x8, $L2: bool) -> F32x8 {
	when L2 {
		d := y - x
		return d * d
	} else {
		return y * x
	}
}

I16x8 :: #simd[8]i16
I64x4 :: #simd[4]i64

LANES8 :: I32x8{0, 1, 2, 3, 4, 5, 6, 7}
LANES8_16 :: I16x8{0, 1, 2, 3, 4, 5, 6, 7}
LANES16 :: I16x16{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
LANES4 :: I64x4{0, 1, 2, 3}

qe_f32_sum :: #force_inline proc "contextless" (q: [^]f32, s: [^]f32, n: int, $L2: bool) -> f32 #no_bounds_check {
	acc0: F32x8
	acc1: F32x8
	acc2: F32x8
	acc3: F32x8
	r := n & 31
	m := r & 7
	if m != 0 {
		mask := simd.lanes_lt(LANES8, I32x8(i32(m)))
		x := simd.masked_load((^F32x8)(q), F32x8{}, mask)
		y := simd.masked_load((^F32x8)(s), F32x8{}, mask)
		acc0 = acc0 + qe_f32_term(x, y, L2)
	}
	i := m
	if r - m >= 8 {
		acc1 = acc1 + qe_f32_term(f32x8_load(q[i:]), f32x8_load(s[i:]), L2)
		i += 8
	}
	if r - m >= 16 {
		acc2 = acc2 + qe_f32_term(f32x8_load(q[i:]), f32x8_load(s[i:]), L2)
		i += 8
	}
	if r - m >= 24 {
		acc3 = acc3 + qe_f32_term(f32x8_load(q[i:]), f32x8_load(s[i:]), L2)
		i += 8
	}
	for ; i < n; i += 32 {
		acc0 = acc0 + qe_f32_term(f32x8_load(q[i:]), f32x8_load(s[i:]), L2)
		acc1 = acc1 + qe_f32_term(f32x8_load(q[i + 8:]), f32x8_load(s[i + 8:]), L2)
		acc2 = acc2 + qe_f32_term(f32x8_load(q[i + 16:]), f32x8_load(s[i + 16:]), L2)
		acc3 = acc3 + qe_f32_term(f32x8_load(q[i + 24:]), f32x8_load(s[i + 24:]), L2)
	}
	return lane_sum8((acc0 + acc1) + (acc2 + acc3))
}

qe_f16_step :: #force_inline proc "contextless" (acc: F32x8, x: F32x8, y: F32x8, $L2: bool) -> F32x8 {
	when L2 {
		d := x - y
		return simd.fma(d, d, acc)
	} else {
		return acc + x * y
	}
}

u16x8_load :: #force_inline proc "contextless" (p: [^]u16) -> U16x8 {
	return intrinsics.unaligned_load((^U16x8)(p))
}

qe_f16_sum :: #force_inline proc "contextless" (q: [^]u16, s: [^]u16, n: int, $L2: bool, $widen: proc "contextless" (v: U16x8) -> F32x8) -> f32 #no_bounds_check {
	acc0: F32x8
	acc1: F32x8
	acc2: F32x8
	acc3: F32x8
	r := n & 31
	m := r & 7
	if m != 0 {
		mask := simd.lanes_lt(LANES8_16, I16x8(i16(m)))
		acc0 = qe_f16_step(acc0, widen(simd.masked_load((^U16x8)(q), U16x8{}, mask)), widen(simd.masked_load((^U16x8)(s), U16x8{}, mask)), L2)
	}
	i := m
	if r - m >= 8 {
		acc1 = qe_f16_step(acc1, widen(u16x8_load(q[i:])), widen(u16x8_load(s[i:])), L2)
		i += 8
	}
	if r - m >= 16 {
		acc2 = qe_f16_step(acc2, widen(u16x8_load(q[i:])), widen(u16x8_load(s[i:])), L2)
		i += 8
	}
	if r - m >= 24 {
		acc3 = qe_f16_step(acc3, widen(u16x8_load(q[i:])), widen(u16x8_load(s[i:])), L2)
		i += 8
	}
	for ; i < n; i += 32 {
		acc0 = qe_f16_step(acc0, widen(u16x8_load(q[i:])), widen(u16x8_load(s[i:])), L2)
		acc1 = qe_f16_step(acc1, widen(u16x8_load(q[i + 8:])), widen(u16x8_load(s[i + 8:])), L2)
		acc2 = qe_f16_step(acc2, widen(u16x8_load(q[i + 16:])), widen(u16x8_load(s[i + 16:])), L2)
		acc3 = qe_f16_step(acc3, widen(u16x8_load(q[i + 24:])), widen(u16x8_load(s[i + 24:])), L2)
	}
	return lane_sum8((acc0 + acc1) + (acc2 + acc3))
}

bf16_split :: #force_inline proc "contextless" (v: U16x16) -> (lo: F32x8, hi: F32x8) {
	l := simd.shuffle(v, v, 0, 1, 2, 3, 8, 9, 10, 11)
	h := simd.shuffle(v, v, 4, 5, 6, 7, 12, 13, 14, 15)
	lo = transmute(F32x8)simd.shl(cast(U32x8)l, U32x8(16))
	hi = transmute(F32x8)simd.shl(cast(U32x8)h, U32x8(16))
	return
}

qe_bf16_term :: #force_inline proc "contextless" (x: F32x8, y: F32x8, $L2: bool) -> F32x8 {
	when L2 {
		d := x - y
		return d * d
	} else {
		return x * y
	}
}

qe_bf16_block :: #force_inline proc "contextless" (acc: F32x8, q: U16x16, s: U16x16, $L2: bool) -> F32x8 {
	ql, qh := bf16_split(q)
	sl, sh := bf16_split(s)
	a := acc + qe_bf16_term(ql, sl, L2)
	return a + qe_bf16_term(qh, sh, L2)
}

qe_bf16_sum :: #force_inline proc "contextless" (q: [^]u16, s: [^]u16, n: int, $L2: bool) -> f32 #no_bounds_check {
	if n < BF16_WIDE_MIN {
		t: f32
		for i in 0 ..< n {
			x := bf16_to_f32(q[i])
			y := bf16_to_f32(s[i])
			when L2 {
				d := x - y
				t = t + d * d
			} else {
				t = t + x * y
			}
		}
		return t
	}
	acc: F32x8
	r := n & 15
	if r != 0 {
		mask := simd.lanes_lt(LANES16, I16x16(i16(r)))
		acc = qe_bf16_block(acc, simd.masked_load((^U16x16)(q), U16x16{}, mask), simd.masked_load((^U16x16)(s), U16x16{}, mask), L2)
	}
	for i := r; i < n; i += 16 {
		acc = qe_bf16_block(acc, intrinsics.unaligned_load((^U16x16)(q[i:])), intrinsics.unaligned_load((^U16x16)(s[i:])), L2)
	}
	return lane_sum8(acc)
}

qe_f64_term :: #force_inline proc "contextless" (q: [^]f64, s: [^]f64, i: int, $L2: bool) -> F64x4 {
	x := intrinsics.unaligned_load((^F64x4)(q[i:]))
	y := intrinsics.unaligned_load((^F64x4)(s[i:]))
	when L2 {
		d := y - x
		return d * d
	} else {
		return y * x
	}
}

qe_f64_sum :: #force_inline proc "contextless" (q: [^]f64, s: [^]f64, n: int, $L2: bool) -> f64 #no_bounds_check {
	acc0: F64x4
	acc1: F64x4
	r := n & 7
	m := r & 3
	if m != 0 {
		mask := simd.lanes_lt(LANES4, I64x4(i64(m)))
		x := simd.masked_load((^F64x4)(q), F64x4{}, mask)
		y := simd.masked_load((^F64x4)(s), F64x4{}, mask)
		when L2 {
			d := y - x
			acc0 = acc0 + d * d
		} else {
			acc0 = acc0 + y * x
		}
	}
	i := m
	if r - m >= 4 {
		acc1 = acc1 + qe_f64_term(q, s, i, L2)
		i += 4
	}
	for ; i < n; i += 8 {
		acc0 = acc0 + qe_f64_term(q, s, i, L2)
		acc1 = acc1 + qe_f64_term(q, s, i + 4, L2)
	}
	v := acc0 + acc1
	return ((simd.extract(v, 0) + simd.extract(v, 1)) + simd.extract(v, 2)) + simd.extract(v, 3)
}

qe_int_l2 :: #force_inline proc "contextless" (q: [^]u8, s: [^]u8, n: int, $signed: bool) -> i64 #no_bounds_check {
	total: i64
	i := 0
	full := n &~ 15
	for i < full {
		end := min(full, i + I8_CHUNK)
		acc: I32x8
		for ; i < end; i += 16 {
			x: I16x16
			y: I16x16
			when signed {
				x = cast(I16x16)intrinsics.unaligned_load((^I8x16)(q[i:]))
				y = cast(I16x16)intrinsics.unaligned_load((^I8x16)(s[i:]))
			} else {
				x = cast(I16x16)cast(U16x16)intrinsics.unaligned_load((^U8x16)(q[i:]))
				y = cast(I16x16)cast(U16x16)intrinsics.unaligned_load((^U8x16)(s[i:]))
			}
			d := cast(I32x16)(x - y)
			sq := d * d
			acc += simd.shuffle(sq, sq, 0, 2, 4, 6, 8, 10, 12, 14) + simd.shuffle(sq, sq, 1, 3, 5, 7, 9, 11, 13, 15)
		}
		total += simd.reduce_add_ordered(cast(#simd[8]i64)acc)
	}
	for ; i < n; i += 1 {
		d: i64
		when signed {
			d = i64(i8(q[i])) - i64(i8(s[i]))
		} else {
			d = i64(q[i]) - i64(s[i])
		}
		total += d * d
	}
	return total
}

qe_int_cosine :: #force_inline proc "contextless" (dot: i64, na: f32, nb: f32) -> f32 {
	return 1 - f32(dot) / (na * nb)
}

nan_sign :: proc "contextless" (p: [^]u8, n: int, elem: Elem) -> (sign: u32, found: bool) #no_bounds_check {
	#partial switch elem {
	case .F32:
		v := ([^]u32)(p)
		for i in 0 ..< n {
			if v[i] & 0x7F800000 == 0x7F800000 && v[i] & 0x7FFFFF != 0 {
				return v[i] >> 31, true
			}
		}
	case .F64:
		v := ([^]u64)(p)
		for i in 0 ..< n {
			if v[i] & 0x7FF0000000000000 == 0x7FF0000000000000 && v[i] & 0xFFFFFFFFFFFFF != 0 {
				return u32(v[i] >> 63), true
			}
		}
	case .F16:
		v := ([^]u16)(p)
		for i in 0 ..< n {
			if v[i] & 0x7C00 == 0x7C00 && v[i] & 0x3FF != 0 {
				return u32(v[i] >> 15), true
			}
		}
	case .BF16:
		v := ([^]u16)(p)
		for i in 0 ..< n {
			if v[i] & 0x7F80 == 0x7F80 && v[i] & 0x7F != 0 {
				return u32(v[i] >> 15), true
			}
		}
	}
	return
}

qe_nan_side :: proc "contextless" (q: [^]u8, s: [^]u8, n: int, elem: Elem) -> (sign: u32, found: bool) {
	first, second := s, q
	if elem == .F16 || elem == .BF16 {
		first, second = q, s
	}
	sign, found = nan_sign(first, n, elem)
	if !found {
		sign, found = nan_sign(second, n, elem)
	}
	return
}

qe_nan32 :: proc "contextless" (d: f32, q: [^]u8, s: [^]u8, n: int, elem: Elem) -> f32 {
	sign, found := qe_nan_side(q, s, n, elem)
	if !found {
		return d
	}
	return transmute(f32)((transmute(u32)d &~ 0x80000000) | (sign << 31))
}

qe_nan64 :: proc "contextless" (d: f64, q: [^]u8, s: [^]u8, n: int) -> f64 {
	sign, found := qe_nan_side(q, s, n, .F64)
	if !found {
		return d
	}
	return transmute(f64)((transmute(u64)d &~ 0x8000000000000000) | (u64(sign) << 63))
}

qe_fix32 :: #force_inline proc "contextless" (d: f32, q: [^]u8, s: [^]u8, n: int, $elem: Elem) -> f32 {
	if d == d {
		return d
	}
	return qe_nan32(d, q, s, n, elem)
}

qe_fix64 :: #force_inline proc "contextless" (d: f64, q: [^]u8, s: [^]u8, n: int) -> f64 {
	if d == d {
		return d
	}
	return qe_nan64(d, q, s, n)
}

qe_f32_l2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(qe_f32_sum(([^]f32)(a), ([^]f32)(b), dim, true), a, b, dim, .F32)
}

qe_f32_ip :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(1 - qe_f32_sum(([^]f32)(a), ([^]f32)(b), dim, false), a, b, dim, .F32)
}

qe_f16_l2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(qe_f16_sum(([^]u16)(a), ([^]u16)(b), dim, true, f16x8_soft), a, b, dim, .F16)
}

qe_f16_ip :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(1 - qe_f16_sum(([^]u16)(a), ([^]u16)(b), dim, false, f16x8_soft), a, b, dim, .F16)
}

qe_bf16_l2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(qe_bf16_sum(([^]u16)(a), ([^]u16)(b), dim, true), a, b, dim, .BF16)
}

qe_bf16_ip :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(1 - qe_bf16_sum(([^]u16)(a), ([^]u16)(b), dim, false), a, b, dim, .BF16)
}

qe_f64_l2_exact :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f64 {
	return qe_fix64(qe_f64_sum(([^]f64)(a), ([^]f64)(b), dim, true), a, b, dim)
}

qe_f64_ip_exact :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f64 {
	return qe_fix64(1 - qe_f64_sum(([^]f64)(a), ([^]f64)(b), dim, false), a, b, dim)
}

qe_f64_l2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(qe_fix64(qe_f64_sum(([^]f64)(a), ([^]f64)(b), dim, true), a, b, dim))
}

qe_f64_ip :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(qe_fix64(1 - qe_f64_sum(([^]f64)(a), ([^]f64)(b), dim, false), a, b, dim))
}

qe_i8_l2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(qe_int_l2(a, b, dim, true))
}

qe_u8_l2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(qe_int_l2(a, b, dim, false))
}

qe_i8_ip :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(1 - dot_i8_base(([^]i8)(a), ([^]i8)(b), dim))
}

qe_u8_ip :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(1 - dot_u8_base(a, b, dim))
}

qe_i8_cosine :: proc "contextless" (a: [^]u8, na: f32, b: [^]u8, nb: f32, dim: int) -> f32 {
	return qe_int_cosine(dot_i8_base(([^]i8)(a), ([^]i8)(b), dim), na, nb)
}

qe_u8_cosine :: proc "contextless" (a: [^]u8, na: f32, b: [^]u8, nb: f32, dim: int) -> f32 {
	return qe_int_cosine(dot_u8_base(a, b, dim), na, nb)
}

search_base_kernels :: proc "contextless" (k: ^Kernel_Set) {
	k[.Search].score[.F64] = {.L2 = qe_f64_l2_exact, .IP = qe_f64_ip_exact, .Cosine = qe_f64_ip_exact}
}

package vmath

import "base:intrinsics"
import "core:math"

sum_squares :: proc "contextless" (x: []f32) -> f32 {
	n := len(x)
	s: f32
	i := 0
	for ; i + 4 <= n; i += 4 {
		s = s + (((x[i] * x[i] + x[i + 1] * x[i + 1]) + x[i + 2] * x[i + 2]) + x[i + 3] * x[i + 3])
	}
	for ; i < n; i += 1 {
		s = s + x[i] * x[i]
	}
	return s
}

l2_norm :: proc "contextless" (x: []f32) -> f32 {
	return math.sqrt(sum_squares(x))
}

stored_norm :: #force_inline proc "contextless" (norm: f32) -> f32 {
	return 1 if norm == 0 else norm
}

normalise :: proc "contextless" (x: []f32, out: []f32) -> (norm: f32) {
	n := min(len(x), len(out))
	norm = stored_norm(l2_norm(x[:n]))
	for i in 0 ..< n {
		out[i] = x[i] / norm
	}
	return
}

q8_round :: #force_inline proc "contextless" (t: f32) -> i8 {
	if math.is_nan(t) || math.is_inf(t) {
		return 0
	}
	return i8(math.round(clamp(t, -Q8_SCALE, Q8_SCALE)))
}

q8_range :: proc "contextless" (xn: []f32) -> (range: f32) {
	for v in xn {
		if abs(v) > range {
			range = abs(v)
		}
	}
	return
}

quantise_i8 :: proc "contextless" (xn: []f32, out: []i8) -> (range: f32) {
	n := min(len(xn), len(out))
	range = q8_range(xn[:n])
	if range == 0 {
		for i in 0 ..< n {
			out[i] = 0
		}
		return
	}
	scale := Q8_SCALE / range
	for i in 0 ..< n {
		out[i] = q8_round(xn[i] * scale)
	}
	return
}

pack_bits :: proc "contextless" (xn: []f32, out: []u64) {
	for &w in out {
		w = 0
	}
	for v, i in xn {
		if v > 0 {
			out[i >> 6] |= u64(1) << uint(i & 63)
		}
	}
}

encode :: proc "contextless" (elem: Elem, x: []f32, out: []u8) -> (norm: f32, range: f32) {
	norm = stored_norm(l2_norm(x))
	range = encode_scaled(elem, x, norm, out)
	return
}

encode_normalised :: proc "contextless" (elem: Elem, xn: []f32, out: []u8) -> (range: f32) {
	return encode_scaled(elem, xn, 1, out)
}

encode_scaled :: proc "contextless" (elem: Elem, x: []f32, divisor: f32, out: []u8) -> (range: f32) {
	n := len(x)
	switch elem {
	case .F32:
		v := f32_view(out)
		for i in 0 ..< n {
			v[i] = x[i] / divisor
		}
	case .Int8:
		q := i8_view(out)
		for i in 0 ..< n {
			a := abs(x[i] / divisor)
			if a > range {
				range = a
			}
		}
		if range == 0 {
			for i in 0 ..< n {
				q[i] = 0
			}
			return
		}
		scale := Q8_SCALE / range
		for i in 0 ..< n {
			q[i] = q8_round((x[i] / divisor) * scale)
		}
	case .Bin:
		w := u64_view(out)
		for &b in w {
			b = 0
		}
		for i in 0 ..< n {
			if x[i] / divisor > 0 {
				w[i >> 6] |= u64(1) << uint(i & 63)
			}
		}
	case .F64, .F16, .BF16, .U8:
	}
	return
}

decode :: proc "contextless" (elem: Elem, data: []u8, norm: f32, range: f32, out: []f32) {
	switch elem {
	case .F32:
		v := f32_view(data)
		for i in 0 ..< len(out) {
			out[i] = v[i] * norm
		}
	case .Int8:
		q := i8_view(data)
		for i in 0 ..< len(out) {
			out[i] = f32(q[i]) * range / Q8_SCALE * norm
		}
	case .Bin:
		w := u64_view(data)
		for i in 0 ..< len(out) {
			out[i] = 1 if (w[i >> 6] >> uint(i & 63)) & 1 != 0 else -1
		}
	case .F64, .F16, .BF16, .U8:
	}
}

bin_padding_clear :: proc "contextless" (words: []u64, dim: int) -> bool {
	tail := dim & 63
	if tail == 0 || len(words) == 0 {
		return true
	}
	return words[len(words) - 1] >> uint(tail) == 0
}

fma_f32 :: #force_inline proc "contextless" (a: f32, b: f32, c: f32) -> f32 {
	return intrinsics.fused_mul_add(a, b, c)
}

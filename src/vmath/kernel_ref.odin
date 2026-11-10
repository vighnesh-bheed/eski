package vmath

import "base:intrinsics"

dot_f32_short :: proc "contextless" (a: [^]f32, b: [^]f32, n: int) -> f32 #no_bounds_check {
	acc0: f32
	acc1: f32
	i := 0
	for ; i + 8 <= n; i += 8 {
		acc0 = acc0 + (((a[i] * b[i] + a[i + 1] * b[i + 1]) + a[i + 2] * b[i + 2]) + a[i + 3] * b[i + 3])
		acc1 = acc1 + (((a[i + 4] * b[i + 4] + a[i + 5] * b[i + 5]) + a[i + 6] * b[i + 6]) + a[i + 7] * b[i + 7])
	}
	for ; i < n; i += 1 {
		acc0 = acc0 + a[i] * b[i]
	}
	return acc0 + acc1
}

dot_f32_tail :: #force_inline proc "contextless" (a: [^]f32, b: [^]f32, start: int, n: int, s: f32) -> f32 #no_bounds_check {
	r := s
	i := start
	for ; i + 4 <= n; i += 4 {
		r = r + a[i] * b[i]
		r = r + a[i + 1] * b[i + 1]
		r = r + a[i + 2] * b[i + 2]
		r = r + a[i + 3] * b[i + 3]
	}
	for ; i < n; i += 1 {
		r = fma_f32(a[i], b[i], r)
	}
	return r
}

dot_f32_ref :: proc "contextless" (a: []f32, b: []f32) -> f32 {
	n := min(len(a), len(b))
	if n < F32_WIDE_MIN {
		return dot_f32_short(raw_data(a), raw_data(b), n)
	}
	acc: [2][8]f32
	i := 0
	for ; i + 16 <= n; i += 16 {
		for k in 0 ..< 2 {
			for j in 0 ..< 8 {
				acc[k][j] = fma_f32(a[i + 8 * k + j], b[i + 8 * k + j], acc[k][j])
			}
		}
	}
	v: [8]f32
	for j in 0 ..< 8 {
		v[j] = acc[0][j] + acc[1][j]
	}
	f := [4]f32{v[0] + v[4], v[1] + v[5], v[2] + v[6], v[3] + v[7]}
	s := (f[0] + f[1]) + (f[2] + f[3])
	return dot_f32_tail(raw_data(a), raw_data(b), i, n, s)
}

dot_i8_ref :: proc "contextless" (a: []i8, b: []i8) -> i64 {
	n := min(len(a), len(b))
	s: i64
	for i in 0 ..< n {
		s += i64(a[i]) * i64(b[i])
	}
	return s
}

hamming_ref :: proc "contextless" (a: []u64, b: []u64) -> u64 {
	n := min(len(a), len(b))
	s: u64
	for i in 0 ..< n {
		s += u64(intrinsics.count_ones(a[i] ~ b[i]))
	}
	return s
}

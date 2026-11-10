package vmath

import "base:intrinsics"
import "core:simd"

F32x4 :: #simd[4]f32
F32x8 :: #simd[8]f32
F64x4 :: #simd[4]f64
I8x16 :: #simd[16]i8
U8x16 :: #simd[16]u8
I16x16 :: #simd[16]i16
I32x8 :: #simd[8]i32
I32x16 :: #simd[16]i32
U16x8 :: #simd[8]u16
U16x16 :: #simd[16]u16
U32x8 :: #simd[8]u32
U64x4 :: #simd[4]u64

base_kernels :: proc "contextless" (k: ^Kernel_Set) {
	k[.Vector_Set].score[.F32][.Cosine] = score_f32_base
	k[.Vector_Set].score[.Int8][.Cosine] = score_i8_base
	k[.Vector_Set].score[.Bin][.Cosine] = score_bin_base
	for &f in k {
		f.dot_f32 = dot_f32_fast_base
		f.dot_f32_exact = dot_f32_exact_base
		f.dot_i8 = dot_i8_base
		f.dot_u8 = dot_u8_base
		f.hamming = hamming_base
	}
	search_base_kernels(k)
	batch_kernels(k)
}

dot_f32_exact_base :: proc "contextless" (a: [^]f32, b: [^]f32, n: int) -> f32 #no_bounds_check {
	if n < F32_WIDE_MIN {
		return dot_f32_short(a, b, n)
	}
	lo0: F32x4
	hi0: F32x4
	lo1: F32x4
	hi1: F32x4
	i := 0
	for ; i + 16 <= n; i += 16 {
		lo0 = simd.fma(intrinsics.unaligned_load((^F32x4)(a[i:])), intrinsics.unaligned_load((^F32x4)(b[i:])), lo0)
		hi0 = simd.fma(intrinsics.unaligned_load((^F32x4)(a[i + 4:])), intrinsics.unaligned_load((^F32x4)(b[i + 4:])), hi0)
		lo1 = simd.fma(intrinsics.unaligned_load((^F32x4)(a[i + 8:])), intrinsics.unaligned_load((^F32x4)(b[i + 8:])), lo1)
		hi1 = simd.fma(intrinsics.unaligned_load((^F32x4)(a[i + 12:])), intrinsics.unaligned_load((^F32x4)(b[i + 12:])), hi1)
	}
	s := simd.reduce_add_pairs((lo0 + lo1) + (hi0 + hi1))
	return dot_f32_tail(a, b, i, n, s)
}

dot_f32_fast_base :: proc "contextless" (a: [^]f32, b: [^]f32, n: int) -> f32 #no_bounds_check {
	acc0: F32x4
	acc1: F32x4
	acc2: F32x4
	acc3: F32x4
	i := 0
	for ; i + 16 <= n; i += 16 {
		acc0 = acc0 + intrinsics.unaligned_load((^F32x4)(a[i:])) * intrinsics.unaligned_load((^F32x4)(b[i:]))
		acc1 = acc1 + intrinsics.unaligned_load((^F32x4)(a[i + 4:])) * intrinsics.unaligned_load((^F32x4)(b[i + 4:]))
		acc2 = acc2 + intrinsics.unaligned_load((^F32x4)(a[i + 8:])) * intrinsics.unaligned_load((^F32x4)(b[i + 8:]))
		acc3 = acc3 + intrinsics.unaligned_load((^F32x4)(a[i + 12:])) * intrinsics.unaligned_load((^F32x4)(b[i + 12:]))
	}
	if i + 4 <= n {
		acc0 = acc0 + intrinsics.unaligned_load((^F32x4)(a[i:])) * intrinsics.unaligned_load((^F32x4)(b[i:]))
		i += 4
	}
	if i + 4 <= n {
		acc1 = acc1 + intrinsics.unaligned_load((^F32x4)(a[i:])) * intrinsics.unaligned_load((^F32x4)(b[i:]))
		i += 4
	}
	if i + 4 <= n {
		acc2 = acc2 + intrinsics.unaligned_load((^F32x4)(a[i:])) * intrinsics.unaligned_load((^F32x4)(b[i:]))
		i += 4
	}
	s := simd.reduce_add_pairs((acc0 + acc1) + (acc2 + acc3))
	for ; i < n; i += 1 {
		s = s + a[i] * b[i]
	}
	return s
}

dot_i8_base :: proc "contextless" (a: [^]i8, b: [^]i8, n: int) -> i64 #no_bounds_check {
	total: i64
	i := 0
	full := n &~ 15
	for i < full {
		end := min(full, i + I8_CHUNK)
		acc: I32x16
		for ; i < end; i += 16 {
			x := cast(I32x16)intrinsics.unaligned_load((^I8x16)(a[i:]))
			y := cast(I32x16)intrinsics.unaligned_load((^I8x16)(b[i:]))
			acc += x * y
		}
		total += i64(simd.reduce_add_ordered(acc))
	}
	for ; i < n; i += 1 {
		total += i64(a[i]) * i64(b[i])
	}
	return total
}

dot_u8_base :: proc "contextless" (a: [^]u8, b: [^]u8, n: int) -> i64 #no_bounds_check {
	total: i64
	i := 0
	full := n &~ 15
	for i < full {
		end := min(full, i + I8_CHUNK)
		acc: I32x16
		for ; i < end; i += 16 {
			x := cast(I32x16)intrinsics.unaligned_load((^U8x16)(a[i:]))
			y := cast(I32x16)intrinsics.unaligned_load((^U8x16)(b[i:]))
			acc += x * y
		}
		total += simd.reduce_add_ordered(cast(#simd[16]i64)acc)
	}
	for ; i < n; i += 1 {
		total += i64(a[i]) * i64(b[i])
	}
	return total
}

hamming_base :: proc "contextless" (a: [^]u64, b: [^]u64, n: int) -> u64 #no_bounds_check {
	s0: u64
	s1: u64
	s2: u64
	s3: u64
	i := 0
	for ; i + 4 <= n; i += 4 {
		s0 += u64(intrinsics.count_ones(a[i] ~ b[i]))
		s1 += u64(intrinsics.count_ones(a[i + 1] ~ b[i + 1]))
		s2 += u64(intrinsics.count_ones(a[i + 2] ~ b[i + 2]))
		s3 += u64(intrinsics.count_ones(a[i + 3] ~ b[i + 3]))
	}
	for ; i < n; i += 1 {
		s0 += u64(intrinsics.count_ones(a[i] ~ b[i]))
	}
	return (s0 + s1) + (s2 + s3)
}

distance_f32_base :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return distance_from_dot(dot_f32_fast_base(([^]f32)(a), ([^]f32)(b), dim))
}

distance_i8_base :: proc "contextless" (a: [^]u8, range_a: f32, b: [^]u8, range_b: f32, dim: int) -> f32 {
	return distance_q8(dot_i8_base(([^]i8)(a), ([^]i8)(b), dim), range_a, range_b, dim)
}

distance_bin_base :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return distance_bin(hamming_base(([^]u64)(a), ([^]u64)(b), bin_words(dim)), dim)
}

score_f32_base :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f64 {
	return score_from_distance(distance_from_dot(dot_f32_exact_base(([^]f32)(a), ([^]f32)(b), dim)))
}

score_i8_base :: proc "contextless" (a: [^]u8, range_a: f32, b: [^]u8, range_b: f32, dim: int) -> f64 {
	return score_from_distance(distance_q8(dot_i8_base(([^]i8)(a), ([^]i8)(b), dim), range_a, range_b, dim))
}

score_bin_base :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f64 {
	return score_bin(hamming_base(([^]u64)(a), ([^]u64)(b), bin_words(dim)), dim)
}

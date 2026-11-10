#+build amd64
package vmath

import "base:intrinsics"
import "core:simd"

avx2_kernels :: proc "contextless" (k: ^Kernel_Set) {
	k[.Vector_Set].score[.F32][.Cosine] = score_f32_avx2
	k[.Vector_Set].score[.Int8][.Cosine] = score_i8_avx2
	k[.Vector_Set].score[.Bin][.Cosine] = score_bin_avx2
	for &f in k {
		f.dot_f32 = dot_f32_fast_avx2
		f.dot_f32_exact = dot_f32_exact_avx2
		f.dot_i8 = dot_i8_avx2
		f.dot_u8 = dot_u8_avx2
		f.hamming = hamming_avx2
	}
	search_avx2_kernels(k)
}

@(enable_target_feature = "avx2,fma,-slow-unaligned-mem-32")
dot_f32_exact_avx2 :: proc "contextless" (a: [^]f32, b: [^]f32, n: int) -> f32 #no_bounds_check {
	if n < F32_WIDE_MIN {
		return dot_f32_short(a, b, n)
	}
	acc0: F32x8
	acc1: F32x8
	i := 0
	for ; i + 16 <= n; i += 16 {
		acc0 = simd.fma(intrinsics.unaligned_load((^F32x8)(a[i:])), intrinsics.unaligned_load((^F32x8)(b[i:])), acc0)
		acc1 = simd.fma(intrinsics.unaligned_load((^F32x8)(a[i + 8:])), intrinsics.unaligned_load((^F32x8)(b[i + 8:])), acc1)
	}
	v := acc0 + acc1
	f := simd.shuffle(v, v, 0, 1, 2, 3) + simd.shuffle(v, v, 4, 5, 6, 7)
	s := simd.reduce_add_pairs(f)
	return dot_f32_tail(a, b, i, n, s)
}

@(enable_target_feature = "avx2,fma,-slow-unaligned-mem-32")
dot_f32_fast_avx2 :: proc "contextless" (a: [^]f32, b: [^]f32, n: int) -> f32 #no_bounds_check {
	acc: [8]F32x8
	i := 0
	for ; i + 64 <= n; i += 64 {
		#unroll for j in 0 ..< 8 {
			acc[j] = simd.fma(intrinsics.unaligned_load((^F32x8)(a[i + 8 * j:])), intrinsics.unaligned_load((^F32x8)(b[i + 8 * j:])), acc[j])
		}
	}
	#unroll for j in 0 ..< 7 {
		if i + 8 <= n {
			acc[j] = simd.fma(intrinsics.unaligned_load((^F32x8)(a[i:])), intrinsics.unaligned_load((^F32x8)(b[i:])), acc[j])
			i += 8
		}
	}
	s := simd.reduce_add_pairs(((acc[0] + acc[1]) + (acc[2] + acc[3])) + ((acc[4] + acc[5]) + (acc[6] + acc[7])))
	for ; i < n; i += 1 {
		s = s + a[i] * b[i]
	}
	return s
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
dot_i8_avx2 :: proc "contextless" (a: [^]i8, b: [^]i8, n: int) -> i64 #no_bounds_check {
	total: i64
	i := 0
	full := n &~ 31
	for i < full {
		end := min(full, i + I8_CHUNK)
		acc0: I32x16
		acc1: I32x16
		for ; i < end; i += 32 {
			x0 := cast(I32x16)intrinsics.unaligned_load((^I8x16)(a[i:]))
			y0 := cast(I32x16)intrinsics.unaligned_load((^I8x16)(b[i:]))
			x1 := cast(I32x16)intrinsics.unaligned_load((^I8x16)(a[i + 16:]))
			y1 := cast(I32x16)intrinsics.unaligned_load((^I8x16)(b[i + 16:]))
			acc0 += x0 * y0
			acc1 += x1 * y1
		}
		total += i64(simd.reduce_add_ordered(acc0 + acc1))
	}
	for ; i < n; i += 1 {
		total += i64(a[i]) * i64(b[i])
	}
	return total
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
dot_u8_avx2 :: proc "contextless" (a: [^]u8, b: [^]u8, n: int) -> i64 #no_bounds_check {
	total: i64
	i := 0
	full := n &~ 31
	for i < full {
		end := min(full, i + I8_CHUNK)
		acc0: I32x16
		acc1: I32x16
		for ; i < end; i += 32 {
			x0 := cast(I32x16)intrinsics.unaligned_load((^U8x16)(a[i:]))
			y0 := cast(I32x16)intrinsics.unaligned_load((^U8x16)(b[i:]))
			x1 := cast(I32x16)intrinsics.unaligned_load((^U8x16)(a[i + 16:]))
			y1 := cast(I32x16)intrinsics.unaligned_load((^U8x16)(b[i + 16:]))
			acc0 += x0 * y0
			acc1 += x1 * y1
		}
		total += simd.reduce_add_ordered(cast(#simd[16]i64)acc0 + cast(#simd[16]i64)acc1)
	}
	for ; i < n; i += 1 {
		total += i64(a[i]) * i64(b[i])
	}
	return total
}

@(enable_target_feature = "avx2,popcnt,-slow-unaligned-mem-32")
hamming_avx2 :: proc "contextless" (a: [^]u64, b: [^]u64, n: int) -> u64 #no_bounds_check {
	acc0: U64x4
	acc1: U64x4
	i := 0
	for ; i + 8 <= n; i += 8 {
		acc0 += intrinsics.count_ones(intrinsics.unaligned_load((^U64x4)(a[i:])) ~ intrinsics.unaligned_load((^U64x4)(b[i:])))
		acc1 += intrinsics.count_ones(intrinsics.unaligned_load((^U64x4)(a[i + 4:])) ~ intrinsics.unaligned_load((^U64x4)(b[i + 4:])))
	}
	for ; i + 4 <= n; i += 4 {
		acc0 += intrinsics.count_ones(intrinsics.unaligned_load((^U64x4)(a[i:])) ~ intrinsics.unaligned_load((^U64x4)(b[i:])))
	}
	s := simd.reduce_add_ordered(acc0 + acc1)
	for ; i < n; i += 1 {
		s += u64(intrinsics.count_ones(a[i] ~ b[i]))
	}
	return s
}

distance_f32_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return distance_from_dot(dot_f32_fast_avx2(([^]f32)(a), ([^]f32)(b), dim))
}

distance_i8_avx2 :: proc "contextless" (a: [^]u8, range_a: f32, b: [^]u8, range_b: f32, dim: int) -> f32 {
	return distance_q8(dot_i8_avx2(([^]i8)(a), ([^]i8)(b), dim), range_a, range_b, dim)
}

distance_bin_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return distance_bin(hamming_avx2(([^]u64)(a), ([^]u64)(b), bin_words(dim)), dim)
}

score_f32_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f64 {
	return score_from_distance(distance_from_dot(dot_f32_exact_avx2(([^]f32)(a), ([^]f32)(b), dim)))
}

score_i8_avx2 :: proc "contextless" (a: [^]u8, range_a: f32, b: [^]u8, range_b: f32, dim: int) -> f64 {
	return score_from_distance(distance_q8(dot_i8_avx2(([^]i8)(a), ([^]i8)(b), dim), range_a, range_b, dim))
}

score_bin_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f64 {
	return score_bin(hamming_avx2(([^]u64)(a), ([^]u64)(b), bin_words(dim)), dim)
}

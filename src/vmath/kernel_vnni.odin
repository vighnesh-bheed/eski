#+build amd64
package vmath

import "base:intrinsics"
import "core:simd"

I32x4 :: #simd[4]i32
I8x32 :: #simd[32]i8

@(private, default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.x86.avx2.vpdpbssd.256")
	vpdpbssd_256 :: proc(acc: I32x8, a: I32x8, b: I32x8) -> I32x8 ---
	@(link_name = "llvm.x86.avx2.vpdpbssd.128")
	vpdpbssd_128 :: proc(acc: I32x4, a: I32x4, b: I32x4) -> I32x4 ---
	@(link_name = "llvm.x86.avx2.vpdpbuud.256")
	vpdpbuud_256 :: proc(acc: I32x8, a: I32x8, b: I32x8) -> I32x8 ---
	@(link_name = "llvm.x86.avx2.vpdpbuud.128")
	vpdpbuud_128 :: proc(acc: I32x4, a: I32x4, b: I32x4) -> I32x4 ---
	@(link_name = "llvm.x86.avx512.vpdpbusd.256")
	vpdpbusd_256 :: proc(acc: I32x8, a: I32x8, b: I32x8) -> I32x8 ---
	@(link_name = "llvm.x86.avx512.vpdpbusd.128")
	vpdpbusd_128 :: proc(acc: I32x4, a: I32x4, b: I32x4) -> I32x4 ---
}

vnni_kernels :: proc "contextless" (k: ^Kernel_Set) {
	put(k, .Vector_Set, .Int8, .Cosine, distance_i8_vnni)
	k[.Vector_Set].score[.Int8][.Cosine] = score_i8_vnni
	for &f in k {
		f.dot_i8 = dot_i8_vnni
		f.dot_u8 = dot_u8_vnni
	}
	put(k, .Search, .Int8, .IP, qe_i8_ip_vnni)
	put(k, .Search, .Int8, .Cosine, qe_i8_cosine_vnni)
	put(k, .Search, .U8, .IP, qe_u8_ip_vnni)
	put(k, .Search, .U8, .Cosine, qe_u8_cosine_vnni)
}

vnni_int8_kernels :: proc "contextless" (k: ^Kernel_Set) {
	put(k, .Vector_Set, .Int8, .Cosine, distance_i8_vnni_int8)
	k[.Vector_Set].score[.Int8][.Cosine] = score_i8_vnni_int8
	for &f in k {
		f.dot_i8 = dot_i8_vnni_int8
		f.dot_u8 = dot_u8_vnni_int8
	}
	put(k, .Search, .Int8, .IP, qe_i8_ip_vnni_int8)
	put(k, .Search, .Int8, .Cosine, qe_i8_cosine_vnni_int8)
	put(k, .Search, .U8, .IP, qe_u8_ip_vnni_int8)
	put(k, .Search, .U8, .Cosine, qe_u8_cosine_vnni_int8)
}

@(enable_target_feature = "avx2")
ld32 :: #force_inline proc "contextless" (p: [^]u8, i: int) -> I32x8 {
	return intrinsics.unaligned_load((^I32x8)(p[i:]))
}

@(enable_target_feature = "avx2")
ld16 :: #force_inline proc "contextless" (p: [^]u8, i: int) -> I32x4 {
	return intrinsics.unaligned_load((^I32x4)(p[i:]))
}

@(enable_target_feature = "avx2")
sum8 :: #force_inline proc "contextless" (v: I32x8) -> i64 {
	return simd.reduce_add_ordered(cast(#simd[8]i64)v)
}

@(enable_target_feature = "avx2")
sum4 :: #force_inline proc "contextless" (v: I32x4) -> i64 {
	return simd.reduce_add_ordered(cast(#simd[4]i64)v)
}

@(enable_target_feature = "avx2,avxvnniint8,-slow-unaligned-mem-32")
dot_i8_vnni_int8 :: proc "contextless" (a: [^]i8, b: [^]i8, n: int) -> i64 #no_bounds_check {
	x := ([^]u8)(a)
	y := ([^]u8)(b)
	total: i64
	i := 0
	for i + 32 <= n {
		end := min(n &~ 31, i + I8_CHUNK)
		acc0: I32x8
		acc1: I32x8
		acc2: I32x8
		acc3: I32x8
		for ; i + 128 <= end; i += 128 {
			acc0 = vpdpbssd_256(acc0, ld32(x, i), ld32(y, i))
			acc1 = vpdpbssd_256(acc1, ld32(x, i + 32), ld32(y, i + 32))
			acc2 = vpdpbssd_256(acc2, ld32(x, i + 64), ld32(y, i + 64))
			acc3 = vpdpbssd_256(acc3, ld32(x, i + 96), ld32(y, i + 96))
		}
		for ; i < end; i += 32 {
			acc0 = vpdpbssd_256(acc0, ld32(x, i), ld32(y, i))
		}
		total += sum8((acc0 + acc1) + (acc2 + acc3))
	}
	if i + 16 <= n {
		total += sum4(vpdpbssd_128(I32x4{}, ld16(x, i), ld16(y, i)))
		i += 16
	}
	for ; i < n; i += 1 {
		total += i64(a[i]) * i64(b[i])
	}
	return total
}

@(enable_target_feature = "avx2,avxvnniint8,-slow-unaligned-mem-32")
dot_u8_vnni_int8 :: proc "contextless" (a: [^]u8, b: [^]u8, n: int) -> i64 #no_bounds_check {
	total: i64
	i := 0
	for i + 32 <= n {
		end := min(n &~ 31, i + I8_CHUNK)
		acc0: I32x8
		acc1: I32x8
		acc2: I32x8
		acc3: I32x8
		for ; i + 128 <= end; i += 128 {
			acc0 = vpdpbuud_256(acc0, ld32(a, i), ld32(b, i))
			acc1 = vpdpbuud_256(acc1, ld32(a, i + 32), ld32(b, i + 32))
			acc2 = vpdpbuud_256(acc2, ld32(a, i + 64), ld32(b, i + 64))
			acc3 = vpdpbuud_256(acc3, ld32(a, i + 96), ld32(b, i + 96))
		}
		for ; i < end; i += 32 {
			acc0 = vpdpbuud_256(acc0, ld32(a, i), ld32(b, i))
		}
		total += sum8((acc0 + acc1) + (acc2 + acc3))
	}
	if i + 16 <= n {
		total += sum4(vpdpbuud_128(I32x4{}, ld16(a, i), ld16(b, i)))
		i += 16
	}
	for ; i < n; i += 1 {
		total += i64(a[i]) * i64(b[i])
	}
	return total
}

@(enable_target_feature = "avx2,avxvnni,-slow-unaligned-mem-32")
dot_i8_vnni :: proc "contextless" (a: [^]i8, b: [^]i8, n: int) -> i64 #no_bounds_check {
	x := ([^]u8)(a)
	y := ([^]u8)(b)
	flip := transmute(I32x8)(I8x32(-128))
	ones := transmute(I32x8)(I8x32(1))
	flip4 := transmute(I32x4)(I8x16(-128))
	ones4 := transmute(I32x4)(I8x16(1))
	total: i64
	i := 0
	for i + 32 <= n {
		end := min(n &~ 31, i + I8_CHUNK)
		acc0: I32x8
		acc1: I32x8
		sb0: I32x8
		sb1: I32x8
		for ; i + 64 <= end; i += 64 {
			y0 := ld32(y, i)
			y1 := ld32(y, i + 32)
			acc0 = vpdpbusd_256(acc0, ld32(x, i) ~ flip, y0)
			acc1 = vpdpbusd_256(acc1, ld32(x, i + 32) ~ flip, y1)
			sb0 = vpdpbusd_256(sb0, ones, y0)
			sb1 = vpdpbusd_256(sb1, ones, y1)
		}
		for ; i < end; i += 32 {
			y0 := ld32(y, i)
			acc0 = vpdpbusd_256(acc0, ld32(x, i) ~ flip, y0)
			sb0 = vpdpbusd_256(sb0, ones, y0)
		}
		total += sum8(acc0 + acc1) - 128 * sum8(sb0 + sb1)
	}
	if i + 16 <= n {
		y0 := ld16(y, i)
		total += sum4(vpdpbusd_128(I32x4{}, ld16(x, i) ~ flip4, y0)) - 128 * sum4(vpdpbusd_128(I32x4{}, ones4, y0))
		i += 16
	}
	for ; i < n; i += 1 {
		total += i64(a[i]) * i64(b[i])
	}
	return total
}

@(enable_target_feature = "avx2,avxvnni,-slow-unaligned-mem-32")
dot_u8_vnni :: proc "contextless" (a: [^]u8, b: [^]u8, n: int) -> i64 #no_bounds_check {
	flip := transmute(I32x8)(I8x32(-128))
	ones := transmute(I32x8)(I8x32(1))
	flip4 := transmute(I32x4)(I8x16(-128))
	ones4 := transmute(I32x4)(I8x16(1))
	total: i64
	i := 0
	for i + 32 <= n {
		end := min(n &~ 31, i + I8_CHUNK)
		acc0: I32x8
		acc1: I32x8
		sa0: I32x8
		sa1: I32x8
		for ; i + 64 <= end; i += 64 {
			x0 := ld32(a, i)
			x1 := ld32(a, i + 32)
			acc0 = vpdpbusd_256(acc0, x0, ld32(b, i) ~ flip)
			acc1 = vpdpbusd_256(acc1, x1, ld32(b, i + 32) ~ flip)
			sa0 = vpdpbusd_256(sa0, x0, ones)
			sa1 = vpdpbusd_256(sa1, x1, ones)
		}
		for ; i < end; i += 32 {
			x0 := ld32(a, i)
			acc0 = vpdpbusd_256(acc0, x0, ld32(b, i) ~ flip)
			sa0 = vpdpbusd_256(sa0, x0, ones)
		}
		total += sum8(acc0 + acc1) + 128 * sum8(sa0 + sa1)
	}
	if i + 16 <= n {
		x0 := ld16(a, i)
		total += sum4(vpdpbusd_128(I32x4{}, x0, ld16(b, i) ~ flip4)) + 128 * sum4(vpdpbusd_128(I32x4{}, x0, ones4))
		i += 16
	}
	for ; i < n; i += 1 {
		total += i64(a[i]) * i64(b[i])
	}
	return total
}

@(enable_target_feature = "avx2,avxvnni,-slow-unaligned-mem-32")
distance_i8_vnni :: proc "contextless" (a: [^]u8, range_a: f32, b: [^]u8, range_b: f32, dim: int) -> f32 {
	return distance_q8(dot_i8_vnni(([^]i8)(a), ([^]i8)(b), dim), range_a, range_b, dim)
}

@(enable_target_feature = "avx2,avxvnni,-slow-unaligned-mem-32")
score_i8_vnni :: proc "contextless" (a: [^]u8, range_a: f32, b: [^]u8, range_b: f32, dim: int) -> f64 {
	return score_from_distance(distance_q8(dot_i8_vnni(([^]i8)(a), ([^]i8)(b), dim), range_a, range_b, dim))
}

@(enable_target_feature = "avx2,avxvnniint8,-slow-unaligned-mem-32")
distance_i8_vnni_int8 :: proc "contextless" (a: [^]u8, range_a: f32, b: [^]u8, range_b: f32, dim: int) -> f32 {
	return distance_q8(dot_i8_vnni_int8(([^]i8)(a), ([^]i8)(b), dim), range_a, range_b, dim)
}

@(enable_target_feature = "avx2,avxvnniint8,-slow-unaligned-mem-32")
score_i8_vnni_int8 :: proc "contextless" (a: [^]u8, range_a: f32, b: [^]u8, range_b: f32, dim: int) -> f64 {
	return score_from_distance(distance_q8(dot_i8_vnni_int8(([^]i8)(a), ([^]i8)(b), dim), range_a, range_b, dim))
}

@(enable_target_feature = "avx2,avxvnni,-slow-unaligned-mem-32")
qe_i8_ip_vnni :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(1 - dot_i8_vnni(([^]i8)(a), ([^]i8)(b), dim))
}

@(enable_target_feature = "avx2,avxvnni,-slow-unaligned-mem-32")
qe_i8_cosine_vnni :: proc "contextless" (a: [^]u8, na: f32, b: [^]u8, nb: f32, dim: int) -> f32 {
	return qe_int_cosine(dot_i8_vnni(([^]i8)(a), ([^]i8)(b), dim), na, nb)
}

@(enable_target_feature = "avx2,avxvnni,-slow-unaligned-mem-32")
qe_u8_ip_vnni :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(1 - dot_u8_vnni(a, b, dim))
}

@(enable_target_feature = "avx2,avxvnni,-slow-unaligned-mem-32")
qe_u8_cosine_vnni :: proc "contextless" (a: [^]u8, na: f32, b: [^]u8, nb: f32, dim: int) -> f32 {
	return qe_int_cosine(dot_u8_vnni(a, b, dim), na, nb)
}

@(enable_target_feature = "avx2,avxvnniint8,-slow-unaligned-mem-32")
qe_i8_ip_vnni_int8 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(1 - dot_i8_vnni_int8(([^]i8)(a), ([^]i8)(b), dim))
}

@(enable_target_feature = "avx2,avxvnniint8,-slow-unaligned-mem-32")
qe_i8_cosine_vnni_int8 :: proc "contextless" (a: [^]u8, na: f32, b: [^]u8, nb: f32, dim: int) -> f32 {
	return qe_int_cosine(dot_i8_vnni_int8(([^]i8)(a), ([^]i8)(b), dim), na, nb)
}

@(enable_target_feature = "avx2,avxvnniint8,-slow-unaligned-mem-32")
qe_u8_ip_vnni_int8 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(1 - dot_u8_vnni_int8(a, b, dim))
}

@(enable_target_feature = "avx2,avxvnniint8,-slow-unaligned-mem-32")
qe_u8_cosine_vnni_int8 :: proc "contextless" (a: [^]u8, na: f32, b: [^]u8, nb: f32, dim: int) -> f32 {
	return qe_int_cosine(dot_u8_vnni_int8(a, b, dim), na, nb)
}

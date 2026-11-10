#+build amd64
package vmath

search_avx2_kernels :: proc "contextless" (k: ^Kernel_Set) {
	put(k, .Vector_Set, .F32, .Cosine, distance_f32_avx2)
	put(k, .Vector_Set, .Int8, .Cosine, distance_i8_avx2)
	put(k, .Vector_Set, .Bin, .Cosine, distance_bin_avx2)
	put(k, .Search, .F32, .L2, qe_f32_l2_avx2)
	put(k, .Search, .F32, .IP, qe_f32_ip_avx2)
	put(k, .Search, .F32, .Cosine, qe_f32_ip_avx2)
	put(k, .Search, .F16, .L2, qe_f16_l2_avx2)
	put(k, .Search, .F16, .IP, qe_f16_ip_avx2)
	put(k, .Search, .F16, .Cosine, qe_f16_ip_avx2)
	put(k, .Search, .BF16, .L2, qe_bf16_l2_avx2)
	put(k, .Search, .BF16, .IP, qe_bf16_ip_avx2)
	put(k, .Search, .BF16, .Cosine, qe_bf16_ip_avx2)
	put(k, .Search, .F64, .L2, qe_f64_l2_avx2)
	put(k, .Search, .F64, .IP, qe_f64_ip_avx2)
	put(k, .Search, .F64, .Cosine, qe_f64_ip_avx2)
	put(k, .Search, .Int8, .L2, qe_i8_l2_avx2)
	put(k, .Search, .Int8, .IP, qe_i8_ip_avx2)
	put(k, .Search, .Int8, .Cosine, qe_i8_cosine_avx2)
	put(k, .Search, .U8, .L2, qe_u8_l2_avx2)
	put(k, .Search, .U8, .IP, qe_u8_ip_avx2)
	put(k, .Search, .U8, .Cosine, qe_u8_cosine_avx2)
	k[.Search].score[.F64] = {.L2 = qe_f64_l2_exact_avx2, .IP = qe_f64_ip_exact_avx2, .Cosine = qe_f64_ip_exact_avx2}
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_f32_l2_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(qe_f32_sum(([^]f32)(a), ([^]f32)(b), dim, true), a, b, dim, .F32)
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_f32_ip_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(1 - qe_f32_sum(([^]f32)(a), ([^]f32)(b), dim, false), a, b, dim, .F32)
}

@(enable_target_feature = "avx2,fma,f16c,-slow-unaligned-mem-32")
qe_f16_l2_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(qe_f16_sum(([^]u16)(a), ([^]u16)(b), dim, true, f16x8_hard), a, b, dim, .F16)
}

@(enable_target_feature = "avx2,fma,f16c,-slow-unaligned-mem-32")
qe_f16_ip_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(1 - qe_f16_sum(([^]u16)(a), ([^]u16)(b), dim, false, f16x8_hard), a, b, dim, .F16)
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_bf16_l2_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(qe_bf16_sum(([^]u16)(a), ([^]u16)(b), dim, true), a, b, dim, .BF16)
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_bf16_ip_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return qe_fix32(1 - qe_bf16_sum(([^]u16)(a), ([^]u16)(b), dim, false), a, b, dim, .BF16)
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_f64_l2_exact_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f64 {
	return qe_fix64(qe_f64_sum(([^]f64)(a), ([^]f64)(b), dim, true), a, b, dim)
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_f64_ip_exact_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f64 {
	return qe_fix64(1 - qe_f64_sum(([^]f64)(a), ([^]f64)(b), dim, false), a, b, dim)
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_f64_l2_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(qe_fix64(qe_f64_sum(([^]f64)(a), ([^]f64)(b), dim, true), a, b, dim))
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_f64_ip_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(qe_fix64(1 - qe_f64_sum(([^]f64)(a), ([^]f64)(b), dim, false), a, b, dim))
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_i8_l2_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(qe_int_l2(a, b, dim, true))
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_u8_l2_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(qe_int_l2(a, b, dim, false))
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_i8_ip_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(1 - dot_i8_avx2(([^]i8)(a), ([^]i8)(b), dim))
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_u8_ip_avx2 :: proc "contextless" (a: [^]u8, _: f32, b: [^]u8, _: f32, dim: int) -> f32 {
	return f32(1 - dot_u8_avx2(a, b, dim))
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_i8_cosine_avx2 :: proc "contextless" (a: [^]u8, na: f32, b: [^]u8, nb: f32, dim: int) -> f32 {
	return qe_int_cosine(dot_i8_avx2(([^]i8)(a), ([^]i8)(b), dim), na, nb)
}

@(enable_target_feature = "avx2,-slow-unaligned-mem-32")
qe_u8_cosine_avx2 :: proc "contextless" (a: [^]u8, na: f32, b: [^]u8, nb: f32, dim: int) -> f32 {
	return qe_int_cosine(dot_u8_avx2(a, b, dim), na, nb)
}

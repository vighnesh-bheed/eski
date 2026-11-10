package vmath

import "core:log"
import "core:math"
import "core:testing"

TEST_DIMS :: [?]int{1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 300, 768, 1536}
TEST_ROUNDS :: 24

F32_Kernel :: struct {
	name: string,
	dot:  Dot_F32_Proc,
}

exact_f32_kernels :: proc() -> []F32_Kernel {
	out := make([dynamic]F32_Kernel, context.temp_allocator)
	append(&out, F32_Kernel{"exact_base", dot_f32_exact_base})
	when ODIN_ARCH == .amd64 {
		if level_supported(.Avx2, cpu_detect()) {
			append(&out, F32_Kernel{"exact_avx2", dot_f32_exact_avx2})
		}
	}
	return out[:]
}

fast_f32_kernels :: proc() -> []F32_Kernel {
	out := make([dynamic]F32_Kernel, context.temp_allocator)
	append(&out, F32_Kernel{"fast_base", dot_f32_fast_base})
	when ODIN_ARCH == .amd64 {
		if level_supported(.Avx2, cpu_detect()) {
			append(&out, F32_Kernel{"fast_avx2", dot_f32_fast_avx2})
		}
	}
	return out[:]
}

i8_kernels :: proc() -> []Dot_I8_Proc {
	out := make([dynamic]Dot_I8_Proc, context.temp_allocator)
	append(&out, dot_i8_base)
	when ODIN_ARCH == .amd64 {
		cpu := cpu_detect()
		if level_supported(.Avx2, cpu) {
			append(&out, dot_i8_avx2)
		}
		if level_supported(.Avx_Vnni, cpu) {
			append(&out, dot_i8_vnni)
		}
		if level_supported(.Avx_Vnni_Int8, cpu) {
			append(&out, dot_i8_vnni_int8)
		}
	}
	return out[:]
}

u8_kernels :: proc() -> []Dot_U8_Proc {
	out := make([dynamic]Dot_U8_Proc, context.temp_allocator)
	append(&out, dot_u8_base)
	when ODIN_ARCH == .amd64 {
		cpu := cpu_detect()
		if level_supported(.Avx2, cpu) {
			append(&out, dot_u8_avx2)
		}
		if level_supported(.Avx_Vnni, cpu) {
			append(&out, dot_u8_vnni)
		}
		if level_supported(.Avx_Vnni_Int8, cpu) {
			append(&out, dot_u8_vnni_int8)
		}
	}
	return out[:]
}

hamming_kernels :: proc() -> []Hamming_Proc {
	out := make([dynamic]Hamming_Proc, context.temp_allocator)
	append(&out, hamming_base)
	when ODIN_ARCH == .amd64 {
		if level_supported(.Avx2, cpu_detect()) {
			append(&out, hamming_avx2)
		}
	}
	return out[:]
}

fast_dot_bound :: proc(a: []f32, b: []f32) -> f64 {
	n := f64(len(a))
	u := 1.0 / 16777216.0
	gamma := n * u / (1 - n * u)
	sum: f64
	for i in 0 ..< len(a) {
		sum += abs(f64(a[i]) * f64(b[i]))
	}
	return 2 * gamma * sum
}

@(test)
kernel_detection_is_consistent :: proc(t: ^testing.T) {
	cpu := cpu_detect()
	testing.expect_value(t, kernels.level, best_level(cpu))
	testing.expect(t, level_supported(.Base, cpu))
	testing.expect_value(t, kernels_for(.Base).level, Level.Base)
	if cpu.avx2 {
		testing.expect(t, cpu.avx)
	}
	for level in Level {
		if level_supported(level, cpu) {
			testing.expect_value(t, kernels_for(level).level, level)
			if level > .Avx2 {
				testing.expect(t, level_supported(.Avx2, cpu))
			}
		}
	}
	if level_supported(.Avx_Vnni_Int8, cpu) {
		testing.expect_value(t, best_level(cpu), Level.Avx_Vnni_Int8)
	}
	testing.expect(t, !level_supported(.Avx_Vnni, Cpu{avx = true, avx2 = true, fma = true, popcnt = true, f16c = true}))
	testing.expect(t, !level_supported(.Avx2, Cpu{avx = true, avx2 = true, fma = true, popcnt = true}))
	testing.expect_value(t, best_level(Cpu{}), Level.Base)
}

@(test)
kernel_table_is_complete :: proc(t: ^testing.T) {
	cpu := cpu_detect()
	testing.expect_value(t, BASE_KERNELS.level, Level.Base)
	testing.expect(t, BASE_KERNELS.hamming == hamming_base)
	for level in Level {
		if !level_supported(level, cpu) {
			continue
		}
		for family in Family {
			k := kernels_for(level, family)
			testing.expect_value(t, k.family, family)
			testing.expect_value(t, k.level, level)
			for elem in Elem {
				for metric in Metric {
					want := family_supports(family, elem, metric)
					testing.expectf(t, (k.distance[elem][metric] != nil) == want, "%v %v %v %v distance", level, family, elem, metric)
					testing.expectf(t, (k.batch[elem][metric] != nil) == want, "%v %v %v %v batch", level, family, elem, metric)
					has_score := family == .Vector_Set || elem == .F64
					testing.expectf(t, (k.score[elem][metric] != nil) == (want && has_score), "%v %v %v %v score", level, family, elem, metric)
				}
			}
			testing.expect(t, k.dot_i8 != nil && k.dot_u8 != nil && k.dot_f32 != nil && k.dot_f32_exact != nil && k.hamming != nil)
		}
	}
	testing.expect_value(t, family_kernels(.Vector_Set).family, Family.Vector_Set)
	testing.expect_value(t, family_kernels(.Search).family, Family.Search)
	testing.expect_value(t, family_kernels(.Search).level, kernels.level)
}

@(test)
kernel_exact_f32_matches_reference_bitwise :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 11)
	for dim in TEST_DIMS {
		for _ in 0 ..< TEST_ROUNDS {
			a := test_raw_vector(&r, dim)
			b := test_raw_vector(&r, dim)
			want := dot_f32_ref(a, b)
			for k in exact_f32_kernels() {
				got := k.dot(raw_data(a), raw_data(b), dim)
				testing.expectf(t, transmute(u32)got == transmute(u32)want, "%s dim %d: %v against %v", k.name, dim, got, want)
			}
		}
	}
}

@(test)
kernel_fast_f32_within_bound_of_reference :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 12)
	worst_ulps := 0
	worst_ratio: f64
	worst_abs: f64
	for dim in TEST_DIMS {
		for _ in 0 ..< TEST_ROUNDS {
			a := test_unit_vector(&r, dim)
			b := test_unit_vector(&r, dim)
			want := dot_f32_ref(a, b)
			bound := fast_dot_bound(a, b)
			for k in fast_f32_kernels() {
				got := k.dot(raw_data(a), raw_data(b), dim)
				diff := abs(f64(got) - f64(want))
				testing.expectf(t, diff <= bound, "%s dim %d: %v against %v beyond %v", k.name, dim, got, want, bound)
				worst_abs = max(worst_abs, diff)
				if bound > 0 {
					worst_ratio = max(worst_ratio, diff / bound)
				}
				worst_ulps = max(worst_ulps, f32_ulps(distance_from_dot(got), distance_from_dot(want)))
			}
		}
	}
	log.infof("fast f32 kernels: worst absolute difference %v, worst fraction of the bound %v, worst distance difference %d ulps", worst_abs, worst_ratio, worst_ulps)
	testing.expectf(t, worst_ulps <= 16, "fast kernels move the distance by %d ulps", worst_ulps)
}

@(test)
kernel_int8_matches_reference :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 13)
	dims := []int{1, 2, 3, 15, 16, 17, 31, 32, 33, 63, 64, 65, 300, 768, 1536, I8_CHUNK + 37}
	for dim in dims {
		rounds := 2 if dim > 4096 else TEST_ROUNDS
		for _ in 0 ..< rounds {
			a := make([]i8, dim, context.temp_allocator)
			b := make([]i8, dim, context.temp_allocator)
			for i in 0 ..< dim {
				a[i] = i8(rng_next(&r))
				b[i] = i8(rng_next(&r))
			}
			want := dot_i8_ref(a, b)
			for k in i8_kernels() {
				testing.expect_value(t, k(raw_data(a), raw_data(b), dim), want)
			}
		}
	}
	extreme := make([]i8, DIM_MAX, context.temp_allocator)
	for &v in extreme {
		v = -128
	}
	for k in i8_kernels() {
		testing.expect_value(t, k(raw_data(extreme), raw_data(extreme), DIM_MAX), i64(16384) * DIM_MAX)
	}
	mixed := make([]i8, DIM_MAX, context.temp_allocator)
	for &v in mixed {
		v = 127
	}
	for k in i8_kernels() {
		testing.expect_value(t, k(raw_data(extreme), raw_data(mixed), DIM_MAX), -i64(16256) * DIM_MAX)
	}
}

@(test)
kernel_uint8_matches_reference :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 16)
	dims := []int{1, 2, 3, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 300, 768, 1536, I8_CHUNK + 37}
	for dim in dims {
		rounds := 2 if dim > 4096 else TEST_ROUNDS
		for _ in 0 ..< rounds {
			a := make([]u8, dim, context.temp_allocator)
			b := make([]u8, dim, context.temp_allocator)
			for i in 0 ..< dim {
				a[i] = u8(rng_next(&r))
				b[i] = u8(rng_next(&r))
			}
			want: i64
			for i in 0 ..< dim {
				want += i64(a[i]) * i64(b[i])
			}
			for k in u8_kernels() {
				testing.expect_value(t, k(raw_data(a), raw_data(b), dim), want)
			}
		}
	}
	full := make([]u8, DIM_MAX, context.temp_allocator)
	for &v in full {
		v = 255
	}
	for k in u8_kernels() {
		testing.expect_value(t, k(raw_data(full), raw_data(full), DIM_MAX), i64(65025) * DIM_MAX)
	}
}

@(test)
kernel_hamming_matches_reference :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 14)
	for words in 1 ..= 40 {
		for _ in 0 ..< TEST_ROUNDS {
			a := make([]u64, words, context.temp_allocator)
			b := make([]u64, words, context.temp_allocator)
			for i in 0 ..< words {
				a[i] = rng_next(&r)
				b[i] = rng_next(&r)
			}
			want := hamming_ref(a, b)
			for k in hamming_kernels() {
				testing.expect_value(t, k(raw_data(a), raw_data(b), words), want)
			}
		}
	}
}

@(test)
kernel_table_scores_match_reference_path :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 15)
	levels := []Level{.Base, .Avx2, .Avx_Vnni, .Avx_Vnni_Int8}
	for level in levels {
		if !level_supported(level, cpu_detect()) {
			continue
		}
		k := kernels_for(level)
		for dim in TEST_DIMS {
			for elem in VSET_ELEMS {
				x := test_raw_vector(&r, dim)
				y := test_raw_vector(&r, dim)
				bx := make([]u8, elem_vector_bytes(elem, dim), context.temp_allocator)
				by := make([]u8, elem_vector_bytes(elem, dim), context.temp_allocator)
				_, rx := encode(elem, x, bx)
				_, ry := encode(elem, y, by)
				want: f64
				switch elem {
				case .F32:
					want = score_from_distance(distance_from_dot(dot_f32_ref(f32_view(bx), f32_view(by))))
				case .Int8:
					want = score_from_distance(distance_q8(dot_i8_ref(i8_view(bx), i8_view(by)), rx, ry, dim))
				case .Bin:
					want = score_bin(hamming_ref(u64_view(bx), u64_view(by)), dim)
				case .F64, .F16, .BF16, .U8:
				}
				got := k.score[elem][.Cosine](raw_data(bx), rx, raw_data(by), ry, dim)
				testing.expectf(t, same_f64(got, want), "%v %v dim %d score %v against %v", level, elem, dim, got, want)
				d := k.distance[elem][.Cosine](raw_data(bx), rx, raw_data(by), ry, dim)
				if elem != .F32 {
					testing.expectf(t, d >= 0 && d <= 2, "%v %v dim %d distance %v", level, elem, dim, d)
					testing.expectf(t, abs(score_from_distance(d) - want) <= 1e-6, "%v %v dim %d distance %v against score %v", level, elem, dim, d, want)
				}
			}
		}
	}
}

@(test)
kernel_distance_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, distance_from_dot(1), f32(0))
	testing.expect_value(t, distance_from_dot(1.0625), f32(-0.0625))
	testing.expect_value(t, distance_from_dot(-1.5), f32(2.5))
	testing.expect(t, math.is_nan(distance_from_dot(math.nan_f32())))
	testing.expect(t, math.is_nan(score_from_distance(math.nan_f32())))
	testing.expect_value(t, score_from_distance(0), 1.0)
	testing.expect_value(t, score_from_distance(1), 0.5)
	testing.expect_value(t, score_from_distance(2), 0.0)
	testing.expect_value(t, score_from_distance(-1.1920928955078125e-07), 1.0000000596046448)
	testing.expect_value(t, distance_q8(16129 * 2, 1, 1, 3), f32(0))
	testing.expect_value(t, distance_q8(-16129 * 2, 1, 1, 3), f32(2))
	testing.expect_value(t, distance_q8(-16129 * 2, 1, 1, 40), f32(2))
	testing.expect_value(t, score_bin(1, 4), 0.75)
	testing.expect_value(t, score_bin(0, 7), 1.0)
	testing.expect_value(t, score_bin(1, 3), 1 - f64(f32(1.0 / 3.0)))
	testing.expect_value(t, distance_bin(2, 4), f32(1))
}

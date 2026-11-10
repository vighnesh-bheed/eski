package vmath

import "core:math"
import "core:simd"
import "core:testing"

SEARCH_TEST_DIMS :: [?]int{1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 23, 24, 25, 31, 32, 33, 39, 40, 47, 48, 63, 64, 65, 100, 127, 128, 129, 300, 768, 1536}

ref_lanes32 :: proc(q: []f32, s: []f32, l2: bool, fused: bool) -> f32 {
	n := len(q)
	acc: [4][8]f32
	step :: proc(acc: ^f32, x: f32, y: f32, l2: bool, fused: bool) {
		if l2 {
			d := y - x
			acc^ = fma_f32(d, d, acc^) if fused else acc^ + d * d
		} else {
			acc^ = fma_f32(x, y, acc^) if fused else acc^ + y * x
		}
	}
	r := n % 32
	m := r % 8
	for j in 0 ..< m {
		step(&acc[0][j], q[j], s[j], l2, fused)
	}
	i := m
	for k := 1; i < r; k += 1 {
		for j in 0 ..< 8 {
			step(&acc[k][j], q[i + j], s[i + j], l2, fused)
		}
		i += 8
	}
	for ; i < n; i += 32 {
		for u in 0 ..< 4 {
			for j in 0 ..< 8 {
				step(&acc[u][j], q[i + 8 * u + j], s[i + 8 * u + j], l2, fused)
			}
		}
	}
	v: [8]f32
	for j in 0 ..< 8 {
		v[j] = (acc[0][j] + acc[1][j]) + (acc[2][j] + acc[3][j])
	}
	t := v[0]
	for j in 1 ..< 8 {
		t = t + v[j]
	}
	return t
}

ref_bf16_sum :: proc(q: []f32, s: []f32, l2: bool) -> f32 {
	n := len(q)
	term :: proc(x: f32, y: f32, l2: bool) -> f32 {
		if l2 {
			d := x - y
			return d * d
		}
		return x * y
	}
	if n < 32 {
		t: f32
		for i in 0 ..< n {
			t = t + term(q[i], s[i], l2)
		}
		return t
	}
	lo := [8]int{0, 1, 2, 3, 8, 9, 10, 11}
	hi := [8]int{4, 5, 6, 7, 12, 13, 14, 15}
	acc: [8]f32
	r := n % 16
	for lanes in ([][8]int{lo, hi}) {
		for j in 0 ..< 8 {
			if lanes[j] < r {
				acc[j] = acc[j] + term(q[lanes[j]], s[lanes[j]], l2)
			}
		}
	}
	for i := r; i < n; i += 16 {
		for lanes in ([][8]int{lo, hi}) {
			for j in 0 ..< 8 {
				acc[j] = acc[j] + term(q[i + lanes[j]], s[i + lanes[j]], l2)
			}
		}
	}
	t := acc[0]
	for j in 1 ..< 8 {
		t = t + acc[j]
	}
	return t
}

ref_f64_sum :: proc(q: []f64, s: []f64, l2: bool) -> f64 {
	n := len(q)
	acc: [2][4]f64
	term :: proc(x: f64, y: f64, l2: bool) -> f64 {
		if l2 {
			d := y - x
			return d * d
		}
		return y * x
	}
	r := n % 8
	m := r % 4
	for j in 0 ..< m {
		acc[0][j] = acc[0][j] + term(q[j], s[j], l2)
	}
	i := m
	if r - m >= 4 {
		for j in 0 ..< 4 {
			acc[1][j] = acc[1][j] + term(q[i + j], s[i + j], l2)
		}
		i += 4
	}
	for ; i < n; i += 8 {
		for u in 0 ..< 2 {
			for j in 0 ..< 4 {
				acc[u][j] = acc[u][j] + term(q[i + 4 * u + j], s[i + 4 * u + j], l2)
			}
		}
	}
	v: [4]f64
	for j in 0 ..< 4 {
		v[j] = acc[0][j] + acc[1][j]
	}
	return ((v[0] + v[1]) + v[2]) + v[3]
}

widen :: proc(b: []u8, elem: Elem, allocator := context.temp_allocator) -> []f32 {
	h := u16_view(b)
	out := make([]f32, len(h), allocator)
	for v, i in h {
		out[i] = bf16_to_f32(v) if elem == .BF16 else f16_to_f32(v)
	}
	return out
}

search_ref :: proc(elem: Elem, metric: Metric, q: []u8, qaux: f32, s: []u8, saux: f32) -> f64 {
	l2 := metric == .L2
	#partial switch elem {
	case .F32:
		d := ref_lanes32(f32_view(q), f32_view(s), l2, false)
		return f64(d if l2 else 1 - d)
	case .F16:
		d := ref_lanes32(widen(q, .F16), widen(s, .F16), l2, true)
		return f64(d if l2 else 1 - d)
	case .BF16:
		d := ref_bf16_sum(widen(q, .BF16), widen(s, .BF16), l2)
		return f64(d if l2 else 1 - d)
	case .F64:
		d := ref_f64_sum(f64_view(q), f64_view(s), l2)
		return d if l2 else 1 - d
	case .Int8, .U8:
		dot: i64
		sq: i64
		for i in 0 ..< len(q) {
			x := i64(i8(q[i])) if elem == .Int8 else i64(q[i])
			y := i64(i8(s[i])) if elem == .Int8 else i64(s[i])
			dot += x * y
			sq += (x - y) * (x - y)
		}
		switch metric {
		case .L2:
			return f64(f32(sq))
		case .IP:
			return f64(f32(1 - dot))
		case .Cosine:
			return f64(1 - f32(dot) / (qaux * saux))
		}
	}
	return 0
}

search_random_blob :: proc(r: ^Rng, elem: Elem, dim: int, wide: bool) -> []u8 {
	b := make([]u8, dim * elem_size(elem), context.temp_allocator)
	for i in 0 ..< dim {
		x := rng_next(r)
		#partial switch elem {
		case .F32:
			v := f32(2 * rng_f64(r) - 1)
			if wide {
				v = transmute(f32)u32(((x >> 63) << 31) | ((100 + ((x >> 23) % 50)) << 23) | (x & 0x7FFFFF))
			}
			f32_view(b)[i] = v
		case .F64:
			v := 2 * rng_f64(r) - 1
			if wide {
				v = transmute(f64)(((x >> 63) << 63) | ((1000 + ((x >> 52) % 50)) << 52) | (x & ((u64(1) << 52) - 1)))
			}
			f64_view(b)[i] = v
		case .F16:
			u16_view(b)[i] = u16(((x >> 63) << 15) | ((x >> 10) % 30) << 10 | (x & 0x3FF))
		case .BF16:
			u16_view(b)[i] = u16(((x >> 63) << 15) | ((100 + ((x >> 7) % 50)) << 7) | (x & 0x7F))
		case .Int8, .U8:
			b[i] = u8(x >> 56)
		}
	}
	return b
}

@(test)
search_kernels_match_scalar_reference :: proc(t: ^testing.T) {
	saved := kernels.level
	defer use_level(saved)
	r: Rng
	rng_seed(&r, 61)
	checked := 0
	for level in search_probe_levels() {
		use_level(level)
		for elem in SEARCH_ELEMS {
			for metric in Metric {
				for dim in SEARCH_TEST_DIMS {
					a: Arena
					testing.expect_value(t, arena_init(&a, elem, metric, dim, context.allocator, 8, .Search), nil)
					for k in 0 ..< 8 {
						_, err := arena_insert_blob(&a, search_random_blob(&r, elem, dim, k % 2 == 1))
						testing.expect_value(t, err, nil)
					}
					buf, _ := query_alloc(&a, context.temp_allocator)
					q, ok := query_encode_blob(&a, search_random_blob(&r, elem, dim, true), buf)
					testing.expect(t, ok)
					for slot in 0 ..< u32(8) {
						got := arena_query_score(&a, q, slot)
						want := search_ref(elem, metric, q.data[:a.stride], q.aux, arena_bytes(&a, slot), arena_aux(&a, slot))
						testing.expectf(t, transmute(u64)got == transmute(u64)want, "%v %v %v dim %d slot %d: %v against %v", level, elem, metric, dim, slot, got, want)
						d := arena_query_distance(&a, q, slot)
						testing.expectf(t, transmute(u32)d == transmute(u32)f32(want), "%v %v %v dim %d distance %v against %v", level, elem, metric, dim, d, want)
						checked += 1
					}
					arena_destroy(&a)
					free_all(context.temp_allocator)
				}
			}
		}
	}
	testing.expect(t, checked >= 6 * 3 * len(SEARCH_TEST_DIMS) * 8)
}

@(test)
search_conversions_are_exact :: proc(t: ^testing.T) {
	for h in 0 ..= 0xFFFF {
		v := f16_to_f32(u16(h))
		want := f32(transmute(f16)u16(h))
		e := u16(h) & 0x7C00
		m := u16(h) & 0x3FF
		if e == 0x7C00 && m != 0 {
			testing.expect(t, math.is_nan(v))
			testing.expectf(t, transmute(u32)v >> 31 == u32(h >> 15), "f16 %x nan sign", h)
			testing.expect_value(t, f32_to_f16_away(v) & 0xFE00, (u16(h) | 0x200) & 0xFE00)
			continue
		}
		testing.expectf(t, transmute(u32)v == transmute(u32)want, "f16 %x widens to %v against %v", h, v, want)
		testing.expectf(t, f32_to_f16_away(v) == u16(h), "f16 %x does not round trip", h)
		b := bf16_to_f32(u16(h))
		testing.expect_value(t, transmute(u32)b, u32(h) << 16)
		if !math.is_nan(b) {
			testing.expect_value(t, f32_to_bf16_rne(b), u16(h))
		}
	}
	testing.expect_value(t, f32_to_f16_away(transmute(f32)u32(0x3F801000)), u16(0x3C01))
	testing.expect_value(t, f32_to_f16_away(transmute(f32)u32(0x3F800FFF)), u16(0x3C00))
	testing.expect_value(t, f32_to_f16_away(transmute(f32)u32(0x34200000)), u16(3))
	testing.expect_value(t, f32_to_f16_away(transmute(f32)u32(0x33000000)), u16(1))
	testing.expect_value(t, f32_to_f16_away(transmute(f32)u32(0x32800000)), u16(0))
	testing.expect_value(t, f32_to_f16_away(transmute(f32)u32(0xB3C00000)), u16(0x8002))
	testing.expect_value(t, f32_to_f16_away(65520), u16(0x7C00))
	testing.expect_value(t, f32_to_f16_away(65519.996), u16(0x7BFF))
	testing.expect_value(t, f32_to_f16_away(math.inf_f32(-1)), u16(0xFC00))
	testing.expect_value(t, f32_to_bf16_rne(transmute(f32)u32(0x3F808000)), u16(0x3F80))
	testing.expect_value(t, f32_to_bf16_rne(transmute(f32)u32(0x3F818000)), u16(0x3F82))
	testing.expect_value(t, f32_to_bf16_rne(transmute(f32)u32(0x3F808001)), u16(0x3F81))
	testing.expect_value(t, f32_to_bf16_rne(transmute(f32)u32(0x7F7FFFFF)), u16(0x7F80))
	testing.expect_value(t, f32_to_bf16_rne(transmute(f32)u32(0xFFC00001)), u16(0xFFC0))
	r: Rng
	rng_seed(&r, 62)
	for _ in 0 ..< 200_000 {
		x := transmute(f32)u32(rng_next(&r))
		if math.is_nan(x) {
			continue
		}
		h := f32_to_f16_away(x)
		lo := f64(f16_to_f32(h))
		want := f64(x)
		testing.expectf(t, math.is_inf(lo) || abs(lo - want) <= f16_half_ulp(h) * (1 + 1e-12), "f16 rounding of %v gave %v", x, lo)
	}
}

@(test)
search_soft_widening_matches_scalar :: proc(t: ^testing.T) {
	for base := 0; base <= 0xFFFF; base += 8 {
		v: U16x8
		for j in 0 ..< 8 {
			v = simd.replace(v, j, u16(base + j))
		}
		w := f16x8_soft(v)
		for j in 0 ..< 8 {
			got := transmute(u32)simd.extract(w, j)
			want := transmute(u32)f16_to_f32(u16(base + j))
			testing.expectf(t, got == want, "half %x widens to %x against %x", base + j, got, want)
		}
	}
	when ODIN_ARCH == .amd64 {
		if level_supported(.Avx2, cpu_detect()) {
			testing.expect(t, f16_hard_matches_soft())
		}
	}
}

f16_half_ulp :: proc(h: u16) -> f64 {
	e := int((h >> 10) & 0x1F)
	if e == 0 {
		return math.pow(f64(2), -25)
	}
	return math.pow(f64(2), f64(e - 15 - 11))
}

@(test)
search_arena_shapes :: proc(t: ^testing.T) {
	a: Arena
	testing.expect_value(t, arena_init(&a, .Bin, .Cosine, 4, context.allocator, 0, .Search), runtime_invalid())
	testing.expect_value(t, arena_init(&a, .F64, .Cosine, 4), runtime_invalid())
	testing.expect_value(t, arena_init(&a, .F32, .L2, 4), runtime_invalid())
	widths := [Elem]int{.F32 = 4, .Int8 = 1, .Bin = 0, .F64 = 8, .F16 = 2, .BF16 = 2, .U8 = 1}
	for elem in SEARCH_ELEMS {
		for metric in Metric {
			for dim in ([]int{1, 3, 300, 768}) {
				testing.expect_value(t, arena_init(&a, elem, metric, dim, context.allocator, 16, .Search), nil)
				testing.expect_value(t, arena_slot_bytes(&a), widths[elem] * dim + 4)
				testing.expect_value(t, slot_bytes(elem, dim, .Search), widths[elem] * dim + 4)
				testing.expectf(t, arena_footprint(&a) - 16 * arena_slot_bytes(&a) < 4, "%v %v dim %d footprint", elem, metric, dim)
				testing.expect_value(t, a.aux != nil, search_has_norm(elem, metric))
				blob := make([]u8, a.stride, context.temp_allocator)
				_, short := arena_insert_blob(&a, blob[1:])
				testing.expect_value(t, short, runtime_invalid())
				_, vec := arena_insert(&a, make([]f32, dim, context.temp_allocator))
				testing.expect_value(t, vec, runtime_invalid())
				slot, err := arena_insert_blob(&a, blob)
				testing.expect_value(t, err, nil)
				testing.expect(t, arena_is_live(&a, slot))
				buf, _ := query_alloc(&a, context.temp_allocator)
				_, qok := query_encode(&a, make([]f32, dim, context.temp_allocator), buf)
				testing.expect(t, !qok)
				arena_destroy(&a)
			}
		}
	}
	v: Arena
	testing.expect_value(t, arena_init(&v, .F32, .Cosine, 4), nil)
	_, bad := arena_insert_blob(&v, make([]u8, 16, context.temp_allocator))
	testing.expect_value(t, bad, runtime_invalid())
	arena_destroy(&v)
}

@(test)
search_zero_vectors_give_negative_nan :: proc(t: ^testing.T) {
	for elem in SEARCH_ELEMS {
		a: Arena
		testing.expect_value(t, arena_init(&a, elem, .Cosine, 5, context.allocator, 2, .Search), nil)
		zero := make([]u8, a.stride, context.temp_allocator)
		_, err := arena_insert_blob(&a, zero)
		testing.expect_value(t, err, nil)
		buf, _ := query_alloc(&a, context.temp_allocator)
		q, ok := query_encode_blob(&a, zero, buf)
		testing.expect(t, ok)
		d := arena_query_score(&a, q, 0)
		testing.expectf(t, math.is_nan(d) && transmute(u64)d >> 63 == 1, "%v zero cosine %v", elem, d)
		arena_destroy(&a)
	}
}

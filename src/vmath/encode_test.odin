package vmath

import "core:math"
import "core:testing"

@(test)
encode_f32_round_trip :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 21)
	for dim in TEST_DIMS {
		for _ in 0 ..< 8 {
			x := test_raw_vector(&r, dim)
			buf := make([]u8, elem_vector_bytes(.F32, dim), context.temp_allocator)
			norm, range := encode(.F32, x, buf)
			testing.expect_value(t, range, f32(0))
			testing.expect_value(t, norm, l2_norm(x))
			unit := f32_view(buf)
			s := dot_f32_ref(unit, unit)
			testing.expectf(t, abs(f64(s) - 1) <= f64(dim) * 1e-7 + 1e-6, "dim %d unit vector sum of squares %v", dim, s)
			out := make([]f32, dim, context.temp_allocator)
			decode(.F32, buf, norm, 0, out)
			for v, i in out {
				bound := abs(f64(x[i])) * 4.0 / 16777216.0 + 1e-30
				testing.expectf(t, abs(f64(v) - f64(x[i])) <= bound, "dim %d component %d: %v against %v", dim, i, v, x[i])
			}
		}
	}
}

@(test)
encode_int8_round_trip_error_bound :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 22)
	for dim in TEST_DIMS {
		for _ in 0 ..< 8 {
			x := test_raw_vector(&r, dim)
			buf := make([]u8, elem_vector_bytes(.Int8, dim), context.temp_allocator)
			norm, range := encode(.Int8, x, buf)
			q := i8_view(buf)
			top := 0
			for v in q {
				testing.expect(t, v != -128)
				top = max(top, int(abs(v)))
			}
			testing.expect_value(t, top, 127)
			unit := make([]f32, dim, context.temp_allocator)
			normalise(x, unit)
			want_range: f32
			for v in unit {
				want_range = max(want_range, abs(v))
			}
			testing.expect_value(t, range, want_range)
			out := make([]f32, dim, context.temp_allocator)
			decode(.Int8, buf, norm, range, out)
			bound := f64(norm) * f64(range) * (0.5 / 127) * (1 + 1e-5) + f64(norm) * 8.0 / 16777216.0
			for v, i in out {
				testing.expectf(t, abs(f64(v) - f64(x[i])) <= bound, "dim %d component %d: %v against %v beyond %v", dim, i, v, x[i], bound)
			}
		}
	}
}

@(test)
encode_bin_layout :: proc(t: ^testing.T) {
	dim := 130
	x := make([]f32, dim, context.temp_allocator)
	x[0] = 1
	x[63] = 0.5
	x[64] = 2
	x[129] = 3
	x[5] = -1
	buf := make([]u8, elem_vector_bytes(.Bin, dim), context.temp_allocator)
	testing.expect_value(t, len(buf), 24)
	norm, _ := encode(.Bin, x, buf)
	w := u64_view(buf)
	testing.expect_value(t, w[0], u64(1) | u64(1) << 63)
	testing.expect_value(t, w[1], u64(1))
	testing.expect_value(t, w[2], u64(1) << 1)
	testing.expect(t, bin_padding_clear(w, dim))
	out := make([]f32, dim, context.temp_allocator)
	decode(.Bin, buf, norm, 0, out)
	for v, i in out {
		testing.expect_value(t, v, f32(1) if x[i] > 0 else f32(-1))
	}
	w[2] |= u64(1) << 2
	testing.expect(t, !bin_padding_clear(w, dim))
}

@(test)
encode_degenerate_vectors :: proc(t: ^testing.T) {
	zero := []f32{0, 0, 0}
	tiny := []f32{1e-30, 0, -1e-30}
	infinite := []f32{math.inf_f32(1), 0, 1}
	for elem in VSET_ELEMS {
		buf := make([]u8, elem_vector_bytes(elem, 3), context.temp_allocator)
		norm, range := encode(elem, zero, buf)
		testing.expect_value(t, norm, f32(1))
		testing.expect_value(t, range, f32(0))
		for b in buf {
			testing.expect_value(t, b, u8(0))
		}
		tn, _ := encode(elem, tiny, buf)
		testing.expect_value(t, tn, f32(1))
		inf_norm, inf_range := encode(elem, infinite, buf)
		testing.expect(t, math.is_inf(inf_norm))
		testing.expect_value(t, inf_range, f32(0))
	}
	buf := make([]u8, 12, context.temp_allocator)
	encode(.F32, tiny, buf)
	testing.expect_value(t, f32_view(buf)[0], f32(1e-30))
	encode(.F32, infinite, buf)
	testing.expect(t, math.is_nan(f32_view(buf)[0]))
	testing.expect_value(t, f32_view(buf)[2], f32(0))
	q := make([]u8, 3, context.temp_allocator)
	encode(.Int8, tiny, q)
	testing.expect_value(t, i8_view(q)[0], i8(127))
	testing.expect_value(t, i8_view(q)[2], i8(-127))
	testing.expect_value(t, q8_round(math.nan_f32()), i8(0))
	testing.expect_value(t, q8_round(126.5), i8(127))
	testing.expect_value(t, q8_round(-62.5), i8(-63))
	testing.expect_value(t, q8_round(60.5), i8(61))
	testing.expect_value(t, q8_round(0.49999997), i8(0))
}

@(test)
encode_normalised_matches_encode :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 23)
	for dim in TEST_DIMS {
		x := test_raw_vector(&r, dim)
		unit := make([]f32, dim, context.temp_allocator)
		norm := normalise(x, unit)
		for elem in VSET_ELEMS {
			a := make([]u8, elem_vector_bytes(elem, dim), context.temp_allocator)
			b := make([]u8, elem_vector_bytes(elem, dim), context.temp_allocator)
			na, ra := encode(elem, x, a)
			rb := encode_normalised(elem, unit, b)
			testing.expect_value(t, na, norm)
			testing.expect_value(t, ra, rb)
			testing.expectf(t, string(a) == string(b), "%v dim %d encodings differ", elem, dim)
		}
	}
}

@(test)
encode_sizes :: proc(t: ^testing.T) {
	testing.expect_value(t, elem_vector_bytes(.F32, 300), 1200)
	testing.expect_value(t, elem_vector_bytes(.Int8, 300), 300)
	testing.expect_value(t, elem_vector_bytes(.Bin, 300), 40)
	testing.expect_value(t, elem_vector_bytes(.Bin, 64), 8)
	testing.expect_value(t, elem_vector_bytes(.Bin, 65), 16)
	for dim in TEST_DIMS {
		testing.expect_value(t, slot_bytes(.F32, dim), 4 * dim + 4)
		testing.expect_value(t, slot_bytes(.Int8, dim), dim + 8)
		testing.expect_value(t, slot_bytes(.Bin, dim), 8 * ((dim + 63) / 64) + 4)
	}
}

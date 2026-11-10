package vmath

import "base:runtime"
import "core:math"
import "core:testing"

@(test)
arena_rejects_invalid_shapes :: proc(t: ^testing.T) {
	a: Arena
	testing.expect_value(t, arena_init(&a, .F32, .Cosine, 0), runtime_invalid())
	testing.expect_value(t, arena_init(&a, .F32, .Cosine, DIM_MAX + 1), runtime_invalid())
	testing.expect_value(t, arena_init(&a, .Int8, .Cosine, 4, context.allocator, -1), runtime_invalid())
	testing.expect_value(t, arena_init(&a, .Bin, .Cosine, DIM_MAX), nil)
	arena_destroy(&a)
}

runtime_invalid :: proc() -> runtime.Allocator_Error {
	return .Invalid_Argument
}

@(test)
arena_growth_doubles_and_keeps_data :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 31)
	for elem in VSET_ELEMS {
		dim := 33
		a: Arena
		testing.expect_value(t, arena_init(&a, elem, .Cosine, dim), nil)
		inputs := make([][]f32, 1000, context.temp_allocator)
		expected := make([][]u8, 1000, context.temp_allocator)
		caps := make([dynamic]u32, context.temp_allocator)
		for i in 0 ..< 1000 {
			inputs[i] = test_raw_vector(&r, dim)
			expected[i] = make([]u8, elem_vector_bytes(elem, dim), context.temp_allocator)
			encode(elem, inputs[i], expected[i])
			before := a.cap
			slot, err := arena_insert(&a, inputs[i])
			testing.expect_value(t, err, nil)
			testing.expect_value(t, slot, u32(i))
			if a.cap != before {
				append(&caps, a.cap)
			}
		}
		testing.expect_value(t, len(caps), 11)
		for c, i in caps {
			testing.expect_value(t, c, u32(1) << uint(i))
		}
		for i in 0 ..< 1000 {
			testing.expectf(t, string(arena_bytes(&a, u32(i))) == string(expected[i]), "%v slot %d changed across growth", elem, i)
			testing.expect_value(t, arena_norm(&a, u32(i)), l2_norm(inputs[i]))
		}
		testing.expect_value(t, a.live, u32(1000))
		arena_destroy(&a)
	}
}

@(test)
arena_footprint_per_slot :: proc(t: ^testing.T) {
	for elem in VSET_ELEMS {
		for dim in TEST_DIMS {
			a: Arena
			testing.expect_value(t, arena_init(&a, elem, .Cosine, dim, context.allocator, 1024), nil)
			testing.expect_value(t, arena_slot_bytes(&a), slot_bytes(elem, dim))
			testing.expect_value(t, arena_footprint(&a), arena_layout(elem, dim, 1024).size)
			extra := arena_footprint(&a) - 1024 * slot_bytes(elem, dim)
			testing.expectf(t, extra >= 0 && extra < size_of(f32), "%v dim %d block carries %d bytes beyond its slots", elem, dim, extra)
			arena_destroy(&a)
		}
	}
	testing.expect_value(t, slot_bytes(.F32, 300) - elem_vector_bytes(.F32, 300), 4)
	testing.expect_value(t, slot_bytes(.Int8, 300) - elem_vector_bytes(.Int8, 300), 8)
	testing.expect_value(t, slot_bytes(.Bin, 300) - elem_vector_bytes(.Bin, 300), 4)
}

@(test)
arena_free_list_reuses_in_place :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 32)
	for elem in VSET_ELEMS {
		a: Arena
		testing.expect_value(t, arena_init(&a, elem, .Cosine, 8), nil)
		for _ in 0 ..< 16 {
			_, err := arena_insert(&a, test_raw_vector(&r, 8))
			testing.expect_value(t, err, nil)
		}
		keep := make([]u8, a.stride, context.temp_allocator)
		copy(keep, arena_bytes(&a, 7))
		keep_norm := arena_norm(&a, 7)
		cap_before := a.cap
		block_before := a.block
		arena_free(&a, 5)
		arena_free(&a, 9)
		arena_free(&a, 2)
		testing.expect_value(t, a.live, u32(13))
		order := []u32{2, 9, 5}
		for want in order {
			slot, err := arena_insert(&a, test_raw_vector(&r, 8))
			testing.expect_value(t, err, nil)
			testing.expect_value(t, slot, want)
		}
		testing.expect_value(t, a.cap, cap_before)
		testing.expect(t, a.block == block_before)
		testing.expect_value(t, a.high, u32(16))
		testing.expect_value(t, a.free, NIL_SLOT)
		testing.expect(t, string(arena_bytes(&a, 7)) == string(keep))
		testing.expect_value(t, arena_norm(&a, 7), keep_norm)
		next, err := arena_alloc(&a)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, next, u32(16))
		testing.expect_value(t, a.cap, u32(32))
		arena_destroy(&a)
	}
}

@(test)
arena_raw_and_queries :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 33)
	for elem in VSET_ELEMS {
		dim := 70
		a: Arena
		testing.expect_value(t, arena_init(&a, elem, .Cosine, dim, context.allocator, 4), nil)
		x := test_raw_vector(&r, dim)
		y := test_raw_vector(&r, dim)
		sx, _ := arena_insert(&a, x)
		sy, _ := arena_insert(&a, y)
		raw, _ := arena_alloc(&a)
		testing.expect(t, arena_set_raw(&a, raw, arena_bytes(&a, sx), arena_norm(&a, sx), arena_range(&a, sx)))
		testing.expect(t, !arena_set_raw(&a, raw, arena_bytes(&a, sx)[1:], 1, 1))
		testing.expect_value(t, arena_score(&a, raw, sy), arena_score(&a, sx, sy))
		buf, _ := runtime.mem_alloc(query_bytes(&a) + 8, ARENA_ALIGN, context.temp_allocator)
		q, ok := query_encode(&a, x, buf)
		testing.expect(t, ok)
		_, bad := query_encode(&a, x, buf[1:])
		testing.expect(t, !bad)
		testing.expect_value(t, arena_query_score(&a, q, sy), arena_score(&a, sx, sy))
		testing.expect_value(t, arena_query_distance(&a, q, sy), arena_distance(&a, sx, sy))
		testing.expect_value(t, arena_query_score(&a, query_slot(&a, sx), sy), arena_score(&a, sx, sy))
		self := arena_score(&a, sx, sx)
		testing.expectf(t, self >= 0.9999999 && self <= 1.0000002, "%v self score %v", elem, self)
		scratch := make([]f32, dim, context.temp_allocator)
		rb, _ := query_alloc(&a, context.temp_allocator)
		rq, rok := query_rebuild(&a, sx, scratch, rb)
		testing.expect(t, rok)
		testing.expectf(t, abs(arena_query_score(&a, rq, sy) - arena_score(&a, sx, sy)) < 1e-2, "%v rebuilt query drifts", elem)
		if elem == .Bin {
			bits := make([]u8, a.stride, context.temp_allocator)
			copy(bits, arena_bytes(&a, sx))
			u64_view(bits)[1] |= u64(1) << 63
			testing.expect(t, !arena_set_raw(&a, raw, bits, 1, 0))
		}
		arena_destroy(&a)
	}
}

@(test)
arena_double_free_is_an_error :: proc(t: ^testing.T) {
	r: Rng
	rng_seed(&r, 34)
	for elem in VSET_ELEMS {
		a: Arena
		testing.expect_value(t, arena_init(&a, elem, .Cosine, 5), nil)
		for _ in 0 ..< 10 {
			_, err := arena_insert(&a, test_raw_vector(&r, 5))
			testing.expect_value(t, err, nil)
		}
		testing.expect_value(t, arena_free(&a, 3), Free_Error.None)
		testing.expect_value(t, arena_free(&a, 3), Free_Error.Already_Free)
		testing.expect_value(t, arena_free(&a, 7), Free_Error.None)
		testing.expect_value(t, arena_free(&a, 3), Free_Error.Already_Free)
		testing.expect_value(t, arena_free(&a, 7), Free_Error.Already_Free)
		testing.expect_value(t, arena_free(&a, 10), Free_Error.Invalid_Slot)
		testing.expect_value(t, arena_free(&a, NIL_SLOT), Free_Error.Invalid_Slot)
		testing.expect_value(t, a.live, u32(8))
		testing.expect(t, !arena_is_live(&a, 3) && !arena_is_live(&a, 7) && arena_is_live(&a, 4))
		s1, _ := arena_alloc(&a)
		s2, _ := arena_alloc(&a)
		testing.expect_value(t, s1, u32(7))
		testing.expect_value(t, s2, u32(3))
		testing.expect(t, arena_is_live(&a, 3) && arena_is_live(&a, 7))
		testing.expect_value(t, a.free, NIL_SLOT)
		for slot in 0 ..< u32(10) {
			testing.expect_value(t, arena_free(&a, slot), Free_Error.None)
		}
		for slot in 0 ..< u32(10) {
			testing.expect_value(t, arena_free(&a, slot), Free_Error.Already_Free)
		}
		testing.expect_value(t, a.live, u32(0))
		for want := 9; want >= 0; want -= 1 {
			slot, err := arena_alloc(&a)
			testing.expect_value(t, err, nil)
			testing.expect_value(t, slot, u32(want))
		}
		arena_destroy(&a)
	}
}

@(test)
arena_free_marks_cannot_be_live_norms :: proc(t: ^testing.T) {
	a: Arena
	testing.expect_value(t, arena_init(&a, .F32, .Cosine, 3), nil)
	defer arena_destroy(&a)
	inputs := [][]f32{{0, 0, 0}, {1e-30, 0, -1e-30}, {math.inf_f32(1), 0, 1}, {math.inf_f32(-1), 0, 0}, {transmute(f32)u32(0xFFC00001), 1, 0}, {transmute(f32)u32(0x7FC00000), 0, 1}, {3e38, 3e38, 0}, {transmute(f32)u32(0x80000001), 0, 0}, {-1, -2, -3}}
	for x in inputs {
		slot, err := arena_insert(&a, x)
		testing.expect_value(t, err, nil)
		norm := arena_norm(&a, slot)
		testing.expectf(t, transmute(u32)norm >> 31 == 0, "norm %v of %v carries the free mark", norm, x)
		testing.expect(t, arena_is_live(&a, slot))
	}
	testing.expect_value(t, arena_norm(&a, 0), f32(1))
	testing.expect(t, math.is_nan(arena_norm(&a, 4)))
	raw := make([]u8, a.stride, context.temp_allocator)
	slot, _ := arena_alloc(&a)
	testing.expect(t, !arena_set_raw(&a, slot, raw, -1, 0))
	testing.expect(t, !arena_set_raw(&a, slot, raw, transmute(f32)u32(0x80000000), 0))
	testing.expect(t, arena_set_raw(&a, slot, raw, transmute(f32)u32(0xFFC00000), 0))
	testing.expect_value(t, transmute(u32)arena_norm(&a, slot), u32(0x7FC00000))
	testing.expect(t, !arena_set_normalised(&a, slot, []f32{1, 0, 0}, -2))
	testing.expect(t, arena_set_normalised(&a, slot, []f32{1, 0, 0}, 2))
	_, bad := arena_insert_normalised(&a, []f32{1, 0, 0}, -3)
	testing.expect_value(t, bad, runtime_invalid())
	testing.expect_value(t, arena_free(&a, slot), Free_Error.None)
	testing.expect_value(t, arena_free(&a, slot), Free_Error.Already_Free)
	s: Arena
	testing.expect_value(t, arena_init(&s, .Int8, .Cosine, 3, context.allocator, 0, .Search), nil)
	defer arena_destroy(&s)
	blob := []u8{0x80, 0x7F, 0}
	x, _ := arena_insert_blob(&s, blob)
	testing.expect(t, transmute(u32)arena_aux(&s, x) >> 31 == 0)
	testing.expect_value(t, arena_free(&s, x), Free_Error.None)
	testing.expect_value(t, arena_free(&s, x), Free_Error.Already_Free)
	y, _ := arena_insert_blob(&s, blob)
	testing.expect_value(t, y, x)
	testing.expect_value(t, arena_aux(&s, y), f32(math.sqrt(f64(128 * 128 + 127 * 127))))
}

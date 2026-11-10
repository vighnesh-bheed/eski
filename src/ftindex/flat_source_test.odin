package ftindex

import "core:fmt"
import "core:math"
import "core:testing"
import ftq "../ftquery"
import "../vmath"

random_blob :: proc(r: ^Rng, elem: vmath.Elem, dim: int, zero: bool) -> []u8 {
	out := make([]u8, vmath.elem_vector_bytes(elem, dim), context.temp_allocator)
	if zero {
		return out
	}
	for i in 0 ..< dim {
		x := f32(rng_below(r, 4001) - 2000) / 1000
		switch elem {
		case .F32:
			(^f32)(&out[4 * i])^ = x
		case .F64:
			(^f64)(&out[8 * i])^ = f64(x) + f64(rng_below(r, 1000)) * 1e-9
		case .F16:
			(^u16)(&out[2 * i])^ = vmath.f32_to_f16_away(x)
		case .BF16:
			(^u16)(&out[2 * i])^ = vmath.f32_to_bf16_rne(x)
		case .Int8, .U8:
			out[i] = u8(rng_below(r, 256))
		case .Bin:
		}
	}
	return out
}

same_distance :: proc(a, b: f64) -> bool {
	return a == b || (math.is_nan(a) && math.is_nan(b))
}

Odd_Filter :: struct {
	modulus: u32,
}

odd_accept :: proc(ctx: rawptr, id: u32) -> bool {
	f := (^Odd_Filter)(ctx)
	return id % f.modulus != 0
}

compare_hits :: proc(t: ^testing.T, label: string, a, b: []Vector_Hit) -> bool {
	if !testing.expectf(t, len(a) == len(b), "%s: flat %d hits, scan %d", label, len(a), len(b)) {
		return false
	}
	for x, i in a {
		y := b[i]
		if !testing.expectf(t, x.doc == y.doc && same_distance(x.distance, y.distance), "%s rank %d: flat %d %v, scan %d %v", label, i, x.doc, x.distance, y.doc, y.distance) {
			return false
		}
	}
	return true
}

@(test)
flat_source_agrees_with_the_scan_reference :: proc(t: ^testing.T) {
	r := Rng{0xF1A7_5C4}
	compared := 0
	for elem in ([?]vmath.Elem{.F32, .F64, .F16, .BF16, .Int8, .U8}) {
		for metric in vmath.Metric {
			for dim in ([?]int{1, 5, 19, 40}) {
				field := Field{name = "v", source = "v", kind = .Vector, weight = 1, separator = ',', vector = {method = .Flat, elem = elem, metric = metric, dim = dim}}
				flat, fe := flat_source_make(&field, context.allocator)
				scan, se := scan_source_make(&field, context.allocator)
				testing.expect(t, fe == .None && se == .None)
				pool := make([dynamic][]u8, context.temp_allocator)
				live := make([dynamic]u32, context.temp_allocator)
				next := u32(1)
				for _ in 0 ..< 160 {
					op := rng_below(&r, 10)
					switch {
					case op < 6 || len(live) == 0:
						blob: []u8
						if len(pool) > 0 && rng_below(&r, 4) == 0 {
							blob = pool[rng_below(&r, len(pool))]
						} else {
							blob = random_blob(&r, elem, dim, rng_below(&r, 25) == 0)
							append(&pool, blob)
						}
						testing.expect_value(t, flat.add(flat.ctx, next, blob), Error.None)
						testing.expect_value(t, scan.add(scan.ctx, next, blob), Error.None)
						append(&live, next)
						next += 1 + u32(rng_below(&r, 3))
					case op < 8:
						id := live[rng_below(&r, len(live))]
						blob := random_blob(&r, elem, dim, false)
						append(&pool, blob)
						testing.expect_value(t, flat.add(flat.ctx, id, blob), Error.None)
						testing.expect_value(t, scan.add(scan.ctx, id, blob), Error.None)
					case:
						at := rng_below(&r, len(live))
						flat.remove(flat.ctx, live[at])
						scan.remove(scan.ctx, live[at])
						unordered_remove(&live, at)
						flat.remove(flat.ctx, next + 1000)
					}
				}
				testing.expect_value(t, flat.count(flat.ctx), scan.count(scan.ctx))
				for round in 0 ..< 12 {
					qb := random_blob(&r, elem, dim, round == 5)
					if len(pool) > 0 && round % 4 == 1 {
						qb = pool[rng_below(&r, len(pool))]
					}
					filter := Odd_Filter{modulus = u32(2 + rng_below(&r, 3))}
					q := Vector_Query{blob = qb, k = rng_below(&r, 25), accepted = -1}
					if round % 3 == 0 {
						q.accept = odd_accept
						q.accept_ctx = &filter
					}
					a := make([dynamic]Vector_Hit, context.temp_allocator)
					b := make([dynamic]Vector_Hit, context.temp_allocator)
					testing.expect_value(t, flat.nearest(flat.ctx, &q, &a), Error.None)
					testing.expect_value(t, scan.nearest(scan.ctx, &q, &b), Error.None)
					label := fmt.tprintf("%v %v dim %d knn %d", elem, metric, dim, q.k)
					if !compare_hits(t, label, a[:], b[:]) {
						continue
					}
					all := make([dynamic]Vector_Hit, context.temp_allocator)
					everything := Vector_Query{blob = qb, k = 100_000, accepted = -1}
					scan.nearest(scan.ctx, &everything, &all)
					q.radius = f64(rng_below(&r, 400)) / 100
					if len(all) > 0 && round % 2 == 0 {
						pick := all[rng_below(&r, len(all))].distance
						if !math.is_nan(pick) {
							q.radius = max(pick, 0)
						}
					}
					clear(&a)
					clear(&b)
					testing.expect_value(t, flat.within(flat.ctx, &q, &a), Error.None)
					testing.expect_value(t, scan.within(scan.ctx, &q, &b), Error.None)
					sort_hits(b[:])
					compare_hits(t, fmt.tprintf("%s range %v", label, q.radius), a[:], b[:])
					compared += len(a)
				}
				bad := make([]u8, vmath.elem_vector_bytes(elem, dim) + 1, context.temp_allocator)
				wrong := Vector_Query{blob = bad, k = 3, accepted = -1}
				out := make([dynamic]Vector_Hit, context.temp_allocator)
				if flat.count(flat.ctx) > 0 {
					testing.expect_value(t, flat.nearest(flat.ctx, &wrong, &out), Error.Blob_Size)
					testing.expect_value(t, flat.within(flat.ctx, &wrong, &out), Error.Blob_Size)
				}
				testing.expect_value(t, flat.add(flat.ctx, 999_999, bad), Error.Blob_Size)
				flat.destroy(flat.ctx)
				scan.destroy(scan.ctx)
				free_all(context.temp_allocator)
			}
		}
	}
	testing.expectf(t, compared > 5000, "only %d range hits compared", compared)
}

@(test)
flat_is_the_default_source_and_reports_the_recorded_blob_error :: proc(t: ^testing.T) {
	fields := [?]Field {
		field_default("t", .Text),
		{name = "v", source = "v", kind = .Vector, weight = 1, separator = ',', vector = {method = .Flat, elem = .F32, metric = .L2, dim = 2}},
		{name = "s", source = "s", kind = .Vector, weight = 1, separator = ',', vector = {method = .Svs_Vamana, elem = .F32, metric = .L2, dim = 2}},
	}
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:])), Error.Unsupported)
	ix2: Index
	testing.expect_value(t, init(&ix2, definition_default(fields[:2])), Error.None)
	defer destroy(&ix2)
	testing.expect(t, ix2.slots[1].vector.add == flat_source_add && ix2.slots[1].vector.nearest == flat_source_nearest)
	v := [2]f32{1, 0}
	add(&ix2, "a", []Value{{"t", "hello"}, {"v", string(([^]u8)(&v)[:8])}})
	bad := [3]f32{1, 2, 3}
	text, _ := parse(&ix2, "hello", Query_Options{dialect = 2})
	defer ftq.parsed_destroy(text)
	res, err, qerr := hybrid(&ix2, text, Hybrid_Vector{field = 1, blob = ([^]u8)(&bad)[:12], k = 2}, {})
	defer hybrid_result_destroy(&res)
	testing.expect_value(t, err, Error.Query_Error)
	testing.expect_value(t, ftq.error_reply(qerr, context.temp_allocator), "SEARCH_QUERY_BAD Error parsing vector similarity query: query vector blob size (12) does not match index's expected size (8).")
	params := []ftq.Param{{name = "q", value = string(([^]u8)(&bad)[:12])}}
	knn, _ := parse(&ix2, "*=>[KNN 2 @v $q AS d]", Query_Options{dialect = 2, params = params})
	defer ftq.parsed_destroy(knn)
	r2, e2, q2 := execute(&ix2, knn, {})
	defer result_destroy(&r2)
	testing.expect_value(t, e2, Error.Query_Error)
	testing.expect_value(t, ftq.error_reply(q2, context.temp_allocator), "SEARCH_QUERY_BAD Error parsing vector similarity query: query vector blob size (12) does not match index's expected size (8).")
	free_all(context.temp_allocator)
}

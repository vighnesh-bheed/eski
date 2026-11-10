package vmath

import "base:runtime"
import "core:testing"

BATCH_TEST_LENGTHS :: [?]int{0, 1, 2, 3, 4, 5, 7, 8, 31, 32, 33, 100}

batch_fill :: proc(t: ^testing.T, a: ^Arena, r: ^Rng, family: Family, elem: Elem, dim: int, count: int) {
	for k in 0 ..< count {
		err: runtime.Allocator_Error
		if family == .Vector_Set {
			_, err = arena_insert(a, test_raw_vector(r, dim))
		} else {
			_, err = arena_insert_blob(a, search_random_blob(r, elem, dim, k % 3 == 0))
		}
		testing.expect_value(t, err, nil)
	}
}

batch_query :: proc(a: ^Arena, r: ^Rng, family: Family, elem: Elem, dim: int) -> (Query, bool) {
	buf, _ := query_alloc(a, context.temp_allocator)
	if family == .Vector_Set {
		return query_encode(a, test_raw_vector(r, dim), buf)
	}
	return query_encode_blob(a, search_random_blob(r, elem, dim, true), buf)
}

@(test)
batch_matches_single_slot_kernels :: proc(t: ^testing.T) {
	saved := kernels.level
	defer use_level(saved)
	r: Rng
	rng_seed(&r, 71)
	checked := 0
	dims := []int{1, 7, 8, 33, 64, 300}
	for level in search_probe_levels() {
		use_level(level)
		for family in Family {
			for elem in Elem {
				for metric in Metric {
					if !family_supports(family, elem, metric) {
						continue
					}
					for dim in dims {
						a: Arena
						testing.expect_value(t, arena_init(&a, elem, metric, dim, context.allocator, 0, family), nil)
						batch_fill(t, &a, &r, family, elem, dim, 64)
						q, ok := batch_query(&a, &r, family, elem, dim)
						testing.expect(t, ok)
						ctx := Arena_Query{&a, q}
						for n in BATCH_TEST_LENGTHS {
							slots := make([]u32, n, context.temp_allocator)
							for &s in slots {
								s = u32(rng_next(&r) % 64)
							}
							out := make([]f32, n, context.temp_allocator)
							hooked := make([]f32, n, context.temp_allocator)
							arena_query_distances(&a, &q, slots, out)
							arena_batch_hook(&ctx, slots, hooked)
							for s, i in slots {
								want := arena_query_distance(&a, q, s)
								testing.expectf(t, transmute(u32)out[i] == transmute(u32)want, "%v %v %v %v dim %d batch %d slot %d: %v against %v", level, family, elem, metric, dim, n, s, out[i], want)
								testing.expect_value(t, transmute(u32)hooked[i], transmute(u32)want)
								testing.expect_value(t, transmute(u32)arena_query_hook(&ctx, s), transmute(u32)want)
								arena_prefetch_hook(&a, s)
								checked += 1
							}
						}
						short := make([]f32, 2, context.temp_allocator)
						short[1] = 7
						arena_query_distances(&a, &q, []u32{3, 4, 5}, short[:1])
						testing.expect_value(t, short[1], f32(7))
						arena_destroy(&a)
						free_all(context.temp_allocator)
					}
				}
			}
		}
	}
	testing.expect(t, checked > 0)
}

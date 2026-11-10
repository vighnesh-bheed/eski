package flatindex

import "core:fmt"
import "core:math"
import "core:testing"
import "../roaring"
import "../vmath"

f32_below :: proc(x: f32) -> f32 {
	if x == 0 {
		return -transmute(f32)u32(1)
	}
	b := transmute(u32)x
	return transmute(f32)(b - 1 if x > 0 else b + 1)
}

@(test)
range_matches_brute_force :: proc(t: ^testing.T) {
	for elem, ei in ALL_ELEMS {
		for metric, mi in ALL_METRICS {
			for dim, di in ([]int{2, 9, 32, 47}) {
				spec := spec_default(elem, metric, dim)
				spec.block_size = 8 if di % 2 == 0 else 1024
				c: Corpus
				seed := u64(5000 + 100 * ei + 10 * mi + di)
				corpus_build(t, &c, spec, 80, seed, true, true)
				r: vmath.Rng
				vmath.rng_seed(&r, seed + 3)
				out := make([dynamic]Hit, context.temp_allocator)
				for qi in 0 ..< 3 {
					qy: Query
					testing.expect_value(t, query_for(&qy, &c.ix, random_blob(&r, elem, dim, qi == 1), context.temp_allocator), Error.None)
					all := oracle_knn(&c.m, &qy, len(c.m.ids), nil, &c.ix)
					radii := make([dynamic]f64, context.temp_allocator)
					append(&radii, 0, 1e300, math.inf_f64(1))
					for h, i in all {
						if i % 9 != 0 || !finite(h.dist) || h.dist < 0 {
							continue
						}
						append(&radii, h.dist, math.nextafter(h.dist, math.inf_f64(-1)), math.nextafter(h.dist, math.inf_f64(1)))
						if elem != .F64 {
							append(&radii, f64(f32_below(f32(h.dist))))
						}
					}
					for radius in radii {
						if radius < 0 {
							clear(&out)
							testing.expect_value(t, range_search(&c.ix, &qy, radius, &out), Error.Negative_Radius)
							testing.expect_value(t, len(out), 0)
							continue
						}
						for limit in ([]int{-1, 0, 3}) {
							for order in Order {
								clear(&out)
								testing.expect_value(t, range_search(&c.ix, &qy, radius, &out, {}, limit, order), Error.None)
								want := oracle_range(&c.m, &qy, radius, nil, &c.ix, limit, order)
								if !expect_hits(t, out[:], want, fmt.tprintf("%v %v dim %d radius %v limit %d %v", elem, metric, dim, radius, limit, order)) {
									return
								}
							}
						}
						sel := Select{salt = u64(qi), percent = 40}
						f := Oracle_Filter{accept = select_accept, ctx = &sel}
						clear(&out)
						testing.expect_value(t, range_search(&c.ix, &qy, radius, &out, filter_accept(select_accept, &sel)), Error.None)
						want := oracle_range(&c.m, &qy, radius, &f, &c.ix)
						if !expect_hits(t, out[:], want, fmt.tprintf("%v %v dim %d radius %v accept", elem, metric, dim, radius)) {
							return
						}
						bm: roaring.Bitmap
						roaring.init(&bm, context.temp_allocator)
						cands := make([dynamic]u32, context.temp_allocator)
						allow := Oracle_Filter{use = true}
						allow.allow = make(map[u32]bool, 16, context.temp_allocator)
						for id in c.m.ids {
							if hash_id(id, 5) % 2 == 0 {
								roaring.add(&bm, id)
								append(&cands, id)
								allow.allow[id] = true
							}
						}
						clear(&out)
						testing.expect_value(t, range_search(&c.ix, &qy, radius, &out, filter_bitmap(&bm), -1, .Id), Error.None)
						want = oracle_range(&c.m, &qy, radius, &allow, &c.ix, -1, .Id)
						expect_hits(t, out[:], want, "bitmap range")
						clear(&out)
						testing.expect_value(t, range_search(&c.ix, &qy, radius, &out, filter_ids(cands[:]), 2), Error.None)
						want = oracle_range(&c.m, &qy, radius, &allow, &c.ix, 2)
						expect_hits(t, out[:], want, "ids range limited")
					}
				}
				corpus_destroy(&c)
				free_all(context.temp_allocator)
			}
		}
	}
}

@(test)
range_bound_rounds_to_the_element_precision :: proc(t: ^testing.T) {
	for elem in ALL_ELEMS {
		spec := spec_default(elem, .L2, 1)
		ix: Index
		testing.expect_value(t, init(&ix, spec, context.allocator), Error.None)
		r: vmath.Rng
		vmath.rng_seed(&r, u64(elem) + 1)
		for id in u32(1) ..= 40 {
			add(&ix, id, random_blob(&r, elem, 1, false))
		}
		qy: Query
		testing.expect_value(t, query_for(&qy, &ix, random_blob(&r, elem, 1, false)), Error.None)
		out := make([dynamic]Hit, context.temp_allocator)
		for id in u32(1) ..= 40 {
			d, ok := distance(&ix, &qy, id)
			testing.expect(t, ok)
			if !finite(d) || d == 0 {
				continue
			}
			inside :: proc(ix: ^Index, qy: ^Query, out: ^[dynamic]Hit, radius: f64, id: u32) -> bool {
				clear(out)
				range_search(ix, qy, radius, out)
				for h in out {
					if h.id == id {
						return true
					}
				}
				return false
			}
			testing.expectf(t, inside(&ix, &qy, &out, d, id), "%v: distance %v is inside its own radius", elem, d)
			below := math.nextafter(d, math.inf_f64(-1))
			testing.expectf(t, inside(&ix, &qy, &out, below, id) == (elem != .F64), "%v: radius %v just below distance %v", elem, below, d)
			if elem != .F64 {
				lo := f64(f32_below(f32(d)))
				testing.expectf(t, !inside(&ix, &qy, &out, lo, id), "%v: the float32 below %v excludes it", elem, d)
				mid := (lo + d) / 2
				even := transmute(u32)f32(d) & 1 == 0
				testing.expectf(t, inside(&ix, &qy, &out, mid, id) == even, "%v: the midpoint below %v rounds to even", elem, d)
			}
		}
		query_destroy(&qy)
		destroy(&ix)
	}
}

package flatindex

import "core:log"
import "core:mem"
import "core:testing"
import "../roaring"
import "../vmath"

@(test)
spec_bounds_are_checked :: proc(t: ^testing.T) {
	testing.expect_value(t, spec_check(spec_default(.F32, .L2, 4)), Error.None)
	testing.expect_value(t, spec_check(spec_default(.Bin, .Cosine, 4)), Error.Invalid_Spec)
	testing.expect_value(t, spec_check(spec_default(.F32, .L2, 0)), Error.Invalid_Spec)
	testing.expect_value(t, spec_check(spec_default(.F32, .L2, vmath.DIM_MAX + 1)), Error.Invalid_Spec)
	testing.expect_value(t, spec_check(spec_default(.F32, .L2, vmath.DIM_MAX)), Error.None)
	s := spec_default(.F16, .IP, 3)
	s.block_size = 0
	testing.expect_value(t, spec_check(s), Error.Invalid_Spec)
	s.block_size = 1
	s.initial_cap = -1
	testing.expect_value(t, spec_check(s), Error.Invalid_Spec)
	s.initial_cap = 0
	testing.expect_value(t, spec_check(s), Error.None)
	testing.expect(t, block_size_valid(1) && block_size_valid(4294967296) && !block_size_valid(0) && !block_size_valid(-1))
	testing.expect(t, initial_cap_valid(0) && initial_cap_valid(100) && !initial_cap_valid(-1))
	for elem in ALL_ELEMS {
		for metric in ALL_METRICS {
			testing.expect_value(t, spec_check(spec_default(elem, metric, 19)), Error.None)
		}
	}
	testing.expect_value(t, vector_bytes(spec_default(.F64, .L2, 4)), 32)
	testing.expect_value(t, vector_bytes(spec_default(.BF16, .L2, 4)), 8)
	testing.expect_value(t, vector_bytes(spec_default(.U8, .L2, 4)), 4)
	testing.expect_value(t, slot_bytes(spec_default(.F32, .Cosine, 128)), 520)
	testing.expect_value(t, type_name(spec_default(.BF16, .L2, 4)), "BFLOAT16")
	testing.expect_value(t, metric_name(spec_default(.BF16, .Cosine, 4)), "COSINE")
}

@(test)
empty_index_allocates_nothing :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	ix: Index
	testing.expect_value(t, init(&ix, spec_default(.F32, .Cosine, 1536), alloc), Error.None)
	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, memory(&ix), 0)
	testing.expect_value(t, count(&ix), 0)
	q := make([]u8, 1536 * 4)
	defer delete(q)
	q[3] = 0x3F
	qy: Query
	testing.expect_value(t, query_for(&qy, &ix, q), Error.None)
	out: [dynamic]Hit
	defer delete(out)
	testing.expect_value(t, knn(&ix, &qy, 10, &out), Error.None)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, range_search(&ix, &qy, 2, &out), Error.None)
	testing.expect_value(t, len(out), 0)
	query_destroy(&qy)
	testing.expect_value(t, track.total_allocation_count, 0)
	destroy(&ix)
	log.infof("an empty index is %d bytes with no allocation; each block adds %d bytes of bookkeeping", size_of(Index), size_of(Block))
}

@(test)
initial_cap_sizes_the_first_allocation :: proc(t: ^testing.T) {
	v := [4]f32{1, 2, 3, 4}
	blob := mem.slice_to_bytes(v[:])
	for c in ([][2]int{{0, 1}, {1, 1}, {100, 100}, {5000, 1024}}) {
		spec := spec_default(.F32, .IP, 4)
		spec.initial_cap = c[0]
		ix: Index
		testing.expect_value(t, init(&ix, spec, context.allocator), Error.None)
		testing.expect_value(t, capacity(&ix), 0)
		add(&ix, 1, blob)
		testing.expect_value(t, capacity(&ix), c[1])
		destroy(&ix)
	}
	spec := spec_default(.F32, .IP, 4)
	spec.block_size = 64
	spec.initial_cap = 1000
	ix: Index
	testing.expect_value(t, init(&ix, spec, context.allocator), Error.None)
	defer destroy(&ix)
	for id in u32(0) ..< 200 {
		add(&ix, id, blob)
	}
	testing.expect_value(t, len(ix.blocks), 4)
	testing.expect_value(t, capacity(&ix), 256)
	testing.expect(t, check_layout(t, &ix))
}

@(test)
add_remove_replace :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	ix: Index
	testing.expect_value(t, init(&ix, spec_default(.F32, .L2, 2), alloc), Error.None)
	v := [2]f32{1, 2}
	w := [2]f32{3, 4}
	blob := mem.slice_to_bytes(v[:])
	other := mem.slice_to_bytes(w[:])
	replaced, err := add(&ix, 5, blob)
	testing.expect(t, !replaced && err == .None)
	replaced, err = add(&ix, 5, other)
	testing.expect(t, replaced && err == .None)
	data, _, ok := stored(&ix, 5)
	testing.expect(t, ok && vmath.f32_view(data)[0] == 3)
	_, err = add(&ix, 6, blob[:4])
	testing.expect_value(t, err, Error.Blob_Size)
	_, err = add(&ix, ID_NONE, blob)
	testing.expect_value(t, err, Error.Invalid_Id)
	testing.expect(t, contains(&ix, 5) && !contains(&ix, 6))
	testing.expect_value(t, remove(&ix, 6), Error.Not_Found)
	testing.expect_value(t, remove(&ix, 5), Error.None)
	testing.expect_value(t, remove(&ix, 5), Error.Not_Found)
	testing.expect(t, !contains(&ix, 5))
	testing.expect_value(t, count(&ix), 0)
	testing.expect_value(t, len(ix.blocks), 0)
	for id in 0 ..< u32(40) {
		_, err = add(&ix, id * 3, blob)
		testing.expect_value(t, err, Error.None)
	}
	testing.expect_value(t, count(&ix), 40)
	i := info(&ix)
	testing.expect_value(t, i.count, 40)
	testing.expect_value(t, i.vector_bytes, 8)
	testing.expect_value(t, i.marked_deleted, 0)
	testing.expect(t, i.memory > 40 * 8 && i.memory == memory(&ix))
	testing.expect(t, i.capacity >= 40)
	destroy(&ix)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
query_errors_are_values :: proc(t: ^testing.T) {
	ix: Index
	testing.expect_value(t, init(&ix, spec_default(.F32, .L2, 2), context.allocator), Error.None)
	defer destroy(&ix)
	v := [2]f32{1, 2}
	blob := mem.slice_to_bytes(v[:])
	add(&ix, 1, blob)
	qy: Query
	testing.expect_value(t, query_for(&qy, &ix, blob[:7]), Error.Blob_Size)
	testing.expect_value(t, query_for(&qy, &ix, {}), Error.Blob_Size)
	big := make([]u8, 12, context.temp_allocator)
	testing.expect_value(t, query_for(&qy, &ix, big), Error.Blob_Size)
	testing.expect_value(t, len(big) == vector_bytes(ix.spec), false)
	other: Query
	testing.expect_value(t, query_init(&other, spec_default(.F32, .IP, 2), blob), Error.None)
	defer query_destroy(&other)
	out: [dynamic]Hit
	defer delete(out)
	testing.expect_value(t, knn(&ix, &other, 1, &out), Error.Query_Mismatch)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, query_for(&qy, &ix, blob), Error.None)
	defer query_destroy(&qy)
	testing.expect_value(t, range_search(&ix, &qy, -1, &out), Error.Negative_Radius)
	nan := transmute(f64)u64(0x7FF8000000000000)
	testing.expect_value(t, range_search(&ix, &qy, nan, &out), Error.Invalid_Radius)
	testing.expect_value(t, range_search(&ix, &qy, 0, &out), Error.None)
	testing.expect_value(t, len(out), 1)
	clear(&out)
	bad := []u32{3, 1}
	testing.expect_value(t, knn(&ix, &qy, 3, &out, filter_ids(bad)), Error.Unsorted_Ids)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, knn(&ix, &qy, 0, &out), Error.None)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, knn(&ix, &qy, -4, &out), Error.None)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, knn(&ix, &qy, 9, &out), Error.None)
	testing.expect_value(t, len(out), 1)
	clear(&out)
	empty: roaring.Bitmap
	roaring.init(&empty)
	defer roaring.destroy(&empty)
	testing.expect_value(t, knn(&ix, &qy, 3, &out, filter_bitmap(&empty)), Error.None)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, knn(&ix, &qy, 3, &out, filter_bitmap(nil)), Error.None)
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, knn(&ix, &qy, 3, &out, filter_ids({})), Error.None)
	testing.expect_value(t, len(out), 0)
	_, err := radius_bound(.F32, 0.1)
	testing.expect_value(t, err, Error.None)
}

@(test)
results_append_after_existing :: proc(t: ^testing.T) {
	ix: Index
	testing.expect_value(t, init(&ix, spec_default(.F32, .L2, 1), context.allocator), Error.None)
	defer destroy(&ix)
	for i in 0 ..< 6 {
		v := [1]f32{f32(i)}
		add(&ix, u32(10 + i), mem.slice_to_bytes(v[:]))
	}
	z := [1]f32{2.2}
	qy: Query
	testing.expect_value(t, query_for(&qy, &ix, mem.slice_to_bytes(z[:])), Error.None)
	defer query_destroy(&qy)
	out := make([dynamic]Hit)
	defer delete(out)
	append(&out, Hit{id = 99, dist = -5})
	testing.expect_value(t, knn(&ix, &qy, 3, &out), Error.None)
	testing.expect_value(t, len(out), 4)
	testing.expect_value(t, out[0].id, 99)
	testing.expect_value(t, out[1].id, 12)
	testing.expect_value(t, out[2].id, 13)
	testing.expect_value(t, out[3].id, 11)
	testing.expect_value(t, range_search(&ix, &qy, 1.5, &out, {}, -1, .Id), Error.None)
	testing.expect_value(t, len(out), 7)
	testing.expect_value(t, out[4].id, 11)
	testing.expect_value(t, out[5].id, 12)
	testing.expect_value(t, out[6].id, 13)
}

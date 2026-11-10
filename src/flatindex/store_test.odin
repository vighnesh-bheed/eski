package flatindex

import "core:mem"
import "core:testing"
import "../vmath"

Churn :: struct {
	ops:        int,
	max_id:     u32,
	monotonic:  bool,
	delete_pct: int,
	check_each: bool,
}

churn_run :: proc(t: ^testing.T, spec: Spec, c: Churn, seed: u64) -> bool {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	ix: Index
	testing.expect_value(t, init(&ix, spec, mem.tracking_allocator(&track)), Error.None)
	m: Model
	model_init(&m, spec)
	defer model_destroy(&m)
	r: vmath.Rng
	vmath.rng_seed(&r, seed)
	next: u32 = 1
	ok := true
	for op in 0 ..< c.ops {
		roll := rand_below(&r, 100)
		if roll < c.delete_pct && len(m.ids) > 0 {
			id := m.ids[rand_below(&r, len(m.ids))]
			if rand_below(&r, 10) == 0 {
				id = u32(rand_below(&r, int(c.max_id)))
			}
			want := model_del(&m, id)
			got := remove(&ix, id)
			if !testing.expect_value(t, got, Error.None if want else Error.Not_Found) {
				ok = false
				break
			}
		} else {
			id: u32
			if c.monotonic || rand_below(&r, 4) != 0 {
				id = next
				next += u32(1 + rand_below(&r, 3))
			} else {
				id = u32(rand_below(&r, int(next) + 2))
			}
			blob := random_blob(&r, spec.elem, spec.dim, rand_below(&r, 2) == 0)
			_, exists := m.blobs[id]
			replaced, err := add(&ix, id, blob)
			if !testing.expect_value(t, err, Error.None) || !testing.expect_value(t, replaced, exists) {
				ok = false
				break
			}
			model_put(&m, id, blob)
		}
		if c.check_each || op % 97 == 0 || op == c.ops - 1 {
			if !check_layout(t, &ix) || !check_contents(t, &ix, &m) {
				ok = false
				break
			}
		}
		free_all(context.temp_allocator)
	}
	if ok && len(m.ids) > 0 {
		live := len(m.ids)
		cap_total := capacity(&ix)
		bound := 2 * live + 2 * ix.block + 2 * GROWTH_MIN * len(ix.blocks)
		testing.expectf(t, cap_total <= bound, "capacity %d for %d live vectors (block %d, %d blocks)", cap_total, live, ix.block, len(ix.blocks))
	}
	destroy(&ix)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
	return ok
}

@(test)
layout_survives_churn_small_blocks :: proc(t: ^testing.T) {
	sizes := [?]int{1, 2, 3, 5, 8, 64}
	for bs, i in sizes {
		spec := spec_default(.F32, .L2, 3)
		spec.block_size = bs
		churn_run(t, spec, Churn{ops = 1500, max_id = 4000, delete_pct = 35, check_each = bs <= 3}, u64(100 + i))
		spec.initial_cap = 2
		churn_run(t, spec, Churn{ops = 800, max_id = 4000, delete_pct = 50, monotonic = true}, u64(200 + i))
	}
}

@(test)
layout_survives_churn_every_type :: proc(t: ^testing.T) {
	for elem, ei in ALL_ELEMS {
		for metric, mi in ALL_METRICS {
			spec := spec_default(elem, metric, 5)
			spec.block_size = 16
			churn_run(t, spec, Churn{ops = 600, max_id = 2000, delete_pct = 40}, u64(300 + 10 * ei + mi))
		}
	}
}

@(test)
layout_default_block_growth :: proc(t: ^testing.T) {
	spec := spec_default(.Int8, .Cosine, 4)
	churn_run(t, spec, Churn{ops = 5000, max_id = 20000, delete_pct = 20, monotonic = true}, 7)
	churn_run(t, spec, Churn{ops = 4000, max_id = 20000, delete_pct = 45}, 8)
}

@(test)
deleted_slots_are_reused :: proc(t: ^testing.T) {
	spec := spec_default(.F32, .IP, 4)
	spec.block_size = 32
	ix: Index
	testing.expect_value(t, init(&ix, spec, context.allocator), Error.None)
	defer destroy(&ix)
	r: vmath.Rng
	vmath.rng_seed(&r, 11)
	next: u32 = 0
	for _ in 0 ..< 200 {
		add(&ix, next, random_blob(&r, .F32, 4, false))
		next += 1
	}
	peak := capacity(&ix)
	for round in 0 ..< 30 {
		for i in 0 ..< 150 {
			victim := next - 200 + u32(i)
			testing.expect_value(t, remove(&ix, victim), Error.None)
			_, err := add(&ix, next + u32(i), random_blob(&r, .F32, 4, false))
			testing.expect_value(t, err, Error.None)
		}
		next += 150
		testing.expect(t, check_layout(t, &ix))
		testing.expectf(t, capacity(&ix) <= peak + 2 * 32, "round %d capacity %d after peak %d", round, capacity(&ix), peak)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, count(&ix), 200)
}

@(test)
out_of_order_inserts_split_blocks :: proc(t: ^testing.T) {
	spec := spec_default(.U8, .L2, 2)
	spec.block_size = 4
	ix: Index
	testing.expect_value(t, init(&ix, spec, context.allocator), Error.None)
	defer destroy(&ix)
	m: Model
	model_init(&m, spec)
	defer model_destroy(&m)
	order := [?]u32{100, 200, 300, 400, 500, 600, 700, 800, 150, 151, 152, 153, 154, 50, 10, 20, 30, 40, 450, 451, 452, 801, 802, 1, 0}
	for id, i in order {
		b := [2]u8{u8(i), u8(id)}
		_, err := add(&ix, id, b[:])
		testing.expect_value(t, err, Error.None)
		model_put(&m, id, b[:])
		testing.expect(t, check_layout(t, &ix))
	}
	testing.expect(t, check_contents(t, &ix, &m))
	for id in ([]u32{153, 10, 800, 0, 300}) {
		testing.expect_value(t, remove(&ix, id), Error.None)
		model_del(&m, id)
		testing.expect(t, check_layout(t, &ix))
	}
	for id in ([]u32{153, 10, 0, 299, 301}) {
		b := [2]u8{9, 9}
		_, err := add(&ix, id, b[:])
		testing.expect_value(t, err, Error.None)
		model_put(&m, id, b[:])
		testing.expect(t, check_layout(t, &ix))
	}
	testing.expect(t, check_contents(t, &ix, &m))
}

Failing :: struct {
	backing: mem.Allocator,
	left:    int,
	failed:  int,
}

failing_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	f := (^Failing)(data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		if f.left == 0 {
			f.failed += 1
			return nil, .Out_Of_Memory
		}
		f.left -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
allocation_failures_leave_the_index_consistent :: proc(t: ^testing.T) {
	failures := 0
	for budget in 0 ..< 60 {
		for bs in ([]int{3, 8}) {
			f := Failing{backing = context.allocator, left = budget}
			alloc := mem.Allocator{procedure = failing_proc, data = &f}
			spec := spec_default(.F32, .L2, 3)
			spec.block_size = bs
			ix: Index
			testing.expect_value(t, init(&ix, spec, alloc), Error.None)
			m: Model
			model_init(&m, spec)
			r: vmath.Rng
			vmath.rng_seed(&r, u64(budget))
			next: u32 = 1
			for step in 0 ..< 120 {
				if step % 5 == 4 && len(m.ids) > 0 {
					id := m.ids[rand_below(&r, len(m.ids))]
					testing.expect_value(t, remove(&ix, id), Error.None)
					model_del(&m, id)
				} else {
					id := next if rand_below(&r, 3) != 0 else u32(rand_below(&r, int(next)))
					next += 2
					blob := random_blob(&r, .F32, 3, false)
					_, exists := m.blobs[id]
					_, err := add(&ix, id, blob)
					if err == .None {
						model_put(&m, id, blob)
					} else {
						testing.expect_value(t, err, Error.Out_Of_Memory)
						if exists {
							model_put(&m, id, blob)
						}
						failures += 1
					}
				}
				if !check_layout(t, &ix) || !check_contents(t, &ix, &m) {
					break
				}
				free_all(context.temp_allocator)
			}
			destroy(&ix)
			model_destroy(&m)
		}
	}
	testing.expect(t, failures > 50)
}

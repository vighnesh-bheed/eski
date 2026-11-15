package hnsw

import "core:testing"

restore_copy :: proc(t: ^testing.T, src: ^Index, dst: ^Index, p: ^Points) -> Restore_Fault {
	params := test_params(src.m, src.ef_construction, 1)
	testing.expect_value(t, init(dst, params, points_distance, p, context.allocator), Error.None)
	free: [dynamic]u32
	defer delete(free)
	testing.expect(t, free_chain(src, &free))
	if restore_reserve(dst, src.cap, src.slots, free[:], src.twin_link != nil) != .None {
		return .Out_Of_Memory
	}
	buf := make([]u32, src.m0)
	defer delete(buf)
	for i in 0 ..< src.slots {
		slot := u32(i)
		lv := src.levels[slot]
		switch {
		case lv == LEVEL_TWIN:
			testing.expect_value(t, restore_twin(dst, slot, twin_prev(src, slot)), Error.None)
		case lv <= LEVEL_CAP:
			testing.expect_value(t, restore_node(dst, slot, int(lv)), Error.None)
			for layer in 0 ..= int(lv) {
				ids := list_decode(src, list_get(src, slot, layer), raw_data(buf))
				testing.expect_value(t, restore_list(dst, slot, layer, ids), Error.None)
			}
		}
	}
	return restore_finish(dst, src.entry, src.max_level, src.rng, src.node_uid, src.twins)
}

restore_same :: proc(a: ^Index, b: ^Index) -> bool {
	if a.slots != b.slots || a.cap != b.cap || a.entry != b.entry || a.max_level != b.max_level || a.live != b.live || a.twins != b.twins || a.rng != b.rng || a.node_uid != b.node_uid || a.width != b.width || a.free_head != b.free_head {
		return false
	}
	for i in 0 ..< a.slots {
		slot := u32(i)
		if a.levels[slot] != b.levels[slot] || next_twin(a, slot) != next_twin(b, slot) {
			return false
		}
		if a.levels[slot] == LEVEL_TWIN && twin_prev(a, slot) != twin_prev(b, slot) {
			return false
		}
		if a.levels[slot] <= LEVEL_CAP {
			for layer in 0 ..= int(a.levels[slot]) {
				la := list_get(a, slot, layer)
				lb := list_get(b, slot, layer)
				if la.count != lb.count {
					return false
				}
				for k in 0 ..< la.count {
					if list_id(a, la, k) != list_id(b, lb, k) {
						return false
					}
				}
			}
		}
	}
	fa: [dynamic]u32
	fb: [dynamic]u32
	defer delete(fa)
	defer delete(fb)
	free_chain(a, &fa)
	free_chain(b, &fb)
	if len(fa) != len(fb) {
		return false
	}
	for x, i in fa {
		if fb[i] != x {
			return false
		}
	}
	return true
}

restore_build :: proc(t: ^testing.T, ix: ^Index, s: ^Scratch, p: ^Points, seed: u64) {
	dim :: 6
	params := test_params(4, 30, seed)
	testing.expect_value(t, init(ix, params, points_distance, p, context.allocator), Error.None)
	state := seed
	a := make([]f32, dim)
	defer delete(a)
	v := make([]f32, dim)
	defer delete(v)
	random_unit(&state, a)
	for i in 0 ..< 300 {
		random_unit(&state, v)
		add_point(t, ix, s, p, a if i % 9 == 0 else v)
	}
	for i in 0 ..< 300 {
		slot := u32((i * 37) % 300)
		if i % 4 == 0 && is_live(ix, slot) {
			remove(ix, s, slot)
		}
	}
	for _ in 0 ..< 20 {
		random_unit(&state, v)
		add_point(t, ix, s, p, v)
	}
}

@(test)
restore_rebuilds_the_same_index :: proc(t: ^testing.T) {
	p: Points
	points_init(&p, 6, true, 400)
	defer points_destroy(&p)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	src: Index
	restore_build(t, &src, &s, &p, 0x5E57)
	defer destroy(&src)
	testing.expect(t, src.twins > 0 && src.free_head != NONE && src.max_level > 0, "the source graph has twins, free slots and upper layers")
	dst: Index
	testing.expect_value(t, restore_copy(t, &src, &dst, &p), Restore_Fault.None)
	defer destroy(&dst)
	testing.expect(t, restore_same(&src, &dst))
	check_graph(t, &dst)
	q := make([]f32, 6)
	defer delete(q)
	state := u64(0x99)
	out_a := make([]Candidate, 20)
	defer delete(out_a)
	out_b := make([]Candidate, 20)
	defer delete(out_b)
	for _ in 0 ..< 50 {
		random_unit(&state, q)
		pq := Point_Query{points = &p, q = q}
		na, _ := search(&src, &s, point_query_distance, &pq, 20, 40, out_a)
		nb, _ := search(&dst, &s, point_query_distance, &pq, 20, 40, out_b)
		testing.expect_value(t, nb, na)
		for i in 0 ..< min(na, nb) {
			testing.expect(t, out_a[i] == out_b[i])
		}
	}
	v := make([]f32, 6)
	defer delete(v)
	sa := u64(0x123)
	sb := sa
	for _ in 0 ..< 30 {
		random_unit(&sa, v)
		x, _ := reserve(&src)
		points_set(&p, x, v)
		insert(&src, &s, x)
		random_unit(&sb, v)
		y, _ := reserve(&dst)
		testing.expect_value(t, y, x)
		insert(&dst, &s, y)
	}
	testing.expect(t, restore_same(&src, &dst), "the same further inserts keep both indexes equal")
}

Restore_Breaker :: struct {
	name: string,
	want: Restore_Fault,
	edit: proc(ix: ^Index) -> bool,
}

restore_first_link :: proc(ix: ^Index, layer: int) -> (a: u32, b: u32, ok: bool) {
	for i in 0 ..< ix.slots {
		slot := u32(i)
		if ix.levels[slot] <= LEVEL_CAP && int(ix.levels[slot]) >= layer && list_count(ix, slot, layer) > 1 {
			return slot, list_id(ix, list_get(ix, slot, layer), 0), true
		}
	}
	return
}

@(test)
restore_check_finds_each_fault :: proc(t: ^testing.T) {
	breakers := []Restore_Breaker {
		{"a reserved slot", .Level, proc(ix: ^Index) -> bool {
				a, _, ok := restore_first_link(ix, 0)
				ix.levels[a] = LEVEL_RESERVED
				return ok
			}},
		{"a link beyond the slots", .Link_Range, proc(ix: ^Index) -> bool {
				a, _, ok := restore_first_link(ix, 0)
				list_put(ix, list_get(ix, a, 0), 0, u32(ix.slots))
				return ok
			}},
		{"a link to itself", .Link_Self, proc(ix: ^Index) -> bool {
				a, _, ok := restore_first_link(ix, 0)
				list_put(ix, list_get(ix, a, 0), 0, a)
				return ok
			}},
		{"a repeated link", .Link_Repeat, proc(ix: ^Index) -> bool {
				a, b, ok := restore_first_link(ix, 0)
				list_put(ix, list_get(ix, a, 0), 1, b)
				return ok
			}},
		{"a link to a free slot", .Link_Target, proc(ix: ^Index) -> bool {
				a, _, ok := restore_first_link(ix, 0)
				list_put(ix, list_get(ix, a, 0), 0, ix.free_head)
				return ok && ix.free_head != NONE
			}},
		{"a one way link", .Asymmetric, proc(ix: ^Index) -> bool {
				a, b, ok := restore_first_link(ix, 0)
				return ok && list_remove(ix, b, 0, a)
			}},
		{"an entry below the top", .Entry, proc(ix: ^Index) -> bool {
				ix.max_level += 1
				return true
			}},
		{"a twin after a free slot", .Twin_Prev, proc(ix: ^Index) -> bool {
				for i in 0 ..< ix.slots {
					if ix.levels[i] == LEVEL_TWIN {
						twin_prev_set(ix, u32(i), ix.free_head)
						return ix.free_head != NONE
					}
				}
				return false
			}},
		{"two twins after one slot", .Twin_Fork, proc(ix: ^Index) -> bool {
				first := NONE
				for i in 0 ..< ix.slots {
					if ix.levels[i] != LEVEL_TWIN {
						continue
					}
					if first == NONE {
						first = u32(i)
					} else if twin_prev(ix, u32(i)) != twin_prev(ix, first) && twin_prev(ix, first) != u32(i) {
						twin_prev_set(ix, u32(i), twin_prev(ix, first))
						return true
					}
				}
				return false
			}},
		{"a twin count that does not match", .Counts, proc(ix: ^Index) -> bool {
				ix.twins += 1
				return true
			}},
	}
	p: Points
	points_init(&p, 6, true, 400)
	defer points_destroy(&p)
	s: Scratch
	scratch_init(&s, context.allocator)
	defer scratch_destroy(&s)
	for b in breakers {
		src: Index
		restore_build(t, &src, &s, &p, 0xB0B)
		testing.expect_value(t, restore_check(&src), Restore_Fault.None)
		if testing.expectf(t, b.edit(&src), "%s: no place for the fault", b.name) {
			got := restore_check(&src)
			testing.expectf(t, got == b.want, "%s: found %v, wanted %v", b.name, got, b.want)
		}
		destroy(&src)
		clear(&p.data)
	}
}

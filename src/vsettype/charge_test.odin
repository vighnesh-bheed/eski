package vsettype

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import "../hnsw"
import lbl "../label"
import "../rax"

own_names_bytes :: proc(p: ^Part_Head) -> int {
	t := rax.create()
	defer rax.destroy(t)
	before := rax.memory(t)
	for i in 0 ..< p.count {
		rax.insert(t, part_element_name(p, p.order[i]), rawptr(uintptr(1)))
	}
	return rax.memory(t) - before
}

names_excess :: proc(s: Vset) -> int {
	real := rax.memory(s.names) - size_of(rax.Rax)
	allowed := 0
	parts := make([dynamic]^Part_Head, context.temp_allocator)
	set_parts(s, &parts)
	for p in parts {
		for i in 0 ..< p.count {
			allowed += NAME_INDEX_BYTES + int(p.elements[p.order[i]].len)
		}
	}
	if s.lab != nil && s.lab.owners != nil {
		idx := s.lab.owners
		real += idx.rax_bytes - int(idx.slot_len) * size_of(rax.Rax)
	}
	return max(real - allowed, 0)
}

set_parts :: proc(s: Vset, out: ^[dynamic]^Part_Head) {
	if s.lab == nil {
		return
	}
	for i in 0 ..< s.lab.sorted_len {
		append(out, &s.lab.sorted[i].head)
	}
	if idx := s.lab.owners; idx != nil {
		for i in 0 ..< idx.part_high {
			if p := idx.parts[i]; p != nil {
				append(out, p)
			}
		}
	}
}

sweep_name :: proc(r: ^Test_Rng, shape: int, i: int) -> string {
	switch shape {
	case 3:
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< test_below(r, 200) {
			strings.write_byte(&b, u8('a' + test_below(r, 26)))
		}
		return fmt.tprintf("%s%d", strings.to_string(b), i)
	case 1, 4:
		return fmt.tprintf("%d", i)
	}
	return fmt.tprintf("%s%d", strings.repeat("n", test_below(r, 6), context.temp_allocator), i)
}

@(test)
partition_charges_cover_the_real_footprint :: proc(t: ^testing.T) {
	old := limits_set(64, 16)
	defer limits_restore(old)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0)})
	defer lattice_destroy(&l.lattice)
	worst := min(int)
	worst_shape := ""
	most := 0.0
	index_worst := 0.0
	most_shape := ""
	checked := 0
	set_closest := max(int)
	excess_most := 0
	kinds: [Part_Kind]int
	modes: [Part_Mode]int
	for q in Quant {
		for m in ([]int{4, 8, 16, 32, 64}) {
			for dim in ([]int{3, 64}) {
				for shape in 0 ..< 6 {
					if shape == 5 && (m != 16 || dim != 64) {
						continue
					}
					r := Test_Rng{state = 0x51 + u64(m) * 3 + u64(dim) + u64(shape) * 1000 + u64(q) * 77}
					x := make([]f32, dim)
					defer delete(x)
					sa := owner_access(&l, 0, SHARED)
					oa := owner_access(&l, 1, 1)
					req := Add_Request{vector = x, quant = q, m = m}
					s, _ := create_at(&req, &sa)
					n := 2500 if shape == 5 else 40 + test_below(&r, 700)
					for i in 0 ..< n {
						random_vector(&r, x)
						if shape == 2 && i % 3 == 0 {
							for k in 0 ..< dim {
								x[k] = 0.5
							}
						}
						a := &sa if i % 2 == 0 else &oa
						attr := fmt.tprintf(`{{"a":%d,"pad":"%s"}}`, i, strings.repeat("p", test_below(&r, 40), context.temp_allocator)) if test_below(&r, 3) == 0 else ""
						rq := Add_Request{name = bytes_of(sweep_name(&r, shape, i)), vector = x, quant = q, m = m, attr = bytes_of(attr), set_attr = attr != ""}
						add_at(s, a, &rq, &sc)
						if shape == 1 && test_below(&r, 3) == 0 {
							remove_at(s, a, bytes_of(fmt.tprintf("%d", test_below(&r, i + 1))), &sc)
						}
						free_all(context.temp_allocator)
					}
					if shape == 4 {
						for i in 0 ..< n {
							if i % 10 != 0 {
								remove_at(s, &sa if i % 2 == 0 else &oa, bytes_of(fmt.tprintf("%d", i)), &sc)
							}
							free_all(context.temp_allocator)
						}
					}
					parts := make([dynamic]^Part_Head, context.temp_allocator)
					set_parts(s, &parts)
					for p in parts {
						real := part_footprint(s, p)
						charge := part_content_bytes(s, p)
						gap := real - charge
						names_allow := 0
						for i in 0 ..< p.count {
							names_allow += NAME_INDEX_BYTES + int(p.elements[p.order[i]].len)
						}
						tree := own_names_bytes(p)
						index_worst = max(index_worst, f64(tree) / f64(max(names_allow, 1)))
						if gap > worst {
							worst = gap
							worst_shape = fmt.aprintf("%v m %d dim %d shape %d %v %v count %d", q, m, dim, shape, p.kind, p.mode, p.count)
						}
						if ratio := f64(charge - names_allow) / f64(real); p.count >= 100 && ratio > most {
							most = ratio
							delete(most_shape)
							most_shape = fmt.aprintf("%v m %d dim %d shape %d %v %v count %d cap %d", q, m, dim, shape, p.kind, p.mode, p.count, p.arena.cap)
						}
						testing.expectf(t, gap <= 0, "%v m %d dim %d shape %d %v %v count %d cap %d: footprint %d above the charge %d", q, m, dim, shape, p.kind, p.mode, p.count, p.arena.cap, real, charge)
						check_partition(t, s, p)
						kinds[p.kind] += 1
						modes[p.mode] += 1
						checked += 1
					}
					excess := names_excess(s)
					whole := charges_total(s) - memory_usage(s)
					testing.expectf(t, whole + excess >= 0, "%v m %d dim %d shape %d: the set holds %d bytes, %d of them in name trees beyond their allowance, and its parts are charged %d", q, m, dim, shape, memory_usage(s), excess, charges_total(s))
					testing.expectf(t, whole >= 0 || shape == 4, "%v m %d dim %d shape %d: a set whose names were not thinned holds %d bytes and its parts are charged %d", q, m, dim, shape, memory_usage(s), charges_total(s))
					set_closest = min(set_closest, whole)
					excess_most = max(excess_most, excess)
					destroy(s)
					free_all(context.temp_allocator)
				}
			}
		}
	}
	testing.expect(t, kinds[.Compact] > 0 && kinds[.Block] > 0 && modes[.Graph] > 0 && modes[.Flat] > 0)
	when .Address not_in ODIN_SANITIZER_FLAGS {
		testing.expectf(t, most < 1.3, "a charge without its name allowance exceeds its footprint by a factor of %.3f", most)
	}
	log.infof("charges: %d partitions; the footprint stays at least %d bytes below the charge (closest: %s); without the name allowance the largest charge of a partition with at least 100 elements is %.3f of its footprint (%s); a name tree of one partition's names alone takes up to %.3f of the name allowance; the sum of a set's charges less what the set holds is at least %d bytes, and the name trees of a set thinned by removals run up to %d bytes over their allowance", checked, -worst, worst_shape, most, most_shape, index_worst, set_closest, excess_most)
	delete(most_shape)
	delete(worst_shape)
}

Selection_Shape :: enum {
	Shared,
	Owned,
	Core,
}

selection_slot :: proc(s: Vset, a: ^Access, name: []u8) -> u32 {
	one_own, one_other: Ref
	own, _ := writer_copies(s, a, name, &one_own, &one_other)
	return own[exact_copy(a, s, own)].slot
}

@(test)
level_selection_stays_inside_the_charge :: proc(t: ^testing.T) {
	old := limits_set(64, 16)
	defer limits_restore(old)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0)})
	defer lattice_destroy(&l.lattice)
	x := make([]f32, 3)
	defer delete(x)
	n :: 120
	for m in ([]int{4, 16, 64}) {
		for shape in Selection_Shape {
			r := Test_Rng{state = 0x99 + u64(m) + 1000 * u64(shape)}
			a := owner_access(&l, 0 if shape == .Core else 1, 7 if shape == .Owned else SHARED)
			req := Add_Request{vector = x, quant = .Q8, m = m}
			s: Vset
			if shape == .Core {
				s = new_set(t, 3, .Q8, m)
			} else {
				s, _ = create_at(&req, &a)
			}
			for i in 0 ..< n {
				random_vector(&r, x)
				if shape == .Core {
					add_values(t, s, fmt.tprintf("e%d", i), x, .Q8, "", false, &sc, m)
				} else {
					rq := Add_Request{name = bytes_of(fmt.tprintf("e%d", i)), vector = x, quant = .Q8, m = m}
					_, f := add_at(s, &a, &rq, &sc)
					testing.expect_value(t, f.err, Error.None)
				}
				free_all(context.temp_allocator)
			}
			testing.expect_value(t, s.lab == nil, shape == .Core)
			p := &s.core.head if s.lab == nil else part_at_scope(s, a.label, a.owner)
			g := part_graphed(p)
			if g == nil {
				testing.expectf(t, false, "m %d %v: the partition holds no graph", m, shape)
				destroy(s)
				continue
			}
			writes := 0
			packed := 0
			closest := max(int)
			high_water := 0
			for target in ([]int{1, 2, 3, 0} if m == 16 else []int{1, 2, 0, 1}) {
				for i in 0 ..< n {
					name := bytes_of(fmt.tprintf("e%d", i))
					for slot_levels(p, selection_slot(s, &a, name)) != target {
						random_vector(&r, x)
						rq := Add_Request{name = name, vector = x, quant = .Q8, m = m}
						before := g.upper_len
						_, f := add_at(s, &a, &rq, &sc)
						testing.expect_value(t, f.err, Error.None)
						writes += 1
						if g.upper_len < before {
							packed += 1
						}
						high_water = max(high_water, g.upper_cap)
						real := part_footprint(s, p)
						charge := part_content_bytes(s, p)
						closest = min(closest, charge - real)
						live := hnsw.upper_lists(g) * (g.m + 1)
						if real > charge || g.upper_len > hnsw.upper_room(g, live) || g.upper_cap > hnsw.upper_bound(g, live) {
							testing.expectf(t, false, "m %d %v after %d writes: footprint %d, charge %d, pool %d of %d words for %d live words", m, shape, writes, real, charge, g.upper_len, g.upper_cap, live)
							destroy(s)
							return
						}
					}
					free_all(context.temp_allocator)
				}
				testing.expectf(t, memory_usage(s) <= charges_total(s), "m %d %v with every element at level %d: the set holds %d and is charged %d", m, shape, target, memory_usage(s), charges_total(s))
				if shape != .Core {
					testing.expect(t, check_partition(t, s, p))
				}
			}
			testing.expectf(t, packed > 0, "m %d %v: %d writes that select levels never packed the pool", m, shape, writes)
			if shape != .Core {
				before := scope_charges_of(s)
				ctx: Save_Context
				saved: [dynamic]Saved_Part
				save_parts(s, &ctx, &saved)
				save_context_destroy(&ctx)
				loaded, err := load_parts(t, saved[:])
				saved_destroy(&saved)
				testing.expect_value(t, err, Decode_Error.None)
				if loaded != nil {
					after := scope_charges_of(loaded)
					for k, v in before {
						testing.expectf(t, after[k] == v, "m %d %v: charged %d running and %d after a reload", m, shape, v, after[k])
					}
					lp := part_at_scope(loaded, a.label, a.owner)
					testing.expect(t, lp != nil && part_footprint(loaded, lp) <= part_content_bytes(loaded, lp))
					destroy(loaded)
				}
			}
			log.infof("level selection m %d %v: %d writes, the pool was packed %d times and never held more than %d words; the footprint stayed at least %d bytes below the charge", m, shape, writes, packed, high_water, closest)
			destroy(s)
			free_all(context.temp_allocator)
		}
	}
}

@(test)
small_sets_are_charged_their_own_header :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0)})
	defer lattice_destroy(&l.lattice)
	held := 0
	charged := 0
	closest := max(int)
	sets := 0
	r := Test_Rng{state = 0x5E7}
	for q in Quant {
		for dim in ([]int{3, 64}) {
			x := make([]f32, dim)
			defer delete(x)
			for owner in ([]Owner{SHARED, 5}) {
				for plain in ([]bool{false, true}) {
					if plain && owner != SHARED {
						continue
					}
					for round in 0 ..< 250 {
						a := owner_access(&l, 0 if plain else 1, owner)
						req := Add_Request{vector = x, quant = q, m = 16}
						s: Vset
						if plain {
							s = new_set(t, dim, q)
						} else {
							s, _ = create_at(&req, &a)
						}
						count := 1 if round % 5 != 0 else 2 + test_below(&r, 6)
						for i in 0 ..< count {
							random_vector(&r, x)
							name := fmt.tprintf("%s%d", strings.repeat("n", test_below(&r, 1 + round % 90), context.temp_allocator), i)
							attr := fmt.tprintf(`{{"a":%d}}`, i) if round % 7 == 0 else ""
							if plain && i == 0 {
								add_values(t, s, name, x, q, attr, attr != "", &sc)
								continue
							}
							rq := Add_Request{name = bytes_of(name), vector = x, quant = q, m = 16, attr = bytes_of(attr), set_attr = attr != ""}
							_, f := add_at(s, &a, &rq, &sc)
							testing.expect_value(t, f.err, Error.None)
						}
						testing.expect_value(t, s.lab == nil, plain)
						real := memory_usage(s)
						charge := charges_total(s)
						testing.expectf(t, real <= charge, "%v dim %d owner %d plain %v with %d elements: the set holds %d and is charged %d", q, dim, owner, plain, count, real, charge)
						closest = min(closest, charge - real)
						held += real
						charged += charge
						sets += 1
						destroy(s)
					}
					free_all(context.temp_allocator)
				}
			}
		}
	}
	testing.expect(t, sets == 4500 && held <= charged)
	log.infof("small sets: %d sets of one to seven elements hold %d bytes and are charged %d; the closest set stays %d bytes below its charge", sets, held, charged, closest)
}

@(test)
a_set_with_many_users_is_covered_by_their_charges :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0)})
	defer lattice_destroy(&l.lattice)
	x := make([]f32, 3)
	defer delete(x)
	r := Test_Rng{state = 0x77}
	sa := owner_access(&l, 0, SHARED)
	req := Add_Request{vector = x, quant = .Q8, m = 16}
	s, _ := create_at(&req, &sa)
	defer destroy(s)
	for i in 0 ..< 3000 {
		random_vector(&r, x)
		oa := owner_access(&l, i % 2, Owner(1 + i))
		rq := Add_Request{name = bytes_of("e"), vector = x, quant = .Q8, m = 16}
		_, f := add_at(s, &oa, &rq, &sc)
		testing.expect_value(t, f.err, Error.None)
		if i % 250 == 249 {
			testing.expectf(t, memory_usage(s) <= charges_total(s), "%d users with one element each hold %d and are charged %d", i + 1, memory_usage(s), charges_total(s))
		}
		free_all(context.temp_allocator)
	}
	log.infof("many users: 3000 users with one element each in one set hold %d bytes and are charged %d", memory_usage(s), charges_total(s))
	idx := s.lab.owners
	last := owner_scope(s, Owner(3000)).parts[0]
	testing.expect_value(t, last.id, OWNER_PART_BASE + 2999)
	for i in 0 ..< 2999 {
		oa := owner_access(&l, i % 2, Owner(1 + i))
		ch, _ := remove_at(s, &oa, bytes_of("e"), &sc)
		testing.expect(t, ch.found)
		live := idx.part_high - idx.free_len
		testing.expectf(t, idx.part_cap <= max(SET_TABLE_MIN, 2 * live) && idx.free_cap <= max(SET_TABLE_MIN, 2 * live), "%d users left: tables of %d and %d entries for %d partitions", i + 1, idx.part_cap, idx.free_cap, live)
		testing.expectf(t, memory_usage(s) <= charges_total(s), "%d users left: the set holds %d and is charged %d", i + 1, memory_usage(s), charges_total(s))
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, idx.part_cap, u32(SET_TABLE_MIN))
	testing.expect(t, last.id < OWNER_PART_BASE + SET_TABLE_MIN)
	survivor := owner_access(&l, 1, Owner(3000))
	v, _ := view_open(s, &survivor, &sc)
	kept, found := view_find(&v, bytes_of("e"))
	testing.expect(t, found && kept.part == last.id)
	check_set(t, s)
	log.infof("many users: after 2999 of them left, the set holds %d bytes and is charged %d", memory_usage(s), charges_total(s))
}

Reader_Snapshot :: struct {
	charges: map[Scope]int,
	text:    [dynamic]string,
}

survivor_read :: proc(s: Vset, l: ^Owner_Lattice, sc: ^Scratch, seed: u64, out: ^Reader_Snapshot) {
	out.charges = scope_charges_of(s)
	out.text = make([dynamic]string, context.temp_allocator)
	readers := [?]Access{owner_access(l, 0, 7), owner_access(l, 1, 7), owner_access(l, 1, SHARED), owner_access(l, 0, 9)}
	x := make([]f32, 3, context.temp_allocator)
	for &a in readers {
		v, err := view_open(s, &a, sc)
		if err != .None {
			append(&out.text, fmt.tprintf("open %v", err))
			continue
		}
		refs := make([dynamic]Ref, context.temp_allocator)
		view_range(&v, {kind = .Min}, {kind = .Max}, -1, &refs)
		b := strings.builder_make(context.temp_allocator)
		for r in refs {
			fmt.sbprintf(&b, "%s ", string(ref_name(s, r)))
		}
		append(&out.text, strings.to_string(b))
		r := Test_Rng{state = seed}
		hits := make([dynamic]Hit, context.temp_allocator)
		for _ in 0 ..< 12 {
			random_vector(&r, x)
			req := Search_Request{kind = .Vector, vector = x, count = 8}
			clear(&hits)
			view_search(&v, &req, sc, &hits)
			append(&out.text, hits_text(s, hits[:]))
		}
		for name in ([]string{"s1", "s7", "s15", "s8", "g4"}) {
			links: Links
			if view_links(&v, bytes_of(name), sc, &links) {
				lb := strings.builder_make(context.temp_allocator)
				for lr in links.refs {
					fmt.sbprintf(&lb, "%s ", string(ref_name(s, lr)))
				}
				fmt.sbprintf(&lb, "%v", links.ends[:])
				append(&out.text, strings.to_string(lb))
			} else {
				append(&out.text, fmt.tprintf("no links for %s", name))
			}
			links_destroy(&links)
		}
	}
}

@(test)
users_leaving_give_back_their_table_entries :: proc(t: ^testing.T) {
	old := limits_set(8, 2)
	defer limits_restore(old)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0)})
	defer lattice_destroy(&l.lattice)
	x := make([]f32, 3)
	defer delete(x)
	worlds: [2]Vset
	for w in 0 ..< 2 {
		r := Test_Rng{state = 0x7AB1E}
		ga := owner_access(&l, 0, SHARED)
		req := Add_Request{vector = x, quant = .Q8, m = 8}
		s, _ := create_at(&req, &ga)
		worlds[w] = s
		transients := 0
		if w == 1 {
			for u in 0 ..< 300 {
				for k in 0 ..< 1 + u % 3 {
					random_vector(&r, x)
					oa := owner_access(&l, k % 2, Owner(100 + u))
					rq := Add_Request{name = bytes_of(fmt.tprintf("t%d", k)), vector = x, quant = .Q8, m = 8}
					add_at(s, &oa, &rq, &sc)
				}
				transients += 1
				free_all(context.temp_allocator)
			}
		}
		r = Test_Rng{state = 0x5E1F}
		for i in 0 ..< 40 {
			random_vector(&r, x)
			for k := 1; k >= 0; k -= 1 {
				if k == 1 && i >= 20 {
					continue
				}
				oa := owner_access(&l, k, 7)
				rq := Add_Request{name = bytes_of(fmt.tprintf("s%d", i)), vector = x, quant = .Q8, m = 8}
				_, f := add_at(s, &oa, &rq, &sc)
				testing.expect_value(t, f.err, Error.None)
			}
			if i % 4 == 0 {
				random_vector(&r, x)
				oa := owner_access(&l, 0, 9)
				rq := Add_Request{name = bytes_of(fmt.tprintf("s%d", i)), vector = x, quant = .Q8, m = 8}
				add_at(s, &oa, &rq, &sc)
				rq.name = bytes_of(fmt.tprintf("g%d", i))
				add_at(s, &ga, &rq, &sc)
			}
			free_all(context.temp_allocator)
		}
		if w == 1 {
			idx := s.lab.owners
			testing.expect(t, owner_scope(s, 7).parts[0].id >= OWNER_PART_BASE + 300)
			order := make([]int, 300)
			defer delete(order)
			for u in 0 ..< 300 {
				order[u] = u
			}
			r = Test_Rng{state = 0xDE9A27}
			for u := 299; u > 0; u -= 1 {
				j := test_below(&r, u + 1)
				order[u], order[j] = order[j], order[u]
			}
			for u, step in order {
				if step % 3 == 0 {
					remove_owner(s, Owner(100 + u))
				} else {
					for k in 0 ..< 1 + u % 3 {
						oa := owner_access(&l, k % 2, Owner(100 + u))
						remove_at(s, &oa, bytes_of(fmt.tprintf("t%d", k)), &sc)
					}
				}
				live := idx.part_high - idx.free_len
				testing.expectf(t, idx.part_cap <= max(SET_TABLE_MIN, 2 * live) && idx.free_cap <= max(SET_TABLE_MIN, 2 * live), "after %d users left: tables of %d and %d entries for %d partitions", step + 1, idx.part_cap, idx.free_cap, live)
				testing.expectf(t, memory_usage(s) <= charges_total(s), "after %d users left: the set holds %d and is charged %d", step + 1, memory_usage(s), charges_total(s))
				if step % 25 == 0 && !check_set(t, s) {
					return
				}
				free_all(context.temp_allocator)
			}
			for p in owner_scope(s, 7).parts[:owner_scope(s, 7).part_len] {
				testing.expectf(t, p.id < OWNER_PART_BASE + 6, "a survivor partition kept id %d after the others left", p.id - OWNER_PART_BASE)
			}
			live := idx.part_high - idx.free_len
			testing.expectf(t, live == 3 && idx.part_high <= idx.part_cap && idx.part_cap <= 2 * live, "three partitions left in a table of %d entries with %d ids in use", idx.part_cap, idx.part_high)
			check_set(t, s)
		}
	}
	defer destroy(worlds[0])
	defer destroy(worlds[1])
	for round in 0 ..< 3 {
		snaps: [2]Reader_Snapshot
		for w in 0 ..< 2 {
			survivor_read(worlds[w], &l, &sc, 0xC0FFEE + u64(round), &snaps[w])
		}
		testing.expect_value(t, len(snaps[0].text), len(snaps[1].text))
		linked := 0
		for line in snaps[1].text {
			if strings.has_suffix(line, "]") && !strings.has_prefix(line, "no links") {
				linked += 1
			}
		}
		testing.expectf(t, linked >= 8, "only %d link lists were compared", linked)
		for i in 0 ..< min(len(snaps[0].text), len(snaps[1].text)) {
			testing.expectf(t, snaps[0].text[i] == snaps[1].text[i], "round %d reply %d: %q alone and %q after other users left", round, i, snaps[0].text[i], snaps[1].text[i])
		}
		for k, v in snaps[0].charges {
			testing.expectf(t, snaps[1].charges[k] == v, "round %d scope %d/%d: charged %d alone and %d after other users left", round, k.label, k.owner, v, snaps[1].charges[k])
		}
		r := Test_Rng{state = 0xAB + u64(round)}
		for w in 0 ..< 2 {
			r = Test_Rng{state = 0xAB + u64(round)}
			for i in 0 ..< 30 {
				oa := owner_access(&l, test_below(&r, 2), 7)
				name := bytes_of(fmt.tprintf("s%d", test_below(&r, 50)))
				random_vector(&r, x)
				if test_below(&r, 3) == 0 {
					remove_at(worlds[w], &oa, name, &sc)
				} else {
					rq := Add_Request{name = name, vector = x, quant = .Q8, m = 8}
					add_at(worlds[w], &oa, &rq, &sc)
				}
				_ = i
			}
			check_set(t, worlds[w])
		}
		free_all(context.temp_allocator)
	}
	ctx: Save_Context
	saved: [dynamic]Saved_Part
	save_parts(worlds[1], &ctx, &saved)
	save_context_destroy(&ctx)
	loaded, err := load_parts(t, saved[:])
	saved_destroy(&saved)
	testing.expect_value(t, err, Decode_Error.None)
	if loaded != nil {
		before := scope_charges_of(worlds[1])
		after := scope_charges_of(loaded)
		for k, v in before {
			testing.expectf(t, after[k] == v, "scope %d/%d: charged %d running and %d after a reload", k.label, k.owner, v, after[k])
		}
		testing.expect(t, memory_usage(loaded) <= charges_total(loaded))
		check_set(t, loaded)
		destroy(loaded)
	}
	free_all(context.temp_allocator)
}

Charge_Step :: struct {
	label: int,
	owner: Owner,
	kind:  int,
	name:  string,
}

charge_world_write :: proc(h: ^History_Run, st: Charge_Step, x: []f32) {
	attr := ""
	if len(st.name) % 3 == 0 {
		attr = fmt.tprintf(`{{"n":"%s"}}`, st.name)
	}
	history_write(h, st.label, st.owner, st.kind, st.name, x, attr)
}

scope_charges_of :: proc(s: Vset) -> map[Scope]int {
	out := make(map[Scope]int, context.temp_allocator)
	if s == nil {
		return out
	}
	parts := make([dynamic]^Part_Head, context.temp_allocator)
	set_parts(s, &parts)
	for p in parts {
		out[Scope{label = p.label, owner = p.owner}] = scope_charge(s, p.label, p.owner)
	}
	return out
}

@(test)
scope_charges_ignore_other_scopes_and_survive_a_reload :: proc(t: ^testing.T) {
	old := limits_set(8, 2)
	defer limits_restore(old)
	labels := []lbl.Label{compartments_label(0), compartments_label(0, 0), compartments_label(1, 0)}
	quiet, busy: History_Run
	history_init(&quiet, labels)
	defer history_destroy(&quiet)
	history_init(&busy, labels)
	defer history_destroy(&busy)
	r := Test_Rng{state = 0xC4A26E}
	x := make([]f32, 4)
	defer delete(x)
	hx := make([]f32, 4)
	defer delete(hx)
	watched := [?]Scope{{label = 0, owner = SHARED}, {label = 0, owner = 1}, {label = 1, owner = 1}}
	others := [?]struct {
		label: int,
		owner: Owner,
	}{{2, SHARED}, {1, SHARED}, {0, 2}, {1, 3}, {2, 1}}
	compared := 0
	reloads := 0
	for step in 0 ..< 400 {
		for _ in 0 ..< test_below(&r, 4) {
			o := others[test_below(&r, len(others))]
			random_vector(&r, hx)
			roll := test_below(&r, 30)
			switch {
			case roll == 0:
				history_write(&busy, o.label, Owner(2 + test_below(&r, 2)), 3, "", hx, "")
			case roll == 1:
				history_write(&busy, o.label, o.owner, 4, "", hx, "")
			case roll < 8:
				history_write(&busy, o.label, o.owner, 1, fmt.tprintf("o%d", test_below(&r, 60)), hx, "")
			case:
				history_write(&busy, o.label, o.owner, 0, fmt.tprintf("o%d", test_below(&r, 60)), hx, fmt.tprintf(`{{"p":"%s"}}`, strings.repeat("q", test_below(&r, 50), context.temp_allocator)))
			}
		}
		w := watched[test_below(&r, len(watched))]
		kind := 0 if test_below(&r, 10) < 7 else 1 + test_below(&r, 2)
		st := Charge_Step{label = int(w.label), owner = w.owner, kind = kind, name = fmt.tprintf("w%d", test_below(&r, 50))}
		random_vector(&r, x)
		charge_world_write(&quiet, st, x)
		charge_world_write(&busy, st, x)
		a, b := scope_charges_of(quiet.s), scope_charges_of(busy.s)
		for ws in watched {
			ql := quiet.l.ids[ws.label]
			bl := busy.l.ids[ws.label]
			qc := a[Scope{label = ql, owner = ws.owner}] if quiet.s != nil else 0
			bc := b[Scope{label = bl, owner = ws.owner}] if busy.s != nil else 0
			testing.expectf(t, qc == bc, "step %d scope %d/%d: charged %d alone and %d beside other scopes", step, ws.label, ws.owner, qc, bc)
			compared += 1
		}
		if step % 50 == 49 && busy.s != nil {
			before := scope_charges_of(busy.s)
			ctx: Save_Context
			saved: [dynamic]Saved_Part
			save_parts(busy.s, &ctx, &saved)
			save_context_destroy(&ctx)
			loaded, err := load_parts(t, saved[:])
			saved_destroy(&saved)
			testing.expect_value(t, err, Decode_Error.None)
			if loaded != nil {
				after := scope_charges_of(loaded)
				testing.expect_value(t, len(after), len(before))
				for k, v in before {
					testing.expectf(t, after[k] == v, "step %d scope %d/%d: charged %d running and %d after a reload", step, k.label, k.owner, v, after[k])
				}
				check_set(t, loaded)
				destroy(loaded)
				reloads += 1
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expect(t, compared == 400 * len(watched) && reloads > 3)
	log.infof("scope charges: %d compared between a set alone and one with other scopes, %d reloads", compared, reloads)
}

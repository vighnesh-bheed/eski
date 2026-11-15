package vsettype

import "base:runtime"
import "core:fmt"
import "core:testing"
import lbl "../label"
import "../vmath"

Query_Copy :: struct {
	buf: []u8,
	q:   vmath.Query,
}

query_copy :: proc(q: vmath.Query, arena: ^vmath.Arena) -> Query_Copy {
	n := max(vmath.query_bytes(arena), 8)
	buf, _ := runtime.mem_alloc(n, vmath.ARENA_ALIGN)
	copy(buf, q.data[:n])
	out := q
	out.data = raw_data(buf)
	return Query_Copy{buf = buf, q = out}
}

query_copy_free :: proc(c: ^Query_Copy) {
	runtime.mem_free_with_size(raw_data(c.buf), len(c.buf))
	c^ = {}
}

hits_equal :: proc(t: ^testing.T, a, b: []Hit, what: string) -> bool {
	if len(a) != len(b) {
		testing.expectf(t, false, "%s: %d hits inline and %d prepared", what, len(a), len(b))
		return false
	}
	for x, i in a {
		y := b[i]
		if x.slot != y.slot || x.part != y.part || x.seq != y.seq || transmute(u64)x.score != transmute(u64)y.score {
			testing.expectf(t, false, "%s: hit %d differs: %v and %v", what, i, x, y)
			return false
		}
	}
	return true
}

random_search :: proc(r: ^Test_Rng, dim: int, names: int) -> Search_Request {
	x := make([]f32, dim, context.temp_allocator)
	random_vector(r, x)
	req := Search_Request{kind = .Vector, vector = x, count = 1 + test_below(r, 25), ef = test_below(r, 3) * 40, truth = test_below(r, 3) == 0}
	if test_below(r, 3) == 0 {
		req.kind = .Element
		req.element = bytes_of(fmt.tprintf("k%d", test_below(r, names)))
	}
	if test_below(r, 3) == 0 {
		req.use_filter = true
		req.filter = ".a >= 2" if test_below(r, 2) == 0 else ".a == 1 or .a == 4"
		req.filter_ef = test_below(r, 3) * 20
	}
	if test_below(r, 4) == 0 {
		req.use_epsilon = true
		req.epsilon = 0.4
	}
	return req
}

@(test)
prepared_search_equals_the_inline_search_on_plain_sets :: proc(t: ^testing.T) {
	r := Test_Rng{state = 0xB3}
	inline_sc, coord_sc, worker_sc: Scratch
	scratch_init(&inline_sc)
	scratch_init(&coord_sc)
	scratch_init(&worker_sc)
	defer scratch_destroy(&inline_sc)
	defer scratch_destroy(&coord_sc)
	defer scratch_destroy(&worker_sc)
	a, b: [dynamic]Hit
	defer delete(a)
	defer delete(b)
	compared := 0
	for round in 0 ..< 12 {
		quant := Quant(round % 3)
		dim := 3 + test_below(&r, 6)
		m := 4 + 4 * test_below(&r, 3)
		s, err := create(Params{quant = quant, dim = dim, m = m, seed = u64(round + 1)})
		testing.expect_value(t, err, Error.None)
		x := make([]f32, dim)
		names := 40 + test_below(&r, 200)
		for i in 0 ..< names {
			random_vector(&r, x)
			req := Add_Request{name = bytes_of(fmt.tprintf("k%d", i)), vector = x, quant = quant, m = m, set_attr = true, attr = bytes_of(fmt.tprintf(`{{"a":%d}}`, i % 5))}
			_, added := add(s, &req, &inline_sc)
			testing.expect_value(t, added.err, Error.None)
			if i % 9 == 0 && i > 0 {
				remove(s, bytes_of(fmt.tprintf("k%d", i - 3)), &inline_sc)
			}
		}
		delete(x)
		testing.expect(t, card(s) > 30)
		for _ in 0 ..< 30 {
			req := random_search(&r, dim, names)
			clear(&a)
			clear(&b)
			fa := search(s, &req, &inline_sc, &a)
			q, fb := search_prepare(s, &req, &coord_sc)
			testing.expect_value(t, fb.err, fa.err)
			if fa.err != .None {
				continue
			}
			copied := query_copy(q, &s.arena)
			job := req
			job.vector = nil
			job.element = nil
			fc := search_query(s, copied.q, &job, &worker_sc, &b)
			query_copy_free(&copied)
			testing.expect_value(t, fc.err, Error.None)
			hits_equal(t, a[:], b[:], "plain search")
			testing.expect(t, len(b) <= min(req.count if req.count > 0 else COUNT_DEFAULT, card(s)))
			compared += 1
		}
		destroy(s)
		free_all(context.temp_allocator)
	}
	testing.expect(t, compared > 200)
}

@(test)
detached_views_search_like_the_open_view :: proc(t: ^testing.T) {
	old := limits_set(6, 2)
	defer limits_restore(old)
	compared, proxied, shadowed := 0, 0, 0
	for seed in ([]u64{0xD1, 0xD2, 0xD3}) {
		f := new(Owner_Fuzz)
		f.t = t
		f.r = Test_Rng{state = seed}
		scheme_init(&f.scheme, &f.r, 3, 2, 6, 2)
		for i in 0 ..< len(f.scheme.ids) {
			row: [OWNERS_TESTED]u64
			for k in 0 ..< OWNERS_TESTED {
				row[k] = stream_seed(f.scheme.ids[i]) ~ (u64(k + 9) * 0x2545F4914F6CDD1D)
			}
			append(&f.streams, row)
		}
		scratch_init(&f.sc)
		f.quant = Quant(seed % 3)
		f.dim = 3 + int(seed % 4)
		worker_sc: Scratch
		scratch_init(&worker_sc)
		a, b: [dynamic]Hit
		for step in 0 ..< 900 {
			owner_fuzz_step(f)
			if f.s == nil || step % 3 != 0 {
				free_all(context.temp_allocator)
				continue
			}
			acc := owner_fuzz_access(f, test_below(&f.r, 9) == 0)
			v, err := view_open(f.s, &acc, &f.sc)
			if err != .None || !view_exists(&v) {
				free_all(context.temp_allocator)
				continue
			}
			req := random_search(&f.r, f.reduce if f.reduce > 0 else f.dim, 40)
			clear(&a)
			clear(&b)
			fa := view_search(&v, &req, &f.sc, &a)
			q, fb := view_search_prepare(&v, &req, &f.sc)
			testing.expect_value(t, fb.err, fa.err)
			if fa.err == .None {
				copied := query_copy(q, &v.parts[0].part.arena)
				bound := min(req.count if req.count > 0 else COUNT_DEFAULT, view_elements(&v))
				sized := view_detach_bytes(&v, &f.sc)
				d, ok := view_detach(&v, &f.sc, context.allocator)
				testing.expect(t, ok && d.bytes == sized)
				if len(d.proxies) > 0 {
					proxied += 1
				}
				if len(d.shadows) > 0 {
					shadowed += 1
				}
				other := owner_fuzz_access(f)
				view_open(f.s, &other, &f.sc)
				job := req
				job.vector = nil
				job.element = nil
				fc := view_search_query(&d.view, copied.q, &job, &worker_sc, &b)
				testing.expect_value(t, fc.err, Error.None)
				hits_equal(t, a[:], b[:], "view search")
				testing.expect(t, len(b) <= bound)
				testing.expect(t, d.view.access.visibility == nil && d.view.access.table == nil && d.view.scope == nil)
				view_detached_destroy(&d)
				query_copy_free(&copied)
				compared += 1
			}
			free_all(context.temp_allocator)
		}
		if f.s != nil {
			destroy(f.s)
		}
		delete(a)
		delete(b)
		scratch_destroy(&worker_sc)
		scratch_destroy(&f.sc)
		delete(f.streams)
		delete(f.hits)
		delete(f.refs)
		delete(f.labels)
		links_destroy(&f.links)
		scheme_destroy(&f.scheme)
		free(f)
	}
	testing.expect(t, compared > 300)
	testing.expectf(t, proxied > 10 && shadowed > 10, "views with proxies %d, with shadows %d", proxied, shadowed)
}

cache_same :: proc(t: ^testing.T, x, y: ^Distance_Cache) -> bool {
	if x.count != y.count {
		testing.expectf(t, false, "caches hold %d and %d distances", x.count, y.count)
		return false
	}
	for k, i in x.keys {
		if k >= CACHE_DEAD {
			continue
		}
		v, ok := cache_get(y, k)
		if !ok || transmute(u32)v != transmute(u32)x.values[i] {
			testing.expectf(t, false, "slot %d has no equal distance in the split plan", k)
			return false
		}
	}
	return true
}

@(test)
split_cas_plan_records_what_cas_prepare_records :: proc(t: ^testing.T) {
	r := Test_Rng{state = 0xCA5}
	sc, worker_sc: Scratch
	scratch_init(&sc)
	scratch_init(&worker_sc)
	defer scratch_destroy(&sc)
	defer scratch_destroy(&worker_sc)
	for round in 0 ..< 6 {
		quant := Quant(round % 3)
		s, _ := create(Params{quant = quant, dim = 6, m = 8, seed = u64(round + 3)})
		x := make([]f32, 6)
		for i in 0 ..< 120 {
			random_vector(&r, x)
			req := Add_Request{name = bytes_of(fmt.tprintf("k%d", i)), vector = x, quant = quant, m = 8}
			_, added := add(s, &req, &sc)
			testing.expect_value(t, added.err, Error.None)
		}
		random_vector(&r, x)
		req := Add_Request{name = bytes_of("new"), vector = x, quant = quant, m = 8, ef = 50}
		one, two: Cas_Plan
		testing.expect_value(t, cas_prepare(s, &req, &one, &sc).err, Error.None)
		target, failed := cas_plan_begin(s, &req, lbl.BOTTOM_ID, SHARED, false, &two, &sc, context.allocator)
		testing.expect_value(t, failed.err, Error.None)
		testing.expect(t, target == &s.core)
		cas_plan_record(&two, target, &worker_sc)
		testing.expect(t, one.uid == two.uid && one.version == two.version && one.part == two.part && one.set == two.set)
		testing.expect(t, cache_same(t, &one.cache, &two.cache) && one.cache.count > 0)
		for v, i in one.stored {
			testing.expect(t, transmute(u32)v == transmute(u32)two.stored[i])
		}
		bad := Add_Request{name = bytes_of("bad"), vector = x[:5], quant = quant, m = 8}
		three: Cas_Plan
		_, refused := cas_plan_begin(s, &bad, lbl.BOTTOM_ID, SHARED, false, &three, &sc, context.allocator)
		testing.expect_value(t, refused.err, Error.Dimension_Mismatch)
		testing.expect(t, !three.ready)
		cas_discard(&one)
		cas_discard(&two)
		delete(x)
		destroy(s)
		free_all(context.temp_allocator)
	}
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(1, 0)})
	defer lattice_destroy(&l.lattice)
	low := owner_access(&l, 0, SHARED)
	mid := owner_access(&l, 1, SHARED)
	s := new_labelled(t, &low, 4)
	x := make([]f32, 4)
	defer delete(x)
	for i in 0 ..< 200 {
		random_vector(&r, x)
		labelled_add(s, &mid if i % 2 == 0 else &low, fmt.tprintf("m%d", i), x, &sc)
	}
	testing.expect(t, card(s) == 200)
	random_vector(&r, x)
	req := Add_Request{name = bytes_of("fresh"), vector = x, quant = .Q8, ef = 40}
	one, two: Cas_Plan
	testing.expect_value(t, cas_prepare_at(s, &mid, &req, &one, &sc).err, Error.None)
	target, failed := cas_plan_begin(s, &req, mid.label, mid.owner, true, &two, &sc, context.allocator)
	testing.expect_value(t, failed.err, Error.None)
	cas_plan_record(&two, target, &worker_sc)
	testing.expect(t, one.part == two.part && one.label == two.label && one.owner == two.owner)
	testing.expect(t, cache_same(t, &one.cache, &two.cache))
	cas_discard(&one)
	cas_discard(&two)
	destroy(s)
	free_all(context.temp_allocator)
}

Write_Audit :: struct {
	tracked: Vset,
	before:  u64,
	hooked:  bool,
	early:   bool,
}

write_audit: Write_Audit

write_audit_hook :: proc(s: Vset) {
	if s == write_audit.tracked && !write_audit.hooked {
		write_audit.hooked = true
		if state_digest(s) != write_audit.before {
			write_audit.early = true
		}
	}
}

write_audit_begin :: proc(s: Vset) {
	write_audit = Write_Audit{tracked = s}
	if s != nil {
		write_audit.before = state_digest(s)
	}
}

write_audit_end :: proc(after: Vset) -> (ok: bool) {
	w := write_audit
	write_audit = {}
	if w.tracked == nil {
		return true
	}
	if w.early {
		return false
	}
	if after == w.tracked {
		return w.hooked || state_digest(after) == w.before
	}
	return w.hooked
}

audited_owner_run :: proc(t: ^testing.T, seed: u64, steps: int, owners: bool) -> (audited: int) {
	f := new(Owner_Fuzz)
	defer free(f)
	f.t = t
	f.r = Test_Rng{state = seed}
	if owners {
		scheme_init(&f.scheme, &f.r, 3, 2, 6, 2)
	} else {
		scheme_init(&f.scheme, &f.r, 3, 2, 7)
	}
	defer scheme_destroy(&f.scheme)
	for i in 0 ..< len(f.scheme.ids) {
		row: [OWNERS_TESTED]u64
		for k in 0 ..< OWNERS_TESTED {
			row[k] = stream_seed(f.scheme.ids[i]) ~ (u64(k + 9) * 0x2545F4914F6CDD1D)
		}
		append(&f.streams, row)
	}
	defer delete(f.streams)
	scratch_init(&f.sc)
	defer scratch_destroy(&f.sc)
	defer delete(f.hits)
	defer delete(f.refs)
	defer delete(f.labels)
	defer links_destroy(&f.links)
	f.quant = Quant(test_below(&f.r, 3))
	f.dim = 2 + test_below(&f.r, 8)
	if test_below(&f.r, 4) == 0 {
		f.reduce = f.dim + 3 + test_below(&f.r, 6)
	}
	for step in 0 ..< steps {
		write_audit_begin(f.s)
		if owners {
			owner_fuzz_step(f)
		} else {
			fuzz_step(&f.fuzz)
		}
		if !write_audit_end(f.s) {
			testing.expectf(t, false, "seed %x step %d changed a set without calling the write hook first", seed, step)
			break
		}
		audited += 1
		free_all(context.temp_allocator)
	}
	if f.s != nil {
		destroy(f.s)
	}
	return
}

@(test)
every_change_the_operation_generators_make_calls_the_write_hook_first :: proc(t: ^testing.T) {
	old := limits_set(6, 2)
	defer limits_restore(old)
	kept := write_hook
	write_hook = write_audit_hook
	defer write_hook = kept
	total := 0
	for seed in ([]u64{0xA1, 0xA2, 0xA3}) {
		total += audited_owner_run(t, seed, 700, false)
		total += audited_owner_run(t, seed, 700, true)
	}
	testing.expect_value(t, total, 6 * 700)
}

@(test)
the_write_audit_finds_a_change_that_skips_the_hook :: proc(t: ^testing.T) {
	kept := write_hook
	write_hook = write_audit_hook
	defer write_hook = kept
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	s, _ := create(Params{quant = .Q8, dim = 3, m = 4, seed = 2})
	defer destroy(s)
	x := []f32{0.1, 0.5, -0.2}
	y := []f32{0.4, -0.5, 0.3}
	req := Add_Request{name = bytes_of("a"), vector = x, quant = .Q8}
	add(s, &req, &sc)
	write_audit_begin(s)
	other := Add_Request{name = bytes_of("b"), vector = y, quant = .Q8}
	add(s, &other, &sc)
	testing.expect(t, write_audit_end(s))
	write_audit_begin(s)
	skipped := Add_Request{name = bytes_of("c"), vector = x, quant = .Q8}
	stored, _ := stored_vector(s, skipped.vector, &sc)
	apply_add(s, &skipped, stored, &sc, nil)
	testing.expect(t, !write_audit_end(s))
	write_audit_begin(s)
	set_attribute(s, bytes_of("c"), bytes_of(`{"z":1}`))
	testing.expect(t, write_audit_end(s))
	write_audit_begin(s)
	slot, _ := find(s, bytes_of("c"))
	attr, _ := make_attribute(s, bytes_of(`{"z":22}`))
	replace_attribute(s, &s.elements[slot], attr)
	testing.expect(t, !write_audit_end(s))
	write_audit_begin(s)
	stored, _ = stored_vector(s, y, &sc)
	late := Add_Request{name = bytes_of("d"), vector = y, quant = .Q8}
	apply_add(s, &late, stored, &sc, nil)
	add(s, &req, &sc)
	testing.expect(t, !write_audit_end(s))
}

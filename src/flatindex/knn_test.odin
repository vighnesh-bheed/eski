package flatindex

import "core:fmt"
import "core:mem"
import "core:testing"
import "../roaring"
import "../vmath"

Corpus :: struct {
	ix: Index,
	m:  Model,
}

corpus_build :: proc(t: ^testing.T, c: ^Corpus, spec: Spec, n: int, seed: u64, churn: bool, specials: bool) {
	testing.expect_value(t, init(&c.ix, spec, context.allocator), Error.None)
	model_init(&c.m, spec)
	r: vmath.Rng
	vmath.rng_seed(&r, seed)
	id: u32 = 1
	for i in 0 ..< n {
		blob: []u8
		switch {
		case i > 0 && i % 7 == 0:
			blob = c.m.blobs[c.m.ids[rand_below(&r, len(c.m.ids))]]
		case specials && i % 23 == 5 && spec.elem != .Int8 && spec.elem != .U8:
			blob = nan_blob(spec.elem, spec.dim, rand_below(&r, spec.dim))
		case specials && i % 29 == 11:
			blob = zero_blob(spec.elem, spec.dim)
		case:
			blob = random_blob(&r, spec.elem, spec.dim, i % 3 == 0)
		}
		owned := make([]u8, len(blob), context.temp_allocator)
		copy(owned, blob)
		_, err := add(&c.ix, id, owned)
		testing.expect_value(t, err, Error.None)
		model_put(&c.m, id, owned)
		id += u32(1 + rand_below(&r, 2))
	}
	if churn {
		for _ in 0 ..< n / 3 {
			victim := c.m.ids[rand_below(&r, len(c.m.ids))]
			testing.expect_value(t, remove(&c.ix, victim), Error.None)
			model_del(&c.m, victim)
		}
		for _ in 0 ..< n / 4 {
			blob := random_blob(&r, spec.elem, spec.dim, false)
			_, err := add(&c.ix, id, blob)
			testing.expect_value(t, err, Error.None)
			model_put(&c.m, id, blob)
			id += 1
		}
		for _ in 0 ..< n / 10 {
			victim := c.m.ids[rand_below(&r, len(c.m.ids))]
			blob := random_blob(&r, spec.elem, spec.dim, true)
			replaced, err := add(&c.ix, victim, blob)
			testing.expect(t, replaced && err == .None)
			model_put(&c.m, victim, blob)
		}
	}
}

corpus_destroy :: proc(c: ^Corpus) {
	destroy(&c.ix)
	model_destroy(&c.m)
}

check_queries :: proc(t: ^testing.T, c: ^Corpus, r: ^vmath.Rng, label: string, queries: int) -> int {
	spec := c.ix.spec
	checked := 0
	out := make([dynamic]Hit, context.temp_allocator)
	for qi in 0 ..< queries {
		qb: []u8
		switch qi {
		case 0:
			qb = c.m.blobs[c.m.ids[0]]
		case 1:
			qb = zero_blob(spec.elem, spec.dim)
		case:
			qb = random_blob(r, spec.elem, spec.dim, qi % 2 == 0)
		}
		qy: Query
		if !testing.expect_value(t, query_for(&qy, &c.ix, qb, context.temp_allocator), Error.None) {
			return checked
		}
		n := len(c.m.ids)
		for k in ([]int{1, 2, 5, 17, n - 1, n, n + 3}) {
			clear(&out)
			testing.expect_value(t, knn(&c.ix, &qy, k, &out), Error.None)
			want := oracle_knn(&c.m, &qy, k, nil, &c.ix)
			if !expect_hits(t, out[:], want, fmt.tprintf("%s query %d k %d", label, qi, k)) {
				return checked
			}
			checked += 1
		}
		for pct in ([]u64{1, 10, 50}) {
			sel := Select{salt = u64(qi) * 31 + pct, percent = pct}
			f := Oracle_Filter{accept = select_accept, ctx = &sel}
			clear(&out)
			testing.expect_value(t, knn(&c.ix, &qy, 10, &out, filter_accept(select_accept, &sel)), Error.None)
			want := oracle_knn(&c.m, &qy, 10, &f, &c.ix)
			if !expect_hits(t, out[:], want, fmt.tprintf("%s query %d accept %d%%", label, qi, pct)) {
				return checked
			}
			cands := make([dynamic]u32, context.temp_allocator)
			bm: roaring.Bitmap
			roaring.init(&bm, context.temp_allocator)
			allow := Oracle_Filter{use = true}
			allow.allow = make(map[u32]bool, 16, context.temp_allocator)
			top := c.m.ids[len(c.m.ids) - 1] + 40
			for id in u32(0) ..< top {
				if hash_id(id, sel.salt) % 100 < pct {
					append(&cands, id)
					if hash_id(id, sel.salt + 1) % 3 == 0 {
						append(&cands, id)
					}
					roaring.add(&bm, id)
					allow.allow[id] = true
				}
			}
			clear(&out)
			testing.expect_value(t, knn(&c.ix, &qy, 10, &out, filter_ids(cands[:])), Error.None)
			want = oracle_knn(&c.m, &qy, 10, &allow, &c.ix)
			if !expect_hits(t, out[:], want, fmt.tprintf("%s query %d ids %d%%", label, qi, pct)) {
				return checked
			}
			clear(&out)
			testing.expect_value(t, knn(&c.ix, &qy, 10, &out, filter_bitmap(&bm)), Error.None)
			if !expect_hits(t, out[:], want, fmt.tprintf("%s query %d bitmap %d%%", label, qi, pct)) {
				return checked
			}
			both := Oracle_Filter{use = true, allow = allow.allow, accept = select_accept, ctx = &Select{salt = 77, percent = 60}}
			clear(&out)
			testing.expect_value(t, knn(&c.ix, &qy, 7, &out, filter_bitmap(&bm, select_accept, both.ctx)), Error.None)
			want = oracle_knn(&c.m, &qy, 7, &both, &c.ix)
			if !expect_hits(t, out[:], want, fmt.tprintf("%s query %d bitmap and accept %d%%", label, qi, pct)) {
				return checked
			}
			checked += 4
		}
		for h in out {
			kd, ok := distance(&c.ix, &qy, h.id)
			testing.expect(t, ok && same_bits(kd, h.dist))
		}
	}
	return checked
}

@(test)
knn_matches_brute_force :: proc(t: ^testing.T) {
	checked := 0
	for elem, ei in ALL_ELEMS {
		for metric, mi in ALL_METRICS {
			for dim, di in ([]int{1, 3, 8, 17, 33, 64}) {
				spec := spec_default(elem, metric, dim)
				spec.block_size = 16 if di % 2 == 0 else 1024
				c: Corpus
				seed := u64(1000 * ei + 100 * mi + di)
				corpus_build(t, &c, spec, 90, seed, di % 3 != 2, true)
				r: vmath.Rng
				vmath.rng_seed(&r, seed + 7)
				checked += check_queries(t, &c, &r, fmt.tprintf("%v %v dim %d", elem, metric, dim), 4)
				corpus_destroy(&c)
				free_all(context.temp_allocator)
			}
		}
	}
	testing.expect(t, checked >= 6 * 3 * 6 * 4 * 19)
}

@(test)
knn_on_every_kernel_level :: proc(t: ^testing.T) {
	saved := vmath.search_kernels.level
	defer vmath.use_level(saved)
	for level in supported_levels() {
		vmath.use_level(level)
		for elem in ALL_ELEMS {
			for metric in ALL_METRICS {
				spec := spec_default(elem, metric, 40)
				spec.block_size = 32
				c: Corpus
				corpus_build(t, &c, spec, 120, u64(level) * 7 + u64(elem) * 3 + u64(metric), true, true)
				r: vmath.Rng
				vmath.rng_seed(&r, 5)
				check_queries(t, &c, &r, fmt.tprintf("%v %v %v", level, elem, metric), 3)
				corpus_destroy(&c)
				free_all(context.temp_allocator)
			}
		}
	}
}

@(test)
ties_take_the_lowest_ids :: proc(t: ^testing.T) {
	spec := spec_default(.F32, .L2, 2)
	spec.block_size = 4
	ix: Index
	testing.expect_value(t, init(&ix, spec, context.allocator), Error.None)
	defer destroy(&ix)
	same := [2]f32{1, 0}
	near := [2]f32{0.1, 0}
	far := [2]f32{3, 3}
	ids := [?]u32{50, 10, 40, 20, 30, 60, 5}
	for id in ids {
		add(&ix, id, mem.slice_to_bytes(same[:]))
	}
	add(&ix, 70, mem.slice_to_bytes(near[:]))
	add(&ix, 1, mem.slice_to_bytes(far[:]))
	z := [2]f32{0, 0}
	qy: Query
	testing.expect_value(t, query_for(&qy, &ix, mem.slice_to_bytes(z[:])), Error.None)
	defer query_destroy(&qy)
	out := make([dynamic]Hit, context.temp_allocator)
	knn(&ix, &qy, 3, &out)
	testing.expect_value(t, len(out), 3)
	testing.expect_value(t, out[0].id, 70)
	testing.expect_value(t, out[1].id, 5)
	testing.expect_value(t, out[2].id, 10)
	remove(&ix, 5)
	remove(&ix, 20)
	add(&ix, 5, mem.slice_to_bytes(same[:]))
	add(&ix, 80, mem.slice_to_bytes(same[:]))
	clear(&out)
	knn(&ix, &qy, 6, &out)
	want := [?]u32{70, 5, 10, 30, 40, 50}
	testing.expect_value(t, len(out), 6)
	for w, i in want {
		testing.expect_value(t, out[i].id, w)
	}
}

@(test)
nan_distances_rank_last :: proc(t: ^testing.T) {
	for elem in ([]vmath.Elem{.F32, .F64, .F16, .BF16}) {
		spec := spec_default(elem, .L2, 2)
		ix: Index
		testing.expect_value(t, init(&ix, spec, context.allocator), Error.None)
		r: vmath.Rng
		vmath.rng_seed(&r, 3)
		add(&ix, 1, nan_blob(elem, 2, 0))
		add(&ix, 2, random_blob(&r, elem, 2, false))
		add(&ix, 3, random_blob(&r, elem, 2, false))
		add(&ix, 4, nan_blob(elem, 2, 1))
		add(&ix, 5, random_blob(&r, elem, 2, false))
		qy: Query
		testing.expect_value(t, query_for(&qy, &ix, zero_blob(elem, 2)), Error.None)
		out := make([dynamic]Hit, context.temp_allocator)
		knn(&ix, &qy, 3, &out)
		testing.expect_value(t, len(out), 3)
		for h in out {
			testing.expect(t, h.dist == h.dist && h.id != 1 && h.id != 4)
		}
		clear(&out)
		knn(&ix, &qy, 5, &out)
		testing.expect_value(t, out[3].id, 1)
		testing.expect_value(t, out[4].id, 4)
		testing.expect(t, out[3].dist != out[3].dist && out[4].dist != out[4].dist)
		clear(&out)
		range_search(&ix, &qy, 1e300, &out)
		testing.expect_value(t, len(out), 3)
		query_destroy(&qy)
		testing.expect_value(t, query_for(&qy, &ix, nan_blob(elem, 2, 0)), Error.None)
		clear(&out)
		knn(&ix, &qy, 2, &out)
		testing.expect_value(t, len(out), 2)
		testing.expect_value(t, out[0].id, 1)
		testing.expect_value(t, out[1].id, 2)
		clear(&out)
		range_search(&ix, &qy, 1e300, &out)
		testing.expect_value(t, len(out), 0)
		query_destroy(&qy)
		destroy(&ix)
	}
	spec := spec_default(.F32, .Cosine, 2)
	ix: Index
	testing.expect_value(t, init(&ix, spec, context.allocator), Error.None)
	defer destroy(&ix)
	zero := [2]f32{0, 0}
	a := [2]f32{1, 0}
	b := [2]f32{0, 1}
	add(&ix, 1, mem.slice_to_bytes(zero[:]))
	add(&ix, 2, mem.slice_to_bytes(a[:]))
	add(&ix, 3, mem.slice_to_bytes(b[:]))
	qy: Query
	testing.expect_value(t, query_for(&qy, &ix, mem.slice_to_bytes(a[:])), Error.None)
	defer query_destroy(&qy)
	out := make([dynamic]Hit, context.temp_allocator)
	knn(&ix, &qy, 3, &out)
	testing.expect_value(t, out[0].id, 2)
	testing.expect_value(t, out[1].id, 3)
	testing.expect_value(t, out[2].id, 1)
	testing.expect_value(t, transmute(u64)out[2].dist >> 63, 1)
}

@(test)
partitions_merge_exactly :: proc(t: ^testing.T) {
	for elem in ALL_ELEMS {
		spec := spec_default(elem, .Cosine, 24)
		spec.block_size = 8
		c: Corpus
		corpus_build(t, &c, spec, 150, u64(elem) + 40, true, true)
		parts: [3]Index
		for &p in parts {
			testing.expect_value(t, init(&p, spec, context.allocator), Error.None)
		}
		for id in c.m.ids {
			add(&parts[hash_id(id, 9) % 3], id, c.m.blobs[id])
		}
		r: vmath.Rng
		vmath.rng_seed(&r, 99)
		for _ in 0 ..< 4 {
			qy: Query
			testing.expect_value(t, query_for(&qy, &c.ix, random_blob(&r, elem, 24, false), context.temp_allocator), Error.None)
			list := []^Index{&parts[0], &parts[1], &parts[2]}
			whole := make([dynamic]Hit, context.temp_allocator)
			split := make([dynamic]Hit, context.temp_allocator)
			knn(&c.ix, &qy, 12, &whole)
			knn_many(list, &qy, 12, &split)
			expect_hits(t, split[:], whole[:], fmt.tprintf("%v partitions", elem))
			clear(&whole)
			clear(&split)
			range_search(&c.ix, &qy, 0.9, &whole, {}, -1, .Id)
			range_many(list, &qy, 0.9, &split, {}, -1, .Id)
			expect_hits(t, split[:], whole[:], fmt.tprintf("%v partitions range", elem))
			sel := Select{salt = 3, percent = 30}
			clear(&whole)
			clear(&split)
			knn(&c.ix, &qy, 5, &whole, filter_accept(select_accept, &sel))
			knn_many(list, &qy, 5, &split, filter_accept(select_accept, &sel))
			expect_hits(t, split[:], whole[:], fmt.tprintf("%v partitions filtered", elem))
		}
		for &p in parts {
			destroy(&p)
		}
		corpus_destroy(&c)
		free_all(context.temp_allocator)
	}
}

@(test)
accept_is_called_once_per_live_vector :: proc(t: ^testing.T) {
	spec := spec_default(.F32, .IP, 4)
	spec.block_size = 16
	c: Corpus
	corpus_build(t, &c, spec, 200, 5, true, false)
	defer corpus_destroy(&c)
	r: vmath.Rng
	vmath.rng_seed(&r, 6)
	qy: Query
	testing.expect_value(t, query_for(&qy, &c.ix, random_blob(&r, .F32, 4, false)), Error.None)
	defer query_destroy(&qy)
	sel := Select{salt = 1, percent = 100}
	out := make([dynamic]Hit, context.temp_allocator)
	knn(&c.ix, &qy, 3, &out, filter_accept(select_accept, &sel))
	testing.expect_value(t, sel.calls, len(c.m.ids))
}

@(test)
history_does_not_change_results :: proc(t: ^testing.T) {
	for elem in ALL_ELEMS {
		spec := spec_default(elem, .L2, 6)
		spec.block_size = 8
		churned: Corpus
		corpus_build(t, &churned, spec, 160, u64(elem) + 900, true, false)
		fresh: Index
		testing.expect_value(t, init(&fresh, spec, context.allocator), Error.None)
		for id in churned.m.ids {
			add(&fresh, id, churned.m.blobs[id])
		}
		testing.expect(t, capacity(&fresh) <= capacity(&churned.ix) + 2 * 8)
		r: vmath.Rng
		vmath.rng_seed(&r, 41)
		for _ in 0 ..< 6 {
			qy: Query
			testing.expect_value(t, query_for(&qy, &fresh, random_blob(&r, elem, 6, false), context.temp_allocator), Error.None)
			a := make([dynamic]Hit, context.temp_allocator)
			b := make([dynamic]Hit, context.temp_allocator)
			knn(&fresh, &qy, 25, &a)
			knn(&churned.ix, &qy, 25, &b)
			expect_hits(t, b[:], a[:], fmt.tprintf("%v knn after churn", elem))
			clear(&a)
			clear(&b)
			range_search(&fresh, &qy, 2, &a, {}, -1, .Id)
			range_search(&churned.ix, &qy, 2, &b, {}, -1, .Id)
			expect_hits(t, b[:], a[:], fmt.tprintf("%v range after churn", elem))
		}
		destroy(&fresh)
		corpus_destroy(&churned)
		free_all(context.temp_allocator)
	}
}

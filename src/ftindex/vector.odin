package ftindex

import "base:runtime"
import "core:math"
import "core:slice"
import "../hnsw"
import "../vmath"

Vector_Hit :: struct {
	doc:      u32,
	distance: f64,
}

Vector_Accept :: #type proc(ctx: rawptr, id: u32) -> bool

Hybrid_Policy :: enum u8 {
	Auto,
	Batches,
	Adhoc_Bf,
}

Vector_Query :: struct {
	blob:       []u8,
	k:          int,
	radius:     f64,
	ef_runtime: int,
	epsilon:    f64,
	policy:     Hybrid_Policy,
	batch_size: int,
	accept:     Vector_Accept,
	accept_ctx: rawptr,
	accepted:   int,
}

Vector_Add_Proc :: #type proc(ctx: rawptr, id: u32, blob: []u8) -> Error

Vector_Remove_Proc :: #type proc(ctx: rawptr, id: u32)

Vector_Count_Proc :: #type proc(ctx: rawptr) -> int

Vector_Search_Proc :: #type proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error

Vector_Destroy_Proc :: #type proc(ctx: rawptr)

Vector_Source :: struct {
	ctx:     rawptr,
	add:     Vector_Add_Proc,
	remove:  Vector_Remove_Proc,
	count:   Vector_Count_Proc,
	nearest: Vector_Search_Proc,
	within:  Vector_Search_Proc,
	destroy: Vector_Destroy_Proc,
}

vector_elem_size :: proc "contextless" (elem: vmath.Elem) -> int {
	return vmath.elem_size(elem)
}

hit_before :: proc(a, b: Vector_Hit) -> bool {
	da, db := a.distance, b.distance
	na, nb := da != da, db != db
	if na != nb {
		return nb
	}
	if !na && da != db {
		return da < db
	}
	return a.doc < b.doc
}

sort_hits :: proc(hits: []Vector_Hit) {
	slice.sort_by(hits, hit_before)
}

default_factory :: proc(ctx: rawptr, field: ^Field, allocator: runtime.Allocator) -> (Vector_Source, Error) {
	switch field.vector.method {
	case .Hnsw:
		return hnsw_source_make(field, allocator)
	case .Flat:
		return flat_source_make(field, allocator)
	case .Svs_Vamana:
	}
	return {}, .Unsupported
}

Hnsw_Source :: struct {
	arena:      vmath.Arena,
	graph:      hnsw.Index,
	scratch:    hnsw.Scratch,
	slot_doc:   [dynamic]u32,
	slot_arena: [dynamic]u32,
	doc_slot:   map[u32]u32,
	query:      []u8,
	ef_runtime: int,
	epsilon:    f64,
	encoded:    vmath.Query,
	user:       ^Vector_Query,
	candidates: [dynamic]hnsw.Candidate,
	allocator:  runtime.Allocator,
}

hnsw_distance :: proc(ctx: rawptr, a, b: u32) -> f32 {
	h := (^Hnsw_Source)(ctx)
	return vmath.arena_distance(&h.arena, h.slot_arena[a], h.slot_arena[b])
}

hnsw_query_distance :: proc(ctx: rawptr, slot: u32) -> f32 {
	h := (^Hnsw_Source)(ctx)
	return vmath.arena_query_distance(&h.arena, h.encoded, h.slot_arena[slot])
}

hnsw_accept :: proc(ctx: rawptr, slot: u32) -> bool {
	h := (^Hnsw_Source)(ctx)
	q := h.user
	if int(slot) >= len(h.slot_doc) || h.slot_doc[slot] == 0 {
		return false
	}
	return q.accept == nil || q.accept(q.accept_ctx, h.slot_doc[slot])
}

hnsw_source_make :: proc(field: ^Field, allocator: runtime.Allocator) -> (Vector_Source, Error) {
	h, ne := new(Hnsw_Source, allocator)
	if ne != nil {
		return {}, .Out_Of_Memory
	}
	h.allocator = allocator
	v := field.vector
	if vmath.arena_init(&h.arena, v.elem, v.metric, v.dim, allocator, 0, .Search) != nil {
		free(h, allocator)
		return {}, .Invalid_Definition
	}
	p := hnsw.params_default()
	p.m = v.m if v.m > 0 else HNSW_M_DEFAULT
	p.ef_construction = v.ef_construction if v.ef_construction > 0 else HNSW_EF_CONSTRUCTION_DEFAULT
	p.level_law = .Inverse_Log_M
	if hnsw.init(&h.graph, p, hnsw_distance, h, allocator) != .None {
		vmath.arena_destroy(&h.arena)
		free(h, allocator)
		return {}, .Invalid_Definition
	}
	hnsw.scratch_init(&h.scratch, allocator)
	h.slot_doc = make([dynamic]u32, allocator)
	h.slot_arena = make([dynamic]u32, allocator)
	h.doc_slot = make(map[u32]u32, 16, allocator)
	h.candidates = make([dynamic]hnsw.Candidate, allocator)
	q, qe := vmath.query_alloc(&h.arena, allocator)
	if qe != nil {
		hnsw_source_destroy(h)
		return {}, .Out_Of_Memory
	}
	h.query = q
	h.ef_runtime = v.ef_runtime if v.ef_runtime > 0 else HNSW_EF_RUNTIME_DEFAULT
	h.epsilon = v.epsilon if v.epsilon > 0 else HNSW_EPSILON_DEFAULT
	return Vector_Source {
			ctx = h,
			add = hnsw_source_add,
			remove = hnsw_source_remove,
			count = hnsw_source_count,
			nearest = hnsw_source_nearest,
			within = hnsw_source_within,
			destroy = proc(ctx: rawptr) {
				hnsw_source_destroy((^Hnsw_Source)(ctx))
			},
		},
		.None
}

hnsw_source_destroy :: proc(h: ^Hnsw_Source) {
	a := h.allocator
	hnsw.destroy(&h.graph)
	hnsw.scratch_destroy(&h.scratch)
	vmath.arena_destroy(&h.arena)
	delete(h.slot_doc)
	delete(h.slot_arena)
	delete(h.doc_slot)
	delete(h.candidates)
	if h.query != nil {
		runtime.mem_free(raw_data(h.query), a)
	}
	free(h, a)
}

hnsw_source_add :: proc(ctx: rawptr, id: u32, blob: []u8) -> Error {
	h := (^Hnsw_Source)(ctx)
	if _, had := h.doc_slot[id]; had {
		hnsw_source_remove(ctx, id)
	}
	aslot, ae := vmath.arena_insert_blob(&h.arena, blob)
	if ae != nil {
		return .Vector_Source
	}
	slot, re := hnsw.reserve(&h.graph)
	if re != .None {
		vmath.arena_free(&h.arena, aslot)
		return .Out_Of_Memory
	}
	for int(slot) >= len(h.slot_doc) {
		append(&h.slot_doc, 0)
		append(&h.slot_arena, vmath.NIL_SLOT)
	}
	h.slot_doc[slot] = id
	h.slot_arena[slot] = aslot
	if hnsw.insert(&h.graph, &h.scratch, slot) != .None {
		hnsw.release(&h.graph, slot)
		vmath.arena_free(&h.arena, aslot)
		h.slot_doc[slot] = 0
		return .Out_Of_Memory
	}
	h.doc_slot[id] = slot
	return .None
}

hnsw_source_remove :: proc(ctx: rawptr, id: u32) {
	h := (^Hnsw_Source)(ctx)
	slot, had := h.doc_slot[id]
	if !had {
		return
	}
	hnsw.remove(&h.graph, &h.scratch, slot)
	vmath.arena_free(&h.arena, h.slot_arena[slot])
	h.slot_doc[slot] = 0
	h.slot_arena[slot] = vmath.NIL_SLOT
	delete_key(&h.doc_slot, id)
}

hnsw_source_count :: proc(ctx: rawptr) -> int {
	return len((^Hnsw_Source)(ctx).doc_slot)
}

hnsw_encode :: proc(h: ^Hnsw_Source, q: ^Vector_Query) -> bool {
	encoded, ok := vmath.query_encode_blob(&h.arena, q.blob, h.query)
	h.encoded = encoded
	h.user = q
	return ok
}

hnsw_emit :: proc(h: ^Hnsw_Source, found: []hnsw.Candidate, out: ^[dynamic]Vector_Hit, radius := -1.0) -> Error {
	start := len(out)
	for c in found {
		doc := h.slot_doc[c.id]
		if doc == 0 {
			continue
		}
		d := vmath.arena_query_score(&h.arena, h.encoded, h.slot_arena[c.id])
		if radius >= 0 && !(d <= radius) {
			continue
		}
		if _, e := append(out, Vector_Hit{doc = doc, distance = d}); e != nil {
			return .Out_Of_Memory
		}
	}
	sort_hits(out[start:])
	return .None
}

hnsw_source_nearest :: proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error {
	h := (^Hnsw_Source)(ctx)
	if q.k <= 0 || len(h.doc_slot) == 0 {
		return .None
	}
	if !hnsw_encode(h, q) {
		return .Vector_Source
	}
	want := q.k
	if q.accept != nil && q.accepted >= 0 {
		want = min(want, q.accepted)
	}
	want = min(want, len(h.doc_slot))
	if want <= 0 {
		return .None
	}
	resize(&h.candidates, want)
	ef := max(q.ef_runtime if q.ef_runtime > 0 else h.ef_runtime, want)
	n: int
	err: hnsw.Error
	if q.accept == nil {
		n, err = hnsw.search(&h.graph, &h.scratch, hnsw_query_distance, h, want, ef, h.candidates[:])
	} else if q.policy == .Adhoc_Bf {
		n, err = hnsw.brute_force(&h.graph, &h.scratch, hnsw_query_distance, h, want, h.candidates[:], hnsw_accept, h)
	} else {
		n, _, err = hnsw.search_filtered(&h.graph, &h.scratch, hnsw_query_distance, h, want, ef, hnsw_accept, h, 0, h.candidates[:])
		if err == .None && n < want {
			n, err = hnsw.brute_force(&h.graph, &h.scratch, hnsw_query_distance, h, want, h.candidates[:], hnsw_accept, h)
		}
	}
	if err != .None {
		return .Out_Of_Memory
	}
	return hnsw_emit(h, h.candidates[:n], out)
}

hnsw_source_within :: proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error {
	h := (^Hnsw_Source)(ctx)
	if len(h.doc_slot) == 0 {
		return .None
	}
	if !hnsw_encode(h, q) {
		return .Vector_Source
	}
	epsilon := q.epsilon if q.epsilon > 0 else h.epsilon
	radius := f32(q.radius)
	if f64(radius) < q.radius {
		radius = math.nextafter_f32(radius, math.inf_f32(1))
	}
	r := hnsw.Range{radius = radius, epsilon = f32(epsilon), inclusive = true}
	found := make([dynamic]hnsw.Candidate, context.temp_allocator)
	accept: hnsw.Accept_Proc = hnsw_accept if q.accept != nil else nil
	ef := q.ef_runtime if q.ef_runtime > 0 else h.ef_runtime
	_, err := hnsw.search_range(&h.graph, &h.scratch, hnsw_query_distance, h, r, max(ef, 1), &found, accept, h)
	if err != .None {
		return .Out_Of_Memory
	}
	return hnsw_emit(h, found[:], out, q.radius)
}

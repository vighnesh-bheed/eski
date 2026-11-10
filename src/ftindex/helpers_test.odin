package ftindex

import "base:runtime"
import "core:c/libc"
import "core:slice"
import "core:strings"
import "../vmath"

Scan_Source :: struct {
	arena:     vmath.Arena,
	slot_doc:  [dynamic]u32,
	doc_slot:  map[u32]u32,
	query:     []u8,
	elem:      vmath.Elem,
	allocator: runtime.Allocator,
}

scan_source_make :: proc(field: ^Field, allocator: runtime.Allocator) -> (Vector_Source, Error) {
	s := new(Scan_Source, allocator)
	s.allocator = allocator
	v := field.vector
	if vmath.arena_init(&s.arena, v.elem, v.metric, v.dim, allocator, 0, .Search) != nil {
		free(s, allocator)
		return {}, .Invalid_Definition
	}
	s.elem = v.elem
	s.slot_doc = make([dynamic]u32, allocator)
	s.doc_slot = make(map[u32]u32, 16, allocator)
	q, _ := vmath.query_alloc(&s.arena, allocator)
	s.query = q
	return Vector_Source {
			ctx = s,
			add = proc(ctx: rawptr, id: u32, blob: []u8) -> Error {
				s := (^Scan_Source)(ctx)
				if len(blob) != vmath.elem_vector_bytes(s.elem, s.arena.dim) {
					return .Blob_Size
				}
				if old, had := s.doc_slot[id]; had {
					vmath.arena_free(&s.arena, old)
					s.slot_doc[old] = 0
				}
				slot, e := vmath.arena_insert_blob(&s.arena, blob)
				if e != nil {
					return .Vector_Source
				}
				for int(slot) >= len(s.slot_doc) {
					append(&s.slot_doc, 0)
				}
				s.slot_doc[slot] = id
				s.doc_slot[id] = slot
				return .None
			},
			remove = proc(ctx: rawptr, id: u32) {
				s := (^Scan_Source)(ctx)
				slot, had := s.doc_slot[id]
				if !had {
					return
				}
				vmath.arena_free(&s.arena, slot)
				s.slot_doc[slot] = 0
				delete_key(&s.doc_slot, id)
			},
			count = proc(ctx: rawptr) -> int {
				return len((^Scan_Source)(ctx).doc_slot)
			},
			nearest = proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error {
				s := (^Scan_Source)(ctx)
				all := scan_all(s, q, -1)
				sort_hits(all[:])
				append(out, ..all[:min(len(all), q.k)])
				return .None
			},
			within = proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error {
				s := (^Scan_Source)(ctx)
				radius := q.radius if s.elem == .F64 else f64(f32(q.radius))
				all := scan_all(s, q, radius)
				append(out, ..all[:])
				return .None
			},
			destroy = proc(ctx: rawptr) {
				s := (^Scan_Source)(ctx)
				a := s.allocator
				vmath.arena_destroy(&s.arena)
				delete(s.slot_doc)
				delete(s.doc_slot)
				runtime.mem_free(raw_data(s.query), a)
				free(s, a)
			},
		},
		.None
}

scan_all :: proc(s: ^Scan_Source, q: ^Vector_Query, radius: f64) -> [dynamic]Vector_Hit {
	out := make([dynamic]Vector_Hit, context.temp_allocator)
	encoded, ok := vmath.query_encode_blob(&s.arena, q.blob, s.query)
	if !ok {
		return out
	}
	if q.k <= 0 && radius < 0 {
		return out
	}
	for doc, slot in s.slot_doc {
		if doc == 0 {
			continue
		}
		if q.accept != nil && !q.accept(q.accept_ctx, doc) {
			continue
		}
		d := vmath.arena_query_score(&s.arena, encoded, u32(slot))
		if radius >= 0 && !(d <= radius) {
			continue
		}
		append(&out, Vector_Hit{doc = doc, distance = d})
	}
	return out
}

test_factory :: proc(ctx: rawptr, field: ^Field, allocator: runtime.Allocator) -> (Vector_Source, Error) {
	if field.vector.method == .Svs_Vamana {
		return flat_source_make(field, allocator)
	}
	return default_factory(ctx, field, allocator)
}

g12 :: proc(v: f64, allocator := context.temp_allocator) -> string {
	buf: [64]u8
	n := libc.snprintf(raw_data(buf[:]), len(buf), "%.12g", v)
	return strings.clone(string(buf[:n]), allocator)
}

Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ z >> 30) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ z >> 27) * 0x94D0_49BB_1331_11EB
	return z ~ z >> 31
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	return int(rng_next(r) % u64(n))
}

sorted_strings :: proc(xs: []string) -> []string {
	out := slice.clone(xs, context.temp_allocator)
	slice.sort(out)
	return out
}

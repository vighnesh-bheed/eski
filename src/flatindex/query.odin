package flatindex

import "base:runtime"
import "../vmath"

Query :: struct {
	q:         vmath.Query,
	buf:       []u8,
	allocator: runtime.Allocator,
	elem:      vmath.Elem,
	metric:    vmath.Metric,
	dim:       int,
}

query_init :: proc(qy: ^Query, spec: Spec, blob: []u8, allocator := context.allocator) -> Error {
	qy^ = {}
	if !vmath.family_supports(.Search, spec.elem, spec.metric) || !vmath.dim_valid(spec.dim) {
		return .Invalid_Spec
	}
	if len(blob) != vector_bytes(spec) {
		return .Blob_Size
	}
	proto: vmath.Arena
	if vmath.arena_init(&proto, spec.elem, spec.metric, spec.dim, allocator, 0, .Search) != nil {
		return .Invalid_Spec
	}
	buf, err := vmath.query_alloc(&proto, allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	q, ok := vmath.query_encode_blob(&proto, blob, buf)
	if !ok {
		runtime.mem_free_with_size(raw_data(buf), len(buf), allocator)
		return .Blob_Size
	}
	qy.q = q
	qy.buf = buf
	qy.allocator = allocator
	qy.elem = spec.elem
	qy.metric = spec.metric
	qy.dim = spec.dim
	return .None
}

query_for :: proc(qy: ^Query, ix: ^Index, blob: []u8, allocator := context.allocator) -> Error {
	return query_init(qy, ix.spec, blob, allocator)
}

query_destroy :: proc(qy: ^Query) {
	if qy.buf != nil {
		runtime.mem_free_with_size(raw_data(qy.buf), len(qy.buf), qy.allocator)
	}
	qy^ = {}
}

query_matches :: #force_inline proc "contextless" (ix: ^Index, qy: ^Query) -> bool {
	return qy.buf != nil && qy.elem == ix.spec.elem && qy.metric == ix.spec.metric && qy.dim == ix.spec.dim
}

query_bytes :: proc "contextless" (qy: ^Query) -> []u8 {
	return qy.buf[:vmath.elem_vector_bytes(qy.elem, qy.dim)]
}

radius_bound :: proc "contextless" (elem: vmath.Elem, radius: f64) -> (bound: f64, err: Error) {
	if radius != radius {
		return 0, .Invalid_Radius
	}
	if radius < 0 {
		return 0, .Negative_Radius
	}
	if elem == .F64 {
		return radius, .None
	}
	return f64(f32(radius)), .None
}

distance :: proc "contextless" (ix: ^Index, qy: ^Query, id: u32) -> (d: f64, ok: bool) {
	if !query_matches(ix, qy) {
		return
	}
	b, l, found := locate(ix, id)
	if !found {
		return
	}
	return vmath.arena_query_score(&ix.blocks[b].arena, qy.q, u32(l)), true
}

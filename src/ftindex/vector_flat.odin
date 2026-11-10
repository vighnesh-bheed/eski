package ftindex

import "base:runtime"
import "../flatindex"

Flat_Source :: struct {
	index:     flatindex.Index,
	hits:      [dynamic]flatindex.Hit,
	allocator: runtime.Allocator,
}

flat_error :: proc "contextless" (e: flatindex.Error) -> Error {
	#partial switch e {
	case .None, .Not_Found:
		return .None
	case .Out_Of_Memory:
		return .Out_Of_Memory
	case .Blob_Size:
		return .Blob_Size
	}
	return .Vector_Source
}

flat_source_make :: proc(field: ^Field, allocator: runtime.Allocator) -> (Vector_Source, Error) {
	f, ne := new(Flat_Source, allocator)
	if ne != nil {
		return {}, .Out_Of_Memory
	}
	f.allocator = allocator
	v := field.vector
	if flatindex.init(&f.index, flatindex.spec_default(v.elem, v.metric, v.dim), allocator) != .None {
		free(f, allocator)
		return {}, .Invalid_Definition
	}
	f.hits = make([dynamic]flatindex.Hit, allocator)
	return Vector_Source {
			ctx = f,
			add = flat_source_add,
			remove = flat_source_remove,
			count = flat_source_count,
			nearest = flat_source_nearest,
			within = flat_source_within,
			destroy = proc(ctx: rawptr) {
				f := (^Flat_Source)(ctx)
				a := f.allocator
				flatindex.destroy(&f.index)
				delete(f.hits)
				free(f, a)
			},
		},
		.None
}

flat_source_add :: proc(ctx: rawptr, id: u32, blob: []u8) -> Error {
	f := (^Flat_Source)(ctx)
	_, e := flatindex.add(&f.index, id, blob)
	return flat_error(e)
}

flat_source_remove :: proc(ctx: rawptr, id: u32) {
	f := (^Flat_Source)(ctx)
	flatindex.remove(&f.index, id)
}

flat_source_count :: proc(ctx: rawptr) -> int {
	return flatindex.count(&(^Flat_Source)(ctx).index)
}

flat_filter :: proc "contextless" (q: ^Vector_Query) -> flatindex.Filter {
	if q.accept == nil {
		return {}
	}
	return flatindex.filter_accept(q.accept, q.accept_ctx)
}

flat_emit :: proc(f: ^Flat_Source, out: ^[dynamic]Vector_Hit) -> Error {
	for h in f.hits {
		if _, e := append(out, Vector_Hit{doc = h.id, distance = h.dist}); e != nil {
			return .Out_Of_Memory
		}
	}
	return .None
}

flat_source_nearest :: proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error {
	f := (^Flat_Source)(ctx)
	if q.k <= 0 || flatindex.count(&f.index) == 0 {
		return .None
	}
	qy: flatindex.Query
	if e := flatindex.query_for(&qy, &f.index, q.blob, f.allocator); e != .None {
		return flat_error(e)
	}
	defer flatindex.query_destroy(&qy)
	clear(&f.hits)
	if e := flatindex.knn(&f.index, &qy, q.k, &f.hits, flat_filter(q)); e != .None {
		return flat_error(e)
	}
	return flat_emit(f, out)
}

flat_source_within :: proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error {
	f := (^Flat_Source)(ctx)
	if flatindex.count(&f.index) == 0 {
		return .None
	}
	qy: flatindex.Query
	if e := flatindex.query_for(&qy, &f.index, q.blob, f.allocator); e != .None {
		return flat_error(e)
	}
	defer flatindex.query_destroy(&qy)
	clear(&f.hits)
	if e := flatindex.range_search(&f.index, &qy, q.radius, &f.hits, flat_filter(q)); e != .None {
		return flat_error(e)
	}
	return flat_emit(f, out)
}

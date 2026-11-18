package ftindex

import "base:runtime"

Multi_Vector_Source :: struct {
	source: Vector_Source,
	documents: map[u32]u32,
	heads: map[u32]u32,
	previous: map[u32]u32,
	last: u32,
	allocator: runtime.Allocator,
}

multi_vector_factory :: proc(ctx: rawptr, field: ^Field, allocator: runtime.Allocator) -> (Vector_Source, Error) {
	source, err := default_factory(nil, field, allocator)
	if err != .None {
		return {}, err
	}
	m, mem_err := new(Multi_Vector_Source, allocator)
	if mem_err != nil {
		source.destroy(source.ctx)
		return {}, .Out_Of_Memory
	}
	m.source, m.allocator = source, allocator
	m.documents = make(map[u32]u32, allocator)
	m.heads = make(map[u32]u32, allocator)
	m.previous = make(map[u32]u32, allocator)
	return {
		ctx = m,
		add = multi_vector_add,
		remove = multi_vector_remove,
		count = multi_vector_count,
		nearest = multi_vector_nearest,
		within = multi_vector_within,
		destroy = multi_vector_destroy,
	}, .None
}

multi_vector_add :: proc(ctx: rawptr, doc: u32, blob: []u8) -> Error {
	m := cast(^Multi_Vector_Source)ctx
	if m.last == max(u32) {
		return .Ids_Exhausted
	}
	id := m.last + 1
	if err := m.source.add(m.source.ctx, id, blob); err != .None {
		return err
	}
	m.last = id
	m.documents[id] = doc
	m.previous[id] = m.heads[doc]
	m.heads[doc] = id
	return .None
}

multi_vector_remove :: proc(ctx: rawptr, doc: u32) {
	m := cast(^Multi_Vector_Source)ctx
	for id := m.heads[doc]; id != 0; {
		previous := m.previous[id]
		m.source.remove(m.source.ctx, id)
		delete_key(&m.documents, id)
		delete_key(&m.previous, id)
		id = previous
	}
	delete_key(&m.heads, doc)
	if len(m.documents) * 4 < cap(m.documents) {
		shrink(&m.documents)
		shrink(&m.previous)
	}
	if len(m.heads) * 4 < cap(m.heads) {
		shrink(&m.heads)
	}
}

multi_vector_count :: proc(ctx: rawptr) -> int {
	m := cast(^Multi_Vector_Source)ctx
	return len(m.documents)
}

multi_vector_destroy :: proc(ctx: rawptr) {
	m := cast(^Multi_Vector_Source)ctx
	m.source.destroy(m.source.ctx)
	delete(m.documents)
	delete(m.heads)
	delete(m.previous)
	free(m, m.allocator)
}

Multi_Vector_Filter :: struct {
	source: ^Multi_Vector_Source,
	query: ^Vector_Query,
}

multi_vector_accept :: proc(ctx: rawptr, id: u32) -> bool {
	filter := cast(^Multi_Vector_Filter)ctx
	return filter.query.accept(filter.query.accept_ctx, filter.source.documents[id])
}

multi_vector_document_hits :: proc(m: ^Multi_Vector_Source, hits: []Vector_Hit, out: ^[dynamic]Vector_Hit, limit: int) -> Error {
	start := len(out)
	seen := make(map[u32]bool, context.temp_allocator)
	for hit in hits {
		id := m.documents[hit.doc]
		if id != 0 && id not_in seen {
			seen[id] = true
			if _, err := append(out, Vector_Hit{id, hit.distance}); err != nil {
				return .Out_Of_Memory
			}
		}
	}
	sort_hits(out[start:])
	resize(out, start + min(len(out) - start, limit))
	return .None
}

multi_vector_nearest :: proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error {
	m := cast(^Multi_Vector_Source)ctx
	want := min(q.k, len(m.heads))
	if q.accept != nil && q.accepted >= 0 {
		want = min(want, q.accepted)
	}
	if want <= 0 {
		return .None
	}
	query := q^
	filter := Multi_Vector_Filter{m, q}
	if q.accept != nil {
		query.accept, query.accept_ctx, query.accepted = multi_vector_accept, &filter, -1
	}
	start := len(out)
	hits := make([dynamic]Vector_Hit, context.temp_allocator)
	for count := want; ; count *= 2 {
		query.k = min(count, len(m.documents))
		clear(&hits)
		if err := m.source.nearest(m.source.ctx, &query, &hits); err != .None {
			return err
		}
		resize(out, start)
		if err := multi_vector_document_hits(m, hits[:], out, want); err != .None {
			return err
		}
		if len(out) - start >= want || len(hits) < query.k || query.k == len(m.documents) {
			break
		}
	}
	return .None
}

multi_vector_within :: proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error {
	m := cast(^Multi_Vector_Source)ctx
	query := q^
	filter := Multi_Vector_Filter{m, q}
	if q.accept != nil {
		query.accept, query.accept_ctx, query.accepted = multi_vector_accept, &filter, -1
	}
	hits := make([dynamic]Vector_Hit, context.temp_allocator)
	if err := m.source.within(m.source.ctx, &query, &hits); err != .None {
		return err
	}
	return multi_vector_document_hits(m, hits[:], out, max(int))
}

package vsettype

import "base:runtime"
import "../hnsw"
import "../vfilter"
import "../vmath"

Scratch :: struct {
	graph:      hnsw.Scratch,
	floats:     [dynamic]f32,
	query:      []u8,
	candidates: [dynamic]hnsw.Candidate,
	stack:      [dynamic]vfilter.Value,
	hits:       [dynamic]Hit,
	allocator:  runtime.Allocator,
	ready:      bool,
}

scratch_init :: proc(sc: ^Scratch, allocator := context.allocator) {
	sc^ = Scratch{allocator = allocator}
	hnsw.scratch_init(&sc.graph, allocator)
	sc.floats = make([dynamic]f32, 0, 0, allocator)
	sc.candidates = make([dynamic]hnsw.Candidate, 0, 0, allocator)
	sc.stack = make([dynamic]vfilter.Value, 0, 0, allocator)
	sc.hits = make([dynamic]Hit, 0, 0, allocator)
	sc.ready = true
}

scratch_destroy :: proc(sc: ^Scratch) {
	if !sc.ready {
		return
	}
	hnsw.scratch_destroy(&sc.graph)
	delete(sc.floats)
	delete(sc.candidates)
	delete(sc.stack)
	delete(sc.hits)
	if sc.query != nil {
		runtime.mem_free_with_size(raw_data(sc.query), len(sc.query), sc.allocator)
	}
	sc^ = {}
}

scratch_floats :: proc(sc: ^Scratch, n: int) -> ([]f32, bool) {
	if resize(&sc.floats, n) != nil {
		return nil, false
	}
	return sc.floats[:n], true
}

scratch_query :: proc(sc: ^Scratch, n: int) -> ([]u8, bool) {
	want := max(n, 8)
	if len(sc.query) >= want {
		return sc.query, true
	}
	buf, err := runtime.mem_alloc(want, vmath.ARENA_ALIGN, sc.allocator)
	if err != nil {
		return nil, false
	}
	if sc.query != nil {
		runtime.mem_free_with_size(raw_data(sc.query), len(sc.query), sc.allocator)
	}
	sc.query = buf
	return buf, true
}

scratch_candidates :: proc(sc: ^Scratch, n: int) -> ([]hnsw.Candidate, bool) {
	if resize(&sc.candidates, n) != nil {
		return nil, false
	}
	return sc.candidates[:n], true
}

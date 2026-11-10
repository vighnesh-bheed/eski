package vsettype

import "base:runtime"
import "../hnsw"
import "../vfilter"
import "../vmath"

Scratch :: struct {
	graph:        hnsw.Scratch,
	floats:       [dynamic]f32,
	query:        []u8,
	candidates:   [dynamic]hnsw.Candidate,
	stack:        [dynamic]vfilter.Value,
	hits:         [dynamic]Hit,
	view_parts:   [dynamic]View_Part,
	shadows:      [dynamic]Shadow,
	shadow_slots: [dynamic]u32,
	shadow_pos:   [dynamic]u32,
	part_view:    [dynamic]i32,
	own_view:     [dynamic]Own_View,
	proxies:      [dynamic]Partition,
	named:        [dynamic]Named_Hit,
	named_heap:   [dynamic]Named_Hit,
	slots:        [dynamic]u32,
	links:        [dynamic]u32,
	pairs:        [dynamic]Seq_Slot,
	allocator:    runtime.Allocator,
	ready:        bool,
}

scratch_init :: proc(sc: ^Scratch, allocator := context.allocator) {
	sc^ = Scratch{allocator = allocator}
	hnsw.scratch_init(&sc.graph, allocator)
	sc.floats = make([dynamic]f32, 0, 0, allocator)
	sc.candidates = make([dynamic]hnsw.Candidate, 0, 0, allocator)
	sc.stack = make([dynamic]vfilter.Value, 0, 0, allocator)
	sc.hits = make([dynamic]Hit, 0, 0, allocator)
	sc.view_parts = make([dynamic]View_Part, 0, 0, allocator)
	sc.shadows = make([dynamic]Shadow, 0, 0, allocator)
	sc.shadow_slots = make([dynamic]u32, 0, 0, allocator)
	sc.shadow_pos = make([dynamic]u32, 0, 0, allocator)
	sc.part_view = make([dynamic]i32, 0, 0, allocator)
	sc.own_view = make([dynamic]Own_View, 0, 0, allocator)
	sc.proxies = make([dynamic]Partition, 0, 0, allocator)
	sc.named = make([dynamic]Named_Hit, 0, 0, allocator)
	sc.named_heap = make([dynamic]Named_Hit, 0, 0, allocator)
	sc.slots = make([dynamic]u32, 0, 0, allocator)
	sc.links = make([dynamic]u32, 0, 0, allocator)
	sc.pairs = make([dynamic]Seq_Slot, 0, 0, allocator)
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
	delete(sc.view_parts)
	delete(sc.shadows)
	delete(sc.shadow_slots)
	delete(sc.shadow_pos)
	delete(sc.part_view)
	delete(sc.own_view)
	delete(sc.proxies)
	delete(sc.named)
	delete(sc.named_heap)
	delete(sc.slots)
	delete(sc.links)
	delete(sc.pairs)
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

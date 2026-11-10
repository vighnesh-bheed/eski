package vmath

import "base:intrinsics"
import "base:runtime"

ARENA_ALIGN :: 64
CANONICAL_NAN :: u32(0x7FC00000)

Arena :: struct {
	block:      [^]u8,
	vectors:    [^]u8,
	norms:      [^]f32,
	ranges:     [^]f32,
	aux:        [^]f32,
	allocator:  runtime.Allocator,
	distance:   Distance_Proc,
	score:      Score_Proc,
	batch:      Batch_Proc,
	block_size: int,
	stride:     int,
	dim:        int,
	cap:        u32,
	high:       u32,
	live:       u32,
	free:       u32,
	family:     Family,
	elem:       Elem,
	metric:     Metric,
}

Query :: struct {
	data:  [^]u8,
	norm:  f32,
	range: f32,
	aux:   f32,
}

Arena_Layout :: struct {
	norms:  int,
	ranges: int,
	size:   int,
}

Free_Error :: enum u8 {
	None,
	Invalid_Slot,
	Already_Free,
}

arena_layout :: proc "contextless" (elem: Elem, dim: int, capacity: int, family := Family.Vector_Set) -> (l: Arena_Layout) {
	vectors := capacity * elem_vector_bytes(elem, dim)
	l.norms = (vectors + size_of(f32) - 1) &~ (size_of(f32) - 1)
	l.ranges = l.norms + capacity * size_of(f32)
	l.size = l.ranges + (capacity * size_of(f32) if elem_has_range(elem, family) else 0)
	return
}

arena_init :: proc(a: ^Arena, elem: Elem, metric: Metric, dim: int, allocator := context.allocator, capacity := 0, family := Family.Vector_Set) -> runtime.Allocator_Error {
	if !dim_valid(dim) || capacity < 0 || capacity > SLOT_LIMIT || !family_supports(family, elem, metric) {
		return .Invalid_Argument
	}
	a^ = {}
	a.family = family
	a.elem = elem
	a.metric = metric
	a.dim = dim
	a.stride = elem_vector_bytes(elem, dim)
	a.allocator = allocator
	a.free = NIL_SLOT
	k := family_kernels(family)
	a.distance = k.distance[elem][metric]
	a.score = k.score[elem][metric]
	a.batch = k.batch[elem][metric]
	if capacity > 0 {
		return arena_reserve(a, capacity)
	}
	return nil
}

arena_destroy :: proc(a: ^Arena) {
	if a.block != nil {
		runtime.mem_free_with_size(a.block, a.block_size, a.allocator)
	}
	a^ = {}
	a.free = NIL_SLOT
}

arena_bind_aux :: proc "contextless" (a: ^Arena) {
	a.aux = nil
	if elem_has_range(a.elem, a.family) {
		a.aux = a.ranges
	} else if a.family == .Search && search_has_norm(a.elem, a.metric) {
		a.aux = a.norms
	}
}

arena_reserve :: proc(a: ^Arena, capacity: int) -> runtime.Allocator_Error {
	if capacity <= int(a.cap) {
		return nil
	}
	if capacity > SLOT_LIMIT {
		return .Out_Of_Memory
	}
	l := arena_layout(a.elem, a.dim, capacity, a.family)
	block, err := runtime.mem_alloc_non_zeroed(l.size, ARENA_ALIGN, a.allocator)
	if err != nil {
		return err
	}
	base := raw_data(block)
	norms := ([^]f32)(base[l.norms:])
	ranges := ([^]f32)(base[l.ranges:]) if elem_has_range(a.elem, a.family) else nil
	used := int(a.high)
	if used > 0 {
		runtime.mem_copy_non_overlapping(base, a.vectors, used * a.stride)
		runtime.mem_copy_non_overlapping(norms, a.norms, used * size_of(f32))
		if ranges != nil {
			runtime.mem_copy_non_overlapping(ranges, a.ranges, used * size_of(f32))
		}
	}
	if a.block != nil {
		runtime.mem_free_with_size(a.block, a.block_size, a.allocator)
	}
	a.block = base
	a.block_size = l.size
	a.vectors = base
	a.norms = norms
	a.ranges = ranges
	a.cap = u32(capacity)
	arena_bind_aux(a)
	return nil
}

free_entry :: #force_inline proc "contextless" (next: u32) -> f32 {
	return transmute(f32)(FREE_MARK | (FREE_NIL if next == NIL_SLOT else next))
}

free_next :: #force_inline proc "contextless" (entry: f32) -> u32 {
	next := transmute(u32)entry &~ FREE_MARK
	return NIL_SLOT if next == FREE_NIL else next
}

is_free_entry :: #force_inline proc "contextless" (entry: f32) -> bool {
	return transmute(u32)entry & FREE_MARK != 0
}

live_norm :: #force_inline proc "contextless" (norm: f32) -> (f32, bool) {
	b := transmute(u32)norm
	if b & FREE_MARK == 0 {
		return norm, true
	}
	if b & 0x7F800000 == 0x7F800000 && b & 0x7FFFFF != 0 {
		return transmute(f32)(b &~ FREE_MARK), true
	}
	return norm, false
}

arena_alloc :: proc(a: ^Arena) -> (slot: u32, err: runtime.Allocator_Error) {
	if a.free != NIL_SLOT {
		slot = a.free
		a.free = free_next(a.norms[slot])
		a.norms[slot] = 0
		a.live += 1
		return
	}
	if a.high == a.cap {
		if int(a.cap) >= SLOT_LIMIT {
			return NIL_SLOT, .Out_Of_Memory
		}
		reserve_err := arena_reserve(a, min(max(1, int(a.cap) * 2), SLOT_LIMIT))
		if reserve_err != nil {
			return NIL_SLOT, reserve_err
		}
	}
	slot = a.high
	a.high += 1
	a.live += 1
	a.norms[slot] = 0
	return
}

arena_is_live :: proc "contextless" (a: ^Arena, slot: u32) -> bool {
	return slot < a.high && !is_free_entry(a.norms[slot])
}

arena_free :: proc "contextless" (a: ^Arena, slot: u32) -> Free_Error {
	if slot >= a.high {
		return .Invalid_Slot
	}
	if is_free_entry(a.norms[slot]) {
		return .Already_Free
	}
	a.norms[slot] = free_entry(a.free)
	a.free = slot
	a.live -= 1
	return .None
}

arena_insert :: proc(a: ^Arena, x: []f32) -> (slot: u32, err: runtime.Allocator_Error) {
	if a.family != .Vector_Set || len(x) < a.dim {
		return NIL_SLOT, .Invalid_Argument
	}
	slot, err = arena_alloc(a)
	if err != nil {
		return
	}
	arena_set(a, slot, x)
	return
}

arena_insert_normalised :: proc(a: ^Arena, xn: []f32, norm: f32) -> (slot: u32, err: runtime.Allocator_Error) {
	if a.family != .Vector_Set || len(xn) < a.dim {
		return NIL_SLOT, .Invalid_Argument
	}
	if _, ok := live_norm(norm); !ok {
		return NIL_SLOT, .Invalid_Argument
	}
	slot, err = arena_alloc(a)
	if err != nil {
		return
	}
	arena_set_normalised(a, slot, xn, norm)
	return
}

arena_insert_blob :: proc(a: ^Arena, blob: []u8) -> (slot: u32, err: runtime.Allocator_Error) {
	if a.family != .Search || len(blob) != a.stride {
		return NIL_SLOT, .Invalid_Argument
	}
	slot, err = arena_alloc(a)
	if err != nil {
		return
	}
	arena_set_blob(a, slot, blob)
	return
}

arena_bytes :: #force_inline proc "contextless" (a: ^Arena, slot: u32) -> []u8 {
	return a.vectors[int(slot) * a.stride:][:a.stride]
}

arena_f32 :: proc "contextless" (a: ^Arena, slot: u32) -> []f32 {
	return f32_view(arena_bytes(a, slot))
}

arena_i8 :: proc "contextless" (a: ^Arena, slot: u32) -> []i8 {
	return i8_view(arena_bytes(a, slot))
}

arena_bits :: proc "contextless" (a: ^Arena, slot: u32) -> []u64 {
	return u64_view(arena_bytes(a, slot))
}

arena_norm :: #force_inline proc "contextless" (a: ^Arena, slot: u32) -> f32 {
	return a.norms[slot]
}

arena_range :: #force_inline proc "contextless" (a: ^Arena, slot: u32) -> f32 {
	return a.ranges[slot] if a.ranges != nil else 0
}

arena_aux :: #force_inline proc "contextless" (a: ^Arena, slot: u32) -> f32 {
	return a.aux[slot] if a.aux != nil else 0
}

arena_set :: proc "contextless" (a: ^Arena, slot: u32, x: []f32) {
	if a.family != .Vector_Set {
		return
	}
	norm, range := encode(a.elem, x[:a.dim], arena_bytes(a, slot))
	a.norms[slot], _ = live_norm(norm)
	if a.ranges != nil {
		a.ranges[slot] = range
	}
}

arena_set_normalised :: proc "contextless" (a: ^Arena, slot: u32, xn: []f32, norm: f32) -> bool {
	stored, ok := live_norm(norm)
	if a.family != .Vector_Set || !ok {
		return false
	}
	range := encode_normalised(a.elem, xn[:a.dim], arena_bytes(a, slot))
	a.norms[slot] = stored
	if a.ranges != nil {
		a.ranges[slot] = range
	}
	return true
}

arena_set_raw :: proc "contextless" (a: ^Arena, slot: u32, data: []u8, norm: f32, range: f32) -> bool {
	stored, ok := live_norm(norm)
	if len(data) != a.stride || !ok {
		return false
	}
	if a.elem == .Bin && !bin_padding_clear(u64_view(data), a.dim) {
		return false
	}
	copy(arena_bytes(a, slot), data)
	a.norms[slot] = stored
	if a.ranges != nil {
		a.ranges[slot] = range
	}
	return true
}

arena_set_blob :: proc "contextless" (a: ^Arena, slot: u32, blob: []u8) -> bool {
	if a.family != .Search || len(blob) != a.stride {
		return false
	}
	aux := search_encode(a.elem, a.metric, blob, arena_bytes(a, slot))
	a.norms[slot] = aux
	return true
}

arena_decode :: proc "contextless" (a: ^Arena, slot: u32, out: []f32) {
	if a.family != .Vector_Set {
		return
	}
	decode(a.elem, arena_bytes(a, slot), a.norms[slot], arena_range(a, slot), out[:a.dim])
}

arena_distance :: #force_inline proc "contextless" (a: ^Arena, x: u32, y: u32) -> f32 {
	return a.distance(raw_data(arena_bytes(a, x)), arena_aux(a, x), raw_data(arena_bytes(a, y)), arena_aux(a, y), a.dim)
}

arena_score :: proc "contextless" (a: ^Arena, x: u32, y: u32) -> f64 {
	if a.score == nil {
		return f64(arena_distance(a, x, y))
	}
	return a.score(raw_data(arena_bytes(a, x)), arena_aux(a, x), raw_data(arena_bytes(a, y)), arena_aux(a, y), a.dim)
}

arena_slot_bytes :: proc "contextless" (a: ^Arena) -> int {
	return slot_bytes(a.elem, a.dim, a.family)
}

arena_footprint :: proc "contextless" (a: ^Arena) -> int {
	return a.block_size
}

query_bytes :: proc "contextless" (a: ^Arena) -> int {
	return a.stride
}

query_alloc :: proc(a: ^Arena, allocator := context.allocator) -> ([]u8, runtime.Allocator_Error) {
	return runtime.mem_alloc(max(a.stride, 1), ARENA_ALIGN, allocator)
}

query_buffer_ok :: #force_inline proc "contextless" (a: ^Arena, buf: []u8) -> bool {
	return len(buf) >= a.stride && uintptr(raw_data(buf)) & 7 == 0
}

query_encode :: proc "contextless" (a: ^Arena, x: []f32, buf: []u8) -> (q: Query, ok: bool) {
	if a.family != .Vector_Set || len(x) != a.dim || !query_buffer_ok(a, buf) {
		return
	}
	q.norm, q.range = encode(a.elem, x, buf[:a.stride])
	q.aux = q.range
	q.data = raw_data(buf)
	return q, true
}

query_encode_normalised :: proc "contextless" (a: ^Arena, xn: []f32, norm: f32, buf: []u8) -> (q: Query, ok: bool) {
	if a.family != .Vector_Set || len(xn) != a.dim || !query_buffer_ok(a, buf) {
		return
	}
	q.range = encode_normalised(a.elem, xn, buf[:a.stride])
	q.aux = q.range
	q.norm = norm
	q.data = raw_data(buf)
	return q, true
}

query_encode_blob :: proc "contextless" (a: ^Arena, blob: []u8, buf: []u8) -> (q: Query, ok: bool) {
	if a.family != .Search || len(blob) != a.stride || !query_buffer_ok(a, buf) {
		return
	}
	q.aux = search_encode(a.elem, a.metric, blob, buf[:a.stride])
	q.norm = q.aux
	q.data = raw_data(buf)
	return q, true
}

query_rebuild :: proc "contextless" (a: ^Arena, slot: u32, scratch: []f32, buf: []u8) -> (q: Query, ok: bool) {
	if a.family != .Vector_Set || len(scratch) < a.dim {
		return
	}
	arena_decode(a, slot, scratch[:a.dim])
	return query_encode(a, scratch[:a.dim], buf)
}

query_slot :: proc "contextless" (a: ^Arena, slot: u32) -> Query {
	return {data = raw_data(arena_bytes(a, slot)), norm = a.norms[slot], range = arena_range(a, slot), aux = arena_aux(a, slot)}
}

arena_query_distance :: #force_inline proc "contextless" (a: ^Arena, q: Query, slot: u32) -> f32 {
	return a.distance(q.data, q.aux, raw_data(arena_bytes(a, slot)), arena_aux(a, slot), a.dim)
}

arena_query_score :: proc "contextless" (a: ^Arena, q: Query, slot: u32) -> f64 {
	if a.score == nil {
		return f64(arena_query_distance(a, q, slot))
	}
	return a.score(q.data, q.aux, raw_data(arena_bytes(a, slot)), arena_aux(a, slot), a.dim)
}

arena_query_distances :: proc "contextless" (a: ^Arena, q: ^Query, slots: []u32, out: []f32) {
	a.batch(a, q, slots, out)
}

arena_prefetch :: #force_inline proc "contextless" (a: ^Arena, slot: u32) {
	start := uintptr(a.vectors) + uintptr(int(slot) * a.stride)
	last := start + uintptr(min(a.stride, PREFETCH_BYTES)) - 1
	for line := start &~ 63; line <= last; line += 64 {
		intrinsics.prefetch_read_data(rawptr(line), 3)
	}
	if a.aux != nil {
		intrinsics.prefetch_read_data(&a.aux[slot], 3)
	}
}

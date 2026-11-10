package vsettype

import "base:runtime"
import "../hnsw"
import "../rax"
import "../vfilter"
import "../vmath"

NIL_SLOT :: vmath.NIL_SLOT
M_DEFAULT :: hnsw.M_DEFAULT
M_MIN :: 4
M_MAX :: hnsw.M_MAX
EF_DEFAULT :: hnsw.EF_CONSTRUCTION_DEFAULT
EF_MAX :: 1_000_000
SEARCH_EF_DEFAULT :: 100
COUNT_DEFAULT :: 10
FILTER_EF_FACTOR :: 100
DIM_MAX :: vmath.DIM_MAX
SLOT_MAX :: vmath.SLOT_LIMIT
NAME_MAX :: int(max(u32))
PREFETCH_ARENA_BYTES :: 128 << 20

Element :: struct {
	name: [^]u8,
	len:  u32,
	pos:  u32,
	attr: vfilter.Attribute,
	seq:  u64,
}

Vset_Object :: struct {
	ledger:      Ledger,
	arena:       vmath.Arena,
	graph:       hnsw.Index,
	names:       ^rax.Rax,
	elements:    [^]Element,
	element_cap: int,
	order:       [^]u32,
	order_cap:   int,
	count:       int,
	attributes:  int,
	uid:         u64,
	version:     u64,
	dim:         int,
	input_dim:   int,
	quant:       vmath.Elem,
	prefetch:    bool,
}

Vset :: ^Vset_Object

Quant :: enum u8 {
	Q8,
	NOQUANT,
	BIN,
}

Params :: struct {
	quant:     Quant,
	dim:       int,
	input_dim: int,
	m:         int,
	seed:      u64,
}

Info :: struct {
	quant:                Quant,
	m:                    int,
	dim:                  int,
	projection_input_dim: int,
	size:                 int,
	max_level:            int,
	attributes_count:     int,
	vset_uid:             u64,
	max_node_uid:         u64,
}

INFO_FIELDS :: [9]string{"quant-type", "hnsw-m", "vector-dim", "projection-input-dim", "size", "max-level", "attributes-count", "vset-uid", "hnsw-max-node-uid"}

quant_elem :: #force_inline proc "contextless" (q: Quant) -> vmath.Elem {
	switch q {
	case .Q8:
		return .Int8
	case .NOQUANT:
		return .F32
	case .BIN:
		return .Bin
	}
	return .Int8
}

elem_quant :: #force_inline proc "contextless" (e: vmath.Elem) -> Quant {
	#partial switch e {
	case .F32:
		return .NOQUANT
	case .Bin:
		return .BIN
	}
	return .Q8
}

params_valid :: proc "contextless" (p: Params) -> bool {
	if p.quant > .BIN || !vmath.dim_valid(p.dim) || p.m < M_MIN || p.m > M_MAX {
		return false
	}
	return p.input_dim == 0 || (p.input_dim >= p.dim && vmath.dim_valid(p.input_dim))
}

allocator_of :: #force_inline proc "contextless" (s: Vset) -> runtime.Allocator {
	return ledger_allocator(&s.ledger)
}

graph_distance :: proc(ctx: rawptr, a, b: u32) -> f32 {
	s := (^Vset_Object)(ctx)
	return vmath.arena_distance(&s.arena, a, b)
}

create :: proc(p: Params) -> (s: Vset, err: Error) {
	if !params_valid(p) {
		return nil, .Invalid_Parameter
	}
	s = cast(Vset)runtime.heap_alloc(size_of(Vset_Object), true)
	if s == nil {
		return nil, .Out_Of_Memory
	}
	s.ledger.bytes = usable_size(s)
	s.dim = p.dim
	s.input_dim = p.input_dim
	s.quant = quant_elem(p.quant)
	alloc := allocator_of(s)
	if vmath.arena_init(&s.arena, s.quant, .Cosine, p.dim, alloc) != nil {
		runtime.heap_free(s)
		return nil, .Out_Of_Memory
	}
	gp := hnsw.params_default()
	gp.m = p.m
	gp.ef_construction = EF_DEFAULT
	gp.seed = p.seed if p.seed != 0 else rand64()
	if hnsw.init(&s.graph, gp, graph_distance, s, alloc) != .None {
		vmath.arena_destroy(&s.arena)
		runtime.heap_free(s)
		return nil, .Invalid_Parameter
	}
	s.names = rax.create()
	s.uid = next_uid()
	return s, .None
}

element_release :: proc(s: Vset, e: ^Element) {
	alloc := allocator_of(s)
	if e.name != nil {
		block_free(&s.ledger, e.name)
	}
	if e.attr.blob != nil {
		vfilter.attribute_destroy(&e.attr, alloc)
		s.attributes -= 1
	}
	e^ = {}
}

destroy :: proc(s: Vset) {
	if s == nil {
		return
	}
	for i in 0 ..< s.count {
		element_release(s, &s.elements[s.order[i]])
	}
	block_free(&s.ledger, s.elements)
	block_free(&s.ledger, s.order)
	hnsw.destroy(&s.graph)
	vmath.arena_destroy(&s.arena)
	rax.destroy(s.names)
	runtime.heap_free(s)
}

ledger_balance :: proc "contextless" (s: Vset) -> int {
	if s == nil {
		return 0
	}
	return s.ledger.bytes - usable_size(s) - block_bytes(s)
}

block_bytes :: proc "contextless" (s: Vset) -> int {
	n := usable_size(s.elements) + usable_size(s.order) + usable_size(s.arena.block)
	n += usable_size(s.graph.links0) + usable_size(s.graph.degree0) + usable_size(s.graph.levels) + usable_size(s.graph.upper_at)
	n += usable_size(s.graph.upper) + usable_size(s.graph.twin_link)
	for i in 0 ..< s.count {
		e := &s.elements[s.order[i]]
		n += usable_size(e.name) + usable_size(raw_data(e.attr.blob))
	}
	return n
}

memory_usage :: proc "contextless" (s: Vset) -> int {
	if s == nil {
		return 0
	}
	return s.ledger.bytes + rax.memory(s.names)
}

card :: #force_inline proc "contextless" (s: Vset) -> int {
	return 0 if s == nil else s.count
}

dim :: #force_inline proc "contextless" (s: Vset) -> int {
	return s.dim
}

quant :: #force_inline proc "contextless" (s: Vset) -> Quant {
	return elem_quant(s.quant)
}

quant_name :: proc "contextless" (q: Quant) -> string {
	return vmath.elem_name(quant_elem(q))
}

params_of :: proc "contextless" (s: Vset) -> Params {
	return Params{quant = elem_quant(s.quant), dim = s.dim, input_dim = s.input_dim, m = s.graph.m}
}

info :: proc "contextless" (s: Vset) -> Info {
	return Info {
		quant = elem_quant(s.quant),
		m = s.graph.m,
		dim = s.dim,
		projection_input_dim = s.input_dim,
		size = s.count,
		max_level = s.graph.max_level,
		attributes_count = s.attributes,
		vset_uid = s.uid,
		max_node_uid = s.graph.node_uid,
	}
}

element_name :: #force_inline proc "contextless" (s: Vset, slot: u32) -> []u8 {
	e := &s.elements[slot]
	return e.name[:e.len]
}

element_attribute :: proc "contextless" (s: Vset, slot: u32) -> (text: string, ok: bool) {
	e := &s.elements[slot]
	if e.attr.blob == nil {
		return "", false
	}
	return vfilter.attribute_text(e.attr), true
}

element_seq :: #force_inline proc "contextless" (s: Vset, slot: u32) -> u64 {
	return s.elements[slot].seq
}

find :: proc "contextless" (s: Vset, name: []u8) -> (slot: u32, ok: bool) {
	if s == nil {
		return NIL_SLOT, false
	}
	v, found := rax.find(s.names, name)
	if !found {
		return NIL_SLOT, false
	}
	return u32(uintptr(v) - 1), true
}

contains :: proc "contextless" (s: Vset, name: []u8) -> bool {
	_, ok := find(s, name)
	return ok
}

grow_capacity :: #force_inline proc "contextless" (cap: int) -> int {
	if cap < 16 {
		return max(1, cap * 2)
	}
	if cap < 64 {
		return cap + cap / 2
	}
	return cap + cap / 4
}

ensure_slot :: proc(s: Vset) -> Error {
	if s.count >= SLOT_MAX {
		return .Out_Of_Memory
	}
	if s.arena.free == NIL_SLOT && s.arena.high == s.arena.cap {
		if vmath.arena_reserve(&s.arena, min(grow_capacity(int(s.arena.cap)), SLOT_MAX)) != nil {
			return .Out_Of_Memory
		}
	}
	if s.graph.free_head == hnsw.NONE && s.graph.slots == s.graph.cap {
		if hnsw.reserve_capacity(&s.graph, min(grow_capacity(s.graph.cap), SLOT_MAX)) != .None {
			return .Out_Of_Memory
		}
	}
	high := int(s.arena.high) + 1
	if high > s.element_cap {
		cap := max(high, grow_capacity(s.element_cap))
		p := block_resize(&s.ledger, s.elements, s.element_cap * size_of(Element), cap * size_of(Element), align_of(Element), true)
		if p == nil {
			return .Out_Of_Memory
		}
		s.elements = ([^]Element)(p)
		s.element_cap = cap
	}
	if s.count + 1 > s.order_cap {
		cap := max(s.count + 1, grow_capacity(s.order_cap))
		p := block_resize(&s.ledger, s.order, s.order_cap * size_of(u32), cap * size_of(u32), align_of(u32), false)
		if p == nil {
			return .Out_Of_Memory
		}
		s.order = ([^]u32)(p)
		s.order_cap = cap
	}
	return .None
}

refresh_prefetch :: proc(s: Vset) {
	if !s.prefetch && vmath.arena_footprint(&s.arena) >= PREFETCH_ARENA_BYTES {
		hnsw.set_prefetch(&s.graph, vmath.arena_prefetch_hook, &s.arena)
		s.prefetch = true
	}
}

order_append :: #force_inline proc "contextless" (s: Vset, slot: u32) {
	s.elements[slot].pos = u32(s.count)
	s.order[s.count] = slot
	s.count += 1
}

order_remove :: #force_inline proc "contextless" (s: Vset, slot: u32) {
	pos := s.elements[slot].pos
	last := s.order[s.count - 1]
	s.order[pos] = last
	s.elements[last].pos = pos
	s.count -= 1
}

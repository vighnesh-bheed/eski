package vsettype

import "base:runtime"
import "../hnsw"
import lbl "../label"
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

Part_Mode :: enum u8 {
	Pinned,
	Flat,
	Graph,
}

Partition :: struct {
	arena:       vmath.Arena,
	graph:       hnsw.Index,
	elements:    [^]Element,
	order:       [^]u32,
	element_cap: u32,
	order_cap:   u32,
	count:       int,
	attributes:  u32,
	id:          u32,
	label:       lbl.Id,
	quant:       vmath.Elem,
	prefetch:    bool,
	mode:        Part_Mode,
}

Vset_Object :: struct {
	ledger:     Ledger,
	using core: Partition,
	names:      ^rax.Rax,
	uid:        u64,
	version:    u64,
	dim:        int,
	input_dim:  int,
	lab:        ^Labelled,
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
	p := (^Partition)(ctx)
	return vmath.arena_distance(&p.arena, a, b)
}

graph_params :: proc "contextless" (m: int, seed: u64) -> hnsw.Params {
	gp := hnsw.params_default()
	gp.m = m
	gp.ef_construction = EF_DEFAULT
	gp.seed = seed
	return gp
}

part_init :: proc(p: ^Partition, quant: vmath.Elem, dim: int, m: int, seed: u64, alloc: runtime.Allocator) -> Error {
	p.quant = quant
	if vmath.arena_init(&p.arena, quant, .Cosine, dim, alloc) != nil {
		return .Out_Of_Memory
	}
	if hnsw.init(&p.graph, graph_params(m, seed), graph_distance, p, alloc) != .None {
		vmath.arena_destroy(&p.arena)
		return .Invalid_Parameter
	}
	return .None
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
	if err = part_init(&s.core, quant_elem(p.quant), p.dim, p.m, p.seed if p.seed != 0 else rand64(), allocator_of(s)); err != .None {
		runtime.heap_free(s)
		return nil, err
	}
	s.names = rax.create()
	s.uid = next_uid()
	return s, .None
}

element_release :: proc(s: Vset, e: ^Element) {
	part_element_release(s, &s.core, e)
}

part_element_release :: proc(s: Vset, p: ^Partition, e: ^Element) {
	if e.name != nil {
		part_free(s, p, e.name)
	}
	if e.attr.blob != nil {
		vfilter.attribute_destroy(&e.attr, part_allocator(s, p))
		p.attributes -= 1
	}
	e^ = {}
}

part_release_all :: proc(s: Vset, p: ^Partition) {
	for i in 0 ..< p.count {
		part_element_release(s, p, &p.elements[p.order[i]])
	}
	part_free(s, p, p.elements)
	part_free(s, p, p.order)
	p.elements = nil
	p.order = nil
	p.element_cap = 0
	p.order_cap = 0
	p.count = 0
	hnsw.destroy(&p.graph)
	vmath.arena_destroy(&p.arena)
}

destroy :: proc(s: Vset) {
	if s == nil {
		return
	}
	if s.lab != nil {
		labelled_destroy(s)
	}
	part_release_all(s, &s.core)
	rax.destroy(s.names)
	runtime.heap_free(s)
}

ledger_balance :: proc "contextless" (s: Vset) -> int {
	if s == nil {
		return 0
	}
	return s.ledger.bytes - usable_size(s) - block_bytes(s)
}

part_block_bytes :: proc "contextless" (p: ^Partition) -> int {
	n := usable_size(p.elements) + usable_size(p.order) + usable_size(p.arena.block)
	n += usable_size(p.graph.links0) + usable_size(p.graph.degree0) + usable_size(p.graph.levels) + usable_size(p.graph.upper_at)
	n += usable_size(p.graph.upper) + usable_size(p.graph.twin_link)
	for i in 0 ..< p.count {
		e := &p.elements[p.order[i]]
		n += usable_size(e.name) + usable_size(raw_data(e.attr.blob))
	}
	return n
}

block_bytes :: proc "contextless" (s: Vset) -> int {
	n := part_block_bytes(&s.core)
	if s.lab != nil {
		n += labelled_block_bytes(s)
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
	if s == nil {
		return 0
	}
	if s.lab != nil {
		return s.lab.total
	}
	return s.count
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
		attributes_count = int(s.attributes),
		vset_uid = s.uid,
		max_node_uid = s.graph.node_uid,
	}
}

element_name :: #force_inline proc "contextless" (s: Vset, slot: u32) -> []u8 {
	e := &s.elements[slot]
	return e.name[:e.len]
}

part_element_name :: #force_inline proc "contextless" (p: ^Partition, slot: u32) -> []u8 {
	e := &p.elements[slot]
	return e.name[:e.len]
}

element_attribute :: proc "contextless" (s: Vset, slot: u32) -> (text: string, ok: bool) {
	return part_element_attribute(&s.core, slot)
}

part_element_attribute :: proc "contextless" (p: ^Partition, slot: u32) -> (text: string, ok: bool) {
	e := &p.elements[slot]
	if e.attr.blob == nil {
		return "", false
	}
	return vfilter.attribute_text(e.attr), true
}

element_seq :: #force_inline proc "contextless" (s: Vset, slot: u32) -> u64 {
	return s.elements[slot].seq
}

find :: proc "contextless" (s: Vset, name: []u8) -> (slot: u32, ok: bool) {
	if s == nil || s.lab != nil {
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
	return part_ensure_slot(s, &s.core)
}

part_ensure_slot :: proc(s: Vset, p: ^Partition) -> Error {
	if p.count >= SLOT_MAX {
		return .Out_Of_Memory
	}
	if p.arena.free == NIL_SLOT && p.arena.high == p.arena.cap {
		if vmath.arena_reserve(&p.arena, min(grow_capacity(int(p.arena.cap)), SLOT_MAX)) != nil {
			return .Out_Of_Memory
		}
	}
	if p.mode != .Flat && p.graph.free_head == hnsw.NONE && p.graph.slots == p.graph.cap {
		if hnsw.reserve_capacity(&p.graph, min(grow_capacity(p.graph.cap), SLOT_MAX)) != .None {
			return .Out_Of_Memory
		}
	}
	high := int(p.arena.high) + 1
	if high > int(p.element_cap) {
		cap := max(high, grow_capacity(int(p.element_cap)))
		q := part_resize(s, p, p.elements, int(p.element_cap) * size_of(Element), cap * size_of(Element), align_of(Element), true)
		if q == nil {
			return .Out_Of_Memory
		}
		p.elements = ([^]Element)(q)
		p.element_cap = u32(cap)
	}
	if p.count + 1 > int(p.order_cap) {
		cap := max(p.count + 1, grow_capacity(int(p.order_cap)))
		q := part_resize(s, p, p.order, int(p.order_cap) * size_of(u32), cap * size_of(u32), align_of(u32), false)
		if q == nil {
			return .Out_Of_Memory
		}
		p.order = ([^]u32)(q)
		p.order_cap = u32(cap)
	}
	return .None
}

refresh_prefetch :: proc(s: Vset) {
	part_refresh_prefetch(&s.core)
}

part_refresh_prefetch :: proc(p: ^Partition) {
	if !p.prefetch && p.mode != .Flat && vmath.arena_footprint(&p.arena) >= PREFETCH_ARENA_BYTES {
		hnsw.set_prefetch(&p.graph, vmath.arena_prefetch_hook, &p.arena)
		p.prefetch = true
	}
}

order_append :: #force_inline proc "contextless" (p: ^Partition, slot: u32) {
	p.elements[slot].pos = u32(p.count)
	p.order[p.count] = slot
	p.count += 1
}

order_remove :: #force_inline proc "contextless" (p: ^Partition, slot: u32) {
	pos := p.elements[slot].pos
	last := p.order[p.count - 1]
	p.order[pos] = last
	p.elements[last].pos = pos
	p.count -= 1
}

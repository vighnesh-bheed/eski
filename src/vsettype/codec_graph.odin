package vsettype

import "base:intrinsics"
import "core:slice"
import "../hnsw"
import "../rax"
import "../vfilter"
import "../vmath"

CODEC_SCOPED :: u8(0x01)
CODEC_RANKS :: u8(0x02)
CODEC_TWINS :: u8(0x04)
CODEC_FLAGS :: CODEC_SCOPED | CODEC_RANKS | CODEC_TWINS
CODEC_M_LIMIT :: 4096
CODEC_COPIES_LIMIT :: int(SHARED_PART_LIMIT)
CODEC_UID_LIMIT :: u64(1) << 63
RESERVE_FACTOR :: 64
RESERVE_FLOOR :: 16
RESERVE_SLOT_BYTES :: 64
RESERVE_ELEMENT_BYTES :: 16
RESERVE_NODE_BYTES :: 64
RESERVE_POOL_WORDS :: 256

Reserve_Costs :: struct {
	slot:    int,
	element: int,
	node:    int,
	pool:    int,
}

RESERVE_COSTS :: Reserve_Costs{slot = RESERVE_SLOT_BYTES, element = RESERVE_ELEMENT_BYTES, node = RESERVE_NODE_BYTES, pool = RESERVE_POOL_WORDS}

Shape :: struct {
	flags:     u8,
	quant:     Quant,
	dim:       int,
	input_dim: int,
	m:         int,
	object:    u64,
	count:     int,
	node_uid:  u64,
	rng:       u64,
	mode:      Part_Mode,
	arena_cap: int,
	slot_high: int,
	graph_cap: int,
	upper:     int,
	entry:     u32,
	max_level: int,
	twins:     int,
	width:     int,
}

Plan :: struct {
	shape: Shape,
	size:  int,
	pad:   int,
}

Elem_Rank :: struct {
	slot:   u32,
	copies: u32,
	rank:   u32,
}

encoder_u8 :: proc(e: ^Encoder, v: u8) {
	b := [1]u8{v}
	encoder_bytes(e, b[:])
}

encoder_u64le :: proc(e: ^Encoder, v: u64) {
	b := transmute([8]u8)u64le(v)
	encoder_bytes(e, b[:])
}

encoder_id :: proc(e: ^Encoder, v: u32, width: int) {
	b: [4]u8
	for i in 0 ..< width {
		b[i] = u8(v >> (8 * uint(i)))
	}
	encoder_bytes(e, b[:width])
}

encoder_zeros :: proc(e: ^Encoder, n: int) {
	zero: [64]u8
	for left := n; left > 0; {
		k := min(left, len(zero))
		encoder_bytes(e, zero[:k])
		left -= k
	}
}

decoder_u8 :: proc "contextless" (d: ^Decoder) -> (v: u8, ok: bool) {
	if d.at >= len(d.data) {
		return 0, false
	}
	v = d.data[d.at]
	d.at += 1
	return v, true
}

decoder_u64le :: proc "contextless" (d: ^Decoder) -> (v: u64, ok: bool) {
	b, good := decoder_take(d, 8)
	if !good {
		return 0, false
	}
	return u64(intrinsics.unaligned_load((^u64le)(raw_data(b)))), true
}

decoder_id :: proc "contextless" (d: ^Decoder, width: int) -> (v: u32, ok: bool) {
	b, good := decoder_take(d, width)
	if !good {
		return 0, false
	}
	for i in 0 ..< width {
		v |= u32(b[i]) << (8 * uint(i))
	}
	return v, true
}

cap_limit :: #force_inline proc "contextless" (n: int) -> int {
	return max(RESERVE_FLOOR, 2 * n)
}

part_rng :: proc "contextless" (p: ^Part_Head) -> u64 {
	if p.kind == .Compact {
		return (^Compact_Block)(p).seed
	}
	return part_graph(p).rng
}

element_copies :: proc "contextless" (s: Vset, p: ^Part_Head, slot: u32) -> (copies: int, rank: int) {
	ni := part_index(s, p)
	one: Ref
	refs := tree_lookup(ni.tree, part_element_name(p, slot), &one)
	if len(refs) <= 1 {
		return 1, 0
	}
	for r, i in refs {
		if r.part == p.id && r.slot == slot {
			return len(refs), i
		}
	}
	return 1, 0
}

part_has_copies :: proc "contextless" (s: Vset, p: ^Part_Head) -> bool {
	for i in 0 ..< p.count {
		if k, _ := element_copies(s, p, p.order[i]); k > 1 {
			return true
		}
	}
	return false
}

part_shape :: proc(s: Vset, p: ^Part_Head, scoped: bool, object: u64) -> (sh: Shape) {
	sh.quant = elem_quant(p.arena.elem)
	sh.dim = s.dim
	sh.input_dim = s.input_dim
	sh.m = s.graph.m
	sh.count = p.count
	sh.node_uid = part_uid(p)
	sh.rng = part_rng(p)
	sh.mode = p.mode
	sh.arena_cap = int(p.arena.cap)
	sh.slot_high = int(p.arena.high)
	sh.width = hnsw.link_width(sh.slot_high)
	if scoped {
		sh.flags |= CODEC_SCOPED
		sh.object = object
		if s.lab != nil && part_has_copies(s, p) {
			sh.flags |= CODEC_RANKS
		}
	}
	if p.mode != .Flat {
		g := part_graph(p)
		sh.graph_cap = g.cap
		sh.upper = hnsw.upper_lists(g)
		sh.entry = g.entry
		sh.max_level = g.max_level
		sh.twins = g.twins
		if g.twin_link != nil {
			sh.flags |= CODEC_TWINS
		}
	}
	return
}

shape_write :: proc(e: ^Encoder, sh: ^Shape) {
	magic := CODEC_MAGIC
	encoder_bytes(e, magic[:])
	head := [3]u8{CODEC_VERSION, sh.flags, u8(sh.quant)}
	encoder_bytes(e, head[:])
	encoder_varint(e, u64(sh.dim))
	encoder_varint(e, u64(sh.input_dim))
	encoder_varint(e, u64(sh.m))
	if sh.flags & CODEC_SCOPED != 0 {
		encoder_varint(e, sh.object)
	}
	encoder_varint(e, u64(sh.count))
	encoder_varint(e, sh.node_uid)
	encoder_u64le(e, sh.rng)
	encoder_u8(e, u8(sh.mode))
	encoder_varint(e, u64(sh.arena_cap))
	encoder_varint(e, u64(sh.slot_high))
	if sh.mode != .Flat {
		encoder_varint(e, u64(sh.graph_cap))
		encoder_varint(e, u64(sh.upper))
		encoder_id(e, sh.entry, sh.width)
		encoder_u8(e, u8(sh.max_level))
		encoder_varint(e, u64(sh.twins))
	}
}

element_write :: proc(e: ^Encoder, p: ^Part_Head, slot: u32, id: u32, seq: u64, width: int) {
	a := &p.arena
	el := &p.elements[slot]
	encoder_id(e, id, width)
	encoder_varint(e, seq)
	encoder_varint(e, u64(el.len))
	encoder_bytes(e, el.name[:el.len])
	encoder_bytes(e, vmath.arena_bytes(a, slot))
	encoder_f32(e, vmath.arena_norm(a, slot))
	if a.elem == .Int8 {
		encoder_f32(e, vmath.arena_range(a, slot))
	}
	if el.attr.blob == nil {
		encoder_varint(e, 0)
	} else {
		text := vfilter.attribute_text(el.attr)
		encoder_varint(e, u64(len(text)) + 1)
		encoder_bytes(e, transmute([]u8)text)
	}
}

part_body :: proc(e: ^Encoder, s: Vset, p: ^Part_Head, sh: ^Shape) {
	w := sh.width
	a := &p.arena
	for at := a.free; at != NIL_SLOT; at = vmath.free_next(a.norms[at]) {
		encoder_id(e, at, w)
	}
	ranked := sh.flags & CODEC_RANKS != 0
	for i in 0 ..< p.count {
		slot := p.order[i]
		element_write(e, p, slot, slot, p.elements[slot].seq, w)
		if ranked {
			k, r := element_copies(s, p, slot)
			encoder_varint(e, u64(k))
			if k > 1 {
				encoder_varint(e, u64(r))
			}
		}
	}
	if sh.mode == .Flat {
		return
	}
	g := part_graph(p)
	for i in 0 ..< sh.slot_high {
		slot := u32(i)
		lv := g.levels[slot]
		encoder_u8(e, lv)
		switch {
		case lv == hnsw.LEVEL_TWIN:
			encoder_id(e, hnsw.twin_prev(g, slot), w)
		case lv <= hnsw.LEVEL_CAP:
			for layer in 0 ..= int(lv) {
				l := hnsw.list_get(g, slot, layer)
				encoder_varint(e, u64(l.count))
				for k in 0 ..< l.count {
					encoder_id(e, hnsw.list_id(g, l, k), w)
				}
			}
		}
	}
}

shape_reserve_with :: proc "contextless" (sh: ^Shape, k: Reserve_Costs) -> int {
	stride := vmath.elem_vector_bytes(quant_elem(sh.quant), sh.dim)
	n := sh.arena_cap * (stride + k.slot) + sh.count * k.element
	if sh.mode != .Flat {
		width := hnsw.link_width(sh.graph_cap)
		n += sh.graph_cap * (2 * sh.m * width + k.node)
		words := sh.upper * (sh.m + 1)
		n += (words + words / 2 + k.pool + (sh.m + 1) * hnsw.LEVEL_CAP) * width
	}
	return n
}

shape_reserve :: proc "contextless" (sh: ^Shape) -> int {
	return shape_reserve_with(sh, RESERVE_COSTS)
}

reserve_floor_with :: proc "contextless" (sh: ^Shape, k: Reserve_Costs) -> int {
	floor := sh^
	floor.arena_cap = RESERVE_FLOOR
	floor.graph_cap = RESERVE_FLOOR
	floor.slot_high = RESERVE_FLOOR
	floor.count = RESERVE_FLOOR
	floor.upper = 0
	return shape_reserve_with(&floor, k)
}

reserve_floor :: proc "contextless" (sh: ^Shape) -> int {
	return reserve_floor_with(sh, RESERVE_COSTS)
}

reserve_admitted_with :: proc "contextless" (sh: ^Shape, total: int, k: Reserve_Costs) -> bool {
	return shape_reserve_with(sh, k) <= RESERVE_FACTOR * total + reserve_floor_with(sh, k)
}

reserve_admitted :: proc "contextless" (sh: ^Shape, total: int) -> bool {
	return reserve_admitted_with(sh, total, RESERVE_COSTS)
}

plan_close :: proc(plan: ^Plan, base: int) {
	need := shape_reserve(&plan.shape)
	floor := reserve_floor(&plan.shape)
	half := RESERVE_FACTOR / 2
	pad := 0
	for {
		total := base + varint_size(u64(pad)) + pad
		if need <= half * total + floor {
			plan.size = total
			plan.pad = pad
			return
		}
		deficit := need - floor - half * total
		pad += (deficit + half - 1) / half
	}
}

part_plan :: proc(s: Vset, p: ^Part_Head, scoped: bool, object: u64) -> (plan: Plan) {
	plan.shape = part_shape(s, p, scoped, object)
	enc := Encoder{dry = true}
	shape_write(&enc, &plan.shape)
	part_body(&enc, s, p, &plan.shape)
	plan_close(&plan, enc.total)
	return
}

part_write :: proc(s: Vset, p: ^Part_Head, plan: ^Plan, sink: Sink) -> int {
	enc := Encoder{sink = sink}
	e := &enc
	shape_write(e, &plan.shape)
	part_body(e, s, p, &plan.shape)
	encoder_varint(e, u64(plan.pad))
	encoder_zeros(e, plan.pad)
	encoder_flush(e)
	return e.total
}

core_plan :: proc(s: Vset) -> Plan {
	return part_plan(s, &s.core, false, 0)
}

core_write :: proc(s: Vset, plan: ^Plan, sink: Sink) -> int {
	return part_write(s, &s.core, plan, sink)
}

view_shape :: proc(v: ^View) -> (sh: Shape) {
	s := v.set
	sh.quant = elem_quant(s.arena.elem)
	sh.dim = s.dim
	sh.input_dim = s.input_dim
	sh.m = s.graph.m
	sh.count = v.size
	sh.node_uid = u64(v.size)
	sh.mode = .Flat
	sh.arena_cap = v.size
	sh.slot_high = v.size
	sh.width = hnsw.link_width(v.size)
	return
}

view_body :: proc(e: ^Encoder, v: ^View, sh: ^Shape) {
	j := 0
	for &vp in v.parts {
		p := vp.part
		for i in 0 ..< p.count {
			slot := p.order[i]
			if len(vp.shadow) > 0 && slot_shadowed(vp.shadow, slot) {
				continue
			}
			element_write(e, p, slot, u32(j), u64(j + 1), sh.width)
			j += 1
		}
	}
}

view_plan :: proc(v: ^View) -> (plan: Plan) {
	plan.shape = view_shape(v)
	enc := Encoder{dry = true}
	shape_write(&enc, &plan.shape)
	view_body(&enc, v, &plan.shape)
	plan_close(&plan, enc.total)
	return
}

view_serialized_size :: proc(v: ^View) -> int {
	if v.size == 0 {
		return 0
	}
	return view_plan(v).size
}

view_serialize :: proc(v: ^View, sink: Sink) -> int {
	if v.size == 0 {
		return 0
	}
	plan := view_plan(v)
	enc := Encoder{sink = sink}
	e := &enc
	shape_write(e, &plan.shape)
	view_body(e, v, &plan.shape)
	encoder_varint(e, u64(plan.pad))
	encoder_zeros(e, plan.pad)
	encoder_flush(e)
	return e.total
}

view_serialize_bytes :: proc(v: ^View, allocator := context.allocator) -> (out: []u8, ok: bool) {
	if v.size == 0 {
		return nil, false
	}
	plan := view_plan(v)
	buf, merr := make([]u8, plan.size, allocator)
	if merr != nil {
		return nil, false
	}
	b := Byte_Sink{out = buf}
	enc := Encoder{sink = Sink{ctx = &b, write = byte_sink_write}}
	e := &enc
	shape_write(e, &plan.shape)
	view_body(e, v, &plan.shape)
	encoder_varint(e, u64(plan.pad))
	encoder_zeros(e, plan.pad)
	encoder_flush(e)
	return buf, true
}

shape_read :: proc "contextless" (d: ^Decoder, sh: ^Shape) -> Decode_Error {
	magic, ok := decoder_take(d, 3)
	if !ok {
		return .Truncated
	}
	want := CODEC_MAGIC
	if magic[0] != want[0] || magic[1] != want[1] || magic[2] != want[2] {
		return .Bad_Magic
	}
	head, got := decoder_take(d, 3)
	if !got {
		return .Truncated
	}
	if head[0] != CODEC_VERSION {
		return .Bad_Version
	}
	if head[1] & ~CODEC_FLAGS != 0 || head[2] > u8(Quant.BIN) {
		return .Bad_Header
	}
	sh.flags = head[1]
	sh.quant = Quant(head[2])
	dim, input, m, count: u64
	good := true
	dim, ok = decoder_varint(d)
	good &= ok
	input, ok = decoder_varint(d)
	good &= ok
	m, ok = decoder_varint(d)
	good &= ok
	if !good {
		return .Truncated
	}
	if dim > u64(DIM_MAX) || input > u64(DIM_MAX) || m > CODEC_M_LIMIT {
		return .Bad_Header
	}
	sh.dim = int(dim)
	sh.input_dim = int(input)
	sh.m = int(m)
	if !params_valid(Params{quant = sh.quant, dim = sh.dim, input_dim = sh.input_dim, m = sh.m}) {
		return .Bad_Header
	}
	if sh.flags & CODEC_SCOPED != 0 {
		if sh.object, ok = decoder_varint(d); !ok {
			return .Truncated
		}
	}
	if count, ok = decoder_varint(d); !ok {
		return .Truncated
	}
	if sh.node_uid, ok = decoder_varint(d); !ok {
		return .Truncated
	}
	if sh.rng, ok = decoder_u64le(d); !ok {
		return .Truncated
	}
	mode: u8
	if mode, ok = decoder_u8(d); !ok {
		return .Truncated
	}
	if count == 0 {
		return .Empty
	}
	if count > u64(SLOT_MAX) || sh.node_uid < count || sh.node_uid >= CODEC_UID_LIMIT || mode > u8(Part_Mode.Graph) {
		return .Bad_Header
	}
	sh.count = int(count)
	sh.mode = Part_Mode(mode)
	acap, high: u64
	if acap, ok = decoder_varint(d); !ok {
		return .Truncated
	}
	if high, ok = decoder_varint(d); !ok {
		return .Truncated
	}
	if acap > u64(SLOT_MAX) || high > u64(SLOT_MAX) {
		return .Bad_Capacity
	}
	sh.arena_cap = int(acap)
	sh.slot_high = int(high)
	sh.width = hnsw.link_width(sh.slot_high)
	if sh.mode == .Flat {
		if sh.flags & CODEC_TWINS != 0 {
			return .Bad_Header
		}
		return .None
	}
	gcap, upper, twins: u64
	if gcap, ok = decoder_varint(d); !ok {
		return .Truncated
	}
	if upper, ok = decoder_varint(d); !ok {
		return .Truncated
	}
	if sh.entry, ok = decoder_id(d, sh.width); !ok {
		return .Truncated
	}
	level: u8
	if level, ok = decoder_u8(d); !ok {
		return .Truncated
	}
	if twins, ok = decoder_varint(d); !ok {
		return .Truncated
	}
	if gcap > u64(SLOT_MAX) {
		return .Bad_Capacity
	}
	if upper > u64(sh.slot_high) * hnsw.LEVEL_CAP || level > hnsw.LEVEL_CAP {
		return .Bad_Graph
	}
	if twins >= count {
		return .Bad_Twin
	}
	sh.graph_cap = int(gcap)
	sh.upper = int(upper)
	sh.max_level = int(level)
	sh.twins = int(twins)
	return .None
}

element_min_bytes :: proc "contextless" (sh: ^Shape) -> int {
	elem := quant_elem(sh.quant)
	n := sh.width + 1 + 1 + vmath.elem_vector_bytes(elem, sh.dim) + 4 + 1
	if elem == .Int8 {
		n += 4
	}
	if sh.flags & CODEC_RANKS != 0 {
		n += 1
	}
	if sh.mode != .Flat {
		n += 2
	}
	return n
}

shape_check :: proc "contextless" (sh: ^Shape, total: int, left: int) -> Decode_Error {
	if sh.slot_high < sh.count {
		return .Bad_Capacity
	}
	if sh.arena_cap < sh.slot_high || sh.arena_cap > cap_limit(sh.slot_high) {
		return .Bad_Capacity
	}
	free := sh.slot_high - sh.count
	need := free * sh.width + 1
	if sh.mode != .Flat {
		if sh.graph_cap < sh.slot_high || sh.graph_cap > cap_limit(sh.slot_high) {
			return .Bad_Capacity
		}
		if int(sh.entry) >= sh.slot_high {
			return .Bad_Entry
		}
		need += free + sh.upper
	}
	if sh.count > (left - need) / element_min_bytes(sh) {
		return .Truncated
	}
	if !reserve_admitted(sh, total) {
		return .Too_Large
	}
	return .None
}

restore_reason :: proc "contextless" (f: hnsw.Restore_Fault) -> Decode_Error {
	switch f {
	case .None:
		return .None
	case .Out_Of_Memory:
		return .Out_Of_Memory
	case .Level, .Degree, .Counts:
		return .Bad_Graph
	case .Link_Range, .Link_Self, .Link_Repeat, .Link_Target:
		return .Bad_Link
	case .Asymmetric:
		return .Asymmetric_Link
	case .Entry:
		return .Bad_Entry
	case .Twin_Prev, .Twin_Fork, .Twin_Cycle, .Twin_Table:
		return .Bad_Twin
	}
	return .Bad_Graph
}

Fill_Target :: struct {
	core:  bool,
	ni:    Name_Index,
	ranks: ^[dynamic]Elem_Rank,
}

part_arrays :: proc(s: Vset, p: ^Part_Head, cap: int) -> bool {
	q := part_resize(s, p, p.elements, int(p.element_cap) * size_of(Element), cap * size_of(Element), align_of(Element), true)
	if q == nil {
		return false
	}
	p.elements = ([^]Element)(q)
	p.element_cap = u32(cap)
	o := part_resize(s, p, p.order, int(p.order_cap) * size_of(u32), cap * size_of(u32), align_of(u32), false)
	if o == nil {
		return false
	}
	p.order = ([^]u32)(o)
	p.order_cap = u32(cap)
	return true
}

fill_name :: proc(s: Vset, p: ^Part_Head, t: ^Fill_Target, name: []u8, slot: u32) -> Decode_Error {
	if t.core {
		if _, dup := rax.find(s.names, name); dup {
			return .Duplicate_Name
		}
		rax.insert(s.names, name, rawptr(uintptr(slot) + 1))
		return .None
	}
	one: Ref
	for r in tree_lookup(t.ni.tree, name, &one) {
		if r.part == p.id {
			return .Duplicate_Name
		}
	}
	if !index_add(s, &t.ni, name, Ref{slot = slot, part = p.id}) {
		return .Out_Of_Memory
	}
	return .None
}

fill_elements :: proc(s: Vset, p: ^Part_Head, d: ^Decoder, sh: ^Shape, t: ^Fill_Target, seqs: []u64) -> Decode_Error {
	a := &p.arena
	w := sh.width
	stride := a.stride
	ranged := a.elem == .Int8
	ranked := sh.flags & CODEC_RANKS != 0
	for i in 0 ..< sh.count {
		slot, ok := decoder_id(d, w)
		if !ok {
			return .Truncated
		}
		seq, seq_ok := decoder_varint(d)
		if !seq_ok {
			return .Truncated
		}
		name_len, len_ok := decoder_varint(d)
		if !len_ok {
			return .Truncated
		}
		if name_len > u64(NAME_MAX) {
			return .Bad_Element
		}
		if name_len > u64(decoder_left(d)) {
			return .Truncated
		}
		name, _ := decoder_take(d, int(name_len))
		vector, vector_ok := decoder_take(d, stride)
		norm, norm_ok := decoder_f32(d)
		if !vector_ok || !norm_ok {
			return .Truncated
		}
		range: f32
		if ranged {
			range_ok: bool
			if range, range_ok = decoder_f32(d); !range_ok {
				return .Truncated
			}
		}
		attr_code, code_ok := decoder_varint(d)
		if !code_ok {
			return .Truncated
		}
		text: []u8
		if attr_code > 0 {
			if attr_code - 1 > u64(NAME_MAX) {
				return .Bad_Element
			}
			if attr_code - 1 > u64(decoder_left(d)) {
				return .Truncated
			}
			text, _ = decoder_take(d, int(attr_code - 1))
		}
		copies, rank: u64 = 1, 0
		if ranked {
			if copies, ok = decoder_varint(d); !ok {
				return .Truncated
			}
			if copies == 0 || copies > u64(CODEC_COPIES_LIMIT) {
				return .Bad_Rank
			}
			if copies > 1 {
				if rank, ok = decoder_varint(d); !ok {
					return .Truncated
				}
				if rank >= copies {
					return .Bad_Rank
				}
			}
		}
		if int(slot) >= sh.slot_high || !vmath.arena_is_live(a, slot) || p.elements[slot].seq != 0 {
			return .Bad_Slot
		}
		if seq == 0 || seq > sh.node_uid {
			return .Bad_Sequence
		}
		if ranged {
			if !range_valid(range) {
				return .Bad_Element
			}
			for b in vector {
				if b == 0x80 {
					return .Bad_Element
				}
			}
		}
		if !vmath.arena_set_raw(a, slot, vector, norm, range) {
			return .Bad_Element
		}
		name_copy, named := part_copy_name(s, p, name)
		if !named {
			return .Out_Of_Memory
		}
		e := &p.elements[slot]
		e^ = Element{name = name_copy, len = u32(len(name)), seq = seq}
		order_append(p, slot)
		if err := fill_name(s, p, t, name, slot); err != .None {
			return err
		}
		if attr_code > 0 {
			attr, made := part_make_attribute(s, p, text, true)
			if !made {
				return .Out_Of_Memory
			}
			part_replace_attribute(s, p, e, attr)
		}
		seqs[i] = seq
		if copies > 1 && t.ranks != nil {
			if _, err := append(t.ranks, Elem_Rank{slot = slot, copies = u32(copies), rank = u32(rank)}); err != nil {
				return .Out_Of_Memory
			}
		}
	}
	slice.sort(seqs)
	for i in 1 ..< len(seqs) {
		if seqs[i] == seqs[i - 1] {
			return .Bad_Sequence
		}
	}
	return .None
}

fill_graph :: proc(p: ^Part_Head, d: ^Decoder, sh: ^Shape) -> Decode_Error {
	g := part_graph(p)
	w := sh.width
	ids, ierr := make([dynamic]u32, 0, g.m0)
	if ierr != nil {
		return .Out_Of_Memory
	}
	defer delete(ids)
	upper := 0
	twins := 0
	for i in 0 ..< sh.slot_high {
		slot := u32(i)
		lv, ok := decoder_u8(d)
		if !ok {
			return .Truncated
		}
		used := p.elements[slot].seq != 0
		if lv == hnsw.LEVEL_FREE {
			if used {
				return .Bad_Graph
			}
			continue
		}
		if !used {
			return .Bad_Graph
		}
		if lv == hnsw.LEVEL_TWIN {
			prev, prev_ok := decoder_id(d, w)
			if !prev_ok {
				return .Truncated
			}
			if int(prev) >= sh.slot_high || hnsw.restore_twin(g, slot, prev) != .None {
				return .Bad_Twin
			}
			twins += 1
			continue
		}
		if lv > hnsw.LEVEL_CAP {
			return .Bad_Graph
		}
		upper += int(lv)
		if upper > sh.upper {
			return .Bad_Graph
		}
		if hnsw.restore_node(g, slot, int(lv)) != .None {
			return .Out_Of_Memory
		}
		for layer in 0 ..= int(lv) {
			n, n_ok := decoder_varint(d)
			if !n_ok {
				return .Truncated
			}
			if n > u64(hnsw.layer_cap(g, layer)) {
				return .Bad_Graph
			}
			if n * u64(w) > u64(decoder_left(d)) {
				return .Truncated
			}
			clear(&ids)
			for _ in 0 ..< int(n) {
				id, _ := decoder_id(d, w)
				if int(id) >= sh.slot_high {
					return .Bad_Link
				}
				append(&ids, id)
			}
			if hnsw.restore_list(g, slot, layer, ids[:]) != .None {
				return .Bad_Graph
			}
		}
	}
	if upper != sh.upper {
		return .Bad_Graph
	}
	if twins != sh.twins {
		return .Bad_Twin
	}
	return restore_reason(hnsw.restore_finish(g, sh.entry, sh.max_level, sh.rng, sh.node_uid, sh.twins))
}

fill_tail :: proc "contextless" (d: ^Decoder) -> Decode_Error {
	pad, ok := decoder_varint(d)
	if !ok {
		return .Truncated
	}
	if pad > u64(decoder_left(d)) {
		return .Truncated
	}
	bytes, _ := decoder_take(d, int(pad))
	for b in bytes {
		if b != 0 {
			return .Bad_Padding
		}
	}
	if decoder_left(d) != 0 {
		return .Trailing_Bytes
	}
	return .None
}

part_fill :: proc(s: Vset, p: ^Part_Head, d: ^Decoder, sh: ^Shape, t: ^Fill_Target) -> Decode_Error {
	a := &p.arena
	if vmath.arena_reserve(a, sh.arena_cap) != nil {
		return .Out_Of_Memory
	}
	for i in 0 ..< sh.slot_high {
		slot, err := vmath.arena_alloc(a)
		if err != nil || int(slot) != i {
			return .Out_Of_Memory
		}
	}
	free := sh.slot_high - sh.count
	chain, cerr := make([]u32, free)
	if cerr != nil {
		return .Out_Of_Memory
	}
	defer delete(chain)
	for i in 0 ..< free {
		id, ok := decoder_id(d, sh.width)
		if !ok {
			return .Truncated
		}
		if int(id) >= sh.slot_high {
			return .Bad_Free_List
		}
		chain[i] = id
	}
	for i := free - 1; i >= 0; i -= 1 {
		if vmath.arena_free(a, chain[i]) != .None {
			return .Bad_Free_List
		}
	}
	if !part_arrays(s, p, sh.arena_cap) {
		return .Out_Of_Memory
	}
	if sh.mode != .Flat {
		if hnsw.restore_reserve(part_graph(p), sh.graph_cap, sh.slot_high, chain, sh.flags & CODEC_TWINS != 0) != .None {
			return .Out_Of_Memory
		}
	}
	seqs, qerr := make([]u64, sh.count)
	if qerr != nil {
		return .Out_Of_Memory
	}
	defer delete(seqs)
	if err := fill_elements(s, p, d, sh, t, seqs); err != .None {
		return err
	}
	if sh.mode != .Flat {
		if err := fill_graph(p, d, sh); err != .None {
			return err
		}
	} else if p.kind == .Compact {
		blk := (^Compact_Block)(p)
		blk.uid = sh.node_uid
		blk.seed = sh.rng
	} else {
		g := part_graph(p)
		g.rng = sh.rng
		g.node_uid = sh.node_uid
	}
	if err := fill_tail(d); err != .None {
		return err
	}
	if full := part_full(p); full != nil && p.mode != .Flat {
		part_refresh_prefetch(full)
	}
	return .None
}

deserialize_graph :: proc(data: []u8, scratch: ^Scratch, seed: u64, rebuild: bool) -> (s: Vset, err: Decode_Error) {
	d := Decoder{data = data}
	sh: Shape
	if err = shape_read(&d, &sh); err != .None {
		return nil, err
	}
	if sh.flags & (CODEC_SCOPED | CODEC_RANKS) != 0 || sh.mode == .Graph {
		return nil, .Bad_Scope
	}
	if sh.mode == .Flat && sh.rng != 0 {
		return nil, .Bad_Header
	}
	if err = shape_check(&sh, len(data), decoder_left(&d)); err != .None {
		return nil, err
	}
	p := Params{quant = sh.quant, dim = sh.dim, input_dim = sh.input_dim, m = sh.m, seed = 1}
	if sh.mode == .Flat {
		p.seed = seed
	}
	cerr: Error
	if s, cerr = create(p); cerr != .None {
		return nil, .Out_Of_Memory if cerr == .Out_Of_Memory else .Bad_Header
	}
	s.core.mode = sh.mode
	drawn := s.core.graph.rng
	t := Fill_Target{core = true}
	if err = part_fill(s, &s.core, &d, &sh, &t); err != .None {
		destroy(s)
		return nil, err
	}
	if sh.mode == .Flat {
		s.core.graph.rng = drawn
	}
	if sh.mode == .Flat && rebuild {
		guard: Scratch_Guard
		sc := guard_begin(&guard, scratch)
		defer guard_end(&guard)
		if part_graduate(s, &s.core, sc) != .None {
			destroy(s)
			return nil, .Out_Of_Memory
		}
		s.core.mode = .Pinned
	}
	s.version = 0
	return s, .None
}

payload_reserve :: proc "contextless" (data: []u8) -> int {
	version, err := payload_version(data)
	if err != .None {
		return 0
	}
	d := Decoder{data = data}
	if version == CODEC_VERSION {
		sh: Shape
		if shape_read(&d, &sh) != .None {
			return 0
		}
		return shape_reserve(&sh)
	}
	head, ok := decoder_take(&d, 5)
	if !ok || head[4] > u8(Quant.BIN) {
		return 0
	}
	dim, d_ok := decoder_int(&d, DIM_MAX)
	_, i_ok := decoder_int(&d, DIM_MAX)
	m, m_ok := decoder_int(&d, CODEC_M_LIMIT)
	count, c_ok := decoder_int(&d, SLOT_MAX)
	if !d_ok || !i_ok || !m_ok || !c_ok || dim == 0 {
		return 0
	}
	k := RESERVE_COSTS
	stride := vmath.elem_vector_bytes(quant_elem(Quant(head[4])), dim)
	width := hnsw.link_width(count)
	n := count * (stride + k.slot + k.element + 2 * m * width + k.node)
	return n + (count * (m + 1) / 3 + k.pool) * width
}

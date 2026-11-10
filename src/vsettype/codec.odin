package vsettype

import "base:intrinsics"
import "base:runtime"
import "../hnsw"
import "../rax"
import "../vfilter"
import "../vmath"

CODEC_MAGIC :: [3]u8{'E', 'V', 'S'}
CODEC_VERSION :: u8(1)
CODEC_HEADER_MIN :: 3 + 1 + 1 + 5
CODEC_BUFFER :: 4096

Sink :: struct {
	ctx:   rawptr,
	write: proc(ctx: rawptr, data: []u8),
}

Decode_Error :: enum u8 {
	None,
	Truncated,
	Bad_Magic,
	Bad_Version,
	Bad_Header,
	Bad_Element,
	Duplicate_Name,
	Trailing_Bytes,
	Empty,
	Out_Of_Memory,
}

Encoder :: struct {
	sink:  Sink,
	buf:   [CODEC_BUFFER]u8,
	n:     int,
	total: int,
}

encoder_flush :: proc(e: ^Encoder) {
	if e.n > 0 {
		e.sink.write(e.sink.ctx, e.buf[:e.n])
		e.n = 0
	}
}

encoder_bytes :: proc(e: ^Encoder, data: []u8) {
	e.total += len(data)
	if len(data) > CODEC_BUFFER - e.n {
		encoder_flush(e)
		if len(data) >= CODEC_BUFFER {
			e.sink.write(e.sink.ctx, data)
			return
		}
	}
	copy(e.buf[e.n:], data)
	e.n += len(data)
}

varint_size :: #force_inline proc "contextless" (v: u64) -> int {
	n := 1
	for x := v; x >= 0x80; x >>= 7 {
		n += 1
	}
	return n
}

encoder_varint :: proc(e: ^Encoder, v: u64) {
	tmp: [10]u8
	n := 0
	x := v
	for x >= 0x80 {
		tmp[n] = u8(x) | 0x80
		x >>= 7
		n += 1
	}
	tmp[n] = u8(x)
	encoder_bytes(e, tmp[:n + 1])
}

encoder_f32 :: proc(e: ^Encoder, v: f32) {
	b := transmute([4]u8)u32le(transmute(u32)v)
	encoder_bytes(e, b[:])
}

quant_code :: #force_inline proc "contextless" (q: Quant) -> u8 {
	return u8(q)
}

element_encoded_size :: proc "contextless" (s: Vset, slot: u32) -> int {
	e := &s.elements[slot]
	n := varint_size(e.seq) + varint_size(u64(e.len)) + int(e.len) + s.arena.stride + 4
	if s.quant == .Int8 {
		n += 4
	}
	if e.attr.blob == nil {
		return n + 1
	}
	text := vfilter.attribute_text(e.attr)
	return n + varint_size(u64(len(text)) + 1) + len(text)
}

header_size :: proc "contextless" (s: Vset) -> int {
	return 3 + 1 + 1 + varint_size(u64(s.dim)) + varint_size(u64(s.input_dim)) + varint_size(u64(s.graph.m)) + varint_size(u64(s.count)) + varint_size(s.graph.node_uid)
}

codec_refuses :: #force_inline proc "contextless" (s: Vset) -> bool {
	return s.lab != nil
}

serialized_size :: proc "contextless" (s: Vset) -> int {
	if codec_refuses(s) {
		return 0
	}
	n := header_size(s)
	for i in 0 ..< s.count {
		n += element_encoded_size(s, s.order[i])
	}
	return n
}

serialize :: proc(s: Vset, sink: Sink) -> int {
	if codec_refuses(s) {
		return 0
	}
	enc := Encoder{sink = sink}
	e := &enc
	magic := CODEC_MAGIC
	encoder_bytes(e, magic[:])
	head := [2]u8{CODEC_VERSION, quant_code(elem_quant(s.quant))}
	encoder_bytes(e, head[:])
	encoder_varint(e, u64(s.dim))
	encoder_varint(e, u64(s.input_dim))
	encoder_varint(e, u64(s.graph.m))
	encoder_varint(e, u64(s.count))
	encoder_varint(e, s.graph.node_uid)
	for i in 0 ..< s.count {
		slot := s.order[i]
		el := &s.elements[slot]
		encoder_varint(e, el.seq)
		encoder_varint(e, u64(el.len))
		encoder_bytes(e, el.name[:el.len])
		encoder_bytes(e, vmath.arena_bytes(&s.arena, slot))
		encoder_f32(e, vmath.arena_norm(&s.arena, slot))
		if s.quant == .Int8 {
			encoder_f32(e, vmath.arena_range(&s.arena, slot))
		}
		if el.attr.blob == nil {
			encoder_varint(e, 0)
		} else {
			text := vfilter.attribute_text(el.attr)
			encoder_varint(e, u64(len(text)) + 1)
			encoder_bytes(e, transmute([]u8)text)
		}
	}
	encoder_flush(e)
	return e.total
}

Byte_Sink :: struct {
	out: []u8,
	n:   int,
}

byte_sink_write :: proc(ctx: rawptr, data: []u8) {
	b := (^Byte_Sink)(ctx)
	copy(b.out[b.n:], data)
	b.n += len(data)
}

serialize_bytes :: proc(s: Vset, allocator := context.allocator) -> (out: []u8, err: runtime.Allocator_Error) {
	if codec_refuses(s) {
		return nil, .Mode_Not_Implemented
	}
	out = make([]u8, serialized_size(s), allocator) or_return
	b := Byte_Sink{out = out}
	serialize(s, Sink{ctx = &b, write = byte_sink_write})
	return out, nil
}

Decoder :: struct {
	data: []u8,
	at:   int,
}

decoder_left :: #force_inline proc "contextless" (d: ^Decoder) -> int {
	return len(d.data) - d.at
}

decoder_take :: proc "contextless" (d: ^Decoder, n: int) -> ([]u8, bool) {
	if n < 0 || n > decoder_left(d) {
		return nil, false
	}
	out := d.data[d.at:][:n]
	d.at += n
	return out, true
}

decoder_varint :: proc "contextless" (d: ^Decoder) -> (v: u64, ok: bool) {
	shift: uint
	for i in 0 ..< 10 {
		if d.at >= len(d.data) {
			return 0, false
		}
		b := d.data[d.at]
		d.at += 1
		if i == 9 && b > 1 {
			return 0, false
		}
		v |= u64(b & 0x7F) << shift
		if b & 0x80 == 0 {
			if i > 0 && b == 0 {
				return 0, false
			}
			return v, true
		}
		shift += 7
	}
	return 0, false
}

decoder_int :: proc "contextless" (d: ^Decoder, limit: int) -> (v: int, ok: bool) {
	x, good := decoder_varint(d)
	if !good || x > u64(limit) {
		return 0, false
	}
	return int(x), true
}

decoder_f32 :: proc "contextless" (d: ^Decoder) -> (v: f32, ok: bool) {
	b, good := decoder_take(d, 4)
	if !good {
		return 0, false
	}
	return transmute(f32)u32(intrinsics.unaligned_load((^u32le)(raw_data(b)))), true
}

element_bytes_min :: proc "contextless" (stride: int, ranged: bool) -> int {
	return 1 + 1 + stride + 4 + (4 if ranged else 0) + 1
}

deserialize :: proc(data: []u8, scratch: ^Scratch = nil, seed: u64 = 0) -> (s: Vset, err: Decode_Error) {
	d := Decoder{data = data}
	magic, ok := decoder_take(&d, 3)
	if !ok {
		return nil, .Truncated
	}
	want := CODEC_MAGIC
	if magic[0] != want[0] || magic[1] != want[1] || magic[2] != want[2] {
		return nil, .Bad_Magic
	}
	head, got := decoder_take(&d, 2)
	if !got {
		return nil, .Truncated
	}
	if head[0] != CODEC_VERSION {
		return nil, .Bad_Version
	}
	if head[1] > u8(Quant.BIN) {
		return nil, .Bad_Header
	}
	p := Params{quant = Quant(head[1]), seed = seed}
	dim_ok, input_ok, m_ok, count_ok, uid_ok: bool
	p.dim, dim_ok = decoder_int(&d, DIM_MAX)
	p.input_dim, input_ok = decoder_int(&d, DIM_MAX)
	p.m, m_ok = decoder_int(&d, M_MAX)
	count: int
	count, count_ok = decoder_int(&d, SLOT_MAX)
	max_uid: u64
	max_uid, uid_ok = decoder_varint(&d)
	if !dim_ok || !input_ok || !m_ok || !count_ok || !uid_ok {
		return nil, .Bad_Header
	}
	if !params_valid(p) || max_uid < u64(count) {
		return nil, .Bad_Header
	}
	if count == 0 {
		return nil, .Empty
	}
	elem := quant_elem(p.quant)
	stride := vmath.elem_vector_bytes(elem, p.dim)
	ranged := elem == .Int8
	if count > decoder_left(&d) / element_bytes_min(stride, ranged) {
		return nil, .Truncated
	}
	cerr: Error
	s, cerr = create(p)
	if cerr != .None {
		return nil, .Out_Of_Memory if cerr == .Out_Of_Memory else .Bad_Header
	}
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	if err = decode_elements(s, &d, count, max_uid, sc); err != .None {
		destroy(s)
		return nil, err
	}
	if decoder_left(&d) != 0 {
		destroy(s)
		return nil, .Trailing_Bytes
	}
	s.graph.node_uid = max_uid
	s.version = 0
	return s, .None
}

reserve_elements :: proc(s: Vset, count: int) -> bool {
	if vmath.arena_reserve(&s.arena, count) != nil {
		return false
	}
	p := block_resize(&s.ledger, s.elements, int(s.element_cap) * size_of(Element), count * size_of(Element), align_of(Element), true)
	if p == nil {
		return false
	}
	s.elements = ([^]Element)(p)
	s.element_cap = u32(count)
	q := block_resize(&s.ledger, s.order, int(s.order_cap) * size_of(u32), count * size_of(u32), align_of(u32), false)
	if q == nil {
		return false
	}
	s.order = ([^]u32)(q)
	s.order_cap = u32(count)
	return true
}

range_valid :: #force_inline proc "contextless" (r: f32) -> bool {
	bits := transmute(u32)r
	return bits & 0x8000_0000 == 0 || (bits & 0x7F80_0000 == 0x7F80_0000 && bits & 0x7F_FFFF != 0)
}

decode_elements :: proc(s: Vset, d: ^Decoder, count: int, max_uid: u64, sc: ^Scratch) -> Decode_Error {
	if !reserve_elements(s, count) {
		return .Out_Of_Memory
	}
	stride := s.arena.stride
	ranged := s.quant == .Int8
	for _ in 0 ..< count {
		seq, seq_ok := decoder_varint(d)
		if !seq_ok {
			return .Truncated
		}
		if seq > max_uid || seq == 0 {
			return .Bad_Element
		}
		name_len, len_ok := decoder_int(d, NAME_MAX)
		if !len_ok {
			return .Truncated
		}
		name, name_ok := decoder_take(d, name_len)
		vector, vector_ok := decoder_take(d, stride)
		norm, norm_ok := decoder_f32(d)
		if !name_ok || !vector_ok || !norm_ok {
			return .Truncated
		}
		range: f32
		if ranged {
			range_ok: bool
			if range, range_ok = decoder_f32(d); !range_ok {
				return .Truncated
			}
			if !range_valid(range) {
				return .Bad_Element
			}
		}
		attr_code, attr_code_ok := decoder_int(d, NAME_MAX)
		if !attr_code_ok {
			return .Truncated
		}
		text: []u8
		if attr_code > 0 {
			text_ok: bool
			if text, text_ok = decoder_take(d, attr_code - 1); !text_ok {
				return .Truncated
			}
		}
		if ranged {
			for b in vector {
				if b == 0x80 {
					return .Bad_Element
				}
			}
		}
		if _, dup := rax.find(s.names, name); dup {
			return .Duplicate_Name
		}
		if err := decode_one(s, name, vector, norm, range, text, attr_code > 0, seq, sc); err != .None {
			return err
		}
	}
	return .None
}

decode_one :: proc(s: Vset, name: []u8, vector: []u8, norm: f32, range: f32, text: []u8, has_attr: bool, seq: u64, sc: ^Scratch) -> Decode_Error {
	if ensure_slot(s) != .None {
		return .Out_Of_Memory
	}
	name_copy, named := copy_name(s, name)
	if !named {
		return .Out_Of_Memory
	}
	slot, aerr := vmath.arena_alloc(&s.arena)
	if aerr != nil {
		block_free(&s.ledger, name_copy)
		return .Out_Of_Memory
	}
	gslot, gerr := hnsw.reserve(&s.graph)
	if gerr != .None || gslot != slot {
		if gerr == .None {
			hnsw.release(&s.graph, gslot)
		}
		vmath.arena_free(&s.arena, slot)
		block_free(&s.ledger, name_copy)
		return .Out_Of_Memory
	}
	if !vmath.arena_set_raw(&s.arena, slot, vector, norm, range) {
		hnsw.release(&s.graph, slot)
		vmath.arena_free(&s.arena, slot)
		block_free(&s.ledger, name_copy)
		return .Bad_Element
	}
	attr: vfilter.Attribute
	made := true
	if has_attr {
		attr, made = make_attribute(s, text, true)
	}
	if !made {
		hnsw.release(&s.graph, slot)
		vmath.arena_free(&s.arena, slot)
		block_free(&s.ledger, name_copy)
		return .Out_Of_Memory
	}
	if insert_node(s, slot, EF_DEFAULT, sc) != .None {
		vmath.arena_free(&s.arena, slot)
		block_free(&s.ledger, name_copy)
		if attr.blob != nil {
			vfilter.attribute_destroy(&attr, allocator_of(s))
		}
		return .Out_Of_Memory
	}
	e := &s.elements[slot]
	e^ = Element{name = name_copy, len = u32(len(name)), seq = seq}
	replace_attribute(s, e, attr)
	rax.insert(s.names, name, rawptr(uintptr(slot) + 1))
	order_append(&s.core, slot)
	refresh_prefetch(s)
	return .None
}

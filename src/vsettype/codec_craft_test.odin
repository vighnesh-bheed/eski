package vsettype

import "core:fmt"
import "core:testing"

C_Element :: struct {
	slot:   u32,
	seq:    u64,
	name:   [dynamic]u8,
	vector: [dynamic]u8,
	norm:   u32,
	range:  u32,
	attr:   int,
	text:   [dynamic]u8,
	copies: u64,
	rank:   u64,
}

C_Slot :: struct {
	level: u8,
	prev:  u32,
	lists: [dynamic][dynamic]u32,
}

Craft :: struct {
	version:   u8,
	flags:     u8,
	quant:     u8,
	dim:       u64,
	input:     u64,
	m:         u64,
	object:    u64,
	count:     u64,
	node_uid:  u64,
	rng:       u64,
	mode:      u8,
	arena_cap: u64,
	slot_high: u64,
	graph_cap: u64,
	upper:     u64,
	entry:     u32,
	max_level: u8,
	twins:     u64,
	free:      [dynamic]u32,
	elements:  [dynamic]C_Element,
	slots:     [dynamic]C_Slot,
	pad:       [dynamic]u8,
	tail:      [dynamic]u8,
	width:     int,
}

C_Reader :: struct {
	b:  []u8,
	at: int,
}

cr_u8 :: proc(r: ^C_Reader) -> u8 {
	v := r.b[r.at]
	r.at += 1
	return v
}

cr_var :: proc(r: ^C_Reader) -> u64 {
	v: u64
	shift: uint
	for {
		b := cr_u8(r)
		v |= u64(b & 0x7F) << shift
		if b & 0x80 == 0 {
			return v
		}
		shift += 7
	}
}

cr_id :: proc(r: ^C_Reader, w: int) -> u32 {
	v: u32
	for i in 0 ..< w {
		v |= u32(cr_u8(r)) << (8 * uint(i))
	}
	return v
}

cr_u32 :: proc(r: ^C_Reader) -> u32 {
	return cr_id(r, 4)
}

cr_bytes :: proc(r: ^C_Reader, n: int) -> [dynamic]u8 {
	out := make([dynamic]u8, n)
	copy(out[:], r.b[r.at:][:n])
	r.at += n
	return out
}

craft_width :: proc(high: u64) -> int {
	if high <= 65_535 {
		return 2
	}
	if high <= 16_777_215 {
		return 3
	}
	return 4
}

craft_stride :: proc(quant: u8, dim: u64) -> int {
	switch quant {
	case 0:
		return int(dim)
	case 1:
		return 4 * int(dim)
	}
	return int((dim + 63) / 64) * 8
}

craft_parse :: proc(data: []u8) -> (c: Craft) {
	r := C_Reader{b = data, at = 3}
	c.version = cr_u8(&r)
	c.flags = cr_u8(&r)
	c.quant = cr_u8(&r)
	c.dim = cr_var(&r)
	c.input = cr_var(&r)
	c.m = cr_var(&r)
	if c.flags & 1 != 0 {
		c.object = cr_var(&r)
	}
	c.count = cr_var(&r)
	c.node_uid = cr_var(&r)
	c.rng = u64(cr_u32(&r)) | u64(cr_u32(&r)) << 32
	c.mode = cr_u8(&r)
	c.arena_cap = cr_var(&r)
	c.slot_high = cr_var(&r)
	c.width = craft_width(c.slot_high)
	w := c.width
	if c.mode != 1 {
		c.graph_cap = cr_var(&r)
		c.upper = cr_var(&r)
		c.entry = cr_id(&r, w)
		c.max_level = cr_u8(&r)
		c.twins = cr_var(&r)
	}
	for _ in 0 ..< c.slot_high - c.count {
		append(&c.free, cr_id(&r, w))
	}
	stride := craft_stride(c.quant, c.dim)
	for _ in 0 ..< c.count {
		e: C_Element
		e.slot = cr_id(&r, w)
		e.seq = cr_var(&r)
		e.name = cr_bytes(&r, int(cr_var(&r)))
		e.vector = cr_bytes(&r, stride)
		e.norm = cr_u32(&r)
		if c.quant == 0 {
			e.range = cr_u32(&r)
		}
		e.attr = int(cr_var(&r)) - 1
		if e.attr >= 0 {
			e.text = cr_bytes(&r, e.attr)
		}
		e.copies = 1
		if c.flags & 2 != 0 {
			e.copies = cr_var(&r)
			if e.copies > 1 {
				e.rank = cr_var(&r)
			}
		}
		append(&c.elements, e)
	}
	if c.mode != 1 {
		for _ in 0 ..< c.slot_high {
			sl: C_Slot
			sl.level = cr_u8(&r)
			if sl.level == 0xFD {
				sl.prev = cr_id(&r, w)
			} else if sl.level <= 30 {
				for _ in 0 ..= int(sl.level) {
					n := int(cr_var(&r))
					l := make([dynamic]u32, 0, n)
					for _ in 0 ..< n {
						append(&l, cr_id(&r, w))
					}
					append(&sl.lists, l)
				}
			}
			append(&c.slots, sl)
		}
	}
	c.pad = cr_bytes(&r, int(cr_var(&r)))
	c.tail = cr_bytes(&r, len(data) - r.at)
	return
}

cw_var :: proc(b: ^[dynamic]u8, v: u64) {
	x := v
	for x >= 0x80 {
		append(b, u8(x) | 0x80)
		x >>= 7
	}
	append(b, u8(x))
}

cw_id :: proc(b: ^[dynamic]u8, v: u32, w: int) {
	for i in 0 ..< w {
		append(b, u8(v >> (8 * uint(i))))
	}
}

craft_emit :: proc(c: ^Craft) -> []u8 {
	b: [dynamic]u8
	w := c.width
	append(&b, 'E', 'V', 'S', c.version, c.flags, c.quant)
	cw_var(&b, c.dim)
	cw_var(&b, c.input)
	cw_var(&b, c.m)
	if c.flags & 1 != 0 {
		cw_var(&b, c.object)
	}
	cw_var(&b, c.count)
	cw_var(&b, c.node_uid)
	cw_id(&b, u32(c.rng), 4)
	cw_id(&b, u32(c.rng >> 32), 4)
	append(&b, c.mode)
	cw_var(&b, c.arena_cap)
	cw_var(&b, c.slot_high)
	if c.mode != 1 {
		cw_var(&b, c.graph_cap)
		cw_var(&b, c.upper)
		cw_id(&b, c.entry, w)
		append(&b, c.max_level)
		cw_var(&b, c.twins)
	}
	for f in c.free {
		cw_id(&b, f, w)
	}
	for &e in c.elements {
		cw_id(&b, e.slot, w)
		cw_var(&b, e.seq)
		cw_var(&b, u64(len(e.name)))
		append(&b, ..e.name[:])
		append(&b, ..e.vector[:])
		cw_id(&b, e.norm, 4)
		if c.quant == 0 {
			cw_id(&b, e.range, 4)
		}
		cw_var(&b, u64(e.attr + 1))
		if e.attr >= 0 {
			append(&b, ..e.text[:])
		}
		if c.flags & 2 != 0 {
			cw_var(&b, e.copies)
			if e.copies > 1 {
				cw_var(&b, e.rank)
			}
		}
	}
	if c.mode != 1 {
		for &sl in c.slots {
			append(&b, sl.level)
			if sl.level == 0xFD {
				cw_id(&b, sl.prev, w)
			} else if sl.level <= 30 {
				for &l in sl.lists {
					cw_var(&b, u64(len(l)))
					for id in l {
						cw_id(&b, id, w)
					}
				}
			}
		}
	}
	cw_var(&b, u64(len(c.pad)))
	append(&b, ..c.pad[:])
	append(&b, ..c.tail[:])
	return b[:]
}

craft_destroy :: proc(c: ^Craft) {
	for &e in c.elements {
		delete(e.name)
		delete(e.vector)
		delete(e.text)
	}
	for &sl in c.slots {
		for &l in sl.lists {
			delete(l)
		}
		delete(sl.lists)
	}
	delete(c.free)
	delete(c.elements)
	delete(c.slots)
	delete(c.pad)
	delete(c.tail)
}

craft_of :: proc(s: Vset) -> Craft {
	blob := g_bytes(s)
	defer delete(blob)
	return craft_parse(blob)
}

craft_slot_of :: proc(c: ^Craft, level_min: int, twin := false) -> int {
	for &sl, i in c.slots {
		if twin {
			if sl.level == 0xFD {
				return i
			}
		} else if sl.level <= 30 && int(sl.level) >= level_min {
			return i
		}
	}
	return -1
}

craft_list_has :: proc(c: ^Craft, slot: int, layer: int, id: u32) -> bool {
	for x in c.slots[slot].lists[layer] {
		if x == id {
			return true
		}
	}
	return false
}

craft_drop :: proc(l: ^[dynamic]u32, id: u32) {
	for x, i in l {
		if x == id {
			ordered_remove(l, i)
			return
		}
	}
}

CRAFT_TRACE :: #config(CRAFT_TRACE, false)

Craft_Case :: struct {
	name:   string,
	want:   Decode_Error,
	mutate: proc(c: ^Craft) -> bool,
}

craft_expect :: proc(t: ^testing.T, base: Vset, k: Craft_Case) {
	when ODIN_DEBUG {
		if CRAFT_TRACE {
			fmt.eprintln("case", k.name)
		}
	}
	c := craft_of(base)
	defer craft_destroy(&c)
	if !testing.expectf(t, k.mutate(&c), "%s: the base set has no place for this case", k.name) {
		return
	}
	data := craft_emit(&c)
	defer delete(data)
	live := blocks_live
	s, err := deserialize(data)
	if s != nil {
		destroy(s)
	}
	testing.expectf(t, err == k.want, "%s: decoded with %v, wanted %v", k.name, err, k.want)
	testing.expectf(t, blocks_live == live, "%s: %d blocks of the set's own allocator left behind", k.name, blocks_live - live)
}

craft_holes :: proc(s: Vset, sc: ^Scratch) {
	for i in 0 ..< 3 {
		owned := fmt.tprintf("%s", string(element_name(s, s.order[(i * 7) % s.count])))
		remove(s, transmute([]u8)owned, sc)
	}
	free_all(context.temp_allocator)
}

craft_bases :: proc(t: ^testing.T, sc: ^Scratch) -> (q8: Vset, bin: Vset, f32s: Vset) {
	q8 = g_build(t, G_Shape{.Q8, 6, 4, 260, 0}, 0x51, sc)
	bin = g_build(t, G_Shape{.BIN, 8, 4, 300, 0}, 0x52, sc)
	f32s = g_build(t, G_Shape{.NOQUANT, 5, 4, 200, 0}, 0x53, sc)
	craft_holes(q8, sc)
	craft_holes(bin, sc)
	craft_holes(f32s, sc)
	return
}

craft_any_link :: proc(c: ^Craft, layer: int) -> (a: int, b: u32, ok: bool) {
	for &sl, i in c.slots {
		if sl.level <= 30 && int(sl.level) >= layer && len(sl.lists[layer]) > 0 {
			return i, sl.lists[layer][0], true
		}
	}
	return
}

@(test)
graph_payload_check_round_trips_its_own_bytes :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	q8, bin, f := craft_bases(t, &sc)
	defer destroy(q8)
	defer destroy(bin)
	defer destroy(f)
	for s in ([3]Vset{q8, bin, f}) {
		blob := g_bytes(s)
		c := craft_parse(blob)
		again := craft_emit(&c)
		testing.expect(t, string(again) == string(blob), "the test parser reads the payload exactly")
		testing.expect(t, int(c.slot_high) > int(c.count) && len(c.free) > 0, "the base set has free slots")
		delete(again)
		craft_destroy(&c)
		delete(blob)
	}
	testing.expect(t, bin.graph.twins > 0, "the binary base set has twins")
}

@(test)
graph_payload_refuses_each_malformed_class :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	q8, bin, f := craft_bases(t, &sc)
	defer destroy(q8)
	defer destroy(bin)
	defer destroy(f)
	header_cases := []Craft_Case {
		{"version", .Bad_Version, proc(c: ^Craft) -> bool {c.version = 3; return true}},
		{"unknown flag", .Bad_Header, proc(c: ^Craft) -> bool {c.flags |= 0x08; return true}},
		{"quantisation", .Bad_Header, proc(c: ^Craft) -> bool {c.quant = 3; return true}},
		{"M below the minimum", .Bad_Header, proc(c: ^Craft) -> bool {c.m = 3; return true}},
		{"M above the command limit", .Bad_Header, proc(c: ^Craft) -> bool {c.m = 4097; return true}},
		{"zero dimension", .Bad_Header, proc(c: ^Craft) -> bool {c.dim = 0; return true}},
		{"projection below the dimension", .Bad_Header, proc(c: ^Craft) -> bool {c.input = c.dim - 1; return true}},
		{"empty", .Empty, proc(c: ^Craft) -> bool {c.count = 0; return true}},
		{"node counter below the count", .Bad_Header, proc(c: ^Craft) -> bool {c.node_uid = c.count - 1; return true}},
		{"mode", .Bad_Header, proc(c: ^Craft) -> bool {c.mode = 3; return true}},
		{"scoped payload", .Bad_Scope, proc(c: ^Craft) -> bool {c.flags |= 1; c.object = 0; return true}},
		{"graph mode without scope", .Bad_Scope, proc(c: ^Craft) -> bool {c.mode = 2; return true}},
		{"count above the slots", .Bad_Capacity, proc(c: ^Craft) -> bool {c.count = c.slot_high + 1; return true}},
		{"arena capacity below the slots", .Bad_Capacity, proc(c: ^Craft) -> bool {c.arena_cap = c.slot_high - 1; return true}},
		{"arena capacity too large", .Bad_Capacity, proc(c: ^Craft) -> bool {c.arena_cap = max(16, 2 * c.slot_high) + 1; return true}},
		{"graph capacity below the slots", .Bad_Capacity, proc(c: ^Craft) -> bool {c.graph_cap = c.slot_high - 1; return true}},
		{"graph capacity too large", .Bad_Capacity, proc(c: ^Craft) -> bool {c.graph_cap = max(16, 2 * c.slot_high) + 1; return true}},
		{"entry beyond the slots", .Bad_Entry, proc(c: ^Craft) -> bool {c.entry = u32(c.slot_high); return true}},
		{"too many upper lists", .Bad_Graph, proc(c: ^Craft) -> bool {c.upper = c.slot_high * 30 + 1; return true}},
		{"upper list total", .Bad_Graph, proc(c: ^Craft) -> bool {c.upper += 1; return true}},
		{"level above the cap", .Bad_Graph, proc(c: ^Craft) -> bool {c.max_level = 31; return true}},
		{"twin count", .Bad_Twin, proc(c: ^Craft) -> bool {c.twins += 1; return true}},
		{"padding", .Bad_Padding, proc(c: ^Craft) -> bool {append(&c.pad, 0, 7); return true}},
		{"trailing bytes", .Trailing_Bytes, proc(c: ^Craft) -> bool {append(&c.tail, 0); return true}},
	}
	free_cases := []Craft_Case {
		{"free slot beyond the slots", .Bad_Free_List, proc(c: ^Craft) -> bool {c.free[0] = u32(c.slot_high); return true}},
		{"free slot repeated", .Bad_Free_List, proc(c: ^Craft) -> bool {
				if len(c.free) < 2 {return false}
				c.free[1] = c.free[0]
				return true
			}},
		{"element in a free slot", .Bad_Slot, proc(c: ^Craft) -> bool {c.elements[0].slot = c.free[0]; return true}},
		{"element beyond the slots", .Bad_Slot, proc(c: ^Craft) -> bool {c.elements[0].slot = u32(c.slot_high); return true}},
		{"element slot repeated", .Bad_Slot, proc(c: ^Craft) -> bool {c.elements[1].slot = c.elements[0].slot; return true}},
		{"sequence zero", .Bad_Sequence, proc(c: ^Craft) -> bool {c.elements[0].seq = 0; return true}},
		{"sequence above the counter", .Bad_Sequence, proc(c: ^Craft) -> bool {c.elements[0].seq = c.node_uid + 1; return true}},
		{"sequence repeated", .Bad_Sequence, proc(c: ^Craft) -> bool {c.elements[1].seq = c.elements[0].seq; return true}},
		{"name repeated", .Duplicate_Name, proc(c: ^Craft) -> bool {
				clear(&c.elements[1].name)
				append(&c.elements[1].name, ..c.elements[0].name[:])
				return true
			}},
		{"norm that marks a free slot", .Bad_Element, proc(c: ^Craft) -> bool {c.elements[0].norm = 0x8000_0001; return true}},
	}
	graph_cases := []Craft_Case {
		{"level byte reserved", .Bad_Graph, proc(c: ^Craft) -> bool {c.slots[c.elements[0].slot].level = 0xFE; return true}},
		{"free level on an element", .Bad_Graph, proc(c: ^Craft) -> bool {
				sl := &c.slots[c.elements[0].slot]
				if sl.level == 0xFD || sl.level > 0 {return false}
				for &l in sl.lists {delete(l)}
				clear(&sl.lists)
				sl.level = 0xFF
				return true
			}},
		{"node level on a free slot", .Bad_Graph, proc(c: ^Craft) -> bool {
				sl := &c.slots[c.free[0]]
				sl.level = 0
				append(&sl.lists, make([dynamic]u32))
				return true
			}},
		{"layer zero over two M", .Bad_Graph, proc(c: ^Craft) -> bool {
				at := craft_slot_of(c, 0)
				for len(c.slots[at].lists[0]) <= int(2 * c.m) {append(&c.slots[at].lists[0], 0)}
				return true
			}},
		{"upper layer over M", .Bad_Graph, proc(c: ^Craft) -> bool {
				at := craft_slot_of(c, 1)
				if at < 0 {return false}
				for len(c.slots[at].lists[1]) <= int(c.m) {append(&c.slots[at].lists[1], 0)}
				return true
			}},
		{"link beyond the slots", .Bad_Link, proc(c: ^Craft) -> bool {
				a, _, ok := craft_any_link(c, 0)
				if !ok {return false}
				c.slots[a].lists[0][0] = u32(c.slot_high)
				return true
			}},
		{"link to itself", .Bad_Link, proc(c: ^Craft) -> bool {
				a, _, ok := craft_any_link(c, 0)
				if !ok {return false}
				c.slots[a].lists[0][0] = u32(a)
				return true
			}},
		{"link repeated", .Bad_Link, proc(c: ^Craft) -> bool {
				for &sl in c.slots {
					if sl.level <= 30 && len(sl.lists[0]) >= 2 {
						sl.lists[0][1] = sl.lists[0][0]
						return true
					}
				}
				return false
			}},
		{"link to a free slot", .Bad_Link, proc(c: ^Craft) -> bool {
				a, _, ok := craft_any_link(c, 0)
				if !ok {return false}
				c.slots[a].lists[0][0] = c.free[0]
				return true
			}},
		{"upper link to a lower node", .Bad_Link, proc(c: ^Craft) -> bool {
				at := craft_slot_of(c, 1)
				if at < 0 || len(c.slots[at].lists[1]) == 0 {return false}
				for &sl, i in c.slots {
					if sl.level == 0 && !craft_list_has(c, at, 1, u32(i)) {
						c.slots[at].lists[1][0] = u32(i)
						return true
					}
				}
				return false
			}},
		{"one way link", .Asymmetric_Link, proc(c: ^Craft) -> bool {
				a, b, ok := craft_any_link(c, 0)
				if !ok {return false}
				craft_drop(&c.slots[b].lists[0], u32(a))
				return true
			}},
		{"entry below the top level", .Bad_Entry, proc(c: ^Craft) -> bool {
				for &sl, i in c.slots {
					if sl.level <= 30 && sl.level < c.max_level {
						c.entry = u32(i)
						return true
					}
				}
				return false
			}},
		{"top level not the highest", .Bad_Entry, proc(c: ^Craft) -> bool {
				if c.max_level == 0 {return false}
				c.max_level -= 1
				return true
			}},
	}
	twin_cases := []Craft_Case {
		{"link to a twin", .Bad_Link, proc(c: ^Craft) -> bool {
				tw := craft_slot_of(c, 0, true)
				a, _, ok := craft_any_link(c, 0)
				if tw < 0 || !ok {return false}
				c.slots[a].lists[0][0] = u32(tw)
				return true
			}},
		{"entry on a twin", .Bad_Entry, proc(c: ^Craft) -> bool {
				tw := craft_slot_of(c, 0, true)
				if tw < 0 {return false}
				c.entry = u32(tw)
				return true
			}},
		{"twin before nothing", .Bad_Twin, proc(c: ^Craft) -> bool {
				tw := craft_slot_of(c, 0, true)
				if tw < 0 {return false}
				c.slots[tw].prev = u32(c.slot_high)
				return true
			}},
		{"twin after a free slot", .Bad_Twin, proc(c: ^Craft) -> bool {
				tw := craft_slot_of(c, 0, true)
				if tw < 0 {return false}
				c.slots[tw].prev = c.free[0]
				return true
			}},
		{"twin after itself", .Bad_Twin, proc(c: ^Craft) -> bool {
				tw := craft_slot_of(c, 0, true)
				if tw < 0 {return false}
				c.slots[tw].prev = u32(tw)
				return true
			}},
		{"two twins after one slot", .Bad_Twin, proc(c: ^Craft) -> bool {
				first := -1
				for &sl, i in c.slots {
					if sl.level != 0xFD {continue}
					if first < 0 {
						first = i
					} else if sl.prev != c.slots[first].prev {
						sl.prev = c.slots[first].prev
						return true
					}
				}
				return false
			}},
		{"twins in a cycle", .Bad_Twin, proc(c: ^Craft) -> bool {
				x, y := -1, -1
				for &sl, i in c.slots {
					if sl.level == 0xFD && c.slots[sl.prev].level <= 30 {
						if x < 0 {x = i} else if c.slots[x].prev != sl.prev {y = i; break}
					}
				}
				if y < 0 {return false}
				for &sl in c.slots {
					if sl.level == 0xFD && (sl.prev == u32(x) || sl.prev == u32(y)) {return false}
				}
				c.slots[x].prev = u32(y)
				c.slots[y].prev = u32(x)
				return true
			}},
		{"twins without their table", .Bad_Twin, proc(c: ^Craft) -> bool {c.flags &~= 0x04; return true}},
	}
	q8_cases := []Craft_Case {
		{"int8 code reserved", .Bad_Element, proc(c: ^Craft) -> bool {c.elements[0].vector[0] = 0x80; return true}},
		{"negative range", .Bad_Element, proc(c: ^Craft) -> bool {c.elements[0].range = 0xBF80_0000; return true}},
	}
	bin_cases := []Craft_Case{{"binary padding", .Bad_Element, proc(c: ^Craft) -> bool {c.elements[0].vector[7] |= 0x80; return true}}}
	for k in header_cases {
		craft_expect(t, q8, k)
	}
	for k in free_cases {
		craft_expect(t, q8, k)
		craft_expect(t, f, k)
	}
	for k in graph_cases {
		craft_expect(t, q8, k)
		craft_expect(t, bin, k)
	}
	for k in twin_cases {
		craft_expect(t, bin, k)
	}
	for k in q8_cases {
		craft_expect(t, q8, k)
	}
	for k in bin_cases {
		craft_expect(t, bin, k)
	}
	flat_cases := []Craft_Case {
		{"flat payload with a generator state", .Bad_Header, proc(c: ^Craft) -> bool {c.rng = 1; return true}},
		{"flat payload with a twin table", .Bad_Header, proc(c: ^Craft) -> bool {c.flags |= 0x04; return true}},
	}
	flat := craft_flat(q8)
	defer craft_destroy(&flat)
	for k in flat_cases {
		c := craft_copy(&flat)
		defer craft_destroy(&c)
		testing.expect(t, k.mutate(&c))
		data := craft_emit(&c)
		s, err := deserialize(data)
		if s != nil {
			destroy(s)
		}
		testing.expectf(t, err == k.want, "%s: decoded with %v, wanted %v", k.name, err, k.want)
		delete(data)
	}
	data := craft_emit(&flat)
	s, err := deserialize(data, &sc, 99)
	testing.expectf(t, err == .None, "a valid flat payload decodes, got %v", err)
	if s != nil {
		testing.expect_value(t, s.count, int(flat.count))
		testing.expect(t, check_invariants(t, s))
		destroy(s)
	}
	delete(data)
}

craft_flat :: proc(s: Vset) -> Craft {
	c := craft_of(s)
	for &sl in c.slots {
		for &l in sl.lists {
			delete(l)
		}
		delete(sl.lists)
	}
	clear(&c.slots)
	clear(&c.free)
	for &e, i in c.elements {
		e.slot = u32(i)
		e.seq = u64(i + 1)
	}
	c.mode = 1
	c.rng = 0
	c.flags = 0
	c.slot_high = c.count
	c.arena_cap = c.count
	c.node_uid = c.count
	c.width = craft_width(c.slot_high)
	return c
}

craft_copy :: proc(c: ^Craft) -> Craft {
	data := craft_emit(c)
	defer delete(data)
	return craft_parse(data)
}

@(test)
graph_payload_refuses_every_truncation :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	s := g_build(t, G_Shape{.BIN, 8, 4, 120, 0}, 0x61, &sc)
	defer destroy(s)
	blob := g_bytes(s)
	defer delete(blob)
	for cut in 0 ..< len(blob) {
		back, err := deserialize(blob[:cut], &sc)
		if back != nil {
			destroy(back)
		}
		testing.expectf(t, err != .None, "a prefix of %d of %d bytes was accepted", cut, len(blob))
	}
	c := craft_parse(blob)
	defer craft_destroy(&c)
	ends := craft_sections(&c)
	defer delete(ends)
	for at in ends {
		if at >= len(blob) {
			continue
		}
		_, err := deserialize(blob[:at], &sc)
		testing.expectf(t, err == .Truncated, "a cut at the section boundary %d gave %v", at, err)
	}
}

craft_sections :: proc(c: ^Craft) -> [dynamic]int {
	out: [dynamic]int
	probe := c^
	probe.free = {}
	probe.elements = {}
	probe.slots = {}
	probe.pad = {}
	probe.tail = {}
	head := craft_emit(&probe)
	n := len(head) - 1
	delete(head)
	append(&out, n)
	n += len(c.free) * c.width
	append(&out, n)
	stride := craft_stride(c.quant, c.dim)
	for &e in c.elements {
		n += c.width + varint_size(e.seq) + varint_size(u64(len(e.name))) + len(e.name) + stride + 4 + (4 if c.quant == 0 else 0) + varint_size(u64(e.attr + 1)) + max(e.attr, 0)
	}
	append(&out, n)
	return out
}

@(test)
graph_payload_reservation_rule :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	s := g_build(t, G_Shape{.NOQUANT, 512, 32, 40, 0}, 0x71, &sc)
	defer destroy(s)
	c := craft_of(s)
	defer craft_destroy(&c)
	extra := 1500
	start := u32(c.slot_high)
	for i in 0 ..< extra {
		append(&c.free, start + u32(i))
		append(&c.slots, C_Slot{level = 0xFF})
	}
	c.slot_high += u64(extra)
	c.width = craft_width(c.slot_high)
	c.arena_cap = c.slot_high
	c.graph_cap = c.slot_high
	clear(&c.pad)
	data := craft_emit(&c)
	back, err := deserialize(data, &sc)
	testing.expectf(t, err == .Too_Large, "free slots that cost a few bytes each and a full row in memory are refused, got %v", err)
	if back != nil {
		destroy(back)
	}
	delete(data)
	sh: Shape
	d := Decoder{data = craft_emit(&c)}
	defer delete(d.data)
	shape_read(&d, &sh)
	plan := Plan{shape = sh}
	base := len(d.data) - 1
	plan_close(&plan, base)
	testing.expect(t, plan.pad > 0, "the writer pads such a state")
	resize(&c.pad, plan.pad)
	padded := craft_emit(&c)
	defer delete(padded)
	testing.expect_value(t, len(padded), plan.size)
	back, err = deserialize(padded, &sc)
	testing.expectf(t, err == .None, "the padded payload is admitted, got %v", err)
	if back != nil {
		testing.expect_value(t, int(back.arena.high), int(c.slot_high))
		again := g_bytes(back)
		testing.expect(t, string(again) == string(padded), "the writer pads the reloaded state the same way")
		delete(again)
		destroy(back)
	}
	free_all(context.temp_allocator)
	_ = fmt.tprintf
}

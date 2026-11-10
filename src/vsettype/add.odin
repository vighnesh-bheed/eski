package vsettype

import "base:intrinsics"
import "../hnsw"
import "../rax"
import "../vfilter"
import "../vmath"

Add_Request :: struct {
	name:     []u8,
	vector:   []f32,
	quant:    Quant,
	reduce:   int,
	m:        int,
	ef:       int,
	attr:     []u8,
	set_attr: bool,
	seed:     u64,
}

request_m :: #force_inline proc "contextless" (req: ^Add_Request) -> int {
	return req.m if req.m > 0 else M_DEFAULT
}

request_ef :: #force_inline proc "contextless" (req: ^Add_Request) -> int {
	return req.ef if req.ef > 0 else EF_DEFAULT
}

request_params :: proc "contextless" (req: ^Add_Request) -> (p: Params, ok: bool) {
	n := len(req.vector)
	p.quant = req.quant
	p.m = request_m(req)
	p.seed = req.seed
	if req.reduce > 0 {
		if req.reduce > n {
			return p, false
		}
		p.dim = req.reduce
		p.input_dim = n
	} else {
		p.dim = n
	}
	return p, params_valid(p) && req.ef >= 0 && request_ef(req) <= EF_MAX
}

create_for :: proc(req: ^Add_Request) -> (s: Vset, f: Failure) {
	p, ok := request_params(req)
	if !ok {
		return nil, failure(.Invalid_Parameter)
	}
	err: Error
	s, err = create(p)
	return s, failure(err)
}

check_add :: proc "contextless" (s: Vset, req: ^Add_Request) -> Failure {
	n := len(req.vector)
	if quant_elem(req.quant) != s.quant {
		return failure(.Quantization_Mismatch)
	}
	if request_m(req) != s.graph.m {
		return failure(.M_Mismatch)
	}
	if s.input_dim > 0 {
		if req.reduce != s.dim {
			return failure(.Dimension_Mismatch, n, s.dim)
		}
		if n != s.input_dim {
			return failure(.Projection_Input_Mismatch, n, s.input_dim)
		}
	} else if n != s.dim {
		return failure(.Dimension_Mismatch, n, s.dim)
	} else if req.reduce > 0 {
		return failure(.Projection_Not_Allowed)
	}
	if request_ef(req) > EF_MAX || req.ef < 0 || len(req.name) > NAME_MAX {
		return failure(.Invalid_Parameter)
	}
	return {}
}

project :: proc "contextless" (x: []f32, input: int, output: int, out: []f32) #no_bounds_check {
	scale := vmath.hadamard_scale(input)
	for j in 0 ..< output {
		acc: f32
		for i in 0 ..< input {
			acc = acc + vmath.hadamard_entry(j, i, scale) * x[i]
		}
		out[j] = acc
	}
}

stored_vector :: proc(s: Vset, vector: []f32, sc: ^Scratch) -> ([]f32, bool) {
	if s.input_dim == 0 {
		return vector, true
	}
	out, ok := scratch_floats(sc, s.dim)
	if !ok {
		return nil, false
	}
	project(vector, s.input_dim, s.dim, out)
	return out, true
}

insert_node :: proc(s: Vset, slot: u32, ef: int, sc: ^Scratch, cache: ^Distance_Cache = nil) -> Error {
	probe := Cache_Probe{aq = vmath.Arena_Query{arena = &s.arena, query = vmath.query_slot(&s.arena, slot)}, cache = cache}
	query: hnsw.Query_Proc = vmath.arena_query_hook
	batch: hnsw.Batch_Query_Proc = vmath.arena_batch_hook
	ctx: rawptr = &probe.aq
	if cache != nil {
		query = cached_query
		batch = cached_batch
		ctx = &probe
	}
	err := hnsw.insert(&s.graph, &sc.graph, slot, ef, query, ctx, batch)
	if err != .None && !hnsw.is_live(&s.graph, slot) {
		hnsw.release(&s.graph, slot)
		return .Out_Of_Memory
	}
	return .None
}

copy_name :: proc(s: Vset, name: []u8) -> (p: [^]u8, ok: bool) {
	if len(name) == 0 {
		return nil, true
	}
	q := block_alloc(&s.ledger, len(name), 1, false)
	if q == nil {
		return nil, false
	}
	intrinsics.mem_copy_non_overlapping(q, raw_data(name), len(name))
	return ([^]u8)(q), true
}

make_attribute :: proc(s: Vset, text: []u8, keep_empty := false) -> (a: vfilter.Attribute, ok: bool) {
	if len(text) == 0 && !keep_empty {
		return {}, true
	}
	attr, err := vfilter.attribute_make(string(text), allocator_of(s))
	if err != nil {
		return {}, false
	}
	return attr, true
}

replace_attribute :: proc(s: Vset, e: ^Element, a: vfilter.Attribute) {
	if e.attr.blob != nil {
		vfilter.attribute_destroy(&e.attr, allocator_of(s))
		s.attributes -= 1
	}
	e.attr = a
	if a.blob != nil {
		s.attributes += 1
	}
}

insert_element :: proc(s: Vset, name: []u8, vector: []f32, attr: vfilter.Attribute, ef: int, sc: ^Scratch, cache: ^Distance_Cache = nil) -> (slot: u32, f: Failure) {
	if err := ensure_slot(s); err != .None {
		return NIL_SLOT, failure(err)
	}
	name_copy, named := copy_name(s, name)
	if !named {
		return NIL_SLOT, failure(.Out_Of_Memory)
	}
	aslot, aerr := vmath.arena_alloc(&s.arena)
	if aerr != nil {
		block_free(&s.ledger, name_copy)
		return NIL_SLOT, failure(.Out_Of_Memory)
	}
	gslot, gerr := hnsw.reserve(&s.graph)
	if gerr != .None || gslot != aslot {
		if gerr == .None {
			hnsw.release(&s.graph, gslot)
		}
		vmath.arena_free(&s.arena, aslot)
		block_free(&s.ledger, name_copy)
		return NIL_SLOT, failure(.Out_Of_Memory)
	}
	slot = aslot
	vmath.arena_set(&s.arena, slot, vector)
	if err := insert_node(s, slot, ef, sc, cache); err != .None {
		vmath.arena_free(&s.arena, slot)
		block_free(&s.ledger, name_copy)
		return NIL_SLOT, failure(err)
	}
	e := &s.elements[slot]
	e^ = Element{name = name_copy, len = u32(len(name)), seq = s.graph.node_uid}
	replace_attribute(s, e, attr)
	rax.insert(s.names, name, rawptr(uintptr(slot) + 1))
	order_append(s, slot)
	s.version += 1
	refresh_prefetch(s)
	return slot, {}
}

drop_element :: proc(s: Vset, slot: u32) {
	vmath.arena_free(&s.arena, slot)
	e := &s.elements[slot]
	rax.remove(s.names, e.name[:e.len])
	order_remove(s, slot)
	element_release(s, e)
	s.version += 1
}

graph_remove :: proc(s: Vset, slot: u32, sc: ^Scratch) -> Error {
	hnsw.remove(&s.graph, &sc.graph, slot)
	if hnsw.is_live(&s.graph, slot) {
		return .Out_Of_Memory
	}
	return .None
}

update_element :: proc(s: Vset, slot: u32, vector: []f32, ef: int, sc: ^Scratch, cache: ^Distance_Cache = nil) -> Failure {
	if err := graph_remove(s, slot, sc); err != .None {
		return failure(err)
	}
	s.version += 1
	vmath.arena_set(&s.arena, slot, vector)
	gslot, gerr := hnsw.reserve(&s.graph)
	if gerr != .None || gslot != slot {
		if gerr == .None {
			hnsw.release(&s.graph, gslot)
		}
		drop_element(s, slot)
		return failure(.Out_Of_Memory)
	}
	if err := insert_node(s, slot, ef, sc, cache); err != .None {
		drop_element(s, slot)
		return failure(err)
	}
	s.elements[slot].seq = s.graph.node_uid
	return {}
}

Scratch_Guard :: struct {
	local: Scratch,
	sc:    ^Scratch,
}

guard_begin :: proc(g: ^Scratch_Guard, sc: ^Scratch) -> ^Scratch {
	if sc != nil {
		g.sc = sc
		return sc
	}
	scratch_init(&g.local)
	g.sc = &g.local
	return g.sc
}

guard_end :: proc(g: ^Scratch_Guard) {
	if g.sc == &g.local {
		scratch_destroy(&g.local)
	}
}

add :: proc(s: Vset, req: ^Add_Request, scratch: ^Scratch = nil) -> (added: bool, f: Failure) {
	if f = check_add(s, req); f.err != .None {
		return
	}
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	vector, ok := stored_vector(s, req.vector, sc)
	if !ok {
		return false, failure(.Out_Of_Memory)
	}
	return apply_add(s, req, vector, sc, nil)
}

apply_add :: proc(s: Vset, req: ^Add_Request, vector: []f32, sc: ^Scratch, cache: ^Distance_Cache) -> (added: bool, f: Failure) {
	ef := request_ef(req)
	slot, exists := find(s, req.name)
	if exists {
		if cache != nil {
			cache_forget(cache, slot)
		}
		attr: vfilter.Attribute
		if req.set_attr {
			made: bool
			if attr, made = make_attribute(s, req.attr); !made {
				return false, failure(.Out_Of_Memory)
			}
		}
		if f = update_element(s, slot, vector, ef, sc, cache); f.err != .None {
			if attr.blob != nil {
				vfilter.attribute_destroy(&attr, allocator_of(s))
			}
			return false, f
		}
		if req.set_attr {
			replace_attribute(s, &s.elements[slot], attr)
		}
		return false, {}
	}
	attr: vfilter.Attribute
	if req.set_attr {
		made: bool
		if attr, made = make_attribute(s, req.attr, true); !made {
			return false, failure(.Out_Of_Memory)
		}
	}
	if _, f = insert_element(s, req.name, vector, attr, ef, sc, cache); f.err != .None {
		if attr.blob != nil {
			vfilter.attribute_destroy(&attr, allocator_of(s))
		}
		return false, f
	}
	return true, {}
}

remove :: proc(s: Vset, name: []u8, scratch: ^Scratch = nil) -> (removed: bool, emptied: bool, f: Failure) {
	slot, ok := find(s, name)
	if !ok {
		return false, false, {}
	}
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	if err := graph_remove(s, slot, sc); err != .None {
		return false, false, failure(err)
	}
	drop_element(s, slot)
	return true, s.count == 0, {}
}

set_attribute :: proc(s: Vset, name: []u8, text: []u8) -> (found: bool, err: Error) {
	slot, ok := find(s, name)
	if !ok {
		return false, .None
	}
	attr, made := make_attribute(s, text)
	if !made {
		return true, .Out_Of_Memory
	}
	replace_attribute(s, &s.elements[slot], attr)
	return true, .None
}

get_attribute :: proc "contextless" (s: Vset, name: []u8) -> (text: string, has: bool) {
	slot, ok := find(s, name)
	if !ok {
		return "", false
	}
	return element_attribute(s, slot)
}

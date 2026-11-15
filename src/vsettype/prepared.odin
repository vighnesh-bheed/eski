package vsettype

import "base:runtime"
import lbl "../label"

cas_plan_begin :: proc(s: Vset, req: ^Add_Request, label: lbl.Id, owner: Owner, scoped: bool, plan: ^Cas_Plan, scratch: ^Scratch, allocator: runtime.Allocator) -> (target: ^Partition, f: Failure) {
	cas_discard(plan)
	if f = check_add(s, req); f.err != .None {
		return nil, f
	}
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	plan.allocator = allocator
	plan.ready = true
	cache_init(&plan.cache, allocator)
	plan.set = s
	plan.uid = s.uid
	plan.version = s.version
	plan.request = req^
	name, nerr := make([]u8, len(req.name), allocator)
	attr, aerr := make([]u8, len(req.attr), allocator)
	input, ierr := make([]f32, len(req.vector), allocator)
	stored, serr := make([]f32, s.dim, allocator)
	plan.request.name = name
	plan.request.attr = attr
	plan.request.vector = input
	plan.stored = stored
	if nerr != nil || aerr != nil || ierr != nil || serr != nil {
		cas_discard(plan)
		return nil, failure(.Out_Of_Memory)
	}
	copy(name, req.name)
	copy(attr, req.attr)
	copy(input, req.vector)
	projected, ok := stored_vector(s, req.vector, sc)
	if !ok {
		cas_discard(plan)
		return nil, failure(.Out_Of_Memory)
	}
	copy(stored, projected)
	plan.part = PART_NONE
	if !scoped {
		if s.lab != nil {
			return nil, {}
		}
		plan.part = 0
		return &s.core, {}
	}
	plan.label = label
	plan.owner = owner
	if s.lab == nil {
		if label != lbl.BOTTOM_ID || owner != SHARED {
			return nil, {}
		}
		plan.part = 0
		return &s.core, {}
	}
	p := part_at_scope(s, label, owner)
	if p == nil || p.mode == .Flat {
		return nil, {}
	}
	full := part_full(p)
	if full == nil {
		return nil, {}
	}
	plan.part = p.id
	return full, {}
}

cas_plan_record :: proc(plan: ^Cas_Plan, target: ^Partition, scratch: ^Scratch) {
	if !plan.ready || target == nil {
		return
	}
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	cas_record(target, plan, plan.stored, request_ef(&plan.request), sc)
}

cas_cache_entries :: proc "contextless" (plan: ^Cas_Plan, target: ^Partition) -> int {
	if !plan.ready || target == nil || target.count == 0 {
		return 0
	}
	return min(saturating_mul(request_ef(&plan.request), max(target.graph.m, 1)), saturating_mul(4, target.count))
}

cas_cache_bytes :: proc "contextless" (plan: ^Cas_Plan, target: ^Partition) -> int {
	entries := cas_cache_entries(plan, target)
	if entries == 0 {
		return 0
	}
	return cache_capacity(entries) * (size_of(u32) + size_of(f32))
}

cas_plan_reserve :: proc(plan: ^Cas_Plan, target: ^Partition) -> bool {
	if !plan.ready {
		return false
	}
	entries := cas_cache_entries(plan, target)
	if entries == 0 {
		plan.cache.fixed = true
		return true
	}
	return cache_fix(&plan.cache, entries)
}

cas_plan_bytes :: proc "contextless" (plan: ^Cas_Plan) -> int {
	if !plan.ready {
		return 0
	}
	return len(plan.request.name) + len(plan.request.attr) + 4 * len(plan.request.vector) + 4 * len(plan.stored) + 8 * len(plan.cache.keys)
}

Digest_State :: struct {
	hash: u64,
}

digest_sink_write :: proc(ctx: rawptr, data: []u8) {
	d := (^Digest_State)(ctx)
	h := d.hash
	for b in data {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	d.hash = h
}

digest_mix :: proc "contextless" (d: ^Digest_State, v: u64) {
	h := d.hash
	x := v
	for _ in 0 ..< 8 {
		h = (h ~ (x & 0xff)) * 0x100000001b3
		x >>= 8
	}
	d.hash = h
}

state_digest :: proc(s: Vset) -> u64 {
	d := Digest_State{hash = 0xcbf29ce484222325}
	if s == nil {
		return d.hash
	}
	sink := Sink{ctx = &d, write = digest_sink_write}
	digest_mix(&d, s.uid)
	digest_mix(&d, s.version)
	digest_mix(&d, u64(card(s)))
	digest_mix(&d, u64(memory_usage(s)))
	if s.lab == nil {
		plan := core_plan(s)
		core_write(s, &plan, sink)
		return d.hash
	}
	lab := s.lab
	digest_mix(&d, u64(lab.sorted_len))
	for i in 0 ..< int(lab.id_high) {
		p := lab.by_id[i]
		if p == nil {
			continue
		}
		digest_mix(&d, u64(p.id))
		plan := part_plan(s, &p.head, true, 0)
		part_write(s, &p.head, &plan, sink)
	}
	if idx := lab.owners; idx != nil {
		for i in 0 ..< int(idx.part_high) {
			p := idx.parts[i]
			if p == nil {
				continue
			}
			digest_mix(&d, u64(p.id))
			digest_mix(&d, u64(p.owner))
			plan := part_plan(s, p, true, 0)
			part_write(s, p, &plan, sink)
		}
	}
	return d.hash
}

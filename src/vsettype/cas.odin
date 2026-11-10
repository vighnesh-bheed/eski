package vsettype

import "base:runtime"
import "../hnsw"
import lbl "../label"
import "../vmath"

CACHE_EMPTY :: max(u32)
CACHE_DEAD :: max(u32) - 1

Distance_Cache :: struct {
	keys:      []u32,
	values:    []f32,
	count:     int,
	used:      int,
	hits:      int,
	misses:    int,
	allocator: runtime.Allocator,
}

cache_init :: proc(c: ^Distance_Cache, allocator := context.allocator) {
	c^ = Distance_Cache{allocator = allocator}
}

cache_destroy :: proc(c: ^Distance_Cache) {
	if c.keys != nil {
		delete(c.keys, c.allocator)
		delete(c.values, c.allocator)
	}
	c.keys = nil
	c.values = nil
	c.count = 0
	c.used = 0
}

cache_clear :: proc "contextless" (c: ^Distance_Cache) {
	for &k in c.keys {
		k = CACHE_EMPTY
	}
	c.count = 0
	c.used = 0
}

cache_slot :: #force_inline proc "contextless" (c: ^Distance_Cache, key: u32) -> int {
	mask := u32(len(c.keys) - 1)
	return int((key * 0x9E3779B1) & mask)
}

cache_reserve :: proc(c: ^Distance_Cache, entries: int) -> bool {
	capacity := 64
	for capacity < 2 * entries && capacity < 1 << 20 {
		capacity *= 2
	}
	if capacity <= len(c.keys) {
		return true
	}
	return cache_resize(c, capacity)
}

cache_grow :: proc(c: ^Distance_Cache) -> bool {
	return cache_resize(c, max(64, 2 * len(c.keys)))
}

cache_resize :: proc(c: ^Distance_Cache, capacity: int) -> bool {
	keys, kerr := make([]u32, capacity, c.allocator)
	if kerr != nil {
		return false
	}
	values, verr := make([]f32, capacity, c.allocator)
	if verr != nil {
		delete(keys, c.allocator)
		return false
	}
	for &k in keys {
		k = CACHE_EMPTY
	}
	old_keys := c.keys
	old_values := c.values
	c.keys = keys
	c.values = values
	c.count = 0
	c.used = 0
	for k, i in old_keys {
		if k < CACHE_DEAD {
			cache_put(c, k, old_values[i])
		}
	}
	if old_keys != nil {
		delete(old_keys, c.allocator)
		delete(old_values, c.allocator)
	}
	return true
}

cache_put :: proc(c: ^Distance_Cache, key: u32, value: f32) {
	if key >= CACHE_DEAD {
		return
	}
	if 2 * (c.used + 1) > len(c.keys) && !cache_grow(c) {
		return
	}
	at := cache_slot(c, key)
	mask := len(c.keys) - 1
	for {
		k := c.keys[at]
		if k == key {
			c.values[at] = value
			return
		}
		if k == CACHE_EMPTY {
			c.keys[at] = key
			c.values[at] = value
			c.count += 1
			c.used += 1
			return
		}
		at = (at + 1) & mask
	}
}

cache_get :: proc "contextless" (c: ^Distance_Cache, key: u32) -> (value: f32, ok: bool) {
	if len(c.keys) == 0 {
		return 0, false
	}
	at := cache_slot(c, key)
	mask := len(c.keys) - 1
	for {
		k := c.keys[at]
		if k == key {
			return c.values[at], true
		}
		if k == CACHE_EMPTY {
			return 0, false
		}
		at = (at + 1) & mask
	}
}

cache_forget :: proc "contextless" (c: ^Distance_Cache, key: u32) {
	if len(c.keys) == 0 {
		return
	}
	at := cache_slot(c, key)
	mask := len(c.keys) - 1
	for {
		k := c.keys[at]
		if k == key {
			c.keys[at] = CACHE_DEAD
			c.count -= 1
			return
		}
		if k == CACHE_EMPTY {
			return
		}
		at = (at + 1) & mask
	}
}

Cache_Probe :: struct {
	aq:    vmath.Arena_Query,
	cache: ^Distance_Cache,
}

recording_query :: proc(ctx: rawptr, slot: u32) -> f32 {
	p := (^Cache_Probe)(ctx)
	d := vmath.arena_query_distance(p.aq.arena, p.aq.query, slot)
	cache_put(p.cache, slot, d)
	return d
}

recording_batch :: proc(ctx: rawptr, slots: []u32, out: []f32) {
	p := (^Cache_Probe)(ctx)
	vmath.arena_query_distances(p.aq.arena, &p.aq.query, slots, out)
	for slot, i in slots {
		cache_put(p.cache, slot, out[i])
	}
}

cached_query :: proc(ctx: rawptr, slot: u32) -> f32 {
	p := (^Cache_Probe)(ctx)
	if d, ok := cache_get(p.cache, slot); ok {
		p.cache.hits += 1
		return d
	}
	p.cache.misses += 1
	return vmath.arena_query_distance(p.aq.arena, p.aq.query, slot)
}

cached_batch :: proc(ctx: rawptr, slots: []u32, out: []f32) {
	p := (^Cache_Probe)(ctx)
	for slot, i in slots {
		if d, ok := cache_get(p.cache, slot); ok {
			out[i] = d
			p.cache.hits += 1
		} else {
			out[i] = vmath.arena_query_distance(p.aq.arena, p.aq.query, slot)
			p.cache.misses += 1
		}
	}
}

Cas_Plan :: struct {
	set:       Vset,
	uid:       u64,
	version:   u64,
	request:   Add_Request,
	stored:    []f32,
	cache:     Distance_Cache,
	allocator: runtime.Allocator,
	label:     lbl.Id,
	part:      u32,
	ready:     bool,
}

cas_discard :: proc(plan: ^Cas_Plan) {
	if !plan.ready {
		return
	}
	a := plan.allocator
	delete(plan.request.name, a)
	delete(plan.request.attr, a)
	delete(plan.request.vector, a)
	delete(plan.stored, a)
	cache_destroy(&plan.cache)
	plan^ = {}
}

cas_prepare :: proc(s: Vset, req: ^Add_Request, plan: ^Cas_Plan, scratch: ^Scratch = nil, allocator := context.allocator) -> Failure {
	cas_discard(plan)
	if f := check_add(s, req); f.err != .None {
		return f
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
		return failure(.Out_Of_Memory)
	}
	copy(name, req.name)
	copy(attr, req.attr)
	copy(input, req.vector)
	projected, ok := stored_vector(s, req.vector, sc)
	if !ok {
		cas_discard(plan)
		return failure(.Out_Of_Memory)
	}
	copy(stored, projected)
	plan.part = PART_NONE
	if s.lab != nil {
		return {}
	}
	plan.part = 0
	cas_record(&s.core, plan, stored, request_ef(req), sc)
	return {}
}

cas_record :: proc(p: ^Partition, plan: ^Cas_Plan, stored: []f32, ef: int, sc: ^Scratch) {
	if p.count == 0 {
		return
	}
	buf, got := scratch_query(sc, vmath.query_bytes(&p.arena))
	if !got {
		return
	}
	q, encoded := vmath.query_encode(&p.arena, stored, buf)
	if !encoded {
		return
	}
	cands, room := scratch_candidates(sc, ef)
	if !room {
		return
	}
	cache_reserve(&plan.cache, min(ef * p.graph.m, 4 * p.count))
	probe := Cache_Probe{aq = vmath.Arena_Query{arena = &p.arena, query = q}, cache = &plan.cache}
	hnsw.search(&p.graph, &sc.graph, recording_query, &probe, ef, ef, cands, recording_batch)
}

cas_commit :: proc(s: Vset, plan: ^Cas_Plan, scratch: ^Scratch = nil) -> (added: bool, f: Failure) {
	if !plan.ready {
		return false, failure(.Invalid_Parameter)
	}
	req := &plan.request
	if plan.set != s || plan.uid != s.uid {
		if f = check_add(s, req); f.err != .None {
			return false, f
		}
		cache_clear(&plan.cache)
	} else if plan.version != s.version {
		cache_clear(&plan.cache)
	}
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	stored := plan.stored
	if plan.set != s {
		projected, ok := stored_vector(s, req.vector, sc)
		if !ok {
			return false, failure(.Out_Of_Memory)
		}
		stored = projected
	}
	return apply_add(s, req, stored, sc, &plan.cache)
}

cas_prepare_at :: proc(s: Vset, a: ^Access, req: ^Add_Request, plan: ^Cas_Plan, scratch: ^Scratch = nil, allocator := context.allocator) -> Failure {
	if f := cas_prepare(s, req, plan, scratch, allocator); f.err != .None || !plan.ready {
		return f
	}
	plan.label = a.label
	plan.part = PART_NONE
	if s.lab == nil && a.label != lbl.BOTTOM_ID {
		return {}
	}
	if s.lab == nil {
		plan.part = 0
		return {}
	}
	p := part_at_label(s, a.label)
	if p == nil || p.mode == .Flat {
		return {}
	}
	plan.part = p.id
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	cas_record(p, plan, plan.stored, request_ef(req), sc)
	return {}
}

cas_commit_at :: proc(s: Vset, a: ^Access, plan: ^Cas_Plan, scratch: ^Scratch = nil) -> (ch: Change, f: Failure) {
	if !plan.ready {
		return ch, failure(.Invalid_Parameter)
	}
	req := &plan.request
	if plan.set != s || plan.uid != s.uid {
		if f = check_add(s, req); f.err != .None {
			return ch, f
		}
		cache_clear(&plan.cache)
	} else if plan.version != s.version {
		cache_clear(&plan.cache)
	}
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	stored := plan.stored
	if plan.set != s {
		projected, ok := stored_vector(s, req.vector, sc)
		if !ok {
			return ch, failure(.Out_Of_Memory)
		}
		stored = projected
	}
	part := plan.part if plan.set == s && plan.label == a.label else PART_NONE
	return apply_add_at(s, a, req, stored, sc, &plan.cache, part)
}

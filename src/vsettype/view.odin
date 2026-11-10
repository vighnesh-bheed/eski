package vsettype

import "base:runtime"
import "core:math"
import "core:slice"
import "../hnsw"
import lbl "../label"
import "../rax"
import "../vfilter"
import "../vmath"

View_Part :: struct {
	part:   ^Partition,
	shadow: []u32,
	pos:    []u32,
	base:   int,
	size:   int,
}

View :: struct {
	set:    Vset,
	access: Access,
	parts:  []View_Part,
	size:   int,
	attrs:  int,
	scope:  ^Owner_Scope,
}

Own_View :: struct {
	id:   u32,
	view: i32,
}

Shadow :: struct {
	view: u32,
	slot: u32,
	pos:  u32,
	attr: bool,
}

Named_Hit :: struct {
	score: f64,
	name:  []u8,
	seq:   u64,
	slot:  u32,
	part:  u32,
}

Links :: struct {
	refs: [dynamic]Ref,
	ends: [dynamic]int,
}

links_destroy :: proc(l: ^Links) {
	delete(l.refs)
	delete(l.ends)
	l^ = {}
}

shadow_less :: proc(a, b: Shadow) -> bool {
	if a.view != b.view {
		return a.view < b.view
	}
	return a.slot < b.slot
}

view_part_less :: #force_inline proc "contextless" (a: ^Access, x: ^View_Part, y: ^View_Part) -> bool {
	return scope_order_less(a, Scope{label = x.part.label, owner = x.part.owner}, Scope{label = y.part.label, owner = y.part.owner})
}

view_head :: #force_inline proc "contextless" (v: ^View, vp: ^View_Part) -> ^Part_Head {
	if vp.part.kind == .Compact {
		return part_by_id(v.set, vp.part.id)
	}
	return vp.part
}

view_open :: proc(s: Vset, a: ^Access, sc: ^Scratch) -> (v: View, err: Error) {
	v.set = s
	v.access = a^
	clear(&sc.view_parts)
	clear(&sc.shadows)
	clear(&sc.shadow_slots)
	clear(&sc.shadow_pos)
	if s == nil {
		return v, .None
	}
	if !access_valid(a) {
		return v, .Invalid_Parameter
	}
	if s.lab == nil {
		if s.count > 0 && sees(a, lbl.BOTTOM_ID) {
			if _, e := append(&sc.view_parts, View_Part{part = &s.core}); e != nil {
				return v, .Out_Of_Memory
			}
		}
	} else {
		lab := s.lab
		scope := owner_scope(s, a.owner) if a.owner != SHARED else nil
		v.scope = scope
		if scope != nil {
			compact := 0
			for i in 0 ..< scope.part_len {
				if p := scope.parts[i]; p.kind == .Compact && sees(a, p.label) {
					compact += 1
				}
			}
			if resize(&sc.proxies, compact) != nil {
				return v, .Out_Of_Memory
			}
		}
		for i in 0 ..< lab.sorted_len {
			p := lab.sorted[i]
			if sees(a, p.label) {
				if _, e := append(&sc.view_parts, View_Part{part = p}); e != nil {
					return v, .Out_Of_Memory
				}
			}
		}
		if scope != nil {
			k := 0
			for i in 0 ..< scope.part_len {
				p := scope.parts[i]
				if !sees(a, p.label) {
					continue
				}
				full := part_full(p)
				if full == nil {
					full = &sc.proxies[k]
					k += 1
					proxy_fill(s, full, (^Compact_Block)(p))
				}
				if _, e := append(&sc.view_parts, View_Part{part = full}); e != nil {
					return v, .Out_Of_Memory
				}
			}
		}
		parts := sc.view_parts[:]
		for i in 1 ..< len(parts) {
			x := parts[i]
			j := i
			for j > 0 && view_part_less(a, &x, &parts[j - 1]) {
				parts[j] = parts[j - 1]
				j -= 1
			}
			parts[j] = x
		}
		if len(parts) > 1 && (lab.multi_len > 0 || scope != nil) {
			if err = view_shadows(s, a, sc, scope); err != .None {
				return v, err
			}
		}
	}
	parts := sc.view_parts[:]
	base := 0
	attrs := 0
	for &vp in parts {
		vp.base = base
		vp.size = vp.part.count - len(vp.shadow)
		base += vp.size
		attrs += int(vp.part.attributes)
	}
	for sh in sc.shadows {
		if sh.attr {
			attrs -= 1
		}
	}
	v.parts = parts
	v.size = base
	v.attrs = attrs
	return v, .None
}

view_of :: proc "contextless" (sc: ^Scratch, id: u32) -> i32 {
	if id < OWNER_PART_BASE {
		return sc.part_view[id] if int(id) < len(sc.part_view) else -1
	}
	for ov in sc.own_view {
		if ov.id == id {
			return ov.view
		}
	}
	return -1
}

shadow_copies :: proc(s: Vset, a: ^Access, sc: ^Scratch, own: []Ref, shared: []Ref) -> Error {
	visible := 0
	for r in own {
		if view_of(sc, r.part) >= 0 {
			visible += 1
		}
	}
	for r in shared {
		if view_of(sc, r.part) >= 0 {
			visible += 1
		}
	}
	if visible < 2 {
		return .None
	}
	parts := sc.view_parts[:]
	in_own, best := resolve_scoped(a, s, own, shared)
	for list, side in ([2][]Ref{own, shared}) {
		for r, i in list {
			vi := view_of(sc, r.part)
			if vi < 0 || (i == best && in_own == (side == 0)) {
				continue
			}
			p := parts[vi].part
			el := &p.elements[r.slot]
			if _, err := append(&sc.shadows, Shadow{view = u32(vi), slot = r.slot, pos = el.pos, attr = el.attr.blob != nil}); err != nil {
				return .Out_Of_Memory
			}
		}
	}
	return .None
}

owner_scan_due :: proc "contextless" (s: Vset, scope: ^Owner_Scope) -> bool {
	return scope.seen_shared != s.lab.owners.shared_gen || scope.collide
}

view_shadows :: proc(s: Vset, a: ^Access, sc: ^Scratch, scope: ^Owner_Scope) -> Error {
	lab := s.lab
	parts := sc.view_parts[:]
	if resize(&sc.part_view, int(lab.id_high)) != nil {
		return .Out_Of_Memory
	}
	for &x in sc.part_view {
		x = -1
	}
	clear(&sc.own_view)
	for vp, i in parts {
		if vp.part.owner == SHARED {
			sc.part_view[vp.part.id] = i32(i)
		} else if _, err := append(&sc.own_view, Own_View{id = vp.part.id, view = i32(i)}); err != nil {
			return .Out_Of_Memory
		}
	}
	scan := scope != nil && owner_scan_due(s, scope)
	for m in 0 ..< lab.multi_len {
		c := lab.multis[m]
		e := copies_entries(c)[:c.count]
		if scan {
			if _, mine := rax.find(scope.names, ref_name(s, e[0])); mine {
				continue
			}
		}
		if err := shadow_copies(s, a, sc, nil, e); err != .None {
			return err
		}
	}
	if scope != nil {
		if scan {
			collide := false
			it: rax.Iterator
			rax.start(&it, scope.names)
			defer rax.stop(&it)
			rax.seek(&it, "^")
			for rax.next(&it) {
				one, other: Ref
				own := name_decode(it.data, &one)
				shared := names_lookup(s, rax.key(&it), &other)
				if shared != nil {
					collide = true
				}
				if len(own) + len(shared) < 2 {
					continue
				}
				if err := shadow_copies(s, a, sc, own, shared); err != .None {
					return err
				}
			}
			scope.collide = collide
			scope.seen_shared = lab.owners.shared_gen
		} else {
			for m in 0 ..< scope.multi_len {
				c := scope.multis[m]
				if err := shadow_copies(s, a, sc, copies_entries(c)[:c.count], nil); err != .None {
					return err
				}
			}
		}
	}
	if len(sc.shadows) == 0 {
		return .None
	}
	slice.sort_by(sc.shadows[:], shadow_less)
	n := len(sc.shadows)
	if resize(&sc.shadow_slots, n) != nil || resize(&sc.shadow_pos, n) != nil {
		return .Out_Of_Memory
	}
	for sh, i in sc.shadows {
		sc.shadow_slots[i] = sh.slot
		sc.shadow_pos[i] = sh.pos
	}
	start := 0
	for start < n {
		vi := sc.shadows[start].view
		end := start
		for end < n && sc.shadows[end].view == vi {
			end += 1
		}
		parts[vi].shadow = sc.shadow_slots[start:end]
		pos := sc.shadow_pos[start:end]
		slice.sort(pos)
		parts[vi].pos = pos
		start = end
	}
	return .None
}

slot_shadowed :: proc "contextless" (shadow: []u32, slot: u32) -> bool {
	lo, hi := 0, len(shadow)
	for lo < hi {
		mid := (lo + hi) / 2
		if shadow[mid] < slot {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(shadow) && shadow[lo] == slot
}

view_part_of :: proc "contextless" (v: ^View, id: u32) -> ^View_Part {
	for &vp in v.parts {
		if vp.part.id == id {
			return &vp
		}
	}
	return nil
}

view_size :: #force_inline proc "contextless" (v: ^View) -> int {
	return v.size
}

view_exists :: #force_inline proc "contextless" (v: ^View) -> bool {
	return v.size > 0
}

view_find :: proc "contextless" (v: ^View, name: []u8) -> (r: Ref, ok: bool) {
	if v.size == 0 {
		return REF_NONE, false
	}
	one, mine: Ref
	shared := names_lookup(v.set, name, &one)
	own: []Ref
	if v.scope != nil {
		own = tree_lookup(v.scope.names, name, &mine)
	}
	if shared == nil && own == nil {
		return REF_NONE, false
	}
	in_own, i := resolve_scoped(&v.access, v.set, own, shared)
	if i < 0 {
		return REF_NONE, false
	}
	r = own[i] if in_own else shared[i]
	if view_part_of(v, r.part) == nil {
		return REF_NONE, false
	}
	return r, true
}

view_contains :: proc "contextless" (v: ^View, name: []u8) -> bool {
	_, ok := view_find(v, name)
	return ok
}

ref_name :: proc "contextless" (s: Vset, r: Ref) -> []u8 {
	return part_element_name(ref_part(s, r), r.slot)
}

ref_attribute :: proc "contextless" (s: Vset, r: Ref) -> (text: string, ok: bool) {
	return part_element_attribute(ref_part(s, r), r.slot)
}

ref_embedding :: proc "contextless" (s: Vset, r: Ref, out: []f32) -> []f32 {
	return part_embedding(ref_part(s, r), r.slot, out)
}

ref_raw_embedding :: proc "contextless" (s: Vset, r: Ref) -> Raw_Embedding {
	return part_raw_embedding(ref_part(s, r), r.slot)
}

ref_link_score :: proc "contextless" (s: Vset, a: Ref, b: Ref) -> f32 {
	return part_link_score(ref_part(s, a), a.slot, b.slot)
}

hit_ref :: #force_inline proc "contextless" (h: Hit) -> Ref {
	return Ref{slot = h.slot, part = h.part}
}

hit_name :: proc "contextless" (s: Vset, h: Hit) -> []u8 {
	return part_element_name(part_by_id(s, h.part), h.slot)
}

hit_attribute :: proc "contextless" (s: Vset, h: Hit) -> (text: string, ok: bool) {
	return part_element_attribute(part_by_id(s, h.part), h.slot)
}

view_get_attribute :: proc "contextless" (v: ^View, name: []u8) -> (text: string, has: bool) {
	r, ok := view_find(v, name)
	if !ok {
		return "", false
	}
	return ref_attribute(v.set, r)
}

named_better :: proc(a, b: Named_Hit) -> bool {
	an := math.is_nan(a.score)
	bn := math.is_nan(b.score)
	if an != bn {
		return bn
	}
	if !an && a.score != b.score {
		return a.score > b.score
	}
	if c := lex_compare(a.name, b.name); c != 0 {
		return c < 0
	}
	if a.part != b.part {
		return a.part < b.part
	}
	return a.slot < b.slot
}

named_worse :: #force_inline proc(a, b: Named_Hit) -> bool {
	return named_better(b, a)
}

named_push_bounded :: proc(h: ^[dynamic]Named_Hit, x: Named_Hit, k: int) {
	if len(h) < k {
		append(h, x)
		i := len(h) - 1
		for i > 0 {
			parent := (i - 1) / 2
			if !named_worse(h[i], h[parent]) {
				break
			}
			h[i], h[parent] = h[parent], h[i]
			i = parent
		}
		return
	}
	if !named_better(x, h[0]) {
		return
	}
	h[0] = x
	n := len(h)
	i := 0
	for {
		l := 2 * i + 1
		if l >= n {
			break
		}
		w := l
		if l + 1 < n && named_worse(h[l + 1], h[l]) {
			w = l + 1
		}
		if !named_worse(h[w], h[i]) {
			break
		}
		h[i], h[w] = h[w], h[i]
		i = w
	}
}

named_hit :: #force_inline proc "contextless" (p: ^Part_Head, score: f64, slot: u32) -> Named_Hit {
	e := &p.elements[slot]
	return Named_Hit{score = score, name = e.name[:e.len], seq = e.seq, slot = slot, part = p.id}
}

view_accept_hook :: proc(ctx: rawptr, slot: u32) -> bool {
	c := (^Accept_Context)(ctx)
	if len(c.shadow) > 0 && slot_shadowed(c.shadow, slot) {
		return false
	}
	if c.filter != nil {
		return filter_accept(c.filter, &c.part.elements[slot].attr)
	}
	return true
}

named_scan :: proc(p: ^Part_Head, q: vmath.Query, k: int, accept: ^Accept_Context, sc: ^Scratch) -> Failure {
	heap := &sc.named_heap
	clear(heap)
	if reserve(heap, k) != nil {
		return failure(.Out_Of_Memory)
	}
	for i in 0 ..< p.count {
		slot := p.order[i]
		if accept != nil && !view_accept_hook(accept, slot) {
			continue
		}
		named_push_bounded(heap, named_hit(p, vmath.arena_query_score(&p.arena, q, slot), slot), k)
	}
	if reserve(&sc.named, len(sc.named) + len(heap)) != nil {
		return failure(.Out_Of_Memory)
	}
	append(&sc.named, ..heap[:])
	clear(heap)
	return {}
}

view_query :: proc(v: ^View, req: ^Search_Request, sc: ^Scratch) -> (q: vmath.Query, f: Failure) {
	s := v.set
	if len(v.parts) == 0 {
		return {}, failure(.Element_Not_Found if req.kind == .Element else .None)
	}
	arena := &v.parts[0].part.arena
	buf, got := scratch_query(sc, vmath.query_bytes(arena))
	if !got {
		return {}, failure(.Out_Of_Memory)
	}
	ok: bool
	switch req.kind {
	case .Element:
		r, found := view_find(v, req.element)
		if !found {
			return {}, failure(.Element_Not_Found)
		}
		tmp, made := scratch_floats(sc, s.dim)
		if !made {
			return {}, failure(.Out_Of_Memory)
		}
		q, ok = vmath.query_rebuild(&ref_part(s, r).arena, r.slot, tmp, buf)
	case .Vector:
		n := len(req.vector)
		if n == s.dim {
			q, ok = vmath.query_encode(arena, req.vector, buf)
		} else if s.input_dim > 0 {
			if n != s.input_dim {
				return {}, failure(.Projection_Input_Mismatch, n, s.input_dim)
			}
			tmp, made := scratch_floats(sc, s.dim)
			if !made {
				return {}, failure(.Out_Of_Memory)
			}
			project(req.vector, s.input_dim, s.dim, tmp)
			q, ok = vmath.query_encode(arena, tmp, buf)
		} else {
			return {}, failure(.Dimension_Mismatch, n, s.dim)
		}
	}
	if !ok {
		return {}, failure(.Out_Of_Memory)
	}
	return q, {}
}

view_search :: proc(v: ^View, req: ^Search_Request, scratch: ^Scratch, out: ^[dynamic]Hit) -> Failure {
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	if v.size == 0 {
		if req.kind == .Element {
			return failure(.Element_Not_Found)
		}
		return {}
	}
	q, f := view_query(v, req, sc)
	if f.err != .None {
		return f
	}
	filter: Filter
	defer filter_destroy(&filter, sc)
	filtered := false
	if req.use_filter {
		if f = filter_compile(&filter, req.filter, sc); f.err != .None {
			return f
		}
		filtered = true
	}
	count := req.count if req.count > 0 else COUNT_DEFAULT
	clear(&sc.named)
	if !(filtered && filter_never(&filter)) {
		for &vp in v.parts {
			p := vp.part
			k := min(count, p.count)
			if k == 0 {
				continue
			}
			actx := Accept_Context{part = p, filter = &filter if filtered else nil, shadow = vp.shadow}
			accept: ^Accept_Context
			if filtered || len(vp.shadow) > 0 {
				accept = &actx
			}
			if req.truth || p.mode == .Flat {
				if f = named_scan(p, q, k, accept, sc); f.err != .None {
					return f
				}
				continue
			}
			budget := 0
			if filtered {
				budget = req.filter_ef if req.filter_ef > 0 else saturating_mul(count, FILTER_EF_FACTOR)
			}
			n: int
			if n, f = part_graph_candidates(p, q, k, req.ef, accept, view_accept_hook, budget, sc); f.err != .None {
				return f
			}
			if reserve(&sc.named, len(sc.named) + n) != nil {
				return failure(.Out_Of_Memory)
			}
			for c in sc.candidates[:n] {
				append(&sc.named, named_hit(p, vmath.arena_query_score(&p.arena, q, c.id), c.id))
			}
		}
	}
	slice.sort_by(sc.named[:], named_better)
	n := min(len(sc.named), count)
	floor := 1 - req.epsilon
	start := len(out)
	if reserve(out, start + n) != nil {
		return failure(.Out_Of_Memory)
	}
	for h in sc.named[:n] {
		if req.use_epsilon && !(h.score >= floor) {
			continue
		}
		append(out, Hit{score = h.score, seq = h.seq, slot = h.slot, part = h.part})
	}
	clear(&sc.named)
	return {}
}

view_info :: proc "contextless" (v: ^View) -> Info {
	s := v.set
	info := Info {
		quant = elem_quant(s.arena.elem),
		m = s.graph.m,
		dim = s.dim,
		projection_input_dim = s.input_dim,
		size = v.size,
		attributes_count = v.attrs,
	}
	for vp in v.parts {
		info.max_level = max(info.max_level, vp.part.graph.max_level)
		info.max_node_uid += vp.part.graph.node_uid
	}
	return info
}

range_seek :: proc "contextless" (it: ^rax.Iterator, start: Lex_Bound) {
	switch start.kind {
	case .Min, .Max:
		rax.seek(it, "^")
	case .Inclusive:
		rax.seek(it, ">=", start.value)
	case .Exclusive:
		rax.seek(it, ">", start.value)
	}
}

range_past :: proc "contextless" (key: []u8, end: Lex_Bound) -> bool {
	#partial switch end.kind {
	case .Inclusive:
		return lex_compare(key, end.value) > 0
	case .Exclusive:
		return lex_compare(key, end.value) >= 0
	}
	return false
}

view_range :: proc(v: ^View, start: Lex_Bound, end: Lex_Bound, count: int, out: ^[dynamic]Ref) {
	s := v.set
	if v.size == 0 || count == 0 || start.kind == .Max || end.kind == .Min {
		return
	}
	if v.scope != nil {
		view_range_scoped(v, start, end, count, out)
		return
	}
	it: rax.Iterator
	rax.start(&it, s.names)
	defer rax.stop(&it)
	range_seek(&it, start)
	taken := 0
	for rax.next(&it) {
		key := rax.key(&it)
		if range_past(key, end) {
			return
		}
		one: Ref
		copies := name_decode(it.data, &one)
		i := resolve(&v.access, s, copies)
		if i < 0 || view_part_of(v, copies[i].part) == nil {
			continue
		}
		append(out, copies[i])
		taken += 1
		if count > 0 && taken >= count {
			return
		}
	}
}

view_range_scoped :: proc(v: ^View, start: Lex_Bound, end: Lex_Bound, count: int, out: ^[dynamic]Ref) {
	s := v.set
	shared, own: rax.Iterator
	rax.start(&shared, s.names)
	defer rax.stop(&shared)
	rax.start(&own, v.scope.names)
	defer rax.stop(&own)
	range_seek(&shared, start)
	range_seek(&own, start)
	has_shared := rax.next(&shared)
	has_own := rax.next(&own)
	taken := 0
	for has_shared || has_own {
		order := 0
		if has_shared && has_own {
			order = lex_compare(rax.key(&shared), rax.key(&own))
		} else if has_own {
			order = 1
		} else {
			order = -1
		}
		key := rax.key(&shared) if order <= 0 else rax.key(&own)
		if range_past(key, end) {
			return
		}
		one, mine: Ref
		sc: []Ref
		oc: []Ref
		if order <= 0 {
			sc = name_decode(shared.data, &one)
		}
		if order >= 0 {
			oc = name_decode(own.data, &mine)
		}
		in_own, i := resolve_scoped(&v.access, s, oc, sc)
		if i >= 0 {
			r := oc[i] if in_own else sc[i]
			if view_part_of(v, r.part) != nil {
				append(out, r)
				taken += 1
				if count > 0 && taken >= count {
					return
				}
			}
		}
		if order <= 0 {
			has_shared = rax.next(&shared)
		}
		if order >= 0 {
			has_own = rax.next(&own)
		}
	}
}

view_ref_at :: proc "contextless" (v: ^View, j: int) -> Ref {
	lo, hi := 0, len(v.parts)
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if v.parts[mid].base <= j {
			lo = mid
		} else {
			hi = mid
		}
	}
	vp := &v.parts[lo]
	x := j - vp.base
	for sp in vp.pos {
		if int(sp) <= x {
			x += 1
		} else {
			break
		}
	}
	return Ref{slot = vp.part.order[x], part = vp.part.id}
}

view_stream :: proc(v: ^View) -> ^u64 {
	return access_stream(&v.access)
}

view_random_member :: proc(v: ^View) -> (r: Ref, ok: bool) {
	if v.size == 0 {
		return REF_NONE, false
	}
	st := view_stream(v)
	if st == nil {
		return REF_NONE, false
	}
	return view_ref_at(v, int(stream_below(st, u64(v.size)))), true
}

view_random_repeats :: proc(v: ^View, count: int, out: ^[dynamic]Ref) {
	if v.size == 0 || count <= 0 {
		return
	}
	st := view_stream(v)
	if st == nil {
		return
	}
	reserve(out, len(out) + count)
	for _ in 0 ..< count {
		append(out, view_ref_at(v, int(stream_below(st, u64(v.size)))))
	}
}

shuffle_refs :: proc "contextless" (st: ^u64, refs: []Ref) {
	for i := len(refs) - 1; i > 0; i -= 1 {
		j := int(stream_below(st, u64(i + 1)))
		refs[i], refs[j] = refs[j], refs[i]
	}
}

view_random_distinct :: proc(v: ^View, count: int, out: ^[dynamic]Ref, allocator := context.temp_allocator) -> runtime.Allocator_Error {
	if v.size == 0 || count <= 0 {
		return nil
	}
	st := view_stream(v)
	if st == nil {
		return nil
	}
	n := v.size
	start := len(out)
	if count >= n {
		reserve(out, start + n) or_return
		for j in 0 ..< n {
			append(out, view_ref_at(v, j))
		}
		shuffle_refs(st, out[start:])
		return nil
	}
	if count * 4 <= n {
		capacity := 16
		for capacity < 2 * count {
			capacity *= 2
		}
		keys := make([]u32, capacity, allocator) or_return
		defer delete(keys, allocator)
		for &k in keys {
			k = max(u32)
		}
		picks := Pick_Set{keys = keys, mask = u32(capacity - 1)}
		reserve(out, start + count) or_return
		for j := n - count; j < n; j += 1 {
			t := u32(stream_below(st, u64(j + 1)))
			if pick_insert(&picks, t) {
				append(out, view_ref_at(v, int(t)))
			} else {
				pick_insert(&picks, u32(j))
				append(out, view_ref_at(v, j))
			}
		}
		shuffle_refs(st, out[start:])
		return nil
	}
	pool := make([]u32, n, allocator) or_return
	defer delete(pool, allocator)
	for j in 0 ..< n {
		pool[j] = u32(j)
	}
	for i in 0 ..< count {
		j := i + int(stream_below(st, u64(n - i)))
		pool[i], pool[j] = pool[j], pool[i]
	}
	reserve(out, start + count) or_return
	for i in 0 ..< count {
		append(out, view_ref_at(v, int(pool[i])))
	}
	return nil
}

view_links :: proc(v: ^View, name: []u8, sc: ^Scratch, out: ^Links) -> bool {
	clear(&out.refs)
	clear(&out.ends)
	r, ok := view_find(v, name)
	if !ok {
		return false
	}
	vp := view_part_of(v, r.part)
	p := vp.part
	if p.mode == .Flat {
		heap := &sc.named_heap
		clear(heap)
		limit := max(p.graph.m0, 1)
		for i in 0 ..< p.count {
			other := p.order[i]
			if other == r.slot || slot_shadowed(vp.shadow, other) {
				continue
			}
			named_push_bounded(heap, named_hit(p, vmath.arena_score(&p.arena, r.slot, other), other), limit)
		}
		slice.sort_by(heap[:], named_better)
		for h in heap {
			append(&out.refs, Ref{slot = h.slot, part = p.id})
		}
		clear(heap)
		append(&out.ends, len(out.refs))
		return true
	}
	layers := part_link_layers(p, r.slot)
	for layer in 0 ..< layers {
		part_layer_list(p, r.slot, layer, layers, &sc.slots, &sc.links)
		for other in sc.slots {
			if !slot_shadowed(vp.shadow, other) {
				append(&out.refs, Ref{slot = other, part = p.id})
			}
		}
		append(&out.ends, len(out.refs))
	}
	clear(&sc.slots)
	return true
}

part_layer_list :: proc(p: ^Partition, slot: u32, layer: int, layers: int, out: ^[dynamic]u32, buf: ^[dynamic]u32) {
	clear(out)
	g := &p.graph
	if layer != layers - 1 {
		append(out, ..part_layer_links(p, slot, layer, buf))
		return
	}
	limit := max(g.m0, 1)
	base := slot
	if hnsw.is_twin(g, slot) {
		base = hnsw.twin_head(g, slot)
		append(out, base)
	}
	links := part_layer_links(p, base, part_link_layers(p, base) - 1, buf)
	for other in links {
		if len(out) >= limit {
			return
		}
		if other != slot {
			append(out, other)
		}
		for t := hnsw.next_twin(g, other); t != hnsw.NONE && len(out) < limit; t = hnsw.next_twin(g, t) {
			if t != slot {
				append(out, t)
			}
		}
	}
	for t := hnsw.next_twin(g, base); t != hnsw.NONE && len(out) < limit; t = hnsw.next_twin(g, t) {
		if t != slot {
			append(out, t)
		}
	}
}

view_memory :: proc "contextless" (v: ^View) -> int {
	s := v.set
	if v.access.top {
		return memory_usage(s)
	}
	if v.size == 0 {
		return 0
	}
	n := VIEW_BASE_BYTES
	for &vp in v.parts {
		n += part_footprint(s, view_head(v, &vp)) + vp.part.count * NAME_INDEX_BYTES
	}
	return n
}

part_element_encoded_size :: proc "contextless" (p: ^Part_Head, slot: u32) -> int {
	e := &p.elements[slot]
	n := varint_size(e.seq) + varint_size(u64(e.len)) + int(e.len) + p.arena.stride + 4
	if p.arena.elem == .Int8 {
		n += 4
	}
	if e.attr.blob == nil {
		return n + 1
	}
	text := vfilter.attribute_text(e.attr)
	return n + varint_size(u64(len(text)) + 1) + len(text)
}

view_serialized_size :: proc "contextless" (v: ^View) -> int {
	s := v.set
	if v.size == 0 {
		return 0
	}
	uid: u64
	for vp in v.parts {
		uid += vp.part.graph.node_uid
	}
	n := 3 + 1 + 1 + varint_size(u64(s.dim)) + varint_size(u64(s.input_dim)) + varint_size(u64(s.graph.m)) + varint_size(u64(v.size)) + varint_size(uid)
	for vp in v.parts {
		p := vp.part
		for i in 0 ..< p.count {
			slot := p.order[i]
			if len(vp.shadow) > 0 && slot_shadowed(vp.shadow, slot) {
				continue
			}
			n += part_element_encoded_size(p, slot)
		}
	}
	return n
}

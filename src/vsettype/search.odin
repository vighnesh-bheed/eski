package vsettype

import "core:math"
import "core:slice"
import "../hnsw"
import "../vfilter"
import "../vmath"

Query_Kind :: enum u8 {
	Vector,
	Element,
}

Search_Request :: struct {
	kind:        Query_Kind,
	vector:      []f32,
	element:     []u8,
	count:       int,
	ef:          int,
	epsilon:     f64,
	use_epsilon: bool,
	filter:      string,
	use_filter:  bool,
	filter_ef:   int,
	truth:       bool,
}

Hit :: struct {
	score: f64,
	seq:   u64,
	slot:  u32,
}

Filter :: struct {
	program: vfilter.Program,
	stack:   []vfilter.Value,
	result:  bool,
	deep:    bool,
	ready:   bool,
}

Accept_Context :: struct {
	s:      Vset,
	filter: ^Filter,
}

hit_better :: proc(a, b: Hit) -> bool {
	an := math.is_nan(a.score)
	bn := math.is_nan(b.score)
	if an != bn {
		return bn
	}
	if !an && a.score != b.score {
		return a.score > b.score
	}
	if a.seq != b.seq {
		return a.seq < b.seq
	}
	return a.slot < b.slot
}

make_hit :: #force_inline proc "contextless" (s: Vset, q: vmath.Query, slot: u32) -> Hit {
	return Hit{score = vmath.arena_query_score(&s.arena, q, slot), seq = s.elements[slot].seq, slot = slot}
}

build_query :: proc(s: Vset, req: ^Search_Request, sc: ^Scratch) -> (q: vmath.Query, f: Failure) {
	buf, got := scratch_query(sc, vmath.query_bytes(&s.arena))
	if !got {
		return {}, failure(.Out_Of_Memory)
	}
	ok: bool
	switch req.kind {
	case .Element:
		slot, found := find(s, req.element)
		if !found {
			return {}, failure(.Element_Not_Found)
		}
		tmp, made := scratch_floats(sc, s.dim)
		if !made {
			return {}, failure(.Out_Of_Memory)
		}
		q, ok = vmath.query_rebuild(&s.arena, slot, tmp, buf)
	case .Vector:
		n := len(req.vector)
		if n == s.dim {
			q, ok = vmath.query_encode(&s.arena, req.vector, buf)
		} else if s.input_dim > 0 {
			if n != s.input_dim {
				return {}, failure(.Projection_Input_Mismatch, n, s.input_dim)
			}
			tmp, made := scratch_floats(sc, s.dim)
			if !made {
				return {}, failure(.Out_Of_Memory)
			}
			project(req.vector, s.input_dim, s.dim, tmp)
			q, ok = vmath.query_encode(&s.arena, tmp, buf)
		} else {
			return {}, failure(.Dimension_Mismatch, n, s.dim)
		}
	}
	if !ok {
		return {}, failure(.Out_Of_Memory)
	}
	return q, {}
}

filter_compile :: proc(f: ^Filter, expression: string, sc: ^Scratch) -> Failure {
	program, near, cerr := vfilter.compile(expression, sc.allocator)
	switch cerr {
	case .None:
	case .Syntax:
		return Failure{err = .Filter_Syntax, near = near}
	case .Out_Of_Memory:
		return failure(.Out_Of_Memory)
	}
	f^ = Filter{program = program, ready = true}
	if program.depth > vfilter.STACK_INLINE {
		if resize(&sc.stack, program.depth) != nil {
			filter_destroy(f, sc)
			return failure(.Out_Of_Memory)
		}
		f.stack = sc.stack[:program.depth]
		f.deep = true
		if program.constant {
			f.result = len(program.code) > 0 && vfilter.program_execute(&f.program, nil, f.stack)
		}
	}
	return {}
}

filter_destroy :: proc(f: ^Filter, sc: ^Scratch) {
	if f.ready {
		vfilter.program_destroy(&f.program, sc.allocator)
	}
	f^ = {}
}

filter_never :: proc "contextless" (f: ^Filter) -> bool {
	if !f.program.constant {
		return false
	}
	if f.deep {
		return !f.result
	}
	return !(f.program.result && len(f.program.code) > 0)
}

filter_accept :: proc(f: ^Filter, attr: ^vfilter.Attribute) -> bool {
	if attr.blob == nil {
		return false
	}
	if !f.deep {
		return vfilter.evaluate(&f.program, attr)
	}
	if f.program.constant {
		return f.result
	}
	return vfilter.program_execute(&f.program, attr.blob, f.stack)
}

accept_hook :: proc(ctx: rawptr, slot: u32) -> bool {
	c := (^Accept_Context)(ctx)
	return filter_accept(c.filter, &c.s.elements[slot].attr)
}

hit_worse :: #force_inline proc(a, b: Hit) -> bool {
	return hit_better(b, a)
}

heap_push_bounded :: proc(h: ^[dynamic]Hit, x: Hit, k: int) {
	if len(h) < k {
		append(h, x)
		i := len(h) - 1
		for i > 0 {
			parent := (i - 1) / 2
			if !hit_worse(h[i], h[parent]) {
				break
			}
			h[i], h[parent] = h[parent], h[i]
			i = parent
		}
		return
	}
	if !hit_better(x, h[0]) {
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
		if l + 1 < n && hit_worse(h[l + 1], h[l]) {
			w = l + 1
		}
		if !hit_worse(h[w], h[i]) {
			break
		}
		h[i], h[w] = h[w], h[i]
		i = w
	}
}

exact_scan :: proc(s: Vset, q: vmath.Query, k: int, accept: ^Accept_Context, sc: ^Scratch, out: ^[dynamic]Hit) -> Failure {
	heap := &sc.hits
	clear(heap)
	if reserve(heap, k) != nil {
		return failure(.Out_Of_Memory)
	}
	for i in 0 ..< s.count {
		slot := s.order[i]
		if accept != nil && !filter_accept(accept.filter, &s.elements[slot].attr) {
			continue
		}
		heap_push_bounded(heap, make_hit(s, q, slot), k)
	}
	start := len(out)
	if reserve(out, start + len(heap)) != nil {
		return failure(.Out_Of_Memory)
	}
	append(out, ..heap[:])
	clear(heap)
	slice.sort_by(out[start:], hit_better)
	return {}
}

saturating_mul :: #force_inline proc "contextless" (a: int, b: int) -> int {
	if a > max(int) / b {
		return max(int)
	}
	return a * b
}

search :: proc(s: Vset, req: ^Search_Request, scratch: ^Scratch, out: ^[dynamic]Hit) -> Failure {
	guard: Scratch_Guard
	sc := guard_begin(&guard, scratch)
	defer guard_end(&guard)
	q, f := build_query(s, req, sc)
	if f.err != .None {
		return f
	}
	filter: Filter
	defer filter_destroy(&filter, sc)
	actx := Accept_Context{s = s, filter = &filter}
	accept: ^Accept_Context
	if req.use_filter {
		if f = filter_compile(&filter, req.filter, sc); f.err != .None {
			return f
		}
		accept = &actx
	}
	count := req.count if req.count > 0 else COUNT_DEFAULT
	k := min(count, s.count)
	start := len(out)
	if accept != nil && filter_never(&filter) {
		k = 0
	}
	if k > 0 {
		if req.truth {
			if f = exact_scan(s, q, k, accept, sc, out); f.err != .None {
				return f
			}
		} else {
			budget := req.filter_ef if req.filter_ef > 0 else saturating_mul(count, FILTER_EF_FACTOR)
			if f = graph_search(s, q, k, req.ef, accept, budget, sc, out); f.err != .None {
				return f
			}
		}
	}
	if req.use_epsilon {
		floor := 1 - req.epsilon
		w := start
		for i in start ..< len(out) {
			if out[i].score >= floor {
				out[w] = out[i]
				w += 1
			}
		}
		resize(out, w)
	}
	return {}
}

graph_search :: proc(s: Vset, q: vmath.Query, k: int, search_ef: int, accept: ^Accept_Context, budget: int, sc: ^Scratch, out: ^[dynamic]Hit) -> Failure {
	cands, ok := scratch_candidates(sc, k)
	if !ok {
		return failure(.Out_Of_Memory)
	}
	ef := search_ef if search_ef > 0 else SEARCH_EF_DEFAULT
	aq := vmath.Arena_Query{arena = &s.arena, query = q}
	n: int
	err: hnsw.Error
	if accept != nil {
		n, _, err = hnsw.search_filtered(&s.graph, &sc.graph, vmath.arena_query_hook, &aq, k, ef, accept_hook, accept, budget, cands, vmath.arena_batch_hook)
	} else {
		n, err = hnsw.search(&s.graph, &sc.graph, vmath.arena_query_hook, &aq, k, ef, cands, vmath.arena_batch_hook)
	}
	if err != .None {
		return failure(.Out_Of_Memory)
	}
	start := len(out)
	reserve(out, start + n)
	for c in cands[:n] {
		append(out, make_hit(s, q, c.id))
	}
	slice.sort_by(out[start:], hit_better)
	return {}
}

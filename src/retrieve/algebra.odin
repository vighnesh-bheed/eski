package retrieve

import "base:runtime"
import "../postings"
import "../sorted"

Strategy :: enum u8 {
	Auto,
	Leapfrog,
	Block,
}

BLOCK_RATIO :: 8

Intersection :: struct {
	using base: Cursor,
	required:   []^Cursor,
	children:   []^Cursor,
	weight:     f64,
	strategy:   Strategy,
	pending:    int,
	found:      int,
	bound:      u32,
	buffer:     [postings.BLOCK]u32,
	allocator:  runtime.Allocator,
}

sort_by_cost :: proc "contextless" (cs: []^Cursor) {
	for i in 1 ..< len(cs) {
		x := cs[i]
		j := i
		for j > 0 && cs[j - 1].cost > x.cost {
			cs[j] = cs[j - 1]
			j -= 1
		}
		cs[j] = x
	}
}

INTERSECTION_OPS := Ops {
	next = proc(c: ^Cursor) -> u32 {
		ix := (^Intersection)(c)
		if ix.doc == END {
			return END
		}
		return intersection_seek(ix, ix.doc + 1)
	},
	advance = proc(c: ^Cursor, target: u32) -> u32 {
		ix := (^Intersection)(c)
		if ix.doc != 0 && ix.doc >= target {
			return ix.doc
		}
		return intersection_seek(ix, max(target, 1))
	},
	score = proc(c: ^Cursor, s: ^Scoring) -> f64 {
		ix := (^Intersection)(c)
		total := 0.0
		have := false
		for ch in ix.children {
			if ch.doc == ix.doc {
				total = fold(s, .Intersection, have, total, score(ch, s))
				have = true
			}
		}
		return ix.weight * total
	},
}

intersection_init :: proc(ix: ^Intersection, required: []^Cursor, optional: []^Cursor = nil, weight := 1.0, strategy := Strategy.Auto, allocator := context.allocator) -> Error {
	if len(required) == 0 {
		return .Invalid_Argument
	}
	req, e1 := make([]^Cursor, len(required), allocator)
	if e1 != nil {
		return .Out_Of_Memory
	}
	all, e2 := make([]^Cursor, len(required) + len(optional), allocator)
	if e2 != nil {
		delete(req, allocator)
		return .Out_Of_Memory
	}
	copy(req, required)
	copy(all, required)
	copy(all[len(required):], optional)
	sort_by_cost(req)
	sort_by_cost(all)
	ix.base = Cursor{doc = 0, cost = req[0].cost, ops = &INTERSECTION_OPS}
	ix.required = req
	ix.children = all
	ix.weight = weight
	ix.pending = 0
	ix.found = 0
	ix.bound = 0
	ix.allocator = allocator
	ix.strategy = strategy
	if strategy == .Auto {
		ix.strategy = .Leapfrog
		if len(req) == 2 && req[0].ops.block != nil && req[1].ops.block != nil && req[1].cost <= BLOCK_RATIO * max(req[0].cost, 1) {
			ix.strategy = .Block
		}
	}
	if ix.strategy == .Block && (len(req) != 2 || req[0].ops.block == nil || req[1].ops.block == nil) {
		ix.strategy = .Leapfrog
	}
	return .None
}

intersection_destroy :: proc(ix: ^Intersection) {
	delete(ix.required, ix.allocator)
	delete(ix.children, ix.allocator)
	ix.required = nil
	ix.children = nil
}

intersection_settle :: proc(ix: ^Intersection, d: u32) -> u32 {
	ix.doc = d
	if d == END {
		return END
	}
	if len(ix.children) > len(ix.required) {
		for ch in ix.children {
			if ch.doc < d {
				advance(ch, d)
			}
		}
	}
	return d
}

intersection_seek :: proc(ix: ^Intersection, target: u32) -> u32 {
	if ix.strategy == .Block {
		return block_seek(ix, target)
	}
	r := ix.required
	candidate := advance(r[0], target)
	outer: for candidate != END {
		for i in 1 ..< len(r) {
			d := advance(r[i], candidate)
			if d != candidate {
				candidate = advance(r[0], d)
				continue outer
			}
		}
		return intersection_settle(ix, candidate)
	}
	return intersection_settle(ix, END)
}

block_seek :: proc(ix: ^Intersection, target: u32) -> u32 #no_bounds_check {
	a, b := ix.required[0], ix.required[1]
	target := target
	for {
		for ix.pending < ix.found {
			candidate := ix.buffer[ix.pending]
			ix.pending += 1
			if candidate < target {
				continue
			}
			if advance(a, candidate) != candidate {
				continue
			}
			if advance(b, candidate) != candidate {
				continue
			}
			return intersection_settle(ix, candidate)
		}
		if ix.bound != 0 {
			if ix.bound == END - 1 {
				return intersection_settle(ix, END)
			}
			target = max(target, ix.bound + 1)
		}
		da := advance(a, target)
		db := advance(b, target)
		if da == END || db == END {
			return intersection_settle(ix, END)
		}
		wa := block(a)
		wb := block(b)
		if len(wa) == 0 || len(wb) == 0 {
			return intersection_settle(ix, END)
		}
		wa = wa[:min(len(wa), len(ix.buffer))]
		wb = wb[:min(len(wb), len(ix.buffer))]
		limit := min(wa[len(wa) - 1], wb[len(wb) - 1])
		na := sorted.upper_bound(wa, limit)
		nb := sorted.upper_bound(wb, limit)
		ix.found = sorted.intersect(wa[:na], wb[:nb], ix.buffer[:])
		ix.pending = 0
		ix.bound = limit
	}
}

Union_Mode :: enum u8 {
	Sum,
	First,
}

Union :: struct {
	using base: Cursor,
	children:   []^Cursor,
	heap:       []int,
	heap_len:   int,
	matched:    []int,
	matched_len: int,
	weight:     f64,
	mode:       Union_Mode,
	started:    bool,
	allocator:  runtime.Allocator,
}

heap_less :: #force_inline proc "contextless" (u: ^Union, i, j: int) -> bool {
	di, dj := u.children[i].doc, u.children[j].doc
	return di < dj || (di == dj && i < j)
}

heap_push :: proc "contextless" (u: ^Union, child: int) #no_bounds_check {
	k := u.heap_len
	u.heap_len += 1
	for k > 0 {
		parent := (k - 1) / 2
		if !heap_less(u, child, u.heap[parent]) {
			break
		}
		u.heap[k] = u.heap[parent]
		k = parent
	}
	u.heap[k] = child
}

heap_pop :: proc "contextless" (u: ^Union) -> int #no_bounds_check {
	top := u.heap[0]
	u.heap_len -= 1
	n := u.heap_len
	if n > 0 {
		last := u.heap[n]
		k := 0
		for {
			child := 2 * k + 1
			if child >= n {
				break
			}
			if child + 1 < n && heap_less(u, u.heap[child + 1], u.heap[child]) {
				child += 1
			}
			if !heap_less(u, u.heap[child], last) {
				break
			}
			u.heap[k] = u.heap[child]
			k = child
		}
		u.heap[k] = last
	}
	return top
}

union_gather :: proc(u: ^Union) -> u32 {
	u.matched_len = 0
	if u.heap_len == 0 {
		u.doc = END
		return END
	}
	d := u.children[u.heap[0]].doc
	for u.heap_len > 0 && u.children[u.heap[0]].doc == d {
		u.matched[u.matched_len] = heap_pop(u)
		u.matched_len += 1
	}
	u.doc = d
	return d
}

union_start :: proc(u: ^Union, target: u32) -> u32 {
	u.started = true
	for ch, i in u.children {
		if advance(ch, target) != END {
			heap_push(u, i)
		}
	}
	return union_gather(u)
}

UNION_OPS := Ops {
	next = proc(c: ^Cursor) -> u32 {
		u := (^Union)(c)
		if u.doc == END {
			return END
		}
		if !u.started {
			return union_start(u, 1)
		}
		for k in 0 ..< u.matched_len {
			i := u.matched[k]
			if next(u.children[i]) != END {
				heap_push(u, i)
			}
		}
		return union_gather(u)
	},
	advance = proc(c: ^Cursor, target: u32) -> u32 {
		u := (^Union)(c)
		if u.doc != 0 && u.doc >= target {
			return u.doc
		}
		if !u.started {
			return union_start(u, max(target, 1))
		}
		for k in 0 ..< u.matched_len {
			i := u.matched[k]
			if advance(u.children[i], target) != END {
				heap_push(u, i)
			}
		}
		u.matched_len = 0
		for u.heap_len > 0 && u.children[u.heap[0]].doc < target {
			i := heap_pop(u)
			if advance(u.children[i], target) != END {
				heap_push(u, i)
			}
		}
		return union_gather(u)
	},
	score = proc(c: ^Cursor, s: ^Scoring) -> f64 {
		u := (^Union)(c)
		if u.matched_len == 0 {
			return 0
		}
		if u.mode == .First {
			return u.weight * score(u.children[u.matched[0]], s)
		}
		total := 0.0
		for k in 0 ..< u.matched_len {
			total = fold(s, .Union, k > 0, total, score(u.children[u.matched[k]], s))
		}
		return u.weight * total
	},
	positions = proc(c: ^Cursor, out: ^[dynamic]u32) -> bool {
		u := (^Union)(c)
		start := len(out)
		found := false
		for k in 0 ..< u.matched_len {
			if positions(u.children[u.matched[k]], out) {
				found = true
			}
		}
		if !found {
			return false
		}
		tail := out[start:]
		if u.matched_len > 1 {
			sort_u32(tail)
			n := 0
			for i in 0 ..< len(tail) {
				if i == 0 || tail[i] != tail[n - 1] {
					tail[n] = tail[i]
					n += 1
				}
			}
			resize(out, start + n)
		}
		return true
	},
}

sort_u32 :: proc "contextless" (a: []u32) {
	for i in 1 ..< len(a) {
		x := a[i]
		j := i
		for j > 0 && a[j - 1] > x {
			a[j] = a[j - 1]
			j -= 1
		}
		a[j] = x
	}
}

union_init :: proc(u: ^Union, children: []^Cursor, weight := 1.0, mode := Union_Mode.Sum, allocator := context.allocator) -> Error {
	n := len(children)
	kids, e1 := make([]^Cursor, n, allocator)
	if e1 != nil {
		return .Out_Of_Memory
	}
	heap, e2 := make([]int, n, allocator)
	if e2 != nil {
		delete(kids, allocator)
		return .Out_Of_Memory
	}
	matched, e3 := make([]int, n, allocator)
	if e3 != nil {
		delete(kids, allocator)
		delete(heap, allocator)
		return .Out_Of_Memory
	}
	copy(kids, children)
	total := u64(0)
	for ch in children {
		total += ch.cost
	}
	u^ = Union{children = kids, heap = heap, matched = matched, weight = weight, mode = mode, allocator = allocator}
	u.base = Cursor{doc = 0, cost = total, ops = &UNION_OPS}
	if n == 0 {
		u.doc = END
	}
	return .None
}

union_destroy :: proc(u: ^Union) {
	delete(u.children, u.allocator)
	delete(u.heap, u.allocator)
	delete(u.matched, u.allocator)
	u.children = nil
}

union_matched :: proc "contextless" (u: ^Union) -> []int {
	return u.matched[:u.matched_len]
}

Difference :: struct {
	using base: Cursor,
	include:    ^Cursor,
	exclude:    ^Cursor,
}

difference_settle :: proc(x: ^Difference, d: u32) -> u32 {
	d := d
	for d != END {
		if advance(x.exclude, d) != d {
			x.doc = d
			return d
		}
		d = next(x.include)
	}
	x.doc = END
	return END
}

DIFFERENCE_OPS := Ops {
	next = proc(c: ^Cursor) -> u32 {
		x := (^Difference)(c)
		if x.doc == END {
			return END
		}
		return difference_settle(x, next(x.include))
	},
	advance = proc(c: ^Cursor, target: u32) -> u32 {
		x := (^Difference)(c)
		if x.doc != 0 && x.doc >= target {
			return x.doc
		}
		return difference_settle(x, advance(x.include, target))
	},
	score = proc(c: ^Cursor, s: ^Scoring) -> f64 {
		x := (^Difference)(c)
		return score(x.include, s)
	},
	positions = proc(c: ^Cursor, out: ^[dynamic]u32) -> bool {
		x := (^Difference)(c)
		return positions(x.include, out)
	},
}

difference_init :: proc(x: ^Difference, include, exclude: ^Cursor) {
	x.base = Cursor{doc = 0, cost = include.cost, ops = &DIFFERENCE_OPS}
	x.include = include
	x.exclude = exclude
}

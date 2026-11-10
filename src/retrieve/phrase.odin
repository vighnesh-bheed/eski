package retrieve

import "base:runtime"
import "../sorted"

UNBOUNDED :: -1

Phrase :: struct {
	using base:  Cursor,
	terms:       []^Cursor,
	order:       []int,
	slop:        int,
	in_order:    bool,
	weight:      f64,
	conjunction: Intersection,
	lists:       [][dynamic]u32,
	views:       [][]u32,
	heads:       []int,
	allocator:   runtime.Allocator,
}

PHRASE_OPS := Ops {
	next = proc(c: ^Cursor) -> u32 {
		p := (^Phrase)(c)
		if p.doc == END {
			return END
		}
		return phrase_settle(p, next(&p.conjunction))
	},
	advance = proc(c: ^Cursor, target: u32) -> u32 {
		p := (^Phrase)(c)
		if p.doc != 0 && p.doc >= target {
			return p.doc
		}
		return phrase_settle(p, advance(&p.conjunction, target))
	},
	score = proc(c: ^Cursor, s: ^Scoring) -> f64 {
		p := (^Phrase)(c)
		total := 0.0
		for i, k in p.order {
			total = fold(s, .Phrase, k > 0, total, score(p.terms[i], s))
		}
		return p.weight * total
	},
}

phrase_init :: proc(p: ^Phrase, terms: []^Cursor, slop: int, in_order: bool, weight := 1.0, cost_order := false, allocator := context.allocator) -> Error {
	if len(terms) == 0 {
		return .Invalid_Argument
	}
	n := len(terms)
	p^ = Phrase{slop = slop, in_order = in_order, weight = weight, allocator = allocator}
	ts, e1 := make([]^Cursor, n, allocator)
	order, e2 := make([]int, n, allocator)
	lists, e3 := make([][dynamic]u32, n, allocator)
	heads, e4 := make([]int, n, allocator)
	views, e5 := make([][]u32, n, allocator)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil {
		delete(ts, allocator)
		delete(order, allocator)
		delete(lists, allocator)
		delete(heads, allocator)
		delete(views, allocator)
		return .Out_Of_Memory
	}
	copy(ts, terms)
	for i in 0 ..< n {
		order[i] = i
		lists[i] = make([dynamic]u32, 0, 8, allocator)
	}
	if cost_order {
		for i in 1 ..< n {
			x := order[i]
			j := i
			for j > 0 && ts[order[j - 1]].cost > ts[x].cost {
				order[j] = order[j - 1]
				j -= 1
			}
			order[j] = x
		}
	}
	p.terms, p.order, p.lists, p.heads, p.views = ts, order, lists, heads, views
	if e := intersection_init(&p.conjunction, terms, nil, 1, .Leapfrog, allocator); e != .None {
		phrase_destroy(p)
		return e
	}
	p.base = Cursor{doc = 0, cost = p.conjunction.cost, ops = &PHRASE_OPS}
	return .None
}

phrase_destroy :: proc(p: ^Phrase) {
	intersection_destroy(&p.conjunction)
	for &l in p.lists {
		delete(l)
	}
	delete(p.lists, p.allocator)
	delete(p.terms, p.allocator)
	delete(p.order, p.allocator)
	delete(p.heads, p.allocator)
	delete(p.views, p.allocator)
	p.terms = nil
}

phrase_settle :: proc(p: ^Phrase, d: u32) -> u32 {
	d := d
	for d != END {
		if phrase_matches(p) {
			p.doc = d
			return d
		}
		d = next(&p.conjunction)
	}
	p.doc = END
	return END
}

phrase_matches :: proc(p: ^Phrase) -> bool {
	if len(p.terms) == 1 || (p.slop < 0 && !p.in_order) {
		return true
	}
	for t, i in p.terms {
		runtime.clear(&p.lists[i])
		if !positions(t, &p.lists[i]) || len(p.lists[i]) == 0 {
			return false
		}
	}
	for i in 0 ..< len(p.lists) {
		p.views[i] = p.lists[i][:]
	}
	if p.in_order {
		return ordered_window(p.views, p.slop)
	}
	return unordered_window(p.views, p.slop, p.heads)
}

ordered_window :: proc "contextless" (lists: [][]u32, slop: int) -> bool #no_bounds_check {
	k := len(lists)
	if k == 0 {
		return false
	}
	for first in lists[0] {
		prev := first
		for i in 1 ..< k {
			j := sorted.lower_bound(lists[i], prev)
			if j == len(lists[i]) {
				return false
			}
			prev = lists[i][j]
		}
		if slop < 0 || i64(prev) - i64(first) - i64(k - 1) <= i64(slop) {
			return true
		}
	}
	return false
}

unordered_window :: proc "contextless" (lists: [][]u32, slop: int, heads: []int) -> bool #no_bounds_check {
	k := len(lists)
	if k == 0 {
		return false
	}
	if k == 1 {
		return len(lists[0]) > 0
	}
	for i in 0 ..< k {
		if len(lists[i]) == 0 {
			return false
		}
		heads[i] = 0
	}
	for {
		lo := lists[0][heads[0]]
		hi := lo
		at := 0
		for i in 1 ..< k {
			v := lists[i][heads[i]]
			if v < lo {
				lo = v
				at = i
			}
			if v > hi {
				hi = v
			}
		}
		if hi > lo && (slop < 0 || i64(hi) - i64(lo) - i64(k - 1) <= i64(slop)) {
			return true
		}
		heads[at] += 1
		if heads[at] == len(lists[at]) {
			return false
		}
	}
}

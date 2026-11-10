package retrieve

import "core:math"

Ranked :: struct {
	doc:   u32,
	score: f64,
}

Collect_Proc :: #type proc(ctx: rawptr, doc: u32, score: f64) -> Error

Threshold_Proc :: #type proc(ctx: rawptr) -> f64

Collector :: struct {
	ctx:       rawptr,
	collect:   Collect_Proc,
	threshold: Threshold_Proc,
}

Fuse_Proc :: #type proc(ctx: rawptr, branches: [][]Ranked, out: ^[dynamic]Ranked) -> Error

Fusion :: struct {
	ctx:  rawptr,
	fuse: Fuse_Proc,
}

collect :: proc(c: ^Collector, doc: u32, score: f64) -> Error {
	if c == nil || c.collect == nil {
		return .None
	}
	return c.collect(c.ctx, doc, score)
}

threshold :: proc(c: ^Collector) -> f64 {
	if c == nil || c.threshold == nil {
		return math.inf_f64(-1)
	}
	return c.threshold(c.ctx)
}

fuse :: proc(f: ^Fusion, branches: [][]Ranked, out: ^[dynamic]Ranked) -> Error {
	if f == nil || f.fuse == nil {
		return .Invalid_Argument
	}
	return f.fuse(f.ctx, branches, out)
}

rank_key :: #force_inline proc "contextless" (s: f64) -> f64 {
	if s != s {
		return math.inf_f64(-1)
	}
	return s
}

ranks_before :: #force_inline proc "contextless" (a, b: Ranked) -> bool {
	ka, kb := rank_key(a.score), rank_key(b.score)
	if ka != kb {
		return ka > kb
	}
	na, nb := a.score != a.score, b.score != b.score
	if na != nb {
		return nb
	}
	return a.doc < b.doc
}

sort_ranked :: proc "contextless" (items: []Ranked) {
	n := len(items)
	for start := n / 2 - 1; start >= 0; start -= 1 {
		sift_worst_down(items, start, n)
	}
	for end := n - 1; end > 0; end -= 1 {
		items[0], items[end] = items[end], items[0]
		sift_worst_down(items, 0, end)
	}
}

sift_worst_down :: proc "contextless" (h: []Ranked, at: int, n: int) #no_bounds_check {
	k := at
	x := h[k]
	for {
		child := 2 * k + 1
		if child >= n {
			break
		}
		if child + 1 < n && ranks_before(h[child], h[child + 1]) {
			child += 1
		}
		if !ranks_before(x, h[child]) {
			break
		}
		h[k] = h[child]
		k = child
	}
	h[k] = x
}

sift_worst_up :: proc "contextless" (h: []Ranked, at: int) #no_bounds_check {
	k := at
	x := h[k]
	for k > 0 {
		parent := (k - 1) / 2
		if !ranks_before(h[parent], x) {
			break
		}
		h[k] = h[parent]
		k = parent
	}
	h[k] = x
}

Top_K :: struct {
	heap:  [dynamic]Ranked,
	k:     int,
	total: u64,
}

top_k_init :: proc(t: ^Top_K, k: int, allocator := context.allocator) -> Error {
	t^ = Top_K{k = max(k, 0)}
	h, err := make([dynamic]Ranked, 0, min(max(k, 0), 1024), allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	t.heap = h
	return .None
}

top_k_destroy :: proc(t: ^Top_K) {
	delete(t.heap)
	t.heap = nil
}

top_k_push :: proc(t: ^Top_K, doc: u32, score: f64) -> Error {
	t.total += 1
	if t.k == 0 {
		return .None
	}
	r := Ranked{doc = doc, score = score}
	if len(t.heap) < t.k {
		if _, err := append(&t.heap, r); err != nil {
			return .Out_Of_Memory
		}
		h := t.heap[:]
		sift_worst_up(h, len(h) - 1)
		return .None
	}
	if ranks_before(r, t.heap[0]) {
		t.heap[0] = r
		sift_worst_down(t.heap[:], 0, len(t.heap))
	}
	return .None
}

top_k_threshold :: proc "contextless" (t: ^Top_K) -> f64 {
	if t.k == 0 {
		return math.inf_f64(1)
	}
	if len(t.heap) < t.k {
		return math.inf_f64(-1)
	}
	return t.heap[0].score
}

top_k_results :: proc(t: ^Top_K, out: ^[dynamic]Ranked) -> Error {
	start := len(out)
	if _, err := append(out, ..t.heap[:]); err != nil {
		return .Out_Of_Memory
	}
	sort_ranked(out[start:])
	return .None
}

top_k_collector :: proc(t: ^Top_K) -> Collector {
	return Collector {
		ctx = t,
		collect = proc(ctx: rawptr, doc: u32, score: f64) -> Error {
			return top_k_push((^Top_K)(ctx), doc, score)
		},
		threshold = proc(ctx: rawptr) -> f64 {
			return top_k_threshold((^Top_K)(ctx))
		},
	}
}

Merge_Head :: struct {
	list: int,
	at:   int,
}

merge :: proc(lists: [][]Ranked, k: int, out: ^[dynamic]Ranked, allocator := context.temp_allocator) -> Error {
	if k <= 0 {
		return .None
	}
	heads, err := make([dynamic]Merge_Head, 0, len(lists), allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	defer delete(heads)
	head_before :: proc "contextless" (lists: [][]Ranked, a, b: Merge_Head) -> bool {
		x, y := lists[a.list][a.at], lists[b.list][b.at]
		if ranks_before(x, y) {
			return true
		}
		if ranks_before(y, x) {
			return false
		}
		return a.list < b.list
	}
	push :: proc(heads: ^[dynamic]Merge_Head, lists: [][]Ranked, h: Merge_Head, before: proc "contextless" (lists: [][]Ranked, a, b: Merge_Head) -> bool) {
		append(heads, h)
		k := len(heads) - 1
		for k > 0 {
			parent := (k - 1) / 2
			if !before(lists, heads[k], heads[parent]) {
				break
			}
			heads[k], heads[parent] = heads[parent], heads[k]
			k = parent
		}
	}
	for l, i in lists {
		if len(l) > 0 {
			push(&heads, lists, Merge_Head{list = i, at = 0}, head_before)
		}
	}
	produced := 0
	for produced < k && len(heads) > 0 {
		top := heads[0]
		if _, e := append(out, lists[top.list][top.at]); e != nil {
			return .Out_Of_Memory
		}
		produced += 1
		if top.at + 1 < len(lists[top.list]) {
			heads[0].at += 1
		} else {
			heads[0] = heads[len(heads) - 1]
			pop(&heads)
		}
		n := len(heads)
		j := 0
		for {
			child := 2 * j + 1
			if child >= n {
				break
			}
			if child + 1 < n && head_before(lists, heads[child + 1], heads[child]) {
				child += 1
			}
			if !head_before(lists, heads[child], heads[j]) {
				break
			}
			heads[j], heads[child] = heads[child], heads[j]
			j = child
		}
	}
	return .None
}


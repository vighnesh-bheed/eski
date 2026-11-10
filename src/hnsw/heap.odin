package hnsw

import "base:runtime"

Candidate :: struct {
	dist: f32,
	id:   u32,
}

Min_Heap :: struct {
	items: [dynamic]Candidate,
}

Max_Heap :: struct {
	items: [dynamic]Candidate,
}

closer :: #force_inline proc "contextless" (a, b: Candidate) -> bool {
	return a.dist < b.dist || (a.dist == b.dist && a.id < b.id)
}

min_heap_init :: proc(h: ^Min_Heap, allocator: runtime.Allocator) {
	h.items = make([dynamic]Candidate, 0, 0, allocator)
}

min_heap_destroy :: proc(h: ^Min_Heap) {
	delete(h.items)
	h.items = nil
}

min_heap_clear :: #force_inline proc "contextless" (h: ^Min_Heap) {
	clear(&h.items)
}

min_heap_len :: #force_inline proc "contextless" (h: ^Min_Heap) -> int {
	return len(h.items)
}

min_heap_top :: #force_inline proc "contextless" (h: ^Min_Heap) -> Candidate {
	return h.items[0]
}

min_heap_push :: proc(h: ^Min_Heap, c: Candidate) -> bool #no_bounds_check {
	if _, err := append(&h.items, c); err != nil {
		return false
	}
	i := len(h.items) - 1
	for i > 0 {
		parent := (i - 1) / 2
		if !closer(c, h.items[parent]) {
			break
		}
		h.items[i] = h.items[parent]
		i = parent
	}
	h.items[i] = c
	return true
}

min_heap_pop :: proc "contextless" (h: ^Min_Heap) -> Candidate #no_bounds_check {
	top := h.items[0]
	n := len(h.items) - 1
	last := h.items[n]
	(^runtime.Raw_Dynamic_Array)(&h.items).len = n
	if n > 0 {
		i := 0
		for {
			child := 2 * i + 1
			if child >= n {
				break
			}
			if child + 1 < n && closer(h.items[child + 1], h.items[child]) {
				child += 1
			}
			if !closer(h.items[child], last) {
				break
			}
			h.items[i] = h.items[child]
			i = child
		}
		h.items[i] = last
	}
	return top
}

max_heap_init :: proc(h: ^Max_Heap, allocator: runtime.Allocator) {
	h.items = make([dynamic]Candidate, 0, 0, allocator)
}

max_heap_destroy :: proc(h: ^Max_Heap) {
	delete(h.items)
	h.items = nil
}

max_heap_clear :: #force_inline proc "contextless" (h: ^Max_Heap) {
	clear(&h.items)
}

max_heap_len :: #force_inline proc "contextless" (h: ^Max_Heap) -> int {
	return len(h.items)
}

max_heap_top :: #force_inline proc "contextless" (h: ^Max_Heap) -> Candidate {
	return h.items[0]
}

max_heap_push :: proc(h: ^Max_Heap, c: Candidate) -> bool #no_bounds_check {
	if _, err := append(&h.items, c); err != nil {
		return false
	}
	i := len(h.items) - 1
	for i > 0 {
		parent := (i - 1) / 2
		if !closer(h.items[parent], c) {
			break
		}
		h.items[i] = h.items[parent]
		i = parent
	}
	h.items[i] = c
	return true
}

max_heap_sift_down :: proc "contextless" (h: ^Max_Heap, c: Candidate) #no_bounds_check {
	n := len(h.items)
	i := 0
	for {
		child := 2 * i + 1
		if child >= n {
			break
		}
		if child + 1 < n && closer(h.items[child], h.items[child + 1]) {
			child += 1
		}
		if !closer(c, h.items[child]) {
			break
		}
		h.items[i] = h.items[child]
		i = child
	}
	h.items[i] = c
}

max_heap_pop :: proc "contextless" (h: ^Max_Heap) -> Candidate #no_bounds_check {
	top := h.items[0]
	n := len(h.items) - 1
	last := h.items[n]
	(^runtime.Raw_Dynamic_Array)(&h.items).len = n
	if n > 0 {
		max_heap_sift_down(h, last)
	}
	return top
}

max_heap_replace_top :: proc "contextless" (h: ^Max_Heap, c: Candidate) -> Candidate {
	top := h.items[0]
	max_heap_sift_down(h, c)
	return top
}

package hnsw

import "base:runtime"

Stamp :: u8

Visited :: struct {
	stamps:    [^]Stamp,
	cap:       int,
	epoch:     Stamp,
	allocator: runtime.Allocator,
}

visited_init :: proc(v: ^Visited, allocator: runtime.Allocator) {
	v^ = Visited{allocator = allocator}
}

visited_destroy :: proc(v: ^Visited) {
	array_free(v.stamps, v.cap, v.allocator)
	v.stamps = nil
	v.cap = 0
	v.epoch = 0
}

visited_begin :: proc(v: ^Visited, n: int) -> bool {
	if n > v.cap {
		grown := max(n, v.cap + v.cap / 2, 64)
		if !array_resize(&v.stamps, v.cap, grown, v.allocator) {
			return false
		}
		runtime.mem_zero(&v.stamps[v.cap], (grown - v.cap) * size_of(Stamp))
		v.cap = grown
	}
	if v.epoch == max(Stamp) {
		runtime.mem_zero(v.stamps, v.cap * size_of(Stamp))
		v.epoch = 0
	}
	v.epoch += 1
	return true
}

visited_mark :: #force_inline proc "contextless" (v: ^Visited, id: u32) -> bool #no_bounds_check {
	if v.stamps[id] == v.epoch {
		return false
	}
	v.stamps[id] = v.epoch
	return true
}

visited_contains :: #force_inline proc "contextless" (v: ^Visited, id: u32) -> bool #no_bounds_check {
	return v.stamps[id] == v.epoch
}

#+private
package rax

import "base:intrinsics"
import "base:runtime"

foreign import libc "system:c"

foreign libc {
	@(link_name = "malloc_usable_size")
	libc_malloc_usable_size :: proc "c" (ptr: rawptr) -> uint ---
}

usable_size :: #force_inline proc "contextless" (p: rawptr) -> int {
	if p == nil {
		return 0
	}
	return int(libc_malloc_usable_size(p))
}

account :: #force_inline proc "contextless" (r: ^Rax, delta: int) {
	r.mem += delta
	if r.shared != nil {
		r.shared^ += delta
	}
}

block_alloc :: proc "contextless" (r: ^Rax, size: int) -> [^]u8 {
	p := runtime.heap_alloc(size, false)
	if p == nil {
		intrinsics.trap()
	}
	account(r, usable_size(p))
	return cast([^]u8)p
}

block_free :: proc "contextless" (r: ^Rax, p: rawptr) {
	if p == nil {
		return
	}
	account(r, -usable_size(p))
	runtime.heap_free(p)
}

node_alloc :: proc "contextless" (r: ^Rax, size: int) -> (^Node, int) {
	p := block_alloc(r, size)
	r.nodes += 1
	return cast(^Node)p, usable_size(p)
}

node_release :: proc "contextless" (r: ^Rax, n: ^Node) {
	r.nodes -= 1
	block_free(r, n)
}

scratch_alloc :: proc "contextless" (size: int) -> [^]u8 {
	p := runtime.heap_alloc(size, false)
	if p == nil {
		intrinsics.trap()
	}
	return cast([^]u8)p
}

scratch_free :: proc "contextless" (p: rawptr) {
	if p != nil {
		runtime.heap_free(p)
	}
}

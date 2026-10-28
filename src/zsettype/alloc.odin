package zsettype

import "base:runtime"

foreign import libc "system:c"

foreign libc {
	@(link_name = "malloc_usable_size")
	_malloc_usable_size :: proc "c" (ptr: rawptr) -> uint ---
}

mem_alloc :: proc "contextless" (size: int) -> [^]u8 {
	return cast([^]u8)runtime.heap_alloc(size, false)
}

mem_alloc_zero :: proc "contextless" (size: int) -> [^]u8 {
	return cast([^]u8)runtime.heap_alloc(size)
}

mem_free :: proc "contextless" (p: rawptr) {
	if p != nil {
		runtime.heap_free(p)
	}
}

mem_usable_size :: proc "contextless" (p: rawptr) -> int {
	if p == nil {
		return 0
	}
	return int(_malloc_usable_size(p))
}

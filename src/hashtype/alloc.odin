package hashtype

import "base:runtime"

foreign import libc "system:c"

foreign libc {
	malloc_usable_size :: proc "c" (p: rawptr) -> uintptr ---
}

RAW_HEAP_ALLOCATOR :: runtime.Allocator{procedure = raw_heap_allocator_proc}

raw_heap_allocator :: proc "contextless" () -> runtime.Allocator {
	return RAW_HEAP_ALLOCATOR
}

mem_alloc :: proc "contextless" (size: int) -> [^]u8 {
	return cast([^]u8)runtime.heap_alloc(size)
}

mem_alloc_uninitialized :: proc "contextless" (size: int) -> [^]u8 {
	return cast([^]u8)runtime.heap_alloc(size, false)
}

mem_realloc :: proc "contextless" (p: [^]u8, size: int) -> [^]u8 {
	return cast([^]u8)runtime.heap_resize(p, size)
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
	return int(malloc_usable_size(p))
}

raw_heap_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	#partial switch mode {
	case .Query_Features:
		(cast(^runtime.Allocator_Mode_Set)old_memory)^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		return nil, .None
	case .Free:
		mem_free(old_memory)
		return nil, .None
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if alignment > 16 || size < 0 {
			return nil, .Invalid_Argument
		}
		if size == 0 {
			mem_free(old_memory)
			return nil, .None
		}
		p: [^]u8
		if mode == .Alloc || mode == .Alloc_Non_Zeroed {
			p = mem_alloc(size)
		} else {
			p = mem_realloc(cast([^]u8)old_memory, size)
		}
		if p == nil {
			return nil, .Out_Of_Memory
		}
		if mode == .Resize && size > old_size {
			for i in old_size ..< size {
				p[i] = 0
			}
		}
		return p[:size], .None
	case:
		return nil, .Mode_Not_Implemented
	}
}

package listpack

import "base:runtime"
import "core:mem"

foreign import raw_heap_libc "system:c"

foreign raw_heap_libc {
	@(link_name = "malloc_usable_size")
	heap_usable_bytes :: proc "c" (p: rawptr) -> uint ---
	@(link_name = "posix_memalign")
	heap_aligned_allocate :: proc "c" (p: ^rawptr, alignment, size: uint) -> i32 ---
}

RAW_HEAP_ALLOCATOR :: runtime.Allocator{procedure = raw_heap_allocator_proc}

raw_heap_allocator :: proc "contextless" () -> runtime.Allocator {
	return RAW_HEAP_ALLOCATOR
}

lp_malloc :: proc "contextless" (size: int) -> [^]u8 {
	if size <= 0 {
		return nil
	}
	return cast([^]u8)runtime.heap_alloc(size, false)
}

lp_realloc :: proc "contextless" (p: [^]u8, size: int) -> [^]u8 {
	if size < 0 {
		return nil
	}
	if size == 0 {
		runtime.heap_free(p)
		return nil
	}
	return cast([^]u8)runtime.heap_resize(p, size)
}

lp_mem_free :: proc "contextless" (p: rawptr) {
	runtime.heap_free(p)
}

lp_malloc_size :: proc "contextless" (p: rawptr) -> int {
	if p == nil {
		return 0
	}
	return int(heap_usable_bytes(p))
}

raw_allocate :: proc "contextless" (size, alignment: int, zeroed: bool) -> (rawptr, runtime.Allocator_Error) {
	if size < 0 || alignment <= 0 || alignment & (alignment - 1) != 0 {
		return nil, .Invalid_Argument
	}
	if size == 0 {
		return nil, .None
	}
	pointer: rawptr
	if alignment <= 16 {
		pointer = runtime.heap_alloc(size, zeroed)
	} else {
		if heap_aligned_allocate(&pointer, uint(alignment), uint(size)) != 0 {
			return nil, .Out_Of_Memory
		}
		if zeroed {
			mem.zero(pointer, size)
		}
	}
	if pointer == nil {
		return nil, .Out_Of_Memory
	}
	return pointer, .None
}

raw_heap_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	switch mode {
	case .Query_Features:
		if old_memory == nil {
			return nil, .Invalid_Argument
		}
		features := cast(^runtime.Allocator_Mode_Set)old_memory
		features^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Query_Features}
		return nil, .None
	case .Free:
		runtime.heap_free(old_memory)
		return nil, .None
	case .Alloc, .Alloc_Non_Zeroed:
		pointer, error := raw_allocate(size, alignment, mode == .Alloc)
		if error != .None {
			return nil, error
		}
		return (cast([^]byte)pointer)[:size], .None
	case .Resize, .Resize_Non_Zeroed:
		if size < 0 || old_size < 0 || alignment <= 0 || alignment & (alignment - 1) != 0 {
			return nil, .Invalid_Argument
		}
		if size == 0 {
			runtime.heap_free(old_memory)
			return nil, .None
		}
		if old_memory == nil {
			pointer, error := raw_allocate(size, alignment, mode == .Resize)
			if error != .None {
				return nil, error
			}
			return (cast([^]byte)pointer)[:size], .None
		}
		pointer: rawptr
		if alignment <= 16 {
			pointer = runtime.heap_resize(old_memory, size)
			if pointer == nil {
				return nil, .Out_Of_Memory
			}
			if mode == .Resize && size > old_size {
				mem.zero(mem.ptr_offset(cast([^]u8)pointer, old_size), size - old_size)
			}
		} else {
			error: runtime.Allocator_Error
			pointer, error = raw_allocate(size, alignment, mode == .Resize)
			if error != .None {
				return nil, error
			}
			mem.copy(pointer, old_memory, min(old_size, size))
			runtime.heap_free(old_memory)
		}
		return (cast([^]byte)pointer)[:size], .None
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

package bitmap

import "base:intrinsics"
import "base:runtime"

RAW_HEAP_ALLOCATOR :: runtime.Allocator{procedure = raw_heap_allocator_proc, data = nil}

GREEDY_GROWTH_LIMIT :: 1024 * 1024

RAW_HEAP_MAX_ALIGN :: 16

raw_heap_allocator :: proc "contextless" () -> runtime.Allocator {
	return RAW_HEAP_ALLOCATOR
}

raw_heap_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	if alignment > RAW_HEAP_MAX_ALIGN && (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) {
		return nil, .Invalid_Argument
	}
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size <= 0 {
			return nil, nil
		}
		p := runtime.heap_alloc(size, mode == .Alloc)
		if p == nil {
			return nil, .Out_Of_Memory
		}
		return ([^]byte)(p)[:size], nil
	case .Free:
		runtime.heap_free(old_memory)
		return nil, nil
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			if size <= 0 {
				return nil, nil
			}
			p := runtime.heap_alloc(size, mode == .Resize)
			if p == nil {
				return nil, .Out_Of_Memory
			}
			return ([^]byte)(p)[:size], nil
		}
		if size <= 0 {
			runtime.heap_free(old_memory)
			return nil, nil
		}
		p := runtime.heap_resize(old_memory, size)
		if p == nil {
			return nil, .Out_Of_Memory
		}
		if mode == .Resize && size > old_size {
			start := max(old_size, 0)
			intrinsics.mem_zero(rawptr(uintptr(p) + uintptr(start)), size - start)
		}
		return ([^]byte)(p)[:size], nil
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}

free_bytes :: proc(buf: ^[]u8, allocator := RAW_HEAP_ALLOCATOR, capacity: ^int = nil) {
	p := raw_data(buf^)
	if p != nil {
		size := len(buf^)
		if capacity != nil && capacity^ > size {
			size = capacity^
		}
		_, _ = allocator.procedure(allocator.data, .Free, 0, 0, p, size)
	}
	buf^ = nil
	if capacity != nil {
		capacity^ = 0
	}
}

growth_target :: proc "contextless" (need: int, greedy: bool) -> int {
	if !greedy {
		return need
	}
	return need + min(need, GREEDY_GROWTH_LIMIT)
}

resize_block :: proc(allocator: runtime.Allocator, base: [^]u8, old_size: int, size: int) -> ([^]u8, bool) {
	block, err := allocator.procedure(allocator.data, .Resize_Non_Zeroed, size, 1, base, old_size)
	return raw_data(block), err == nil
}

grow_zero :: proc(buf: ^[]u8, need: int, allocator := RAW_HEAP_ALLOCATOR, capacity: ^int = nil) -> Error {
	used := len(buf^)
	if need <= used {
		return .None
	}
	spare := used if capacity == nil else max(used, capacity^)
	base := raw_data(buf^)
	if need > spare {
		size := growth_target(need, capacity != nil)
		fresh, resized := resize_block(allocator, base, spare, size)
		if !resized && size > need {
			size = need
			fresh, resized = resize_block(allocator, base, spare, size)
		}
		if !resized || fresh == nil {
			return .Out_Of_Memory
		}
		base, spare = fresh, size
	}
	intrinsics.mem_zero(&base[used], need - used)
	buf^ = base[:need]
	if capacity != nil {
		capacity^ = spare
	}
	return .None
}

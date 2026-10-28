package hll

import "base:runtime"

HLL_HEAP_ALIGNMENT :: 16

hll_raw_heap_allocator :: proc() -> runtime.Allocator {
	return runtime.Allocator{procedure = raw_heap_allocator_proc, data = nil}
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
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if alignment > HLL_HEAP_ALIGNMENT {
			return nil, .Invalid_Argument
		}
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
		if alignment > HLL_HEAP_ALIGNMENT {
			return nil, .Invalid_Argument
		}
		if size <= 0 {
			runtime.heap_free(old_memory)
			return nil, nil
		}
		if old_memory == nil {
			p := runtime.heap_alloc(size, mode == .Resize)
			if p == nil {
				return nil, .Out_Of_Memory
			}
			return ([^]byte)(p)[:size], nil
		}
		p := runtime.heap_resize(old_memory, size)
		if p == nil {
			return nil, .Out_Of_Memory
		}
		if mode == .Resize && size > old_size {
			runtime.mem_zero(rawptr(uintptr(p) + uintptr(max(old_size, 0))), size - max(old_size, 0))
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

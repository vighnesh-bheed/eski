package bitmap

import "base:intrinsics"
import "base:runtime"

RAW_HEAP_ALLOCATOR :: runtime.Allocator{procedure = raw_heap_allocator_proc, data = nil}

SDS_MAX_PREALLOC :: 1024 * 1024

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

grow_zero :: proc(buf: ^[]u8, need: int, allocator := RAW_HEAP_ALLOCATOR, capacity: ^int = nil) -> Error {
	have := len(buf^)
	if need <= have {
		return .None
	}
	room := have
	if capacity != nil && capacity^ > room {
		room = capacity^
	}
	base := raw_data(buf^)
	if need > room {
		target := need
		if capacity != nil {
			target = need * 2 if need < SDS_MAX_PREALLOC else need + SDS_MAX_PREALLOC
		}
		mem, err := allocator.procedure(allocator.data, .Resize_Non_Zeroed, target, 1, base, room)
		if err != nil && target > need {
			target = need
			mem, err = allocator.procedure(allocator.data, .Resize_Non_Zeroed, target, 1, base, room)
		}
		if err != nil || raw_data(mem) == nil {
			return .Out_Of_Memory
		}
		base = raw_data(mem)
		room = target
	}
	intrinsics.mem_zero(rawptr(uintptr(base) + uintptr(have)), need - have)
	buf^ = base[:need]
	if capacity != nil {
		capacity^ = room
	}
	return .None
}

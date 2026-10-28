package listpack

import "base:runtime"
import "core:testing"

@(test)
raw_heap_memory_round_trips_runtime_primitives :: proc(t: ^testing.T) {
	pointer := lp_malloc(31)
	testing.expect(t, pointer != nil)
	if pointer == nil {
		return
	}
	testing.expect(t, lp_malloc_size(pointer) >= 31)
	for index in 0..<31 {
		pointer[index] = u8(index)
	}
	replacement := cast([^]u8)runtime.heap_resize(pointer, 67)
	testing.expect(t, replacement != nil)
	if replacement == nil {
		lp_mem_free(pointer)
		return
	}
	for index in 0..<31 {
		testing.expect(t, replacement[index] == u8(index))
	}
	testing.expect(t, lp_malloc_size(replacement) >= 67)
	runtime.heap_free(replacement)
	pointer = cast([^]u8)runtime.heap_alloc(17, false)
	testing.expect(t, pointer != nil)
	if pointer == nil {
		return
	}
	pointer[0], pointer[16] = 33, 77
	replacement = lp_realloc(pointer, 91)
	testing.expect(t, replacement != nil)
	if replacement == nil {
		runtime.heap_free(pointer)
		return
	}
	testing.expect(t, replacement[0] == 33 && replacement[16] == 77 && lp_malloc_size(replacement) >= 91)
	lp_mem_free(replacement)
	testing.expect(t, lp_malloc_size(nil) == 0 && lp_malloc(-1) == nil)
}

@(test)
raw_allocator_alignment_zeroing_resize_and_modes :: proc(t: ^testing.T) {
	features: runtime.Allocator_Mode_Set
	_, error := RAW_HEAP_ALLOCATOR.procedure(nil, .Query_Features, 0, 0, &features, 0)
	testing.expect(t, error == .None && .Resize in features && .Free in features && .Free_All not_in features)
	alignments := []int{1, 8, 16, 64, 4096}
	for alignment in alignments {
		data, alloc_error := RAW_HEAP_ALLOCATOR.procedure(nil, .Alloc, 17, alignment, nil, 0)
		testing.expect(t, alloc_error == .None && len(data) == 17)
		if alloc_error != .None || len(data) != 17 {
			continue
		}
		testing.expect(t, uintptr(raw_data(data)) % uintptr(alignment) == 0 && lp_malloc_size(raw_data(data)) >= 17)
		for byte in data {
			testing.expect(t, byte == 0)
		}
		data[0], data[16] = 33, 77
		grown, grow_error := RAW_HEAP_ALLOCATOR.procedure(nil, .Resize, 91, alignment, raw_data(data), len(data))
		testing.expect(t, grow_error == .None && len(grown) == 91)
		if grow_error != .None {
			runtime.heap_free(raw_data(data))
			continue
		}
		testing.expect(t, uintptr(raw_data(grown)) % uintptr(alignment) == 0 && grown[0] == 33 && grown[16] == 77)
		for byte in grown[17:] {
			testing.expect(t, byte == 0)
		}
		runtime.heap_free(raw_data(grown))
	}
	_, error = RAW_HEAP_ALLOCATOR.procedure(nil, .Alloc, 17, 3, nil, 0)
	testing.expect(t, error == .Invalid_Argument)
	_, error = RAW_HEAP_ALLOCATOR.procedure(nil, .Alloc, -1, 16, nil, 0)
	testing.expect(t, error == .Invalid_Argument)
	_, error = RAW_HEAP_ALLOCATOR.procedure(nil, .Free_All, 0, 0, nil, 0)
	testing.expect(t, error == .Mode_Not_Implemented)
}

@(test)
raw_allocator_invalid_resize_preserves_allocation_and_zero_size_releases :: proc(t: ^testing.T) {
	pointer := lp_malloc(23)
	testing.expect(t, pointer != nil)
	if pointer == nil {
		return
	}
	for index in 0..<23 {
		pointer[index] = u8(23 - index)
	}
	rejected := lp_realloc(pointer, -1)
	testing.expect(t, rejected == nil && lp_malloc_size(pointer) >= 23)
	invalid, error := RAW_HEAP_ALLOCATOR.procedure(nil, .Resize, 47, 3, pointer, 23)
	testing.expect(t, error == .Invalid_Argument && len(invalid) == 0)
	for index in 0..<23 {
		testing.expect(t, pointer[index] == u8(23 - index))
	}
	zero, zero_error := RAW_HEAP_ALLOCATOR.procedure(nil, .Resize, 0, 16, pointer, 23)
	testing.expect(t, zero_error == .None && len(zero) == 0)
	empty, empty_error := RAW_HEAP_ALLOCATOR.procedure(nil, .Alloc, 0, 16, nil, 0)
	testing.expect(t, empty_error == .None && len(empty) == 0)
	_, free_error := RAW_HEAP_ALLOCATOR.procedure(nil, .Free, 0, 0, nil, 0)
	testing.expect(t, free_error == .None)
}

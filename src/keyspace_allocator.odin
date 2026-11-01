package main

import "base:runtime"
import ks "keyspace"

keyspace_worker_allocator :: proc "contextless" () -> runtime.Allocator {
	return {procedure = keyspace_worker_allocator_proc, data = &keyspace_pool}
}

keyspace_worker_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	pool := cast(^ks.Pool)allocator_data
	if size < 0 || old_size < 0 || alignment > 16 { return nil, .Invalid_Argument }
	switch mode {
	case .Query_Features:
		if old_memory == nil { return nil, .Invalid_Argument }
		(cast(^runtime.Allocator_Mode_Set)old_memory)^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Query_Features}
		return nil, .None
	case .Free:
		if old_memory != nil && !ks.free(pool, (cast([^]u8)old_memory)[:old_size]) { store_fatal("keyspace allocator release invariant") }
		return nil, .None
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		bytes: []u8
		if size > 0 {
			bytes = ks.allocate(pool, size)
			if len(bytes) == 0 { return nil, .Out_Of_Memory }
			if mode == .Alloc || mode == .Resize { for &byte in bytes { byte = 0 } }
		}
		if old_memory != nil {
			copy(bytes, (cast([^]u8)old_memory)[:min(size, old_size)])
			if !ks.free(pool, (cast([^]u8)old_memory)[:old_size]) { store_fatal("keyspace allocator resize invariant") }
		}
		return bytes, .None
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

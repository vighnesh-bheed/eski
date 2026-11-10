package vsettype

import "base:intrinsics"
import "base:runtime"

foreign import libc "system:c"

foreign libc {
	@(link_name = "malloc_usable_size")
	libc_malloc_usable_size :: proc "c" (ptr: rawptr) -> uint ---
	@(link_name = "posix_memalign")
	libc_posix_memalign :: proc "c" (out: ^rawptr, alignment: uint, size: uint) -> i32 ---
}

HEAP_ALIGN :: 16

Ledger :: struct {
	bytes: int,
}

usable_size :: #force_inline proc "contextless" (p: rawptr) -> int {
	if p == nil {
		return 0
	}
	return int(libc_malloc_usable_size(p))
}

block_alloc :: proc "contextless" (l: ^Ledger, size: int, alignment: int, zero: bool) -> rawptr {
	if size <= 0 {
		return nil
	}
	p: rawptr
	if alignment <= HEAP_ALIGN {
		p = runtime.heap_alloc(size, zero)
	} else {
		if alignment & (alignment - 1) != 0 || libc_posix_memalign(&p, uint(alignment), uint(size)) != 0 {
			return nil
		}
		if zero {
			intrinsics.mem_zero(p, size)
		}
	}
	if p != nil {
		l.bytes += usable_size(p)
	}
	return p
}

block_free :: proc "contextless" (l: ^Ledger, p: rawptr) {
	if p == nil {
		return
	}
	l.bytes -= usable_size(p)
	runtime.heap_free(p)
}

block_resize :: proc "contextless" (l: ^Ledger, p: rawptr, old_size: int, size: int, alignment: int, zero: bool) -> rawptr {
	if p == nil {
		return block_alloc(l, size, alignment, zero)
	}
	if size <= 0 {
		block_free(l, p)
		return nil
	}
	q: rawptr
	if alignment <= HEAP_ALIGN {
		before := usable_size(p)
		q = runtime.heap_resize(p, size)
		if q == nil {
			return nil
		}
		l.bytes += usable_size(q) - before
	} else {
		q = block_alloc(l, size, alignment, false)
		if q == nil {
			return nil
		}
		intrinsics.mem_copy_non_overlapping(q, p, min(max(old_size, 0), size))
		block_free(l, p)
	}
	if zero && size > old_size {
		start := max(old_size, 0)
		intrinsics.mem_zero(rawptr(uintptr(q) + uintptr(start)), size - start)
	}
	return q
}

ledger_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	l := (^Ledger)(allocator_data)
	#partial switch mode {
	case .Query_Features:
		if old_memory != nil {
			(^runtime.Allocator_Mode_Set)(old_memory)^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, .None
	case .Free:
		block_free(l, old_memory)
		return nil, .None
	case .Alloc, .Alloc_Non_Zeroed:
		if size < 0 {
			return nil, .Invalid_Argument
		}
		if size == 0 {
			return nil, .None
		}
		p := block_alloc(l, size, alignment, mode == .Alloc)
		if p == nil {
			return nil, .Out_Of_Memory
		}
		return ([^]u8)(p)[:size], .None
	case .Resize, .Resize_Non_Zeroed:
		if size < 0 || old_size < 0 {
			return nil, .Invalid_Argument
		}
		if size == 0 {
			block_free(l, old_memory)
			return nil, .None
		}
		p := block_resize(l, old_memory, old_size, size, alignment, mode == .Resize)
		if p == nil {
			return nil, .Out_Of_Memory
		}
		return ([^]u8)(p)[:size], .None
	}
	return nil, .Mode_Not_Implemented
}

ledger_allocator :: proc "contextless" (l: ^Ledger) -> runtime.Allocator {
	return runtime.Allocator{procedure = ledger_allocator_proc, data = l}
}

Charge :: struct {
	bytes: int,
	root:  ^Ledger,
}

charge_alloc :: proc "contextless" (c: ^Charge, size: int, alignment: int, zero: bool) -> rawptr {
	before := c.root.bytes
	p := block_alloc(c.root, size, alignment, zero)
	c.bytes += c.root.bytes - before
	return p
}

charge_free :: proc "contextless" (c: ^Charge, p: rawptr) {
	before := c.root.bytes
	block_free(c.root, p)
	c.bytes += c.root.bytes - before
}

charge_resize :: proc "contextless" (c: ^Charge, p: rawptr, old_size: int, size: int, alignment: int, zero: bool) -> rawptr {
	before := c.root.bytes
	q := block_resize(c.root, p, old_size, size, alignment, zero)
	c.bytes += c.root.bytes - before
	return q
}

charge_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	c := (^Charge)(allocator_data)
	before := c.root.bytes
	out, err := ledger_allocator_proc(c.root, mode, size, alignment, old_memory, old_size, loc)
	c.bytes += c.root.bytes - before
	return out, err
}

charge_allocator :: proc "contextless" (c: ^Charge) -> runtime.Allocator {
	return runtime.Allocator{procedure = charge_allocator_proc, data = c}
}

part_charge :: #force_inline proc "contextless" (s: Vset, p: ^Partition) -> ^Charge {
	if s.lab == nil || p == &s.core {
		return nil
	}
	return &(^Part_Block)(p).charge
}

part_alloc :: proc "contextless" (s: Vset, p: ^Partition, size: int, alignment: int, zero: bool) -> rawptr {
	if c := part_charge(s, p); c != nil {
		return charge_alloc(c, size, alignment, zero)
	}
	return block_alloc(&s.ledger, size, alignment, zero)
}

part_free :: proc "contextless" (s: Vset, p: ^Partition, ptr: rawptr) {
	if c := part_charge(s, p); c != nil {
		charge_free(c, ptr)
		return
	}
	block_free(&s.ledger, ptr)
}

part_resize :: proc "contextless" (s: Vset, p: ^Partition, ptr: rawptr, old_size: int, size: int, alignment: int, zero: bool) -> rawptr {
	if c := part_charge(s, p); c != nil {
		return charge_resize(c, ptr, old_size, size, alignment, zero)
	}
	return block_resize(&s.ledger, ptr, old_size, size, alignment, zero)
}

part_allocator :: proc "contextless" (s: Vset, p: ^Partition) -> runtime.Allocator {
	if c := part_charge(s, p); c != nil {
		return charge_allocator(c)
	}
	return ledger_allocator(&s.ledger)
}

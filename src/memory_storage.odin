package main

import "base:intrinsics"
import "core:sys/posix"

Storage_Kind :: enum u8 {
	Table,
	Slab,
	Slab_Metadata,
}

storage_table_bytes: int
storage_table_mapped: int
storage_slab_virtual: int
storage_slab_writable: int
storage_metadata_owned: int
storage_metadata_virtual: int
storage_metadata_writable: int
storage_retired: [Storage_Kind]int
storage_dead_payload: int

storage_table_allocated :: #force_inline proc "contextless" () -> int {
	return intrinsics.atomic_load_explicit(&storage_table_bytes, .Relaxed)
}

storage_unmap :: proc "contextless" (base: [^]u8, size: int, kind: Storage_Kind, writable: bool = true) {
	if size == 0 {
		return
	}
	if posix.munmap(base, uint(size)) != .OK {
		store_fatal("cannot release storage memory")
	}
	switch kind {
	case .Table:
		intrinsics.atomic_sub_explicit(&storage_table_mapped, size, .Relaxed)
	case .Slab:
		intrinsics.atomic_sub_explicit(&storage_slab_virtual, size, .Relaxed)
		if writable {
			intrinsics.atomic_sub_explicit(&storage_slab_writable, size, .Relaxed)
		}
	case .Slab_Metadata:
		intrinsics.atomic_sub_explicit(&storage_metadata_virtual, size, .Relaxed)
		if writable {
			intrinsics.atomic_sub_explicit(&storage_metadata_writable, size, .Relaxed)
		}
	}
}

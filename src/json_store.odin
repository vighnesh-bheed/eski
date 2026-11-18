package main

import "base:intrinsics"
import "base:runtime"
import "jsondoc"

Json_Object :: struct {
	doc:   jsondoc.Document,
	bytes: int,
}

@(private = "file")
Json_Allocation :: struct {
	base: rawptr,
	size: int,
	held: int,
}

@(private = "file")
json_allocator :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	object := cast(^Json_Object)data
	switch mode {
	case .Query_Features:
		if old_memory != nil {
			(cast(^runtime.Allocator_Mode_Set)old_memory)^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Query_Features}
		}
		return nil, .None
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free:
	}

	bytes: []byte
	if mode != .Free && size > 0 {
		aligned_to := max(alignment, align_of(Json_Allocation))
		overhead := size_of(Json_Allocation) + aligned_to - 1
		if size > max(int) - overhead {
			return nil, .Out_Of_Memory
		}
		held := size + overhead
		base := runtime.heap_alloc(held, mode == .Alloc || mode == .Resize)
		if base == nil {
			return nil, .Out_Of_Memory
		}
		addr := (uintptr(base) + uintptr(overhead)) & ~uintptr(aligned_to - 1)
		header := (^Json_Allocation)(addr - size_of(Json_Allocation))
		header^ = {base, size, held}
		bytes = ([^]byte)(addr)[:size]
		object.bytes += held
	}
	if old_memory != nil {
		old := (^Json_Allocation)(uintptr(old_memory) - size_of(Json_Allocation))
		if len(bytes) != 0 {
			intrinsics.mem_copy_non_overlapping(raw_data(bytes), old_memory, min(size, old.size))
		}
		object.bytes -= old.held
		runtime.heap_free(old.base)
	}
	return bytes, .None
}

json_object_new :: proc "contextless" () -> ^Json_Object {
	object := cast(^Json_Object)runtime.heap_alloc(size_of(Json_Object))
	if object != nil {
		object.doc.allocator = {procedure = json_allocator, data = object}
		object.bytes = size_of(Json_Object)
	}
	return object
}

json_object_dup :: proc(object: ^Json_Object) -> ^Json_Object {
	next := json_object_new()
	if next == nil {
		return nil
	}
	next.doc.root = jsondoc.clone(object.doc.root, next.doc.allocator)
	if next.doc.root == nil {
		json_object_release(next)
		return nil
	}
	return next
}

json_object_release :: proc "contextless" (pointer: rawptr) -> int {
	context = runtime.default_context()
	object := cast(^Json_Object)pointer
	held := object.bytes
	jsondoc.destroy(&object.doc)
	assert(object.bytes == size_of(Json_Object))
	runtime.heap_free(object)
	return held
}

json_object_at :: #force_inline proc "contextless" (entry: ^Entry) -> ^Json_Object {
	return cast(^Json_Object)entry_object(entry, .Json) if entry != nil else nil
}

json_object_attach :: proc "contextless" (entry: ^Entry, object: ^Json_Object) {
	entry_object_attach(entry, object, .Json, .Raw, object.bytes)
	if search_active_in(entry.db) {
		search_document_changed(entry.db, key_bytes(entry.kp, &entry.db.slab), object, true)
	}
}

json_object_sync :: proc "contextless" (db: ^Db, object: ^Json_Object, previous_bytes, previous_charge: int) {
	real := object.bytes - previous_bytes
	charge := json_object_content_memory(object) - previous_charge if labels_on else real
	object_charged(db, real, charge)
}

json_object_content_memory :: proc "contextless" (object: ^Json_Object) -> int {
	return object.doc.root.charge if object.doc.root != nil else 0
}

package main

import "base:intrinsics"

Obj_Type :: enum u8 {
	String,
	List,
	Set,
	Zset,
	Hash,
	Stream,
}

Obj_Encoding :: enum u8 {
	Raw,
	Int,
	Embstr,
	Listpack,
	Hashtable,
	Intset,
	Quicklist,
	Skiplist,
	Stream,
	Listpack_Ex,
}

#assert(len(Obj_Type) <= 1 << 3)
#assert(len(Obj_Encoding) <= 1 << 4)

FORM_NONE :: 0
FORM_INLINE :: 1
FORM_SLAB :: 9
FORM_HEAP :: 10
FORM_OBJECT :: 11
INLINE_BYTES :: 7

Slot_Meta :: bit_field u64 {
	expire_at: u64 | 48,
	clock:     u16 | 16,
}

Slot_Tag :: bit_field u8 {
	key_form: u8 | 4,
	val_form: u8 | 4,
}

Val_Info :: bit_field u8 {
	type: Obj_Type     | 3,
	enc:  Obj_Encoding | 4,
}

Key_Small :: struct #packed {
	bytes: [INLINE_BYTES]u8,
	tag:   Slot_Tag,
}

Key_Slab :: struct #packed {
	offset: u32,
	len:    u16,
	spare:  u8,
	tag:    Slot_Tag,
}

Key_Handle :: struct #raw_union {
	bits:  u64,
	small: Key_Small,
	slab:  Key_Slab,
	heap:  bit_field u64 {
		addr: uintptr | 48,
	},
}

Val_Small :: struct #packed {
	bytes: [INLINE_BYTES]u8,
	lfu:   u8,
}

Val_Slab :: struct #packed {
	offset: u32,
	len:    u16,
	info:   Val_Info,
	lfu:    u8,
}

Val_Handle :: struct #raw_union {
	bits:  u64,
	small: Val_Small,
	slab:  Val_Slab,
	ref:   bit_field u64 {
		addr: uintptr | 48,
	},
}

Slot :: struct {
	meta: Slot_Meta,
	key:  Key_Handle,
	val:  Val_Handle,
}

Big_Str :: struct {
	data: [^]u8,
	len:  u32,
	cap:  u32,
}

KEY_CMP_MASK :: u64(0x0FFF_FFFF_FFFF_FFFF)
LFU_SHIFT :: 56
MAX_EXPIRE_MS :: i64(1 << 48) - 1

#assert(size_of(Slot_Meta) == 8)
#assert(size_of(Slot_Tag) == 1)
#assert(size_of(Val_Info) == 1)
#assert(size_of(Key_Handle) == 8)
#assert(size_of(Val_Handle) == 8)
#assert(size_of(Key_Small) == 8 && size_of(Key_Slab) == 8)
#assert(size_of(Val_Small) == 8 && size_of(Val_Slab) == 8)
#assert(offset_of(Key_Small, tag) == 7 && offset_of(Key_Slab, tag) == 7)
#assert(offset_of(Val_Small, lfu) == 7 && offset_of(Val_Slab, lfu) == 7)
#assert(offset_of(Val_Slab, info) == 6)
#assert(size_of(Slot) == 24)
#assert(size_of(Slot_Meta) + size_of(Key_Handle) + size_of(Val_Handle) <= 24)
#assert(size_of(Big_Str) == 16)

pack_small :: #force_inline proc "contextless" (b: []u8) -> u64 #no_bounds_check {
	n := len(b)
	p := raw_data(b)
	switch {
	case n >= 4:
		lo := u64(intrinsics.unaligned_load((^u32)(p)))
		hi := u64(intrinsics.unaligned_load((^u32)(&p[n - 4])))
		return lo | (hi << (u64(n - 4) * 8))
	case n > 0:
		return u64(p[0]) | (u64(p[n >> 1]) << (u64(n >> 1) * 8)) | (u64(p[n - 1]) << (u64(n - 1) * 8))
	}
	return 0
}

string_encoding_of :: proc "contextless" (v: []u8) -> Obj_Encoding {
	if len(v) <= 20 {
		if _, ok := parse_i64(v); ok {
			return .Int
		}
	}
	if len(v) <= EMBSTR_SIZE_LIMIT {
		return .Embstr
	}
	return .Raw
}

small_encoding :: #force_inline proc "contextless" (v: []u8) -> Obj_Encoding {
	if _, ok := parse_i64(v); ok {
		return .Int
	}
	return .Embstr
}

encoding_name :: proc "contextless" (enc: Obj_Encoding) -> string {
	switch enc {
	case .Raw:
		return "raw"
	case .Int:
		return "int"
	case .Embstr:
		return "embstr"
	case .Listpack:
		return "listpack"
	case .Hashtable:
		return "hashtable"
	case .Intset:
		return "intset"
	case .Quicklist:
		return "quicklist"
	case .Skiplist:
		return "skiplist"
	case .Stream:
		return "stream"
	case .Listpack_Ex:
		return "listpackex"
	}
	return "raw"
}

type_name :: proc "contextless" (t: Obj_Type) -> string {
	switch t {
	case .String:
		return "string"
	case .List:
		return "list"
	case .Set:
		return "set"
	case .Zset:
		return "zset"
	case .Hash:
		return "hash"
	case .Stream:
		return "stream"
	}
	return "none"
}

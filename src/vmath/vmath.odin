package vmath

Family :: enum u8 {
	Vector_Set,
	Search,
}

Elem :: enum u8 {
	F32,
	Int8,
	Bin,
	F64,
	F16,
	BF16,
	U8,
}

Metric :: enum u8 {
	Cosine,
	L2,
	IP,
}

VSET_ELEMS :: bit_set[Elem]{.F32, .Int8, .Bin}
SEARCH_ELEMS :: bit_set[Elem]{.F32, .F64, .F16, .BF16, .Int8, .U8}

DIM_MAX :: 1 << 19
NIL_SLOT :: max(u32)
SLOT_LIMIT :: (1 << 31) - 1
FREE_MARK :: u32(1) << 31
FREE_NIL :: FREE_MARK - 1
Q8_SCALE :: f32(127)
I8_CHUNK :: 1 << 16
F32_WIDE_MIN :: 16
Q8_FUSED_MIN :: 32
BF16_WIDE_MIN :: 32

bin_words :: #force_inline proc "contextless" (dim: int) -> int {
	return (dim + 63) >> 6
}

family_supports :: proc "contextless" (family: Family, elem: Elem, metric: Metric) -> bool {
	switch family {
	case .Vector_Set:
		return elem in VSET_ELEMS && metric == .Cosine
	case .Search:
		return elem in SEARCH_ELEMS
	}
	return false
}

elem_size :: proc "contextless" (elem: Elem) -> int {
	switch elem {
	case .F32:
		return size_of(f32)
	case .F64:
		return size_of(f64)
	case .F16, .BF16:
		return size_of(u16)
	case .Int8, .U8:
		return 1
	case .Bin:
		return 0
	}
	return 0
}

elem_vector_bytes :: proc "contextless" (elem: Elem, dim: int) -> int {
	if elem == .Bin {
		return bin_words(dim) * size_of(u64)
	}
	return dim * elem_size(elem)
}

elem_has_range :: #force_inline proc "contextless" (elem: Elem, family := Family.Vector_Set) -> bool {
	return family == .Vector_Set && elem == .Int8
}

search_has_norm :: #force_inline proc "contextless" (elem: Elem, metric: Metric) -> bool {
	return metric == .Cosine && (elem == .Int8 || elem == .U8)
}

elem_scalar_bytes :: proc "contextless" (elem: Elem, family := Family.Vector_Set) -> int {
	return size_of(f32) * (2 if elem_has_range(elem, family) else 1)
}

slot_bytes :: proc "contextless" (elem: Elem, dim: int, family := Family.Vector_Set) -> int {
	return elem_vector_bytes(elem, dim) + elem_scalar_bytes(elem, family)
}

elem_name :: proc "contextless" (elem: Elem) -> string {
	switch elem {
	case .F32:
		return "f32"
	case .Int8:
		return "int8"
	case .Bin:
		return "bin"
	case .F64:
		return "f64"
	case .F16:
		return "f16"
	case .BF16:
		return "bf16"
	case .U8:
		return "u8"
	}
	return ""
}

search_type_name :: proc "contextless" (elem: Elem) -> string {
	switch elem {
	case .F32:
		return "FLOAT32"
	case .F64:
		return "FLOAT64"
	case .F16:
		return "FLOAT16"
	case .BF16:
		return "BFLOAT16"
	case .Int8:
		return "INT8"
	case .U8:
		return "UINT8"
	case .Bin:
		return ""
	}
	return ""
}

metric_name :: proc "contextless" (metric: Metric) -> string {
	switch metric {
	case .Cosine:
		return "COSINE"
	case .L2:
		return "L2"
	case .IP:
		return "IP"
	}
	return ""
}

dim_valid :: #force_inline proc "contextless" (dim: int) -> bool {
	return dim >= 1 && dim <= DIM_MAX
}

f32_view :: #force_inline proc "contextless" (b: []u8) -> []f32 {
	return ([^]f32)(raw_data(b))[:len(b) / size_of(f32)]
}

f64_view :: #force_inline proc "contextless" (b: []u8) -> []f64 {
	return ([^]f64)(raw_data(b))[:len(b) / size_of(f64)]
}

u16_view :: #force_inline proc "contextless" (b: []u8) -> []u16 {
	return ([^]u16)(raw_data(b))[:len(b) / size_of(u16)]
}

i8_view :: #force_inline proc "contextless" (b: []u8) -> []i8 {
	return ([^]i8)(raw_data(b))[:len(b)]
}

u64_view :: #force_inline proc "contextless" (b: []u8) -> []u64 {
	return ([^]u64)(raw_data(b))[:len(b) / size_of(u64)]
}

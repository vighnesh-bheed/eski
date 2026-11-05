package listpack

import "base:intrinsics"
import "core:mem"

lp_get_total_bytes :: proc "contextless" (p: [^]u8) -> u32 {
	value, _ := read_unsigned(p[:PACK_HEADER_BYTES], 0, 4)
	return u32(value)
}

lp_get_num_elements :: proc "contextless" (p: [^]u8) -> u32 {
	value, _ := read_unsigned(p[:PACK_HEADER_BYTES], 4, 2)
	return u32(value)
}

lp_set_total_bytes :: proc "contextless" (p: [^]u8, v: u64) {
	if v > u64(max(u32)) {
		intrinsics.trap()
	}
	write_unsigned(p[:PACK_HEADER_BYTES], 0, 4, v)
}

lp_set_num_elements :: proc "contextless" (p: [^]u8, v: u64) {
	write_unsigned(p[:PACK_HEADER_BYTES], 4, 2, min(v, COUNT_UNTRACKED))
}

lp_bytes :: proc "contextless" (lp: [^]u8) -> int {
	if lp == nil {
		return 0
	}
	return int(lp_get_total_bytes(lp))
}

lp_view :: proc "contextless" (lp: [^]u8) -> []u8 {
	if lp == nil {
		return nil
	}
	return lp[:lp_bytes(lp)]
}

lp_new :: proc "contextless" (capacity: int) -> [^]u8 {
	minimum :: PACK_HEADER_BYTES + 1
	lp := lp_malloc(max(capacity, minimum))
	if lp == nil {
		return nil
	}
	lp_set_total_bytes(lp, minimum)
	lp_set_num_elements(lp, 0)
	lp[PACK_HEADER_BYTES] = PACK_END
	return lp
}

lp_free :: proc "contextless" (lp: [^]u8) {
	lp_mem_free(lp)
}

lp_shrink_to_fit :: proc "contextless" (lp: [^]u8) -> [^]u8 {
	if lp == nil {
		return nil
	}
	replacement := lp_realloc(lp, lp_bytes(lp))
	return replacement if replacement != nil else lp
}

lp_dup :: proc "contextless" (lp: [^]u8) -> [^]u8 {
	if lp == nil {
		return nil
	}
	size := lp_bytes(lp)
	duplicate := lp_malloc(size)
	if duplicate != nil {
		mem.copy(duplicate, lp, size)
	}
	return duplicate
}

lp_safe_to_add :: proc "contextless" (lp: [^]u8, add: int) -> bool {
	projected := i128(add)
	if lp != nil {
		projected += i128(lp_get_total_bytes(lp))
	}
	return projected >= 0 && projected <= PACK_SIZE_CEILING
}

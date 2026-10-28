package listpack

import "base:intrinsics"
import "core:mem"

lp_get_total_bytes :: proc "contextless" (p: [^]u8) -> u32 {
	value, _ := read_unsigned(p[:LP_HDR_SIZE], 0, 4)
	return u32(value)
}

lp_get_num_elements :: proc "contextless" (p: [^]u8) -> u32 {
	value, _ := read_unsigned(p[:LP_HDR_SIZE], 4, 2)
	return u32(value)
}

lp_set_total_bytes :: proc "contextless" (p: [^]u8, v: u64) {
	if v > u64(max(u32)) {
		intrinsics.trap()
	}
	write_unsigned(p[:LP_HDR_SIZE], 0, 4, v)
}

lp_set_num_elements :: proc "contextless" (p: [^]u8, v: u64) {
	write_unsigned(p[:LP_HDR_SIZE], 4, 2, min(v, LP_HDR_NUMELE_UNKNOWN))
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
	minimum :: LP_HDR_SIZE + 1
	lp := lp_malloc(max(capacity, minimum))
	if lp == nil {
		return nil
	}
	lp_set_total_bytes(lp, minimum)
	lp_set_num_elements(lp, 0)
	lp[LP_HDR_SIZE] = LP_EOF
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
	current := u64(0)
	if lp != nil {
		current = u64(lp_get_total_bytes(lp))
	}
	limit :: u64(LISTPACK_MAX_SAFETY_SIZE)
	if add >= 0 {
		return current <= limit && u64(add) <= limit - current
	}
	magnitude := u64(-(add + 1)) + 1
	return magnitude <= current && current - magnitude <= limit
}

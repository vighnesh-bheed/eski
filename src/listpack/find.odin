package listpack

lp_compare :: proc "contextless" (p: [^]u8, s: []u8) -> bool {
	body, valid := owned_body(p)
	if !valid {
		return false
	}
	if body.is_string {
		return string(padd(p, body.string_offset)[:body.string_length]) == string(s)
	}
	value := i64(0)
	return lp_string_to_int64(s, &value) && value == body.value
}

stride_origin :: proc(pack: [^]u8, from: [^]u8) -> [^]u8 {
	origin := lp_first(pack) if from == nil else from
	if origin != nil && origin[0] == PACK_END {
		return nil
	}
	return origin
}

stride_hop :: proc(pack: [^]u8, at: [^]u8, skip: u32) -> [^]u8 {
	return seek_steps(pack, at, u64(skip) + 1, false)
}

lp_find :: proc(lp: [^]u8, p: [^]u8, s: []u8, skip: u32) -> [^]u8 {
	for at := stride_origin(lp, p); at != nil; at = stride_hop(lp, at, skip) {
		if lp_compare(at, s) {
			return at
		}
	}
	return nil
}

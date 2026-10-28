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

lp_find :: proc(lp: [^]u8, p: [^]u8, s: []u8, skip: u32) -> [^]u8 {
	cursor := p
	if cursor == nil {
		cursor = lp_first(lp)
	}
	remaining := u32(0)
	for cursor != nil && cursor[0] != LP_EOF {
		if remaining == 0 {
			if lp_compare(cursor, s) {
				return cursor
			}
			remaining = skip
		} else {
			remaining -= 1
		}
		cursor = lp_next(lp, cursor)
	}
	return nil
}

lp_estimate_bytes_repeated_integer :: proc "contextless" (lval: i64, rep: u64) -> int {
	entry_size := u64(lp_entry_size_integer(lval))
	if rep > (u64(max(int)) - LP_HDR_SIZE - 1) / entry_size {
		return max(int)
	}
	return LP_HDR_SIZE + 1 + int(rep * entry_size)
}

lp_find_cb :: proc(lp: [^]u8, p: [^]u8, user: rawptr, cmp: Lp_Cmp, skip: u32) -> [^]u8 {
	if cmp == nil {
		return nil
	}
	cursor := p
	if cursor == nil {
		cursor = lp_first(lp)
	}
	remaining := u32(0)
	for cursor != nil && cursor[0] != LP_EOF {
		if remaining == 0 {
			count := i64(0)
			value := lp_get(cursor, &count, nil)
			if cmp(lp, cursor, user, value, count) == 0 {
				return cursor
			}
			remaining = skip
		} else {
			remaining -= 1
		}
		cursor = lp_next(lp, cursor)
	}
	return nil
}

package listpack

owned_body_size :: proc "contextless" (p: [^]u8) -> (int, bool) {
	if p == nil {
		return 0, false
	}
	tag := p[0]
	if tag < 128 {
		return 1, true
	}
	if tag < 192 {
		return 1 + int(tag & 63), true
	}
	if tag < 224 {
		return 2, true
	}
	if tag < 240 {
		return 2 + (int(tag & 15) << 8) + int(p[1]), true
	}
	if tag == 240 {
		length, _ := read_unsigned(p[:5], 1, 4)
		if length > u64(max(int) - 5) {
			return 0, false
		}
		return 5 + int(length), true
	}
	switch tag {
	case 241:
		return 3, true
	case 242:
		return 4, true
	case 243:
		return 5, true
	case 244:
		return 9, true
	}
	return 0, false
}

owned_body :: proc "contextless" (p: [^]u8) -> (Body, bool) {
	length, valid := owned_body_size(p)
	if !valid {
		return {}, false
	}
	return decode_body(p[:length], 0)
}

lp_skip :: proc "contextless" (p: [^]u8) -> [^]u8 {
	length, valid := owned_body_size(p)
	if !valid || length > max(int) - backlen_width(u64(length)) {
		return nil
	}
	return padd(p, length + backlen_width(u64(length)))
}

lp_first :: proc(lp: [^]u8) -> [^]u8 {
	return lp_validate_first(lp)
}

lp_next :: proc(lp: [^]u8, p: [^]u8) -> [^]u8 {
	if lp == nil || p == nil {
		return nil
	}
	next := lp_skip(p)
	if next == nil || next[0] == PACK_END {
		return nil
	}
	return next
}

lp_prev :: proc(lp: [^]u8, p: [^]u8) -> [^]u8 {
	if lp == nil || p == nil {
		return nil
	}
	base, address := uintptr(lp), uintptr(p)
	if address <= base || address - base <= PACK_HEADER_BYTES || address - base >= uintptr(lp_bytes(lp)) {
		return nil
	}
	offset := int(address - base)
	length, _, valid := read_backlen(lp[:lp_bytes(lp)], offset - 1, 0)
	if !valid || length == 0 {
		return nil
	}
	width := backlen_width(length)
	if length + u64(width) > u64(offset - PACK_HEADER_BYTES) {
		return nil
	}
	return padd(lp, offset - int(length) - width)
}

lp_last :: proc(lp: [^]u8) -> [^]u8 {
	if lp == nil || lp_bytes(lp) <= PACK_HEADER_BYTES + 1 {
		return nil
	}
	return lp_prev(lp, padd(lp, lp_bytes(lp) - 1))
}

seek_steps :: proc(lp: [^]u8, start: [^]u8, steps: u64, reverse: bool) -> [^]u8 {
	cursor := start
	remaining := steps
	for cursor != nil && remaining > 0 {
		cursor = lp_prev(lp, cursor) if reverse else lp_next(lp, cursor)
		remaining -= 1
	}
	return cursor
}

lp_seek :: proc(lp: [^]u8, index: i64) -> [^]u8 {
	if lp == nil {
		return nil
	}
	count := u64(lp_get_num_elements(lp))
	known := count != COUNT_UNTRACKED
	if index >= 0 {
		target := u64(index)
		if known {
			if target >= count {
				return nil
			}
			if target >= count / 2 {
				return seek_steps(lp, lp_last(lp), count - target - 1, true)
			}
		}
		return seek_steps(lp, lp_first(lp), target, false)
	}
	magnitude := u64(-(index + 1)) + 1
	if known {
		if magnitude > count {
			return nil
		}
		if magnitude > count / 2 {
			return seek_steps(lp, lp_first(lp), count - magnitude, false)
		}
	}
	return seek_steps(lp, lp_last(lp), magnitude - 1, true)
}

lp_get_entry :: proc "contextless" (p: [^]u8) -> Element {
	body, valid := owned_body(p)
	if !valid {
		return {}
	}
	if body.is_string {
		return {text = padd(p, body.string_offset), text_len = u32(body.string_length)}
	}
	return entry_from_int(body.value)
}

lp_get_bytes :: proc "contextless" (p: [^]u8, intbuf: ^[DECIMAL_BUFFER_BYTES]u8) -> []u8 {
	return entry_bytes(lp_get_entry(p), intbuf)
}

lp_get :: proc "contextless" (p: [^]u8, count: ^i64, intbuf: [^]u8) -> [^]u8 {
	body, decoded := owned_body(p)
	text: [^]u8
	measure := i64(body.string_length)
	switch {
	case !decoded:
		return nil
	case body.is_string:
		text = padd(p, body.string_offset)
	case intbuf != nil:
		text = intbuf
		measure = i64(ll2string(intbuf, body.value))
	case:
		measure = body.value
	}
	if count != nil {
		count^ = measure
	}
	return text
}

lp_get_value :: proc "contextless" (p: [^]u8, slen: ^u32, lval: ^i64) -> [^]u8 {
	body, valid := owned_body(p)
	if !valid {
		return nil
	}
	if body.is_string {
		if slen != nil {
			slen^ = u32(body.string_length)
		}
		return padd(p, body.string_offset)
	}
	if lval != nil {
		lval^ = body.value
	}
	return nil
}

lp_integer_at :: proc "contextless" (at: [^]u8) -> (value: i64, ok: bool) {
	body, valid := owned_body(at)
	if !valid || body.is_string {
		return 0, false
	}
	return body.value, true
}

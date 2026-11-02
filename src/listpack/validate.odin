package listpack

Entry_Extent :: struct {
	body:       Body,
	end:        int,
	back_bytes: int,
}

decode_entry_extent :: proc "contextless" (data: []u8, offset, limit: int) -> (Entry_Extent, bool) {
	if offset < 0 || limit < 0 || limit > len(data) || offset >= limit {
		return {}, false
	}
	body, valid := decode_body(data[:limit], offset)
	if !valid {
		return {}, false
	}
	body_end := offset + body.bytes
	width := backlen_width(u64(body.bytes))
	if width > limit - body_end {
		return {}, false
	}
	end := body_end + width
	value, _, back_valid := read_backlen(data, end - 1, 0)
	if !back_valid || value != u64(body.bytes) {
		return {}, false
	}
	return {body = body, end = end, back_bytes = width}, true
}

walk_entries :: proc(data: []u8, header: Header, entry_cb: Element_Visitor, userdata: rawptr) -> (u64, bool) {
	if len(data) < PACK_HEADER_BYTES + 1 || u64(header.bytes) != u64(len(data)) || data[len(data) - 1] != PACK_END {
		return 0, false
	}
	count := u64(0)
	cursor := PACK_HEADER_BYTES
	limit := len(data) - 1
	for cursor < limit {
		extent, valid := decode_entry_extent(data, cursor, limit)
		if !valid {
			return count, false
		}
		count += 1
		if entry_cb != nil && !entry_cb(raw_data(data[cursor:]), u32(header.count), userdata) {
			return count, false
		}
		cursor = extent.end
	}
	return count, header.count == COUNT_UNTRACKED || count == u64(header.count)
}

lp_length :: proc(lp: [^]u8) -> u64 {
	if lp == nil {
		return 0
	}
	cached := lp_get_num_elements(lp)
	if cached != COUNT_UNTRACKED {
		return u64(cached)
	}
	data := lp_view(lp)
	header, header_valid := decode_header(data)
	if !header_valid {
		return 0
	}
	count, valid := walk_entries(data, header, nil, nil)
	if !valid {
		return 0
	}
	if count < COUNT_UNTRACKED {
		lp_set_num_elements(lp, count)
	}
	return count
}

lp_validate_integrity :: proc(lp: [^]u8, size: u64, deep: bool, entry_cb: Element_Visitor, cb_userdata: rawptr) -> bool {
	if lp == nil || size < PACK_HEADER_BYTES + 1 || size > u64(max(int)) || size > u64(max(u32)) {
		return false
	}
	data := lp[:int(size)]
	header, valid := decode_header(data)
	if !valid || u64(header.bytes) != size {
		return false
	}
	if !deep {
		return true
	}
	_, entries_valid := walk_entries(data, header, entry_cb, cb_userdata)
	return entries_valid
}

lp_validate_first :: proc "contextless" (lp: [^]u8) -> [^]u8 {
	if lp == nil || lp_bytes(lp) <= PACK_HEADER_BYTES + 1 || lp[PACK_HEADER_BYTES] == PACK_END {
		return nil
	}
	return padd(lp, PACK_HEADER_BYTES)
}

lp_validate_next :: proc "contextless" (lp: [^]u8, pp: ^[^]u8, lpbytes: u64) -> bool {
	if lp == nil || pp == nil || pp^ == nil || lpbytes < PACK_HEADER_BYTES + 1 || lpbytes > u64(max(int)) || lpbytes > u64(max(u32)) {
		return false
	}
	base, address := uintptr(lp), uintptr(pp^)
	if address < base || u64(address - base) >= lpbytes {
		return false
	}
	offset := int(address - base)
	limit := int(lpbytes) - 1
	data := lp[:int(lpbytes)]
	if offset == limit && data[offset] == PACK_END {
		pp^ = nil
		return true
	}
	if offset < PACK_HEADER_BYTES {
		return false
	}
	extent, valid := decode_entry_extent(data, offset, limit)
	if !valid {
		return false
	}
	pp^ = padd(lp, extent.end)
	return true
}

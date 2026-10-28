package listpack

Header_Dependency :: struct {
	start: int,
	body_bytes: int,
}

Header_Dependencies :: struct {
	entries: [2]Header_Dependency,
	count: int,
}

capture_header_dependencies :: proc "contextless" (lp: [^]u8) -> Header_Dependencies {
	result: Header_Dependencies
	limit := min(lp_bytes(lp) - 1, LP_HDR_SIZE + 4)
	if limit <= LP_HDR_SIZE {
		return result
	}
	data := lp[:limit]
	offset := LP_HDR_SIZE
	for offset < limit && result.count < len(result.entries) {
		body, valid := decode_body(data, offset)
		if !valid {
			break
		}
		width := backlen_width(u64(body.bytes))
		end := offset + body.bytes + width
		if end > limit {
			break
		}
		value, groups, back_valid := read_backlen(data, end - 1, 0)
		if back_valid && value == u64(body.bytes) && end - groups < LP_HDR_SIZE {
			result.entries[result.count] = {start = offset, body_bytes = body.bytes}
			result.count += 1
		}
		offset = end
	}
	return result
}

map_spliced_dependencies :: proc "contextless" (dependencies: Header_Dependencies, offset, removed_bytes, inserted_bytes: int) -> Header_Dependencies {
	result: Header_Dependencies
	for index in 0..<dependencies.count {
		entry := dependencies.entries[index]
		mapped := entry
		if entry.start >= offset {
			if entry.start < offset + removed_bytes {
				continue
			}
			mapped.start += inserted_bytes - removed_bytes
		}
		result.entries[result.count] = mapped
		result.count += 1
	}
	return result
}

repair_header_dependencies :: proc "contextless" (lp: [^]u8, dependencies: Header_Dependencies) {
	data := lp_view(lp)
	for index in 0..<dependencies.count {
		entry := dependencies.entries[index]
		back_start := entry.start + entry.body_bytes
		width := backlen_width(u64(entry.body_bytes))
		value, _, valid := read_backlen(data, back_start + width - 1, 0)
		if !valid || value != u64(entry.body_bytes) {
			lp_encode_backlen(padd(lp, back_start), u64(entry.body_bytes))
		}
	}
}

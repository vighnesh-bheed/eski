package listpack

Merge_Shape :: struct {
	left_bytes:   int,
	right_bytes:  int,
	left_payload: int,
	joined_bytes: int,
	joined_count: u64,
}

measure_merge :: proc(left, right: [^]u8) -> (shape: Merge_Shape, ok: bool) {
	smallest :: PACK_HEADER_BYTES + 1
	if left == nil || right == nil || left == right {
		return
	}
	shape.left_bytes = lp_bytes(left)
	shape.right_bytes = lp_bytes(right)
	if min(shape.left_bytes, shape.right_bytes) < smallest {
		return
	}
	shape.left_payload = shape.left_bytes - smallest
	if shape.right_bytes > PACK_SIZE_CEILING - shape.left_payload {
		return
	}
	shape.joined_bytes = shape.left_payload + shape.right_bytes
	left_count := merge_count(left) or_return
	right_count := merge_count(right) or_return
	shape.joined_count = left_count + right_count
	return shape, true
}

resize_for_merge :: proc(pack: [^]u8, size: int) -> [^]u8 {
	if lp_malloc_size(pack) == size {
		return pack
	}
	return lp_realloc(pack, size)
}

append_payload :: proc(host, donor: [^]u8, shape: Merge_Shape) {
	tail := host[shape.left_bytes - 1:shape.joined_bytes]
	copy(tail, donor[PACK_HEADER_BYTES:shape.right_bytes])
}

prepend_payload :: proc(host, donor: [^]u8, shape: Merge_Shape) {
	body := host[PACK_HEADER_BYTES:shape.joined_bytes]
	copy(body[shape.left_payload:], host[PACK_HEADER_BYTES:shape.right_bytes])
	copy(body[:shape.left_payload], donor[PACK_HEADER_BYTES:shape.left_bytes - 1])
}

merge_packs :: proc(first, second: [^]u8, keep_first: bool) -> [^]u8 {
	shape, measured := measure_merge(first, second)
	if !measured {
		return nil
	}
	left_marks := capture_header_dependencies(first)
	right_marks := capture_header_dependencies(second)
	for &mark in right_marks.entries[:right_marks.count] {
		mark.start += shape.left_payload
	}
	host := resize_for_merge(first if keep_first else second, shape.joined_bytes)
	if host == nil {
		return nil
	}
	if keep_first {
		append_payload(host, second, shape)
		lp_free(second)
	} else {
		prepend_payload(host, first, shape)
		lp_free(first)
	}
	lp_set_total_bytes(host, u64(shape.joined_bytes))
	lp_set_num_elements(host, shape.joined_count)
	repair_header_dependencies(host, left_marks)
	repair_header_dependencies(host, right_marks)
	return host
}

lp_merge :: proc(first: ^[^]u8, second: ^[^]u8) -> [^]u8 {
	if first == nil || second == nil || first == second {
		return nil
	}
	left, right := first^, second^
	if left == nil || right == nil || left == right {
		return nil
	}
	into_left := lp_bytes(left) >= lp_bytes(right)
	joined := merge_packs(left, right, into_left)
	if joined != nil {
		first^ = joined if into_left else nil
		second^ = nil if into_left else joined
	}
	return joined
}

merge_count :: proc(lp: [^]u8) -> (u64, bool) {
	cached := lp_get_num_elements(lp)
	if cached != COUNT_UNTRACKED {
		return u64(cached), true
	}
	data := lp_view(lp)
	header, valid := decode_header(data)
	if !valid {
		return 0, false
	}
	return walk_entries(data, header, nil, nil)
}

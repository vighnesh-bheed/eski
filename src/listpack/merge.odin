package listpack

merge_packs :: proc(first, second: [^]u8, keep_first: bool) -> [^]u8 {
	first_size, second_size := lp_bytes(first), lp_bytes(second)
	if first == nil || second == nil || first == second || first_size < LP_HDR_SIZE + 1 || second_size < LP_HDR_SIZE + 1 {
		return nil
	}
	first_payload := first_size - LP_HDR_SIZE - 1
	if first_payload > LISTPACK_MAX_SAFETY_SIZE - second_size {
		return nil
	}
	first_dependencies := capture_header_dependencies(first)
	second_dependencies := capture_header_dependencies(second)
	for index in 0..<second_dependencies.count {
		second_dependencies.entries[index].start += first_payload
	}
	total := first_payload + second_size
	first_count, first_count_valid := merge_count(first)
	second_count, second_count_valid := merge_count(second)
	if !first_count_valid || !second_count_valid {
		return nil
	}
	count := min(first_count + second_count, LP_HDR_NUMELE_UNKNOWN)
	target := first if keep_first else second
	if total != lp_malloc_size(target) {
		target = lp_realloc(target, total)
		if target == nil {
			return nil
		}
	}
	if keep_first {
		copy(target[first_size - 1:total], second[LP_HDR_SIZE:second_size])
		lp_free(second)
	} else {
		copy(target[LP_HDR_SIZE + first_payload:total], target[LP_HDR_SIZE:second_size])
		copy(target[LP_HDR_SIZE:LP_HDR_SIZE + first_payload], first[LP_HDR_SIZE:first_size - 1])
		lp_free(first)
	}
	lp_set_total_bytes(target, u64(total))
	lp_set_num_elements(target, count)
	repair_header_dependencies(target, first_dependencies)
	repair_header_dependencies(target, second_dependencies)
	return target
}

lp_merge :: proc(first: ^[^]u8, second: ^[^]u8) -> [^]u8 {
	if first == nil || second == nil || first == second || first^ == nil || second^ == nil || first^ == second^ {
		return nil
	}
	keep_first := lp_bytes(first^) >= lp_bytes(second^)
	result := merge_packs(first^, second^, keep_first)
	if result == nil {
		return nil
	}
	if keep_first {
		first^ = result
		second^ = nil
	} else {
		first^ = nil
		second^ = result
	}
	return result
}

merge_count :: proc(lp: [^]u8) -> (u64, bool) {
	cached := lp_get_num_elements(lp)
	if cached != LP_HDR_NUMELE_UNKNOWN {
		return u64(cached), true
	}
	data := lp_view(lp)
	header, valid := decode_header(data)
	if !valid {
		return 0, false
	}
	return walk_entries(data, header, nil, nil)
}

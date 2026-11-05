package listpack

encode_entries :: proc(entries: []Element, maximum: int) -> ([]u8, bool) {
	if maximum < 0 {
		return nil, false
	}
	total := 0
	for entry in entries {
		plan, valid := plan_entry(entry)
		if !valid || plan.encoded_bytes > maximum - total {
			return nil, false
		}
		total += plan.encoded_bytes
	}
	if total == 0 {
		return nil, true
	}
	storage := lp_malloc(total)
	if storage == nil {
		return nil, false
	}
	bytes := storage[:total]
	offset := 0
	for entry in entries {
		plan, valid := plan_entry(entry)
		if !valid || !write_entry(bytes[offset:offset + plan.encoded_bytes], plan) {
			lp_mem_free(storage)
			return nil, false
		}
		offset += plan.encoded_bytes
	}
	return bytes, true
}

mutation_offset :: proc(lp, p: [^]u8) -> (int, bool) {
	if lp == nil || p == nil {
		return 0, false
	}
	base, address := uintptr(lp), uintptr(p)
	if address < base || address - base < PACK_HEADER_BYTES || address - base >= uintptr(lp_bytes(lp)) {
		return 0, false
	}
	return int(address - base), true
}

splice_bytes :: proc(lp: [^]u8, offset, removed_bytes: int, removed_count: u64, inserted: []u8, inserted_count: u64) -> [^]u8 {
	old_size := lp_bytes(lp)
	if offset < PACK_HEADER_BYTES || offset >= old_size || removed_bytes < 0 || removed_bytes > old_size - 1 - offset {
		return nil
	}
	retained := old_size - removed_bytes
	if retained > PACK_SIZE_CEILING || len(inserted) > PACK_SIZE_CEILING - retained {
		return nil
	}
	new_size := retained + len(inserted)
	dependencies := map_spliced_dependencies(capture_header_dependencies(lp), offset, removed_bytes, len(inserted))
	count := u64(lp_get_num_elements(lp))
	if count != COUNT_UNTRACKED {
		if removed_count > count || inserted_count > max(u64) - (count - removed_count) {
			return nil
		}
		count = min(count - removed_count + inserted_count, COUNT_UNTRACKED)
	}
	result := lp
	if new_size > lp_malloc_size(lp) {
		result = lp_realloc(lp, new_size)
		if result == nil {
			return nil
		}
	}
	copy(result[offset + len(inserted):new_size], result[offset + removed_bytes:old_size])
	copy(result[offset:offset + len(inserted)], inserted)
	lp_set_total_bytes(result, u64(new_size))
	lp_set_num_elements(result, count)
	repair_header_dependencies(result, dependencies)
	if new_size < old_size {
		result = lp_shrink_to_fit(result)
	}
	return result
}

insert_entries :: proc(lp: [^]u8, p: [^]u8, where_: Placement, entries: []Element, newp: ^[^]u8) -> [^]u8 {
	if len(entries) == 0 {
		return lp
	}
	offset, valid := mutation_offset(lp, p)
	if !valid || where_ > .Replace {
		return nil
	}
	removed_bytes := 0
	removed_count := u64(0)
	if where_ != Placement.Before {
		if p[0] == PACK_END {
			return nil
		}
		next := lp_skip(p)
		if next == nil {
			return nil
		}
		if where_ == Placement.After {
			offset = pdiff(next, lp)
		} else {
			removed_bytes = pdiff(next, p)
			removed_count = 1
		}
	}
	encoded, encoded_valid := encode_entries(entries, PACK_SIZE_CEILING - (lp_bytes(lp) - removed_bytes))
	if !encoded_valid {
		return nil
	}
	defer lp_mem_free(raw_data(encoded))
	last_plan, _ := plan_entry(entries[len(entries) - 1])
	result := splice_bytes(lp, offset, removed_bytes, removed_count, encoded, u64(len(entries)))
	if result != nil && newp != nil {
		newp^ = padd(result, offset + len(encoded) - last_plan.encoded_bytes)
	}
	return result
}

lp_splice_entries :: proc(pack: [^]u8, entries: []Element, anchor: [^]u8, placement: Placement, cursor: ^[^]u8) -> [^]u8 {
	if len(entries) == 0 {
		return pack
	}
	if placement != Placement.Before && placement != Placement.After {
		return nil
	}
	return insert_entries(pack, anchor, placement, entries, cursor)
}

lp_insert_string :: proc(lp: [^]u8, s: []u8, p: [^]u8, where_: Placement, newp: ^[^]u8) -> [^]u8 {
	entries := [1]Element{entry_from_bytes(s)}
	return insert_entries(lp, p, where_, entries[:], newp)
}

lp_insert_integer :: proc(lp: [^]u8, lval: i64, p: [^]u8, where_: Placement, newp: ^[^]u8) -> [^]u8 {
	entries := [1]Element{entry_from_int(lval)}
	return insert_entries(lp, p, where_, entries[:], newp)
}

lp_append :: proc(lp: [^]u8, s: []u8) -> [^]u8 {
	if lp == nil {
		return nil
	}
	return lp_insert_string(lp, s, padd(lp, lp_bytes(lp) - 1), Placement.Before, nil)
}

lp_append_integer :: proc(lp: [^]u8, lval: i64) -> [^]u8 {
	if lp == nil {
		return nil
	}
	return lp_insert_integer(lp, lval, padd(lp, lp_bytes(lp) - 1), Placement.Before, nil)
}

lp_prepend :: proc(lp: [^]u8, s: []u8) -> [^]u8 {
	if lp == nil {
		return nil
	}
	return lp_insert_string(lp, s, padd(lp, PACK_HEADER_BYTES), Placement.Before, nil)
}

lp_prepend_integer :: proc(lp: [^]u8, lval: i64) -> [^]u8 {
	if lp == nil {
		return nil
	}
	return lp_insert_integer(lp, lval, padd(lp, PACK_HEADER_BYTES), Placement.Before, nil)
}

lp_append_entries :: proc(pack: [^]u8, entries: []Element) -> [^]u8 {
	if pack == nil {
		return nil
	}
	return lp_splice_entries(pack, entries, padd(pack, lp_bytes(pack) - 1), Placement.Before, nil)
}

lp_replace :: proc(lp: [^]u8, p: ^[^]u8, s: []u8) -> [^]u8 {
	if p == nil {
		return nil
	}
	return lp_insert_string(lp, s, p^, Placement.Replace, p)
}

lp_replace_integer :: proc(lp: [^]u8, p: ^[^]u8, lval: i64) -> [^]u8 {
	if p == nil {
		return nil
	}
	return lp_insert_integer(lp, lval, p^, Placement.Replace, p)
}

lp_delete_range_with_entry :: proc(lp: [^]u8, p: ^[^]u8, num: u64) -> [^]u8 {
	if p == nil || p^ == nil || num == 0 {
		return lp
	}
	offset, valid := mutation_offset(lp, p^)
	if !valid {
		return nil
	}
	end := p^
	removed_count := u64(0)
	for end[0] != PACK_END && removed_count < num {
		end = lp_skip(end)
		if end == nil {
			return nil
		}
		removed_count += 1
	}
	result := splice_bytes(lp, offset, pdiff(end, p^), removed_count, nil, 0)
	if result != nil {
		p^ = padd(result, offset)
		if p^[0] == PACK_END {
			p^ = nil
		}
	}
	return result
}

lp_delete :: proc(lp: [^]u8, p: [^]u8, newp: ^[^]u8) -> [^]u8 {
	cursor := p
	result := lp_delete_range_with_entry(lp, &cursor, 1)
	if result != nil && newp != nil {
		newp^ = cursor
	}
	return result
}

lp_delete_range :: proc(lp: [^]u8, index: i64, num: u64) -> [^]u8 {
	cursor := lp_seek(lp, index)
	return lp_delete_range_with_entry(lp, &cursor, num)
}

sort_offsets :: proc(values: []int) {
	for start := len(values) / 2 - 1; start >= 0; start -= 1 {
		sift_offset_heap(values, start, len(values))
	}
	for end := len(values) - 1; end > 0; end -= 1 {
		values[0], values[end] = values[end], values[0]
		sift_offset_heap(values, 0, end)
	}
}

sift_offset_heap :: proc(values: []int, root, count: int) {
	position := root
	for position < count / 2 {
		child := position * 2 + 1
		if child + 1 < count && values[child] < values[child + 1] {
			child += 1
		}
		if values[position] >= values[child] {
			break
		}
		values[position], values[child] = values[child], values[position]
		position = child
	}
}

lp_batch_delete :: proc(lp: [^]u8, ps: [][^]u8) -> [^]u8 {
	if len(ps) == 0 {
		return lp
	}
	offsets := make([]int, len(ps))
	defer delete(offsets)
	for p, index in ps {
		offset, valid := mutation_offset(lp, p)
		if !valid || p[0] == PACK_END {
			return nil
		}
		offsets[index] = offset
	}
	sort_offsets(offsets)
	unique := 0
	for offset in offsets {
		if unique == 0 || offsets[unique - 1] != offset {
			offsets[unique] = offset
			unique += 1
		}
	}
	old_size := lp_bytes(lp)
	dependencies := capture_header_dependencies(lp)
	mapped_dependencies: Header_Dependencies
	for entry in dependencies.entries[:dependencies.count] {
		mapped := entry
		kept := true
		for index in 0..<unique {
			if offsets[index] == entry.start {
				kept = false
				break
			}
			if offsets[index] < entry.start {
				p := padd(lp, offsets[index])
				mapped.start -= pdiff(lp_skip(p), p)
			}
		}
		if kept {
			mapped_dependencies.entries[mapped_dependencies.count] = mapped
			mapped_dependencies.count += 1
		}
	}
	removed_bytes := 0
	for index in 0..<unique {
		p := padd(lp, offsets[index])
		next := lp_skip(p)
		if next == nil || uintptr(next) >= uintptr(lp) + uintptr(old_size) {
			return nil
		}
		removed_bytes += pdiff(next, p)
	}
	count := u64(lp_get_num_elements(lp))
	if count != COUNT_UNTRACKED && u64(unique) > count {
		return nil
	}
	write_offset := offsets[0]
	for index in 0..<unique {
		read_offset := pdiff(lp_skip(padd(lp, offsets[index])), lp)
		end := old_size
		if index + 1 < unique {
			end = offsets[index + 1]
		}
		copy(lp[write_offset:write_offset + end - read_offset], lp[read_offset:end])
		write_offset += end - read_offset
	}
	lp_set_total_bytes(lp, u64(old_size - removed_bytes))
	if count != COUNT_UNTRACKED {
		lp_set_num_elements(lp, count - u64(unique))
	}
	repair_header_dependencies(lp, mapped_dependencies)
	return lp_shrink_to_fit(lp)
}

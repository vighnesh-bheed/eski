package listpack

random_state: u64 = 11400714819323198485

lp_srand :: proc "contextless" (seed: u64) {
	random_state = seed if seed != 0 else 11400714819323198485
}

lp_rand :: proc "contextless" () -> u32 {
	state := random_state
	state ~= state >> 12
	state ~= state << 25
	state ~= state >> 27
	random_state = state
	return u32((state * 2685821657736338717) >> 33)
}

random_below :: proc "contextless" (limit: u64) -> u64 {
	if limit <= 1 {
		return 0
	}
	threshold := (max(u64) - limit + 1) % limit
	for {
		value := u64(lp_rand()) << 33 | u64(lp_rand()) << 2 | u64(lp_rand() & 3)
		if value >= threshold {
			return value % limit
		}
	}
}

Sample_Choice :: struct {
	rank: u64,
	slot: int,
}

sample_choice_less :: proc(a, b: Sample_Choice) -> bool {
	return a.rank < b.rank || (a.rank == b.rank && a.slot < b.slot)
}

sift_sample_heap :: proc(values: []Sample_Choice, root, count: int) {
	position := root
	for position < count / 2 {
		child := position * 2 + 1
		if child + 1 < count && sample_choice_less(values[child], values[child + 1]) {
			child += 1
		}
		if !sample_choice_less(values[position], values[child]) {
			break
		}
		values[position], values[child] = values[child], values[position]
		position = child
	}
}

sort_sample_choices :: proc(values: []Sample_Choice) {
	for start := len(values) / 2 - 1; start >= 0; start -= 1 {
		sift_sample_heap(values, start, len(values))
	}
	for end := len(values) - 1; end > 0; end -= 1 {
		values[0], values[end] = values[end], values[0]
		sift_sample_heap(values, 0, end)
	}
}

write_sample_choices :: proc(lp: [^]u8, choices: []Sample_Choice, keys, vals: []Entry, tuple_len: int) {
	sort_sample_choices(choices)
	cursor := lp_first(lp)
	rank := u64(0)
	for choice in choices {
		for cursor != nil && rank < choice.rank {
			for _ in 0..<tuple_len {
				cursor = lp_next(lp, cursor)
			}
			rank += 1
		}
		if cursor == nil {
			return
		}
		keys[choice.slot] = lp_get_entry(cursor)
		if len(vals) > 0 && tuple_len >= 2 {
			vals[choice.slot] = lp_get_entry(lp_next(lp, cursor))
		}
	}
}

lp_random_pair :: proc(lp: [^]u8, total_count: u64, key: ^Entry, val: ^Entry, tuple_len: int) {
	if lp == nil || tuple_len < 1 || total_count == 0 || key == nil {
		return
	}
	available := lp_length(lp) / u64(tuple_len)
	count := min(total_count, available)
	if count == 0 {
		return
	}
	cursor := lp_seek(lp, i64(random_below(count) * u64(tuple_len)))
	if cursor == nil {
		return
	}
	key^ = lp_get_entry(cursor)
	if val != nil && tuple_len >= 2 {
		val^ = lp_get_entry(lp_next(lp, cursor))
	}
}

lp_random_entries :: proc(lp: [^]u8, entries: []Entry) {
	if len(entries) == 0 || lp == nil {
		return
	}
	total := lp_length(lp)
	if total == 0 {
		return
	}
	choices := make([]Sample_Choice, len(entries))
	defer delete(choices)
	for _, slot in choices {
		choices[slot] = {rank = random_below(total), slot = slot}
	}
	write_sample_choices(lp, choices, entries, nil, 1)
}

lp_random_pairs :: proc(lp: [^]u8, count: int, keys: []Entry, vals: []Entry, tuple_len: int) {
	if lp == nil || count <= 0 || tuple_len < 1 {
		return
	}
	total := lp_length(lp) / u64(tuple_len)
	if total == 0 {
		return
	}
	requested := min(count, len(keys))
	if len(vals) > 0 {
		requested = min(requested, len(vals))
	}
	choices := make([]Sample_Choice, requested)
	defer delete(choices)
	for _, slot in choices {
		choices[slot] = {rank = random_below(total), slot = slot}
	}
	write_sample_choices(lp, choices, keys, vals, tuple_len)
}

lp_random_pairs_unique :: proc(lp: [^]u8, count: int, keys: []Entry, vals: []Entry, tuple_len: int) -> int {
	if lp == nil || count <= 0 || tuple_len < 2 {
		return 0
	}
	total := lp_length(lp) / u64(tuple_len)
	requested := min(u64(count), total, u64(len(keys)))
	if len(vals) > 0 {
		requested = min(requested, u64(len(vals)))
	}
	remaining := requested
	cursor := lp_first(lp)
	available := total
	written := 0
	for cursor != nil && remaining > 0 && available > 0 {
		if random_below(available) < remaining {
			keys[written] = lp_get_entry(cursor)
			if len(vals) > 0 {
				vals[written] = lp_get_entry(lp_next(lp, cursor))
			}
			written += 1
			remaining -= 1
		}
		available -= 1
		for _ in 0..<tuple_len {
			cursor = lp_next(lp, cursor)
		}
	}
	return written
}

lp_next_random :: proc(lp: [^]u8, p: [^]u8, index: ^u32, remaining: u32, tuple_len: int) -> [^]u8 {
	if lp == nil || p == nil || index == nil || remaining == 0 || tuple_len < 1 {
		return nil
	}
	total := lp_length(lp)
	position := u64(index^)
	if position >= total {
		return nil
	}
	alignment_steps := (u64(tuple_len) - position % u64(tuple_len)) % u64(tuple_len)
	if alignment_steps >= total - position {
		return nil
	}
	cursor := p
	for _ in 0..<alignment_steps {
		cursor = lp_next(lp, cursor)
	}
	position += alignment_steps
	available := 1 + (total - position - 1) / u64(tuple_len)
	for cursor != nil && available > 0 {
		if u64(remaining) >= available || random_below(available) < u64(remaining) {
			index^ = u32(position)
			return cursor
		}
		for _ in 0..<tuple_len {
			cursor = lp_next(lp, cursor)
		}
		position += u64(tuple_len)
		available -= 1
	}
	return nil
}

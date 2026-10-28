package settype

scan_reverse :: proc "contextless" (value: u64) -> u64 {
	input := value
	output := u64(0)
	for _ in 0 ..< 64 {
		output = (output << 1) | (input & 1)
		input >>= 1
	}
	return output
}

cursor_next :: proc "contextless" (v: u64, mask: u64) -> u64 {
	return scan_reverse(scan_reverse(v | ~mask) + 1)
}

slots_scan_bucket :: proc(slots: [^]Slot, cap: int, bucket: u64, out: ^[dynamic]Value) -> (sampled: int) {
	if cap == 0 {
		return 0
	}
	mask := u64(cap - 1)
	index := int(bucket & mask)
	for _ in 0 ..< cap {
		slot := slots[index]
		if slot.blob == nil {
			break
		}
		if blob_live(slot.blob) && slot.hash & mask == bucket & mask {
			append(out, Value{str = blob_bytes(slot.blob)})
			sampled += 1
		}
		index = (index + 1) & (cap - 1)
	}
	return
}

scan_bucket :: proc(t: ^Table, v: u64, out: ^[dynamic]Value) -> (next: u64, sampled: int) {
	if t.cap == 0 || t.count == 0 {
		return 0, 0
	}
	if t.resize == nil {
		sampled = slots_scan_bucket(t.slots, t.cap, v & u64(t.cap - 1), out)
		return cursor_next(v, u64(t.cap - 1)), sampled
	}
	small, small_cap := t.slots, t.cap
	large, large_cap := t.resize.old_slots, t.resize.old_cap
	if small_cap > large_cap {
		small, large = large, small
		small_cap, large_cap = large_cap, small_cap
	}
	small_mask := u64(small_cap - 1)
	large_mask := u64(large_cap - 1)
	sampled = slots_scan_bucket(small, small_cap, v & small_mask, out)
	cursor := v
	for {
		sampled += slots_scan_bucket(large, large_cap, cursor & large_mask, out)
		cursor = cursor_next(cursor, large_mask)
		if cursor & (small_mask ~ large_mask) == 0 {
			break
		}
	}
	return cursor, sampled
}

scan :: proc(s: Set, cursor: u64, count: int, out: ^[dynamic]Value) -> u64 {
	if s == nil || size(s) == 0 {
		return 0
	}
	if s.encoding != .Hashtable {
		it := iterator(s)
		for {
			value, ok := next(&it)
			if !ok {
				break
			}
			append(out, value)
		}
		return 0
	}
	limit := max(0, count)
	budget := max(int) if limit > max(int) / 10 else max(1, limit * 10)
	current := cursor
	collected := 0
	for _ in 0 ..< budget {
		n: int
		current, n = scan_bucket(s.table, current, out)
		collected += n
		if current == 0 || collected >= limit {
			break
		}
	}
	return current
}

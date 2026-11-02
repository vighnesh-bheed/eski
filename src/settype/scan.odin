package settype

reverse_increment :: proc "contextless" (cursor: u64, mask: u64) -> u64 {
	position := cursor & mask
	for bit := mask ~ (mask >> 1); bit != 0; bit >>= 1 {
		if position & bit == 0 {
			return position | bit
		}
		position &~= bit
	}
	return 0
}

slots_scan_bucket :: proc(slots: [^]Slot, cap: int, bucket: u64, out: ^[dynamic]Member) -> (sampled: int) {
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
			append(out, Member{text = blob_bytes(slot.blob)})
			sampled += 1
		}
		index = (index + 1) & (cap - 1)
	}
	return
}

Bank :: struct {
	slots: [^]Slot,
	cap:   int,
}

bank_mask :: proc "contextless" (bank: Bank) -> u64 {
	return u64(bank.cap - 1)
}

bank_collect :: proc(bank: Bank, bucket: u64, out: ^[dynamic]Member) -> int {
	return slots_scan_bucket(bank.slots, bank.cap, bucket & bank_mask(bank), out)
}

scan_bucket :: proc(t: ^Table, v: u64, out: ^[dynamic]Member) -> (next: u64, sampled: int) {
	if t.count == 0 || t.cap == 0 {
		return 0, 0
	}
	current := Bank{t.slots, t.cap}
	if t.resize == nil {
		sampled = bank_collect(current, v, out)
		return reverse_increment(v, bank_mask(current)), sampled
	}
	coarse, fine := current, Bank{t.resize.old_slots, t.resize.old_cap}
	if coarse.cap > fine.cap {
		coarse, fine = fine, coarse
	}
	sampled = bank_collect(coarse, v, out)
	spread := bank_mask(coarse) ~ bank_mask(fine)
	next = v
	for {
		sampled += bank_collect(fine, next, out)
		next = reverse_increment(next, bank_mask(fine))
		if next & spread == 0 {
			return
		}
	}
}

scan :: proc(s: Set, cursor: u64, count: int, out: ^[dynamic]Member) -> u64 {
	if size(s) == 0 {
		return 0
	}
	if s.encoding != .Hashtable {
		walk := iterator(s)
		for member in next(&walk) {
			append(out, member)
		}
		return 0
	}
	wanted := max(count, 0)
	visits := max(int) if wanted > max(int) / 10 else max(wanted * 10, 1)
	position := cursor
	gathered := 0
	for ; visits > 0; visits -= 1 {
		found: int
		position, found = scan_bucket(s.table, position, out)
		gathered += found
		if position == 0 || gathered >= wanted {
			break
		}
	}
	return position
}

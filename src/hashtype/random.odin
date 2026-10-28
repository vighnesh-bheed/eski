package hashtype

import lp "../listpack"

HRANDFIELD_SUB_STRATEGY_MUL :: 3
HRANDFIELD_RANDOM_SAMPLE_LIMIT :: 1000

random_state: u64 = 0x8b8b8b8b5a5a5a5a

rand64 :: #force_inline proc "contextless" () -> u64 {
	x := random_state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	random_state = x
	return x * 0x2545f4914f6cdd1d
}

rand_below :: #force_inline proc "contextless" (n: u64) -> u64 {
	if n <= 1 {
		return 0
	}
	if n & (n - 1) == 0 {
		return rand64() & (n - 1)
	}
	threshold := (0 - n) % n
	for {
		x := rand64()
		if x >= threshold {
			return x % n
		}
	}
}

table_random_blob :: proc "contextless" (t: ^Table) -> ^Blob {
	if t.count == 0 {
		return nil
	}
	total := t.cap
	if t.resize != nil {
		total += t.resize.old_cap
	}
	for _ in 0 ..< 32 {
		i := int(rand_below(u64(total)))
		b: ^Blob
		if i < t.cap {
			b = t.slots[i].blob
		} else {
			b = t.resize.old_slots[i - t.cap].blob
		}
		if blob_live(b) {
			return b
		}
	}
	rank := int(rand_below(u64(t.count)))
	for bank in 0 ..< 2 {
		slots, cap := table_bank(t, bank)
		for i in 0 ..< cap {
			if blob_live(slots[i].blob) {
				if rank == 0 {
					return slots[i].blob
				}
				rank -= 1
			}
		}
	}
	return nil
}

random_element :: proc(h: Hash) -> (field: Value, value: Value) {
	if length(h) == 0 {
		return
	}
	if h.encoding == .Hashtable {
		b := table_random_blob(h.table)
		return Value{str = blob_field(b)}, Value{str = blob_value(b)}
	}
	f, v: lp.Entry
	lp.lp_random_pair(h.lp, u64(length(h)), &f, &v, tuple_len(h))
	return value_from_entry(f), value_from_entry(v)
}

Random_Choice :: struct {
	index: int,
	order: int,
}

random_with_repeats :: proc(h: Hash, count: int, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) {
	n := length(h)
	if n == 0 || count <= 0 {
		return
	}
	if h.encoding == .Hashtable {
		for _ in 0 ..< count {
			b := table_random_blob(h.table)
			append(fields, Value{str = blob_field(b)})
			if with_values {
				append(values, Value{str = blob_value(b)})
			}
		}
		return
	}
	remaining := count
	for remaining > 0 {
		batch := min(remaining, HRANDFIELD_RANDOM_SAMPLE_LIMIT)
		choices := make([]Random_Choice, batch)
		start := len(fields^)
		vstart := len(values^)
		for i in 0 ..< batch {
			choices[i] = Random_Choice{index = int(rand_below(u64(n))), order = i}
			append(fields, Value{})
			if with_values {
				append(values, Value{})
			}
		}
		for i in 1 ..< batch {
			x := choices[i]
			j := i
			for j > 0 && choices[j - 1].index > x.index {
				choices[j] = choices[j - 1]
				j -= 1
			}
			choices[j] = x
		}
		it := iterator(h)
		row := 0
		pick := 0
		for next(&it) {
			for pick < batch && choices[pick].index == row {
				order := choices[pick].order
				fields^[start + order] = current_field(&it)
				if with_values {
					values^[vstart + order] = current_value(&it)
				}
				pick += 1
			}
			if pick == batch {
				break
			}
			row += 1
		}
		delete(choices)
		remaining -= batch
	}
}

Unique_Set :: struct {
	slots: []u64,
	mask: u64,
}

unique_insert :: proc "contextless" (s: ^Unique_Set, idx: int) -> bool {
	x := u64(idx) + 1
	i := ((x >> 4) ~ (x >> 20) ~ x) & s.mask
	for s.slots[i] != 0 {
		if s.slots[i] == x {
			return false
		}
		i = (i + 1) & s.mask
	}
	s.slots[i] = x
	return true
}

random_unique_try_table :: proc(t: ^Table, count, attempt_budget: int, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) -> bool {
	resize_require(count > 0 && count <= t.count && count <= HRANDFIELD_RANDOM_SAMPLE_LIMIT && attempt_budget >= 0)
	if attempt_budget == 0 {
		return false
	}
	if count == 1 {
		b := table_random_blob(t)
		append(fields, Value{str = blob_field(b)})
		if with_values {
			append(values, Value{str = blob_value(b)})
		}
		return true
	}
	capacity := next_pow2(count * 2)
	storage := mem_alloc(capacity * size_of(u64))
	defer mem_free(storage)
	seen := Unique_Set{slots = (cast([^]u64)storage)[:capacity]}
	seen.mask = u64(len(seen.slots) - 1)
	start := len(fields^)
	vstart := len(values^)
	for _ in 0 ..< attempt_budget {
		b := table_random_blob(t)
		if !unique_insert(&seen, int(uintptr(b))) {
			continue
		}
		append(fields, Value{str = blob_field(b)})
		if with_values {
			append(values, Value{str = blob_value(b)})
		}
		if len(fields^) - start == count {
			return true
		}
	}
	resize(fields, start)
	resize(values, vstart)
	return false
}

random_unique :: proc(h: Hash, count: int, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) {
	n := length(h)
	k := min(max(count, 0), n)
	if k == 0 {
		return
	}
	if h.encoding == .Hashtable && k <= HRANDFIELD_RANDOM_SAMPLE_LIMIT && k <= n / HRANDFIELD_SUB_STRATEGY_MUL {
		if random_unique_try_table(h.table, k, k * 8 + 32, with_values, fields, values) {
			return
		}
	}
	start := len(fields^)
	vstart := len(values^)
	it := iterator(h)
	row := 0
	for next(&it) {
		if row < k {
			append(fields, current_field(&it))
			if with_values {
				append(values, current_value(&it))
			}
		} else if slot := int(rand_below(u64(row + 1))); slot < k {
			fields^[start + slot] = current_field(&it)
			if with_values {
				values^[vstart + slot] = current_value(&it)
			}
		}
		row += 1
	}
	if k == n {
		return
	}
	for i := k - 1; i > 0; i -= 1 {
		j := int(rand_below(u64(i + 1)))
		fields^[start + i], fields^[start + j] = fields^[start + j], fields^[start + i]
		if with_values {
			values^[vstart + i], values^[vstart + j] = values^[vstart + j], values^[vstart + i]
		}
	}
}

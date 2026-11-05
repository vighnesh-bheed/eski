package hashtype

import lp "../listpack"
import "base:intrinsics"

RANDOM_PICK_BATCH :: 1000

random_state: u64 = 0x8b8b8b8b5a5a5a5a

rand64 :: #force_inline proc "contextless" () -> u64 {
	previous := intrinsics.atomic_load_explicit(&random_state, .Relaxed)
	for {
		x := previous
		x ~= x >> 12
		x ~= x << 25
		x ~= x >> 27
		observed, exchanged := intrinsics.atomic_compare_exchange_weak_explicit(&random_state, previous, x, .Relaxed, .Relaxed)
		if exchanged {
			return x * 0x2545f4914f6cdd1d
		}
		previous = observed
	}
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
	f, v: lp.Element
	lp.lp_random_pair(h.lp, u64(length(h)), &f, &v, pack_stride(h))
	return value_from_entry(f), value_from_entry(v)
}

put_pick :: #force_inline proc(fields: ^[dynamic]Value, values: ^[dynamic]Value, keep_value: bool, field: Value, value: Value) {
	append(fields, field)
	if keep_value {
		append(values, value)
	}
}

put_blob :: #force_inline proc(fields: ^[dynamic]Value, values: ^[dynamic]Value, keep_value: bool, b: ^Blob) {
	put_pick(fields, values, keep_value, Value{str = blob_field(b)}, Value{str = blob_value(b)})
}

Packed_Row :: struct {
	field: Value,
	value: Value,
}

packed_rows :: proc(h: Hash) -> []Packed_Row {
	rows := make([dynamic]Packed_Row, 0, length(h))
	walk := iterator(h)
	for next(&walk) {
		append(&rows, Packed_Row{current_field(&walk), current_value(&walk)})
	}
	return rows[:]
}

packed_repeats :: proc(h: Hash, count: int, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) {
	rows := packed_rows(h)
	defer delete(rows)
	if len(rows) == 0 {
		return
	}
	for _ in 0 ..< count {
		row := rows[rand_below(u64(len(rows)))]
		put_pick(fields, values, with_values, row.field, row.value)
	}
}

random_with_repeats :: proc(h: Hash, count: int, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) {
	if count <= 0 || length(h) == 0 {
		return
	}
	if h.encoding != .Hashtable {
		packed_repeats(h, count, with_values, fields, values)
		return
	}
	for _ in 0 ..< count {
		put_blob(fields, values, with_values, table_random_blob(h.table))
	}
}

every_row :: proc(h: Hash, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) {
	walk := iterator(h)
	for next(&walk) {
		put_pick(fields, values, with_values, current_field(&walk), current_value(&walk))
	}
}

packed_ordered_subset :: proc(h: Hash, want: int, total: int, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) {
	chosen := make([]bool, total)
	defer delete(chosen)
	for top in total - want ..< total {
		pick := int(rand_below(u64(top + 1)))
		if chosen[pick] {
			chosen[top] = true
		} else {
			chosen[pick] = true
		}
	}
	walk := iterator(h)
	for position := 0; next(&walk); position += 1 {
		if position < total && chosen[position] {
			put_pick(fields, values, with_values, current_field(&walk), current_value(&walk))
		}
	}
}

table_distinct_draws :: proc(t: ^Table, want: int, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) {
	taken := make(map[^Blob]struct{}, want)
	defer delete(taken)
	for len(taken) < want {
		b := table_random_blob(t)
		if b == nil {
			return
		}
		if b in taken {
			continue
		}
		taken[b] = {}
		put_blob(fields, values, with_values, b)
	}
}

table_shuffled_prefix :: proc(t: ^Table, want: int, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) {
	pool := make([dynamic]^Blob, 0, t.count)
	defer delete(pool)
	for bank in 0 ..< 2 {
		slots, capacity := table_bank(t, bank)
		for i in 0 ..< capacity {
			if blob_live(slots[i].blob) {
				append(&pool, slots[i].blob)
			}
		}
	}
	for front in 0 ..< min(want, len(pool)) {
		swap := front + int(rand_below(u64(len(pool) - front)))
		pool[front], pool[swap] = pool[swap], pool[front]
		put_blob(fields, values, with_values, pool[front])
	}
}

random_unique :: proc(h: Hash, count: int, with_values: bool, fields: ^[dynamic]Value, values: ^[dynamic]Value) {
	total := length(h)
	want := clamp(count, 0, total)
	switch {
	case want == 0:
		return
	case want == total:
		every_row(h, with_values, fields, values)
	case h.encoding != .Hashtable:
		packed_ordered_subset(h, want, total, with_values, fields, values)
	case want * 2 <= total:
		table_distinct_draws(h.table, want, with_values, fields, values)
	case:
		table_shuffled_prefix(h.table, want, with_values, fields, values)
	}
}

package hashtype

import xx "core:hash/xxhash"
import "base:intrinsics"

TABLE_INITIAL_SIZE :: 4
TABLE_MIN_FILL :: 8

Blob :: struct {
	flen: u32,
	vlen: u32,
	hidx: u32,
}

Slot :: struct {
	hash: u64,
	blob: ^Blob,
}

Vol_Item :: struct {
	expire: u64,
	blob: ^Blob,
}

Table :: struct {
	slots: [^]Slot,
	cap: int,
	count: int,
	blob_bytes: int,
	vol: [^]Vol_Item,
	vol_len: int,
	vol_cap: int,
	resize: ^Resize_State,
}

TABLE_MAX_CAPACITY :: (max(int) / size_of(Slot) + 1) / 2

hash_seed: u64 = 0x5851F42D4C957F2D
EMPTY_FIELD := [1]u8{0}

set_hash_seed :: proc "contextless" (seed: u64) {
	intrinsics.atomic_store_explicit(&hash_seed, seed, .Relaxed)
}

hash_field :: #force_inline proc(field: []u8) -> u64 {
	if len(field) == 0 {
		return xx.XXH3_64_with_seed(EMPTY_FIELD[:0], intrinsics.atomic_load_explicit(&hash_seed, .Relaxed))
	}
	return xx.XXH3_64_with_seed(field, intrinsics.atomic_load_explicit(&hash_seed, .Relaxed))
}

blob_field :: #force_inline proc "contextless" (b: ^Blob) -> []u8 {
	return (cast([^]u8)b)[size_of(Blob):size_of(Blob) + int(b.flen)]
}

blob_value :: #force_inline proc "contextless" (b: ^Blob) -> []u8 {
	offset := size_of(Blob) + int(b.flen)
	return (cast([^]u8)b)[offset:offset + int(b.vlen)]
}

blob_new :: proc "contextless" (t: ^Table, field, value: []u8) -> ^Blob {
	b := cast(^Blob)mem_alloc_uninitialized(size_of(Blob) + len(field) + len(value))
	b.flen = u32(len(field))
	b.vlen = u32(len(value))
	b.hidx = 0
	copy(blob_field(b), field)
	copy(blob_value(b), value)
	t.blob_bytes += mem_usable_size(b)
	return b
}

blob_set_value :: proc "contextless" (t: ^Table, b: ^Blob, value: []u8) -> ^Blob {
	if int(b.vlen) == len(value) {
		copy(blob_value(b), value)
		return b
	}
	n := blob_new(t, blob_field(b), value)
	n.hidx = b.hidx
	if n.hidx != 0 {
		t.vol[n.hidx - 1].blob = n
	}
	t.blob_bytes -= mem_usable_size(b)
	mem_free(b)
	return n
}

blob_free :: proc "contextless" (t: ^Table, b: ^Blob) {
	if b.hidx != 0 {
		vol_remove(t, b)
	}
	t.blob_bytes -= mem_usable_size(b)
	mem_free(b)
}

checked_table_capacity :: proc "contextless" (n: int) -> (capacity: int, valid: bool) {
	if n < 0 || n > TABLE_MAX_CAPACITY {
		return 0, false
	}
	c := TABLE_INITIAL_SIZE
	for c < n {
		c *= 2
	}
	return c, true
}

checked_count_capacity :: proc "contextless" (n: int) -> (capacity: int, valid: bool) {
	if n < 0 || n > TABLE_MAX_CAPACITY {
		return 0, false
	}
	return checked_table_capacity(n + n / 3 + 1)
}

next_pow2 :: proc "contextless" (n: int) -> int {
	capacity, valid := checked_table_capacity(n)
	resize_require(valid)
	return capacity
}

cap_for :: proc "contextless" (n: int) -> int {
	capacity, valid := checked_count_capacity(n)
	resize_require(valid)
	return capacity
}

table_make :: proc "contextless" (expected: int) -> ^Table {
	capacity := cap_for(expected)
	t := cast(^Table)mem_alloc(size_of(Table))
	resize_require(t != nil)
	t.cap = capacity
	t.slots = slots_alloc(t.cap)
	return t
}

table_free :: proc "contextless" (t: ^Table) {
	if t == nil {
		return
	}
	for bank in 0 ..< 2 {
		slots, cap := table_bank(t, bank)
		for i in 0 ..< cap {
			if blob_live(slots[i].blob) {
				blob_free(t, slots[i].blob)
			}
		}
	}
	if t.resize != nil {
		r := t.resize
		resize_unlink(r)
		slots_free(r.old_slots, r.old_cap)
		mem_free(r)
	}
	slots_free(t.slots, t.cap)
	mem_free(t.vol)
	mem_free(t)
}

table_resize :: proc "contextless" (t: ^Table, new_cap: int) {
	resize_require(new_cap >= TABLE_INITIAL_SIZE && new_cap & (new_cap - 1) == 0)
	capacity, valid := checked_table_capacity(new_cap)
	resize_require(valid && t.resize == nil)
	resize_require(t.count >= 0 && t.count < capacity)
	if capacity == t.cap {
		return
	}
	new_slots := slots_alloc(capacity)
	if t.cap == 0 {
		t.slots = new_slots
		t.cap = capacity
		return
	}
	r := cast(^Resize_State)mem_alloc(size_of(Resize_State))
	resize_require(r != nil)
	r.target = t
	r.old_slots = t.slots
	r.old_cap = t.cap
	r.old_count = t.count
	t.resize = r
	t.slots = new_slots
	t.cap = capacity
}

table_reserve :: proc "contextless" (t: ^Table, n: int) {
	capacity := cap_for(n)
	if t.resize == nil && capacity > t.cap {
		table_resize(t, capacity)
	}
}

slots_find :: #force_inline proc "contextless" (slots: [^]Slot, cap: int, field: []u8, h: u64) -> ^Slot {
	if cap == 0 {
		return nil
	}
	i := int(h & u64(cap - 1))
	for _ in 0 ..< cap {
		s := &slots[i]
		if s.blob == nil {
			return nil
		}
		if blob_live(s.blob) && s.hash == h && bytes_equal(blob_field(s.blob), field) {
			return s
		}
		i = (i + 1) & (cap - 1)
	}
	return nil
}

table_find :: #force_inline proc "contextless" (t: ^Table, field: []u8, h: u64) -> ^Slot {
	if s := slots_find(t.slots, t.cap, field, h); s != nil {
		return s
	}
	if t.resize != nil {
		return slots_find(t.resize.old_slots, t.resize.old_cap, field, h)
	}
	return nil
}

table_grow_if_needed :: proc "contextless" (t: ^Table) {
	resize_require(t.count >= 0)
	if t.cap == 0 {
		table_resize(t, TABLE_INITIAL_SIZE)
	} else if t.resize == nil && t.count >= t.cap - t.cap / 4 {
		resize_require(t.cap <= TABLE_MAX_CAPACITY / 2)
		table_resize(t, t.cap * 2)
	}
}

slots_place :: proc "contextless" (slots: [^]Slot, cap: int, s: Slot) -> (probes: int) {
	i := int(s.hash & u64(cap - 1))
	for {
		probes += 1
		if !blob_live(slots[i].blob) {
			slots[i] = s
			return
		}
		i = (i + 1) & (cap - 1)
	}
}

table_place :: proc "contextless" (t: ^Table, h: u64, b: ^Blob) {
	slots_place(t.slots, t.cap, Slot{hash = h, blob = b})
	t.count += 1
}

table_insert_absent :: proc(t: ^Table, field, value: []u8, h: u64) -> ^Blob {
	table_grow_if_needed(t)
	b := blob_new(t, field, value)
	table_place(t, h, b)
	if t.resize != nil {
		table_step(t, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
	}
	return b
}

table_add_new :: proc(t: ^Table, field, value: []u8) -> ^Blob {
	h := hash_field(field)
	if table_find(t, field, h) != nil {
		return nil
	}
	return table_insert_absent(t, field, value, h)
}

table_set :: proc(t: ^Table, field, value: []u8, keep_ttl := false) -> (updated: bool) {
	h := hash_field(field)
	s := table_find(t, field, h)
	if s == nil {
		table_insert_absent(t, field, value, h)
		return false
	}
	if !keep_ttl && s.blob.hidx != 0 {
		vol_remove(t, s.blob)
	}
	s.blob = blob_set_value(t, s.blob, value)
	if t.resize != nil {
		table_step(t, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
	}
	return true
}

table_get :: #force_inline proc(t: ^Table, field: []u8) -> (value: []u8, found: bool) {
	if s := table_find(t, field, hash_field(field)); s != nil {
		return blob_value(s.blob), true
	}
	return nil, false
}

table_delete_at :: proc "contextless" (t: ^Table, slot: ^Slot) {
	blob_free(t, slot.blob)
	t.count -= 1
	if t.resize != nil {
		a := uintptr(slot)
		start := uintptr(t.resize.old_slots)
		if a >= start && a < start + uintptr(t.resize.old_cap * size_of(Slot)) {
			slot.blob = TOMBSTONE
			t.resize.old_count -= 1
			return
		}
	}
	mask := t.cap - 1
	hole := int((uintptr(slot) - uintptr(t.slots)) / size_of(Slot))
	i := (hole + 1) & mask
	for t.slots[i].blob != nil {
		home := int(t.slots[i].hash & u64(mask))
		if ((i - home) & mask) >= ((hole - home) & mask) {
			t.slots[hole] = t.slots[i]
			hole = i
		}
		i = (i + 1) & mask
	}
	t.slots[hole] = {}
}

table_shrink_if_needed :: proc "contextless" (t: ^Table) {
	if t.resize == nil && t.cap > TABLE_INITIAL_SIZE && t.count < t.cap / TABLE_MIN_FILL {
		table_resize(t, cap_for(t.count))
	}
}

table_delete :: proc(t: ^Table, field: []u8) -> bool {
	s := table_find(t, field, hash_field(field))
	if s == nil {
		return false
	}
	table_delete_at(t, s)
	if t.count == 0 {
		table_empty(t)
	} else {
		if t.resize != nil {
			table_step(t, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
		}
		table_shrink_if_needed(t)
	}
	return true
}

table_memory :: proc "contextless" (t: ^Table) -> int {
	if t == nil {
		return 0
	}
	n := mem_usable_size(t) + t.blob_bytes + mem_usable_size(t.vol) + slots_memory(t.slots, t.cap)
	if t.resize != nil {
		n += mem_usable_size(t.resize) + slots_memory(t.resize.old_slots, t.resize.old_cap)
	}
	return n
}

read_word64 :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	v: u64
	copy((cast([^]u8)&v)[:size_of(v)], p[:size_of(v)])
	return v
}

read_word32 :: #force_inline proc "contextless" (p: [^]u8) -> u32 {
	v: u32
	copy((cast([^]u8)&v)[:size_of(v)], p[:size_of(v)])
	return v
}

read_word16 :: #force_inline proc "contextless" (p: [^]u8) -> u16 {
	v: u16
	copy((cast([^]u8)&v)[:size_of(v)], p[:size_of(v)])
	return v
}

bytes_equal :: #force_inline proc "contextless" (a, b: []u8) -> bool #no_bounds_check {
	if len(a) != len(b) {
		return false
	}
	left := raw_data(a)
	right := raw_data(b)
	remaining := len(a)
	for remaining >= size_of(u64) {
		if read_word64(left) != read_word64(right) {
			return false
		}
		left = cast([^]u8)(uintptr(left) + size_of(u64))
		right = cast([^]u8)(uintptr(right) + size_of(u64))
		remaining -= size_of(u64)
	}
	if remaining >= size_of(u32) {
		if read_word32(left) != read_word32(right) {
			return false
		}
		left = cast([^]u8)(uintptr(left) + size_of(u32))
		right = cast([^]u8)(uintptr(right) + size_of(u32))
		remaining -= size_of(u32)
	}
	if remaining >= size_of(u16) {
		if read_word16(left) != read_word16(right) {
			return false
		}
		left = cast([^]u8)(uintptr(left) + size_of(u16))
		right = cast([^]u8)(uintptr(right) + size_of(u16))
		remaining -= size_of(u16)
	}
	return remaining == 0 || left[0] == right[0]
}

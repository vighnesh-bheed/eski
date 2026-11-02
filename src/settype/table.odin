package settype

import lp "../listpack"
import xxhash "core:hash/xxhash"
import "base:runtime"
import "base:intrinsics"
import "core:sync"

TABLE_INITIAL_SIZE :: 4
TABLE_SPARSE_RATIO :: 8
TABLE_RANDOM_PROBES :: 4096
TABLE_MAX_CAPACITY :: (max(int) / size_of(Slot) + 1) / 2

Blob :: struct {
	len: u32,
}

Slot :: struct {
	hash: u64,
	blob: ^Blob,
}

Table :: struct {
	slots:      [^]Slot,
	cap:        int,
	count:      int,
	blob_bytes: int,
	resize:     ^Resize_State,
}

hash_seed: u64 = 0x9E3779B97F4A7C15
hash_seeded: bool
hash_seed_init_mutex: sync.Mutex
EMPTY_MEMBER := [1]u8{0}
set_random_state: u64 = 0xD1B54A32D192ED03

set_hash_seed :: proc "contextless" (seed: u64) {
	intrinsics.atomic_store_explicit(&hash_seed, seed, .Relaxed)
	intrinsics.atomic_store_explicit(&hash_seeded, true, .Release)
}

hash_member :: proc(m: []u8) -> u64 {
	if len(m) == 0 {
		return xxhash.XXH3_64_with_seed(EMPTY_MEMBER[:0], intrinsics.atomic_load_explicit(&hash_seed, .Relaxed))
	}
	return xxhash.XXH3_64_with_seed(m, intrinsics.atomic_load_explicit(&hash_seed, .Relaxed))
}

blob_bytes :: proc "contextless" (b: ^Blob) -> []u8 {
	p := lp.padd(cast([^]u8)b, size_of(Blob))
	return p[:int(b.len)]
}

blob_new :: proc "contextless" (t: ^Table, m: []u8) -> ^Blob {
	resize_require(u64(len(m)) <= u64(max(u32)) && len(m) <= max(int) - size_of(Blob))
	b := cast(^Blob)lp.lp_malloc(size_of(Blob) + len(m))
	resize_require(b != nil)
	b.len = u32(len(m))
	copy(blob_bytes(b), m)
	t.blob_bytes += lp.lp_malloc_size(b)
	return b
}

blob_free :: proc "contextless" (t: ^Table, b: ^Blob) {
	t.blob_bytes -= lp.lp_malloc_size(b)
	lp.lp_mem_free(b)
}

next_pow2 :: proc "contextless" (n: int) -> int {
	resize_require(n >= 0 && n <= TABLE_MAX_CAPACITY)
	cap := TABLE_INITIAL_SIZE
	for cap < n {
		cap *= 2
	}
	return cap
}

cap_for :: proc "contextless" (n: int) -> int {
	resize_require(n >= 0 && n <= (max(int) - 2) / 4)
	return next_pow2((4 * n + 2) / 3 + 1)
}

table_make :: proc "contextless" (expected: int) -> ^Table {
	capacity := cap_for(expected)
	if !intrinsics.atomic_load_explicit(&hash_seeded, .Acquire) {
		sync.mutex_lock(&hash_seed_init_mutex)
		if !intrinsics.atomic_load_explicit(&hash_seeded, .Acquire) {
			set_hash_seed(rand64())
		}
		sync.mutex_unlock(&hash_seed_init_mutex)
	}
	t := cast(^Table)runtime.heap_alloc(size_of(Table))
	resize_require(t != nil)
	t^ = {cap = capacity, slots = slots_alloc(capacity)}
	return t
}

table_free :: proc "contextless" (t: ^Table) {
	if t == nil {
		return
	}
	for bank in 0 ..< 2 {
		slots, capacity := table_bank(t, bank)
		for i in 0 ..< capacity {
			if blob_live(slots[i].blob) {
				blob_free(t, slots[i].blob)
			}
		}
	}
	if r := t.resize; r != nil {
		resize_unlink(r)
		slots_free(r.old_slots, r.old_cap)
		lp.lp_mem_free(r)
	}
	slots_free(t.slots, t.cap)
	lp.lp_mem_free(t)
}

table_resize :: proc "contextless" (t: ^Table, new_cap: int) {
	resize_require(new_cap >= TABLE_INITIAL_SIZE && new_cap <= TABLE_MAX_CAPACITY)
	resize_require(new_cap & (new_cap - 1) == 0 && t.resize == nil)
	resize_require(t.count >= 0 && t.count < new_cap)
	if new_cap == t.cap {
		return
	}
	bank := slots_alloc(new_cap)
	if t.cap == 0 {
		t.slots = bank
		t.cap = new_cap
		return
	}
	r := cast(^Resize_State)runtime.heap_alloc(size_of(Resize_State))
	resize_require(r != nil)
	r^ = {target = t, old_slots = t.slots, old_cap = t.cap, old_count = t.count}
	t.slots = bank
	t.cap = new_cap
	t.resize = r
}

set_bytes_equal :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

slots_find :: proc "contextless" (slots: [^]Slot, cap: int, field: []u8, h: u64) -> ^Slot {
	if cap == 0 {
		return nil
	}
	index := int(h & u64(cap - 1))
	for _ in 0 ..< cap {
		slot := &slots[index]
		if slot.blob == nil {
			return nil
		}
		if blob_live(slot.blob) && slot.hash == h && set_bytes_equal(blob_bytes(slot.blob), field) {
			return slot
		}
		index = (index + 1) & (cap - 1)
	}
	return nil
}

table_find :: proc "contextless" (t: ^Table, field: []u8, h: u64) -> ^Slot {
	if slot := slots_find(t.slots, t.cap, field, h); slot != nil {
		return slot
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
	} else if t.resize == nil && t.count >= t.cap / 4 * 3 {
		resize_require(t.cap <= TABLE_MAX_CAPACITY / 2)
		table_resize(t, t.cap * 2)
	}
}

slots_place :: proc "contextless" (slots: [^]Slot, cap: int, s: Slot) -> (probes: int) {
	resize_require(cap >= TABLE_INITIAL_SIZE)
	index := int(s.hash & u64(cap - 1))
	for probes < cap {
		probes += 1
		if !blob_live(slots[index].blob) {
			slots[index] = s
			return
		}
		index = (index + 1) & (cap - 1)
	}
	resize_require(false)
	return
}

table_place :: proc "contextless" (t: ^Table, h: u64, b: ^Blob) {
	slots_place(t.slots, t.cap, {hash = h, blob = b})
	t.count += 1
}

table_add :: proc(t: ^Table, m: []u8) -> bool {
	h := hash_member(m)
	if table_find(t, m, h) != nil {
		return false
	}
	table_grow_if_needed(t)
	table_place(t, h, blob_new(t, m))
	if t.resize != nil {
		table_step(t, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
	}
	return true
}

table_add_new :: proc(t: ^Table, m: []u8) {
	table_add(t, m)
}

table_contains :: proc(t: ^Table, m: []u8) -> bool {
	return table_find(t, m, hash_member(m)) != nil
}

table_delete_at :: proc "contextless" (t: ^Table, slot: ^Slot) {
	blob_free(t, slot.blob)
	t.count -= 1
	if t.resize != nil {
		address := uintptr(slot)
		old_start := uintptr(t.resize.old_slots)
		old_end := old_start + uintptr(t.resize.old_cap) * size_of(Slot)
		if address >= old_start && address < old_end {
			slot.blob = TOMBSTONE
			t.resize.old_count -= 1
			return
		}
	}
	mask := t.cap - 1
	hole := int((uintptr(slot) - uintptr(t.slots)) / size_of(Slot))
	index := (hole + 1) & mask
	for t.slots[index].blob != nil {
		home := int(t.slots[index].hash & u64(mask))
		if ((hole - home) & mask) < ((index - home) & mask) {
			t.slots[hole] = t.slots[index]
			hole = index
		}
		index = (index + 1) & mask
	}
	t.slots[hole] = {}
}

table_shrink_if_needed :: proc "contextless" (t: ^Table) {
	sparse := t.cap > TABLE_INITIAL_SIZE && t.count * TABLE_SPARSE_RATIO <= t.cap
	if sparse && t.resize == nil {
		table_resize(t, t.cap / 2)
	}
}

table_delete :: proc(t: ^Table, field: []u8) -> bool {
	slot := table_find(t, field, hash_member(field))
	if slot == nil {
		return false
	}
	table_delete_at(t, slot)
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
	n := lp.lp_malloc_size(t) + t.blob_bytes + slots_memory(t.slots, t.cap)
	if t.resize != nil {
		n += lp.lp_malloc_size(t.resize) + slots_memory(t.resize.old_slots, t.resize.old_cap)
	}
	return n
}

rand64 :: proc "contextless" () -> u64 {
	v := intrinsics.atomic_add_explicit(&set_random_state, u64(0x9E3779B97F4A7C15), .Relaxed) + 0x9E3779B97F4A7C15
	v = (v ~ (v >> 30)) * 0xBF58476D1CE4E5B9
	v = (v ~ (v >> 27)) * 0x94D049BB133111EB
	return v ~ (v >> 31)
}

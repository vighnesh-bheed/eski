package vsettype

import "base:intrinsics"
import "base:runtime"

GOLDEN_GAMMA :: u64(0x9E3779B97F4A7C15)

vset_uid_next: u64
random_state: u64 = 0x6A09E667F3BCC909

next_uid :: proc "contextless" () -> u64 {
	return intrinsics.atomic_add_explicit(&vset_uid_next, 1, .Relaxed)
}


mix64 :: #force_inline proc "contextless" (v: u64) -> u64 {
	z := v
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

rand64 :: proc "contextless" () -> u64 {
	return mix64(intrinsics.atomic_add_explicit(&random_state, GOLDEN_GAMMA, .Relaxed) + GOLDEN_GAMMA)
}

rand_below :: proc "contextless" (n: u64) -> u64 {
	if n <= 1 {
		return 0
	}
	floor := (u64(0) - n) % n
	for {
		v := rand64()
		if v >= floor {
			return v % n
		}
	}
}

random_member :: proc "contextless" (s: Vset) -> (slot: u32, ok: bool) {
	if s == nil || s.count == 0 {
		return NIL_SLOT, false
	}
	return s.order[rand_below(u64(s.count))], true
}

repeat_total :: #force_inline proc "contextless" (count: i64) -> u64 {
	if count >= 0 {
		return 0
	}
	return u64(~count) + 1
}

random_repeats :: proc(s: Vset, count: int, out: ^[dynamic]u32) {
	if s == nil || s.count == 0 || count <= 0 {
		return
	}
	reserve(out, len(out) + count)
	for _ in 0 ..< count {
		append(out, s.order[rand_below(u64(s.count))])
	}
}

shuffle_slots :: proc "contextless" (slots: []u32) {
	for i := len(slots) - 1; i > 0; i -= 1 {
		j := int(rand_below(u64(i + 1)))
		slots[i], slots[j] = slots[j], slots[i]
	}
}

Pick_Set :: struct {
	keys: []u32,
	mask: u32,
}

pick_insert :: proc "contextless" (p: ^Pick_Set, v: u32) -> bool {
	h := (v * 0x9E3779B1) & p.mask
	for {
		k := p.keys[h]
		if k == max(u32) {
			p.keys[h] = v
			return true
		}
		if k == v {
			return false
		}
		h = (h + 1) & p.mask
	}
}

random_distinct :: proc(s: Vset, count: int, out: ^[dynamic]u32, allocator := context.temp_allocator) -> runtime.Allocator_Error {
	if s == nil || s.count == 0 || count <= 0 {
		return nil
	}
	n := s.count
	start := len(out)
	if count >= n {
		reserve(out, start + n) or_return
		append(out, ..s.order[:n])
		shuffle_slots(out[start:])
		return nil
	}
	if count * 4 <= n {
		capacity := 16
		for capacity < 2 * count {
			capacity *= 2
		}
		keys := make([]u32, capacity, allocator) or_return
		defer delete(keys, allocator)
		for &k in keys {
			k = max(u32)
		}
		picks := Pick_Set{keys = keys, mask = u32(capacity - 1)}
		reserve(out, start + count) or_return
		for j := n - count; j < n; j += 1 {
			t := u32(rand_below(u64(j + 1)))
			if pick_insert(&picks, t) {
				append(out, s.order[t])
			} else {
				pick_insert(&picks, u32(j))
				append(out, s.order[j])
			}
		}
		shuffle_slots(out[start:])
		return nil
	}
	pool := make([]u32, n, allocator) or_return
	defer delete(pool, allocator)
	copy(pool, s.order[:n])
	for i in 0 ..< count {
		j := i + int(rand_below(u64(n - i)))
		pool[i], pool[j] = pool[j], pool[i]
	}
	reserve(out, start + count) or_return
	append(out, ..pool[:count])
	return nil
}

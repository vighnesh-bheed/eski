package main

import "base:intrinsics"
import "base:runtime"
import "core:mem/virtual"
import "core:simd"
import "core:sys/linux"

GROUP_SLOTS :: 16
GROUP_SHIFT :: 4
CTRL_EMPTY :: u8(0x00)
CTRL_DELETED :: u8(0x01)
TABLE_MIN_CAP :: 16
TABLE_PAGE :: 4096
HUGE_PAGE :: 2 << 20

Group :: #simd[GROUP_SLOTS]u8

Table :: struct {
	ctrl:   [^]u8,
	slots:  #soa[]Slot,
	gmask:  u64,
	cap:    int,
	live:   int,
	tombs:  int,
	growth: int,
	region: [^]u8,
	size:   int,
}

Lookup :: struct {
	key:    []u8,
	hash:   u64,
	packed: u64,
	small:  bool,
}

#assert(size_of(Group) == GROUP_SLOTS)
#assert(size_of(type_of(CTRL_EMPTY)) == 1 && size_of(Slot) <= 24)
#assert(size_of(#soa[]Slot) == 32)
#assert(size_of(Table) == 96)
#assert(size_of(Lookup) == 40)

TABLE_SLOT_BYTES :: size_of(Slot) + 1

lookup_make :: #force_inline proc "contextless" (key: []u8) -> (l: Lookup) {
	l.key = key
	l.hash = hash_bytes(key)
	if len(key) <= INLINE_BYTES {
		l.small = true
		l.packed = pack_small(key) | (u64(len(key) + FORM_INLINE) << 56)
	}
	return
}

group_load :: #force_inline proc "contextless" (ctrl: [^]u8, g: u64) -> Group {
	return (^Group)(&ctrl[g << GROUP_SHIFT])^
}

group_match :: #force_inline proc "contextless" (grp: Group, b: u8) -> u32 {
	return u32(transmute(u16)simd.extract_msbs(simd.lanes_eq(grp, Group(b))))
}

group_empty :: #force_inline proc "contextless" (grp: Group) -> u32 {
	return group_match(grp, CTRL_EMPTY)
}

group_full :: #force_inline proc "contextless" (grp: Group) -> u32 {
	return u32(transmute(u16)simd.extract_msbs(grp))
}

group_free :: #force_inline proc "contextless" (grp: Group) -> u32 {
	return group_full(grp) ~ 0xFFFF
}

hash_h2 :: #force_inline proc "contextless" (h: u64) -> u8 {
	return u8(h) | 0x80
}

hash_home :: #force_inline proc "contextless" (h: u64, gmask: u64) -> u64 {
	return (h >> 7) & gmask
}

key_bytes :: #force_inline proc "contextless" (kp: ^Key_Handle, s: ^Slab) -> []u8 {
	form := kp.small.tag.key_form
	if form <= FORM_INLINE + INLINE_BYTES {
		return ([^]u8)(kp)[:form - FORM_INLINE]
	}
	if form == FORM_SLAB {
		return slab_ptr(s, kp.slab.offset)[:kp.slab.len]
	}
	hp := ([^]u8)(kp.heap.addr)
	return hp[8:][:(^int)(hp)^]
}

key_eq :: #force_inline proc "contextless" (a: [^]u8, b: [^]u8, n: int) -> bool #no_bounds_check {
	if n >= 8 && n <= 16 {
		a0 := intrinsics.unaligned_load((^u64)(a))
		b0 := intrinsics.unaligned_load((^u64)(b))
		a1 := intrinsics.unaligned_load((^u64)(&a[n - 8]))
		b1 := intrinsics.unaligned_load((^u64)(&b[n - 8]))
		return (a0 ~ b0) | (a1 ~ b1) == 0
	}
	return runtime.memory_equal(a, b, n)
}

@(private = "file")
key_matches :: #force_inline proc "contextless" (kh: Key_Handle, s: ^Slab, l: ^Lookup) -> bool #no_bounds_check {
	if l.small {
		return kh.bits & KEY_CMP_MASK == l.packed
	}
	form := kh.small.tag.key_form
	n := len(l.key)
	if form == FORM_SLAB {
		return int(kh.slab.len) == n && key_eq(slab_ptr(s, kh.slab.offset), raw_data(l.key), n)
	}
	if form == FORM_HEAP {
		hp := ([^]u8)(kh.heap.addr)
		return (^int)(hp)^ == n && runtime.memory_equal(&hp[8], raw_data(l.key), n)
	}
	return false
}

@(private = "file")
prefetch_group :: #force_inline proc "contextless" (t: ^Table, g: u64, want_meta: bool, write: bool) #no_bounds_check {
	i := int(g << GROUP_SHIFT)
	intrinsics.prefetch_read_data(&t.slots[i].key, 3)
	intrinsics.prefetch_read_data(&t.slots[i + GROUP_SLOTS / 2].key, 3)
	if write {
		intrinsics.prefetch_write_data(&t.slots[i].val, 3)
		intrinsics.prefetch_write_data(&t.slots[i + GROUP_SLOTS / 2].val, 3)
	} else {
		intrinsics.prefetch_read_data(&t.slots[i].val, 3)
		intrinsics.prefetch_read_data(&t.slots[i + GROUP_SLOTS / 2].val, 3)
	}
	if want_meta {
		intrinsics.prefetch_read_data(&t.slots[i].meta, 3)
		intrinsics.prefetch_read_data(&t.slots[i + GROUP_SLOTS / 2].meta, 3)
	}
}

@(private = "file")
prefetch_value :: #force_inline proc "contextless" (kh: Key_Handle, vh: Val_Handle, s: ^Slab, write: bool) {
	if kh.small.tag.val_form == FORM_SLAB {
		if write {
			intrinsics.prefetch_write_data(slab_ptr(s, vh.slab.offset), 3)
		} else {
			intrinsics.prefetch_read_data(slab_ptr(s, vh.slab.offset), 3)
		}
	}
}

table_alloc_size :: #force_inline proc "contextless" (cap: int) -> int {
	if cap < TABLE_MIN_CAP || cap & (cap - 1) != 0 || cap > (max(int) - TABLE_PAGE - 63) / TABLE_SLOT_BYTES {
		store_fatal("invalid key table capacity")
	}
	ctrl_bytes := (cap + 63) &~ 63
	return (ctrl_bytes + cap * size_of(Slot) + TABLE_PAGE - 1) &~ (TABLE_PAGE - 1)
}

table_alloc :: proc "contextless" (cap: int) -> (t: Table) {
	size := table_alloc_size(cap)
	ctrl_bytes := (cap + 63) &~ 63
	data, err := virtual.reserve_and_commit(uint(size))
	if err != nil {
		store_fatal("cannot allocate the key table")
	}
	base := raw_data(data)
	intrinsics.atomic_add_explicit(&storage_table_bytes, size, .Relaxed)
	intrinsics.atomic_add_explicit(&storage_table_mapped, size, .Relaxed)
	if size >= HUGE_PAGE {
		linux.madvise(base, uint(size), .HUGEPAGE)
	}
	t.region = base
	t.size = size
	t.ctrl = base
	metas := ([^]Slot_Meta)(&base[ctrl_bytes])[:cap]
	keys := ([^]Key_Handle)(&base[ctrl_bytes + cap * size_of(Slot_Meta)])[:cap]
	vals := ([^]Val_Handle)(&base[ctrl_bytes + cap * (size_of(Slot_Meta) + size_of(Key_Handle))])[:cap]
	t.slots = soa_zip(meta = metas, key = keys, val = vals)
	t.gmask = u64(cap / GROUP_SLOTS - 1)
	t.cap = cap
	t.growth = cap - cap / 8
	return
}

table_detach :: proc "contextless" (t: ^Table) {
	if t.region != nil {
		intrinsics.atomic_sub_explicit(&storage_table_bytes, t.size, .Relaxed)
		graveyard_push(t.region, t.size, .Table)
	}
	t^ = {}
}

table_find :: #force_inline proc "contextless" (t: ^Table, s: ^Slab, l: ^Lookup, want_meta: bool) -> int #no_bounds_check {
	gmask := t.gmask
	g := hash_home(l.hash, gmask)
	h2 := hash_h2(l.hash)
	prefetch_group(t, g, want_meta, false)
	step: u64 = 0
	for {
		grp := group_load(t.ctrl, g)
		m := group_match(grp, h2)
		for m != 0 {
			i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(m))
			kh := t.slots[i].key
			vh := t.slots[i].val
			if want_meta {
				intrinsics.prefetch_read_data(&t.slots[i].meta, 3)
			}
			prefetch_value(kh, vh, s, false)
			if key_matches(kh, s, l) {
				return i
			}
			m &= m - 1
		}
		if group_empty(grp) != 0 {
			return -1
		}
		step += 1
		g = (g + step) & gmask
	}
}

table_find_slow :: proc "contextless" (t: ^Table, s: ^Slab, l: ^Lookup, want_meta: bool) -> int {
	return table_find(t, s, l, want_meta)
}

table_find_slot :: #force_inline proc "contextless" (t: ^Table, s: ^Slab, l: ^Lookup, want_meta: bool) -> (slot: int, found: bool) #no_bounds_check {
	gmask := t.gmask
	g := hash_home(l.hash, gmask)
	h2 := hash_h2(l.hash)
	prefetch_group(t, g, want_meta, true)
	step: u64 = 0
	free := -1
	for {
		grp := group_load(t.ctrl, g)
		m := group_match(grp, h2)
		for m != 0 {
			i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(m))
			kh := t.slots[i].key
			vh := t.slots[i].val
			if want_meta {
				intrinsics.prefetch_write_data(&t.slots[i].meta, 3)
			}
			prefetch_value(kh, vh, s, true)
			if key_matches(kh, s, l) {
				return i, true
			}
			m &= m - 1
		}
		if free < 0 {
			f := group_free(grp)
			if f != 0 {
				free = int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(f))
			}
		}
		if group_empty(grp) != 0 {
			return free, false
		}
		step += 1
		g = (g + step) & gmask
	}
}

table_place :: #force_inline proc "contextless" (t: ^Table, i: int, h: u64) #no_bounds_check {
	if t.ctrl[i] == CTRL_DELETED {
		t.tombs -= 1
	} else {
		t.growth -= 1
	}
	t.ctrl[i] = hash_h2(h)
	t.live += 1
}

table_claim :: proc "contextless" (t: ^Table, h: u64) -> int #no_bounds_check {
	gmask := t.gmask
	g := hash_home(h, gmask)
	step: u64 = 0
	for {
		f := group_free(group_load(t.ctrl, g))
		if f != 0 {
			i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(f))
			table_place(t, i, h)
			return i
		}
		step += 1
		g = (g + step) & gmask
	}
}

table_erase :: proc "contextless" (t: ^Table, i: int, clear_meta: bool) #no_bounds_check {
	g := u64(i) >> GROUP_SHIFT
	if group_empty(group_load(t.ctrl, g)) != 0 {
		t.ctrl[i] = CTRL_EMPTY
		t.growth += 1
	} else {
		t.ctrl[i] = CTRL_DELETED
		t.tombs += 1
	}
	if clear_meta {
		t.slots[i].meta = {}
	}
	t.live -= 1
}

table_migrate_group :: proc "contextless" (src, dst: ^Table, s: ^Slab, g: u64, limit: int) -> (moved: int, done: bool) #no_bounds_check {
	full := group_full(group_load(src.ctrl, g))
	if full == 0 {
		return 0, true
	}
	base := int(g << GROUP_SHIFT)
	idx: [GROUP_SLOTS]int = ---
	hashes: [GROUP_SLOTS]u64 = ---
	n := 0
	m := full
	for m != 0 && n < limit {
		i := base + int(intrinsics.count_trailing_zeros(m))
		kp := &src.slots[i].key
		if kp.small.tag.key_form == FORM_SLAB {
			intrinsics.prefetch_read_data(slab_ptr(s, kp.slab.offset), 3)
		}
		idx[n] = i
		n += 1
		m &= m - 1
	}
	for k in 0 ..< n {
		h := hash_bytes(key_bytes(&src.slots[idx[k]].key, s))
		hashes[k] = h
		hg := hash_home(h, dst.gmask) << GROUP_SHIFT
		intrinsics.prefetch_write_data(&dst.ctrl[hg], 3)
		intrinsics.prefetch_write_data(&dst.slots[hg].meta, 3)
		intrinsics.prefetch_write_data(&dst.slots[hg].key, 3)
		intrinsics.prefetch_write_data(&dst.slots[hg].val, 3)
	}
	for k in 0 ..< n {
		i := idx[k]
		j := table_claim(dst, hashes[k])
		dst.slots[j] = src.slots[i]
		src.ctrl[i] = CTRL_DELETED
		src.slots[i].meta = {}
	}
	src.live -= n
	src.tombs += n
	return n, m == 0
}

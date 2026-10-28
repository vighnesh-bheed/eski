package main

import "base:intrinsics"
import "core:mem/virtual"
import "core:sys/linux"

SLAB_UNIT :: 8
SLAB_RESERVE :: 32 << 30
SLAB_COMMIT_STEP :: 4 << 20
SLAB_MAX :: 4096
SLAB_CLASSES :: 36

slab_cold_pages: bool

slab_class_size := [SLAB_CLASSES]u32 {
	8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128,
	160, 192, 224, 256, 320, 384, 448, 512, 640, 768, 896, 1024,
	1280, 1536, 1792, 2048, 2560, 3072, 3584, 4096,
}

Slab :: struct {
	base:             [^]u8,
	committed:        int,
	top:              int,
	live:             int,
	free:             [SLAB_CLASSES]u32,
	run_pos:          [SLAB_CLASSES]u32,
	run_last:         [SLAB_CLASSES]u32,
	warm:             int,
	payload_capacity: int,
	runs:             [^]Slab_Record,
}

SLAB_RUN :: 64 << 10
SLAB_WARM_AHEAD :: 8 << 20
SLAB_WARM_MIN :: 2 << 20
SLAB_PAGE :: 4096
SLAB_LINE :: 64

#assert(size_of(Slab) == 56 + SLAB_CLASSES * 4 * 3)
#assert(offset_of(Slab, runs) == 480)
#assert(offset_of(Slab, warm) == 32 + SLAB_CLASSES * size_of(u32) * 3)
#assert(offset_of(Slab, payload_capacity) == 40 + SLAB_CLASSES * size_of(u32) * 3)
#assert(offset_of(Slab, run_pos) == 32 + SLAB_CLASSES * size_of(u32))
#assert(offset_of(Slab, run_last) == 32 + SLAB_CLASSES * size_of(u32) * 2)
#assert(SLAB_RUN % SLAB_LINE == 0 && SLAB_RUN >= SLAB_MAX * 16)
#assert(SLAB_RESERVE % SLAB_RUN == 0 && SLAB_RUN % SLAB_UNIT == 0)
#assert(SLAB_RESERVE / SLAB_UNIT <= 1 << 32)
#assert(SLAB_MAX <= max(u16))

slab_class :: #force_inline proc "contextless" (n: int) -> int {
	if n <= 128 {
		return ((max(n, 1) + 7) >> 3) - 1
	}
	m := u64(n - 1)
	b := 63 - intrinsics.count_leading_zeros(m)
	return 16 + int(b - 7) * 4 + int((m - (u64(1) << b)) >> (b - 2))
}

slab_size_of :: #force_inline proc "contextless" (n: int) -> int #no_bounds_check {
	return int(slab_class_size[slab_class(n)])
}

slab_ptr :: #force_inline proc "contextless" (s: ^Slab, off: u32) -> [^]u8 {
	return s.base[int(off) * SLAB_UNIT:]
}

slab_alloc :: proc "contextless" (s: ^Slab, n: int) -> u32 #no_bounds_check {
	c := slab_class(n)
	size := int(slab_class_size[c])
	if s.live == 0 && s.runs != nil {
		slab_zero_cancel(s)
	}
	s.live += size
	db_used_memory += size
	head := s.free[c]
	if head != 0 {
		r := &s.runs[head].node
		off := (head << SLAB_RUN_SHIFT) + (u32(r.free_head) - 1)
		r.free_head = (^u16)(slab_ptr(s, off))^
		r.free_count -= 1
		r.live += 1
		if r.free_head == 0 {
			s.free[c] = slab_run_unlink(s, head, head)
		}
		return off
	}
	units := u32(size / SLAB_UNIT)
	pos := s.run_pos[c]
	if pos == 0 {
		pos = slab_new_run(s, c, size)
	}
	s.run_pos[c] = 0 if pos == s.run_last[c] else pos + units
	s.runs[pos >> SLAB_RUN_SHIFT].node.live += 1
	return pos
}

@(private = "file")
slab_new_run :: #force_no_inline proc "contextless" (s: ^Slab, c: int, size: int) -> u32 {
	id := slab_field(s, 0, SLAB_DIRTY_HEAD) if s.runs != nil else 0
	if id == 0 && s.runs != nil {
		id = slab_field(s, 0, SLAB_CLEAN_HEAD)
	}
	start: int
	if id != 0 {
		slab_empty_remove(s, id)
		start = int(id) * SLAB_RUN
	} else {
		if s.base == nil || s.top + SLAB_RUN > s.committed {
			slab_grow(s, SLAB_RUN)
		}
		start = s.top
		s.top = start + SLAB_RUN
		id = u32(start / SLAB_RUN)
		slab_metadata_commit(s, id)
	}
	s.runs[id].node = Slab_Run{class = u8(c), state = .Assigned}
	s.payload_capacity += SLAB_RUN / size * size
	if s.warm < s.top + slab_warm_ahead(s) / 2 {
		slab_cold_pages = true
	}
	s.run_last[c] = u32((start + (SLAB_RUN / size - 1) * size) / SLAB_UNIT)
	return u32(start / SLAB_UNIT)
}

slab_free :: proc "contextless" (s: ^Slab, off: u32, n: int) #no_bounds_check {
	c := slab_class(n)
	size := int(slab_class_size[c])
	id := off >> SLAB_RUN_SHIFT
	r := &s.runs[id].node
	when ODIN_DEBUG {
		if r.state != .Assigned || r.class != u8(c) || r.live == 0 {
			store_fatal("invalid slab allocation")
		}
	}
	r.live -= 1
	s.live -= size
	db_used_memory -= size
	if r.live > 0 {
		if r.free_head == 0 {
			r.next = s.free[c]
			if r.next != 0 {
				s.runs[r.next].node.prev = id
			}
			s.free[c] = id
		}
		(^u16)(slab_ptr(s, off))^ = r.free_head
		r.free_head = u16(off & (SLAB_RUN_UNITS - 1)) + 1
		r.free_count += 1
		return
	}
	if r.free_head != 0 {
		s.free[c] = slab_run_unlink(s, id, s.free[c])
	}
	if s.run_pos[c] >> SLAB_RUN_SHIFT == id {
		s.run_pos[c] = 0
		s.run_last[c] = 0
	}
	s.payload_capacity -= SLAB_RUN / size * size
	slab_empty_dirty(s, id)
	if s.live == 0 {
		s.runs[0].control[0] |= SLAB_ZERO_PENDING
		slab_zero_slabs += 1
	}
}

slab_warm_ahead :: #force_inline proc "contextless" (s: ^Slab) -> int {
	return clamp(s.top / 8, min(s.top, SLAB_WARM_MIN), SLAB_WARM_AHEAD)
}

slab_warm :: proc "contextless" (s: ^Slab, deadline: i64) -> bool {
	if s.base == nil || s.live == 0 {
		return false
	}
	target := min(s.top + slab_warm_ahead(s), SLAB_RESERVE)
	if s.warm >= target {
		return false
	}
	if target > s.committed {
		slab_grow(s, target - s.top)
	}
	p := max(s.warm, (s.top + SLAB_PAGE - 1) &~ (SLAB_PAGE - 1))
	for p < target {
		intrinsics.volatile_store(&s.base[p], 0)
		p += SLAB_PAGE
		if now_ns() >= deadline {
			break
		}
	}
	s.warm = p
	return true
}

@(cold)
slab_grow :: #force_no_inline proc "contextless" (s: ^Slab, size: int) {
	if s.base == nil {
		data, err := virtual.reserve(SLAB_RESERVE)
		if err != nil {
			store_fatal("cannot reserve address space for the value slab")
		}
		s.base = raw_data(data)
		if linux.madvise(s.base, SLAB_RESERVE, .NOHUGEPAGE) != .NONE {
			store_fatal("cannot disable huge pages for the value slab")
		}
		intrinsics.atomic_add_explicit(&storage_slab_virtual, SLAB_RESERVE, .Relaxed)
		s.top = SLAB_RUN
		s.committed = 0
	}
	need := s.top + size
	if need > SLAB_RESERVE {
		store_fatal("value slab exhausted")
	}
	target := min((need + SLAB_COMMIT_STEP - 1) / SLAB_COMMIT_STEP * SLAB_COMMIT_STEP, SLAB_RESERVE)
	if virtual.commit(&s.base[s.committed], uint(target - s.committed)) != nil {
		store_fatal("cannot commit memory for the value slab")
	}
	intrinsics.atomic_add_explicit(&storage_slab_writable, target - s.committed, .Relaxed)
	s.committed = target
}

slab_take :: proc "contextless" (s: ^Slab) -> (base: [^]u8, size: int) {
	slab_metadata_detach(s)
	if s.base != nil {
		storage_unmap(&s.base[s.committed], SLAB_RESERVE - s.committed, .Slab, false)
		base, size = s.base, s.committed
	}
	db_used_memory -= s.live
	s^ = {}
	return
}

slab_detach :: proc "contextless" (s: ^Slab) {
	base, size := slab_take(s)
	graveyard_push(base, size, .Slab)
}

package main

import "base:intrinsics"
import "core:mem/virtual"
import "core:sys/linux"

SLAB_RUN_SHIFT :: 13
SLAB_RUN_UNITS :: SLAB_RUN / SLAB_UNIT
SLAB_RUN_COUNT :: SLAB_RESERVE / SLAB_RUN
SLAB_METADATA_RESERVE :: SLAB_RUN_COUNT * size_of(Slab_Record)
SLAB_ID_MASK :: (1 << 19) - 1
SLAB_DIRTY_HEAD :: 0
SLAB_DIRTY_TAIL :: 19
SLAB_CLEAN_HEAD :: 38
SLAB_EMPTY_COUNT :: 0
SLAB_DIRTY_COUNT :: 19
SLAB_META_PAGES :: 38
SLAB_ZERO_PENDING :: u64(1) << 57
SLAB_RECLAIM_CALLS :: 4
SLAB_RECLAIM_DBS :: 16

Slab_Run_State :: enum u8 {
	Unused,
	Assigned,
	Dirty,
	Clean,
}

Slab_Run :: struct {
	next:       u32,
	prev:       u32,
	free_head:  u16,
	live:       u16,
	free_count: u16,
	class:      u8,
	state:      Slab_Run_State,
}

Slab_Record :: struct #raw_union {
	node:    Slab_Run,
	control: [2]u64,
}

Slab_Reclaim_Work :: struct {
	visited: int,
	advised: int,
	failed:  int,
	retired: int,
}

slab_dirty_runs: int
slab_zero_slabs: int
slab_reclaim_next: int
slab_reclaim_errors: i64

#assert(size_of(Slab_Run) == 16 && align_of(Slab_Run) == 4)
#assert(size_of(Slab_Record) == 16 && align_of(Slab_Record) == 8)
#assert(offset_of(Slab_Run, next) == 0 && offset_of(Slab_Run, prev) == 4)
#assert(offset_of(Slab_Run, free_head) == 8 && offset_of(Slab_Run, live) == 10)
#assert(offset_of(Slab_Run, free_count) == 12 && offset_of(Slab_Run, class) == 14 && offset_of(Slab_Run, state) == 15)
#assert(SLAB_RUN_COUNT == 1 << 19 && SLAB_RUN_UNITS == 1 << SLAB_RUN_SHIFT)
#assert(SLAB_METADATA_RESERVE == 8 << 20 && SLAB_METADATA_RESERVE / SLAB_PAGE < 1 << 12)
#assert(SLAB_RUN_UNITS <= max(u16))

slab_field :: #force_inline proc "contextless" (s: ^Slab, word, shift: int) -> u32 {
	return u32(s.runs[0].control[word] >> uint(shift) & SLAB_ID_MASK)
}

slab_field_set :: #force_inline proc "contextless" (s: ^Slab, word, shift: int, value: u32) {
	s.runs[0].control[word] = s.runs[0].control[word] &~ (u64(SLAB_ID_MASK) << uint(shift)) | u64(value) << uint(shift)
}

slab_metadata_bytes :: #force_inline proc "contextless" (s: ^Slab) -> int {
	return int(s.runs[0].control[1] >> SLAB_META_PAGES & 0xFFF) * SLAB_PAGE if s.runs != nil else 0
}

slab_metadata_commit :: proc "contextless" (s: ^Slab, id: u32) {
	if s.runs == nil {
		data, err := virtual.reserve(SLAB_METADATA_RESERVE)
		if err != nil {
			store_fatal("cannot reserve slab metadata")
		}
		s.runs = ([^]Slab_Record)(raw_data(data))
		if linux.madvise(s.runs, SLAB_METADATA_RESERVE, .NOHUGEPAGE) != .NONE || virtual.commit(s.runs, SLAB_PAGE) != nil {
			store_fatal("cannot commit slab metadata")
		}
		s.runs[0].control[1] = u64(1) << SLAB_META_PAGES
		intrinsics.atomic_add_explicit(&storage_metadata_virtual, SLAB_METADATA_RESERVE, .Relaxed)
		intrinsics.atomic_add_explicit(&storage_metadata_writable, SLAB_PAGE, .Relaxed)
		intrinsics.atomic_add_explicit(&storage_metadata_owned, SLAB_PAGE, .Relaxed)
	}
	current := slab_metadata_bytes(s)
	want := ((int(id) + 1) * size_of(Slab_Record) + SLAB_PAGE - 1) &~ (SLAB_PAGE - 1)
	if want > current {
		p := rawptr(uintptr(s.runs) + uintptr(current))
		if virtual.commit(p, uint(want - current)) != nil {
			store_fatal("cannot grow slab metadata")
		}
		s.runs[0].control[1] = s.runs[0].control[1] &~ (u64(0xFFF) << SLAB_META_PAGES) | u64(want / SLAB_PAGE) << SLAB_META_PAGES
		intrinsics.atomic_add_explicit(&storage_metadata_writable, want - current, .Relaxed)
		intrinsics.atomic_add_explicit(&storage_metadata_owned, want - current, .Relaxed)
	}
}

slab_run_unlink :: #force_inline proc "contextless" (s: ^Slab, id, head: u32) -> u32 {
	r := &s.runs[id].node
	next_head := head
	if r.prev != 0 {
		s.runs[r.prev].node.next = r.next
	} else {
		next_head = r.next
	}
	if r.next != 0 {
		s.runs[r.next].node.prev = r.prev
	}
	r.next = 0
	r.prev = 0
	return next_head
}

slab_zero_cancel :: #force_inline proc "contextless" (s: ^Slab) {
	if s.runs[0].control[0] & SLAB_ZERO_PENDING != 0 {
		s.runs[0].control[0] &~= SLAB_ZERO_PENDING
		slab_zero_slabs -= 1
	}
}

slab_empty_remove :: proc "contextless" (s: ^Slab, id: u32) {
	r := &s.runs[id].node
	shift := SLAB_CLEAN_HEAD
	if r.state == .Dirty {
		shift = SLAB_DIRTY_HEAD
		if slab_field(s, 0, SLAB_DIRTY_TAIL) == id {
			slab_field_set(s, 0, SLAB_DIRTY_TAIL, r.prev)
		}
		slab_field_set(s, 1, SLAB_DIRTY_COUNT, slab_field(s, 1, SLAB_DIRTY_COUNT) - 1)
		slab_dirty_runs -= 1
	}
	head := slab_run_unlink(s, id, slab_field(s, 0, shift))
	slab_field_set(s, 0, shift, head)
	slab_field_set(s, 1, SLAB_EMPTY_COUNT, slab_field(s, 1, SLAB_EMPTY_COUNT) - 1)
}

slab_empty_dirty :: proc "contextless" (s: ^Slab, id: u32) {
	tail := slab_field(s, 0, SLAB_DIRTY_TAIL)
	s.runs[id].node = Slab_Run{prev = tail, class = 255, state = .Dirty}
	if tail != 0 {
		s.runs[tail].node.next = id
	} else {
		slab_field_set(s, 0, SLAB_DIRTY_HEAD, id)
	}
	slab_field_set(s, 0, SLAB_DIRTY_TAIL, id)
	slab_field_set(s, 1, SLAB_EMPTY_COUNT, slab_field(s, 1, SLAB_EMPTY_COUNT) + 1)
	slab_field_set(s, 1, SLAB_DIRTY_COUNT, slab_field(s, 1, SLAB_DIRTY_COUNT) + 1)
	slab_dirty_runs += 1
}

slab_advise_one :: proc "contextless" (s: ^Slab) -> bool {
	id := slab_field(s, 0, SLAB_DIRTY_HEAD)
	ok := linux.madvise(&s.base[int(id) * SLAB_RUN], SLAB_RUN, .DONTNEED) == .NONE
	slab_empty_remove(s, id)
	if !ok {
		slab_reclaim_errors += 1
		slab_empty_dirty(s, id)
		return false
	}
	head := slab_field(s, 0, SLAB_CLEAN_HEAD)
	s.runs[id].node = Slab_Run{next = head, class = 255, state = .Clean}
	if head != 0 {
		s.runs[head].node.prev = id
	}
	slab_field_set(s, 0, SLAB_CLEAN_HEAD, id)
	slab_field_set(s, 1, SLAB_EMPTY_COUNT, slab_field(s, 1, SLAB_EMPTY_COUNT) + 1)
	return true
}

slab_metadata_detach :: proc "contextless" (s: ^Slab) {
	if s.runs == nil {
		return
	}
	slab_dirty_runs -= int(slab_field(s, 1, SLAB_DIRTY_COUNT))
	slab_zero_cancel(s)
	size := slab_metadata_bytes(s)
	base := ([^]u8)(s.runs)
	intrinsics.atomic_sub_explicit(&storage_metadata_owned, size, .Relaxed)
	storage_unmap(&base[size], SLAB_METADATA_RESERVE - size, .Slab_Metadata, false)
	graveyard_push(base, size, .Slab_Metadata)
	s.runs = nil
}

slab_reclaim_pending :: #force_inline proc "contextless" () -> bool {
	return slab_dirty_runs > 0 || slab_zero_slabs > 0
}

slab_retire_zero :: proc "contextless" (s: ^Slab) -> bool {
	if s.base == nil || s.live != 0 {
		return false
	}
	needed := int(s.committed > RELEASE_NOW_BYTES) + int(slab_metadata_bytes(s) > RELEASE_NOW_BYTES)
	if graveyard_len + needed > GRAVEYARD_MAX {
		return false
	}
	slab_detach(s)
	return true
}

slab_reclaim :: proc "contextless" (deadline: i64, zero_only: bool = false) -> (work: Slab_Reclaim_Work) {
	if !slab_reclaim_pending() || zero_only && slab_zero_slabs == 0 || len(db_parts) == 0 {
		return
	}
	if slab_reclaim_next >= len(db_parts) {
		slab_reclaim_next = 0
	}
	for work.visited < min(len(db_parts), SLAB_RECLAIM_DBS) {
		if now_ns() >= deadline {
			break
		}
		s := &db_parts[slab_reclaim_next].slab
		slab_reclaim_next = (slab_reclaim_next + 1) % len(db_parts)
		work.visited += 1
		if work.retired == 0 && s.base != nil && s.live == 0 && now_ns() < deadline && slab_retire_zero(s) {
			work.retired += 1
		}
		if !zero_only && s.runs != nil {
			for work.advised + work.failed < SLAB_RECLAIM_CALLS && slab_field(s, 0, SLAB_DIRTY_HEAD) != 0 {
				if now_ns() >= deadline {
					break
				}
				if slab_advise_one(s) {
					work.advised += 1
				} else {
					work.failed += 1
				}
			}
		}
		if work.retired == 1 || work.advised + work.failed == SLAB_RECLAIM_CALLS {
			break
		}
	}
	return
}

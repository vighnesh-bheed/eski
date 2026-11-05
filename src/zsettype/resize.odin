package zsettype

import "base:intrinsics"
import "base:runtime"
import "core:mem/virtual"
import "core:sys/linux"
import "core:sync"
import "../sysclock"

RESIZE_WRITE_SCANS :: 64
RESIZE_WRITE_MOVES :: 4
SLOTS_HEAP_LIMIT :: 4096
RESIZE_RELEASE_BYTES :: 2 << 20
RESIZE_RELEASE_CALLS :: 16
TOMBSTONE :: (^Node)(uintptr(1))

Context :: struct {
	resize_head:  ^Resize_State,
	resize_tail:  ^Resize_State,
	resize_count: int,
	owner:        rawptr,
	resize_epoch: u64,
}

Resize_State :: struct {
	target:            ^Skiplist,
	old_slots:         [^]^Node,
	old_cap:           int,
	old_count:         int,
	cursor:            int,
	prev:              ^Resize_State,
	next:              ^Resize_State,
	owner:             Zset,
	reg:               ^Context,
	epoch:             u64,
	release_remaining: int,
}

Resize_Work :: struct {
	scanned: int,
	moved:   int,
	probes:  int,
}

resize_jobs: int
resize_retired_head: ^Resize_State
resize_retired_tail: ^Resize_State
resize_retired_heap: int
resize_retired_count: int
resize_retired_mutex: sync.Mutex
resize_mapped: int
resize_retired_mapped: int

#assert(size_of(Node) == 32 && size_of(Level) == 16)
#assert(size_of(Zset_Object) == 32)
#assert(offset_of(Node, score) == 0 && offset_of(Node, backward) == 8 && offset_of(Node, hash) == 16)
#assert(offset_of(Node, mlen) == 24 && offset_of(Node, nlevel) == 28)
#assert(size_of(Skiplist) == 72 && align_of(Skiplist) == 8)
#assert(offset_of(Skiplist, header) == 0 && offset_of(Skiplist, tail) == 8)
#assert(offset_of(Skiplist, length) == 16 && offset_of(Skiplist, level) == 24)
#assert(offset_of(Skiplist, slots) == 32 && offset_of(Skiplist, cap) == 40)
#assert(offset_of(Skiplist, count) == 48 && offset_of(Skiplist, bytes) == 56 && offset_of(Skiplist, resize) == 64)
#assert(size_of(Context) == 40 && offset_of(Context, resize_epoch) == 32)
#assert(size_of(Resize_State) == 88)

node_live :: #force_inline proc "contextless" (b: ^Node) -> bool {
	return uintptr(b) > 1
}

dict_bank :: #force_inline proc "contextless" (t: ^Skiplist, bank: int) -> ([^]^Node, int) {
	if bank == 0 {
		return t.slots, t.cap
	}
	if t.resize != nil {
		return t.resize.old_slots, t.resize.old_cap
	}
	return nil, 0
}

slots_alloc :: proc "contextless" (cap: int) -> [^]^Node {
	resize_require(cap >= DICT_MIN_CAP && cap <= max(int) / size_of(^Node) && cap & (cap - 1) == 0)
	n := cap * size_of(^Node)
	if n <= SLOTS_HEAP_LIMIT {
		p := runtime.heap_alloc(n, true)
		resize_require(p != nil)
		return ([^]^Node)(p)
	}
	data, err := virtual.reserve_and_commit(uint(n))
	resize_require(err == nil && len(data) == n)
	intrinsics.atomic_add_explicit(&resize_mapped, n, .Relaxed)
	return ([^]^Node)(raw_data(data))
}

slots_memory :: #force_inline proc "contextless" (slots: [^]^Node, cap: int) -> int {
	if cap * size_of(^Node) > SLOTS_HEAP_LIMIT {
		return cap * size_of(^Node)
	}
	return mem_usable_size(slots)
}

slots_free :: proc "contextless" (slots: [^]^Node, cap: int) {
	if cap * size_of(^Node) <= SLOTS_HEAP_LIMIT {
		mem_free(slots)
		return
	}
	n := cap * size_of(^Node)
	resize_require(linux.munmap(slots, uint(n)) == .NONE)
	intrinsics.atomic_sub_explicit(&resize_mapped, n, .Relaxed)
}

resize_unlink :: proc "contextless" (r: ^Resize_State) {
	reg := r.reg
	if reg != nil && r.epoch == intrinsics.atomic_load_explicit(&reg.resize_epoch, .Acquire) {
		if r.prev != nil {
			r.prev.next = r.next
		} else {
			reg.resize_head = r.next
		}
		if r.next != nil {
			r.next.prev = r.prev
		} else {
			reg.resize_tail = r.prev
		}
		reg.resize_count -= 1
		intrinsics.atomic_sub_explicit(&resize_jobs, 1, .Relaxed)
	}
	r.reg = nil
	r.owner = nil
	r.prev = nil
	r.next = nil
}

maintenance_bind :: proc "contextless" (h: Zset, reg: ^Context) {
	if h.encoding != .Skiplist || h.sl.resize == nil {
		return
	}
	r := h.sl.resize
	epoch := intrinsics.atomic_load_explicit(&reg.resize_epoch, .Acquire)
	if r.reg == reg && r.epoch == epoch {
		return
	}
	resize_unlink(r)
	r.reg = reg
	r.epoch = epoch
	r.owner = h
	r.prev = reg.resize_tail
	if r.prev != nil {
		r.prev.next = r
	} else {
		reg.resize_head = r
	}
	reg.resize_tail = r
	reg.resize_count += 1
	intrinsics.atomic_add_explicit(&resize_jobs, 1, .Relaxed)
}

maintenance_cancel :: proc "contextless" (h: Zset) {
	if h.encoding == .Skiplist && h.sl.resize != nil {
		resize_unlink(h.sl.resize)
	}
}

maintenance_clear :: proc "contextless" (reg: ^Context) {
	epoch := intrinsics.atomic_load_explicit(&reg.resize_epoch, .Relaxed)
	resize_require(epoch != max(u64))
	intrinsics.atomic_store_explicit(&reg.resize_epoch, epoch + 1, .Release)
	intrinsics.atomic_sub_explicit(&resize_jobs, reg.resize_count, .Relaxed)
	reg.resize_head = nil
	reg.resize_tail = nil
	reg.resize_count = 0
}

@(private)
resize_retire :: proc "contextless" (r: ^Resize_State) {
	resize_unlink(r)
	if r.old_cap * size_of(^Node) <= SLOTS_HEAP_LIMIT {
		slots_free(r.old_slots, r.old_cap)
		mem_free(r)
		return
	}
	r.target = nil
	r.release_remaining = r.old_cap * size_of(^Node)
	intrinsics.atomic_add_explicit(&resize_retired_heap, mem_usable_size(r), .Relaxed)
	intrinsics.atomic_add_explicit(&resize_retired_mapped, r.release_remaining, .Relaxed)
	sync.mutex_lock(&resize_retired_mutex)
	if resize_retired_tail != nil {
		resize_retired_tail.next = r
	} else {
		resize_retired_head = r
	}
	resize_retired_tail = r
	intrinsics.atomic_add_explicit(&resize_retired_count, 1, .Release)
	sync.mutex_unlock(&resize_retired_mutex)
}

dict_empty :: proc "contextless" (t: ^Skiplist) {
	resize_require(t.count == 0)
	if r := t.resize; r != nil {
		t.resize = nil
		resize_retire(r)
	}
	if t.cap * size_of(^Node) > SLOTS_HEAP_LIMIT {
		r := (^Resize_State)(runtime.heap_alloc(size_of(Resize_State), true))
		r.old_slots = t.slots
		r.old_cap = t.cap
		resize_retire(r)
	} else {
		slots_free(t.slots, t.cap)
	}
	t.slots = nil
	t.cap = 0
}

dict_step :: proc "contextless" (t: ^Skiplist, scan_budget, move_budget: int) -> (work: Resize_Work) #no_bounds_check {
	r := t.resize
	if r == nil {
		return
	}
	for r.old_count > 0 && work.scanned < scan_budget && work.moved < move_budget {
		resize_require(r.cursor < r.old_cap)
		s := &r.old_slots[r.cursor]
		r.cursor += 1
		work.scanned += 1
		if !node_live(s^) {
			continue
		}
		work.probes += dict_place(t.slots, u64(t.cap - 1), s^)
		s^ = TOMBSTONE
		r.old_count -= 1
		work.moved += 1
	}
	if r.old_count == 0 {
		t.resize = nil
		resize_retire(r)
	}
	return
}

maintenance_pending :: #force_inline proc "contextless" () -> bool {
	return intrinsics.atomic_load_explicit(&resize_jobs, .Relaxed) > 0 || intrinsics.atomic_load_explicit(&resize_retired_count, .Acquire) > 0
}

maintenance_step :: proc "contextless" (reg: ^Context, scans, moves: int) -> (h: Zset, work: Resize_Work) {
	r := reg.resize_head
	if r == nil {
		return
	}
	h = r.owner
	work = dict_step(r.target, scans, moves)
	if h.sl.resize != nil {
		resize_unlink(r)
		maintenance_bind(h, reg)
	} else {
		dict_shrink_if_needed(h.sl)
		maintenance_bind(h, reg)
	}
	return
}

maintenance_release :: proc "contextless" (budget: int = RESIZE_RELEASE_BYTES, deadline_ns: i64 = 0, call_budget: int = RESIZE_RELEASE_CALLS) -> (released: int) {
	resize_require(budget >= 0 && budget <= RESIZE_RELEASE_BYTES && budget % 4096 == 0 && call_budget >= 0 && call_budget <= RESIZE_RELEASE_CALLS)
	calls := 0
	for released < budget && calls < call_budget {
		if calls > 0 && deadline_ns != 0 {
			ts, _ := sysclock.monotonic()
			if i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec) >= deadline_ns {
				break
			}
		}
		sync.mutex_lock(&resize_retired_mutex)
		r := resize_retired_head
		if r != nil {
			resize_retired_head = r.next
			if r.next == nil { resize_retired_tail = nil }
			r.next = nil
		}
		sync.mutex_unlock(&resize_retired_mutex)
		if r == nil { break }
		calls += 1
		n := min(r.release_remaining, budget - released)
		offset := r.old_cap * size_of(^Node) - r.release_remaining
		p := rawptr(uintptr(r.old_slots) + uintptr(offset))
		resize_require(linux.munmap(p, uint(n)) == .NONE)
		intrinsics.atomic_sub_explicit(&resize_retired_mapped, n, .Relaxed)
		intrinsics.atomic_sub_explicit(&resize_mapped, n, .Relaxed)
		r.release_remaining -= n
		released += n
		if r.release_remaining == 0 {
			intrinsics.atomic_sub_explicit(&resize_retired_heap, mem_usable_size(r), .Relaxed)
			mem_free(r)
			intrinsics.atomic_sub_explicit(&resize_retired_count, 1, .Release)
		} else {
			sync.mutex_lock(&resize_retired_mutex)
			r.next = resize_retired_head
			resize_retired_head = r
			if resize_retired_tail == nil { resize_retired_tail = r }
			sync.mutex_unlock(&resize_retired_mutex)
		}
	}
	return
}

maintenance_metadata :: #force_inline proc "contextless" () -> int {
	return intrinsics.atomic_load_explicit(&resize_retired_heap, .Relaxed)
}

maintenance_memory :: proc "contextless" () -> (mapped, retired, metadata: int) {
	return intrinsics.atomic_load_explicit(&resize_mapped, .Relaxed), intrinsics.atomic_load_explicit(&resize_retired_mapped, .Relaxed), intrinsics.atomic_load_explicit(&resize_retired_heap, .Relaxed)
}

maintenance_effort :: proc "contextless" (h: Zset) -> int {
	if h.encoding != .Skiplist {
		return 0
	}
	n := h.sl.cap + h.sl.length
	if h.sl.resize != nil {
		n += h.sl.resize.old_cap
	}
	return n
}

@(private)
resize_require :: #force_inline proc "contextless" (ok: bool) {
	if !ok {
		runtime.panic_contextless("invalid zset resize state or allocation failure")
	}
}

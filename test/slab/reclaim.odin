package main

import "core:sys/linux"
import "core:fmt"
import "core:encoding/json"

foreign import slab_libc "system:c"

@(default_calling_convention = "c")
foreign slab_libc {
	@(link_name = "fork")
	slab_test_fork :: proc() -> i32 ---
}

Resident_State :: struct {
	phase:          string,
	base:           u64,
	reserve:        int,
	top:            int,
	committed:      int,
	metadata:       u64,
	metadata_bytes: int,
	live:           int,
	empty:          int,
	owned:          int,
	payload_virtual: int,
	metadata_virtual: int,
}

resident_emit :: proc(phase: string, s: ^Slab) {
	empty := int(slab_field(s, 1, SLAB_EMPTY_COUNT)) if s.runs != nil else 0
	data, err := json.marshal(Resident_State{phase, u64(uintptr(s.base)), SLAB_RESERVE, s.top, s.committed, u64(uintptr(s.runs)), slab_metadata_bytes(s), s.live, empty, storage_metadata_owned, storage_slab_virtual, storage_metadata_virtual})
	check(err == nil, "resident state serializes as valid JSON")
	fmt.println(string(data))
	delete(data)
}

resident_token :: proc() {
	token: [1]u8
	n, err := linux.read(0, token[:])
	check(n == 1 && err == .NONE, "resident fixture receives bounded driver token")
}

resident_fixture :: proc() {
	owners := make([]Db, 1)
	dbs = owners
	defer delete(owners)
	s := &dbs[0].slab
	keeper := slab_alloc(s, 24)
	slab_ptr(s, keeper)[0] = 0xA7
	offsets := make([]u32, 16 * 1024)
	defer delete(offsets)
	for &off in offsets {
		off = slab_alloc(s, 64)
		p := slab_ptr(s, off)
		p[0], p[63] = 0x4D, 0x4D
	}
	top := s.top
	resident_emit("filled", s)
	resident_token()
	for off in offsets {
		slab_free(s, off, 64)
	}
	resident_emit("dirty", s)
	resident_token()
	for _ in 0 ..< 16 {
		slab_reclaim(now_ns() + 1_000_000_000)
		if slab_dirty_runs == 0 {
			break
		}
	}
	check(slab_dirty_runs == 0 && s.live == 24 && slab_ptr(s, keeper)[0] == 0xA7, "partial-slab advice preserves the keeper")
	resident_emit("reclaimed", s)
	resident_token()
	for &off in offsets[:2048] {
		off = slab_alloc(s, 512)
		p := slab_ptr(s, off)
		p[0], p[511] = 0x6E, 0x6E
	}
	check(s.top == top && slab_field(s, 1, SLAB_EMPTY_COUNT) == 0, "64-to-512 reuse consumes all clean runs without extending high water")
	resident_emit("reused", s)
	resident_token()
	for off in offsets[:2048] {
		slab_free(s, off, 512)
	}
	slab_free(s, keeper, 24)
	slab_reclaim(now_ns() + 1_000_000_000)
	check(s.base == nil && s.runs == nil && db_used_memory == 0 && !slab_reclaim_pending() && storage_slab_virtual == 0 && storage_metadata_virtual == 0, "resident fixture retires the whole zero owner through successful actual unmaps")
	resident_emit("retired", s)
	resident_token()
}

cow_fixture :: proc() {
	owners := make([]Db, 1)
	dbs = owners
	defer delete(owners)
	s := &dbs[0].slab
	keeper := slab_alloc(s, 24)
	offsets := make([]u32, 2048)
	defer delete(offsets)
	for &off in offsets {
		off = slab_alloc(s, 64)
		p := slab_ptr(s, off)
		p[0], p[63] = 0x4D, 0x4D
	}
	old_live := s.live
	old_meta := storage_metadata_owned
	pipes: [2]linux.Fd
	check(linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK}) == .NONE, "create bounded slab COW ordering pipe")
	pid := slab_test_fork()
	check(pid >= 0, "public-libc isolated allocator fork succeeds")
	if pid == 0 {
		linux.close(pipes[1])
		deadline := now_ns() + 5_000_000_000
		token: [1]u8
		got := false
		for now_ns() < deadline {
			n, err := linux.read(pipes[0], token[:])
			if n == 1 {
				got = true
				break
			}
			check(err == .EAGAIN || err == .EINTR, "child COW ordering pipe remains valid")
			ts := linux.Time_Spec{time_nsec = 100_000}
			linux.nanosleep(&ts, nil)
		}
		check(got && token[0] == 1, "child checks bytes after parent advice and reassignment")
		check(s.live == old_live && storage_metadata_owned == old_meta && slab_field(s, 1, SLAB_EMPTY_COUNT) == 0, "parent metadata transitions cannot change child ownership snapshot")
		for off in offsets {
			p := slab_ptr(s, off)
			check(p[0] == 0x4D && p[63] == 0x4D && s.runs[off >> SLAB_RUN_SHIFT].node.class == 7, "child keeps the live bytes and run class it had at fork")
		}
		slab_detach(s)
		linux.exit_group(0)
	}
	linux.close(pipes[0])
	for off in offsets {
		slab_free(s, off, 64)
	}
	slab_reclaim(now_ns() + 1_000_000_000)
	for &off in offsets[:256] {
		off = slab_alloc(s, 512)
		p := slab_ptr(s, off)
		p[0], p[511] = 0x6E, 0x6E
	}
	token := [1]u8{1}
	n, err := linux.write(pipes[1], token[:])
	check(n == 1 && err == .NONE, "parent signals completed COW mutation")
	linux.close(pipes[1])
	deadline := now_ns() + 5_000_000_000
	status: u32
	done := false
	for now_ns() < deadline {
		got, werr := linux.wait4(linux.Pid(pid), &status, {.WNOHANG}, nil)
		check(werr == .NONE, "wait for allocator COW child")
		if got == linux.Pid(pid) {
			done = true
			break
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(done && status == 0, "isolated allocator child preserved COW state")
	check(s.live == 24 + 256 * 512 && storage_metadata_owned == old_meta, "child cleanup cannot decrement parent ownership")
	for off in offsets[:256] {
		p := slab_ptr(s, off)
		check(p[0] == 0x6E && p[511] == 0x6E, "parent reused bytes remain intact after child release")
	}
	slab_free(s, keeper, 24)
	slab_detach(s)
	fmt.printfln("PASS slab COW checks=%d metadata_bytes=%d", checks, old_meta)
}

final_metadata :: proc(s: ^Slab, c: int, empty: bool) {
	check(slab_metadata_bytes(s) == SLAB_METADATA_RESERVE && storage_metadata_owned == SLAB_METADATA_RESERVE && storage_metadata_writable == SLAB_METADATA_RESERVE && storage_metadata_virtual == SLAB_METADATA_RESERVE, "synthetic final fixture owns the real complete metadata prefix")
	prior_unused := true
	for id in 1 ..< SLAB_RUN_COUNT - 1 {
		r := s.runs[id].node
		prior_unused = prior_unused && r.state == .Unused && r.live == 0 && r.free_head == 0 && r.free_count == 0 && r.next == 0 && r.prev == 0
	}
	check(prior_unused, "synthetic historical payload prefix has only Unused descriptors")
	id := u32(SLAB_RUN_COUNT - 1)
	r := s.runs[id].node
	if empty {
		check(r.state == .Dirty && r.live == 0 && r.class == 255 && r.free_head == 0 && r.free_count == 0, "only real final run becomes a cleanly detached empty descriptor")
		check(slab_field(s, 0, SLAB_DIRTY_HEAD) == id && slab_field(s, 0, SLAB_DIRTY_TAIL) == id && slab_field(s, 1, SLAB_EMPTY_COUNT) == 1 && slab_field(s, 1, SLAB_DIRTY_COUNT) == 1, "synthetic fixture publishes exactly its real final empty run")
		check(slab_zero_slabs == 1 && s.runs[0].control[0] & SLAB_ZERO_PENDING != 0, "highest-offset full-free queues zero ownership once")
	} else {
		check(r.state == .Assigned && int(r.class) == c && int(r.live) == SLAB_RUN / int(slab_class_size[c]), "only real final descriptor owns its complete live class")
		check(slab_field(s, 1, SLAB_EMPTY_COUNT) == 0 && slab_field(s, 1, SLAB_DIRTY_COUNT) == 0 && slab_field(s, 0, SLAB_CLEAN_HEAD) == 0 && slab_field(s, 0, SLAB_DIRTY_HEAD) == 0, "final allocation/reuse has no phantom pool owners")
		check(slab_zero_slabs == 0 && s.runs[0].control[0] & SLAB_ZERO_PENDING == 0, "highest-offset reuse cancels pending zero ownership")
	}
}

recount :: proc(s: ^Slab) {
	count := s.top / SLAB_RUN
	seen := make([]bool, count)
	defer delete(seen)
	for head, c in s.free {
		prev: u32
		for id := head; id != 0; id = s.runs[id].node.next {
			check(int(id) < count && !seen[id], "class run list has unique bounded ownership")
			seen[id] = true
			r := &s.runs[id].node
			check(r.prev == prev && r.state == .Assigned && int(r.class) == c && r.free_head != 0, "class list state and reciprocal links")
			prev = id
		}
	}
	empty, dirty := 0, 0
	for state in ([2]Slab_Run_State{.Dirty, .Clean}) {
		shift := SLAB_DIRTY_HEAD if state == .Dirty else SLAB_CLEAN_HEAD
		prev: u32
		for id := slab_field(s, 0, shift); id != 0; id = s.runs[id].node.next {
			check(int(id) < count && !seen[id], "empty run pools are bounded and disjoint")
			seen[id] = true
			r := &s.runs[id].node
			check(r.state == state && r.prev == prev && r.live == 0 && r.class == 255 && r.free_head == 0 && r.free_count == 0, "empty run descriptor has no old cell links or class")
			empty += 1
			dirty += int(state == .Dirty)
			prev = id
		}
		if state == .Dirty {
			check(prev == slab_field(s, 0, SLAB_DIRTY_TAIL), "dirty FIFO tail matches traversal")
		}
	}
	live, capacity, tails, bump, cells := 0, 0, 0, 0, 0
	for id in 1 ..< count {
		r := &s.runs[id].node
		if r.state != .Assigned {
			check(seen[id], "every nonassigned issued run belongs to one empty pool")
			continue
		}
		check(r.class < SLAB_CLASSES && r.live > 0, "assigned run has a valid class and live cells")
		size := int(slab_class_size[r.class])
		n := SLAB_RUN / size
		capacity += n * size
		tails += SLAB_RUN % size
		live += int(r.live) * size
		check(seen[id] == (r.free_head != 0), "class membership equals presence of freed cells")
		freed := 0
		for rel := r.free_head; rel != 0; {
			check(rel <= SLAB_RUN_UNITS && freed < n, "relative cell chain terminates within one run")
			at := (int(rel) - 1) * SLAB_UNIT
			check(at % size == 0 && at + size <= SLAB_RUN, "relative free cell has correct class alignment")
			rel = (^u16)(&s.base[id * SLAB_RUN + at])^
			freed += 1
		}
		check(freed == int(r.free_count), "actual freed chain equals its independent descriptor count")
		cells += freed * size
		left := 0
		pos := s.run_pos[r.class]
		if pos != 0 && int(pos >> SLAB_RUN_SHIFT) == id {
			last := id * SLAB_RUN + (n - 1) * size
			check(int(s.run_last[r.class]) * SLAB_UNIT == last && int(pos) * SLAB_UNIT <= last, "inclusive bump cursor has exact last valid start")
			left = last - int(pos) * SLAB_UNIT + size
		}
		bump += left
		check(n * size == int(r.live) * size + freed * size + left, "per-run live/free/bump conservation")
	}
	check(live == s.live && capacity == s.payload_capacity, "independent descriptors match live and class capacity")
	check(capacity == live + cells + bump, "allocator payload conservation")
	check(s.top == SLAB_RUN + capacity + tails + empty * SLAB_RUN, "assigned tails and empty pools partition issued bytes")
	check(empty == int(slab_field(s, 1, SLAB_EMPTY_COUNT)) && dirty == int(slab_field(s, 1, SLAB_DIRTY_COUNT)), "packed pool counts equal actual linked runs")
	check(slab_metadata_bytes(s) >= (count * size_of(Slab_Record) + SLAB_PAGE - 1) &~ (SLAB_PAGE - 1), "metadata prefix covers every issued descriptor")
}

pool_reclaim :: proc() {
	owners := make([]Db, 1)
	dbs = owners
	defer delete(owners)
	s := &dbs[0].slab
	keeper := slab_alloc(s, 24)
	for i in 0 ..< 24 {
		slab_ptr(s, keeper)[i] = 0xA7
	}
	offsets: [48]u32
	for &off in offsets {
		off = slab_alloc(s, 4096)
		slab_ptr(s, off)[0] = 0x5A
		slab_ptr(s, off)[4095] = 0x5A
	}
	for run in 0 ..< 3 {
		slab_free(s, offsets[run * 16], 4096)
	}
	recount(s)
	for i in 17 ..< 32 {
		slab_free(s, offsets[i], 4096)
	}
	recount(s)
	check(slab_field(s, 1, SLAB_EMPTY_COUNT) == 1, "emptying the middle free-run list node unlinks it in constant work")
	for i in 1 ..< 16 {
		slab_free(s, offsets[i], 4096)
	}
	for i in 33 ..< 48 {
		slab_free(s, offsets[i], 4096)
	}
	recount(s)
	top := s.top
	first_dirty := slab_field(s, 0, SLAB_DIRTY_HEAD)
	off := slab_alloc(s, 512)
	check(off >> SLAB_RUN_SHIFT == first_dirty && s.top == top, "cross-class reuse prefers the dirty FIFO before extending")
	check(slab_field(s, 1, SLAB_EMPTY_COUNT) == 2 && slab_dirty_runs == 2, "reuse cancels exactly one dirty work item")
	slab_free(s, off, 512)
	work := slab_reclaim(1)
	check(work.visited == 0 && work.advised == 0 && work.failed == 0 && work.retired == 0, "expired deadline starts no reclaim work")
	id := slab_field(s, 0, SLAB_DIRTY_HEAD)
	p := s.base[int(id) * SLAB_RUN:]
	check(p[SLAB_RUN - 1] == 0x5A, "advice fixture retains recognizable data beyond free-chain links")
	check(linux.mlock(p, SLAB_RUN) == .NONE, "bounded real locked-page advice failure fixture")
	before_errors := slab_reclaim_errors
	work = slab_reclaim(now_ns() + 1_000_000_000)
	check(work.advised + work.failed == 4 && work.failed > 0 && work.retired == 0, "actual syscall failure rotates fairly within the four-call cap")
	check(s.runs[id].node.state == .Dirty && slab_reclaim_errors == before_errors + i64(work.failed), "failed advice retains dirty ownership and records each failure")
	check(linux.munlock(p, SLAB_RUN) == .NONE, "unlock failure fixture")
	work = slab_reclaim(now_ns() + 1_000_000_000)
	check(work.advised == 1 && work.failed == 0 && slab_dirty_runs == 0, "retry makes finite dirty FIFO progress")
	recount(s)
	for i in 0 ..< 24 {
		check(slab_ptr(s, keeper)[i] == 0xA7, "adjacent live bytes survive run advice")
	}
	check(p[0] == 0 && p[SLAB_RUN - 1] == 0, "successful DONTNEED yields zero-filled private pages")
	clean := slab_alloc(s, 1792)
	check(s.top == top && s.runs[clean >> SLAB_RUN_SHIFT].node.class == 30, "clean run reassigns to a remainder class without growth")
	slab_free(s, clean, 1792)
	slab_free(s, keeper, 24)
	check(slab_zero_slabs == 1 && s.live == 0, "last live cell queues a single whole-owner retirement")
	recount(s)
	old_base := s.base
	newcell := slab_alloc(s, 40)
	check(slab_zero_slabs == 0 && s.base == old_base && s.top == top, "replacement cancels zero retirement and reuses dirty memory")
	slab_free(s, newcell, 40)
	work = slab_reclaim(now_ns() + 1_000_000_000)
	check(work.retired == 1 && s.base == nil && s.runs == nil, "whole-zero owner retirement clears payload and descriptors")
	check(!slab_reclaim_pending() && db_used_memory == 0 && storage_metadata_owned == 0 && storage_metadata_virtual == 0 && storage_slab_virtual == 0, "whole-zero release converges every owner and mapping counter")
	dbs = nil
}

metadata_growth :: proc() {
	s: Slab
	offsets := make([]u32, 255 * 16 + 1)
	defer delete(offsets)
	for &off, i in offsets {
		off = slab_alloc(&s, 4096)
		if i == 0 || i == 255 * 16 - 1 {
			check(slab_metadata_bytes(&s) == 4096 && storage_metadata_owned == 4096, "first 255 descriptors share exactly one committed metadata page")
		}
	}
	check(slab_metadata_bytes(&s) == 8192 && storage_metadata_owned == 8192 && storage_metadata_virtual == 8 << 20, "descriptor256 commits only the second metadata page")
	recount(&s)
	for off in offsets {
		slab_free(&s, off, 4096)
	}
	recount(&s)
	slab_detach(&s)
	check(storage_metadata_virtual == 0 && storage_metadata_writable == 0 && storage_metadata_owned == 0 && slab_dirty_runs == 0 && slab_zero_slabs == 0, "large descriptor prefix releases exactly once")
}

owner_budget :: proc() {
	owners := make([]Db, 20)
	dbs = owners
	defer delete(owners)
	for &d in dbs {
		off := slab_alloc(&d.slab, 64)
		slab_free(&d.slab, off, 64)
	}
	check(slab_zero_slabs == 20 && slab_dirty_runs == 20, "many databases publish exact global owner hints")
	for _ in 0 ..< 40 {
		work := slab_reclaim(now_ns() + 1_000_000_000)
		check(work.visited <= 16 && work.advised + work.failed <= 4 && work.retired <= 1, "global per-pass visit/advice/whole-owner ceilings")
		if !slab_reclaim_pending() {
			break
		}
	}
	check(!slab_reclaim_pending() && storage_metadata_owned == 0 && storage_slab_virtual == 0, "round-robin progress eventually retires every quiet owner")
	s := &dbs[0].slab
	off := slab_alloc(s, 64)
	slab_free(s, off, 64)
	slab_metadata_commit(s, SLAB_RUN_COUNT - 1)
	base := s.base
	owned := storage_metadata_owned
	graveyard_len = GRAVEYARD_MAX - 1
	slab_reclaim_next = 0
	work := slab_reclaim(now_ns() + 1_000_000_000, true)
	check(work.retired == 0 && s.base == base && storage_metadata_owned == owned && slab_zero_slabs == 1, "two-large-prefix retirement requires both graveyard slots before changing ownership")
	graveyard_len = GRAVEYARD_MAX - 2
	slab_reclaim_next = 0
	work = slab_reclaim(now_ns() + 1_000_000_000, true)
	check(work.retired == 1 && s.base == nil && storage_metadata_virtual == 0 && storage_slab_virtual == 0, "admitted owner releases both exact mapping prefixes")
	graveyard_len = 0
	dbs = nil
}

reclaim_fairness :: proc() {
	for locked in ([2]bool{false, true}) {
		owners := make([]Db, 16)
		dbs = owners
		keepers: [2]u32
		for &keeper, i in keepers {
			s := &dbs[i].slab
			keeper = slab_alloc(s, 24)
			offsets: [64]u32
			for &off in offsets {
				off = slab_alloc(s, 4096)
			}
			for off in offsets {
				slab_free(s, off, 4096)
			}
		}
		if locked {
			for id := slab_field(&dbs[0].slab, 0, SLAB_DIRTY_HEAD); id != 0; id = dbs[0].slab.runs[id].node.next {
				check(linux.mlock(&dbs[0].slab.base[int(id) * SLAB_RUN], SLAB_RUN) == .NONE, "lock all first-owner dirty runs")
			}
		}
		slab_reclaim_next = 0
		first := slab_reclaim(now_ns() + 1_000_000_000)
		check(first.visited == 1 && first.advised + first.failed == 4 && slab_reclaim_next == 1, "quota exhaustion preserves the following database service cursor")
		if locked {
			check(first.failed == 4, "persistent first-owner failure consumes only its finite grant")
		} else {
			offsets: [64]u32
			for &off in offsets {
				off = slab_alloc(&dbs[0].slab, 4096)
			}
			for off in offsets {
				slab_free(&dbs[0].slab, off, 4096)
			}
		}
		check(slab_field(&dbs[0].slab, 1, SLAB_DIRTY_COUNT) == 4 && slab_field(&dbs[1].slab, 1, SLAB_DIRTY_COUNT) == 4, "first owner remains replenished while the second waits")
		second := slab_reclaim(now_ns() + 1_000_000_000)
		check(second.advised == 4 && second.failed == 0 && slab_field(&dbs[1].slab, 1, SLAB_DIRTY_COUNT) == 0, "second live owner receives advice despite continual first-owner work or failure")
		for keeper, i in keepers {
			if locked && i == 0 {
				for id := slab_field(&dbs[0].slab, 0, SLAB_DIRTY_HEAD); id != 0; id = dbs[0].slab.runs[id].node.next {
					check(linux.munlock(&dbs[0].slab.base[int(id) * SLAB_RUN], SLAB_RUN) == .NONE, "unlock persistent failure fixture")
				}
			}
			slab_free(&dbs[i].slab, keeper, 24)
			slab_detach(&dbs[i].slab)
		}
		delete(owners)
		dbs = nil
		check(!slab_reclaim_pending() && storage_metadata_owned == 0 && storage_slab_virtual == 0, "fairness fixture releases all ownership")
	}
}

package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:sys/linux"

db_used_memory: int
checks: int
Db :: struct {
	slab: Slab,
}
dbs: []Db
graveyard_len: int
GRAVEYARD_MAX :: 64
RELEASE_NOW_BYTES :: 1 << 20

SLAB_STORAGE_ACCOUNTING :: #config(SLAB_STORAGE_ACCOUNTING, true)

store_fatal :: proc "contextless" (msg: string) -> ! {
	linux.write(2, transmute([]u8)string("eski: "))
	linux.write(2, transmute([]u8)msg)
	linux.write(2, transmute([]u8)string("\n"))
	linux.exit_group(1)
}

now_ns :: proc "contextless" () -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

graveyard_push :: proc "contextless" (base: [^]u8, size: int, kind: Storage_Kind = .Table) {
	when SLAB_STORAGE_ACCOUNTING {
		storage_unmap(base, size, kind)
	} else {
		linux.munmap(base, uint(size))
	}
}

check :: proc(ok: bool, name: string, loc := #caller_location) {
	checks += 1
	if !ok {
		fmt.eprintf("FAIL %s (%s:%d)\n", name, loc.file_path, loc.line)
		os.exit(2)
	}
}

final_slab :: proc() -> Slab {
	data, err := virtual.reserve(SLAB_RESERVE)
	check(err == nil, "reserve virtual address space")
	check(linux.madvise(raw_data(data), SLAB_RESERVE, .NOHUGEPAGE) == .NONE, "final reservation disables huge pages locally")
	start := SLAB_RESERVE - SLAB_RUN
	when SLAB_STORAGE_ACCOUNTING {
		storage_slab_virtual += SLAB_RESERVE
		storage_slab_writable += start
	}
	return Slab{base = raw_data(data), top = start, committed = start}
}

request_for :: proc(c: int, i: int) -> int {
	if i % 2 == 0 {
		return int(slab_class_size[c])
	}
	return 0 if c == 0 else int(slab_class_size[c - 1]) + 1
}

exercise :: proc(c: int, final: bool) {
	size := int(slab_class_size[c])
	capacity := SLAB_RUN / size
	count := capacity if final else capacity + 2
	s: Slab
	if final {
		s = final_slab()
	}
	defer {
		if s.base != nil {
			linux.munmap(s.base, SLAB_RESERVE)
		}
	}
	offsets := make([]u32, count)
	defer delete(offsets)
	for i in 0 ..< count {
		n := request_for(c, i)
		check(slab_class(n) == c && slab_size_of(n) == size, "class rounding")
		off := slab_alloc(&s, n)
		offsets[i] = off
		at := int(off) * SLAB_UNIT
		check(off != 0 && at % SLAB_UNIT == 0, "nonzero aligned offset")
		check(at >= SLAB_RUN && at <= SLAB_RESERVE - size, "allocation within reserved bounds")
		if i > 0 {
			check(at >= int(offsets[i - 1]) * SLAB_UNIT + size, "unique nonoverlapping allocation")
		}
		if final {
			check(at >= SLAB_RESERVE - SLAB_RUN, "allocation in final run")
		} else {
			run := i / capacity
			check(at / SLAB_RUN == run + 1, "ordinary run rollover")
		}
		p := slab_ptr(&s, off)
		p[0] = u8(i % 251 + 1)
		p[size - 1] = u8(i % 239 + 1)
	}
	if final {
		check(s.top == SLAB_RESERVE && s.committed == SLAB_RESERVE, "final run committed without exceeding reservation")
		check(s.run_pos[c] == 0, "final run explicitly exhausted")
		end := int(offsets[count - 1]) * SLAB_UNIT + size
		check(SLAB_RESERVE - end == SLAB_RUN % size, "all final-run capacity allocated")
		if size == SLAB_UNIT {
			check(offsets[count - 1] == max(u32), "maximum u32 offset allocated")
		}
	}
	check(s.live == count * size && db_used_memory == s.live, "allocation accounting")
	if !final {
		recount(&s)
	} else {
		final_metadata(&s, c, false)
	}
	for off, i in offsets {
		p := slab_ptr(&s, off)
		check(p[0] == u8(i % 251 + 1) && p[size - 1] == u8(i % 239 + 1), "allocation bytes intact")
	}
	last := offsets[count - 1]
	slab_free(&s, last, size)
	check(slab_alloc(&s, size) == last, "final block free and reuse")
	if !final {
		freed := make(map[u32]bool)
		for i := 0; i < count; i += 2 {
			slab_free(&s, offsets[i], size)
			freed[offsets[i]] = true
		}
		recount(&s)
		for i := 0; i < count; i += 2 {
			off := slab_alloc(&s, size)
			check(freed[off], "every size class reuses a unique partial-run free-chain cell")
			delete_key(&freed, off)
		}
		check(len(freed) == 0, "partial-run free chains drain exactly across all size classes")
		delete(freed)
		recount(&s)
	}
	top := s.top
	pos := s.run_pos[c]
	for off in offsets {
		slab_free(&s, off, size)
	}
	check(s.live == 0 && db_used_memory == 0, "free accounting")
	if !final {
		recount(&s)
	} else {
		final_metadata(&s, c, true)
	}
	seen := make(map[u32]bool)
	defer delete(seen)
	for i in 0 ..< count {
		off := slab_alloc(&s, request_for(c, i))
		check(!seen[off], "full-free reuse returns unique cells")
		seen[off] = true
		check(s.top == top, "reuse does not advance high water")
	}
	for off in offsets {
		check(seen[off], "empty-run reassignment reuses the same valid cell set")
	}
	_ = pos
	check(s.free[c] == 0 && s.live == count * size, "free list drained exactly")
	if !final {
		recount(&s)
	} else {
		final_metadata(&s, c, false)
	}
	if c % 2 == 0 {
		base, committed := slab_take(&s)
		check(base != nil && committed > 0, "take allocated slab")
		when SLAB_STORAGE_ACCOUNTING {
			storage_unmap(base, committed, .Slab)
		} else {
			linux.munmap(base, uint(committed))
		}
	} else {
		slab_detach(&s)
	}
	check(s.base == nil && s.top == 0 && s.live == 0 && db_used_memory == 0, "slab reset accounting")
	check(storage_slab_virtual == 0 && storage_slab_writable == 0, "slab mapping accounting reset")
	check(storage_metadata_owned == 0 && storage_metadata_virtual == 0 && storage_metadata_writable == 0, "metadata mapping accounting reset")
	check(slab_dirty_runs == 0 && slab_zero_slabs == 0, "reset cancels every pending run and owner")
}

exhaust :: proc(c: int) {
	s := final_slab()
	size := int(slab_class_size[c])
	capacity := SLAB_RUN / size
	last: u32
	for _ in 0 ..< capacity {
		last = slab_alloc(&s, size)
		check(last != 0, "exhaustion setup allocates valid offsets")
	}
	slab_free(&s, last, size)
	check(slab_alloc(&s, size) == last, "last block reusable before exhaustion")
	fmt.printf("READY %d %d\n", c, capacity)
	slab_alloc(&s, size)
	fmt.println("FAIL allocation succeeded beyond reservation")
	os.exit(2)
}

main :: proc() {
	if len(os.args) == 2 && os.args[1] == "resident" {
		resident_fixture()
		return
	}
	if len(os.args) == 2 && os.args[1] == "cow" {
		cow_fixture()
		return
	}
	if len(os.args) == 3 && os.args[1] == "exhaust" {
		c, ok := strconv.parse_int(os.args[2])
		check(ok && c >= 0 && c < SLAB_CLASSES, "valid exhaustion class")
		exhaust(c)
		return
	}
	for c in 0 ..< SLAB_CLASSES {
		exercise(c, false)
		exercise(c, true)
	}
	pool_reclaim()
	metadata_growth()
	owner_budget()
	reclaim_fairness()
	fmt.printf("PASS slab classes=%d checks=%d reserved_bytes=%d populated_run_bytes=%d\n", SLAB_CLASSES, checks, SLAB_RESERVE, SLAB_RUN)
}

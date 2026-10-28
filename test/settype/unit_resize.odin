package settype_harness

import lp "../../src/listpack"
import rdb "../../src/rdb"
import st "../../src/settype"
import "core:fmt"
import "core:strconv"

rb :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

resize_recount :: proc(t: ^st.Table) {
	seen: map[uintptr]bool
	old, live := 0, 0
	for bank in 0 ..< 2 {
		slots, cap := st.table_bank(t, bank)
		for i in 0 ..< cap {
			b := slots[i].blob
			if !st.blob_live(b) {
				continue
			}
			check(uintptr(b) not_in seen, "each member Blob has exactly one bank owner")
			seen[uintptr(b)] = true
			live += 1
			old += int(bank == 1)
		}
	}
	check(live == t.count && (t.resize == nil || old == t.resize.old_count), "independent bank recount matches live counters")
	delete(seen)
}

resize_drain :: proc(t: ^st.Table) {
	for t.resize != nil {
		work := st.table_step(t, 7, 2)
		check(work.scanned <= 7 && work.moved <= 2, "explicit member grant observes both bounds")
	}
}

resize_write :: proc(t: ^st.Table, member: []u8, remove: bool = false) {
	r := t.resize
	cursor, count := 0, 0
	if r != nil {
		cursor, count = r.cursor, r.old_count
	}
	if remove {
		check(st.table_delete(t, member), "known member removal succeeds")
	} else {
		check(st.table_add(t, member), "new member addition succeeds")
	}
	if r != nil {
		if t.resize == r {
			check(r.cursor - cursor <= 64 && count - r.old_count <= 4 + int(remove), "real member write respects migration and removal bounds")
		} else {
			check(count <= 4 + int(remove), "real final write cannot drain extra source members")
		}
	}
}

resize_release_all :: proc() {
	for st.maintenance_pending() {
		st.maintenance_release()
	}
}

resize_set :: proc(n: int, prefix: string = "member:") -> st.Set {
	s := st.create_table(n)
	for i in 0 ..< n {
		st.add(s, rb(fmt.tprintf("%s%d", prefix, i)))
	}
	st.table_resize(s.table, s.table.cap * 2)
	return s
}

unit_resize :: proc() {
	for initial in ([?]int{4, 8, 16, 32, 64, 128, 256, 512, 1024, 8192}) {
		t := st.table_make(initial / 2)
		for i in 0 ..< initial * 3 {
			resize_write(t, rb(fmt.tprintf("member:%d", i)))
			check(t.count <= t.cap / 4 * 3, "destination retains insertion headroom without emergency drain")
			if i % 257 == 0 {
				resize_recount(t)
			}
		}
		for i in 0 ..< initial * 3 {
			member := rb(fmt.tprintf("member:%d", i))
			check(st.table_contains(t, member), "every growing member remains findable")
		}
		for i in 0 ..< initial * 3 {
			resize_write(t, rb(fmt.tprintf("member:%d", i)), true)
		}
		check(t.count == 0 && t.cap == 0 && t.resize == nil, "last member detaches empty banks")
		st.table_add(t, rb("reuse"))
		check(t.cap == 4 && st.table_contains(t, rb("reuse")), "detached table supports a new member")
		st.table_free(t)
	}
	resize_release_all()
	unit_resize_views()
	unit_resize_random_pop()
	unit_resize_algebra()
	unit_resize_scan()
	unit_resize_collision()
	unit_resize_empty()
	unit_resize_release()
	t := st.table_make(0)
	state := st.Resize_State{}
	ctx := st.Context{}
	fmt.printfln("set layouts requested/usable: Table %d/%d, cold %d/%d, Context %d/%d, contexts16 %d/%d", size_of(st.Table), lp.lp_malloc_size(t), size_of(state), resize_usable(size_of(state)), size_of(ctx), resize_usable(size_of(ctx)), 16 * size_of(ctx), resize_usable(16 * size_of(ctx)))
	st.table_free(t)
}

resize_usable :: proc(n: int) -> int {
	p := lp.lp_malloc(n)
	defer lp.lp_mem_free(p)
	return lp.lp_malloc_size(p)
}

unit_resize_views :: proc() {
	s := resize_set(60, "binary\x00:")
	t := s.table
	first, second: st.Context
	st.maintenance_bind(s, &first)
	r := t.resize
	check(!st.add(s, rb("binary\x00:0")) && !st.remove(s, rb("missing")) && r.cursor == 0 && r.old_count == 60, "failed member changes do not migrate")
	pointers: map[string]uintptr
	it := st.iterator(s)
	for v in st.next(&it) {
		pointers[string(v.str)] = uintptr(raw_data(v.str))
	}
	work := st.table_step(t, 64, 4)
	check(work.scanned <= 64 && work.moved == 4, "initial two-bank migration grant")
	it = st.iterator(s)
	for v in st.next(&it) {
		check(pointers[string(v.str)] == uintptr(raw_data(v.str)), "pure Slot migration preserves borrowed member addresses")
	}
	delete(pointers)
	d := st.dup(s)
	check(st.size(d) == 60 && s.table.resize != nil, "duplicate visits both banks without draining source")
	for member in set_members(d) {
		check(st.is_member(s, rb(member)), "duplicate preserves binary member bytes")
	}
	st.destroy(d)
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	st.rdb_save(&w, s)
	reader: rdb.Reader
	rdb.reader_init_mem(&reader, rdb.writer_bytes(&w), false)
	loaded := st.rdb_load(&reader, int(st.rdb_type(s)), true)
	check(loaded != nil && st.size(loaded) == 60, "two-bank RDB round trip preserves count")
	for member in set_members(s) {
		check(st.is_member(loaded, rb(member)), "RDB preserves full binary members")
	}
	st.destroy(loaded)
	rdb.reader_destroy(&reader)
	rdb.writer_destroy(&w)
	st.maintenance_bind(s, &second)
	check(first.resize_count == 0 && second.resize_count == 1, "single Set job rebinds owner context")
	st.maintenance_clear(&second)
	st.maintenance_bind(s, &first)
	check(first.resize_count == 1 && second.resize_count == 0, "invalidated generation safely rebinds")
	for t.resize != nil {
		owner, grant := st.maintenance_step(&first, 64, 4)
		check(owner == s && grant.scanned <= 64 && grant.moved <= 4, "quiet Set service returns exact owner and bounded work")
	}
	check(first.resize_count == 0, "completion unlinks the owner job")
	long_member: [4096]u8
	for &v, i in long_member {
		v = u8(i % 251)
	}
	st.add(s, long_member[:])
	st.add(s, rb(""))
	st.add(s, rb("prefix"))
	st.add(s, rb("prefix\x00tail"))
	st.table_resize(t, t.cap * 2)
	st.table_step(t, 64, 4)
	check(st.is_member(s, long_member[:]) && st.is_member(s, rb("")) && st.is_member(s, rb("prefix\x00tail")) && !st.is_member(s, rb("prefix\x00")), "empty, long and common-prefix binary members keep full comparison bounds")
	rdb.writer_init_mem(&w, false, false)
	st.rdb_save(&w, s)
	rdb.reader_init_mem(&reader, rdb.writer_bytes(&w), false)
	loaded = st.rdb_load(&reader, int(st.rdb_type(s)), true)
	check(loaded != nil && st.size(loaded) == 64 && st.is_member(loaded, long_member[:]) && st.is_member(loaded, rb("")) && st.is_member(loaded, rb("prefix\x00tail")), "two-bank RDB preserves long and empty binary member bytes")
	st.destroy(loaded)
	rdb.reader_destroy(&reader)
	rdb.writer_destroy(&w)
	st.destroy(s)
	resize_release_all()
}

unit_resize_random_pop :: proc() {
	s := resize_set(60)
	st.table_step(s.table, 64, 4)
	hits: [60]int
	lp.lp_srand(0x76B04611)
	for _ in 0 ..< 30000 {
		v := st.random_element(s)
		i, ok := strconv.parse_int(string(v.str)[7:])
		check(ok && i >= 0 && i < 60, "random sampling returns a member from either bank")
		hits[i] += 1
	}
	for hit in hits {
		check(hit > 350 && hit < 650, "bank weighting preserves equal member probability")
	}
	for count in ([?]int{20, 21, 59}) {
		out: [dynamic]st.Value
		st.random_unique(s, count, &out)
		check(len(out) == count, "both unique strategies return requested count")
		seen: map[string]bool
		for v in out {
			member := string(v.str)
			check(member not_in seen && st.is_member(s, v.str), "unique sample uses member identity across banks")
			seen[member] = true
		}
		delete(seen)
		delete(out)
	}
	st.destroy(s)
	for count in ([?]int{1, 20, 50, 59}) {
		source := resize_set(60, "pop\x00:")
		popped: st.Popped
		newset := st.spop_count(source, count, &popped)
		remaining := source if newset == nil else newset
		check(st.popped_len(&popped) == count && st.size(remaining) == 60 - count, "SPOP strategies split exact cardinalities")
		seen: map[string]bool
		for i in 0 ..< st.popped_len(&popped) {
			v := st.popped_get(&popped, i)
			check(string(v.str) not_in seen, "popped copies are unique")
			seen[string(v.str)] = true
		}
		it := st.iterator(remaining)
		for v in st.next(&it) {
			check(string(v.str) not_in seen, "remaining members do not alias popped membership")
			seen[string(v.str)] = true
		}
		for i in 0 ..< 60 {
			check(fmt.tprintf("pop\x00:%d", i) in seen, "SPOP preserves every binary member across copied/deleted banks")
		}
		delete(seen)
		st.popped_destroy(&popped)
		if newset != nil {
			st.destroy(newset)
		}
		st.destroy(source)
	}
	resize_release_all()
}

unit_resize_algebra :: proc() {
	a := resize_set(60, "a:")
	b := st.create_table(60)
	for i in 30 ..< 90 {
		st.add(b, rb(fmt.tprintf("a:%d", i)))
	}
	st.table_resize(b.table, b.table.cap * 2)
	sources := [2]st.Set{a, b}
	out: [dynamic]st.Value
	check(st.inter_collect(sources[:], &out) == 30 && len(out) == 30, "intersection reads both banks")
	check(st.inter_card(sources[:], 7) == 7, "intersection cardinality preserves LIMIT")
	inter := st.inter_store(sources[:])
	united := st.union_diff(sources[:], .Union)
	diff := st.union_diff(sources[:], .Diff)
	check(st.size(inter) == 30 && st.size(united) == 90 && st.size(diff) == 30, "all algebra results retain correct two-bank cardinalities")
	for i in 0 ..< 90 {
		member := rb(fmt.tprintf("a:%d", i))
		check(st.is_member(inter, member) == (i >= 30 && i < 60), "intersection exact membership")
		check(st.is_member(united, member), "union exact membership")
		check(st.is_member(diff, member) == (i < 30), "difference exact membership")
	}
	check(a.table.resize.cursor == 0 && b.table.resize.cursor == 0, "read-only algebra never drains an input")
	repeated := [2]st.Set{a, a}
	empty := st.union_diff(repeated[:], .Diff)
	check(st.size(empty) == 0, "same-set difference remains empty")
	st.destroy(empty)
	st.destroy(inter)
	st.destroy(united)
	st.destroy(diff)
	st.destroy(a)
	st.destroy(b)
	delete(out)
	large := resize_set(300, "d:")
	one := st.create_table(1)
	two := st.create_table(1)
	st.add(one, rb("d:1"))
	st.add(two, rb("d:2"))
	st.table_resize(one.table, one.table.cap * 2)
	st.table_resize(two.table, two.table.cap * 2)
	inputs := [3]st.Set{large, one, two}
	d := st.union_diff(inputs[:], .Diff)
	check(st.size(d) == 298 && !st.is_member(d, rb("d:1")) && !st.is_member(d, rb("d:2")), "difference algorithm two safely mutates its separate result")
	st.destroy(d)
	st.destroy(large)
	st.destroy(one)
	st.destroy(two)
	resize_release_all()
}

unit_resize_scan :: proc() {
	for shrink in ([?]bool{false, true}) {
		s := st.create_table(256)
		for i in 0 ..< 64 {
			st.add(s, rb(fmt.tprintf("stable:%d", i)))
		}
		st.table_resize(s.table, s.table.cap / 2 if shrink else s.table.cap * 2)
		cursor: u64
		out: [dynamic]st.Value
		seen: map[string]bool
		pages := 0
		for {
			clear(&out)
			cursor = st.scan(s, cursor, 1, &out)
			for v in out {
				seen[string(v.str)] = true
			}
			pages += 1
			if cursor == 0 {
				break
			}
			st.table_step(s.table, 64, 4)
			check(pages < 4096, "tick-only SSCAN completes")
		}
		check(len(seen) == 64 && s.table.resize == nil, "SSCAN returns all continuously present members through quiet completion")
		delete(out)
		delete(seen)
		st.destroy(s)
	}
	resize_release_all()
}

unit_resize_collision :: proc() {
	t := st.table_make(64)
	fields: [40]string
	found, serial := 0, 0
	for found < len(fields) {
		field := fmt.tprintf("wrap:%d", serial)
		serial += 1
		if st.hash_member(rb(field)) & u64(t.cap - 1) != u64(t.cap - 1) {
			continue
		}
		fields[found] = field
		found += 1
		st.table_add(t, rb(field))
	}
	st.table_resize(t, t.cap * 2)
	work := st.table_step(t, 3, 2)
	check(work.scanned == 2 && work.moved == 2, "wrapped cluster migration respects a two-move grant")
	check(st.table_delete(t, rb(fields[0])), "delete the old-bank home member across a wrapped cluster")
	for i in 1 ..< len(fields) {
		check(st.table_contains(t, rb(fields[i])), "tombstones preserve wrapped old probe chains")
	}
	resize_recount(t)
	resize_drain(t)
	for i in 1 ..< len(fields) {
		check(st.table_contains(t, rb(fields[i])), "destination retains wrapped collision members")
	}
	st.table_free(t)
	resize_release_all()
}

unit_resize_empty :: proc() {
	t := st.table_make(8000)
	fields: [8]string
	found, serial := 0, 0
	for found < len(fields) {
		field := fmt.tprintf("sparse:%d", serial)
		serial += 1
		home := st.hash_member(rb(field)) & u64(t.cap - 1)
		if home < 4096 || home >= 8192 {
			continue
		}
		fields[found] = field
		found += 1
		st.table_add(t, rb(field))
	}
	check(t.cap == 16384, "sparse fixture owns known source capacity")
	st.table_resize(t, 32768)
	for member in fields {
		resize_write(t, rb(member), true)
	}
	check(t.cap == 0 && t.slots == nil && t.resize == nil, "empty sparse set detaches both banks without scanning")
	mapped, retired, metadata := st.maintenance_memory()
	check(mapped == 786432 && retired == mapped && metadata >= 176, "known 256 KiB source plus512 KiB target remain physically pending")
	for remaining := 786432; remaining > 0; remaining -= 4096 {
		check(st.maintenance_release(4096) == 4096, "empty banks release exactly one page per tiny grant")
	}
	mapped, retired, metadata = st.maintenance_memory()
	check(mapped == 0 && retired == 0 && metadata == 0, "empty-bank capacity and metadata fully settle")
	st.table_free(t)
}

unit_resize_release :: proc() {
	for _ in 0 ..< 40 {
		t := st.table_make(256)
		st.table_add(t, rb("one"))
		st.table_resize(t, 1024)
		resize_drain(t)
		st.table_free(t)
	}
	mapped, retired, metadata := st.maintenance_memory()
	check(mapped == 40 * 8192 && retired == mapped, "forty small source mappings remain physically owned")
	check(st.maintenance_release(call_budget = 0) == 0, "zero syscall quota leaves retirement untouched")
	check(st.maintenance_release(deadline_ns = 1) == 8192, "expired deadline still permits one-call progress")
	check(st.maintenance_release(call_budget = 3) == 24576, "explicit three-call release bound")
	check(st.maintenance_release() == 16 * 8192, "default sixteen-call release bound")
	resize_release_all()
	mapped, retired, metadata = st.maintenance_memory()
	check(mapped == 0 && retired == 0 && metadata == 0, "many-record release makes bounded eventual progress")
}

resize_guard :: proc(name: string) {
	switch name {
	case "negative":
		st.table_make(-1)
	case "overflow":
		st.table_make(max(int))
	case "capacity":
		st.slots_alloc(3)
	case "generation":
		ctx := st.Context{resize_epoch = max(u64)}
		st.maintenance_clear(&ctx)
	}
}

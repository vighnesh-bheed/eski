package hashtype_harness

import ht "../../src/hashtype"
import rdb "../../src/rdb"
import lp "../../src/listpack"
import "core:strconv"
import "core:strings"
import "core:fmt"

resize_drain :: proc(t: ^ht.Table) {
	for t.resize != nil {
		work := ht.table_step(t, 7, 2)
		check(work.scanned <= 7 && work.moved <= 2, "explicit migration grant obeys both limits")
	}
}

resize_write_check :: proc(t: ^ht.Table, field: string, remove: bool = false) {
	before := t.resize
	cursor, count := 0, 0
	if before != nil {
		cursor, count = before.cursor, before.old_count
	}
	if remove {
		ht.table_delete(t, b(field))
	} else {
		ht.table_set(t, b(field), b("updated\x00value"), true)
	}
	if before != nil {
		if t.resize == before {
			check(before.cursor - cursor <= ht.RESIZE_WRITE_SCANS && count - before.old_count <= ht.RESIZE_WRITE_MOVES + int(remove), "actual field write respects migration and deletion limits")
		} else {
			check(count <= ht.RESIZE_WRITE_MOVES + int(remove), "actual final field write cannot drain more than its move allowance")
		}
	}
}

unit_resize :: proc() {
	set_config(0, 0)
	for initial in ([?]int{4, 8, 16, 32, 64, 128, 256, 512, 1024, 8192}) {
		t := ht.table_make(initial / 2)
		for i in 0 ..< initial * 3 {
			resize_write_check(t, tp("field:", i))
			check(t.count <= t.cap / 4 * 3, "every insert retains destination headroom without draining")
			if i % 257 == 0 {
				resize_recount(t)
			}
		}
		for i in 0 ..< initial * 3 {
			_, found := ht.table_get(t, b(tp("field:", i)))
			check(found, "all growing-bank fields remain findable")
		}
		for i in 0 ..< initial * 3 - 1 {
			resize_write_check(t, tp("field:", i), true)
		}
		resize_drain(t)
		check(t.count == 1, "deletion and partial shrink retain final field")
		ht.table_free(t)
	}
	h := ht.create()
	ht.convert(h, 3072)
	t := h.table
	for i in 0 ..< 3072 {
		ht.set(h, b(tp("binary\x00:", i)), b("value\x00suffix"))
	}
	r0: ht.Registry
	r1: ht.Registry
	ttl_fields := [3][]u8{b("binary\x00:0"), b("binary\x00:1"), b("binary\x00:3000")}
	ttl_result: [dynamic]i64
	defer delete(ttl_result)
	ht.expire_fields(&r0, nil, h, ttl_fields[:], NOW + 1000, .None, NOW, &ttl_result)
	ht.table_resize(t, t.cap * 2)
	ht.maintenance_bind(h, &r0)
	check(r0.resize_count == 1 && r0.resize_head.owner == h, "active hash binds once to its cold registry")
	before_cursor := t.resize.cursor
	for _ in 0 ..< 50 {
		ht.table_get(t, ttl_fields[0])
	}
	check(t.resize.cursor == before_cursor, "pure lookups do not mutate a migration or its accounting")
	work := ht.table_step(t, 64, 4)
	check(work.scanned <= 64 && work.moved == 4, "four-entry migration grant")
	for i in 0 ..< 3 {
		s := ht.table_find(t, ttl_fields[i], ht.hash_field(ttl_fields[i]))
		check(s != nil && t.vol[s.blob.hidx - 1].blob == s.blob, "migration preserves TTL heap blob identity")
	}
	for bank in 0 ..< 2 {
		slots, cap := ht.table_bank(t, bank)
		for i in 0 ..< cap {
			if ht.blob_live(slots[i].blob) {
				field := strings.clone(string(ht.blob_field(slots[i].blob)), context.temp_allocator)
				ht.vol_set(t, slots[i].blob, NOW + 1000)
				long_value: [4096]u8
				for &v, j in long_value {
					v = u8(j % 251)
				}
				ht.table_set(t, b(field), long_value[:], true)
				s := ht.table_find(t, b(field), ht.hash_field(b(field)))
				check(s != nil && s.blob.vlen == 4096 && t.vol[s.blob.hidx - 1].blob == s.blob && ht.table_field_expire(t, s.blob) == NOW + 1000, "value realloc refreshes the actual bank and shared TTL heap pointer")
				break
			}
		}
	}
	d, _ := ht.duplicate(h)
	check(ht.length(d) == ht.length(h), "duplicate visits both banks without completing source migration")
	it := ht.iterator(d)
	for ht.next(&it) {
		v, _, found := ht.get_raw(h, ht.blob_field(it.blob))
		check(found && vstr(v) == vstr(ht.current_value(&it)), "copied binary fields and values match source")
	}
	ht.destroy(d)
	writer: rdb.Writer
	rdb.writer_init_mem(&writer, false, false)
	ht.rdb_save(&writer, h)
	check(writer.len > 0, "RDB saves an in-progress member migration")
	reader: rdb.Reader
	rdb.reader_init_mem(&reader, rdb.writer_bytes(&writer), false)
	loaded := ht.rdb_load(&reader, int(ht.rdb_type(h)), true)
	check(loaded != nil && ht.length(loaded) == ht.length(h), "RDB reload contains both source and destination banks")
	lit := ht.iterator(h)
	for ht.next(&lit) {
		v, expire, found := ht.get_raw(loaded, ht.blob_field(lit.blob))
		check(found && vstr(v) == vstr(ht.current_value(&lit)) && expire == ht.current_expire(&lit), "RDB round trip preserves each binary field, value and TTL")
	}
	ht.destroy(loaded)
	rdb.reader_destroy(&reader)
	rdb.writer_destroy(&writer)
	ht.maintenance_bind(h, &r1)
	check(r0.resize_count == 0 && r1.resize_count == 1, "MOVE-style registry rebind is constant work")
	ht.maintenance_clear(&r1)
	check(r1.resize_count == 0 && r1.resize_head == nil, "bulk cancellation detaches the whole queue")
	ht.maintenance_bind(h, &r0)
	check(r0.resize_count == 1, "invalidated source generation can bind again safely")
	for t.resize != nil {
		hh, grant := ht.maintenance_step(&r0, 64, 4)
		check(hh == h && grant.scanned <= 64 && grant.moved <= 4, "quiet work returns the owner and bounded work")
	}
	check(r0.resize_count == 0, "completed migration leaves no active registry job")
	mapped, retired, metadata := ht.maintenance_memory()
	check(mapped >= t.cap * size_of(ht.Slot) && retired > 0 && metadata > 0, "mapped retirement preserves physical and metadata ownership")
	for ht.maintenance_pending() {
		check(ht.maintenance_release(4096) <= 4096, "retired source unmaps at most one page per release grant")
	}
	_, retired, metadata = ht.maintenance_memory()
	check(retired == 0 && metadata == 0, "all retired mapping and metadata charges settle exactly")
	ht.registry_destroy(&r0)
	ht.registry_destroy(&r1)
	ht.destroy(h)
	unit_resize_collision()
	unit_resize_scan_random()
	unit_resize_empty()
	unit_resize_release_budget()
	tiny := ht.table_make(0)
	r := ht.Resize_State{}
	reg := ht.Registry{}
	fmt.printfln("    hash layouts requested/usable: Table %d/%d, Resize %d/%d, Registry %d/%d", size_of(ht.Table), ht.mem_usable_size(tiny), size_of(r), resize_usable(size_of(r)), size_of(reg), resize_usable(size_of(reg)))
	fmt.printfln("    default Registry array requested/usable: %d/%d", 16 * size_of(ht.Registry), resize_usable(16 * size_of(ht.Registry)))
	ht.table_free(tiny)
}

resize_usable :: proc(n: int) -> int {
	p := ht.mem_alloc(n)
	defer ht.mem_free(p)
	return ht.mem_usable_size(p)
}

unit_resize_collision :: proc() {
	t := ht.table_make(64)
	fields: [40]string
	found, serial := 0, 0
	for found < len(fields) {
		f := tp("wrap:", serial)
		serial += 1
		if ht.hash_field(b(f)) & u64(t.cap - 1) != u64(t.cap - 1) {
			continue
		}
		fields[found] = f
		found += 1
		ht.table_set(t, b(f), b("collision"))
	}
	ht.table_resize(t, t.cap * 2)
	w := ht.table_step(t, 3, 2)
	check(w.scanned == 2 && w.moved == 2, "wrapped collision cluster migrates within a two-entry grant")
	check(ht.table_delete(t, b(fields[0])), "delete old source home slot while cluster wraps")
	for i in 1 ..< len(fields) {
		_, ok := ht.table_get(t, b(fields[i]))
		check(ok, "old-bank tombstones preserve all collision probe chains")
	}
	resize_drain(t)
	for i in 1 ..< len(fields) {
		_, ok := ht.table_get(t, b(fields[i]))
		check(ok, "destination wrap collision survives full migration")
	}
	ht.table_free(t)
	for ht.maintenance_pending() {
		ht.maintenance_release()
	}
}

resize_guard :: proc(name: string) {
	switch name {
	case "negative":
		ht.table_make(-1)
	case "overflow":
		ht.table_make(max(int))
	case "capacity":
		ht.slots_alloc(3)
	case "generation":
		reg := ht.Registry{resize_epoch = max(u64)}
		ht.maintenance_clear(&reg)
	}
}

unit_resize_scan_random :: proc() {
	for shrink in ([?]bool{false, true}) {
		h := ht.create()
		ht.convert(h, 256)
		for i in 0 ..< 64 {
			ht.set(h, b(tp("stable:", i)), b("value\x00"))
		}
		t := h.table
		ht.table_resize(t, t.cap / 2 if shrink else t.cap * 2)
		cursor: u64
		seen: map[string]bool
		out: [dynamic]ht.Value
		pages := 0
		for {
			clear(&out)
			cursor = ht.scan(h, cursor, ht.Scan_Options{count = 1, no_values = true}, &out, NOW)
			for value in out {
				seen[vstr(value)] = true
			}
			pages += 1
			if cursor == 0 {
				break
			}
			ht.table_step(t, 64, 4)
			check(pages < 4096, "tick-only HSCAN completes")
		}
		check(len(seen) == 64 && t.resize == nil, "HSCAN retains every stable field through tick-only grow/shrink completion")
		delete(seen)
		delete(out)
		ht.destroy(h)
	}
	h := ht.create()
	ht.convert(h, 64)
	for i in 0 ..< 64 {
		ht.set(h, b(tp("sample:", i)), b(tp("value:", i)))
	}
	reg: ht.Registry
	fields := [4][]u8{b("sample:0"), b("sample:1"), b("sample:2"), b("sample:3")}
	result: [dynamic]i64
	ht.expire_fields(&reg, nil, h, fields[:], NOW + 10, .None, NOW, &result)
	delete(result)
	ht.table_resize(h.table, h.table.cap * 2)
	ht.table_step(h.table, 64, 4)
	ht.expire_if_needed(h, NOW + 11)
	check(ht.length(h) == 60 && h.table.resize != nil, "expired-field filtering leaves two live banks")
	hits: [64]int
	lp.lp_srand(0x738A0E43)
	for _ in 0 ..< 30000 {
		f, v := ht.random_element(h)
		index, ok := strconv.parse_int(vstr(f)[7:])
		check(ok && index >= 4 && index < 64 && vstr(v) == tp("value:", index), "random sample filters expired fields and pairs both-bank values")
		hits[index] += 1
	}
	for i in 4 ..< 64 {
		check(hits[i] > 350 && hits[i] < 650, "both banks have equal per-field selection probability")
	}
	out, values: [dynamic]ht.Value
	seen: map[string]bool
	for count in ([?]int{20, 21, 59}) {
		clear(&out)
		clear(&values)
		clear(&seen)
		ht.random_unique(h, count, true, &out, &values)
		check(len(out) == count && len(values) == count, "both random strategies return exact requested field/value lengths")
		for f, i in out {
			key := vstr(f)
			check(key not_in seen && vstr(values[i]) == tp("value:", key[7:]), "unique random selection uses Blob identity across banks")
			seen[key] = true
		}
	}
	delete(seen)
	delete(out)
	delete(values)
	ht.registry_destroy(&reg)
	ht.destroy(h)
	for ht.maintenance_pending() {
		ht.maintenance_release()
	}
}

resize_recount :: proc(t: ^ht.Table) {
	seen: map[uintptr]bool
	old, live := 0, 0
	for bank in 0 ..< 2 {
		slots, cap := ht.table_bank(t, bank)
		for i in 0 ..< cap {
			b := slots[i].blob
			if !ht.blob_live(b) {
				continue
			}
			check(uintptr(b) not_in seen, "each live Blob has exactly one owner across banks")
			seen[uintptr(b)] = true
			live += 1
			old += int(bank == 1)
		}
	}
	check(live == t.count && (t.resize == nil || old == t.resize.old_count), "independent both-bank recount matches total and source live counts")
	delete(seen)
}

unit_resize_empty :: proc() {
	t := ht.table_make(8000)
	check(t.cap == 16384, "sparse empty fixture owns the expected 256 KiB source")
	fields: [8]string
	found, serial := 0, 0
	for found < len(fields) {
		field := tp("sparse:", serial)
		serial += 1
		home := ht.hash_field(b(field)) & u64(t.cap - 1)
		if home < 4096 || home >= 8192 {
			continue
		}
		fields[found] = field
		found += 1
		ht.table_set(t, b(field), b("value"))
	}
	ht.table_resize(t, 32768)
	for i in 0 ..< 8 {
		resize_write_check(t, fields[i], true)
	}
	check(t.count == 0 && t.cap == 0 && t.slots == nil && t.resize == nil, "last field detaches both large empty banks without a source scan")
	mapped, retired, metadata := ht.maintenance_memory()
	check(mapped == 786432 && retired == 786432 && metadata >= 2 * size_of(ht.Resize_State), "known 256 KiB source and 512 KiB target remain pending bounded unmap")
	for remaining := 786432; remaining > 0; remaining -= 4096 {
		check(ht.maintenance_release(4096) == 4096, "empty-bank retirement releases exactly one page per grant")
	}
	mapped, retired, metadata = ht.maintenance_memory()
	check(mapped == 0 && retired == 0 && metadata == 0, "empty-bank physical and metadata ownership settles exactly")
	ht.table_set(t, b("reused"), b("again"))
	value, exists := ht.table_get(t, b("reused"))
	check(exists && string(value) == "again" && t.cap == 4, "detached empty table supports its next write")
	ht.table_free(t)
}

unit_resize_release_budget :: proc() {
	for _ in 0 ..< 40 {
		t := ht.table_make(256)
		ht.table_set(t, b("one"), b("value"))
		ht.table_resize(t, 1024)
		for t.resize != nil {
			ht.table_step(t, 64, 4)
		}
		ht.table_free(t)
	}
	mapped, retired, metadata := ht.maintenance_memory()
	check(mapped == 40 * 8192 && retired == mapped, "many-small-retired fixture owns forty known 8 KiB source arrays")
	check(ht.maintenance_release(call_budget = 0) == 0, "zero syscall allowance leaves retirement untouched")
	check(ht.maintenance_release(deadline_ns = 1) == 8192, "expired soft deadline allows one-call progress and checks before the next record")
	check(ht.maintenance_release(call_budget = 3) == 3 * 8192, "release service obeys an explicit three-unmap-call cap")
	check(ht.maintenance_release() == ht.RESIZE_RELEASE_CALLS * 8192, "default release service obeys its sixteen-call cap below the byte budget")
	for ht.maintenance_pending() {
		ht.maintenance_release()
	}
	mapped, retired, metadata = ht.maintenance_memory()
	check(mapped == 0 && retired == 0 && metadata == 0, "bounded many-record retirement completes without starvation")
}

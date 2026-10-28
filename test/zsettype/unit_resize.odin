package zsettype_harness

import rdb "../../src/rdb"
import zt "../../src/zsettype"
import "core:fmt"
import "core:strconv"

resize_recount :: proc(z: zt.Zset) {
	sl := z.sl
	seen: map[uintptr]bool
	ranks: map[uintptr]int
	old, live := 0, 0
	for bank in 0 ..< 2 {
		slots, cap := zt.dict_bank(sl, bank)
		for i in 0 ..< cap {
			n := slots[i]
			if uintptr(n) <= 1 {
				continue
			}
			check(uintptr(n) not_in seen, "canonical Node appears in exactly one dictionary bank")
			seen[uintptr(n)] = true
			live += 1
			old += int(bank == 1)
		}
	}
	check(live == sl.count && sl.count == sl.length && (sl.resize == nil || old == sl.resize.old_count), "independent dictionary counts match the ordered length")
	rank, bytes := 0, 0
	prev: ^zt.Node
	for n := zt.sl_first(sl); n != nil; n = zt.sl_next(n) {
		rank += 1
		ranks[uintptr(n)] = rank
		check(uintptr(n) in seen && n.backward == prev, "ordered chain owns every indexed Node exactly once")
		delete_key(&seen, uintptr(n))
		check(n.hash == zt.hash_member(zt.node_member(n)) && n.nlevel >= 1 && n.nlevel <= 32, "Node cached hash and level bounds survive migration")
		check(zt.dict_find(sl, zt.node_member(n), n.hash) == n && zt.sl_get_by_rank(sl, u64(rank)) == n && zt.sl_get_rank(sl, n.score, zt.node_member(n)) == u64(rank), "dictionary, score rank and ordered rank resolve the same Node")
		if prev != nil {
			check(prev.score < n.score || (prev.score == n.score && zt.member_cmp(zt.node_member(prev), zt.node_member(n)) < 0), "score and binary lexicographic order remain canonical")
		}
		bytes += zt.mem_usable_size(n)
		prev = n
	}
	check(rank == sl.length && len(seen) == 0 && sl.tail == prev && sl.bytes == bytes, "ordered ownership and actual live Node bytes agree")
	for level in 0 ..< sl.level {
		current := sl.header
		for {
			link := zt.node_levels(current)[level]
			distance := sl.length - ranks[uintptr(current)]
			if link.forward != nil {
				distance = ranks[uintptr(link.forward)] - ranks[uintptr(current)]
			}
			check(link.span == u64(distance), "each skiplist span equals an independently counted rank distance")
			if link.forward == nil {
				break
			}
			current = link.forward
		}
	}
	delete(seen)
	delete(ranks)
}

resize_drain :: proc(sl: ^zt.Skiplist) {
	for sl.resize != nil {
		work := zt.dict_step(sl, 7, 2)
		check(work.scanned <= 7 && work.moved <= 2, "explicit dictionary grant observes both bounds")
	}
}

resize_release_all :: proc() {
	for zt.maintenance_pending() {
		zt.maintenance_release()
	}
}

resize_zset :: proc(n: int, prefix: string = "member:") -> zt.Zset {
	z := zt.create_skiplist(n)
	for i in 0 ..< n {
		zt.add(z, f64(i), b(fmt.tprintf("%s%d", prefix, i)), {})
	}
	zt.dict_resize(z.sl, z.sl.cap * 2)
	return z
}

resize_change :: proc(z: zt.Zset, member: []u8, score: f64, remove: bool = false) {
	r := z.sl.resize
	cursor, count := 0, 0
	if r != nil {
		cursor, count = r.cursor, r.old_count
	}
	if remove {
		check(zt.del(z, member), "known Node removal succeeds")
	} else {
		_, _, ok := zt.add(z, score, member, {})
		check(ok, "Node insertion or score change succeeds")
	}
	if r != nil {
		if z.sl.resize == r {
			check(r.cursor - cursor <= 64 && count - r.old_count <= 4 + int(remove), "real mutation respects source scans and pointer-move bounds")
		} else {
			check(count <= 4 + int(remove), "final mutation cannot drain more than its grant")
		}
	}
}

unit_resize :: proc() {
	zt.set_seed(0x7718B6E1)
	for initial in ([?]int{4, 8, 16, 32, 64, 128, 256, 512, 1024, 8192}) {
		z := zt.create_skiplist(initial / 2)
		for i in 0 ..< initial * 3 {
			resize_change(z, b(fmt.tprintf("member:%d", i)), f64(i % 11))
			check(z.sl.count <= z.sl.cap / 4 * 3, "destination retains headroom without emergency completion")
			if i % 2053 == 0 {
				resize_recount(z)
			}
		}
		for i in 0 ..< initial * 3 {
			resize_change(z, b(fmt.tprintf("member:%d", i)), 0, true)
		}
		check(z.sl.count == 0 && z.sl.length == 0 && z.sl.bytes == 0 && z.sl.cap == 0 && z.sl.slots == nil && z.sl.resize == nil, "final Node removal detaches both empty indexes")
		zt.add(z, 1, b("reuse"), {})
		check(z.sl.cap == 4 && zt.length(z) == 1, "empty Skiplist/header support reinsertion")
		resize_recount(z)
		zt.destroy(z)
	}
	resize_release_all()
	unit_resize_shrink_refill()
	unit_resize_identity()
	unit_resize_rng_alloc()
	unit_resize_union()
	unit_resize_random()
	unit_resize_scan_ranges()
	unit_resize_collision()
	unit_resize_empty_release()
	z := zt.create_skiplist(0)
	fmt.printfln("zset layouts requested/usable: Skiplist %d/%d header %d/%d cold %d/%d Context %d/%d contexts16 %d/%d", size_of(zt.Skiplist), zt.mem_usable_size(z.sl), size_of(zt.Node) + 32 * size_of(zt.Level), zt.mem_usable_size(z.sl.header), size_of(zt.Resize_State), resize_usable(size_of(zt.Resize_State)), size_of(zt.Context), resize_usable(size_of(zt.Context)), 16 * size_of(zt.Context), resize_usable(16 * size_of(zt.Context)))
	zt.destroy(z)
}

resize_usable :: proc(n: int) -> int {
	p := zt.mem_alloc(n)
	defer zt.mem_free(p)
	return zt.mem_usable_size(p)
}

unit_resize_identity :: proc() {
	z := resize_zset(96, "binary\x00:")
	sl := z.sl
	before: map[string]^zt.Node
	for n := zt.sl_first(sl); n != nil; n = zt.sl_next(n) {
		before[string(zt.node_member(n))] = n
	}
	ctx: zt.Context
	zt.maintenance_bind(z, &ctx)
	work := zt.dict_step(sl, 64, 4)
	check(work.moved == 4 && work.scanned <= 64, "pure dictionary grant moves pointers only")
	for member, node in before {
		check(zt.dict_find(sl, b(member), node.hash) == node, "migration preserves Node and borrowed member identity")
	}
	cursor, source := sl.resize.cursor, sl.resize.old_count
	zt.add(z, 0, b("binary\x00:0"), {})
	zt.add(z, 99, b("binary\x00:0"), {.Nx})
	zt.add(z, 0, b("missing"), {.Xx})
	zt.add(z, -1, b("binary\x00:0"), {.Gt})
	zt.add(z, 99, b("binary\x00:0"), {.Lt})
	_, _, accepted := zt.add(z, zt.F64_NAN, b("binary\x00:0"), {})
	check(!accepted, "NaN score is rejected without dictionary work")
	zt.del(z, b("missing"))
	check(sl.resize.cursor == cursor && sl.resize.old_count == source, "no-op score/condition/missing operations do not migrate")
	for bank in 0 ..< 2 {
		slots, cap := zt.dict_bank(sl, bank)
		selected: ^zt.Node
		for i in 0 ..< cap {
			if uintptr(slots[i]) > 1 && slots[i].score != 2 && slots[i].score != 90 && slots[i].score != 50 {
				selected = slots[i]
				break
			}
		}
		check(selected != nil, "score-update fixture contains a live Node in each physical bank")
		member := zt.node_member(selected)
		resize_change(z, member, selected.score + 0.25)
		check(zt.dict_find(sl, member, selected.hash) == selected, "in-place score change retains either-bank Node identity")
		resize_change(z, member, f64(-1000 - bank))
		check(zt.dict_find(sl, member, selected.hash) == selected, "ordered reinsert retains either-bank Node identity")
	}
	for member, node in before {
		if node.score == 2 || node.score == 90 {
			resize_change(z, b(member), 50)
			check(zt.dict_find(sl, b(member), node.hash) == node, "score reorder preserves canonical Node identity")
		}
	}
	delete(before)
	long_member: [4096]u8
	for &v, i in long_member {
		v = u8(i % 251)
	}
	zt.add(z, 0, long_member[:], {})
	zt.add(z, 0, b(""), {})
	zt.add(z, 0, b("prefix"), {})
	zt.add(z, 0, b("prefix\x00tail"), {})
	zt.add(z, zt.F64_INF, b("positive-infinity"), {})
	zt.add(z, zt.F64_NEG_INF, b("negative-infinity"), {})
	zt.add(z, f64(0h8000_0000_0000_0000), b("negative-zero"), {})
	_, long_found := zt.score(z, long_member[:])
	_, prefix_found := zt.score(z, b("prefix\x00"))
	check(long_found && !prefix_found, "dictionary compares full long and NUL-prefix member bytes")
	resize_recount(z)
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	zt.rdb_save(&w, z)
	r: rdb.Reader
	rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
	loaded := zt.rdb_load(&r, int(zt.rdb_type(z)), true)
	check(loaded != nil && zt.length(loaded) == zt.length(z), "ordered RDB includes Nodes from both indexes")
	for n := zt.sl_first(sl); n != nil; n = zt.sl_next(n) {
		score, found := zt.score(loaded, zt.node_member(n))
		check(found && bits_of(score) == bits_of(n.score), "RDB retains binary member and exact score bits")
	}
	zt.destroy(loaded)
	rdb.reader_destroy(&r)
	rdb.writer_destroy(&w)
	for sl.resize != nil {
		owner, grant := zt.maintenance_step(&ctx, 64, 4)
		check(owner == z && grant.scanned <= 64 && grant.moved <= 4, "quiet dictionary work returns exact owner and work")
	}
	check(ctx.resize_count == 0, "completed dictionary unlinks its cold context")
	resize_recount(z)
	zt.destroy(z)
	resize_release_all()
}

unit_resize_union :: proc() {
	a := zt.create_skiplist(96)
	bb := zt.create_skiplist(98)
	for i in 0 ..< 96 {
		zt.add(a, f64(i), b(fmt.tprintf("a:%d", i)), {})
	}
	for i in 0 ..< 98 {
		zt.add(bb, f64(i), b(fmt.tprintf("b:%d", i)), {})
	}
	sources := [2]zt.Source{zt.source_make(a), zt.source_make(bb)}
	z, _, _, _ := zt.setop_compute(sources[:], .Union, .Sum, false, 0)
	check(z.sl.resize != nil && z.sl.count == 194 && z.sl.length == 194, "ZUNION final linking visits both banks while dictionary-first migration remains active")
	resize_recount(z)
	for i in 0 ..< 96 {
		score, found := zt.score(z, b(fmt.tprintf("a:%d", i)))
		check(found && score == f64(i), "ZUNION preserves every first-source Node")
	}
	for i in 0 ..< 98 {
		score, found := zt.score(z, b(fmt.tprintf("b:%d", i)))
		check(found && score == f64(i), "ZUNION preserves every second-source Node")
	}
	repeated := [2]zt.Source{zt.source_make(z, 2), zt.source_make(z, -1)}
	agg, _, _, _ := zt.setop_compute(repeated[:], .Union, .Sum, false, 0)
	check(zt.length(agg) == 194, "duplicate source IDs keep unique canonical Nodes")
	resize_recount(agg)
	for n := zt.sl_first(z.sl); n != nil; n = zt.sl_next(n) {
		score, found := zt.score(agg, zt.node_member(n))
		check(found && score == n.score, "weighted repeated-source aggregation reads both banks")
	}
	zt.destroy(a)
	zt.destroy(bb)
	zt.destroy(z)
	zt.destroy(agg)
	resize_release_all()
}

unit_resize_random :: proc() {
	z := resize_zset(60, "sample:")
	zt.dict_step(z.sl, z.sl.resize.old_cap, 59)
	check(z.sl.resize.old_count == 1, "random fixture has sparse source and dense destination")
	for budget in ([3]int{0, 8, 4096}) {
		hits: [60]int
		for _ in 0 ..< 30000 {
			n := zt.dict_random_node(z.sl, budget)
			i, ok := strconv.parse_int(string(zt.node_member(n))[7:])
			check(ok && i >= 0 && i < 60 && n.score == f64(i), "random/fallback preserves exact member-score pairing")
			hits[i] += 1
		}
		for hit in hits {
			check(hit > 350 && hit < 650, "uniform combined-bank rejection and global rank fallback are unbiased")
		}
	}
	for count in ([?]int{1, 20, 21, 59, 60}) {
		out: [dynamic]zt.Item
		zt.random_unique(z, count, &out)
		check(len(out) == count, "random unique strategy boundaries return exact cardinality")
		seen: map[string]bool
		for item in out {
			member := string(item.str)
			score, found := zt.score(z, item.str)
			check(member not_in seen && found && item.score == score, "random unique gathers all ordered Nodes without bank bias or duplicates")
			seen[member] = true
		}
		delete(seen)
		delete(out)
	}
	zt.destroy(z)
	resize_release_all()
}

unit_resize_scan_ranges :: proc() {
	for shrink in ([?]bool{false, true}) {
		z := zt.create_skiplist(512)
		for i in 0 ..< 64 {
			zt.add(z, f64(i), b(fmt.tprintf("stable:%d", i)), {})
		}
		zt.dict_resize(z.sl, z.sl.cap / 2 if shrink else z.sl.cap * 2)
		cursor: u64
		out: [dynamic]zt.Item
		seen: map[string]bool
		pages := 0
		for {
			clear(&out)
			cursor = zt.scan(z, cursor, 1, &out)
			for i := 0; i < len(out); i += 2 {
				member := string(out[i].str)
				score, found := zt.score(z, out[i].str)
				check(found && out[i + 1].score == score, "ZSCAN keeps full member/score pairing across banks")
				seen[member] = true
			}
			pages += 1
			if cursor == 0 {
				break
			}
			zt.add(z, f64(-pages), b("stable:0"), {})
			zt.dict_step(z.sl, 64, 4)
			zt.maintenance_release()
			check(pages < 4096, "quiet/reordering ZSCAN completes without pinning a source")
		}
		check(len(seen) == 64 && z.sl.resize == nil, "ZSCAN returns all continuously present members through grow/shrink/quiet completion")
		resize_recount(z)
		delete(out)
		delete(seen)
		zt.destroy(z)
	}
	for mode in 0 ..< 3 {
		z := zt.create_skiplist(128)
		for i in 0 ..< 128 {
			zt.add(z, f64(i) if mode != 2 else 0, b(fmt.tprintf("range:%03d", i)), {})
		}
		zt.dict_resize(z.sl, z.sl.cap * 2)
		n := 0
		switch mode {
		case 0:
			n = zt.remrange_by_rank(z, 4, 34)
		case 1:
			range := zt.Range_Spec{min = 4, max = 34}
			n = zt.remrange_by_score(z, &range)
		case 2:
			range := zt.Lex_Spec{min = b("range:004"), max = b("range:034")}
			n = zt.remrange_by_lex(z, &range)
		}
		check(n == 31 && zt.length(z) == 97, "all range-removal loops preserve count through migration")
		resize_recount(z)
		for i in 0 ..< 128 {
			_, found := zt.score(z, b(fmt.tprintf("range:%03d", i)))
			check(found == (i < 4 || i > 34), "range removal frees exactly the requested canonical Nodes")
		}
		check(zt.remrange_by_rank(z, 0, -1) == 97 && z.sl.cap == 0, "bulk final removal detaches indexes after ordered unlink")
		resize_recount(z)
		zt.destroy(z)
	}
	resize_release_all()
}

unit_resize_collision :: proc() {
	z := zt.create_skiplist(64)
	members: [40]string
	found, serial := 0, 0
	for found < len(members) {
		member := fmt.tprintf("wrap:%d", serial)
		serial += 1
		if zt.hash_member(b(member)) & u64(z.sl.cap - 1) != u64(z.sl.cap - 1) {
			continue
		}
		members[found] = member
		found += 1
		zt.add(z, 0, b(member), {})
	}
	zt.dict_resize(z.sl, z.sl.cap * 2)
	grant := zt.dict_step(z.sl, 3, 2)
	check(grant.moved == 2 && grant.scanned == 2, "wrapped dictionary cluster respects pointer-move quota")
	zt.del(z, b(members[0]))
	for i in 1 ..< len(members) {
		_, exists := zt.score(z, b(members[i]))
		check(exists, "old-bank tombstones preserve wrapped lookup chains")
	}
	resize_recount(z)
	resize_drain(z.sl)
	resize_recount(z)
	zt.destroy(z)
	resize_release_all()
}

unit_resize_empty_release :: proc() {
	z := zt.create_skiplist(8000)
	members: [8]string
	found, serial := 0, 0
	for found < len(members) {
		member := fmt.tprintf("sparse:%d", serial)
		serial += 1
		home := zt.hash_member(b(member)) & u64(z.sl.cap - 1)
		if home < 4096 || home >= 8192 {
			continue
		}
		members[found] = member
		found += 1
		zt.add(z, 0, b(member), {})
	}
	check(z.sl.cap == 16384, "sparse dictionary owns known128 KiB source")
	zt.dict_resize(z.sl, 32768)
	for member in members {
		resize_change(z, b(member), 0, true)
	}
	check(z.sl.cap == 0 && z.sl.resize == nil && z.sl.length == 0 && z.sl.bytes == 0, "sparse last-member deletion detaches both indexes without scanning")
	mapped, retired, metadata := zt.maintenance_memory()
	check(mapped == 393216 && retired == mapped && metadata >= 176, "known128 KiB source and256 KiB target remain separately retired")
	for remaining := 393216; remaining > 0; remaining -= 4096 {
		check(zt.maintenance_release(4096) == 4096, "sparse empty retirement releases exact page units")
	}
	zt.destroy(z)
	for _ in 0 ..< 40 {
		s := zt.create_skiplist(512)
		zt.add(s, 1, b("one"), {})
		zt.dict_resize(s.sl, 2048)
		resize_drain(s.sl)
		zt.destroy(s)
	}
	mapped, retired, metadata = zt.maintenance_memory()
	check(mapped == 40 * 8192 && retired == mapped, "many small retired dictionaries retain actual physical ownership")
	check(zt.maintenance_release(call_budget = 0) == 0, "zero syscall credit preserves queued mappings")
	check(zt.maintenance_release(deadline_ns = 1) == 8192, "past soft deadline still makes one-call progress")
	check(zt.maintenance_release(call_budget = 3) == 24576, "explicit three-syscall release quota")
	check(zt.maintenance_release() == 16 * 8192, "default sixteen-syscall release quota")
	resize_release_all()
	mapped, retired, metadata = zt.maintenance_memory()
	check(mapped == 0 && retired == 0 && metadata == 0, "retired dictionary bytes and records converge to zero")
}

resize_guard :: proc(name: string) {
	switch name {
	case "negative":
		zt.sl_create(-1)
	case "overflow":
		zt.sl_create(max(int))
	case "capacity":
		zt.slots_alloc(3)
	case "generation":
		ctx := zt.Context{resize_epoch = max(u64)}
		zt.maintenance_clear(&ctx)
	}
}

unit_resize_shrink_refill :: proc() {
	for capacity in ([?]int{8, 16, 32, 64, 128, 256, 512, 1024, 8192}) {
		z := zt.create_skiplist(capacity / 2)
		check(z.sl.cap == capacity, "refill fixture has the intended initial capacity")
		for i in 0 ..< capacity / 8 {
			zt.add(z, f64(i), b(fmt.tprintf("refill:%d", i)), {})
		}
		zt.dict_resize(z.sl, capacity / 2)
		check(z.sl.resize != nil && z.sl.resize.old_count == capacity / 8, "refill starts with a live C-to-C/2 shrink source")
		limit := capacity / 8 * 3
		writes_in_source := 0
		for i in capacity / 8 ..= limit {
			if z.sl.resize != nil && z.sl.cap == capacity / 2 {
				writes_in_source += 1
			}
			resize_change(z, b(fmt.tprintf("refill:%d", i)), f64(i))
			check(z.sl.count <= z.sl.cap / 4 * 3, "ordinary refill insertion preserves assisted headroom")
		}
		check(writes_in_source > 0 && z.sl.count == limit + 1 && z.sl.cap == capacity, "normal insertion crosses destination three-quarter threshold after bounded shrink progress")
		resize_recount(z)
		zt.destroy(z)
	}
	resize_release_all()
}

unit_resize_rng_alloc :: proc() {
	level_after: u32
	for migrated in ([2]bool{true, false}) {
		zt.set_seed(0x77D38AA9)
		z := zt.create_skiplist(96)
		for i in 0 ..< 96 {
			zt.add(z, f64(i), b(fmt.tprintf("rng:%d", i)), {})
		}
		if migrated {
			zt.dict_resize(z.sl, z.sl.cap * 2)
			resize_drain(z.sl)
		}
		zt.add(z, 100, b("next-random-level"), {})
		n := zt.dict_find(z.sl, b("next-random-level"), zt.hash_member(b("next-random-level")))
		if migrated {
			level_after = n.nlevel
		} else {
			check(n.nlevel == level_after, "pure dictionary migration consumes no skiplist RNG state")
		}
		zt.destroy(z)
	}
	z := zt.create_skiplist(16)
	for length in ([?]int{0, 1, 15, 16, 17, 4096}) {
		member := make([]u8, length)
		for &v, i in member {
			v = u8(i % 251)
		}
		zt.add(z, f64(length), member, {})
		n := zt.dict_find(z.sl, member, zt.hash_member(member))
		requested := 32 + int(n.nlevel) * 16 + length
		check(zt.mem_usable_size(n) >= requested && len(zt.node_member(n)) == length, "actual Node allocation honors unchanged header/levels/member boundary")
		fmt.printfln("  Node member=%d levels=%d requested/usable=%d/%d", length, n.nlevel, requested, zt.mem_usable_size(n))
		delete(member)
	}
	resize_recount(z)
	zt.destroy(z)
	resize_release_all()
}

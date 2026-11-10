package main

import "base:runtime"
import "base:sanitizer"
import "core:fmt"
import "core:testing"
import ht "hashtype"
import lb "label"
import ow "owner"
import vt "vsettype"

OWNER_TAIL_TOUCH :: #config(OWNER_TAIL_TOUCH, false)

compact_test_number: u32 = 900_000

compact_test_entry :: proc() -> ^Owner_Entry {
	if len(dbs) == 0 {
		db_init()
	}
	e := new(Owner_Entry, runtime.heap_allocator())
	compact_test_number += 1
	e.number = ow.Owner(compact_test_number)
	return e
}

compact_test_part :: proc(t: ^testing.T, e: ^Owner_Entry, dbi: int) -> ^Db {
	p, ok := owner_part_make(e, dbi, lb.BOTTOM_ID)
	testing.expect(t, ok)
	return owner_db(p)
}

compact_test_put :: proc(db: ^Db, name: string, value: string, at: i64 = 0) {
	e, _ := db_upsert_timed_in(db, owner_test_bytes(name), at)
	entry_assign(e, owner_test_bytes(value))
	entry_set_expire(e, at)
}

compact_test_lane_bound :: proc(t: ^testing.T, db: ^Db) -> bool {
	tab := &db.t[0]
	if tab.region == nil {
		return true
	}
	lanes := table_lanes(tab)
	if lanes >= TABLE_MIN_CAP {
		return true
	}
	ok := lanes == 1 || lanes == 2 || lanes == 4
	ok = ok && tab.live + tab.growth == lanes && tab.tombs == 0 && tab.cap == TABLE_MIN_CAP && tab.groups == 1
	for j in lanes ..< GROUP_SLOTS {
		ok = ok && tab.ctrl[j] == CTRL_EMPTY
	}
	testing.expectf(t, ok, "lane bound broken: lanes %d live %d growth %d tombs %d", lanes, tab.live, tab.growth, tab.tombs)
	return ok
}

compact_test_same_lanes :: proc(t: ^testing.T, a, b: ^Db) -> bool {
	x, y := &a.t[0], &b.t[0]
	ok := db_size_of(a) == db_size_of(b) && a.rehash_idx < 0 && b.rehash_idx < 0
	if x.region == nil || y.region == nil {
		ok = ok && x.region == nil && y.region == nil
		testing.expect(t, ok)
		return ok
	}
	ok = ok && x.cap == y.cap && x.groups == 1 && y.groups == 1 && x.live == y.live
	for j in 0 ..< GROUP_SLOTS {
		ok = ok && x.ctrl[j] == y.ctrl[j]
		if ok && x.ctrl[j] & 0x80 != 0 {
			ok = ok && string(key_bytes(&x.slots[j].key, &a.slab)) == string(key_bytes(&y.slots[j].key, &b.slab))
			va := string(db_view_slot(a, x, j).val)
			vb := string(db_view_slot(b, y, j).val)
			ok = ok && va == vb
		}
	}
	testing.expect(t, ok, "compact and full tables differ lane by lane")
	return ok
}

compact_test_drop_spaces :: proc(e: ^Owner_Entry) {
	for e.keyspace.space != nil {
		owner_space_drop(e.keyspace.space)
	}
}

@(test)
keyspace_owners_partition_core_ends_the_allocation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	e := compact_test_entry()
	saved := owner_compact
	defer owner_compact = saved
	owner_compact = true
	_ = sanitizer.address_is_poisoned
	base_structs := owner_struct_bytes - owner_global_bytes
	d := compact_test_part(t, e, 0)
	p := owner_part_of(d)
	testing.expect(t, owner_db(p) == d)
	testing.expect_value(t, int(uintptr(d) - uintptr(p)), int(OWNER_HEAD_BYTES))
	testing.expect_value(t, int(uintptr(&d.slab) - uintptr(p)), size_of(Owner_Part))
	testing.expect(t, d.hreg == nil && d.sctx == nil && d.zctx == nil)
	testing.expect_value(t, d.role, DB_ROLE_HEAP | DB_ROLE_OWNER)
	when .Address in ODIN_SANITIZER_FLAGS {
		testing.expect(t, sanitizer.address_region_is_poisoned(rawptr(p), size_of(Owner_Part)) == nil)
		testing.expect(t, sanitizer.address_is_poisoned(rawptr(&d.slab)))
	}
	when OWNER_TAIL_TOUCH {
		fmt.println("touching the absent tail of an owner partition")
		testing.expect_value(t, d.slab.live, 0)
	}
	owner_touch(d)
	compact_test_put(d, "k", "v")
	owner_settle()
	testing.expect_value(t, table_lanes(&d.t[0]), 1)
	testing.expect_value(t, d.t[0].size, GROUP_SLOTS + SLOT_BYTES)
	owner_touch(d)
	found, _ := db_remove_in(d, owner_test_bytes("k"))
	testing.expect(t, found)
	owner_settle()
	compact_test_drop_spaces(e)
	testing.expect_value(t, e.keyspace.structs, 0)
	testing.expect_value(t, e.keyspace.used, 0)
	testing.expect_value(t, e.keyspace.parts, 0)
	testing.expect_value(t, owner_struct_bytes - owner_global_bytes, base_structs)
	free(e, runtime.heap_allocator())
}

@(test)
keyspace_owners_short_table_ladder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := owner_compact
	defer owner_compact = saved
	owner_compact = true
	db := owner_test_heap_db()
	defer owner_test_heap_db_free(db)
	base := storage_table_allocated()
	want := []int{1, 2, 4, 4, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 32}
	for lanes, i in want {
		compact_test_put(db, fmt.tprintf("key-number-%d", i), "v")
		testing.expect_value(t, table_lanes(&db.t[0]), lanes)
		size := GROUP_SLOTS + lanes * SLOT_BYTES if lanes < TABLE_MIN_CAP else table_heap_size(lanes)
		testing.expect_value(t, db.t[0].size, size)
		testing.expect_value(t, storage_table_allocated() - base, size)
		testing.expect_value(t, db.t[0].warm_at, TABLE_HEAP_WARM)
		compact_test_lane_bound(t, db)
		for k in 0 ..= i {
			testing.expect(t, owner_test_found(db, fmt.tprintf("key-number-%d", k)))
		}
	}
	mapped := table_alloc_owner(db, 2048)
	testing.expect_value(t, mapped.warm_at, TABLE_COLD_WARM)
	testing.expect_value(t, table_lanes(&mapped), 2048)
	table_detach(&mapped)
	heap := table_alloc_owner(db, TABLE_HEAP_MAX_CAP)
	testing.expect_value(t, heap.warm_at, TABLE_HEAP_WARM)
	table_detach(&heap)
	owner_compact = false
	full := owner_test_heap_db()
	compact_test_put(full, "one", "v")
	testing.expect_value(t, table_lanes(&full.t[0]), TABLE_MIN_CAP)
	testing.expect_value(t, full.t[0].size, table_heap_size(TABLE_MIN_CAP))
	owner_test_heap_db_free(full)
	owner_compact = true
}

@(test)
keyspace_owners_short_tables_match_the_full_form_lane_by_lane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := owner_compact
	defer owner_compact = saved
	a := owner_test_heap_db()
	defer owner_test_heap_db_free(a)
	b := owner_test_heap_db()
	defer owner_test_heap_db_free(b)
	names := []string{"a", "bb", "key-c", "long-key-d", "e", "f-long-name", "g", "hh", "i-name", "jj"}
	values := []string{"v", "1234567", "value-longer-than-inline", "", "42"}
	state: u64 = 0x2545_F491_4F6C_DD1D
	next :: proc(s: ^u64) -> int {
		s^ = s^ * 6364136223846793005 + 1442695040888963407
		return int(s^ >> 33)
	}
	compactions := 0
	shapes: [5]int
	for step in 0 ..< 6000 {
		name := names[next(&state) % len(names)]
		op := next(&state) % 10
		value := values[next(&state) % len(values)]
		for side in 0 ..< 2 {
			owner_compact = side == 0
			db := a if side == 0 else b
			switch {
			case op < 5:
				compact_test_put(db, name, value)
			case op < 6:
				compact_test_put(db, name, value, 4_000_000_000_000)
			case:
				db_remove_in(db, owner_test_bytes(name))
			}
		}
		owner_compact = true
		if step % 7 == 0 {
			before := a.t[0].size
			db_table_compact(a)
			if a.t[0].size != before {
				compactions += 1
			}
		}
		switch table_lanes(&a.t[0]) {
		case 1: shapes[0] += 1
		case 2: shapes[1] += 1
		case 4: shapes[2] += 1
		case 16: shapes[3] += 1
		case: shapes[4] += 1
		}
		if !compact_test_lane_bound(t, a) || !compact_test_same_lanes(t, a, b) {
			testing.expectf(t, false, "first difference at step %d", step)
			return
		}
	}
	testing.expect(t, compactions > 0)
	testing.expect(t, shapes[0] > 0 && shapes[1] > 0 && shapes[2] > 0 && shapes[3] > 0)
}

@(test)
keyspace_owners_compaction_copies_lanes_and_settles_bytes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := owner_compact
	defer owner_compact = saved
	owner_compact = true
	e := compact_test_entry()
	d := compact_test_part(t, e, 0)
	od := &owner_dbs[0]
	owner_touch(d)
	for i in 0 ..< 5 {
		compact_test_put(d, fmt.tprintf("n%d", i), "v")
	}
	owner_settle()
	testing.expect_value(t, table_lanes(&d.t[0]), TABLE_MIN_CAP)
	used := e.keyspace.used
	tables := od.tables
	total := owner_bytes_total
	owner_touch(d)
	for i in 2 ..< 5 {
		db_remove_in(d, owner_test_bytes(fmt.tprintf("n%d", i)))
	}
	owner_settle()
	short := GROUP_SLOTS + TABLE_SHORT_SHRINK * SLOT_BYTES
	saved_bytes := table_heap_size(TABLE_MIN_CAP) - short
	testing.expect_value(t, table_lanes(&d.t[0]), TABLE_SHORT_SHRINK)
	testing.expect_value(t, d.t[0].size, short)
	testing.expect_value(t, e.keyspace.used, used - saved_bytes)
	testing.expect_value(t, od.tables, tables - saved_bytes)
	testing.expect_value(t, owner_bytes_total, total - saved_bytes)
	testing.expect_value(t, owner_used_live(e) - ow.table_entry_bytes(&owner_table, e), e.keyspace.used)
	testing.expect(t, owner_test_found(d, "n0") && owner_test_found(d, "n1"))
	testing.expect_value(t, d.t[0].growth, TABLE_SHORT_SHRINK - 2)
	owner_touch(d)
	db_remove_in(d, owner_test_bytes("n0"))
	compact_test_put(d, "z", "v")
	testing.expect_value(t, string(key_bytes(&d.t[0].slots[0].key, &d.slab)), "z")
	compact_test_put(d, "y", "v")
	compact_test_put(d, "x", "v")
	testing.expect_value(t, table_lanes(&d.t[0]), TABLE_SHORT_SHRINK)
	compact_test_put(d, "w", "v")
	testing.expect_value(t, table_lanes(&d.t[0]), TABLE_MIN_CAP)
	owner_settle()
	owner_touch(d)
	for name in ([]string{"n1", "z", "y", "x", "w"}) {
		found, _ := db_remove_in(d, owner_test_bytes(name))
		testing.expect(t, found)
	}
	owner_settle()
	compact_test_drop_spaces(e)
	testing.expect_value(t, e.keyspace.used, 0)
	testing.expect_value(t, e.keyspace.structs, 0)
	free(e, runtime.heap_allocator())
}

@(test)
keyspace_owners_contexts_appear_with_the_first_object :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := owner_compact
	defer owner_compact = saved
	owner_compact = true
	e := compact_test_entry()
	d := compact_test_part(t, e, 0)
	owner_touch(d)
	compact_test_put(d, "plain", "v")
	testing.expect(t, d.hreg == nil)
	before := e.keyspace.structs
	h := ht.create()
	h.acct = ht.memory_usage(h)
	he, _ := db_upsert_in(d, owner_test_bytes("hash"))
	entry_object_attach(he, h, .Hash, .Listpack, h.acct)
	testing.expect(t, d.hreg != nil && d.sctx != nil && d.zctx != nil)
	testing.expect(t, d.hreg.owner == rawptr(d) && d.sctx.owner == rawptr(d) && d.zctx.owner == rawptr(d))
	testing.expect_value(t, e.keyspace.structs - before, size_of(Owner_Ctx))
	first := d.hreg
	h2 := ht.create()
	h2.acct = ht.memory_usage(h2)
	he2, _ := db_upsert_in(d, owner_test_bytes("hash2"))
	entry_object_attach(he2, h2, .Hash, .Listpack, h2.acct)
	testing.expect(t, d.hreg == first)
	testing.expect_value(t, e.keyspace.structs - before, size_of(Owner_Ctx))
	other := compact_test_part(t, e, 1)
	owner_touch(other)
	testing.expect(t, other.hreg == nil)
	moving := e.keyspace.structs
	testing.expect(t, db_move(d, other, owner_test_bytes("hash")))
	testing.expect(t, other.hreg != nil && other.hreg != d.hreg)
	testing.expect_value(t, e.keyspace.structs - moving, size_of(Owner_Ctx))
	testing.expect(t, db_find_in(other, owner_test_bytes("hash")) != nil)
	for name in ([]string{"plain", "hash2"}) {
		found, _ := db_remove_in(d, owner_test_bytes(name))
		testing.expect(t, found)
	}
	found, _ := db_remove_in(other, owner_test_bytes("hash"))
	testing.expect(t, found)
	owner_settle()
	compact_test_drop_spaces(e)
	testing.expect_value(t, e.keyspace.structs, 0)
	testing.expect_value(t, e.keyspace.used, 0)
	owner_compact = false
	eager := compact_test_part(t, e, 0)
	testing.expect(t, eager.hreg != nil && eager.sctx != nil && eager.zctx != nil)
	owner_touch(eager)
	owner_settle()
	compact_test_drop_spaces(e)
	testing.expect_value(t, e.keyspace.structs, 0)
	free(e, runtime.heap_allocator())
}

@(test)
keyspace_owners_table_walkers_stay_inside_short_tables :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := owner_compact
	saved_now := srv.now_ms
	saved_cur := db_cur
	saved_child := pst.in_child
	defer {
		owner_compact = saved
		srv.now_ms = saved_now
		db_cur = saved_cur
		pst.in_child = saved_child
	}
	owner_compact = true
	for count in 1 ..= 4 {
		for lazy in ([]bool{false, true}) {
			for tries := 0; dead_len > 0 && tries < 64; tries += 1 {
				db_tick()
			}
			db := owner_test_heap_db()
			srv.now_ms = 1_000_000
			base := storage_table_allocated()
			names := []string{"a", "walker-long-key-1", "walker-timed-2", "walker-hash-3"}
			for i in 0 ..< count {
				switch i {
				case 0:
					compact_test_put(db, names[i], "v")
				case 1:
					compact_test_put(db, names[i], "a value that is longer than the inline form")
				case 2:
					compact_test_put(db, names[i], "timed", 2_000_000)
				case 3:
					h := ht.create()
					h.acct = ht.memory_usage(h)
					he, _ := db_upsert_in(db, owner_test_bytes(names[i]))
					entry_object_attach(he, h, .Hash, .Listpack, h.acct)
				}
			}
			want := 1 if count == 1 else 2 if count == 2 else 4
			testing.expect_value(t, table_lanes(&db.t[0]), want)
			for i in 0 ..< count {
				testing.expect(t, db_find_in(db, owner_test_bytes(names[i])) != nil)
			}
			testing.expect(t, db_find_in(db, owner_test_bytes("missing")) == nil)
			testing.expect(t, db_find_in(db, owner_test_bytes("missing-long-name")) == nil)
			again, created := db_upsert_in(db, owner_test_bytes(names[0]))
			testing.expect(t, !created)
			entry_assign(again, owner_test_bytes("w"))
			db_cur = db
			db_keys(owner_test_bytes("*"), true)
			testing.expect_value(t, len(key_scratch), count)
			db_keys(owner_test_bytes("walker*"), false)
			testing.expect_value(t, len(key_scratch), count - 1)
			cursor := db_scan(0, 10, nil, false)
			testing.expect_value(t, cursor, 0)
			testing.expect_value(t, len(key_scratch), count)
			_, ok := db_random_key()
			testing.expect(t, ok)
			_, _, sampled := db_sample_key(db)
			testing.expect(t, sampled)
			picks: [16]Evict_Sample
			testing.expect_value(t, db_evict_sample(db, picks[:], false, .Lru), count)
			testing.expect_value(t, db_evict_sample(db, picks[:], false, .Lfu), count)
			testing.expect_value(t, db_evict_sample(db, picks[:], true, .Ttl), 1 if count >= 3 else 0)
			sets := make([dynamic]vt.Vset, context.temp_allocator)
			owner_presences(db, &sets)
			testing.expect_value(t, len(sets), 0)
			db_cur = saved_cur
			srv.now_ms = 3_000_000
			db_expire_scan(db, now_ns() + 1_000_000_000)
			testing.expect_value(t, db_size_of(db), count - 1 if count >= 3 else count)
			compact_test_lane_bound(t, db)
			pst.in_child = lazy
			db_flush_in(db, lazy)
			pst.in_child = saved_child
			for tries := 0; dead_len > 0 && tries < 64; tries += 1 {
				db_tick()
			}
			testing.expect_value(t, dead_len, 0)
			testing.expect_value(t, storage_table_allocated(), base)
			owner_test_heap_db_free(db)
		}
	}
}

@(test)
keyspace_owners_bytes_ignore_work_list_membership :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := owner_compact
	saved_now := srv.now_ms
	defer {
		owner_compact = saved
		srv.now_ms = saved_now
	}
	srv.now_ms = 1_000_000
	for compact in ([]bool{true, false}) {
		owner_compact = compact
		e := compact_test_entry()
		base_mem := mem_used()
		base_global := owner_global_bytes
		d := compact_test_part(t, e, 0)
		p := owner_part_of(d)
		owner_touch(d)
		compact_test_put(d, "k", "v")
		compact_test_put(d, "timed", "v", 4_000_000_000_000)
		owner_settle()
		testing.expect(t, p.active[.Expire] != 0)
		testing.expect(t, p.sample[.Expires] != 0)
		owner_touch(d)
		found, _ := db_remove_in(d, owner_test_bytes("timed"))
		testing.expect(t, found)
		owner_settle()
		testing.expect(t, p.active[.Expire] != 0)
		used := e.keyspace.used
		live := owner_used_live(e)
		owner_active_expire(now_ns() + 1_000_000_000)
		testing.expect(t, p.active[.Expire] == 0)
		testing.expect_value(t, e.keyspace.used, used)
		testing.expect_value(t, owner_used_live(e), live)
		owner_active_add(p, .Rehash)
		owner_active_drop(p, .Rehash)
		owner_sampler_remove(p, .Keys)
		testing.expect_value(t, e.keyspace.used, used)
		owner_sampler_note(p, .Keys)
		testing.expect_value(t, e.keyspace.used, used)
		testing.expect_value(t, mem_used() - base_mem, e.keyspace.used + (owner_global_bytes - base_global))
		owner_touch(d)
		found, _ = db_remove_in(d, owner_test_bytes("k"))
		testing.expect(t, found)
		owner_settle()
		testing.expect_value(t, mem_used() - base_mem, e.keyspace.used + (owner_global_bytes - base_global))
		compact_test_drop_spaces(e)
		testing.expect_value(t, e.keyspace.used, 0)
		testing.expect_value(t, mem_used() - base_mem, owner_global_bytes - base_global)
		free(e, runtime.heap_allocator())
	}
}

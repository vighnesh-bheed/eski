package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import st "settype"
import zt "zsettype"
import ht "hashtype"
import lp "listpack"

VERSION :: "test"

checks: int
storage_test_worker_pause: i32
storage_test_worker_entered: i32

storage_test_worker_gate :: proc "contextless" () {
	if intrinsics.atomic_load_explicit(&storage_test_worker_pause, .Acquire) == 0 {
		return
	}
	intrinsics.atomic_store_explicit(&storage_test_worker_entered, 1, .Release)
	deadline := now_ns() + 5_000_000_000
	for intrinsics.atomic_load_explicit(&storage_test_worker_pause, .Acquire) != 0 {
		if now_ns() >= deadline {
			store_fatal("storage test worker barrier timed out")
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
}

check :: proc(ok: bool, name: string, loc := #caller_location) {
	checks += 1
	if !ok {
		fmt.eprintf("FAIL %s (%s:%d)\n", name, loc.file_path, loc.line)
		os.exit(2)
	}
}

settle :: proc() {
	for _ in 0 ..< 10000 {
		db_tick()
		if !lazyfree_jobs_pending() && dead_len == 0 && graveyard_len == 0 && store_rehashing == 0 && !ht.maintenance_pending() && !st.maintenance_pending() && !zt.maintenance_pending() && !slab_reclaim_pending() {
			return
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(false, "pending ownership settles")
}

audit :: proc() {
	settle()
	m := mem_storage()
	tables, virtual, writable, live, heap, metadata := 0, 0, 0, 0, 0, 0
	for &d in dbs {
		tables += d.t[0].size + d.t[1].size + d.next.size
		heap += d.heap_bytes
		if d.slab.base != nil {
			virtual += SLAB_RESERVE
			writable += d.slab.committed
			live += d.slab.live
			metadata += slab_metadata_bytes(&d.slab)
		}
	}
	check(m.table_allocated == tables && m.table_mapped == tables, "owned/mapped table recount")
	check(m.slab_virtual == virtual && m.slab_writable == writable, "slab mapping recount")
	check(m.slab_live == live && db_used_memory == live + heap, "live payload recount")
	check(m.slab_capacity == m.slab_live + m.slab_free + m.slab_bump, "class capacity conservation")
	check(m.slab_reusable == m.slab_free + m.slab_bump, "reusable capacity conservation")
	check(m.slab_writable == m.slab_sentinel + m.slab_capacity + m.slab_tail + m.slab_empty + m.slab_ahead, "writable capacity conservation includes empty pools")
	check(m.metadata_owned == metadata && m.metadata_writable == metadata && m.metadata_virtual == virtual / SLAB_RESERVE * SLAB_METADATA_RESERVE && m.metadata_retired == 0, "metadata ownership and mapping recount")
	check(m.slab_empty == m.slab_dirty + m.slab_clean, "dirty and clean pools partition empty runs")
	check(m.dead_payload == 0 && m.lazy_payload == 0 && m.lazy_slab_live == 0, "pending payload ownership drained")
	check(m.table_retired == 0 && m.slab_retired == 0, "retired mappings drained")
	check(mem_used() == mem_startup + db_used_memory + tables + metadata + ps_memory + conn_mem + tx_mem_total + mem_aof_buffer(), "allocated memory recount includes only owned metadata")
}

put :: proc(key, value: string) {
	e, _ := db_upsert(transmute([]u8)key)
	entry_assign(e, transmute([]u8)value)
}

storage_clear :: proc() {
	maxmemory_bytes = 0
	db_flush_all(false)
	settle()
	audit()
	check(storage_table_allocated() == 0 && storage_table_mapped == 0, "flush releases every table")
	check(storage_slab_virtual == 0 && storage_slab_writable == 0, "flush releases every slab")
	check(storage_metadata_owned == 0 && storage_metadata_virtual == 0 && storage_metadata_writable == 0 && !slab_reclaim_pending(), "flush releases every descriptor and pending owner")
}

inline_tables :: proc() {
	put("a", "b")
	check(mem_db_overhead(db_cur) == TABLE_PAGE, "one inline key owns a complete table page")
	check(db_used_memory == 0 && mem_used() == mem_startup + TABLE_PAGE, "inline key charges allocated table only")
	audit()
	db_swap(0, 1)
	check(db_size_of(&dbs[0]) == 0 && db_size_of(&dbs[1]) == 1, "swap transfers table ownership")
	audit()
	db_cur = &dbs[1]
	db_remove(transmute([]u8)string("a"))
	check(storage_table_allocated() == TABLE_PAGE, "empty allocated table remains charged")
	db_flush_in(db_cur, false)
	check(storage_table_allocated() == 0, "flush releases empty minimum table")
	db_cur = &dbs[0]
	for i in 0 ..< 8000 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "k%d", i), "v")
		if db_cur.rehash_idx >= 0 {
			check(mem_db_overhead(db_cur) == db_cur.t[0].size + db_cur.t[1].size + db_cur.next.size, "rehash capacity charged once")
		}
	}
	audit()
	db_prepare_next(db_cur)
	check(db_cur.next.region != nil, "speculative table prepared")
	next := db_cur.next.size
	before := mem_used()
	maxmemory_bytes = u64(before + 1024)
	config_apply_maxmemory()
	check(db_cur.next.region == nil && mem_used() == before - next, "memory limit releases speculative table")
	storage_clear()
}

slab_churn :: proc() {
	value: [96]u8
	for &b, i in value {
		b = u8(i + 1)
	}
	for i in 0 ..< 2000 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "long-key-%d", i), string(value[:]))
	}
	audit()
	before := mem_storage()
	for i in 0 ..< 2000 {
		buf: [32]u8
		db_remove(transmute([]u8)fmt.bprintf(buf[:], "long-key-%d", i))
	}
	freed := mem_storage()
	check(freed.slab_live == 0 && freed.slab_writable >= before.slab_writable, "free payload keeps writable mapping outside allocation charge")
	check(freed.slab_empty > 0 && freed.slab_capacity == 0 && freed.slab_reusable == 0 && slab_zero_slabs == 1, "all-empty runs leave class ownership and queue one owner")
	for i in 0 ..< 2000 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "long-key-%d", i), string(value[:]))
	}
	audit()
	check(mem_storage().slab_capacity == before.slab_capacity, "same-class reuse does not assign extra runs")
	check(slab_zero_slabs == 0, "writes before maintenance cancel whole-owner retirement")
	storage_clear()
}

slab_expected :: proc() {
	first := slab_alloc(&db_cur.slab, 17)
	for _ in 1 ..< 2731 {
		slab_alloc(&db_cur.slab, 17)
	}
	for _ in 0 ..< 3 {
		slab_alloc(&db_cur.slab, 33)
	}
	for _ in 0 ..< 16 {
		slab_alloc(&db_cur.slab, 4096)
	}
	m := mem_storage()
	check(m.slab_capacity == 262096 && m.slab_live == 131200, "known four-run class capacity and rounded live bytes")
	check(m.slab_bump == 130896 && m.slab_free == 0 && m.slab_tail == 48, "known bump bytes and tails for 24/40/4096 classes")
	check(db_cur.slab.top == 327680 && m.slab_sentinel == 65536 && m.slab_writable == SLAB_COMMIT_STEP, "known assigned runs, sentinel and commit step")
	slab_free(&db_cur.slab, first, 17)
	m = mem_storage()
	check(m.slab_free == 24 && m.slab_bump == 130896 && m.slab_live == 131176, "known free-list cell does not change bump capacity")
	check(slab_alloc(&db_cur.slab, 24) == first && mem_storage().slab_free == 0, "known free-list cell reused")
	storage_clear()
}

deferred :: proc() {
	value: [5000]u8
	for _ in 0 ..< DEAD_MAX + 2 {
		for i in 0 ..< 100 {
			buf: [32]u8
			put(fmt.bprintf(buf[:], "heap-%d", i), string(value[:]))
		}
		heap := db_cur.heap_bytes
		before := storage_dead_payload
		db_flush_in(db_cur, false)
		check(storage_dead_payload >= before && storage_dead_payload <= before + heap, "deferred heap ownership transferred or freed by bounded queue fallback")
		check(db_used_memory == 0, "flushed heap no longer owned by database")
	}
	check(dead_len == DEAD_MAX && storage_dead_payload > 0, "dead queue capacity and payload visible")
	audit()
	for i in 0 ..< 1000 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "heap-%d", i), string(value[:]))
	}
	db_flush_in(db_cur, true)
	audit()
	s := st.create(transmute([]u8)string("member0"), 1000)
	for i in 0 ..< 1000 {
		buf: [32]u8
		st.add(s, transmute([]u8)fmt.bprintf(buf[:], "member%d", i))
	}
	s.acct = st.memory_usage(s)
	e, _ := db_upsert(transmute([]u8)string("large-set"))
	entry_object_attach(e, s, .Set, .Hashtable, s.acct)
	saved := lazy_set(true)
	db_remove(transmute([]u8)string("large-set"))
	lazy_mode = saved
	audit()
	storage_clear()
}

retired :: proc() {
	t := table_alloc(131072)
	size := t.size
	table_detach(&t)
	check(storage_table_allocated() == 0 && storage_table_mapped == size, "retired mapping is free allocation but remains mapped")
	check(storage_retired[.Table] == size, "retired mapping size recorded")
	storage_test_release_chunk()
	check(storage_table_mapped == size - RELEASE_CHUNK && storage_retired[.Table] == size - RELEASE_CHUNK, "partial unmap removes only released bytes")
	audit()
}

storage_command :: proc(handler: Command_Proc, values: ..string) {
	c := Conn{db = db_cur, resp = 2, wbuf = mem_alloc(WBUF_INIT), wcap = WBUF_INIT}
	defer mem_free(c.wbuf)
	args := make([][]u8, len(values))
	defer delete(args)
	for value, i in values {
		args[i] = transmute([]u8)value
	}
	handler(&c, args)
	check(c.wlen > 0 && c.wbuf[0] != '-', "composite fixture command succeeds")
}

composite_dead :: proc() {
	value: [5000]u8
	db_cur.t[0] = table_alloc(131072)
	for i in 0 ..< 100 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "heap-%d", i), string(value[:]))
	}
	first_half := 0
	for i in 0 ..< DEAD_SCAN_SLOTS {
		if db_cur.t[0].ctrl[i] & 0x80 != 0 {
			first_half += 1
		}
	}
	db_flush_in(db_cur, false)
	check(storage_dead_payload == 501600, "known 100 heap payloads include 16-byte wrappers")
	storage_test_dead_chunk()
	check(storage_dead_payload == (100 - first_half) * 5016, "partial dead scan frees exactly the known occupied heap payloads")
	audit()
	storage_clear()
	db_cur.t[0] = table_alloc(131072)
	storage_command(cmd_hset, "HSET", "hash", "field", "value")
	storage_command(cmd_rpush, "RPUSH", "list", "value")
	storage_command(cmd_zadd, "ZADD", "zset", "1", "value")
	storage_command(cmd_xadd, "XADD", "stream", "*", "field", "value")
	heap := db_cur.heap_bytes
	db_flush_in(db_cur, false)
	check(dead_len == 1 && storage_dead_payload == heap, "all composite types transfer recorded allocation ownership")
	storage_test_dead_chunk()
	check(dead_len == 1 && storage_dead_payload >= 0 && storage_dead_payload <= heap, "partial dead scan keeps remaining allocation ownership")
	audit()
	storage_clear()
}

eviction :: proc() {
	for i in 0 ..< 4000 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "%d", i), "v")
	}
	maxmemory_policy = .Allkeys_Random
	maxmemory_bytes = u64(mem_startup + TABLE_PAGE * 2)
	config_apply_maxmemory()
	for _ in 0 ..< 100 {
		result := perform_evictions()
		if result == .Ok {
			break
		}
		db_tick()
	}
	over, _ := memory_state_over()
	check(!over, "inline-only eviction makes progress through shrink")
	check(db_size() < 4000, "inline keys evicted to release capacity")
	storage_clear()
	maxmemory_policy = .Noeviction
}

fork_ownership :: proc() {
	for i in 0 ..< 100 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "fork-key-%d", i), "fork-value-kept")
	}
	audit()
	before := mem_storage()
	pid, err := linux.fork()
	check(err == .NONE, "fork storage snapshot")
	if pid == 0 {
		db_flush_all(false)
		settle()
		linux.exit_group(0)
	}
	status: u32
	_, werr := linux.waitpid(pid, &status, {}, nil)
	check(werr == .NONE && status == 0, "child releases only child-private mappings")
	audit()
	after := mem_storage()
	check(before.table_allocated == after.table_allocated && before.slab_virtual == after.slab_virtual && before.slab_live == after.slab_live && db_size() == 100, "fork child does not decrement parent ownership")
	storage_clear()
}

fork_pending_worker :: proc() {
	value: [5000]u8
	for &v, i in value {
		v = u8(i % 251 + 1)
	}
	for i in 0 ..< 100 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "pending-%d", i), string(value[:]))
	}
	pending_hash := hash_fixture("pending-hash")
	pending_blob := pending_hash.table.resize.old_slots
	e := db_find(transmute([]u8)string("pending-0"))
	borrowed := e.val
	payload := db_cur.heap_bytes + db_cur.slab.live
	old_table := mem_db_overhead(db_cur)
	freed := lazyfreed_objects()
	intrinsics.atomic_store_explicit(&storage_test_worker_entered, 0, .Release)
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 1, .Release)
	db_flush_in(db_cur, true)
	deadline := now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 0 && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 1, "actual worker reaches the unlocked pre-destruction barrier")
	check(lazyfree_jobs_pending() && lazyfree_pending_objects() == 101 && lazyfree_pending_bytes() == payload, "real async flush publishes pending object and payload ownership before fork")
	put("live-new", "snapshot")
	before := mem_storage()
	check(before.table_allocated == old_table + mem_db_overhead(db_cur), "pending worker retains its actual table allocation")
	check(before.lazy_payload == payload && before.lazy_slab_live > 0 && before.slab_writable > db_cur.slab.committed, "pending worker retains slab and heap ownership")
	pipes: [2]linux.Fd
	check(linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK}) == .NONE, "create bounded parent-child ordering pipe")
	cfg.dbfilename = "pending-worker.rdb"
	pid, err := linux.fork()
	check(err == .NONE, "fork while the real worker job is pending")
	if pid == 0 {
		linux.close(pipes[1])
		token: [1]u8
		got := false
		child_deadline := now_ns() + 5_000_000_000
		for now_ns() < child_deadline {
			n, rerr := linux.read(pipes[0], token[:])
			if n == 1 {
				got = true
				break
			}
			check(rerr == .EAGAIN || rerr == .EINTR, "child pipe remains valid before parent cleanup")
			ts := linux.Time_Spec{time_nsec = 100_000}
			linux.nanosleep(&ts, nil)
		}
		check(got && token[0] == 1, "child observes snapshot only after parent worker cleanup")
		linux.close(pipes[0])
		snapshot := mem_storage()
		check(snapshot.table_allocated == before.table_allocated && snapshot.table_mapped == before.table_mapped && snapshot.slab_virtual == before.slab_virtual && snapshot.slab_writable == before.slab_writable, "child retains its copied pending mapping counters")
		check(snapshot.metadata_owned == before.metadata_owned && snapshot.metadata_virtual == before.metadata_virtual && snapshot.metadata_writable == before.metadata_writable && snapshot.metadata_retired == before.metadata_retired, "parent old-worker release preserves the child metadata ownership snapshot")
		check(snapshot.lazy_payload == payload && lazyfree_pending_objects() == 101 && lazyfreed_objects() == freed, "parent cleanup cannot mutate child pending counters")
		check(string(borrowed) == string(value[:]), "parent heap destruction cannot invalidate child snapshot bytes")
		check(pending_hash.table.resize.old_slots == pending_blob && pending_hash.table.resize.reg.resize_epoch != pending_hash.table.resize.epoch, "child pending hash retains cancelled generation and mapped source")
		v, _, found := ht.get_raw(pending_hash, transmute([]u8)string("field:255"))
		check(found && string(v.str) == "value\x00suffix", "parent worker cannot invalidate child pending hash banks")
		check(db_size() == 1 && string(db_find(transmute([]u8)string("live-new")).val) == "snapshot", "child live keyspace excludes the detached pending database")
		persist_child_setup()
		check(persist_rdb_save(), "child persists live keyspace with pending worker snapshot")
		linux.exit_group(0)
	}
	linux.close(pipes[0])
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 0, .Release)
	settle()
	check(lazyfree_pending_bytes() == 0 && lazyfree_pending_objects() == 0 && lazyfreed_objects() == freed + 101, "parent real worker releases pending payload exactly once")
	check(storage_table_allocated() == before.table_allocated - old_table, "parent real worker releases pending table exactly once")
	put("after-fork-only", "parent")
	token := [1]u8{1}
	n, werr := linux.write(pipes[1], token[:])
	check(n == 1 && werr == .NONE, "parent signals completed cleanup to child")
	linux.close(pipes[1])
	deadline = now_ns() + 5_000_000_000
	status: u32
	done := false
	for now_ns() < deadline {
		got, waiterr := linux.waitpid(pid, &status, {.WNOHANG}, nil)
		if waiterr != .NONE {
			check(false, "poll pending-worker child completion")
		}
		if got == pid {
			done = true
			break
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	if !done {
		linux.kill(pid, .SIGKILL)
		linux.waitpid(pid, &status, {}, nil)
	}
	check(done && status == 0, "pending-worker fork child completes within its bounded deadline")
	audit()
	check(db_size() == 2 && lazyfreed_objects() == freed + 101, "child persistence and exit leave parent cleanup unchanged")
	storage_clear()
	check(persist_rdb_load(false, false) == .Ok, "load pending-worker child snapshot")
	check(db_size() == 1 && db_find(transmute([]u8)string("after-fork-only")) == nil && string(db_find(transmute([]u8)string("live-new")).val) == "snapshot", "saved child snapshot contains only the pre-fork live keyspace")
	audit()
	storage_clear()
}
zset_fork_pending_worker :: proc() {
	value: [5000]u8
	for &v, i in value {
		v = u8(i % 251 + 1)
	}
	for i in 0 ..< 100 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "pending-%d", i), string(value[:]))
	}
	pending_zset := zset_fixture("pending-zset")
	storage_command(cmd_zadd, "ZADD", "pending-zset", "2048", "pending\x00member")
	pending_slots := pending_zset.sl.resize.old_slots
	e := db_find(transmute([]u8)string("pending-0"))
	borrowed := e.val
	payload := db_cur.heap_bytes + db_cur.slab.live
	old_table := mem_db_overhead(db_cur)
	freed := lazyfreed_objects()
	intrinsics.atomic_store_explicit(&storage_test_worker_entered, 0, .Release)
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 1, .Release)
	db_flush_in(db_cur, true)
	deadline := now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 0 && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 1, "actual worker reaches the unlocked pre-destruction barrier")
	check(lazyfree_jobs_pending() && lazyfree_pending_objects() == 101 && lazyfree_pending_bytes() == payload, "real async flush publishes pending object and payload ownership before fork")
	put("live-new", "snapshot")
	before := mem_storage()
	zset_mapped_before, zset_retired_before, _ := zt.maintenance_memory()
	check(before.table_allocated == old_table + mem_db_overhead(db_cur), "pending worker retains its actual table allocation")
	check(before.lazy_payload == payload && before.lazy_slab_live > 0 && before.slab_writable > db_cur.slab.committed, "pending worker retains slab and heap ownership")
	pipes: [2]linux.Fd
	check(linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK}) == .NONE, "create bounded parent-child ordering pipe")
	cfg.dbfilename = "pending-zset-worker.rdb"
	pid, err := linux.fork()
	check(err == .NONE, "fork while the real worker job is pending")
	if pid == 0 {
		linux.close(pipes[1])
		token: [1]u8
		got := false
		child_deadline := now_ns() + 5_000_000_000
		for now_ns() < child_deadline {
			n, rerr := linux.read(pipes[0], token[:])
			if n == 1 {
				got = true
				break
			}
			check(rerr == .EAGAIN || rerr == .EINTR, "child pipe remains valid before parent cleanup")
			ts := linux.Time_Spec{time_nsec = 100_000}
			linux.nanosleep(&ts, nil)
		}
		check(got && token[0] == 1, "child observes snapshot only after parent worker cleanup")
		linux.close(pipes[0])
		snapshot := mem_storage()
		child_mapped, child_retired, _ := zt.maintenance_memory()
		check(child_mapped == zset_mapped_before && child_retired == zset_retired_before, "child retains its cancelled Zset mapping snapshot after parent cleanup")
		check(snapshot.table_allocated == before.table_allocated && snapshot.table_mapped == before.table_mapped && snapshot.slab_virtual == before.slab_virtual && snapshot.slab_writable == before.slab_writable, "child retains its copied pending mapping counters")
		check(snapshot.metadata_owned == before.metadata_owned && snapshot.metadata_virtual == before.metadata_virtual && snapshot.metadata_writable == before.metadata_writable && snapshot.metadata_retired == before.metadata_retired, "parent old-worker release preserves the child metadata ownership snapshot")
		check(snapshot.lazy_payload == payload && lazyfree_pending_objects() == 101 && lazyfreed_objects() == freed, "parent cleanup cannot mutate child pending counters")
		check(string(borrowed) == string(value[:]), "parent heap destruction cannot invalidate child snapshot bytes")
		check(pending_zset.sl.resize.old_slots == pending_slots && pending_zset.sl.resize.reg.resize_epoch != pending_zset.sl.resize.epoch, "child pending Zset retains cancelled generation and mapped source")
		child_score, child_found := zt.score(pending_zset, transmute([]u8)string("pending\x00member"))
		check(child_found && child_score == 2048, "parent worker cannot invalidate child pending Zset banks")
		check(db_size() == 1 && string(db_find(transmute([]u8)string("live-new")).val) == "snapshot", "child live keyspace excludes the detached pending database")
		persist_child_setup()
		check(persist_rdb_save(), "child persists live keyspace with pending worker snapshot")
		linux.exit_group(0)
	}
	linux.close(pipes[0])
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 0, .Release)
	settle()
	parent_mapped, parent_retired, _ := zt.maintenance_memory()
	check(parent_mapped == 0 && parent_retired == 0, "actual worker releases old Zset mappings only in the parent")
	check(lazyfree_pending_bytes() == 0 && lazyfree_pending_objects() == 0 && lazyfreed_objects() == freed + 101, "parent real worker releases pending payload exactly once")
	check(storage_table_allocated() == before.table_allocated - old_table, "parent real worker releases pending table exactly once")
	put("after-fork-only", "parent")
	token := [1]u8{1}
	n, werr := linux.write(pipes[1], token[:])
	check(n == 1 && werr == .NONE, "parent signals completed cleanup to child")
	linux.close(pipes[1])
	deadline = now_ns() + 5_000_000_000
	status: u32
	done := false
	for now_ns() < deadline {
		got, waiterr := linux.waitpid(pid, &status, {.WNOHANG}, nil)
		if waiterr != .NONE {
			check(false, "poll pending-worker child completion")
		}
		if got == pid {
			done = true
			break
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	if !done {
		linux.kill(pid, .SIGKILL)
		linux.waitpid(pid, &status, {}, nil)
	}
	check(done && status == 0, "pending-worker fork child completes within its bounded deadline")
	audit()
	check(db_size() == 2 && lazyfreed_objects() == freed + 101, "child persistence and exit leave parent cleanup unchanged")
	storage_clear()
	check(persist_rdb_load(false, false) == .Ok, "load pending-worker child snapshot")
	check(db_size() == 1 && db_find(transmute([]u8)string("after-fork-only")) == nil && string(db_find(transmute([]u8)string("live-new")).val) == "snapshot", "saved child snapshot contains only the pre-fork live keyspace")
	audit()
	storage_clear()
}


set_fork_pending_worker :: proc() {
	value: [5000]u8
	for &v, i in value {
		v = u8(i % 251 + 1)
	}
	for i in 0 ..< 100 {
		buf: [32]u8
		put(fmt.bprintf(buf[:], "pending-%d", i), string(value[:]))
	}
	pending_set := set_fixture("pending-set")
	storage_command(cmd_sadd, "SADD", "pending-set", "pending\x00member")
	pending_blob := pending_set.table.resize.old_slots
	e := db_find(transmute([]u8)string("pending-0"))
	borrowed := e.val
	payload := db_cur.heap_bytes + db_cur.slab.live
	old_table := mem_db_overhead(db_cur)
	freed := lazyfreed_objects()
	intrinsics.atomic_store_explicit(&storage_test_worker_entered, 0, .Release)
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 1, .Release)
	db_flush_in(db_cur, true)
	deadline := now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 0 && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 1, "actual worker reaches the unlocked pre-destruction barrier")
	check(lazyfree_jobs_pending() && lazyfree_pending_objects() == 101 && lazyfree_pending_bytes() == payload, "real async flush publishes pending object and payload ownership before fork")
	put("live-new", "snapshot")
	before := mem_storage()
	set_mapped_before, set_retired_before, _ := st.maintenance_memory()
	check(before.table_allocated == old_table + mem_db_overhead(db_cur), "pending worker retains its actual table allocation")
	check(before.lazy_payload == payload && before.lazy_slab_live > 0 && before.slab_writable > db_cur.slab.committed, "pending worker retains slab and heap ownership")
	pipes: [2]linux.Fd
	check(linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK}) == .NONE, "create bounded parent-child ordering pipe")
	cfg.dbfilename = "pending-set-worker.rdb"
	pid, err := linux.fork()
	check(err == .NONE, "fork while the real worker job is pending")
	if pid == 0 {
		linux.close(pipes[1])
		token: [1]u8
		got := false
		child_deadline := now_ns() + 5_000_000_000
		for now_ns() < child_deadline {
			n, rerr := linux.read(pipes[0], token[:])
			if n == 1 {
				got = true
				break
			}
			check(rerr == .EAGAIN || rerr == .EINTR, "child pipe remains valid before parent cleanup")
			ts := linux.Time_Spec{time_nsec = 100_000}
			linux.nanosleep(&ts, nil)
		}
		check(got && token[0] == 1, "child observes snapshot only after parent worker cleanup")
		linux.close(pipes[0])
		snapshot := mem_storage()
		child_mapped, child_retired, _ := st.maintenance_memory()
		check(child_mapped == set_mapped_before && child_retired == set_retired_before, "child retains its cancelled Set mapping snapshot after parent cleanup")
		check(snapshot.table_allocated == before.table_allocated && snapshot.table_mapped == before.table_mapped && snapshot.slab_virtual == before.slab_virtual && snapshot.slab_writable == before.slab_writable, "child retains its copied pending mapping counters")
		check(snapshot.metadata_owned == before.metadata_owned && snapshot.metadata_virtual == before.metadata_virtual && snapshot.metadata_writable == before.metadata_writable && snapshot.metadata_retired == before.metadata_retired, "parent old-worker release preserves the child metadata ownership snapshot")
		check(snapshot.lazy_payload == payload && lazyfree_pending_objects() == 101 && lazyfreed_objects() == freed, "parent cleanup cannot mutate child pending counters")
		check(string(borrowed) == string(value[:]), "parent heap destruction cannot invalidate child snapshot bytes")
		check(pending_set.table.resize.old_slots == pending_blob && pending_set.table.resize.reg.resize_epoch != pending_set.table.resize.epoch, "child pending Set retains cancelled generation and mapped source")
		check(st.is_member(pending_set, transmute([]u8)string("pending\x00member")), "parent worker cannot invalidate child pending Set banks")
		check(db_size() == 1 && string(db_find(transmute([]u8)string("live-new")).val) == "snapshot", "child live keyspace excludes the detached pending database")
		persist_child_setup()
		check(persist_rdb_save(), "child persists live keyspace with pending worker snapshot")
		linux.exit_group(0)
	}
	linux.close(pipes[0])
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 0, .Release)
	settle()
	parent_mapped, parent_retired, _ := st.maintenance_memory()
	check(parent_mapped == 0 && parent_retired == 0, "actual worker releases old Set mappings only in the parent")
	check(lazyfree_pending_bytes() == 0 && lazyfree_pending_objects() == 0 && lazyfreed_objects() == freed + 101, "parent real worker releases pending payload exactly once")
	check(storage_table_allocated() == before.table_allocated - old_table, "parent real worker releases pending table exactly once")
	put("after-fork-only", "parent")
	token := [1]u8{1}
	n, werr := linux.write(pipes[1], token[:])
	check(n == 1 && werr == .NONE, "parent signals completed cleanup to child")
	linux.close(pipes[1])
	deadline = now_ns() + 5_000_000_000
	status: u32
	done := false
	for now_ns() < deadline {
		got, waiterr := linux.waitpid(pid, &status, {.WNOHANG}, nil)
		if waiterr != .NONE {
			check(false, "poll pending-worker child completion")
		}
		if got == pid {
			done = true
			break
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	if !done {
		linux.kill(pid, .SIGKILL)
		linux.waitpid(pid, &status, {}, nil)
	}
	check(done && status == 0, "pending-worker fork child completes within its bounded deadline")
	audit()
	check(db_size() == 2 && lazyfreed_objects() == freed + 101, "child persistence and exit leave parent cleanup unchanged")
	storage_clear()
	check(persist_rdb_load(false, false) == .Ok, "load pending-worker child snapshot")
	check(db_size() == 1 && db_find(transmute([]u8)string("after-fork-only")) == nil && string(db_find(transmute([]u8)string("live-new")).val) == "snapshot", "saved child snapshot contains only the pre-fork live keyspace")
	audit()
	storage_clear()
}


set_allocator_sample :: proc() {
	baseline := mem_overhead()
	t := st.table_make(256)
	for i in 0 ..< 256 {
		field: [32]u8
		st.table_add(t, transmute([]u8)fmt.bprintf(field[:], "sample:%d", i))
	}
	st.table_resize(t, 1024)
	for t.resize != nil {
		st.table_step(t, 64, 4)
	}
	check(st.maintenance_release(4096) == 4096, "sample fixture partially unmaps its known 8 KiB retired source")
	mapped, retired, metadata := st.maintenance_memory()
	check(mapped == 20480 && retired == 4096 && metadata > 0, "sample fixture retains one retired page beside its owned 16 KiB destination")
	allocated, rss, libc_allocated := storage_test_memory_sample()
	check(allocated == libc_allocated + 16384, "allocator sample charges owned member mappings and libc metadata exactly once")
	check(rss > 0 && mapped > mapped - retired, "RSS stays a kernel sample while mapped diagnostics retain retired capacity")
	overhead := mem_overhead()
	check(overhead.total - baseline.total == metadata && overhead.overhead - baseline.overhead == metadata, "retired maintenance records are charged exactly to overhead")
	check(overhead.dataset == baseline.dataset && overhead.lut == baseline.lut, "retired metadata changes neither dataset nor keyspace table capacity")
	st.table_free(t)
	for st.maintenance_pending() {
		st.maintenance_release()
	}
	mapped, retired, metadata = st.maintenance_memory()
	check(mapped == 0 && retired == 0 && metadata == 0, "sample fixture fully releases ownership")
	overhead = mem_overhead()
	check(overhead.total == baseline.total && overhead.overhead == baseline.overhead && overhead.dataset == baseline.dataset, "released record restores the exact overhead and dataset totals")
}

hash_allocator_sample :: proc() {
	baseline := mem_overhead()
	t := ht.table_make(256)
	for i in 0 ..< 256 {
		field: [32]u8
		ht.table_set(t, transmute([]u8)fmt.bprintf(field[:], "sample:%d", i), transmute([]u8)string("value"))
	}
	ht.table_resize(t, 1024)
	for t.resize != nil {
		ht.table_step(t, 64, 4)
	}
	check(ht.maintenance_release(4096) == 4096, "sample fixture partially unmaps its known 8 KiB retired source")
	mapped, retired, metadata := ht.maintenance_memory()
	check(mapped == 20480 && retired == 4096 && metadata > 0, "sample fixture retains one retired page beside its owned 16 KiB destination")
	allocated, rss, libc_allocated := storage_test_memory_sample()
	check(allocated == libc_allocated + 16384, "allocator sample charges owned member mappings and libc metadata exactly once")
	check(rss > 0 && mapped > mapped - retired, "RSS stays a kernel sample while mapped diagnostics retain retired capacity")
	overhead := mem_overhead()
	check(overhead.total - baseline.total == metadata && overhead.overhead - baseline.overhead == metadata, "retired maintenance records are charged exactly to overhead")
	check(overhead.dataset == baseline.dataset && overhead.lut == baseline.lut, "retired metadata changes neither dataset nor keyspace table capacity")
	ht.table_free(t)
	for ht.maintenance_pending() {
		ht.maintenance_release()
	}
	mapped, retired, metadata = ht.maintenance_memory()
	check(mapped == 0 && retired == 0 && metadata == 0, "sample fixture fully releases ownership")
	overhead = mem_overhead()
	check(overhead.total == baseline.total && overhead.overhead == baseline.overhead && overhead.dataset == baseline.dataset, "released record restores the exact overhead and dataset totals")
}

zset_fixture :: proc(key: string) -> zt.Zset {
	h := zset_new_skiplist(512)
	for i in 0 ..< 512 {
		field: [32]u8
		zt.add(h, f64(i), transmute([]u8)fmt.bprintf(field[:], "member:%d", i), {})
	}
	zt.dict_resize(h.sl, h.sl.cap * 2)
	h.acct = zt.memory_usage(h)
	e, _ := db_upsert(transmute([]u8)key)
	entry_object_attach(e, h, .Zset, .Skiplist, h.acct)
	zt.maintenance_bind(h, e.db.zctx)
	return h
}

set_fixture :: proc(key: string) -> st.Set {
	h := st.create_table(256)
	for i in 0 ..< 256 {
		field: [32]u8
		st.add(h, transmute([]u8)fmt.bprintf(field[:], "member:%d", i))
	}
	st.table_resize(h.table, h.table.cap * 2)
	h.acct = st.memory_usage(h)
	e, _ := db_upsert(transmute([]u8)key)
	entry_object_attach(e, h, .Set, .Hashtable, h.acct)
	st.maintenance_bind(h, e.db.sctx)
	return h
}

hash_fixture :: proc(key: string) -> ht.Hash {
	h := ht.create()
	ht.convert(h, 256)
	for i in 0 ..< 256 {
		field: [32]u8
		ht.set(h, transmute([]u8)fmt.bprintf(field[:], "field:%d", i), transmute([]u8)string("value\x00suffix"))
	}
	ht.table_resize(h.table, h.table.cap * 2)
	h.acct = ht.memory_usage(h)
	e, _ := db_upsert(transmute([]u8)key)
	entry_object_attach(e, h, .Hash, .Hashtable, h.acct)
	ht.maintenance_bind(h, e.db.hreg)
	return h
}

hash_ownership :: proc() {
	h := hash_fixture("hash")
	reg := db_cur.hreg
	old_bytes := 512 * size_of(ht.Slot)
	state_bytes := ht.mem_usable_size(h.table.resize)
	before := db_cur.heap_bytes
	check(h.table.resize.old_cap == 512 && reg.resize_count == 1 && reg.owner == db_cur, "hash fixture owns known source array and cold resize job")
	db_swap(0, 1)
	check(dbs[1].hreg == reg && reg.owner == &dbs[1] && dbs[0].hreg.owner == &dbs[0], "SWAPDB updates stable registry owners without walking hash jobs")
	active_before := active_expire_enabled
	active_expire_enabled = false
	maxmemory_bytes = u64(mem_used() - 4096)
	over, _ := memory_state_over()
	check(over, "active source capacity is charged before migration completion")
	for _ in 0 ..< 1024 {
		if h.table.resize == nil {
			break
		}
		db_tick()
	}
	active_expire_enabled = active_before
	over, _ = memory_state_over()
	check(!over, "quiet member progress releases maxmemory charge with HFE disabled")
	maxmemory_bytes = 0
	check(h.table.resize == nil && dbs[1].heap_bytes == before - old_bytes - state_bytes, "idle completion charges exact known array and state release to swapped owner")
	check(dbs[1].heap_bytes == h.acct && h.acct == ht.memory_usage(h) && dbs[0].heap_bytes == 0, "quiet callback refreshes owning database without cached Entry")
	db_cur = &dbs[1]
	moved := hash_fixture("move")
	check(db_move(&dbs[1], &dbs[0], transmute([]u8)string("move")), "MOVE transfers an active no-TTL member migration")
	check(moved.table.resize.reg == dbs[0].hreg && dbs[0].hreg.resize_count == 1 && reg.resize_count == 0, "MOVE rebinds hash jobs even without field expiry")
	settle()
	check(dbs[0].heap_bytes == moved.acct && moved.acct == ht.memory_usage(moved), "moved job completes against destination accounting")
	db_cur = &dbs[0]
	a := hash_fixture("unlink-a")
	hash_fixture("unlink-b")
	check(db_cur.hreg.resize_count == 2, "two hashes share a live maintenance queue")
	saved := lazy_set(true)
	db_remove(transmute([]u8)string("unlink-a"))
	lazy_mode = saved
	check(db_cur.hreg.resize_count == 1 && db_cur.hreg.resize_head.owner != a, "UNLINK cancels the actual job before worker publication")
	epoch := db_cur.hreg.resize_epoch
	db_flush_in(db_cur, true)
	check(db_cur.hreg.resize_count == 0 && db_cur.hreg.resize_epoch == epoch + 1, "async flush invalidates remaining jobs in one registry generation")
	audit()
	storage_clear()
	db_cur = &dbs[0]
	h = hash_fixture("fork-hash")
	cfg.dbfilename = "hash-banks.rdb"
	mapped, _, _ := ht.maintenance_memory()
	pid, err := linux.fork()
	check(err == .NONE, "fork with active hash-member migration")
	if pid == 0 {
		persist_child_setup()
		check(persist_rdb_save(), "child persists both live hash banks before migration")
		settle()
		check(h.table.resize == nil && db_cur.heap_bytes == h.acct && h.acct == ht.memory_usage(h), "child completes private migration and ownership accounting")
		v, _, found := ht.get_raw(h, transmute([]u8)string("field:255"))
		check(found && string(v.str) == "value\x00suffix", "child retains both-bank payload bytes")
		storage_clear()
		linux.exit_group(0)
	}
	status: u32
	linux.waitpid(pid, &status, {}, nil)
	check(status == 0 && h.table.resize != nil && db_cur.hreg.resize_count == 1, "child completion cannot consume parent migration job")
	after, _, _ := ht.maintenance_memory()
	check(after == mapped && db_cur.heap_bytes == h.acct, "child unmaps cannot change parent member-array counters")
	audit()
	storage_clear()
	check(persist_rdb_load(false, false) == .Ok, "reload fork snapshot containing both member banks")
	e := db_find(transmute([]u8)string("fork-hash"))
	loaded := ht.Hash(entry_object(e, .Hash))
	check(loaded != nil && ht.length(loaded) == 256 && loaded.acct == ht.memory_usage(loaded), "persisted hash has complete fields and exact allocation ownership")
	audit()
	storage_clear()
}

zset_worker_generation_reuse :: proc() {
	storage_clear()
	old := zset_fixture("old")
	reg := db_cur.zctx
	epoch := reg.resize_epoch
	old_payload := old.acct
	old_tables := mem_db_overhead(db_cur)
	freed := lazyfreed_objects()
	check(old.sl.cap == 2048 && old.sl.resize.old_cap == 1024 && old_tables == 4096, "old-generation fixture owns known member arrays and key table")
	intrinsics.atomic_store_explicit(&storage_test_worker_entered, 0, .Release)
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 1, .Release)
	db_flush_in(db_cur, true)
	deadline := now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 0 && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 1, "old-generation worker pauses after real submission outside queue mutex")
	check(db_cur.zctx == reg && reg.resize_epoch == epoch + 1 && reg.resize_count == 0, "async flush invalidates the old job before stable registry reuse")
	check(lazyfree_pending_objects() == 1 && lazyfree_pending_bytes() == old_payload, "paused old job retains exact pending payload ownership")
	a := zset_fixture("a")
	b := zset_fixture("b")
	first, last := a.sl.resize, b.sl.resize
	new_epoch := reg.resize_epoch
	new_payload := a.acct + b.acct
	before_memory := mem_used()
	check(reg.resize_head == first && reg.resize_tail == last && reg.resize_count == 2 && first.prev == nil && first.next == last && last.prev == first && last.next == nil, "two new jobs populate the reused registry before old worker resumes")
	check(first.reg == reg && last.reg == reg && first.epoch == new_epoch && last.epoch == new_epoch && first.cursor == 0 && last.cursor == 0, "new jobs retain the current generation without migration grants")
	mapped, retired, metadata := zt.maintenance_memory()
	check(mapped == 3 * 24576 && retired == 0 && metadata == 0 && db_cur.heap_bytes == new_payload && db_used_memory == new_payload, "pending old arrays and two new active zsets have exact separate ownership")
	check(storage_table_allocated() == old_tables + mem_db_overhead(db_cur), "old and reused databases each retain their actual key table")
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 0, .Release)
	deadline = now_ns() + 2_000_000_000
	for !storage_test_worker_idle() && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(storage_test_worker_idle(), "old-generation destruction completes without db_tick")
	check(reg.resize_epoch == new_epoch && reg.resize_head == first && reg.resize_tail == last && reg.resize_count == 2, "old-generation worker cannot alter the new registry epoch or list endpoints")
	check(first.prev == nil && first.next == last && last.prev == first && last.next == nil && first.cursor == 0 && last.cursor == 0 && first.old_count == 512 && last.old_count == 512, "old-generation worker cannot change new links, counts or migration positions")
	check(first.owner == a && last.owner == b && first.reg == reg && last.reg == reg && first.epoch == new_epoch && last.epoch == new_epoch, "new job identities and ownership remain intact after old cleanup")
	mapped, retired, metadata = zt.maintenance_memory()
	check(mapped == 2 * 24576 && retired == 0 && metadata == 0 && db_cur.heap_bytes == new_payload && db_used_memory == new_payload, "real worker releases only the old mapped arrays and payload")
	check(lazyfree_pending_bytes() == 0 && lazyfree_pending_objects() == 0 && lazyfreed_objects() == freed + 1 && storage_table_allocated() == mem_db_overhead(db_cur), "real worker releases the old table and pending counters exactly once")
	check(before_memory - mem_used() == old_payload + old_tables, "old-generation cleanup removes exactly the old payload and table allocation charge")
	settle()
	check(reg.resize_count == 0 && a.sl.resize == nil && b.sl.resize == nil && a.acct == zt.memory_usage(a) && b.acct == zt.memory_usage(b), "new-generation jobs later make normal progress with exact refreshed accounting")
	mapped, retired, metadata = zt.maintenance_memory()
	check(mapped == 2 * 16384 && retired == 0 && metadata == 0, "both new jobs settle to their known destination arrays")
	audit()
	storage_clear()
}

set_worker_generation_reuse :: proc() {
	storage_clear()
	old := set_fixture("old")
	reg := db_cur.sctx
	epoch := reg.resize_epoch
	old_payload := old.acct
	old_tables := mem_db_overhead(db_cur)
	freed := lazyfreed_objects()
	check(old.table.cap == 1024 && old.table.resize.old_cap == 512 && old_tables == 4096, "old-generation fixture owns known member arrays and key table")
	intrinsics.atomic_store_explicit(&storage_test_worker_entered, 0, .Release)
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 1, .Release)
	db_flush_in(db_cur, true)
	deadline := now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 0 && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 1, "old-generation worker pauses after real submission outside queue mutex")
	check(db_cur.sctx == reg && reg.resize_epoch == epoch + 1 && reg.resize_count == 0, "async flush invalidates the old job before stable registry reuse")
	check(lazyfree_pending_objects() == 1 && lazyfree_pending_bytes() == old_payload, "paused old job retains exact pending payload ownership")
	a := set_fixture("a")
	b := set_fixture("b")
	first, last := a.table.resize, b.table.resize
	new_epoch := reg.resize_epoch
	new_payload := a.acct + b.acct
	before_memory := mem_used()
	check(reg.resize_head == first && reg.resize_tail == last && reg.resize_count == 2 && first.prev == nil && first.next == last && last.prev == first && last.next == nil, "two new jobs populate the reused registry before old worker resumes")
	check(first.reg == reg && last.reg == reg && first.epoch == new_epoch && last.epoch == new_epoch && first.cursor == 0 && last.cursor == 0, "new jobs retain the current generation without migration grants")
	mapped, retired, metadata := st.maintenance_memory()
	check(mapped == 3 * 24576 && retired == 0 && metadata == 0 && db_cur.heap_bytes == new_payload && db_used_memory == new_payload, "pending old arrays and two new active sets have exact separate ownership")
	check(storage_table_allocated() == old_tables + mem_db_overhead(db_cur), "old and reused databases each retain their actual key table")
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 0, .Release)
	deadline = now_ns() + 2_000_000_000
	for !storage_test_worker_idle() && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(storage_test_worker_idle(), "old-generation destruction completes without db_tick")
	check(reg.resize_epoch == new_epoch && reg.resize_head == first && reg.resize_tail == last && reg.resize_count == 2, "old-generation worker cannot alter the new registry epoch or list endpoints")
	check(first.prev == nil && first.next == last && last.prev == first && last.next == nil && first.cursor == 0 && last.cursor == 0 && first.old_count == 256 && last.old_count == 256, "old-generation worker cannot change new links, counts or migration positions")
	check(first.owner == a && last.owner == b && first.reg == reg && last.reg == reg && first.epoch == new_epoch && last.epoch == new_epoch, "new job identities and ownership remain intact after old cleanup")
	mapped, retired, metadata = st.maintenance_memory()
	check(mapped == 2 * 24576 && retired == 0 && metadata == 0 && db_cur.heap_bytes == new_payload && db_used_memory == new_payload, "real worker releases only the old mapped arrays and payload")
	check(lazyfree_pending_bytes() == 0 && lazyfree_pending_objects() == 0 && lazyfreed_objects() == freed + 1 && storage_table_allocated() == mem_db_overhead(db_cur), "real worker releases the old table and pending counters exactly once")
	check(before_memory - mem_used() == old_payload + old_tables, "old-generation cleanup removes exactly the old payload and table allocation charge")
	settle()
	check(reg.resize_count == 0 && a.table.resize == nil && b.table.resize == nil && a.acct == st.memory_usage(a) && b.acct == st.memory_usage(b), "new-generation jobs later make normal progress with exact refreshed accounting")
	mapped, retired, metadata = st.maintenance_memory()
	check(mapped == 2 * 16384 && retired == 0 && metadata == 0, "both new jobs settle to their known destination arrays")
	audit()
	storage_clear()
}

hash_worker_generation_reuse :: proc() {
	storage_clear()
	old := hash_fixture("old")
	reg := db_cur.hreg
	epoch := reg.resize_epoch
	old_payload := old.acct
	old_tables := mem_db_overhead(db_cur)
	freed := lazyfreed_objects()
	check(old.table.cap == 1024 && old.table.resize.old_cap == 512 && old_tables == 4096, "old-generation fixture owns known member arrays and key table")
	intrinsics.atomic_store_explicit(&storage_test_worker_entered, 0, .Release)
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 1, .Release)
	db_flush_in(db_cur, true)
	deadline := now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 0 && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 1, "old-generation worker pauses after real submission outside queue mutex")
	check(db_cur.hreg == reg && reg.resize_epoch == epoch + 1 && reg.resize_count == 0, "async flush invalidates the old job before stable registry reuse")
	check(lazyfree_pending_objects() == 1 && lazyfree_pending_bytes() == old_payload, "paused old job retains exact pending payload ownership")
	a := hash_fixture("a")
	b := hash_fixture("b")
	first, last := a.table.resize, b.table.resize
	new_epoch := reg.resize_epoch
	new_payload := a.acct + b.acct
	before_memory := mem_used()
	check(reg.resize_head == first && reg.resize_tail == last && reg.resize_count == 2 && first.prev == nil && first.next == last && last.prev == first && last.next == nil, "two new jobs populate the reused registry before old worker resumes")
	check(first.reg == reg && last.reg == reg && first.epoch == new_epoch && last.epoch == new_epoch && first.cursor == 0 && last.cursor == 0, "new jobs retain the current generation without migration grants")
	mapped, retired, metadata := ht.maintenance_memory()
	check(mapped == 3 * 24576 && retired == 0 && metadata == 0 && db_cur.heap_bytes == new_payload && db_used_memory == new_payload, "pending old arrays and two new active hashes have exact separate ownership")
	check(storage_table_allocated() == old_tables + mem_db_overhead(db_cur), "old and reused databases each retain their actual key table")
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 0, .Release)
	deadline = now_ns() + 2_000_000_000
	for !storage_test_worker_idle() && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(storage_test_worker_idle(), "old-generation destruction completes without db_tick")
	check(reg.resize_epoch == new_epoch && reg.resize_head == first && reg.resize_tail == last && reg.resize_count == 2, "old-generation worker cannot alter the new registry epoch or list endpoints")
	check(first.prev == nil && first.next == last && last.prev == first && last.next == nil && first.cursor == 0 && last.cursor == 0 && first.old_count == 256 && last.old_count == 256, "old-generation worker cannot change new links, counts or migration positions")
	check(first.owner == a && last.owner == b && first.reg == reg && last.reg == reg && first.epoch == new_epoch && last.epoch == new_epoch, "new job identities and ownership remain intact after old cleanup")
	mapped, retired, metadata = ht.maintenance_memory()
	check(mapped == 2 * 24576 && retired == 0 && metadata == 0 && db_cur.heap_bytes == new_payload && db_used_memory == new_payload, "real worker releases only the old mapped arrays and payload")
	check(lazyfree_pending_bytes() == 0 && lazyfree_pending_objects() == 0 && lazyfreed_objects() == freed + 1 && storage_table_allocated() == mem_db_overhead(db_cur), "real worker releases the old table and pending counters exactly once")
	check(before_memory - mem_used() == old_payload + old_tables, "old-generation cleanup removes exactly the old payload and table allocation charge")
	settle()
	check(reg.resize_count == 0 && a.table.resize == nil && b.table.resize == nil && a.acct == ht.memory_usage(a) && b.acct == ht.memory_usage(b), "new-generation jobs later make normal progress with exact refreshed accounting")
	mapped, retired, metadata = ht.maintenance_memory()
	check(mapped == 2 * 16384 && retired == 0 && metadata == 0, "both new jobs settle to their known destination arrays")
	audit()
	storage_clear()
}

zset_ownership :: proc() {
	s := zset_fixture("set")
	ctx := db_cur.zctx
	before := db_cur.heap_bytes
	state_bytes := st_size(s.sl.resize)
	db_swap(0, 1)
	check(dbs[1].zctx == ctx && ctx.owner == &dbs[1] && dbs[0].zctx.owner == &dbs[0], "Zset SWAPDB updates two cold owners without walking jobs")
	active_before := active_expire_enabled
	active_expire_enabled = false
	maxmemory_bytes = u64(mem_used() - 4096)
	over, _ := memory_state_over()
	check(over, "active Zset source capacity is charged")
	for _ in 0 ..< 1024 {
		if s.sl.resize == nil {
			break
		}
		db_tick()
	}
	active_expire_enabled = active_before
	over, _ = memory_state_over()
	check(!over && s.sl.resize == nil && dbs[1].heap_bytes == before - 8192 - state_bytes, "quiet Zset service releases exact source bytes with expiry disabled")
	maxmemory_bytes = 0
	check(dbs[1].heap_bytes == s.acct && s.acct == zt.memory_usage(s), "swapped Zset callback refreshes the correct Db")
	db_cur = &dbs[1]
	moved := zset_fixture("move-set")
	check(db_move(&dbs[1], &dbs[0], transmute([]u8)string("move-set")), "MOVE transfers active Zset migration")
	check(moved.sl.resize.reg == dbs[0].zctx && dbs[0].zctx.resize_count == 1 && ctx.resize_count == 0, "MOVE rebinds the Zset job before allocation ownership transfer")
	settle()
	check(dbs[0].heap_bytes == moved.acct && moved.acct == zt.memory_usage(moved), "moved Zset completes against destination accounting")
	db_cur = &dbs[0]
	a := zset_fixture("unlink-a")
	zset_fixture("unlink-b")
	check(db_cur.zctx.resize_count == 2, "two Sets populate one cold queue")
	saved := lazy_set(true)
	db_remove(transmute([]u8)string("unlink-a"))
	lazy_mode = saved
	check(db_cur.zctx.resize_count == 1 && db_cur.zctx.resize_head.owner != a, "Zset UNLINK cancels its job before real worker publication")
	epoch := db_cur.zctx.resize_epoch
	db_flush_in(db_cur, true)
	check(db_cur.zctx.resize_count == 0 && db_cur.zctx.resize_epoch == epoch + 1, "Zset async flush invalidates queue generation in constant work")
	audit()
	storage_clear()
	db_cur = &dbs[0]
}

set_ownership :: proc() {
	s := set_fixture("set")
	ctx := db_cur.sctx
	before := db_cur.heap_bytes
	state_bytes := st_size(s.table.resize)
	db_swap(0, 1)
	check(dbs[1].sctx == ctx && ctx.owner == &dbs[1] && dbs[0].sctx.owner == &dbs[0], "Set SWAPDB updates two cold owners without walking jobs")
	active_before := active_expire_enabled
	active_expire_enabled = false
	maxmemory_bytes = u64(mem_used() - 4096)
	over, _ := memory_state_over()
	check(over, "active Set source capacity is charged")
	for _ in 0 ..< 1024 {
		if s.table.resize == nil {
			break
		}
		db_tick()
	}
	active_expire_enabled = active_before
	over, _ = memory_state_over()
	check(!over && s.table.resize == nil && dbs[1].heap_bytes == before - 8192 - state_bytes, "quiet Set service releases exact source bytes with expiry disabled")
	maxmemory_bytes = 0
	check(dbs[1].heap_bytes == s.acct && s.acct == st.memory_usage(s), "swapped Set callback refreshes the correct Db")
	db_cur = &dbs[1]
	moved := set_fixture("move-set")
	check(db_move(&dbs[1], &dbs[0], transmute([]u8)string("move-set")), "MOVE transfers active Set migration")
	check(moved.table.resize.reg == dbs[0].sctx && dbs[0].sctx.resize_count == 1 && ctx.resize_count == 0, "MOVE rebinds the Set job before allocation ownership transfer")
	settle()
	check(dbs[0].heap_bytes == moved.acct && moved.acct == st.memory_usage(moved), "moved Set completes against destination accounting")
	db_cur = &dbs[0]
	a := set_fixture("unlink-a")
	set_fixture("unlink-b")
	check(db_cur.sctx.resize_count == 2, "two Sets populate one cold queue")
	saved := lazy_set(true)
	db_remove(transmute([]u8)string("unlink-a"))
	lazy_mode = saved
	check(db_cur.sctx.resize_count == 1 && db_cur.sctx.resize_head.owner != a, "Set UNLINK cancels its job before real worker publication")
	epoch := db_cur.sctx.resize_epoch
	db_flush_in(db_cur, true)
	check(db_cur.sctx.resize_count == 0 && db_cur.sctx.resize_epoch == epoch + 1, "Set async flush invalidates queue generation in constant work")
	audit()
	storage_clear()
	db_cur = &dbs[0]
}

st_size :: proc(p: rawptr) -> int {
	return lp.lp_malloc_size(p)
}

set_commands :: proc() {
	a := set_fixture("a")
	b := set_fixture("b")
	storage_command(cmd_smove, "SMOVE", "a", "b", "member:255")
	check(st.size(a) == 255 && st.size(b) == 256 && !st.is_member(a, transmute([]u8)string("member:255")), "SMOVE into existing membership updates only source")
	storage_command(cmd_sadd, "SADD", "a", "binary\x00member")
	storage_command(cmd_smove, "SMOVE", "a", "b", "binary\x00member")
	check(st.size(a) == 255 && st.size(b) == 257 && st.is_member(b, transmute([]u8)string("binary\x00member")), "SMOVE copies binary member bytes before source destruction")
	check(a.acct == st.memory_usage(a) && b.acct == st.memory_usage(b), "SMOVE refreshes both allocation owners")
	storage_command(cmd_copy, "COPY", "a", "c")
	storage_command(cmd_sunionstore, "SUNIONSTORE", "a", "a", "b")
	e := db_find(transmute([]u8)string("a"))
	a = st.Set(entry_object(e, .Set))
	check(st.size(a) == 257 && a.acct == st.memory_usage(a), "SUNIONSTORE destination=input preserves all members before replacement")
	storage_command(cmd_sinterstore, "SINTERSTORE", "b", "b", "a")
	e = db_find(transmute([]u8)string("b"))
	b = st.Set(entry_object(e, .Set))
	check(st.size(b) == 257 && b.acct == st.memory_usage(b), "SINTERSTORE safely replaces an input with copied members")
	storage_command(cmd_sdiffstore, "SDIFFSTORE", "a", "a", "c")
	e = db_find(transmute([]u8)string("a"))
	a = st.Set(entry_object(e, .Set))
	check(st.size(a) == 2 && st.is_member(a, transmute([]u8)string("member:255")) && st.is_member(a, transmute([]u8)string("binary\x00member")), "SDIFFSTORE aliasing keeps exact binary difference")
	audit()
	storage_clear()
}

storage_debug_response :: proc(key: string, full: bool, protocol: u8) -> []u8 {
	c := Conn{db = db_cur, resp = protocol, wbuf = mem_alloc(WBUF_INIT), wcap = WBUF_INIT}
	defer mem_free(c.wbuf)
	args := [4][]u8{transmute([]u8)string("DEBUG"), transmute([]u8)string("HTSTATS-KEY"), transmute([]u8)key, transmute([]u8)string("full")}
	check(debug_more(&c, args[:4 if full else 3]), "actual DEBUG reader handles the fixture")
	result := mem_alloc(c.wlen)
	intrinsics.mem_copy_non_overlapping(result, c.wbuf, c.wlen)
	return result[:c.wlen]
}

storage_debug_payload :: proc(response: []u8, protocol: u8) -> string {
	text := string(response)
	check(response[0] == ('$' if protocol == 2 else '='), "DEBUG preserves RESP2 bulk/RESP3 verbatim shape")
	line := strings.index(text, "\r\n")
	declared, ok := strconv.parse_int(text[1:line])
	check(ok && declared == len(text) - line - 4, "DEBUG response declares its exact byte length")
	payload := text[line + 2:len(text) - 2]
	if protocol == 3 {
		check(strings.has_prefix(payload, "txt:"), "DEBUG RESP3 text verbatim format")
		payload = payload[4:]
	}
	return payload
}

storage_debug_bank :: proc(text: string, counts: []int, bank: int) -> int {
	used, buckets, longest := 0, 0, 0
	for chain in counts {
		used += chain
		buckets += int(chain > 0)
		longest = max(longest, chain)
	}
	check(longest < 49 && used > 0, "DEBUG fixture has complete visible chain distribution")
	header := "Hash table 0 stats (main hash table):\n" if bank == 0 else "Hash table 1 stats (rehashing target):\n"
	check(strings.has_prefix(text, header), "DEBUG reports exact reference bank header")
	check(strings.contains(text, fmt.tprintf(" table size: %d\n number of elements: %d\n different slots: %d\n max chain length: %d\n", len(counts), used, buckets, longest)), "DEBUG physical-bank size/live/bucket/chain counters match actual occupancy")
	lines := strings.split(text, "\n")
	defer delete(lines)
	chain_sum, bucket_sum := 0, 0
	for line in lines {
		if !strings.has_prefix(line, "   ") {
			continue
		}
		fields := strings.fields(line)
		check(len(fields) == 3, "DEBUG chain row shape")
		chain, chain_ok := strconv.parse_int(fields[0][:len(fields[0]) - 1])
		n, n_ok := strconv.parse_int(fields[1])
		check(chain_ok && n_ok && chain >= 0 && chain <= longest, "DEBUG chain row numeric fields")
		expected := 0
		for c in counts {
			expected += int(c == chain)
		}
		check(n == expected, "DEBUG distribution counts match independent physical buckets")
		chain_sum += chain * n
		bucket_sum += n
		delete(fields)
	}
	check(chain_sum == used && bucket_sum == len(counts), "DEBUG chain distribution totals equal actual elements and capacity")
	return used
}

storage_debug_banks :: proc(key: string, first, second: []int, expected: int = 256) {
	for protocol in ([2]u8{2, 3}) {
		response := storage_debug_response(key, true, protocol)
		body := storage_debug_payload(response, protocol)
		split := strings.index(body, "Hash table 1 stats (rehashing target):\n")
		check(split > 0, "DEBUG reports both active banks without migration")
		count := storage_debug_bank(body[:split], first, 0)
		count += storage_debug_bank(body[split:], second, 1)
		check(count == expected, "DEBUG aggregate bank elements and chain counts equal logical cardinality")
		mem_free(raw_data(response))
		response = storage_debug_response(key, false, protocol)
		body = storage_debug_payload(response, protocol)
		check(strings.contains(body, "Hash table 0 stats (main hash table):\n") && strings.contains(body, "Hash table 1 stats (rehashing target):\n") && !strings.contains(body, "Chain length distribution"), "DEBUG non-full response preserves both labels without chain details")
		mem_free(raw_data(response))
	}
}

set_hash_debug :: proc() {
	h := hash_fixture("debug-hash")
	s := set_fixture("debug-set")
	ht.table_step(h.table, 64, 4)
	st.table_step(s.table, 64, 4)
	hash_cursor, set_cursor := h.table.resize.cursor, s.table.resize.cursor
	hash_counts, set_counts: [2][]int
	hash_tombs, set_tombs := 0, 0
	for bank in 0 ..< 2 {
		hs, hc := ht.table_bank(h.table, 1 - bank)
		ss, sc := st.table_bank(s.table, 1 - bank)
		hash_counts[bank] = make([]int, hc)
		set_counts[bank] = make([]int, sc)
		for i in 0 ..< hc {
			if uintptr(hs[i].blob) > 1 {
				hash_counts[bank][hs[i].hash & u64(hc - 1)] += 1
			} else {
				hash_tombs += int(uintptr(hs[i].blob) == 1)
			}
		}
		for i in 0 ..< sc {
			if uintptr(ss[i].blob) > 1 {
				set_counts[bank][ss[i].hash & u64(sc - 1)] += 1
			} else {
				set_tombs += int(uintptr(ss[i].blob) == 1)
			}
		}
	}
	check(hash_tombs == 4 && set_tombs == 4, "diagnostic fixtures contain live source/target entries and old tombstones")
	storage_sort_banks()
	storage_debug_banks("debug-hash", hash_counts[0], hash_counts[1])
	storage_debug_banks("debug-set", set_counts[0], set_counts[1])
	check(h.table.resize.cursor == hash_cursor && s.table.resize.cursor == set_cursor, "DEBUG inspection never forces migration completion")
	for i in 0 ..< 2 {
		delete(hash_counts[i])
		delete(set_counts[i])
	}
	settle()
	for key in ([2]string{"debug-hash", "debug-set"}) {
		response := storage_debug_response(key, true, 2)
		body := storage_debug_payload(response, 2)
		check(strings.has_prefix(body, "Hash table 0 stats (main hash table):\n table size: 1024\n number of elements: 256\n") && !strings.contains(body, "Hash table 1"), "settled DEBUG keeps its single-table output")
		mem_free(raw_data(response))
	}
	put("debug-string", "value")
	response := storage_debug_response("debug-string", true, 2)
	check(string(response) == "-ERR The value stored at the specified key is not represented using an hash table\r\n", "DEBUG unsupported encoding error remains exact")
	mem_free(raw_data(response))
	response = storage_debug_response("missing-debug", true, 3)
	check(string(response) == "-ERR no such key\r\n", "DEBUG missing-key error remains exact")
	mem_free(raw_data(response))
	audit()
	storage_clear()
}

set_loaded_bind :: proc() {
	s := st.create_table(256)
	for i in 0 ..< 256 {
		member: [32]u8
		st.add(s, transmute([]u8)fmt.bprintf(member[:], "loaded:%d", i))
	}
	st.table_resize(s.table, 1024)
	check(s.table.resize.reg == nil, "clamped-load fixture ends with unbound two-bank Set")
	key := transmute([]u8)string("loaded-set")
	e, _ := db_upsert(key)
	persist_attach(e, key, Loaded_Value{type = .Set, obj = s})
	check(s.table.resize.reg == db_cur.sctx && db_cur.sctx.resize_count == 1 && s.acct == st.memory_usage(s) && db_cur.heap_bytes == s.acct, "shared load/RESTORE attachment binds Set maintenance and exact ownership")
	settle()
	check(s.table.resize == nil && s.acct == st.memory_usage(s) && db_cur.heap_bytes == s.acct, "loaded Set makes idle progress with refreshed ownership")
	audit()
	storage_clear()
}

set_spop_pending :: proc() {
	s := set_fixture("pop-set")
	work := st.table_step(s.table, 512, 240)
	check(work.moved == 240 && s.table.resize.old_count == 16, "SPOP replacement fixture retains sixteen unmigrated source members")
	old_acct := s.acct
	old_config := cfg.lazyfree_lazy_server_del
	old_mode := lazy_mode
	cfg.lazyfree_lazy_server_del = true
	lazy_mode = .Server
	intrinsics.atomic_store_explicit(&storage_test_worker_entered, 0, .Release)
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 1, .Release)
	storage_command(cmd_spop, "SPOP", "pop-set", "250")
	cfg.lazyfree_lazy_server_del = old_config
	lazy_mode = old_mode
	deadline := now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 0 && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 1, "SPOP replacement publishes its old Set to the real paused worker")
	check(s.table.resize == nil && s.table.count == 250 && s.table.cap == 1024, "SPOP survivor moves complete source migration before old Set publication")
	remaining := lp.lp_malloc_size(s) + lp.lp_malloc_size(s.table) + 16384
	blobs := 0
	for i in 0 ..< s.table.cap {
		if uintptr(s.table.slots[i].blob) > 1 {
			remaining += lp.lp_malloc_size(s.table.slots[i].blob)
			blobs += 1
		}
	}
	check(blobs == 250 && s.acct == remaining && st.memory_usage(s) == remaining && old_acct > remaining + 8192, "independent remaining-Blob sum excludes freed survivors and old source capacity")
	check(lazyfree_pending_objects() == 1 && lazyfree_pending_bytes() == remaining, "SPOP lazy replacement publishes exact remaining ownership rather than stale pre-pop bytes")
	e := db_find(transmute([]u8)string("pop-set"))
	newset := st.Set(entry_object(e, .Set))
	check(st.size(newset) == 6 && newset.acct == st.memory_usage(newset) && db_cur.heap_bytes == newset.acct, "SPOP replacement owns only its six copied survivors")
	mapped, retired, metadata := st.maintenance_memory()
	check(mapped == 24576 && retired == 8192 && metadata > 0, "old SPOP source remains separately retired while remaining target is pending")
	check(mem_used() == mem_startup + newset.acct + remaining + metadata + storage_table_allocated(), "new payload, pending old payload and retired record are charged exactly once")
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 0, .Release)
	settle()
	check(lazyfree_pending_bytes() == 0 && db_cur.heap_bytes == newset.acct, "SPOP worker cleanup leaves only the new live Set")
	audit()
	storage_clear()
}

zset_active_fork :: proc() {
	s := zset_fixture("fork-zset")
	storage_command(cmd_zadd, "ZADD", "fork-zset", "2048", "fork\x00member")
	mapped, _, _ := zt.maintenance_memory()
	cfg.dbfilename = "zset-banks.rdb"
	pid, err := linux.fork()
	check(err == .NONE, "fork with active Zset member migration")
	if pid == 0 {
		persist_child_setup()
		check(persist_rdb_save(), "child persists both Zset banks before migration")
		settle()
		check(s.sl.resize == nil && s.acct == zt.memory_usage(s) && db_cur.heap_bytes == s.acct, "child Zset migration refreshes private owner counters")
		child_score, child_found := zt.score(s, transmute([]u8)string("fork\x00member"))
		check(child_found && child_score == 2048, "child preserves full binary Zset member and score")
		storage_clear()
		linux.exit_group(0)
	}
	deadline := now_ns() + 5_000_000_000
	status: u32
	done := false
	for now_ns() < deadline {
		got, waiterr := linux.waitpid(pid, &status, {.WNOHANG}, nil)
		check(waiterr == .NONE, "poll active Zset child")
		if got == pid {
			done = true
			break
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	if !done {
		linux.kill(pid, .SIGKILL)
		linux.waitpid(pid, &status, {}, nil)
	}
	check(done && status == 0 && s.sl.resize != nil && db_cur.zctx.resize_count == 1, "child completion cannot consume the parent Zset job")
	after, _, _ := zt.maintenance_memory()
	check(after == mapped && db_cur.heap_bytes == s.acct, "child Zset unmaps cannot change parent mapping/accounting snapshots")
	audit()
	storage_clear()
	check(persist_rdb_load(false, false) == .Ok, "reload fork snapshot containing both Zset banks")
	e := db_find(transmute([]u8)string("fork-zset"))
	loaded := zt.Zset(entry_object(e, .Zset))
	loaded_score, loaded_found := zt.score(loaded, transmute([]u8)string("fork\x00member"))
	check(loaded != nil && zt.length(loaded) == 513 && loaded_found && loaded_score == 2048 && loaded.acct == zt.memory_usage(loaded), "normal Zset load retains complete binary data and exact allocation ownership")
	audit()
	storage_clear()
}

set_active_fork :: proc() {
	s := set_fixture("fork-set")
	storage_command(cmd_sadd, "SADD", "fork-set", "fork\x00member")
	mapped, _, _ := st.maintenance_memory()
	cfg.dbfilename = "set-banks.rdb"
	pid, err := linux.fork()
	check(err == .NONE, "fork with active Set member migration")
	if pid == 0 {
		persist_child_setup()
		check(persist_rdb_save(), "child persists both Set banks before migration")
		settle()
		check(s.table.resize == nil && s.acct == st.memory_usage(s) && db_cur.heap_bytes == s.acct, "child Set migration refreshes private owner counters")
		check(st.is_member(s, transmute([]u8)string("fork\x00member")), "child preserves full binary Set member")
		storage_clear()
		linux.exit_group(0)
	}
	deadline := now_ns() + 5_000_000_000
	status: u32
	done := false
	for now_ns() < deadline {
		got, waiterr := linux.waitpid(pid, &status, {.WNOHANG}, nil)
		check(waiterr == .NONE, "poll active Set child")
		if got == pid {
			done = true
			break
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	if !done {
		linux.kill(pid, .SIGKILL)
		linux.waitpid(pid, &status, {}, nil)
	}
	check(done && status == 0 && s.table.resize != nil && db_cur.sctx.resize_count == 1, "child completion cannot consume the parent Set job")
	after, _, _ := st.maintenance_memory()
	check(after == mapped && db_cur.heap_bytes == s.acct, "child Set unmaps cannot change parent mapping/accounting snapshots")
	audit()
	storage_clear()
	check(persist_rdb_load(false, false) == .Ok, "reload fork snapshot containing both Set banks")
	e := db_find(transmute([]u8)string("fork-set"))
	loaded := st.Set(entry_object(e, .Set))
	check(loaded != nil && st.size(loaded) == 257 && st.is_member(loaded, transmute([]u8)string("fork\x00member")) && loaded.acct == st.memory_usage(loaded), "normal Set load retains complete binary data and exact allocation ownership")
	audit()
	storage_clear()
}

storage_sort_banks :: proc() {
	key := transmute([]u8)string("debug-set")
	e := db_find(key)
	s := st.Set(entry_object(e, .Set))
	members: [dynamic]string
	defer delete(members)
	it := st.iterator(s)
	for member in st.next(&it) {
		append(&members, string(member.str))
	}
	slice.sort(members[:])
	expected: [dynamic]u8
	defer delete(expected)
	append(&expected, ..transmute([]u8)fmt.tprintf("*%d\r\n", len(members)))
	for member in members {
		append(&expected, ..transmute([]u8)fmt.tprintf("$%d\r\n", len(member)))
		append(&expected, ..transmute([]u8)member)
		append(&expected, '\r', '\n')
	}
	c := Conn{db = db_cur, resp = 2, wbuf = mem_alloc(WBUF_INIT), wcap = WBUF_INIT}
	defer mem_free(c.wbuf)
	args := [3][]u8{transmute([]u8)string("SORT"), key, transmute([]u8)string("ALPHA")}
	cmd_sort(&c, args[:])
	check(string(c.wbuf[:c.wlen]) == string(expected[:]), "actual SORT ALPHA loads every Set member from both banks")
}

zset_allocator_sample :: proc() {
	baseline := mem_overhead()
	sl := zt.sl_create(512)
	for i in 0 ..< 512 {
		member: [32]u8
		m := transmute([]u8)fmt.bprintf(member[:], "sample:%d", i)
		zt.sl_insert(sl, f64(i), m, zt.hash_member(m))
	}
	zt.dict_resize(sl, 2048)
	for sl.resize != nil {
		zt.dict_step(sl, 64, 4)
	}
	check(zt.maintenance_release(4096) == 4096, "zset sample partially unmaps its known8 KiB retired source")
	mapped, retired, metadata := zt.maintenance_memory()
	check(mapped == 20480 && retired == 4096 && metadata > 0, "zset sample retains one retired page beside owned16 KiB target")
	allocated, rss, libc_allocated := storage_test_memory_sample()
	check(allocated == libc_allocated + 16384 && rss > 0, "allocator sample includes live Node heap and owned zset mappings exactly once")
	overhead := mem_overhead()
	check(overhead.total - baseline.total == metadata && overhead.overhead - baseline.overhead == metadata && overhead.dataset == baseline.dataset && overhead.lut == baseline.lut, "retired zset records change overhead without dataset/LUT double charging")
	zt.sl_free(sl)
	for zt.maintenance_pending() {
		zt.maintenance_release()
	}
	mapped, retired, metadata = zt.maintenance_memory()
	overhead = mem_overhead()
	check(mapped == 0 && retired == 0 && metadata == 0 && overhead.total == baseline.total && overhead.dataset == baseline.dataset, "zset sampled allocation/overhead charges settle exactly")
}

zset_loaded_bind :: proc() {
	z := zset_new_skiplist(512)
	for i in 0 ..< 512 {
		member: [32]u8
		zt.add(z, f64(i), transmute([]u8)fmt.bprintf(member[:], "loaded:%d", i), {})
	}
	zt.dict_resize(z.sl, 2048)
	check(z.sl.resize.reg == nil, "clamped-load fixture has an unbound two-bank Zset")
	key := transmute([]u8)string("loaded-zset")
	e, _ := db_upsert(key)
	persist_attach(e, key, Loaded_Value{type = .Zset, obj = z})
	check(z.sl.resize.reg == db_cur.zctx && db_cur.zctx.resize_count == 1 && z.acct == zt.memory_usage(z) && db_cur.heap_bytes == z.acct, "shared load/RESTORE attach binds Zset maintenance and actual allocation ownership")
	settle()
	check(z.sl.resize == nil && z.acct == zt.memory_usage(z) && db_cur.heap_bytes == z.acct, "loaded Zset progresses with refreshed owner accounting")
	audit()
	storage_clear()
}

storage_capture :: proc(handler: Command_Proc, protocol: u8, values: ..string) -> []u8 {
	c := Conn{db = db_cur, resp = protocol, wbuf = mem_alloc(WBUF_INIT), wcap = WBUF_INIT}
	defer mem_free(c.wbuf)
	args := make([][]u8, len(values))
	defer delete(args)
	for value, i in values {
		args[i] = transmute([]u8)value
	}
	handler(&c, args)
	copy := mem_alloc(c.wlen)
	intrinsics.mem_copy_non_overlapping(copy, c.wbuf, c.wlen)
	return copy[:c.wlen]
}

zset_commands :: proc() {
	a := zset_fixture("za")
	zset_fixture("zb")
	member := transmute([]u8)string("member:100")
	node := zt.dict_find(a.sl, member, zt.hash_member(member))
	storage_command(cmd_zincrby, "ZINCRBY", "za", "0.5", "member:100")
	check(zt.dict_find(a.sl, member, node.hash) == node && node.score == 100.5 && a.acct == zt.memory_usage(a), "actual score update preserves Node identity and allocation owner")
	storage_command(cmd_copy, "COPY", "za", "zc")
	storage_command(cmd_zunionstore, "ZUNIONSTORE", "za", "2", "za", "zb")
	e := db_find(transmute([]u8)string("za"))
	a = zt.Zset(entry_object(e, .Zset))
	score, found := zt.score(a, member)
	check(zt.length(a) == 512 && found && score == 200.5 && a.acct == zt.memory_usage(a), "ZUNIONSTORE destination=input keeps exact member scores before replacement")
	storage_command(cmd_zinterstore, "ZINTERSTORE", "zb", "2", "zb", "za", "WEIGHTS", "2", "0.5", "AGGREGATE", "MAX")
	e = db_find(transmute([]u8)string("zb"))
	bb := zt.Zset(entry_object(e, .Zset))
	score, found = zt.score(bb, member)
	check(zt.length(bb) == 512 && found && score == 200 && bb.acct == zt.memory_usage(bb), "ZINTERSTORE weighted aliasing preserves aggregation and owner accounting")
	storage_command(cmd_zdiffstore, "ZDIFFSTORE", "za", "2", "za", "zc")
	check(db_find(transmute([]u8)string("za")) == nil, "ZDIFFSTORE destination=input deletes an empty independent result")
	storage_command(cmd_zrangestore, "ZRANGESTORE", "zb", "zb", "4", "34")
	e = db_find(transmute([]u8)string("zb"))
	bb = zt.Zset(entry_object(e, .Zset))
	score, found = zt.score(bb, transmute([]u8)string("member:4"))
	check(zt.length(bb) == 31 && found && score == 8 && bb.acct == zt.memory_usage(bb), "ZRANGESTORE copies borrowed input before alias replacement")
	audit()
	storage_clear()
	pop := zset_fixture("pop-zset")
	storage_command(cmd_zadd, "ZADD", "pop-zset", "-1000", "binary\x00min", "100000", "binary\x00max")
	response := storage_capture(cmd_zpopmin, 2, "ZPOPMIN", "pop-zset")
	check(string(response) == "*2\r\n$10\r\nbinary\x00min\r\n$5\r\n-1000\r\n", "ZPOPMIN copies full binary bytes and score before freeing the Node")
	mem_free(raw_data(response))
	response = storage_capture(cmd_zpopmax, 2, "ZPOPMAX", "pop-zset")
	check(string(response) == "*2\r\n$10\r\nbinary\x00max\r\n$6\r\n100000\r\n", "ZPOPMAX copies full binary bytes and score before freeing the Node")
	mem_free(raw_data(response))
	check(zt.length(pop) == 512 && pop.acct == zt.memory_usage(pop), "endpoint pops refresh the live Zset allocation owner")
	audit()
	storage_clear()
}

zset_sort_debug :: proc() {
	z := zset_fixture("debug-zset")
	zt.dict_step(z.sl, 64, 4)
	cursor := z.sl.resize.cursor
	counts: [2][]int
	tombs := 0
	members: [dynamic]string
	for bank in 0 ..< 2 {
		slots, cap := zt.dict_bank(z.sl, 1 - bank)
		counts[bank] = make([]int, cap)
		for i in 0 ..< cap {
			if uintptr(slots[i]) > 1 {
				counts[bank][slots[i].hash & u64(cap - 1)] += 1
				append(&members, string(zt.node_member(slots[i])))
			} else {
				tombs += int(uintptr(slots[i]) == 1)
			}
		}
	}
	check(tombs == 4 && len(members) == 512, "Zset diagnostic fixture has both live banks and source tombstones")
	storage_debug_banks("debug-zset", counts[0], counts[1], 512)
	slice.sort(members[:])
	expected: [dynamic]u8
	append(&expected, ..transmute([]u8)string("*512\r\n"))
	for member in members {
		append(&expected, ..transmute([]u8)fmt.tprintf("$%d\r\n", len(member)))
		append(&expected, ..transmute([]u8)member)
		append(&expected, '\r', '\n')
	}
	response := storage_capture(cmd_sort, 2, "SORT", "debug-zset", "ALPHA")
	check(string(response) == string(expected[:]), "SORT ALPHA loads full Zset input from both dictionary banks")
	mem_free(raw_data(response))
	clear(&expected)
	append(&expected, ..transmute([]u8)string("*7\r\n"))
	for i in 0 ..< 7 {
		member := fmt.tprintf("member:%d", 508 - i)
		append(&expected, ..transmute([]u8)fmt.tprintf("$%d\r\n%s\r\n", len(member), member))
	}
	response = storage_capture(cmd_sort, 2, "SORT", "debug-zset", "BY", "nosort", "DESC", "LIMIT", "3", "7")
	check(string(response) == string(expected[:]), "SORT dontsort retains ordered/rank fast path during dictionary migration")
	mem_free(raw_data(response))
	check(z.sl.resize.cursor == cursor, "SORT and DEBUG never force a Zset dictionary drain")
	delete(expected)
	delete(members)
	delete(counts[0])
	delete(counts[1])
	audit()
	storage_clear()
}

zset_geo_alias :: proc() {
	old_limit := zt.zset_max_listpack_entries
	zt.zset_max_listpack_entries = 0
	storage_command(cmd_geoadd, "GEOADD", "geo", "13.361389", "38.115556", "Palermo", "15.087269", "37.502669", "Catania")
	e := db_find(transmute([]u8)string("geo"))
	z := zt.Zset(entry_object(e, .Zset))
	zt.dict_resize(z.sl, z.sl.cap * 2)
	score, found := zt.score(z, transmute([]u8)string("Palermo"))
	check(found, "GEO fixture retains its canonical coordinate score")
	storage_command(cmd_zadd, "ZADD", "geo", fmt.tprintf("%.0f", score), "Palermo")
	check(z.sl.resize != nil && z.sl.resize.reg == db_cur.zctx && z.acct == zt.memory_usage(z), "GEO-backed Zset binds active index ownership")
	storage_command(cmd_geosearchstore, "GEOSEARCHSTORE", "geo", "geo", "FROMLONLAT", "13.361389", "38.115556", "BYRADIUS", "200", "km")
	e = db_find(transmute([]u8)string("geo"))
	stored := zt.Zset(entry_object(e, .Zset))
	newscore, kept := zt.score(stored, transmute([]u8)string("Palermo"))
	check(zt.length(stored) == 2 && kept && newscore == score && stored.acct == zt.memory_usage(stored), "GEO store destination=input preserves coordinate scores and refreshed owner")
	zt.zset_max_listpack_entries = old_limit
	audit()
	storage_clear()
}

zset_union_attach :: proc() {
	for which in 0 ..< 2 {
		n := 96 if which == 0 else 98
		key := "source-a" if which == 0 else "source-b"
		z := zset_new_skiplist(n)
		for i in 0 ..< n {
			member: [32]u8
			zt.add(z, f64(i), transmute([]u8)fmt.bprintf(member[:], "%d:%d", which, i), {})
		}
		e, _ := db_upsert(transmute([]u8)key)
		zset_copy_attach(e, transmute([]u8)key, z, 0)
	}
	storage_command(cmd_zunionstore, "ZUNIONSTORE", "built-union", "2", "source-a", "source-b")
	e := db_find(transmute([]u8)string("built-union"))
	z := zt.Zset(entry_object(e, .Zset))
	check(z.sl.count == 194 && z.sl.length == 194 && z.sl.resize != nil && z.sl.resize.reg == db_cur.zctx && z.acct == zt.memory_usage(z), "dictionary-first ZUNION final result attaches its still-active owner context")
	before := z.acct
	settle()
	score, found := zt.score(z, transmute([]u8)string("1:97"))
	check(z.sl.resize == nil && z.acct < before && z.acct == zt.memory_usage(z) && found && score == 97, "attached ZUNION result completes through real idle callbacks without losing Nodes")
	audit()
	storage_clear()
}

main :: proc() {
	if len(os.args) == 3 && os.args[1] == "invalid" {
		capacity, ok := strconv.parse_int(os.args[2])
		check(ok, "parse invalid-capacity fixture")
		table_alloc(capacity)
		os.exit(2)
	}
	config_init()
	update_clock()
	db_init()
	srv.epfd, _ = linux.epoll_create1({.FDCLOEXEC})
	mem_init()
	fmt.printfln("storage layouts: Db sizeof=%d array requested/usable=%d/%d Zset Context16 requested/usable=%d/%d", size_of(Db), db_count * size_of(Db), lp.lp_malloc_size(raw_data(dbs)), db_count * size_of(zt.Context), lp.lp_malloc_size(dbs[0].zctx))
	fixed_block, slab_block := mem_alloc(480), mem_alloc(size_of(Slab))
	fmt.printfln("slab layouts: fixed/slab requested=480/%d usable=%d/%d record=%d control_alignment=%d", size_of(Slab), lp.lp_malloc_size(fixed_block), lp.lp_malloc_size(slab_block), size_of(Slab_Record), align_of(Slab_Record))
	mem_free(fixed_block)
	mem_free(slab_block)
	check(storage_table_allocated() == 0 && storage_slab_virtual == 0, "fresh databases allocate no table or slab mapping")
	hash_allocator_sample()
	set_allocator_sample()
	zset_allocator_sample()
	inline_tables()
	slab_churn()
	slab_expected()
	slab_zero_pressure()
	slab_eviction_progress()
	slab_metadata_sample()
	slab_worker_metadata()
	slab_swap_move()
	slab_fork_reclaim()
	pressure_policy_compaction()
	pressure_compaction_bounds()
	deferred()
	retired()
	composite_dead()
	hash_ownership()
	hash_worker_generation_reuse()
	set_ownership()
	set_commands()
	set_loaded_bind()
	set_hash_debug()
	set_worker_generation_reuse()
	set_spop_pending()
	set_active_fork()
	set_fork_pending_worker()
	zset_ownership()
	zset_loaded_bind()
	zset_worker_generation_reuse()
	zset_commands()
	zset_union_attach()
	zset_sort_debug()
	zset_geo_alias()
	zset_active_fork()
	zset_fork_pending_worker()
	eviction()
	fork_ownership()
	fork_pending_worker()
	srv.now_ms += MEM_SAMPLE_MS + 1
	mem_cron()
	check(mem_overhead().allocated > 0 && mem_overhead().rss > 0, "allocator and process samples available separately")
	check(intrinsics.atomic_load_explicit(&storage_table_bytes, .Relaxed) == 0, "final table ownership empty")
	fmt.printf("PASS storage ownership checks=%d slab_bytes=%d\n", checks, size_of(Slab))
}

slab_zero_pressure :: proc() {
	value: [96]u8
	bigger: [512]u8
	heap: [5000]u8
	for &v in heap {
		v = 'H'
	}
	put("a", "b")
	put(string(heap[:]), string(heap[:]))
	storage_command(cmd_hset, "HSET", "h", "field", "value")
	put("s", string(value[:]))
	base := db_cur.slab.base
	top := db_cur.slab.top
	put("s", string(bigger[:]))
	check(db_cur.slab.base == base && db_cur.slab.top == top && slab_zero_slabs == 0, "last-value replacement cancels zero retirement and reuses its whole run across classes")
	db_remove(transmute([]u8)string("s"))
	check(db_cur.slab.live == 0 && db_size() == 3 && slab_zero_slabs == 1 && storage_metadata_owned == 4096, "zero slab owner remains distinct from inline, heap-key/string and object entries")
	for _ in 0 ..< GRAVEYARD_MAX {
		t := table_alloc(65536)
		check(t.size > RELEASE_NOW_BYTES, "admission fixture uses actual deferred table mappings")
		table_detach(&t)
	}
	check(graveyard_len == GRAVEYARD_MAX, "actual graveyard reaches its finite admission capacity")
	work := slab_reclaim(now_ns() + 1_000_000_000, true)
	check(work.retired == 0 && db_cur.slab.base == base && storage_metadata_owned == 4096 && slab_zero_slabs == 1, "full graveyard defers zero ownership without whole-prefix fallback unmap")
	for graveyard_len == GRAVEYARD_MAX {
		storage_test_release_chunk()
	}
	before := mem_overhead()
	evicted := stat_evicted_keys
	old_policy := maxmemory_policy
	maxmemory_policy = .Noeviction
	maxmemory_bytes = u64(mem_used() - 4096)
	check(perform_evictions() == .Ok, "bounded cold maxmemory hook releases zero metadata before noeviction failure")
	maxmemory_bytes = 0
	maxmemory_policy = old_policy
	after := mem_overhead()
	check(before.total - after.total == 4096 && before.overhead - after.overhead == 4096 && before.dataset == after.dataset && before.lut == after.lut, "zero metadata leaves allocation and overhead exactly once without changing dataset or table ownership")
	check(db_cur.slab.base == nil && db_cur.slab.runs == nil && storage_metadata_owned == 0 && storage_retired[.Slab] == SLAB_COMMIT_STEP && stat_evicted_keys == evicted, "pressure transfers one payload prefix without evicting unrelated live keys")
	check(string(db_find(transmute([]u8)string("a")).val) == "b" && string(db_find(heap[:]).val) == string(heap[:]), "inline and independent heap key/string survive slab retirement")
	storage_command(cmd_hget, "HGET", "h", "field")
	put("s", string(value[:]))
	check(db_cur.slab.base != nil && db_cur.slab.live == 96 && storage_metadata_owned == 4096, "a later slab value starts a fresh allocator owner")
	storage_clear()
}

slab_eviction_progress :: proc() {
	value: [96]u8
	heap: [5000]u8
	put("i", "ok")
	put("heap", string(heap[:]))
	storage_command(cmd_hset, "HSET", "h", "field", "value")
	put("victim", string(value[:]))
	entry_set_expire(db_find(transmute([]u8)string("victim")), srv.now_ms + 60000)
	check(slab_zero_slabs == 0 && db_cur.slab.live == 96, "eviction starts with a real live slab owner")
	old_policy := maxmemory_policy
	maxmemory_policy = .Volatile_Ttl
	old_timer := evict_timer
	evict_timer = false
	maxmemory_bytes = u64(mem_used() - 4096)
	evicted := stat_evicted_keys
	result := perform_evictions()
	over, _ := memory_state_over()
	check(result == .Ok && !over, "same bounded pressure credit reclaims metadata when eviction itself frees the final cell")
	maxmemory_bytes = 0
	maxmemory_policy = old_policy
	evict_timer = old_timer
	check(stat_evicted_keys == evicted + 1 && db_size() == 3 && db_cur.slab.base == nil && storage_metadata_owned == 0, "only the eligible last slab key is evicted and zero metadata makes progress")
	check(db_find(transmute([]u8)string("i")) != nil && db_find(transmute([]u8)string("heap")) != nil && db_find(transmute([]u8)string("h")) != nil, "inline, heap and object keys survive last-cell eviction reclaim")
	storage_clear()
}

slab_metadata_sample :: proc() {
	baseline := mem_overhead()
	off := slab_alloc(&db_cur.slab, 4096)
	slab_metadata_commit(&db_cur.slab, SLAB_RUN_COUNT - 1)
	meta := SLAB_METADATA_RESERVE
	allocated, _, libc_allocated := storage_test_memory_sample()
	check(allocated == libc_allocated + meta + 4096, "allocator sample charges only real owned metadata prefix and live slab cells")
	owned := mem_overhead()
	check(owned.total - baseline.total == meta + 4096 && owned.overhead - baseline.overhead == meta && owned.dataset - baseline.dataset == 4096 && owned.lut == baseline.lut, "metadata is exact allocator overhead rather than dataset or keyspace table capacity")
	slab_free(&db_cur.slab, off, 4096)
	work := slab_reclaim(now_ns() + 1_000_000_000, true)
	m := mem_storage()
	check(work.retired == 1 && m.metadata_owned == 0 && m.metadata_retired == meta && m.metadata_virtual == meta && m.metadata_writable == meta, "logically released metadata remains physically mapped and retired")
	allocated, _, libc_allocated = storage_test_memory_sample()
	check(allocated == libc_allocated && mem_used() == baseline.total && mem_overhead().overhead == baseline.overhead, "retired metadata is excluded from allocation samples and maxmemory exactly once")
	for storage_retired[.Slab] > 0 {
		storage_test_release_chunk()
	}
	storage_test_release_chunk()
	m = mem_storage()
	check(m.metadata_retired == meta - RELEASE_CHUNK && m.metadata_virtual == meta - RELEASE_CHUNK && m.metadata_writable == meta - RELEASE_CHUNK && m.metadata_owned == 0, "partial metadata release removes only the actual unmapped chunk")
	storage_clear()
}

slab_worker_metadata :: proc() {
	value: [96]u8
	heap: [5000]u8
	put("slab-worker-key", string(value[:]))
	put("heap-worker-key", string(heap[:]))
	payload := db_cur.heap_bytes + db_cur.slab.live
	old_table := mem_db_overhead(db_cur)
	check(storage_metadata_owned == 4096 && storage_metadata_virtual == SLAB_METADATA_RESERVE, "old database has one real metadata owner")
	intrinsics.atomic_store_explicit(&storage_test_worker_entered, 0, .Release)
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 1, .Release)
	db_flush_in(db_cur, true)
	deadline := now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 0 && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(intrinsics.atomic_load_explicit(&storage_test_worker_entered, .Acquire) == 1 && lazyfree_pending_bytes() == payload, "real paused whole-Db worker retains only payload ownership")
	check(storage_metadata_owned == 0 && storage_metadata_virtual == 0 && storage_metadata_writable == 0 && !slab_reclaim_pending(), "main thread releases old descriptors before publishing the detached database worker")
	put("new-worker-slab-key", string(value[:]))
	new_live := db_cur.slab.live
	new_base := db_cur.slab.base
	check(storage_metadata_owned == 4096 && storage_slab_virtual == SLAB_RESERVE + SLAB_COMMIT_STEP && storage_table_allocated() == old_table + mem_db_overhead(db_cur), "new owner is distinct from the paused old writable payload prefix and table")
	intrinsics.atomic_store_explicit(&storage_test_worker_pause, 0, .Release)
	deadline = now_ns() + 2_000_000_000
	for !storage_test_worker_idle() && now_ns() < deadline {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	check(storage_test_worker_idle() && lazyfree_pending_bytes() == 0 && storage_slab_virtual == SLAB_RESERVE, "actual worker releases only detached payload mappings without descriptors")
	check(db_cur.slab.base == new_base && db_cur.slab.live == new_live && storage_metadata_owned == 4096 && storage_metadata_virtual == SLAB_METADATA_RESERVE && db_used_memory == new_live, "old worker cannot mutate new slab descriptors or ownership")
	check(string(db_find(transmute([]u8)string("new-worker-slab-key")).val) == string(value[:]), "new allocator bytes survive old worker destruction")
	storage_clear()
}

slab_swap_move :: proc() {
	value: [96]u8
	for &v in value {
		v = 0x61
	}
	put("owner", string(value[:]))
	other := slab_alloc(&db_cur.slab, 4096)
	slab_free(&db_cur.slab, other, 4096)
	base := db_cur.slab.base
	metadata := db_cur.slab.runs
	dirty := slab_dirty_runs
	db_swap(0, 1)
	check(dbs[1].slab.base == base && dbs[1].slab.runs == metadata && dbs[0].slab.base == nil && slab_dirty_runs == dirty, "SWAPDB transfers owner-relative run queues and metadata in constant bookkeeping")
	db_cur = &dbs[1]
	storage_command(cmd_copy, "COPY", "owner", "copied", "DB", "0")
	check(db_move(&dbs[1], &dbs[0], transmute([]u8)string("owner")), "MOVE copies live slab bytes to an independent destination allocator")
	check(dbs[1].slab.live == 0 && slab_zero_slabs == 1 && dbs[0].slab.runs != metadata, "moving the last source cell queues only the source owner")
	db_cur = &dbs[0]
	storage_command(cmd_rename, "RENAME", "owner", "renamed")
	check(string(db_find(transmute([]u8)string("renamed")).val) == string(value[:]) && string(db_find(transmute([]u8)string("copied")).val) == string(value[:]), "COPY/MOVE/RENAME preserve independent slab values")
	slab_reclaim_next = 0
	slab_reclaim(now_ns() + 1_000_000_000)
	check(dbs[1].slab.base == nil && dbs[0].slab.base != nil && slab_zero_slabs == 0, "post-swap zero work retires the actual current source owner")
	audit()
	storage_clear()
}

slab_fork_reclaim :: proc() {
	value: [64]u8
	keeper: [96]u8
	replacement: [512]u8
	for &v in value {
		v = 0x44
	}
	for &v in replacement {
		v = 0x4E
	}
	put("keep", string(keeper[:]))
	put("dead", string(value[:]))
	e := db_find(transmute([]u8)string("dead"))
	old_run := e.vp.slab.offset >> SLAB_RUN_SHIFT
	old_metadata := db_cur.slab.runs
	before := mem_storage()
	pipes: [2]linux.Fd
	check(linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK}) == .NONE, "create deterministic slab persistence COW ordering pipe")
	cfg.dbfilename = "slab-reclaim.rdb"
	pid, err := linux.fork()
	check(err == .NONE, "fork the actual live slab keyspace before parent reclaim")
	if pid == 0 {
		linux.close(pipes[1])
		deadline := now_ns() + 5_000_000_000
		token: [1]u8
		got := false
		for now_ns() < deadline {
			n, rerr := linux.read(pipes[0], token[:])
			if n == 1 {
				got = true
				break
			}
			check(rerr == .EAGAIN || rerr == .EINTR, "child slab persistence ordering pipe remains valid")
			ts := linux.Time_Spec{time_nsec = 100_000}
			linux.nanosleep(&ts, nil)
		}
		check(got && old_metadata[old_run].node.class == u8(slab_class(64)), "parent advice and class reassignment preserve the child metadata snapshot")
		check(string(db_find(transmute([]u8)string("dead")).val) == string(value[:]) && string(db_find(transmute([]u8)string("keep")).val) == string(keeper[:]), "child live values survive parent DONTNEED and reuse")
		check(mem_storage().metadata_owned == before.metadata_owned, "parent slab changes cannot decrement child metadata ownership")
		persist_child_setup()
		check(persist_rdb_save(), "child persists the unchanged slab bytes after parent reclaim")
		linux.exit_group(0)
	}
	linux.close(pipes[0])
	db_remove(transmute([]u8)string("dead"))
	slab_reclaim_next = 0
	work := slab_reclaim(now_ns() + 1_000_000_000)
	check(work.advised == 1 && work.retired == 0, "parent advises only the empty run while another value remains live")
	put("new", string(replacement[:]))
	check(db_cur.slab.runs == old_metadata && old_metadata[old_run].node.class == u8(slab_class(512)), "parent reassigns the same clean run across classes after fork")
	token := [1]u8{1}
	n, werr := linux.write(pipes[1], token[:])
	check(n == 1 && werr == .NONE, "parent signals completed slab reclaim/reuse to persistence child")
	linux.close(pipes[1])
	deadline := now_ns() + 5_000_000_000
	status: u32
	done := false
	for now_ns() < deadline {
		got, waiterr := linux.waitpid(pid, &status, {.WNOHANG}, nil)
		check(waiterr == .NONE, "poll slab persistence child")
		if got == pid {
			done = true
			break
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	if !done {
		linux.kill(pid, .SIGKILL)
		linux.waitpid(pid, &status, {}, nil)
	}
	check(done && status == 0 && db_cur.slab.runs == old_metadata && mem_storage().metadata_owned == before.metadata_owned, "child persistence cannot change parent descriptors or ownership")
	check(string(db_find(transmute([]u8)string("new")).val) == string(replacement[:]), "parent new bytes survive child snapshot persistence")
	storage_clear()
	check(persist_rdb_load(false, false) == .Ok, "reload actual slab reclaim fork snapshot")
	check(db_size() == 2 && string(db_find(transmute([]u8)string("dead")).val) == string(value[:]) && string(db_find(transmute([]u8)string("keep")).val) == string(keeper[:]), "reloaded child snapshot contains the saved bytes and keys")
	storage_clear()
}

pressure_policy_compaction :: proc() {
	old_policy := maxmemory_policy
	old_timer := evict_timer
	for policy in ([?]Evict_Policy{.Volatile_Lru, .Volatile_Lfu, .Volatile_Random, .Volatile_Ttl}) {
		base := mem_used()
		maxmemory_bytes = 1 << 30
		maxmemory_policy = policy
		evict_policy_changed()
		evict_timer = false
		buf: [32]u8
		for i in 0 ..= 1792 {
			e, _ := db_upsert(transmute([]u8)fmt.bprintf(buf[:], "key:%d", i))
			entry_assign(e, transmute([]u8)string("x"))
			if i % 2 != 0 {
				entry_set_expire(e, srv.now_ms + 10_000_000)
			}
		}
		settle()
		before := mem_storage()
		check(db_size() == 1793 && db_cur.expires == 896 && db_cur.t[0].cap == 4096 && before.table_allocated == 102400, "mixed policy fixture owns known page-rounded4096-slot table")
		check(before.slab_live == 6344 && before.metadata_owned == 4096, "mixed protected/volatile long keys and real metadata have independent expected bytes")
		maxmemory_bytes = u64(base + 100 * 1024)
		initial := mem_used()
		peak := initial
		started := false
		for _ in 0 ..< 128 {
			perform_evictions()
			peak = max(peak, mem_used())
			if db_cur.rehash_idx >= 0 && db_cur.t[1].cap < db_cur.t[0].cap {
				started = true
				break
			}
		}
		check(started && db_cur.expires == 0 && db_size() == 897 && db_cur.t[0].cap == 4096 && db_cur.t[1].cap == 2048, "exhausted volatile eviction admits exactly one level without removing protected keys")
		coexist := mem_storage()
		check(coexist.table_allocated == 155648 && coexist.slab_live == 3176 && coexist.metadata_owned == 4096, "temporary old-plus-target allocation is fully charged while metadata stays truthful")
		check(mem_used() == base + 155648 + 3176 + 4096 && mem_used() > int(maxmemory_bytes), "coexisting banks remain genuinely over limit rather than reporting early success")
		maxmemory_policy = .Noeviction
		check(perform_evictions() == .Fail && db_cur.rehash_idx >= 0, "Noeviction does not allow an over-limit write while compaction remains partial")
		maxmemory_policy = policy
		steps := 0
		for db_cur.rehash_idx >= 0 && steps < 128 {
			left, cursor := db_cur.t[0].live, db_cur.rehash_idx
			work := db_pressure_shrink(now_ns() + 1_000_000_000)
			check(work.visited <= 16 && work.admitted_bytes == 0, "existing pressure migration uses bounded visits without allocating another target")
			if db_cur.rehash_idx >= 0 {
				check(left - db_cur.t[0].live <= 64 && db_cur.rehash_idx - cursor <= 16 && (db_cur.t[0].live < left || db_cur.rehash_idx > cursor), "incremental large-source pressure grant advances within64moves/16groups")
			} else {
				check(left <= 64, "final incremental pressure grant completes only its remaining move allowance")
			}
			peak = max(peak, mem_used())
			steps += 1
		}
		after := mem_storage()
		check(db_cur.rehash_idx < 0 && db_cur.t[0].cap == 2048 && after.table_allocated == 53248 && before.table_allocated - after.table_allocated == 49152, "actual table allocation falls by49152bytes after bounded progress")
		check(after.slab_live == 3176 && after.metadata_owned == 4096 && mem_used() == base + 60520 && perform_evictions() == .Ok, "only actual net allocation reduction resolves memory pressure")
		for i := 0; i <= 1792; i += 2 {
			e := db_find(transmute([]u8)fmt.bprintf(buf[:], "key:%d", i))
			check(e != nil && string(e.val) == "x" && e.expire_at == 0, "every protected key survives each volatile policy")
		}
		for i in 0 ..< 256 {
			check(perform_evictions() != .Fail, "actual released capacity permits subsequent volatile writes")
			e, _ := db_upsert(transmute([]u8)fmt.bprintf(buf[:], "foo:%d", i))
			entry_assign(e, transmute([]u8)string("x"))
			entry_set_expire(e, srv.now_ms + 10_000_000)
		}
		check(db_size() == 1153 && db_cur.expires == 256 && storage_metadata_owned == 4096, "new volatile data is kept while all protected data and metadata remain")
		fmt.printfln("pressure policy=%s base=%d initial=%d coexist_peak=%d final_before_new=%d table_before/after=%d/%d protected=897 new_volatile=256 metadata=%d steps=%d", EVICT_POLICY_NAMES[policy], base, initial, peak, base + 60520, before.table_allocated, after.table_allocated, after.metadata_owned, steps)
		storage_clear()
	}
	maxmemory_policy = old_policy
	evict_policy_changed()
	evict_timer = old_timer
}

pressure_compaction_bounds :: proc() {
	buf: [32]u8
	db_cur.t[0] = table_alloc(1024)
	for i in 0 ..< 128 {
		put(fmt.bprintf(buf[:], "k%d", i), "x")
	}
	maxmemory_bytes = u64(mem_used() - 1)
	pressure_db_next = 0
	work := db_pressure_shrink(now_ns() + 1_000_000_000)
	check(work.admitted_bytes == 16384 && db_cur.t[0].cap == 512 && db_cur.rehash_idx < 0 && db_size() == 128, "existing oldcap1024 synchronous exception completes128live moves without raising the ceiling")
	storage_clear()
	db_cur.t[0] = table_alloc(128)
	put("same", "page")
	maxmemory_bytes = u64(mem_used() - 1)
	work = db_pressure_shrink(now_ns() + 1_000_000_000)
	check(work.admitted_bytes == 0 && db_cur.t[0].cap == 128 && db_cur.rehash_idx < 0, "same-page half capacity with no allocation saving is rejected")
	storage_clear()
	db_cur.t[0] = table_alloc(131072)
	put("large", "kept")
	maxmemory_bytes = u64(mem_used() - 1)
	work = db_pressure_shrink(now_ns() + 1_000_000_000)
	check(work.admitted_bytes == 0 && db_cur.t[0].cap == 131072 && db_cur.rehash_idx < 0, "oversized target/source is not admitted under pressure")
	storage_clear()
	db_cur.t[0] = table_alloc(4096)
	put("small", "kept")
	maxmemory_bytes = u64(mem_used() - 1)
	dict_resizing = false
	work = db_pressure_shrink(now_ns() + 1_000_000_000)
	check(work.admitted_bytes == 0 && db_cur.t[0].cap == 4096 && db_cur.rehash_idx < 0, "disabled dictionary resizing prevents new pressure banks")
	dict_resizing = true
	work = db_pressure_shrink(1)
	check(work.visited == 0 && work.admitted_bytes == 0 && db_cur.rehash_idx < 0, "expired pressure deadline starts no visit or allocation")
	maxmemory_bytes = 0
	work = db_pressure_shrink(now_ns() + 1_000_000_000)
	check(work.visited == 0 && work.admitted_bytes == 0 && db_cur.rehash_idx < 0, "no real maxmemory pressure means no cold shrink admission")
	storage_clear()
	maxmemory_bytes = 1 << 30
	for i in 0 ..= 1792 {
		put(fmt.bprintf(buf[:], "g%d", i), "x")
	}
	check(db_cur.rehash_idx >= 0 && db_cur.t[1].cap > db_cur.t[0].cap, "active grow guard uses a real foreground-started migration")
	maxmemory_bytes = u64(mem_used() - 1)
	left, active := db_cur.t[0].live, db_cur.t[1].region
	work = db_pressure_shrink(now_ns() + 1_000_000_000)
	check(work.admitted_bytes == 0 && db_cur.t[1].region == active && db_cur.t[0].live == left, "active grow banks are preserved without nested allocation or pressure drain")
	storage_clear()
	db_cur.t[0] = table_alloc(4096)
	for i in 0 ..< 3073 {
		put(fmt.bprintf(buf[:], "p%d", i), "x")
	}
	check(db_cur.next.region != nil, "prepared-next guard uses an actual foreground preparation")
	for i in 0 ..< 2173 {
		db_remove(transmute([]u8)fmt.bprintf(buf[:], "p%d", i))
	}
	next := db_cur.next.region
	maxmemory_bytes = u64(mem_used() - 1)
	work = db_pressure_shrink(now_ns() + 1_000_000_000)
	check(work.admitted_bytes == 0 && db_cur.next.region == next && db_cur.t[0].live == 900 && db_cur.rehash_idx < 0, "pressure helper preserves existing prepared ownership without a drop fallback")
	storage_clear()
	db_cur.t[0] = table_alloc(65536)
	put("hold", "kept")
	for _ in 0 ..< GRAVEYARD_MAX {
		t := table_alloc(65536)
		table_detach(&t)
	}
	queued := storage_retired[.Table]
	check(graveyard_len == GRAVEYARD_MAX && queued == GRAVEYARD_MAX * 1638400, "full graveyard fixture owns actual bounded deferred regions")
	maxmemory_bytes = u64(mem_used() - 1)
	pressure_db_next = 0
	work = db_pressure_shrink(now_ns() + 1_000_000_000)
	check(work.admitted_bytes == 819200, "largest admitted half bank requests819200bytes below1MiB")
	for _ in 0 ..< 512 {
		if db_cur.rehash_idx < 0 {
			break
		}
		work = db_pressure_shrink(now_ns() + 1_000_000_000)
		check(work.admitted_bytes == 0 && work.visited <= 16, "full-queue migration progresses without another allocation")
	}
	check(db_cur.rehash_idx < 0 && db_cur.t[0].cap == 32768 && storage_table_allocated() == 819200 && graveyard_len == GRAVEYARD_MAX && storage_retired[.Table] == queued, "existing queue-full fallback releases only bounded1638400byte source at completion")
	check(string(db_find(transmute([]u8)string("hold")).val) == "kept", "full-queue bounded release preserves the moved key")
	storage_clear()
}

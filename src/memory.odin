package main

import "base:intrinsics"
import "base:runtime"
import lr "lua_runtime"
import ht "hashtype"
import st "settype"
import zt "zsettype"

foreign import libc_mem "system:c"

@(private = "file")
Mallinfo2 :: struct {
	arena:    uint,
	ordblks:  uint,
	smblks:   uint,
	hblks:    uint,
	hblkhd:   uint,
	usmblks:  uint,
	fsmblks:  uint,
	uordblks: uint,
	fordblks: uint,
	keepcost: uint,
}

@(private = "file")
@(default_calling_convention = "c")
foreign libc_mem {
	mallinfo2 :: proc() -> Mallinfo2 ---
	malloc_trim :: proc(pad: uint) -> i32 ---
	sysconf :: proc(name: i32) -> i64 ---
	snprintf :: proc(buf: [^]u8, size: uint, format: cstring, #c_vararg args: ..any) -> i32 ---
}

MEM_ALLOCATOR :: "libc"
MEM_SAMPLE_MS :: 100
MEM_DOCTOR_EMPTY :: 5 * 1024 * 1024
MEM_DOCTOR_BIG_BYTES :: 10 << 20
MEM_DOCTOR_CLIENT_AVG :: 200 * 1024
SC_PAGESIZE :: 30
SC_PHYS_PAGES :: 85

mem_startup: int
conn_mem: int
tx_mem_total: int
mem_peak: int
mem_system: i64

@(private = "file")
mem_sample_rss: i64
@(private = "file")
mem_sample_used: int
@(private = "file")
mem_sample_ms: i64
@(private = "file")
mem_sample_allocated: int

Mem_Overhead :: struct {
	total:         int,
	startup:       int,
	peak:          int,
	clients:       int,
	aof:           int,
	lut:           int,
	rehashing:     int,
	rehash_count:  int,
	overhead:      int,
	keys:          int,
	dataset:       int,
	bytes_per_key: int,
	dataset_perc:  f32,
	peak_perc:     f32,
	frag:          f32,
	frag_bytes:    i64,
	rss:           i64,
	sampled_used:  int,
	allocated:     int,
}

Storage_Memory :: struct {
	table_allocated: int,
	table_mapped: int,
	table_retired: int,
	slab_virtual: int,
	slab_writable: int,
	slab_retired: int,
	slab_live: int,
	slab_capacity: int,
	slab_reusable: int,
	slab_bump: int,
	slab_free: int,
	slab_tail: int,
	slab_sentinel: int,
	slab_ahead: int,
	slab_empty: int,
	slab_dirty: int,
	slab_clean: int,
	metadata_owned: int,
	metadata_virtual: int,
	metadata_writable: int,
	metadata_retired: int,
	dead_payload: int,
	lazy_payload: int,
	lazy_slab_live: int,
}

mem_storage :: proc "contextless" () -> (m: Storage_Memory) {
	m.table_allocated = storage_table_allocated()
	m.table_mapped = intrinsics.atomic_load_explicit(&storage_table_mapped, .Relaxed)
	m.table_retired = storage_retired[.Table]
	m.slab_virtual = intrinsics.atomic_load_explicit(&storage_slab_virtual, .Relaxed)
	m.slab_writable = intrinsics.atomic_load_explicit(&storage_slab_writable, .Relaxed)
	m.slab_retired = storage_retired[.Slab]
	m.metadata_owned = intrinsics.atomic_load_explicit(&storage_metadata_owned, .Relaxed)
	m.metadata_virtual = intrinsics.atomic_load_explicit(&storage_metadata_virtual, .Relaxed)
	m.metadata_writable = intrinsics.atomic_load_explicit(&storage_metadata_writable, .Relaxed)
	m.metadata_retired = storage_retired[.Slab_Metadata]
	m.dead_payload = storage_dead_payload
	m.lazy_payload = lazyfree_pending_bytes()
	m.lazy_slab_live = lazyfree_pending_slab_bytes()
	for &d in dbs {
		s := &d.slab
		if s.base == nil {
			continue
		}
		m.slab_live += s.live
		m.slab_capacity += s.payload_capacity
		m.slab_reusable += s.payload_capacity - s.live
		empty := int(slab_field(s, 1, SLAB_EMPTY_COUNT)) * SLAB_RUN
		dirty := int(slab_field(s, 1, SLAB_DIRTY_COUNT)) * SLAB_RUN
		m.slab_empty += empty
		m.slab_dirty += dirty
		m.slab_clean += empty - dirty
		m.slab_tail += s.top - SLAB_RUN - empty - s.payload_capacity
		m.slab_sentinel += SLAB_RUN
		m.slab_ahead += s.committed - s.top
		for pos, c in s.run_pos {
			if pos != 0 {
				m.slab_bump += int(s.run_last[c] - pos) * SLAB_UNIT + int(slab_class_size[c])
			}
		}
	}
	m.slab_free = m.slab_reusable - m.slab_bump
	return
}

mem_init :: proc() {
	mi := mallinfo2()
	mem_startup = max(int(mi.uordblks + mi.hblkhd) - int(runtime.global_default_temp_allocator_data.arena.total_capacity), 0)
	mem_system = sysconf(SC_PHYS_PAGES) * sysconf(SC_PAGESIZE)
	mem_peak = mem_used()
	mem_sample()
}

mem_aof_buffer :: #force_inline proc "contextless" () -> int {
	return cap(aof.buf) if aof.state != .Disabled else 0
}

mem_keyspace :: #force_inline proc "contextless" () -> int {
	return storage_table_allocated()
}

mem_used :: #force_inline proc "contextless" () -> int {
	return intrinsics.atomic_load_explicit(&storage_metadata_owned, .Relaxed) + ht.maintenance_metadata() + st.maintenance_metadata() + zt.maintenance_metadata() + mem_startup + db_used_memory + mem_keyspace() + storage_dead_payload + client_metadata_total + client_registry_memory() + conn_mem + tx_mem_total + mem_aof_buffer() + lazyfree_pending_bytes() + compute_reserved + keyspace_memory_used() + lua_memory_used() + stat_error_memory() + diagnostics_memory_used()
}

mem_not_counted :: #force_inline proc "contextless" () -> int {
	return mem_aof_buffer()
}

mem_note_peak :: #force_inline proc "contextless" () {
	if u := mem_used(); u > mem_peak {
		mem_peak = u
	}
}

@(private = "file")
mem_sample :: proc() {
	mem_sample_rss = read_rss()
	mem_sample_used = mem_used()
	mi := mallinfo2()
	slab_live := lazyfree_pending_slab_bytes()
	for &d in dbs {
		slab_live += d.slab.live
	}
	mapped, retired, _ := ht.maintenance_memory()
	set_mapped, set_retired, _ := st.maintenance_memory()
	zset_mapped, zset_retired, _ := zt.maintenance_memory()
	mem_sample_allocated = int(mi.uordblks + mi.hblkhd) + slab_live + storage_table_allocated() + mapped - retired + set_mapped - set_retired + zset_mapped - zset_retired + intrinsics.atomic_load_explicit(&storage_metadata_owned, .Relaxed) + diagnostics_memory_used()
	mem_sample_ms = srv.now_ms
}

mem_cron :: proc() {
	mem_note_peak()
	if srv.now_ms - mem_sample_ms >= MEM_SAMPLE_MS {
		mem_sample()
	}
}

mem_reset_peak :: proc() {
	mem_peak = mem_used()
}

mem_db_overhead :: proc "contextless" (db: ^Db) -> int {
	return db.t[0].size + db.t[1].size + db.next.size
}

mem_overhead :: proc() -> (mh: Mem_Overhead) {
	used := mem_used()
	mh.total = used
	mh.startup = mem_startup
	mh.peak = mem_peak
	mh.rss = mem_sample_rss
	mh.sampled_used = mem_sample_used
	mh.allocated = mem_sample_allocated
	mh.frag = f32(mem_sample_rss) / f32(max(mem_sample_used, 1))
	mh.frag_bytes = mem_sample_rss - i64(mem_sample_used)
	mh.clients = conn_mem + tx_mem_total + client_metadata_total
	mh.aof = mem_aof_buffer()
	total := mem_startup + mh.clients + client_registry_memory() + mh.aof + mem_keyspace() + ht.maintenance_metadata() + st.maintenance_metadata() + zt.maintenance_metadata() + intrinsics.atomic_load_explicit(&storage_metadata_owned, .Relaxed) + compute_reserved + keyspace_memory_used() + lua_memory_used() + stat_error_memory() + diagnostics_memory_used()
	mh.lut = mem_keyspace()
	for &d in dbs {
		mh.keys += db_size_of(&d)
		if d.rehash_idx >= 0 {
			mh.rehashing += d.t[0].size
			mh.rehash_count += 1
		}
	}
	mh.overhead = total
	mh.dataset = used - total
	mh.peak_perc = f32(used) * 100 / f32(max(mh.peak, 1))
	net := 1
	if used > mem_startup {
		net = used - mem_startup
	}
	mh.dataset_perc = f32(mh.dataset) * 100 / f32(net)
	if mh.keys > 0 {
		mh.bytes_per_key = mh.dataset / mh.keys
	}
	return
}

sb_fixed :: proc(b: ^[dynamic]u8, v: f64) {
	tmp: [64]u8
	n := snprintf(&tmp[0], uint(len(tmp)), "%.2f", v)
	if n > 0 {
		sb_bytes(b, tmp[:min(int(n), len(tmp) - 1)])
	}
}

sb_human :: proc(b: ^[dynamic]u8, n: i64) {
	K :: f64(1024)
	u := u64(n)
	d := f64(u)
	switch {
	case u < 1024:
		sb_int(b, n)
		sb_byte(b, 'B')
		return
	case u < 1024 * 1024:
		sb_fixed(b, d / K)
		sb_byte(b, 'K')
	case u < 1024 * 1024 * 1024:
		sb_fixed(b, d / (K * K))
		sb_byte(b, 'M')
	case u < 1024 * 1024 * 1024 * 1024:
		sb_fixed(b, d / (K * K * K))
		sb_byte(b, 'G')
	case u < 1024 * 1024 * 1024 * 1024 * 1024:
		sb_fixed(b, d / (K * K * K * K))
		sb_byte(b, 'T')
	case u < 1024 * 1024 * 1024 * 1024 * 1024 * 1024:
		sb_fixed(b, d / (K * K * K * K * K))
		sb_byte(b, 'P')
	case:
		sb_int(b, n)
		sb_byte(b, 'B')
	}
}

@(private = "file")
info_line_ratio :: proc(b: ^[dynamic]u8, name: string, v: f32, percent: bool) {
	sb_str(b, name)
	sb_byte(b, ':')
	sb_fixed(b, f64(v))
	if percent {
		sb_byte(b, '%')
	}
	sb_str(b, "\r\n")
}

info_memory :: proc(b: ^[dynamic]u8) {
	library_host, _ := lua_library_memory()
	library_vm := int(lr.functions_active_stats().current_bytes)
	eval_vm := int(lr.eval_stats().current_bytes)
	mem_note_peak()
	mh := mem_overhead()
	used := i64(mh.total)
	info_section_header(b, "Memory")
	info_line_int(b, "used_memory", used)
	info_line_human(b, "used_memory_human", used)
	info_line_int(b, "used_memory_rss", mh.rss)
	info_line_human(b, "used_memory_rss_human", mh.rss)
	info_line_int(b, "used_memory_peak", i64(mh.peak))
	info_line_human(b, "used_memory_peak_human", i64(mh.peak))
	info_line_ratio(b, "used_memory_peak_perc", mh.peak_perc, true)
	info_line_int(b, "used_memory_overhead", i64(mh.overhead))
	info_line_int(b, "used_memory_startup", i64(mh.startup))
	info_line_int(b, "used_memory_dataset", i64(mh.dataset))
	info_line_ratio(b, "used_memory_dataset_perc", mh.dataset_perc, true)
	info_line_int(b, "allocator_allocated", i64(mh.allocated))
	info_line_int(b, "allocator_active", 0)
	info_line_int(b, "allocator_resident", 0)
	info_line_int(b, "allocator_muzzy", 0)
	info_line_int(b, "total_system_memory", mem_system)
	info_line_human(b, "total_system_memory_human", mem_system)
	info_line_int(b, "used_memory_lua", i64(eval_vm))
	info_line_int(b, "used_memory_vm_eval", i64(eval_vm))
	info_line_human(b, "used_memory_lua_human", i64(eval_vm))
	info_line_int(b, "used_memory_scripts_eval", i64(lua_cache_bytes))
	info_line_int(b, "number_of_cached_scripts", i64(lua_cache_count))
	info_line_int(b, "number_of_functions", i64(lua_function_count))
	info_line_int(b, "number_of_libraries", i64(lua_library_count))
	info_line_int(b, "used_memory_vm_functions", i64(library_vm))
	info_line_int(b, "used_memory_vm_total", i64(eval_vm+library_vm))
	info_line_human(b, "used_memory_vm_total_human", i64(eval_vm+library_vm))
	info_line_int(b, "used_memory_functions", i64(library_host))
	info_line_int(b, "used_memory_scripts", i64(lua_cache_bytes+lua_retired_bytes+library_host))
	info_line_human(b, "used_memory_scripts_human", i64(lua_cache_bytes+lua_retired_bytes+library_host))
	info_line_int(b, "maxmemory", i64(maxmemory_bytes))
	info_line_human(b, "maxmemory_human", i64(maxmemory_bytes))
	info_line_str(b, "maxmemory_policy", EVICT_POLICY_NAMES[maxmemory_policy])
	info_line_ratio(b, "allocator_frag_ratio", 0, false)
	info_line_int(b, "allocator_frag_bytes", 0)
	info_line_ratio(b, "allocator_rss_ratio", 0, false)
	info_line_int(b, "allocator_rss_bytes", 0)
	info_line_ratio(b, "rss_overhead_ratio", 0, false)
	info_line_int(b, "rss_overhead_bytes", 0)
	info_line_ratio(b, "mem_fragmentation_ratio", mh.frag, false)
	info_line_int(b, "mem_fragmentation_bytes", mh.frag_bytes)
	info_line_int(b, "mem_not_counted_for_evict", i64(mem_not_counted()))
	info_line_int(b, "mem_replication_backlog", 0)
	info_line_int(b, "mem_total_replication_buffers", 0)
	info_line_int(b, "mem_clients_slaves", 0)
	info_line_int(b, "mem_clients_normal", i64(mh.clients))
	info_line_int(b, "mem_cluster_links", 0)
	info_line_int(b, "mem_aof_buffer", i64(mh.aof))
	info_line_str(b, "mem_allocator", MEM_ALLOCATOR)
	info_line_int(b, "mem_overhead_db_hashtable_rehashing", i64(mh.rehashing))
	info_line_int(b, "active_defrag_running", 0)
	info_line_int(b, "lazyfree_pending_objects", lazyfree_pending_objects())
	info_line_int(b, "lazyfreed_objects", lazyfreed_objects())
}

@(private = "file")
memory_help := [?]string {
	"MEMORY <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"DOCTOR",
	"    Return memory problems reports.",
	"MALLOC-STATS",
	"    Return internal statistics report from the memory allocator.",
	"PURGE",
	"    Attempt to purge dirty pages for reclamation by the allocator.",
	"STATS",
	"    Return information about the memory usage of the server.",
	"USAGE <key> [SAMPLES <count>]",
	"    Return memory in bytes used by <key> and its value. Nested values are",
	"    sampled up to <count> times (default: 5, 0 means sample all).",
	"HELP",
	"    Print this help.",
}

@(private = "file")
DOCTOR_EMPTY :: "Hi Sam, this instance is empty or is using very little memory, my issues detector can't be used in these conditions. Please, leave for your mission on Earth and fill it with some data. The new Sam and I will be back to our programming as soon as I finished rebooting.\n"
@(private = "file")
DOCTOR_FINE :: "Hi Sam, I can't find any memory issue in your instance. I can only account for what occurs on this base.\n"
@(private = "file")
DOCTOR_HEAD :: "Sam, I detected a few issues in this Redis instance memory implants:\n\n"
@(private = "file")
DOCTOR_PEAK :: " * Peak memory: In the past this instance used more than 150% the memory that is currently using. The allocator is normally not able to release memory after a peak, so you can expect to see a big fragmentation ratio, however this is actually harmless and is only due to the memory peak, and if the Redis instance Resident Set Size (RSS) is currently bigger than expected, the memory will be used as soon as you fill the Redis instance with more data. If the memory peak was only occasional and you want to try to reclaim memory, please try the MEMORY PURGE command, otherwise the only other option is to shutdown and restart the instance.\n\n"
@(private = "file")
DOCTOR_FRAG :: " * High total RSS: This instance has a memory fragmentation and RSS overhead greater than 1.4 (this means that the Resident Set Size of the Redis process is much larger than the sum of the logical allocations Redis performed). This problem is usually due either to a large peak memory (check if there is a peak memory entry above in the report) or may result from a workload that causes the allocator to fragment memory a lot. If the problem is a large peak memory, then there is no issue. Otherwise, make sure you are using the Jemalloc allocator and not the default libc malloc. Note: The currently used allocator is \"" + MEM_ALLOCATOR + "\".\n\n"
@(private = "file")
DOCTOR_CLIENTS :: " * Big client buffers: The clients output buffers in this instance are greater than 200K per client (on average). This may result from different causes, like Pub/Sub clients subscribed to channels bot not receiving data fast enough, so that data piles on the Redis instance output buffer, or clients sending commands with large replies or very large sequences of commands in the same pipeline. Please use the CLIENT LIST command in order to investigate the issue if it causes problems in your instance, or to understand better why certain clients are using a big amount of memory.\n\n"
@(private = "file")
DOCTOR_TAIL :: "I'm here to keep you safe, Sam. I want to help you.\n"

@(private = "file")
memory_doctor :: proc(c: ^Conn) {
	mh := mem_overhead()
	b := &scratch
	clear(b)
	if mh.total < MEM_DOCTOR_EMPTY {
		sb_str(b, DOCTOR_EMPTY)
		reply_verbatim(c, b[:])
		return
	}
	big_peak := f32(mh.peak) / f32(mh.total) > 1.5
	high_frag := mh.frag > 1.4 && mh.frag_bytes > MEM_DOCTOR_BIG_BYTES
	nclients := max(srv.nconns - mc_conn_count(), 1)
	big_clients := mh.clients / nclients > MEM_DOCTOR_CLIENT_AVG
	if !big_peak && !high_frag && !big_clients {
		sb_str(b, DOCTOR_FINE)
		reply_verbatim(c, b[:])
		return
	}
	sb_str(b, DOCTOR_HEAD)
	if big_peak {
		sb_str(b, DOCTOR_PEAK)
	}
	if high_frag {
		sb_str(b, DOCTOR_FRAG)
	}
	if big_clients {
		sb_str(b, DOCTOR_CLIENTS)
	}
	sb_str(b, DOCTOR_TAIL)
	reply_verbatim(c, b[:])
}

@(private = "file")
reply_kv_int :: proc(c: ^Conn, name: string, v: i64) {
	reply_bulk_str(c, name)
	reply_int(c, v)
}

@(private = "file")
reply_kv_double :: proc(c: ^Conn, name: string, v: f32) {
	reply_bulk_str(c, name)
	reply_double(c, f64(v))
}

@(private = "file")
memory_stats :: proc(c: ^Conn) {
	mh := mem_overhead()
	ndbs := 0
	for &d in dbs {
		if mem_db_overhead(&d) > 0 {
			ndbs += 1
		}
	}
	reply_map(c, 31 + ndbs)
	reply_kv_int(c, "peak.allocated", i64(mh.peak))
	reply_kv_int(c, "total.allocated", i64(mh.total))
	reply_kv_int(c, "startup.allocated", i64(mh.startup))
	reply_kv_int(c, "replication.backlog", 0)
	reply_kv_int(c, "clients.slaves", 0)
	reply_kv_int(c, "clients.normal", i64(mh.clients))
	reply_kv_int(c, "cluster.links", 0)
	reply_kv_int(c, "aof.buffer", i64(mh.aof))
	reply_kv_int(c, "lua.caches", i64(lua_cache_bytes+lua_retired_bytes))
	library_host, _ := lua_library_memory()
	reply_kv_int(c, "functions.caches", i64(library_host))
	for &d in dbs {
		if mem_db_overhead(&d) == 0 {
			continue
		}
		clear(&scratch)
		sb_str(&scratch, "db.")
		sb_int(&scratch, i64(d.id))
		reply_bulk(c, scratch[:])
		reply_map(c, 2)
		reply_kv_int(c, "overhead.hashtable.main", i64(mem_db_overhead(&d)))
		reply_kv_int(c, "overhead.hashtable.expires", 0)
	}
	reply_kv_int(c, "overhead.db.hashtable.lut", i64(mh.lut))
	reply_kv_int(c, "overhead.db.hashtable.rehashing", i64(mh.rehashing))
	reply_kv_int(c, "overhead.total", i64(mh.overhead))
	reply_kv_int(c, "db.dict.rehashing.count", i64(mh.rehash_count))
	reply_kv_int(c, "keys.count", i64(mh.keys))
	reply_kv_int(c, "keys.bytes-per-key", i64(mh.bytes_per_key))
	reply_kv_int(c, "dataset.bytes", i64(mh.dataset))
	reply_kv_double(c, "dataset.percentage", mh.dataset_perc)
	reply_kv_double(c, "peak.percentage", mh.peak_perc)
	reply_kv_int(c, "allocator.allocated", i64(mh.allocated))
	reply_kv_int(c, "allocator.active", 0)
	reply_kv_int(c, "allocator.resident", 0)
	reply_kv_int(c, "allocator.muzzy", 0)
	reply_kv_double(c, "allocator-fragmentation.ratio", 0)
	reply_kv_int(c, "allocator-fragmentation.bytes", 0)
	reply_kv_double(c, "allocator-rss.ratio", 0)
	reply_kv_int(c, "allocator-rss.bytes", 0)
	reply_kv_double(c, "rss-overhead.ratio", 0)
	reply_kv_int(c, "rss-overhead.bytes", 0)
	reply_kv_double(c, "fragmentation", mh.frag)
	reply_kv_int(c, "fragmentation.bytes", mh.frag_bytes)
}

@(private = "file")
memory_usage :: proc(c: ^Conn, argv: [][]u8) {
	for j := 3; j < len(argv); j += 1 {
		if !eq_nocase(argv[j], "samples") || j + 1 >= len(argv) {
			reply_error(c, ERR_SYNTAX)
			return
		}
		samples, ok := parse_i64(argv[j + 1])
		if !ok {
			reply_error(c, ERR_NOT_INT)
			return
		}
		if samples < 0 {
			reply_error(c, ERR_SYNTAX)
			return
		}
		j += 1
	}
	e := db_find_notouch(argv[2])
	if e == nil {
		reply_null(c)
		return
	}
	reply_int(c, i64(len(argv[2]) + entry_memory(e) + ENTRY_OVERHEAD))
}

entry_memory :: proc(e: ^Entry) -> int {
	if h := entry_object(e, .Hash); h != nil {
		return hash_memory(h)
	}
	if s := entry_object(e, .Set); s != nil {
		return set_object_acct(s)
	}
	if l := entry_object(e, .List); l != nil {
		return list_memory(l)
	}
	if z := entry_object(e, .Zset); z != nil {
		return zset_memory(z)
	}
	if sm := entry_object(e, .Stream); sm != nil {
		return stream_memory(sm)
	}
	return int(e.cap)
}

cmd_memory :: proc(c: ^Conn, argv: [][]u8) {
	sub := argv[1]
	switch {
	case eq_nocase(sub, "usage"):
		if len(argv) < 3 {
			reply_wrong_args(c, "memory|usage")
			return
		}
		memory_usage(c, argv)
	case eq_nocase(sub, "stats"):
		if len(argv) != 2 {
			reply_wrong_args(c, "memory|stats")
			return
		}
		memory_stats(c)
	case eq_nocase(sub, "doctor"):
		if len(argv) != 2 {
			reply_wrong_args(c, "memory|doctor")
			return
		}
		memory_doctor(c)
	case eq_nocase(sub, "purge"):
		if len(argv) != 2 {
			reply_wrong_args(c, "memory|purge")
			return
		}
		malloc_trim(0)
		reply_ok(c)
	case eq_nocase(sub, "malloc-stats"):
		if len(argv) != 2 {
			reply_wrong_args(c, "memory|malloc-stats")
			return
		}
		reply_bulk_str(c, "Stats not supported for the current allocator")
	case eq_nocase(sub, "help"):
		if len(argv) != 2 {
			reply_wrong_args(c, "memory|help")
			return
		}
		reply_array(c, len(memory_help))
		for line in memory_help {
			reply_simple(c, line)
		}
	case:
		reply_unknown_subcommand(c, sub, "MEMORY")
	}
}

CLIENT_EVICT_MIN :: 128 * 1024
CLIENT_BUCKET_MIN_LOG :: 15
CLIENT_BUCKET_MAX_LOG :: 33

client_buckets_on: bool

@(private = "file")
client_evict_buf: [dynamic]u8
@(private = "file")
client_evict_seq: u64

client_eviction_limit :: proc() -> int {
	actual: int
	if cfg.maxmemory_clients < 0 && maxmemory_bytes > 0 {
		actual = int(f64(maxmemory_bytes) * -f64(cfg.maxmemory_clients) / 100)
	} else if cfg.maxmemory_clients > 0 {
		actual = int(cfg.maxmemory_clients)
	} else {
		return 0
	}
	return max(actual, CLIENT_EVICT_MIN)
}

memory_worker_admissible :: proc() -> bool {
	over, _ := memory_state_over()
	limit := client_eviction_limit()
	return !over && !evict_timer && (limit == 0 || conn_mem + tx_mem_total + client_metadata_total <= limit)
}

Memory_Worker_Access :: struct {
	lfu: bool,
	clock: u32,
	minutes: u16,
	log_factor, decay_time: int,
	random: u64,
}

memory_worker_access_snapshot :: proc "contextless" () -> Memory_Worker_Access {
	return Memory_Worker_Access{lfu = lfu_policy, clock = lru_clock(), minutes = lfu_minutes(), log_factor = lfu_log_factor, decay_time = lfu_decay_time, random = rng_next() if lfu_policy else 0}
}

memory_worker_access_touch :: proc "contextless" (access: ^Memory_Worker_Access, clock: u32, created: bool = false) -> u32 {
	if !access.lfu { return access.clock }
	if created { return u32(access.minutes) << 8 | LFU_INIT_VAL }
	counter := i64(u8(clock))
	if access.decay_time > 0 {
		last := i64(u16(clock >> 8))
		now := i64(access.minutes)
		elapsed := now - last if now >= last else LFU_TIME_MAX - last + now
		periods := elapsed / i64(access.decay_time)
		counter = max(0, counter - periods)
	}
	if counter < 255 {
		x := access.random
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		access.random = x
		r := f64(x >> 11) / f64(u64(1) << 53)
		base := max(f64(counter - LFU_INIT_VAL), 0)
		if r < 1.0 / (base * f64(access.log_factor) + 1) { counter += 1 }
	}
	return u32(access.minutes) << 8 | u32(counter)
}

conn_memory :: proc(c: ^Conn) -> int {
	return size_of(Conn) + c.rcap + c.wcap + len(c.name) + len(c.lib_name) + len(c.lib_ver) + tx_multi_mem(c) + request_inline_memory(c) + transport_connection_memory(c) + client_metadata_memory(c)
}

@(private = "file")
client_bucket :: proc(mem: int) -> int {
	b := 64 - int(intrinsics.count_leading_zeros(u64(mem)))
	return clamp(b, CLIENT_BUCKET_MIN_LOG, CLIENT_BUCKET_MAX_LOG) - CLIENT_BUCKET_MIN_LOG
}

@(private = "file")
client_evictable :: #force_inline proc(t: ^Conn) -> bool {
	return t != nil && t.kind == .Redis && !t.close_after && .No_Evict not_in t.flags
}

@(private = "file")
client_bucket_note :: proc(c: ^Conn) {
	b := u8(client_bucket(conn_memory(c)) + 1)
	if b != c.ev_bucket {
		c.ev_bucket = b
		client_evict_seq += 1
		c.ev_seq = client_evict_seq
	}
}

@(cold)
client_bucket_track :: #force_no_inline proc(c: ^Conn) {
	if client_evictable(c) {
		client_bucket_note(c)
	}
}

client_buckets_apply :: proc() {
	on := cfg.maxmemory_clients != 0
	if on == client_buckets_on {
		return
	}
	client_buckets_on = on
	for t in sorted_conns() {
		t.ev_bucket = 0
		if on && client_evictable(t) {
			client_bucket_note(t)
		}
	}
}

@(cold)
evict_clients :: #force_no_inline proc(current: ^Conn) -> (evicted_current: bool) {
	limit := client_eviction_limit()
	if limit == 0 {
		return
	}
	if conn_mem + tx_mem_total + client_metadata_total <= limit { return }
	keyspace_fence()
	held := 0
	for conn_mem + tx_mem_total + client_metadata_total - held > limit {
		victim: ^Conn
		for t in srv.conns {
			if !client_evictable(t) {
				continue
			}
			client_bucket_note(t)
			if victim == nil || t.ev_bucket > victim.ev_bucket || (t.ev_bucket == victim.ev_bucket && t.ev_seq < victim.ev_seq) {
				victim = t
			}
		}
		if victim == nil {
			plog(LOG_WARNING, "Over client maxmemory after evicting all evictable clients")
			return
		}
		clear(&client_evict_buf)
		client_info_line(&client_evict_buf, victim, nil, nil)
		plog(LOG_NOTICE, "Evicting client: ", string(client_evict_buf[:len(client_evict_buf) - 1]))
		stat_evicted_clients += 1
		if victim == current {
			held += conn_memory(victim)
			victim.wlen = victim.wpos
			victim.close_after = true
			evicted_current = true
			continue
		}
		conn_close(victim)
	}
	return
}

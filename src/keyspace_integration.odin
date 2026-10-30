package main

import "base:runtime"
import ks "keyspace"
import "core:sys/linux"

KEYSPACE_BUCKETS :: 1024

Keyspace_Task :: struct {
	job:        ks.Job,
	region:     []u8,
	argv:       [][]u8,
	client:     Conn,
	fd:         linux.Fd,
	client_id:  i64,
	token:      u64,
	start:      u64,
	stats:      ^Cmd_Hot,
	suppressed: bool,
}

Keyspace_Ready :: struct {
	fd:    linux.Fd,
	id:    i64,
	token: u64,
}

keyspace_pool: ks.Pool
keyspace_threads: i64
keyspace_max_memory: i64 = 128 * 1024 * 1024
keyspace_initialized: bool
keyspace_registered: bool
keyspace_in_fence: bool
keyspace_directory: [KEYSPACE_BUCKETS]^ks.Record
keyspace_records: int
keyspace_pending: int
keyspace_next_token: u64
keyspace_submitted: i64
keyspace_completed: i64
keyspace_gets: i64
keyspace_sets: i64
keyspace_fallbacks: i64
keyspace_barriers: i64
keyspace_worker_ns: i64
keyspace_ready: [dynamic]Keyspace_Ready
keyspace_draining_ready_bytes: int

keyspace_memory_used :: proc "contextless" () -> int {
	return ks.memory_used(&keyspace_pool) + cap(keyspace_ready) * size_of(Keyspace_Ready) + keyspace_draining_ready_bytes
}

keyspace_candidate :: proc(cmd: ^Command, argv: [][]u8) -> bool {
	return cmd != nil && ((cmd.handler == cmd_get && len(argv) == 2) || (cmd.handler == cmd_set && len(argv) == 3))
}

keyspace_eligible :: proc(c: ^Conn) -> bool {
	return keyspace_threads > 0 && keyspace_max_memory > 0 && !keyspace_in_fence && c.fd >= 0 && c.kind == .Redis && c.db != nil && c.compute == nil && c.keyspace == nil && !c.keyspace_ready && c.blocked == .None && !c.held && !c.close_after && c.ps == {} && .Multi not_in c.txf && tx_exec_conn == nil && !deny_blocking && tx_multi_count == 0 && !cmd_hooks && !key_hooks && watch_total == 0 && !tracking_on && tracking_clients == 0 && notify_active == {} && len(monitors) == 0 && len(ps_conns) == 0 && ps_exec == nil && !ps_hooked && ps_held_count == 0 && block_work == 0 && block_count() == 0 && lazy_blocked == 0 && maxmemory_bytes == 0 && cfg.maxmemory_clients == 0 && !client_buckets_on && !evict_timer && !lfu_policy && mc_port == 0 && mc_flush_at == 0 && srv.pause_end_ms == 0 && srv.held_count == 0 && !srv.resume_due && !cron_paused && !pst.loading && !pst.serve_while_loading && !pst.in_child && !pst.gate_active && pst.child_pid <= 0 && !pst.bgsave_scheduled && aof.state == .Off && !aof.wanted && !aof.feed && !aof.loading && len(aof.buf) == 0 && len(aof.deferred) == 0
}

keyspace_start :: proc() -> bool {
	if pst.in_child || keyspace_threads == 0 || keyspace_max_memory == 0 {
		return false
	}
	if !keyspace_initialized {
		if !ks.init(&keyspace_pool, int(keyspace_threads), int(keyspace_max_memory)) {
			return false
		}
		keyspace_initialized = true
	} else if !ks.resume(&keyspace_pool) {
		return false
	}
	if !keyspace_registered {
		if epoll_set(ks.completion_fd(&keyspace_pool), .ADD, false, 0) != .NONE {
			ks.stop(&keyspace_pool)
			return false
		}
		keyspace_registered = true
	}
	return true
}

keyspace_event_fd :: proc() -> linux.Fd {
	return ks.completion_fd(&keyspace_pool) if keyspace_registered else -1
}

keyspace_queue_ready :: proc(c: ^Conn, token: u64) {
	c.keyspace_ready = true
	saved := context.allocator
	context.allocator = runtime.heap_allocator()
	append(&keyspace_ready, Keyspace_Ready{c.fd, c.id, token})
	context.allocator = saved
}

keyspace_complete :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	keyspace_worker_ns += job.elapsed_ns
	if job.op == .Set {
		pst.dirty += 1
		keyspace_sets += 1
	} else {
		keyspace_gets += 1
		if job.result_found {
			srv.stat_hits += 1
		} else {
			srv.stat_misses += 1
		}
	}
	stat_keyspace_complete(&task.client, task.stats, task.argv, mono_now() - task.start)
	c: ^Conn
	if int(task.fd) >= 0 && int(task.fd) < len(srv.conns) {
		c = srv.conns[task.fd]
	}
	valid := c != nil && c.id == task.client_id && c.keyspace == task && c.keyspace_token == task.token
	if valid {
		c.keyspace = nil
		c.atime_ms = srv.now_ms
		if !task.suppressed {
			if job.op == .Set {
				reply_ok(c)
			} else if job.result_found {
				reply_bulk(c, ks.value_data(job.result))
			} else {
				reply_null(c)
			}
		}
		keyspace_queue_ready(c, task.token)
	}
	ks.value_release(job.result)
	ks.value_release(job.value)
	region := task.region
	keyspace_pending -= 1
	keyspace_completed += 1
	if !ks.free(&keyspace_pool, region) {
		store_fatal("keyspace task release invariant")
	}
}

keyspace_collect :: proc() {
	if !keyspace_initialized {
		return
	}
	ks.drain_notifications(&keyspace_pool)
	for _ in 0 ..< ks.CAPACITY {
		job := ks.poll(&keyspace_pool)
		if job == nil {
			break
		}
		keyspace_complete(job)
	}
}

keyspace_fence :: proc() {
	if !keyspace_initialized || keyspace_in_fence {
		return
	}
	keyspace_in_fence = true
	defer keyspace_in_fence = false
	ks.pause(&keyspace_pool)
	if keyspace_records > 0 || keyspace_pending > 0 {
		keyspace_barriers += 1
	}
	keyspace_collect()
	if keyspace_pending != 0 || ks.pending(&keyspace_pool) != 0 {
		store_fatal("keyspace fence completion invariant")
	}
	saved_db := db_cur
	defer db_cur = saved_db
	for &head in keyspace_directory {
		r := head
		for r != nil {
			next := r.caller_next
			if r.exists && (r.changed || r.touched) {
				keyspace_store_import(&dbs[r.db], transmute([]u8)r.key, ks.value_data(r.value), r.clock, r.changed)
			}
			if !ks.record_free(&keyspace_pool, r) {
				store_fatal("keyspace record release invariant")
			}
			r = next
		}
		head = nil
	}
	keyspace_records = 0
}

keyspace_before_fork :: proc() {
	if keyspace_initialized && !pst.in_child {
		keyspace_fence()
		ks.stop(&keyspace_pool)
	}
}

keyspace_shutdown :: proc() {
	if !keyspace_initialized {
		return
	}
	keyspace_fence()
	ks.stop(&keyspace_pool)
	if keyspace_registered {
		epoll_set(ks.completion_fd(&keyspace_pool), .DEL, false, 0)
		keyspace_registered = false
	}
	if !ks.destroy(&keyspace_pool) {
		store_fatal("keyspace pool destruction invariant")
	}
	keyspace_initialized = false
	delete(keyspace_ready)
	keyspace_ready = nil
}

keyspace_conn_closed :: proc(c: ^Conn) {
	c.keyspace = nil
	c.keyspace_ready = false
}

keyspace_tick :: proc() {
	if pst.in_child || !keyspace_initialized || keyspace_in_fence {
		return
	}
	keyspace_collect()
	ready := keyspace_ready
	keyspace_ready = nil
	keyspace_draining_ready_bytes += cap(ready) * size_of(Keyspace_Ready)
	for ticket in ready {
		if int(ticket.fd) < 0 || int(ticket.fd) >= len(srv.conns) {
			continue
		}
		c := srv.conns[ticket.fd]
		if c == nil || c.id != ticket.id || c.keyspace_token != ticket.token || !c.keyspace_ready {
			continue
		}
		c.keyspace_ready = false
		process_input(c)
		conn_flush(c)
	}
	keyspace_draining_ready_bytes -= cap(ready) * size_of(Keyspace_Ready)
	delete(ready)
}

keyspace_try :: proc(c: ^Conn, cmd: ^Command, stats: ^Cmd_Hot, argv: [][]u8) -> bool {
	if !keyspace_candidate(cmd, argv) || !keyspace_eligible(c) {
		keyspace_fence()
		return false
	}
	start := mono_now()
	if !keyspace_start() || keyspace_pending >= ks.CAPACITY {
		keyspace_fallbacks += 1
		keyspace_fence()
		return false
	}
	hash := hash_bytes(argv[1]) ~ (u64(c.db.id) * WY_P1)
	bucket := int(hash & (KEYSPACE_BUCKETS - 1))
	r := keyspace_directory[bucket]
	for r != nil {
		if r.db == c.db.id && r.key == transmute(string)argv[1] {
			break
		}
		r = r.caller_next
	}
	if r == nil {
		seed, clock, exists, eligible := keyspace_store_seed(c.db, argv[1])
		if !eligible {
			keyspace_fallbacks += 1
			keyspace_fence()
			return false
		}
		r = ks.record_new(&keyspace_pool, c.db.id, argv[1], int(hash % u64(keyspace_threads)), exists, seed, clock)
		if r == nil {
			keyspace_fallbacks += 1
			keyspace_fence()
			return false
		}
		r.caller_next = keyspace_directory[bucket]
		keyspace_directory[bucket] = r
		keyspace_records += 1
	}
	setting := cmd.handler == cmd_set
	bytes := u128(size_of(Keyspace_Task)) + u128(len(argv)) * size_of([]u8) + u128(len(c.name))
	for arg, i in argv {
		if !setting || i != 2 {
			bytes += u128(len(arg))
		}
	}
	if bytes > u128(max(int)) {
		keyspace_fallbacks += 1
		keyspace_fence()
		return false
	}
	region := ks.allocate(&keyspace_pool, int(bytes))
	if len(region) == 0 {
		keyspace_fallbacks += 1
		keyspace_fence()
		return false
	}
	task := cast(^Keyspace_Task)raw_data(region)
	task^ = Keyspace_Task{}
	task.region = region
	task.job.record = r
	task.job.op = .Set if setting else .Get
	if setting {
		task.job.value = ks.value_new(&keyspace_pool, argv[2])
		if task.job.value == nil {
			if !ks.free(&keyspace_pool, region) {
				store_fatal("keyspace rejected task release invariant")
			}
			keyspace_fallbacks += 1
			keyspace_fence()
			return false
		}
	}
	offset := size_of(Keyspace_Task)
	task.argv = (cast([^][]u8)(&region[offset]))[:len(argv)]
	offset += len(argv) * size_of([]u8)
	for arg, i in argv {
		if setting && i == 2 {
			task.argv[i] = ks.value_data(task.job.value)
		} else {
			task.argv[i] = region[offset:offset + len(arg)]
			copy(task.argv[i], arg)
			offset += len(arg)
		}
	}
	task.client = Conn{fd = -1, id = c.id, addr = c.addr, addr_len = c.addr_len}
	task.client.name = region[offset:offset + len(c.name)]
	copy(task.client.name, c.name)
	task.fd = c.fd
	task.client_id = c.id
	keyspace_next_token += 1
	if keyspace_next_token == 0 {
		keyspace_next_token += 1
	}
	task.token = keyspace_next_token
	task.start = start
	task.stats = stats
	task.suppressed = c.reply & {.Off, .Skip} != {}
	task.job.clock = lru_clock()
	task.job.touch = .No_Touch not_in c.flags
	task.job.data = task
	if !ks.submit(&keyspace_pool, &task.job) {
		ks.value_release(task.job.value)
		if !ks.free(&keyspace_pool, region) {
			store_fatal("keyspace rejected task release invariant")
		}
		keyspace_fallbacks += 1
		keyspace_fence()
		return false
	}
	c.keyspace = task
	c.keyspace_token = task.token
	keyspace_pending += 1
	keyspace_submitted += 1
	stat_cur = nil
	mem_note_peak()
	return true
}

keyspace_info :: proc(b: ^[dynamic]u8) {
	info_line_int(b, "keyspace_threads_configured", keyspace_threads)
	info_line_int(b, "keyspace_threads_active", i64(ks.active_workers(&keyspace_pool)))
	info_line_int(b, "keyspace_jobs_pending", i64(keyspace_pending))
	info_line_int(b, "keyspace_memory_used", i64(ks.memory_used(&keyspace_pool)))
	info_line_int(b, "keyspace_records", i64(keyspace_records))
	info_line_int(b, "keyspace_jobs_submitted", keyspace_submitted)
	info_line_int(b, "keyspace_jobs_completed", keyspace_completed)
	info_line_int(b, "keyspace_gets", keyspace_gets)
	info_line_int(b, "keyspace_sets", keyspace_sets)
	info_line_int(b, "keyspace_sync_fallbacks", keyspace_fallbacks)
	info_line_int(b, "keyspace_barriers", keyspace_barriers)
	info_line_int(b, "keyspace_worker_nanoseconds", keyspace_worker_ns)
}

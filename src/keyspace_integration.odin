package main

import "base:runtime"
import ks "keyspace"
import ld "ldfloat"
import "core:sys/linux"

KEYSPACE_INDEX_SLOTS :: 512
KEYSPACE_KEY_INDICES :: 32
KEYSPACE_CONN_DEPTH :: 16

Keyspace_Slot :: struct {
	record: ^ks.Record,
	tag:    u32,
	length: u32,
}

#assert(size_of(Keyspace_Slot) == 16)

Keyspace_Task :: struct {
	job:        ks.Job,
	region:     []u8,
	argv:       [][]u8,
	client:     Conn,
	fd:         linux.Fd,
	client_id:  i64,
	token:      u64,
	sequence:   u64,
	start:      u64,
	stats:      ^Cmd_Hot,
	suppressed: bool,
	forked: bool,
	op: Keyspace_Op,
	command_name: string,
	restore_deep: bool,
	restore_user: Acl_User,
	sanitized: i64,
	command: ^Command,
	events: []Keyspace_Event,
	event_storage: []Keyspace_Event,
	poststates: []Keyspace_Poststate,
	poststate_storage: []Keyspace_Poststate,
	capture_poststate: bool,
	hash_aof_ready: bool,
	hash_expired: ^ks.Value,
	hash_expired_count: int,
	hash_expire_at: i64,
	access: Memory_Worker_Access,
	rolled_back: bool,
	inline: bool,
	records: []^ks.Record,
	values: []^ks.Value,
	results: []^ks.Value,
	now: i64,
	limit: i64,
	integer: i64,
	from: i64,
	to: i64,
	dirty: i64,
	hits: i64,
	misses: i64,
	expired: i64,
	subexpired: i64,
	failed: bool,
	bulk: bool,
	null: bool,
	ok: bool,
	array: bool,
	raw: bool,
	status: string,

}

Keyspace_Ready :: struct {
	fd: linux.Fd,
	id: i64,
}

keyspace_pool: ks.Pool
keyspace_threads: i64
keyspace_max_memory: i64 = 128 * 1024 * 1024
keyspace_initialized: bool
keyspace_registered: bool
keyspace_notified: bool
keyspace_in_fence: bool
keyspace_index_fixed: [KEYSPACE_INDEX_SLOTS]Keyspace_Slot
keyspace_index: []Keyspace_Slot
keyspace_timed: bool
keyspace_records: int
keyspace_pending: int
keyspace_next_token: u64
keyspace_next_sequence: u64
keyspace_publish_sequence: u64
keyspace_completions: [ks.CAPACITY]^Keyspace_Task
keyspace_completion_count: int
keyspace_replay_needed: bool
keyspace_submitted: i64
keyspace_completed: i64
keyspace_gets: i64
keyspace_sets: i64
keyspace_fallbacks: i64
keyspace_inline: i64
keyspace_barriers: i64
keyspace_worker_ns: i64
keyspace_retries: [dynamic]^Keyspace_Task
keyspace_ready: [dynamic]Keyspace_Ready
keyspace_waiting: [dynamic]Keyspace_Ready
keyspace_draining_ready_bytes: int

keyspace_memory_used :: proc "contextless" () -> int {
	return ks.memory_used(&keyspace_pool) + (cap(keyspace_ready) + cap(keyspace_waiting)) * size_of(Keyspace_Ready) + cap(keyspace_retries) * size_of(^Keyspace_Task) + keyspace_draining_ready_bytes
}

keyspace_signal_owed :: #force_inline proc "contextless" () {
	ks.signal_owed(&keyspace_pool)
}

keyspace_conn_busy :: #force_inline proc "contextless" (c: ^Conn) -> bool {
	return c.keyspace_inflight > 0 || c.keyspace_ready || c.keyspace_waiting
}

keyspace_admits :: proc(c: ^Conn) -> bool {
	if c.keyspace_inflight >= KEYSPACE_CONN_DEPTH {
		return false
	}
	if keyspace_pending < ks.CAPACITY {
		c.keyspace_waiting = false
		return true
	}
	if c.keyspace_inflight == 0 && !c.keyspace_waiting {
		c.keyspace_waiting = true
		keyspace_ticket(&keyspace_waiting, c)
	}
	return false
}

keyspace_settle :: proc(c: ^Conn) {
	if c.keyspace_inflight > 0 {
		keyspace_fence()
	}
}

keyspace_resume_due :: #force_inline proc "contextless" () -> bool {
	return len(keyspace_ready) > 0 || len(keyspace_waiting) > 0 && keyspace_pending < ks.CAPACITY || keyspace_replay_needed
}

Keyspace_Op :: enum u8 {
	Get, Set, Getex, Getdel, Getset, Setnx, Setex, Psetex,
	Append, Strlen, Getrange, Setrange, Incr, Decr, Incrby, Decrby, Incrbyfloat,
	Mget, Mset, Msetnx, Del, Exists, Touch, Type, Ttl, Pttl, Expiretime, Pexpiretime,
	Expire, Pexpire, Expireat, Pexpireat, Persist,
	Llen, Lindex, Lrange, Lpos, Lpush, Rpush, Lpushx, Rpushx, Lpop, Rpop,
	Lset, Linsert, Ltrim, Lrem, Lmove, Rpoplpush, Lmpop,
	Setbit, Getbit, Bitcount, Bitpos, Bitop, Bitfield, Bitfield_ro,
	Pfadd, Pfcount, Pfmerge, Pfdebug,
	Sadd, Srem, Smove, Sismember, Smismember, Scard, Spop, Srandmember, Smembers,
	Sinter, Sintercard, Sinterstore, Sunion, Sunionstore, Sdiff, Sdiffstore, Sscan,
	Hset, Hmset, Hsetnx, Hget, Hmget, Hgetall, Hkeys, Hvals, Hlen, Hexists, Hstrlen,
	Hdel, Hincrby, Hincrbyfloat, Hrandfield, Hscan, Hexpire, Hpexpire, Hexpireat,
	Hpexpireat, Httl, Hpttl, Hexpiretime, Hpexpiretime, Hpersist,
	Zset,
	Geo,
	Stream,
	Key,
}

keyspace_operation :: proc "contextless" (cmd: ^Command) -> (Keyspace_Op, bool) {
	if cmd == nil {
		return {}, false
	}
	switch cmd.handler {
	case cmd_rename: return .Key, true
	case cmd_renamenx: return .Key, true
	case cmd_copy: return .Key, true
	case cmd_move: return .Key, true
	case cmd_dump: return .Key, true
	case cmd_restore: return .Key, true
	case cmd_xadd: return .Stream, true
	case cmd_xrange: return .Stream, true
	case cmd_xrevrange: return .Stream, true
	case cmd_xlen: return .Stream, true
	case cmd_xdel: return .Stream, true
	case cmd_xtrim: return .Stream, true
	case cmd_xsetid: return .Stream, true
	case cmd_xinfo: return .Stream, true
	case cmd_xread: return .Stream, true
	case cmd_xreadgroup: return .Stream, true
	case cmd_xgroup: return .Stream, true
	case cmd_xack: return .Stream, true
	case cmd_xpending: return .Stream, true
	case cmd_xclaim: return .Stream, true
	case cmd_xautoclaim: return .Stream, true
	case cmd_geoadd: return .Geo, true
	case cmd_geodist: return .Geo, true
	case cmd_geohash: return .Geo, true
	case cmd_geopos: return .Geo, true
	case cmd_georadius: return .Geo, true
	case cmd_georadius_ro: return .Geo, true
	case cmd_georadiusbymember: return .Geo, true
	case cmd_georadiusbymember_ro: return .Geo, true
	case cmd_geosearch: return .Geo, true
	case cmd_geosearchstore: return .Geo, true
	case cmd_zadd: return .Zset, true
	case cmd_zincrby: return .Zset, true
	case cmd_zrem: return .Zset, true
	case cmd_zcard: return .Zset, true
	case cmd_zscore: return .Zset, true
	case cmd_zmscore: return .Zset, true
	case cmd_zrank: return .Zset, true
	case cmd_zrevrank: return .Zset, true
	case cmd_zrange: return .Zset, true
	case cmd_zrangestore: return .Zset, true
	case cmd_zrevrange: return .Zset, true
	case cmd_zrangebyscore: return .Zset, true
	case cmd_zrevrangebyscore: return .Zset, true
	case cmd_zrangebylex: return .Zset, true
	case cmd_zrevrangebylex: return .Zset, true
	case cmd_zcount: return .Zset, true
	case cmd_zlexcount: return .Zset, true
	case cmd_zremrangebyrank: return .Zset, true
	case cmd_zremrangebyscore: return .Zset, true
	case cmd_zremrangebylex: return .Zset, true
	case cmd_zunionstore: return .Zset, true
	case cmd_zinterstore: return .Zset, true
	case cmd_zdiffstore: return .Zset, true
	case cmd_zunion: return .Zset, true
	case cmd_zinter: return .Zset, true
	case cmd_zdiff: return .Zset, true
	case cmd_zintercard: return .Zset, true
	case cmd_zpopmin: return .Zset, true
	case cmd_zpopmax: return .Zset, true
	case cmd_zmpop: return .Zset, true
	case cmd_zrandmember: return .Zset, true
	case cmd_zscan: return .Zset, true
	case cmd_hset: return .Hset, true
	case cmd_hmset: return .Hmset, true
	case cmd_hsetnx: return .Hsetnx, true
	case cmd_hget: return .Hget, true
	case cmd_hmget: return .Hmget, true
	case cmd_hgetall: return .Hgetall, true
	case cmd_hkeys: return .Hkeys, true
	case cmd_hvals: return .Hvals, true
	case cmd_hlen: return .Hlen, true
	case cmd_hexists: return .Hexists, true
	case cmd_hstrlen: return .Hstrlen, true
	case cmd_hdel: return .Hdel, true
	case cmd_hincrby: return .Hincrby, true
	case cmd_hincrbyfloat: return .Hincrbyfloat, true
	case cmd_hrandfield: return .Hrandfield, true
	case cmd_hscan: return .Hscan, true
	case cmd_hexpire: return .Hexpire, true
	case cmd_hpexpire: return .Hpexpire, true
	case cmd_hexpireat: return .Hexpireat, true
	case cmd_hpexpireat: return .Hpexpireat, true
	case cmd_httl: return .Httl, true
	case cmd_hpttl: return .Hpttl, true
	case cmd_hexpiretime: return .Hexpiretime, true
	case cmd_hpexpiretime: return .Hpexpiretime, true
	case cmd_hpersist: return .Hpersist, true
	case cmd_sadd: return .Sadd, true
	case cmd_srem: return .Srem, true
	case cmd_smove: return .Smove, true
	case cmd_sismember: return .Sismember, true
	case cmd_smismember: return .Smismember, true
	case cmd_scard: return .Scard, true
	case cmd_spop: return .Spop, true
	case cmd_srandmember: return .Srandmember, true
	case cmd_smembers: return .Smembers, true
	case cmd_sinter: return .Sinter, true
	case cmd_sintercard: return .Sintercard, true
	case cmd_sinterstore: return .Sinterstore, true
	case cmd_sunion: return .Sunion, true
	case cmd_sunionstore: return .Sunionstore, true
	case cmd_sdiff: return .Sdiff, true
	case cmd_sdiffstore: return .Sdiffstore, true
	case cmd_sscan: return .Sscan, true
	case cmd_setbit: return .Setbit, true
	case cmd_getbit: return .Getbit, true
	case cmd_bitcount: return .Bitcount, true
	case cmd_bitpos: return .Bitpos, true
	case cmd_bitop: return .Bitop, true
	case cmd_bitfield: return .Bitfield, true
	case cmd_bitfield_ro: return .Bitfield_ro, true
	case cmd_pfadd: return .Pfadd, true
	case cmd_pfcount: return .Pfcount, true
	case cmd_pfmerge: return .Pfmerge, true
	case cmd_pfdebug: return .Pfdebug, true
	case cmd_llen: return .Llen, true
	case cmd_lindex: return .Lindex, true
	case cmd_lrange: return .Lrange, true
	case cmd_lpos: return .Lpos, true
	case cmd_lpush: return .Lpush, true
	case cmd_rpush: return .Rpush, true
	case cmd_lpushx: return .Lpushx, true
	case cmd_rpushx: return .Rpushx, true
	case cmd_lpop: return .Lpop, true
	case cmd_rpop: return .Rpop, true
	case cmd_lset: return .Lset, true
	case cmd_linsert: return .Linsert, true
	case cmd_ltrim: return .Ltrim, true
	case cmd_lrem: return .Lrem, true
	case cmd_lmove: return .Lmove, true
	case cmd_rpoplpush: return .Rpoplpush, true
	case cmd_lmpop: return .Lmpop, true
	case cmd_get: return .Get, true
	case cmd_set: return .Set, true
	case cmd_getex: return .Getex, true
	case cmd_getdel: return .Getdel, true
	case cmd_getset: return .Getset, true
	case cmd_setnx: return .Setnx, true
	case cmd_setex: return .Setex, true
	case cmd_psetex: return .Psetex, true
	case cmd_append: return .Append, true
	case cmd_strlen: return .Strlen, true
	case cmd_getrange: return .Getrange, true
	case cmd_setrange: return .Setrange, true
	case cmd_incr: return .Incr, true
	case cmd_decr: return .Decr, true
	case cmd_incrby: return .Incrby, true
	case cmd_decrby: return .Decrby, true
	case cmd_incrbyfloat: return .Incrbyfloat, true
	case cmd_mget: return .Mget, true
	case cmd_mset: return .Mset, true
	case cmd_msetnx: return .Msetnx, true
	case cmd_del: return .Del, true
	case cmd_exists: return .Exists, true
	case cmd_touch: return .Touch, true
	case cmd_type: return .Type, true
	case cmd_ttl: return .Ttl, true
	case cmd_pttl: return .Pttl, true
	case cmd_expiretime: return .Expiretime, true
	case cmd_pexpiretime: return .Pexpiretime, true
	case cmd_expire: return .Expire, true
	case cmd_pexpire: return .Pexpire, true
	case cmd_expireat: return .Expireat, true
	case cmd_pexpireat: return .Pexpireat, true
	case cmd_persist: return .Persist, true
	}
	return {}, false
}

keyspace_constant :: #force_inline proc "contextless" (op: Keyspace_Op, arity, argc: int) -> bool {
	single := argc == abs(arity)
	if op <= .Persist {
		return single || op < .Mget || op > .Touch
	}
	return op >= .Hset && op <= .Hpersist && single && (op < .Hgetall || op > .Hvals) && (op < .Hrandfield || op > .Hscan)
}

keyspace_lone :: #force_inline proc "contextless" (c: ^Conn, slot: ^Cmd_Slot, op: Keyspace_Op, argc: int) -> bool {
	return c.rpos >= c.rlen && keyspace_constant(op, slot.cmd.arity, argc)
}

keyspace_candidate :: #force_inline proc(slot: ^Cmd_Slot, argv: [][]u8) -> bool {
	if keyspace_threads == 0 || slot == nil {
		return false
	}
	op, ok := slot.keyspace.?
	return ok && len(argv) >= 2 && (op != .Stream || keyspace_stream_admission(slot.cmd.name, argv))
}

keyspace_eligible :: proc(c: ^Conn) -> bool {
	if lua_active != nil {
		return false
	}
	return keyspace_threads > 0 && keyspace_max_memory > 0 && !labels_on && !keyspace_in_fence && !keyspace_replay_needed && c.fd >= 0 && c.kind == .Redis && c.db != nil && c.compute == nil && c.keyspace_inflight < KEYSPACE_CONN_DEPTH && c.blocked == .None && !c.held && !c.close_after && c.ps - {.Tracking} == {} && .Multi not_in c.txf && tx_exec_conn == nil && !deny_blocking && (ps_exec == nil || ps_exec == c) && !ps_hooked && memory_worker_admissible() && !pst.loading && !pst.serve_while_loading && !pst.in_child && !aof.loading
}

keyspace_start :: proc() -> bool {
	if pst.in_child || keyspace_threads == 0 || keyspace_max_memory == 0 {
		return false
	}
	if !keyspace_initialized {
		if !ks.init(&keyspace_pool, int(keyspace_threads), int(keyspace_max_memory), diagnostics_thread_enter, diagnostics_thread_leave, diagnostics_worker_failure()) {
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

keyspace_ticket :: proc(tickets: ^[dynamic]Keyspace_Ready, c: ^Conn) {
	saved := context.allocator
	context.allocator = runtime.heap_allocator()
	append(tickets, Keyspace_Ready{fd = c.fd, id = c.id})
	context.allocator = saved
}

keyspace_queue_ready :: proc(c: ^Conn) {
	if !c.keyspace_ready {
		c.keyspace_ready = true
		keyspace_ticket(&keyspace_ready, c)
	}
}

keyspace_complete :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	inline := task.inline
	keyspace_worker_ns += job.elapsed_ns
	if job.cancelled { task.failed = true }
	if !task.failed {
		pst.dirty += task.dirty
		srv.stat_hits += task.hits
		srv.stat_misses += task.misses
		stat_expired_subkeys += task.subexpired
		stat_dump_sanitizations += task.sanitized
	}
	srv.stat_expired += task.expired
	if !task.failed {
		if !inline && task.op == .Get { keyspace_gets += 1 }
		if !inline && task.op == .Set { keyspace_sets += 1 }
		stat_keyspace_complete(&task.client, task.stats, task.argv, mono_now() - task.start)
	}
	c: ^Conn
	if int(task.fd) >= 0 && int(task.fd) < len(srv.conns) {
		c = srv.conns[task.fd]
	}
	valid := c != nil && c.id == task.client_id && c.keyspace_inflight > 0 && c.keyspace_token == task.token
	source := c if valid else nil
	keyspace_features_publish(task, source)
	if valid {
		c.keyspace_inflight -= 1
		c.atime_ms = max(c.atime_ms, lua_connection_clock())
		if !task.failed && !task.suppressed {
			keyspace_reply(c, task)
		}
		if task.failed || !inline { keyspace_queue_ready(c) }
	}
	keyspace_features_after_reply(task, source)
	if task.failed {
		saved := context.allocator
		context.allocator = runtime.heap_allocator()
		append(&keyspace_retries, task)
		context.allocator = saved
		keyspace_fallbacks += 1
	} else { keyspace_task_free(task) }
	keyspace_pending -= 1
	if !inline { keyspace_completed += 1 }
}

keyspace_stage :: proc(task: ^Keyspace_Task) {
	if task.failed { keyspace_replay_needed = true }
	index := int(task.sequence % ks.CAPACITY)
	if keyspace_completions[index] != nil { store_fatal("keyspace completion sequence collision") }
	keyspace_completions[index] = task
	keyspace_completion_count += 1
}

keyspace_collect :: proc(publish_ready: bool = true) {
	if !keyspace_initialized {
		return
	}
	if keyspace_notified {
		keyspace_notified = false
		ks.drain_notifications(&keyspace_pool)
	}
	jobs: [ks.CAPACITY]^ks.Job = ---
	count := ks.poll_all(&keyspace_pool, jobs[:])
	for job in jobs[:count] {
		task := cast(^Keyspace_Task)job.data
		if job.cancelled { task.failed = true }
		keyspace_stage(task)
	}
	if publish_ready { keyspace_publish_completions(false) }
}

keyspace_publish_completions :: proc(replay: bool) {
	for keyspace_completion_count > 0 {
		index := int(keyspace_publish_sequence % ks.CAPACITY)
		task := keyspace_completions[index]
		if task == nil || task.sequence != keyspace_publish_sequence || task.failed && !replay { break }
		keyspace_completions[index] = nil
		keyspace_completion_count -= 1
		keyspace_publish_sequence += 1
		keyspace_complete(&task.job)
		if replay && len(keyspace_retries) > 0 { keyspace_retry_all() }
	}
}

keyspace_fence_idle :: #force_inline proc "contextless" () -> bool {
	return keyspace_records == 0 && keyspace_pending == 0 && keyspace_completion_count == 0 && len(keyspace_retries) == 0 && !keyspace_replay_needed && keyspace_publish_sequence == keyspace_next_sequence
}

keyspace_fence :: proc() {
	if !keyspace_initialized || keyspace_in_fence {
		return
	}
	if keyspace_fence_idle() {
		keyspace_timed = false
		return
	}
	keyspace_in_fence = true
	defer keyspace_in_fence = false
	ks.pause(&keyspace_pool)
	if keyspace_records > 0 || keyspace_pending > 0 {
		keyspace_barriers += 1
	}
	keyspace_collect(false)
	if ks.pending(&keyspace_pool) != 0 || keyspace_completion_count != keyspace_pending {
		store_fatal("keyspace fence staging invariant")
	}
	saved_db := db_cur
	defer db_cur = saved_db
	saved_reconciling := store_reconciling
	store_reconciling = true
	visited := 0
	slots := keyspace_index_slots()
	for &slot in slots {
		r := slot.record
		if r == nil {
			continue
		}
		if r.changed && r.exists && !r.value_changed {
			keyspace_store_import_metadata(&dbs[r.db], transmute([]u8)r.key, r.clock, r.expire_at)
		} else if r.changed && r.exists && r.kind != u8(Obj_Type.String) {
			keyspace_object_import(&dbs[r.db], r)
		} else if r.changed && r.exists && r.string_copy {
			keyspace_store_import_copy(&dbs[r.db], transmute([]u8)r.key, ks.value_data(r.value), r.clock, r.expire_at, r.encoding)
		} else if r.changed || r.touched {
			keyspace_store_import_full(&dbs[r.db], transmute([]u8)r.key, ks.value_data(r.value), r.clock, r.changed, r.exists, r.expire_at, r.encoding)
		}
		if !ks.record_free(&keyspace_pool, r) {
			store_fatal("keyspace record release invariant")
		}
		slot = {}
		visited += 1
	}
	if visited != keyspace_records {
		store_fatal("keyspace record index invariant")
	}
	keyspace_index_reset()
	store_reconciling = saved_reconciling
	keyspace_records = 0
	keyspace_timed = false
	keyspace_publish_completions(true)
	keyspace_replay_needed = false
	if keyspace_pending != 0 || keyspace_completion_count != 0 || len(keyspace_retries) != 0 || keyspace_publish_sequence != keyspace_next_sequence {
		store_fatal("keyspace fence publication invariant")
	}
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
	delete(keyspace_waiting)
	keyspace_waiting = nil
	delete(keyspace_retries)
	keyspace_retries = nil
}

keyspace_conn_closed :: proc(c: ^Conn) {
	c.keyspace_inflight = 0
	c.keyspace_token = 0
	c.keyspace_ready = false
	c.keyspace_waiting = false
}

keyspace_tick :: proc() {
	if pst.in_child || !keyspace_initialized || keyspace_in_fence {
		return
	}
	keyspace_collect()
	if keyspace_replay_needed { keyspace_fence() }
	if len(keyspace_waiting) > 0 && keyspace_pending < ks.CAPACITY {
		waiting := keyspace_waiting
		keyspace_waiting = nil
		keyspace_resume(waiting, true)
	}
	ready := keyspace_ready
	keyspace_ready = nil
	keyspace_resume(ready, false)
}

keyspace_resume :: proc(tickets: [dynamic]Keyspace_Ready, waiting: bool) {
	keyspace_draining_ready_bytes += cap(tickets) * size_of(Keyspace_Ready)
	for ticket in tickets {
		if int(ticket.fd) < 0 || int(ticket.fd) >= len(srv.conns) {
			continue
		}
		c := srv.conns[ticket.fd]
		if c == nil || c.id != ticket.id {
			continue
		}
		if waiting {
			if !c.keyspace_waiting { continue }
			c.keyspace_waiting = false
		} else {
			if !c.keyspace_ready { continue }
			c.keyspace_ready = false
		}
		process_input(c)
		conn_flush(c)
	}
	keyspace_draining_ready_bytes -= cap(tickets) * size_of(Keyspace_Ready)
	delete(tickets)
}

keyspace_task_free :: proc(task: ^Keyspace_Task) {
	ks.value_release(task.hash_expired)
	for value in task.values { ks.value_release(value) }
	for value in task.results { ks.value_release(value) }
	for state in task.poststates { ks.value_release(state.payload) }
	if !ks.free(&keyspace_pool, task.region) { store_fatal("keyspace task release invariant") }
}

keyspace_index_slots :: #force_inline proc "contextless" () -> []Keyspace_Slot {
	return keyspace_index if len(keyspace_index) != 0 else keyspace_index_fixed[:]
}

keyspace_index_reset :: proc "contextless" () {
	if len(keyspace_index) == 0 {
		return
	}
	region := (cast([^]u8)raw_data(keyspace_index))[:len(keyspace_index) * size_of(Keyspace_Slot)]
	keyspace_index = nil
	if !ks.free(&keyspace_pool, region) { store_fatal("keyspace record index release invariant") }
}

keyspace_index_find :: proc "contextless" (hash: u64, key: []u8) -> ^ks.Record {
	slots := keyspace_index_slots()
	mask := u64(len(slots) - 1)
	tag, length := u32(hash), u32(len(key))
	for i := hash & mask; ; i = (i + 1) & mask {
		slot := slots[i]
		if slot.record == nil { return nil }
		if slot.tag == tag && slot.length == length && string(ks.record_key(slot.record, len(key))) == string(key) { return slot.record }
	}
}

keyspace_index_place :: proc "contextless" (slots: []Keyspace_Slot, slot: Keyspace_Slot) {
	mask := u64(len(slots) - 1)
	i := u64(slot.tag) & mask
	for slots[i].record != nil { i = (i + 1) & mask }
	slots[i] = slot
}

keyspace_index_prefetch :: proc "contextless" (hashes: []u64) #no_bounds_check {
	slots := keyspace_index_slots()
	mask := u64(len(slots) - 1)
	for hash in hashes {
		i := hash & mask
		for _ in 0 ..< 4 {
			slot := slots[i]
			if slot.record == nil { break }
			if slot.tag == u32(hash) {
				ks.record_prefetch(slot.record, int(slot.length))
				break
			}
			i = (i + 1) & mask
		}
	}
}

keyspace_index_reserve :: proc "contextless" () -> bool {
	slots := keyspace_index_slots()
	if 2 * (keyspace_records + 1) <= len(slots) {
		return true
	}
	if len(slots) > max(int) / (2 * size_of(Keyspace_Slot)) || 2 * len(slots) > 1 << 32 {
		return false
	}
	size := 2 * len(slots)
	region := ks.allocate(&keyspace_pool, size * size_of(Keyspace_Slot))
	if len(region) == 0 {
		return false
	}
	runtime.mem_zero(raw_data(region), len(region))
	grown := (cast([^]Keyspace_Slot)raw_data(region))[:size]
	for slot in slots {
		if slot.record != nil { keyspace_index_place(grown, slot) }
	}
	if len(keyspace_index) == 0 { keyspace_index_fixed = {} } else { keyspace_index_reset() }
	keyspace_index = grown
	return true
}

keyspace_index_insert :: proc "contextless" (hash: u64, r: ^ks.Record) {
	keyspace_index_place(keyspace_index_slots(), Keyspace_Slot{record = r, tag = u32(hash), length = u32(len(r.key))})
	keyspace_records += 1
}

keyspace_record :: proc(db: ^Db, key: []u8) -> ^ks.Record {
	if len(key) > int(max(u32)) { return nil }
	hash := hash_bytes(key) ~ (u64(db.id) * WY_P1)
	if r := keyspace_index_find(hash, key); r != nil { return r }
	if !keyspace_index_reserve() { return nil }
	seed, clock, expires, encoding, exists, eligible := keyspace_store_seed_full(db, key)
	r: ^ks.Record
	if eligible {
		r = ks.record_new(&keyspace_pool, db.id, key, int(hash % u64(keyspace_threads)), exists, seed, clock)
		if r == nil { return nil }
		r.expire_at = expires
		r.encoding = encoding
		if exists && encoding == u8(Obj_Encoding.Int) { r.string_copy = keyspace_store_string_copy(db, key) }
	} else {
		r = keyspace_object_seed(db, key, int(hash % u64(keyspace_threads)))
		if r == nil { return nil }
	}
	if r.expire_at != 0 { keyspace_timed = true }
	keyspace_index_insert(hash, r)
	return r
}

keyspace_key_indices :: proc(spec: ^Cmd_Spec, argv: [][]u8, fixed: ^[KEYSPACE_KEY_INDICES]int) -> [dynamic]int {
	indices := transmute([dynamic]int)runtime.Raw_Dynamic_Array{data = fixed, cap = len(fixed), allocator = runtime.nil_allocator()}
	command_keys(spec, argv, &indices)
	if len(indices) < len(fixed) {
		return indices
	}
	indices = make([dynamic]int, 0, 2 * len(fixed), runtime.heap_allocator())
	command_keys(spec, argv, &indices)
	return indices
}

keyspace_try :: proc(c: ^Conn, slot: ^Cmd_Slot, argv: [][]u8) -> bool {
	if !keyspace_candidate(slot, argv) || !keyspace_eligible(c) {
		keyspace_fence()
		return false
	}
	op, _ := slot.keyspace.?
	lone := keyspace_lone(c, slot, op, len(argv))
	if lone && keyspace_fence_idle() {
		keyspace_inline += 1
		return false
	}
	start := mono_now()
	if !keyspace_start() || keyspace_pending >= ks.CAPACITY {
		keyspace_fallbacks += 1
		keyspace_fence()
		return false
	}
	cmd := slot.cmd
	stats := slot.stats
	restore := op == .Key && cmd.name == "restore"
	if restore && len(argv) > 3 && vset_payload_module(argv[3]) { keyspace_fence(); return false }
	relocate := op == .Key && (cmd.name == "copy" || cmd.name == "move")
	if (op >= .Hset && op <= .Hpersist) || restore { keyspace_timed = true }
	if op == .Setex || op == .Psetex || op == .Getex || op == .Expire || op == .Pexpire || op == .Expireat || op == .Pexpireat || (op == .Set && len(argv) > 3) { keyspace_timed = true }
	if (op == .Mset || op == .Msetnx) && len(argv) % 2 == 0 { keyspace_fence(); return false }
	spec := cmd_spec_lookup(cmd, argv)
	if spec == nil || !arity_ok(int(spec.arity), len(argv)) { keyspace_fence(); return false }
	fixed: [KEYSPACE_KEY_INDICES]int = ---
	indices := keyspace_key_indices(spec, argv, &fixed)
	defer delete(indices)
	target_db := c.db.id
	if relocate {
		id, _, ok := keyspace_key_target(cmd.name, argv, c.db.id)
		if !ok { keyspace_fence(); return false }
		target_db = id
		if cmd.name == "move" { append(&indices, 1) }
	}
	count := len(indices)
	if count == 0 { keyspace_fence(); return false }
	for index in indices { if index < 1 || index >= len(argv) { keyspace_fence(); return false } }
	for index, i in indices {
		db := c.db.id
		if relocate && i == 1 { db = target_db }
		if keyspace_features_blocked(db, argv[index]) || !mc_worker_key_admissible(&dbs[db], argv[index]) || expiry_deletion_paused() && !keyspace_store_pause_admissible(&dbs[db], argv[index]) { keyspace_fence(); return false }
	}

	event_capacity := 0
	if key_hooks || cmd_hooks || watch_total > 0 || tracking_on || tracking_clients > 0 || notify_active != {} || len(monitors) > 0 || block_count() > 0 || aof.feed { event_capacity = len(argv) * 8 + 64 }
	poststate_capacity := count if aof.feed else 0
	bytes := u128(event_capacity) * size_of(Keyspace_Event) + u128(poststate_capacity) * size_of(Keyspace_Poststate) + u128(size_of(Keyspace_Task)) + u128(len(argv)) * size_of([]u8) + u128(count) * (size_of(^ks.Record) + 2 * size_of(^ks.Value)) + u128(len(c.name))
	for arg in argv { bytes += u128(len(arg)) }
	if bytes > u128(max(int)) { keyspace_fence(); return false }
	region := ks.allocate(&keyspace_pool, int(bytes))
	if len(region) == 0 { keyspace_fallbacks += 1; keyspace_fence(); return false }
	task := cast(^Keyspace_Task)raw_data(region)
	task^ = Keyspace_Task{region = region, op = op, command_name = cmd.name, command = cmd, capture_poststate = aof.feed, access = memory_worker_access_snapshot(), now = expire_now(), limit = min(string_max_len(), i64(max(u32)) - 2 * STRING_DOUBLING_LIMIT)}
	offset := size_of(Keyspace_Task)
	task.argv = (cast([^][]u8)(&region[offset]))[:len(argv)]
	offset += len(argv) * size_of([]u8)
	task.records = (cast([^]^ks.Record)(&region[offset]))[:count]
	offset += count * size_of(^ks.Record)
	task.values = (cast([^]^ks.Value)(&region[offset]))[:count]
	offset += count * size_of(^ks.Value)
	task.results = (cast([^]^ks.Value)(&region[offset]))[:count]
	offset += count * size_of(^ks.Value)
	if event_capacity > 0 {
		task.event_storage = (cast([^]Keyspace_Event)(&region[offset]))[:event_capacity]
		task.events = task.event_storage[:0]
		offset += event_capacity * size_of(Keyspace_Event)
	}
	if poststate_capacity > 0 {
		task.poststate_storage = (cast([^]Keyspace_Poststate)(&region[offset]))[:poststate_capacity]
		task.poststates = task.poststate_storage[:0]
		offset += poststate_capacity * size_of(Keyspace_Poststate)
	}
	for i in 0 ..< count { task.values[i] = nil; task.results[i] = nil }
	for arg, i in argv {
		task.argv[i] = region[offset:offset + len(arg)]
		copy(task.argv[i], arg)
		offset += len(arg)
	}
	for i in 0 ..< count {
		db := c.db
		if relocate && i == 1 { db = &dbs[target_db] }
		task.records[i] = keyspace_record(db, argv[indices[i]])
		if task.records[i] == nil { keyspace_task_free(task); keyspace_fallbacks += 1; keyspace_fence(); return false }
	}
	if restore { task.restore_deep = persist_deep_sanitize(true) && !(pst.sanitize == .Clients && acl_skips_sanitize(c)) }
	task.client = Conn{fd = -1, id = c.id, addr = c.addr, addr_len = c.addr_len, db = c.db, kind = c.kind, flags = c.flags, resp = c.resp}
	if restore && c.user != nil {
		task.restore_user.attributes = c.user.attributes
		task.client.user = &task.restore_user
	}
	task.client.name = region[offset:offset + len(c.name)]
	copy(task.client.name, c.name)
	task.fd = c.fd
	task.client_id = c.id
	if c.keyspace_inflight == 0 {
		keyspace_next_token += 1
		if keyspace_next_token == 0 { keyspace_next_token += 1 }
		c.keyspace_token = keyspace_next_token
	}
	task.token = c.keyspace_token
	task.sequence = keyspace_next_sequence
	task.start = start
	task.stats = stats
	task.suppressed = c.reply & {.Off, .Skip} != {}
	task.forked = pst.child_pid > 0
	task.job = ks.Job{op = .Custom, record = task.records[0], records = task.records, context_executor = keyspace_execute_context, clock = access_seconds_now, touch = .No_Touch not_in c.flags && !task.forked, data = task}
	if lone && keyspace_pending == 0 && keyspace_completion_count == 0 && len(keyspace_retries) == 0 && ks.execute_inline(&keyspace_pool, &task.job) {
		task.inline = true
		keyspace_next_sequence += 1
		c.keyspace_inflight += 1
		keyspace_pending += 1
		keyspace_inline += 1
		stat_cur = nil
		keyspace_stage(task)
		keyspace_publish_completions(false)
		mem_note_peak()
		return true
	}
	if !ks.submit(&keyspace_pool, &task.job) {
		keyspace_task_free(task)
		keyspace_fallbacks += 1
		keyspace_fence()
		return false
	}
	keyspace_next_sequence += 1
	c.keyspace_inflight += 1
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
	info_line_int(b, "keyspace_inline", keyspace_inline)
	info_line_int(b, "keyspace_barriers", keyspace_barriers)
	info_line_int(b, "keyspace_worker_signals", i64(ks.signal_count(&keyspace_pool)))
	info_line_int(b, "keyspace_worker_nanoseconds", keyspace_worker_ns)
}

Keyspace_Write :: struct {
	nx, xx, get, keep, persist, ifeq: bool,
	deadline: i64,
	has_deadline: bool,
	expected: []u8,
}

keyspace_deadline :: proc "contextless" (now: i64, form, text: []u8) -> (i64, bool) {
	amount, ok := parse_i64(text)
	if !ok || amount <= 0 { return 0, false }
	if eq_nocase(form, "ex") || eq_nocase(form, "exat") {
		if amount > max(i64) / 1000 { return 0, false }
		amount *= 1000
	}
	if eq_nocase(form, "ex") || eq_nocase(form, "px") {
		if amount > max(i64) - now { return 0, false }
		amount += now
	}
	return min(amount, MAX_EXPIRE_MS), true
}

keyspace_write_plan :: proc "contextless" (task: ^Keyspace_Task, setting: bool) -> (plan: Keyspace_Write, ok: bool) {
	argv := task.argv
	from := 3 if setting else 2
	last_form: []u8
	for i := from; i < len(argv); i += 1 {
		a := argv[i]
		switch {
		case setting && eq_nocase(a, "nx"):
			if plan.xx || plan.ifeq { return plan, false }; plan.nx = true
		case setting && eq_nocase(a, "xx"):
			if plan.nx || plan.ifeq { return plan, false }; plan.xx = true
		case setting && eq_nocase(a, "get"): plan.get = true
		case setting && eq_nocase(a, "keepttl"):
			if plan.has_deadline { return plan, false }; plan.keep = true
		case !setting && eq_nocase(a, "persist"):
			if plan.has_deadline { return plan, false }; plan.persist = true
		case setting && eq_nocase(a, "ifeq"):
			if plan.nx || plan.xx || plan.ifeq || i + 1 >= len(argv) { return plan, false }
			plan.ifeq = true; i += 1; plan.expected = argv[i]
		case:
			if !(eq_nocase(a, "ex") || eq_nocase(a, "px") || eq_nocase(a, "exat") || eq_nocase(a, "pxat")) || i + 1 >= len(argv) || plan.keep || plan.persist { return plan, false }
			if plan.has_deadline && !eq_nocase(a, transmute(string)last_form) { return plan, false }
			last_form = a
			i += 1
			at, parsed := keyspace_deadline(task.now, a, argv[i])
			if !parsed { return plan, false }
			plan.deadline = at; plan.has_deadline = true
		}
	}
	return plan, true
}

keyspace_remove :: proc "contextless" (r: ^ks.Record) {
	ks.record_object_clear(r)
	ks.value_release(r.value)
	r.value = nil
	r.exists = false
	r.expire_at = 0
	r.changed = true
	r.value_changed = true
}

keyspace_touch :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record, force: bool = false, created: bool = false) {
	if r.exists && (task.job.touch || (force && !task.forked) || created) {
		r.clock = memory_worker_access_touch(&task.access, r.clock, created)
		r.touched = true
	}
}

keyspace_read :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record, touch: bool = true) {
	if r.exists {
		task.hits += 1
		if touch { keyspace_touch(task, r) }
	} else { task.misses += 1; keyspace_notify(task, r, .Key_Miss, "keymiss") }
}

keyspace_save :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record, value: ^ks.Value, expires: i64) {
	created := !r.exists
	ks.record_object_clear(r)
	r.kind = u8(Obj_Type.String)
	old := r.value
	r.value = ks.value_retain(value)
	r.exists = true
	r.changed = true
	r.value_changed = true
	r.string_copy = false
	r.expire_at = expires
	r.encoding = u8(string_encoding_of(ks.value_data(value)))
	keyspace_touch(task, r, created = created)
	ks.value_release(old)
	if created { keyspace_notify(task, r, .New, "new") }
}

keyspace_value :: proc "contextless" (task: ^Keyspace_Task, bytes: []u8, index: int = 0) -> bool {
	task.values[index] = ks.value_new(&keyspace_pool, bytes)
	if task.values[index] == nil { task.failed = true; return false }
	return true
}

keyspace_bulk :: proc "contextless" (task: ^Keyspace_Task, r: ^ks.Record) {
	task.bulk = true
	task.null = !r.exists
	if r.exists { task.results[0] = ks.value_retain(r.value) }
}

keyspace_execute :: proc "contextless" (job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	defer job.abort = task.failed
	if !keyspace_validate(task) || !keyspace_string_types(task) { task.failed = true; return }
	argv := task.argv
	r := task.records[0]
	if task.op != .Msetnx {
		for record in task.records { keyspace_expire(task, record) }
	}
	value := ks.value_data(r.value)
	op := task.op
	#partial switch op {
	case .Llen, .Lindex, .Lrange, .Lpos, .Lpush, .Rpush, .Lpushx, .Rpushx, .Lpop, .Rpop, .Lset, .Linsert, .Ltrim, .Lrem, .Lmove, .Rpoplpush, .Lmpop:
	case .Get:
		keyspace_read(task, r); keyspace_bulk(task, r)
	case .Set, .Getset, .Setnx, .Setex, .Psetex:
		plan: Keyspace_Write
		text := argv[2]
		if op == .Set {
			parsed: bool
			plan, parsed = keyspace_write_plan(task, true)
			if !parsed { task.failed = true; return }
		}
		if op == .Setex || op == .Psetex {
			form := "ex" if op == .Setex else "px"
			at, parsed := keyspace_deadline(task.now, transmute([]u8)form, argv[2])
			if !parsed { task.failed = true; return }
			plan.deadline = at; text = argv[3]
		}
		if op == .Setnx { plan.nx = true }
		if op == .Getset { plan.get = true }
		if plan.get { keyspace_read(task, r); keyspace_bulk(task, r) } else { keyspace_touch(task, r) }
		write := !(plan.nx && r.exists) && !(plan.xx && !r.exists) && !(plan.ifeq && (!r.exists || !bytes_eq(value, plan.expected)))
		if !write {
			if op != .Setnx && !plan.get { task.null = true }
			return
		}
		if !keyspace_value(task, text) { return }
		expires := plan.deadline
		if plan.keep { expires = r.expire_at }
		keyspace_save(task, r, task.values[0], expires)
		keyspace_changed(task, r, .String, "set")
		if plan.has_deadline || op == .Setex || op == .Psetex { keyspace_notify(task, r, .Generic, "expire") }
		task.dirty = 1
		if op == .Setnx { task.integer = 1 } else if !plan.get { task.ok = true }
	case .Getex, .Getdel:
		plan: Keyspace_Write
		if op == .Getex {
			parsed: bool
			plan, parsed = keyspace_write_plan(task, false)
			if !parsed { task.failed = true; return }
		}
		keyspace_read(task, r); keyspace_bulk(task, r)
		if !r.exists { return }
		if op == .Getdel || (plan.has_deadline && plan.deadline <= task.now) {
			keyspace_remove(r); task.dirty = 1; keyspace_changed(task, r, .Generic, "del")
		} else if plan.has_deadline || (plan.persist && r.expire_at != 0) {
			r.expire_at = plan.deadline; r.changed = true; task.dirty = 1
			keyspace_changed(task, r, .Generic, "expire" if plan.has_deadline else "persist")
		}
	case .Strlen:
		keyspace_read(task, r); task.integer = i64(len(value))
	case .Getrange:
		from, a := parse_i64(argv[2]); to, b := parse_i64(argv[3])
		if !a || !b { task.failed = true; return }
		keyspace_read(task, r)
		task.bulk = true
		size := i64(len(value))
		if size == 0 { return }
		if from < 0 { from += size }; if to < 0 { to += size }
		from = max(from, 0); to = min(max(to, 0), size - 1)
		if from > to { return }
		task.results[0] = ks.value_retain(r.value); task.from = from; task.to = to + 1
	case .Append, .Setrange:
		offset := i64(len(value))
		text := argv[2]
		if op == .Setrange {
			parsed: bool
			offset, parsed = parse_i64(argv[2])
			if !parsed || offset < 0 { task.failed = true; return }
			text = argv[3]
			if len(text) == 0 { keyspace_touch(task, r); task.integer = i64(len(value)); return }
		}
		if offset > task.limit - i64(len(text)) { task.failed = true; return }
		size := max(len(value), int(offset) + len(text))
		region := ks.allocate(&keyspace_pool, size)
		if size != 0 && len(region) == 0 { task.failed = true; return }
		for &byte in region { byte = 0 }
		copy(region, value); copy(region[int(offset):], text)
		allocated := keyspace_value(task, region)
		ks.free(&keyspace_pool, region)
		if !allocated { return }
		existed := r.exists
		keyspace_save(task, r, task.values[0], r.expire_at)
		if op == .Setrange || existed { r.encoding = u8(Obj_Encoding.Raw) }
		task.dirty = 1; task.integer = i64(size)
		keyspace_changed(task, r, .String, "append" if op == .Append else "setrange")
	case .Incr, .Decr, .Incrby, .Decrby:
		delta: i64 = 1
		if op == .Decr { delta = -1 }
		if op == .Incrby || op == .Decrby {
			parsed: bool
			delta, parsed = parse_i64(argv[2])
			if !parsed || (op == .Decrby && delta == min(i64)) { task.failed = true; return }
			if op == .Decrby { delta = -delta }
		}
		current: i64
		if r.exists {
			parsed: bool
			current, parsed = parse_i64(value)
			if !parsed { task.failed = true; return }
		}
		if (delta > 0 && current > max(i64) - delta) || (delta < 0 && current < min(i64) - delta) { task.failed = true; return }
		task.integer = current + delta
		digits: [24]u8
		n := format_i64(raw_data(digits[:]), task.integer)
		if !keyspace_value(task, digits[:n]) { return }
		keyspace_save(task, r, task.values[0], r.expire_at); task.dirty = 1
		keyspace_changed(task, r, .String, "incrby")
	case .Incrbyfloat:
		step, parsed := ld.parse(argv[2])
		if !parsed { task.failed = true; return }
		current := ld.zero(false)
		if r.exists {
			valid: bool
			current, valid = ld.parse(value)
			if !valid { task.failed = true; return }
		}
		total := ld.add(current, step)
		if !ld.is_finite(total) { task.failed = true; return }
		text: [ld.MAX_LONG_DOUBLE_CHARS]u8
		n := ld.format_human(total, text[:])
		if !keyspace_value(task, text[:n]) { return }
		keyspace_save(task, r, task.values[0], r.expire_at)
		r.encoding = u8(Obj_Encoding.Embstr if n <= EMBEDDED_STRING_MAX else Obj_Encoding.Raw)
		task.dirty = 1; keyspace_bulk(task, r)
		keyspace_changed(task, r, .String, "incrbyfloat")
	case .Mget:
		task.array = true
		for record, i in task.records {
			keyspace_read(task, record)
			if record.exists && record.kind == u8(Obj_Type.String) { task.results[i] = ks.value_retain(record.value) }
		}
	case .Mset, .Msetnx:
		if op == .Msetnx {
			for record in task.records {
				keyspace_expire(task, record)
				keyspace_touch(task, record)
				if record.exists { return }
			}
		}
		for _, i in task.records {
			if !keyspace_value(task, argv[2 + i * 2], i) { return }
		}
		for record, i in task.records { keyspace_save(task, record, task.values[i], 0); keyspace_changed(task, record, .String, "set") }
		task.dirty = i64(len(task.records)); task.ok = op == .Mset; task.integer = 1
	case .Del, .Exists, .Touch:
		for record in task.records {
			if op == .Exists { keyspace_read(task, record, false) }
			if op == .Touch { keyspace_read(task, record, false) }
			if record.exists {
				task.integer += 1
				if op == .Del { keyspace_remove(record); keyspace_changed(task, record, .Generic, "del") }
				if op == .Touch { keyspace_touch(task, record, true) }
			}
		}
		if op == .Del { task.dirty = task.integer }
	case .Type:
		keyspace_read(task, r, false); task.status = type_name(Obj_Type(r.kind)) if r.exists else "none"
	case .Ttl, .Pttl, .Expiretime, .Pexpiretime:
		keyspace_read(task, r, false)
		if !r.exists { task.integer = -2; return }
		if r.expire_at == 0 { task.integer = -1; return }
		task.integer = r.expire_at
		if op == .Ttl || op == .Pttl { task.integer -= task.now }
		if op == .Ttl || op == .Expiretime { task.integer = (task.integer + 500) / 1000 }
	case .Persist:
		keyspace_touch(task, r)
		if r.exists && r.expire_at != 0 { r.expire_at = 0; r.changed = true; task.integer = 1; task.dirty = 1; keyspace_changed(task, r, .Generic, "persist") }
	case .Expire, .Pexpire, .Expireat, .Pexpireat:
		nx, xx, gt, lt := false, false, false, false
		for arg in argv[3:] {
			switch {
			case eq_nocase(arg, "nx"): nx = true
			case eq_nocase(arg, "xx"): xx = true
			case eq_nocase(arg, "gt"): gt = true
			case eq_nocase(arg, "lt"): lt = true
			case: task.failed = true; return
			}
		}
		if (nx && (xx || gt || lt)) || (gt && lt) { task.failed = true; return }
		at, parsed := parse_i64(argv[2])
		if !parsed { task.failed = true; return }
		if op == .Expire || op == .Expireat {
			if at > max(i64) / 1000 || at < min(i64) / 1000 { task.failed = true; return }; at *= 1000
		}
		if op == .Expire || op == .Pexpire {
			if at > max(i64) - task.now { task.failed = true; return }; at += task.now
		}
		keyspace_touch(task, r)
		if !r.exists { return }
		current := r.expire_at
		if (nx && current != 0) || (xx && current == 0) || (gt && (current == 0 || at <= current)) || (lt && current != 0 && at >= current) { return }
		if at <= task.now { keyspace_remove(r) } else { r.expire_at = min(at, MAX_EXPIRE_MS); r.changed = true }
		task.integer = 1; task.dirty = 1
		keyspace_changed(task, r, .Generic, "expire" if r.exists else "del")
	}
}

keyspace_reply :: proc(c: ^Conn, task: ^Keyspace_Task) {
	if task.raw {
		bytes := ks.value_data(task.results[0])
		out := wb_reserve(c, len(bytes))
		copy(out[:len(bytes)], bytes)
		c.wlen += len(bytes)
		return
	}
	if task.array {
		reply_array(c, len(task.results))
		for value in task.results {
			if value == nil { reply_null(c) } else { reply_bulk(c, ks.value_data(value)) }
		}
	} else if task.null {
		reply_null(c)
	} else if task.bulk {
		bytes := ks.value_data(task.results[0])
		if task.op == .Getrange { bytes = bytes[task.from:task.to] }
		reply_bulk(c, bytes)
	} else if task.ok {
		reply_ok(c)
	} else if task.status != "" {
		reply_simple(c, task.status)
	} else { reply_int(c, task.integer) }
}

keyspace_retry_execute :: proc(task: ^Keyspace_Task, source: ^Conn) {
	c := source if source != nil else &task.client
	cmd, st := task.command, task.stats
	saved_ps, saved_db, saved_stat := ps_exec, db_cur, stat_cur
	saved_touch, saved_hooked, saved_managed := store_no_touch, ps_hooked, tx_reply_managed
	defer {
		ps_exec, db_cur, stat_cur = saved_ps, saved_db, saved_stat
		store_no_touch, ps_hooked, tx_reply_managed = saved_touch, saved_hooked, saved_managed
	}
	if task.suppressed && c.reply == {} { c.reply += {.Skip} }
	pending := c.wlen - c.wpos
	if source != nil && source.pubsub != nil { source.pubsub.mark = pending }
	ps_exec, db_cur = source, c.db
	store_no_touch = .No_Touch in task.client.flags && cmd.handler != cmd_touch
	dirty := pst.dirty
	tx_reply_managed = false
	if aof.feed { aof_cmd_begin(c, cmd, task.argv) }
	ps_hooked = true
	stat_cur = &st.stats
	start := mono_now()
	cmd.handler(c, task.argv)
	ticks := mono_now() - start
	ps_hooked = false
	if ticks < st.limit_ticks {
		#no_bounds_check st.small[(ticks * mono_mul) >> 32] += 1
		srv.stat_commands += 1
	} else { stat_call_slow(c, cmd, st, task.argv, ticks) }
	persist_note(c, cmd, task.argv, pending, dirty)
	if source != nil { pubsub_after(source, cmd, task.argv) }
	if len(monitors) > 0 { monitor_feed(c, cmd, task.argv) }
	if source != nil && client_buckets_on { client_bucket_track(source) }
	if !tx_reply_managed && c.reply & {.Off, .Skip} != {} { c.wlen = c.wpos + pending }
	c.reply -= {.Skip}
}

keyspace_retry_all :: proc() {
	retries := keyspace_retries
	keyspace_retries = nil
	keyspace_draining_ready_bytes += cap(retries) * size_of(^Keyspace_Task)
	for task in retries {
		saved_now := srv.now_ms
		srv.now_ms = task.now
		c: ^Conn
		if int(task.fd) >= 0 && int(task.fd) < len(srv.conns) { c = srv.conns[task.fd] }
		valid := c != nil && c.id == task.client_id && c.keyspace_token == task.token && c.keyspace_ready
		keyspace_retry_execute(task, c if valid else nil)
		srv.now_ms = saved_now
		if task.client.wbuf != nil { runtime.heap_free(task.client.wbuf) }
		keyspace_task_free(task)
	}
	keyspace_draining_ready_bytes -= cap(retries) * size_of(^Keyspace_Task)
	delete(retries)
}

keyspace_validate :: proc "contextless" (task: ^Keyspace_Task) -> bool {
	argv := task.argv
	#partial switch task.op {
	case .Set, .Getex:
		_, ok := keyspace_write_plan(task, task.op == .Set)
		return ok
	case .Setex, .Psetex:
		form := "ex" if task.op == .Setex else "px"
		_, ok := keyspace_deadline(task.now, transmute([]u8)form, argv[2])
		return ok
	case .Getrange:
		_, a := parse_i64(argv[2]); _, b := parse_i64(argv[3]); return a && b
	case .Setrange:
		offset, ok := parse_i64(argv[2]); return ok && offset >= 0
	case .Incrby, .Decrby:
		delta, ok := parse_i64(argv[2]); return ok && (task.op != .Decrby || delta != min(i64))
	case .Incrbyfloat:
		_, ok := ld.parse(argv[2]); return ok
	case .Expire, .Pexpire, .Expireat, .Pexpireat:
		nx, xx, gt, lt := false, false, false, false
		for arg in argv[3:] {
			switch {
			case eq_nocase(arg, "nx"): nx = true
			case eq_nocase(arg, "xx"): xx = true
			case eq_nocase(arg, "gt"): gt = true
			case eq_nocase(arg, "lt"): lt = true
			case: return false
			}
		}
		if (nx && (xx || gt || lt)) || (gt && lt) { return false }
		at, ok := parse_i64(argv[2])
		if !ok { return false }
		if task.op == .Expire || task.op == .Expireat {
			if at > max(i64) / 1000 || at < min(i64) / 1000 { return false }; at *= 1000
		}
		return (task.op != .Expire && task.op != .Pexpire) || at <= max(i64) - task.now
	case:
		return true
	}
}

keyspace_expire :: proc "contextless" (task: ^Keyspace_Task, record: ^ks.Record) {
	if record.exists && record.expire_at != 0 && record.expire_at <= task.now {
		keyspace_remove(record)
		task.expired += 1
		keyspace_invalidate(task, record, false, true)
		keyspace_notify(task, record, .Expired, "expired", true)
	}
}

keyspace_execute_context :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	if task.capture_poststate { keyspace_capture_execute(job) } else { keyspace_execute_kernel(job) }
}

keyspace_execute_kernel :: proc(job: ^ks.Job) {
	task := cast(^Keyspace_Task)job.data
	if task.op == .Key { keyspace_key_execute(job) } else if task.op == .Stream { keyspace_stream_execute(job) } else if task.op == .Geo { keyspace_geo_execute(job) } else if task.op == .Zset { keyspace_zset_execute(job) } else if task.op >= .Hset { keyspace_hash_execute(job) } else if task.op >= .Sadd { keyspace_set_execute(job) } else if task.op >= .Pfadd { keyspace_hll_execute(job) } else if task.op >= .Setbit { keyspace_bitmap_execute(job) } else if task.op >= .Llen { keyspace_list_execute(job) } else { keyspace_execute(job) }
}

keyspace_string_types :: proc "contextless" (task: ^Keyspace_Task) -> bool {
	#partial switch task.op {
	case .Get, .Getex, .Getdel, .Getset, .Append, .Strlen, .Getrange, .Setrange, .Incr, .Decr, .Incrby, .Decrby, .Incrbyfloat:
		return !task.records[0].exists || task.records[0].kind == u8(Obj_Type.String) || (task.records[0].expire_at != 0 && task.records[0].expire_at <= task.now)
	case .Set:
		plan, ok := keyspace_write_plan(task, true)
		r := task.records[0]
		return ok && (!(plan.get || plan.ifeq) || !r.exists || r.kind == u8(Obj_Type.String) || (r.expire_at != 0 && r.expire_at <= task.now))
	case: return true
	}
}

keyspace_task_record :: proc "contextless" (task: ^Keyspace_Task, key: []u8) -> ^ks.Record {
	for record in task.records { if record.key == transmute(string)key { return record } }
	return nil
}

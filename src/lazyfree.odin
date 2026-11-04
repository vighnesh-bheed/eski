package main

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import ht "hashtype"
import lt "listtype"
import rx "rax"
import st "settype"
import sm "streamtype"
import zt "zsettype"

LAZYFREE_THRESHOLD :: 64

Lazy_Job :: struct {
	tables:    [2]Table,
	ntables:   int,
	scan:      bool,
	type:      Obj_Type,
	obj:       rawptr,
	slab_base: [^]u8,
	slab_size: int,
	slab_live: int,
	bytes:     int,
	count:     int,
	waiter_fd: linux.Fd,
	waiter_id: i64,
	release: proc "contextless" (payload: rawptr),
	payload: rawptr,
}

Lazy_Mode :: enum u8 {
	Server,
	Sync,
	Async,
}

lazy_mode: Lazy_Mode
lazy_efd: linux.Fd = -1
lazy_blocked: int

@(private = "file")
lazy_mutex: sync.Mutex
@(private = "file")
lazy_sema: sync.Sema
@(private = "file")
lazy_queue: [dynamic]Lazy_Job
@(private = "file")
lazy_head: int
@(private = "file")
lazy_done: [dynamic][2]i64
@(private = "file")
lazy_thread: ^thread.Thread
@(private = "file")
lazy_pending_objs: int
@(private = "file")
lazy_freed: int
@(private = "file")
lazy_pending_mem: int
@(private = "file")
lazy_pending_slab: int
@(private = "file")
lazy_jobs: int

lazy_set :: #force_inline proc "contextless" (on: bool) -> Lazy_Mode {
	saved := lazy_mode
	lazy_mode = .Async if on else .Sync
	return saved
}

lazyfree_pending_bytes :: #force_inline proc "contextless" () -> int {
	return intrinsics.atomic_load_explicit(&lazy_pending_mem, .Relaxed)
}

lazyfree_pending_slab_bytes :: proc "contextless" () -> int {
	return intrinsics.atomic_load_explicit(&lazy_pending_slab, .Relaxed)
}

lazyfree_pending_objects :: proc "contextless" () -> i64 {
	return i64(intrinsics.atomic_load_explicit(&lazy_pending_objs, .Relaxed))
}

lazyfreed_objects :: proc "contextless" () -> i64 {
	return i64(intrinsics.atomic_load_explicit(&lazy_freed, .Relaxed))
}

lazyfree_note_deferred :: proc "contextless" (count: int) {
	intrinsics.atomic_add_explicit(&lazy_pending_objs, count, .Relaxed)
}

lazyfree_note_reaped :: proc "contextless" (count: int) {
	intrinsics.atomic_add_explicit(&lazy_freed, count, .Relaxed)
	intrinsics.atomic_sub_explicit(&lazy_pending_objs, count, .Relaxed)
}

lazyfree_jobs_pending :: proc "contextless" () -> bool {
	return intrinsics.atomic_load_explicit(&lazy_jobs, .Relaxed) > 0
}

lazyfree_reset_stats :: proc "contextless" () {
	intrinsics.atomic_store_explicit(&lazy_freed, 0, .Relaxed)
}

object_acct_of :: proc "contextless" (type: Obj_Type, obj: rawptr) -> int {
	#partial switch type {
	case .Set:
		return set_object_acct(obj)
	case .List:
		return list_object_acct(obj)
	case .Zset:
		return zset_object_acct(obj)
	case .Stream:
		return stream_object_acct(obj)
	case .Hash:
		return ht.Hash(obj).acct
	}
	return 0
}

object_release_any :: proc "contextless" (type: Obj_Type, obj: rawptr) {
	#partial switch type {
	case .Set:
		set_object_release(obj)
	case .List:
		list_object_release(obj)
	case .Zset:
		zset_object_release(obj)
	case .Stream:
		stream_object_release(obj)
	case:
		object_release(type, obj)
	}
}

lazyfree_effort :: proc(type: Obj_Type, obj: rawptr) -> int {
	#partial switch type {
	case .List:
		l := lt.List(obj)
		if l.encoding == .Quicklist {
			return l.ql.len
		}
	case .Set:
		s := st.Set(obj)
		if s.encoding == .Hashtable {
			return st.maintenance_effort(s)
		}
	case .Zset:
		z := zt.Zset(obj)
		if z.encoding == .Skiplist {
			return zt.maintenance_effort(z)
		}
	case .Hash:
		h := ht.Hash(obj)
		if h.encoding == .Hashtable {
			return ht.maintenance_effort(h)
		}
	case .Stream:
		s := sm.Stream(obj)
		effort := 2 * int(sm.node_count(s)) + 1
		if groups := int(sm.group_count(s)); groups > 0 {
			it: rx.Iterator
			rx.start(&it, s.groups)
			rx.seek(&it, "^")
			pel := 0
			if rx.next(&it) {
				pel = int((^sm.Group)(it.data).pending.stored)
			}
			rx.stop(&it)
			effort += groups * (1 + pel)
		}
		return effort
	}
	return 1
}

@(private = "file")
lazyfree_run :: proc "contextless" (job: ^Lazy_Job) {
	if job.release != nil { job.release(job.payload) }
	if job.obj != nil {
		object_release_any(job.type, job.obj)
	}
	for i in 0 ..< job.ntables {
		t := &job.tables[i]
		if job.scan && t.live > 0 {
			table_release_values(t)
		}
		intrinsics.atomic_sub_explicit(&storage_table_bytes, t.size, .Relaxed)
		storage_unmap(t.region, t.size, .Table)
	}
	if job.slab_base != nil && job.slab_size > 0 {
		storage_unmap(job.slab_base, job.slab_size, .Slab)
	}
}

@(private = "file")
lazyfree_main :: proc() {
	context.assertion_failure_proc = diagnostics_assertion_failure if intrinsics.atomic_load_explicit(&diagnostic_initialized, .Acquire) != 0 else context.assertion_failure_proc
	diagnostics_thread_enter()
	defer diagnostics_thread_leave()
	runtime_tuning_enter(.Bio)
	for {
		sync.sema_wait(&lazy_sema)
		sync.mutex_lock(&lazy_mutex)
		job := lazy_queue[lazy_head]
		lazy_head += 1
		if lazy_head == len(lazy_queue) {
			clear(&lazy_queue)
			lazy_head = 0
		}
		sync.mutex_unlock(&lazy_mutex)
		lazyfree_run(&job)
		intrinsics.atomic_sub_explicit(&lazy_pending_mem, job.bytes, .Relaxed)
		intrinsics.atomic_sub_explicit(&lazy_pending_slab, job.slab_live, .Relaxed)
		intrinsics.atomic_sub_explicit(&lazy_pending_objs, job.count, .Relaxed)
		intrinsics.atomic_add_explicit(&lazy_freed, job.count, .Relaxed)
		if job.waiter_id != 0 {
			sync.mutex_lock(&lazy_mutex)
			append(&lazy_done, [2]i64{i64(job.waiter_fd), job.waiter_id})
			sync.mutex_unlock(&lazy_mutex)
			one := u64(1)
			linux.write(lazy_efd, ([^]u8)(&one)[:8])
		}
		intrinsics.atomic_sub_explicit(&lazy_jobs, 1, .Release)
	}
}

lazyfree_before_fork :: proc() {
	for intrinsics.atomic_load_explicit(&lazy_jobs, .Acquire) != 0 {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
}

lazyfree_after_fork :: proc() {
	if lazy_efd >= 0 { linux.close(lazy_efd) }
	lazy_efd = -1
	lazy_thread = nil
	clear(&lazy_queue)
	clear(&lazy_done)
	lazy_head = 0
	lazy_mutex = {}
	lazy_sema = {}
	lazy_pending_objs = 0
	lazy_pending_mem = 0
	lazy_pending_slab = 0
	lazy_jobs = 0
	lazy_blocked = 0
}

@(private = "file")
lazyfree_start :: proc() {
	efd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {
		store_fatal("cannot create the lazyfree event descriptor")
	}
	lazy_efd = efd
	epoll_set(efd, .ADD, false, 0)
	lazy_thread = thread.create_and_start(lazyfree_main)
}

lazyfree_submit :: proc(job: Lazy_Job) {
	if pst.in_child {
		local := job
		lazyfree_run(&local)
		intrinsics.atomic_add_explicit(&lazy_freed, job.count, .Relaxed)
		return
	}
	if lazy_thread == nil {
		lazyfree_start()
	}
	intrinsics.atomic_add_explicit(&lazy_pending_mem, job.bytes, .Relaxed)
	intrinsics.atomic_add_explicit(&lazy_pending_slab, job.slab_live, .Relaxed)
	intrinsics.atomic_add_explicit(&lazy_pending_objs, job.count, .Relaxed)
	intrinsics.atomic_add_explicit(&lazy_jobs, 1, .Relaxed)
	sync.mutex_lock(&lazy_mutex)
	append(&lazy_queue, job)
	sync.mutex_unlock(&lazy_mutex)
	sync.sema_post(&lazy_sema)
}

@(cold)
lazyfree_object :: #force_no_inline proc "contextless" (type: Obj_Type, obj: rawptr) -> (n: int, queued: bool) {
	context = runtime.default_context()
	if lazyfree_effort(type, obj) <= LAZYFREE_THRESHOLD {
		return 0, false
	}
	n = object_acct_of(type, obj)
	if type == .Hash {
		ht.registry_remove(ht.Hash(obj))
		ht.maintenance_cancel(ht.Hash(obj))
	} else if type == .Set {
		st.maintenance_cancel(st.Set(obj))
	} else if type == .Zset {
		zt.maintenance_cancel(zt.Zset(obj))
	}
	lazyfree_submit(Lazy_Job{type = type, obj = obj, bytes = n, count = 1})
	return n, true
}

lazyfree_block :: proc(c: ^Conn) {
	if pst.in_child { reply_ok(c); return }
	lazyfree_submit(Lazy_Job{waiter_fd = c.fd, waiter_id = c.id})
	c.blocked = .Lazyfree
	lazy_blocked += 1
	block_work += 1
}

lazyfree_unblock :: proc(c: ^Conn) {
	c.blocked = .None
	lazy_blocked -= 1
	block_work -= 1
}

lazyfree_drain :: proc() {
	buf: [8]u8
	linux.read(lazy_efd, buf[:])
	sync.mutex_lock(&lazy_mutex)
	done := lazy_done
	lazy_done = nil
	sync.mutex_unlock(&lazy_mutex)
	defer delete(done)
	for d in done {
		fd := int(d[0])
		if fd < 0 || fd >= len(srv.conns) {
			continue
		}
		c := srv.conns[fd]
		if c == nil || c.id != d[1] || c.blocked != .Lazyfree {
			continue
		}
		lazyfree_unblock(c)
		reply_ok(c)
		srv.stat_commands += 1
		stats_unblocked(c, nil, false)
		block_wake(c)
	}
}

lazyfree_wait :: proc(limit_us: i64, ok: proc() -> bool) -> bool {
	keyspace_signal_owed()
	start := now_ns()
	for lazyfree_jobs_pending() && (now_ns() - start) / 1000 < limit_us {
		if ok() {
			return true
		}
		ts := linux.Time_Spec {
			time_nsec = uint(min(limit_us, 1000) * 1000),
		}
		linux.nanosleep(&ts, nil)
	}
	return false
}

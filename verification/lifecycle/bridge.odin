package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:sys/linux"
import "core:thread"
import cp "compute"
import ks "keyspace"

VERSION :: "0.1.0"
REDIS_COMPAT_VERSION :: "7.4.11"
PROJECT_LICENSE :: "Apache-2.0"

foreign import lifecycle_libc "system:c"

foreign lifecycle_libc {
	pthread_atfork :: proc "c" (prepare, parent, child: proc "c" ()) -> i32 ---
}

lifecycle_enters: i32
lifecycle_leaves: i32
lifecycle_alive: i32 = 1
lifecycle_computed: i32
lifecycle_hooks: [3]i32
lifecycle_alarm_blocked: bool
lifecycle_callback_entered: i32
lifecycle_callback_gate: i32
lifecycle_shutdown_started: i32
lifecycle_shutdown_done: i32

lifecycle_enter :: proc() {
	assert(intrinsics.atomic_load(&lifecycle_alive) == 1)
	intrinsics.atomic_add(&lifecycle_enters, 1)
}

lifecycle_leave :: proc() {
	assert(intrinsics.atomic_load(&lifecycle_alive) == 1)
	intrinsics.atomic_add(&lifecycle_leaves, 1)
}

lifecycle_compute :: proc "contextless" (job: ^cp.Job) {
	intrinsics.atomic_add(&lifecycle_computed, 1)
}

lifecycle_prepare :: proc "c" () {
	lifecycle_hooks[0] += 1
	mask: linux.Sig_Set
	problem := linux.rt_sigprocmask(.SIG_SETMASK, nil, &mask)
	lifecycle_alarm_blocked = problem == .NONE && mask[0] & (uint(1) << uint(i32(linux.Signal.SIGALRM) - 1)) != 0
}
lifecycle_parent :: proc "c" () { lifecycle_hooks[1] += 1 }
lifecycle_child :: proc "c" () { lifecycle_hooks[2] += 1 }

lifecycle_wait :: proc(value: ^i32) {
	for intrinsics.atomic_load_explicit(value, .Acquire) == 0 {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
}

lifecycle_release :: proc "contextless" (payload: rawptr) {
	context = runtime.default_context()
	intrinsics.atomic_store_explicit(&lifecycle_callback_entered, 1, .Release)
	for intrinsics.atomic_load_explicit(&lifecycle_callback_gate, .Acquire) == 0 {
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	assert(runtime_syslog_open && runtime_syslog_ident != nil)
	runtime_log_syslog(LOG_WARNING, transmute([]u8)string("lifecycle-active-callback"))
}

lifecycle_shutdown :: proc() {
	intrinsics.atomic_store_explicit(&lifecycle_shutdown_started, 1, .Release)
	runtime_operations_shutdown()
	intrinsics.atomic_store_explicit(&lifecycle_shutdown_done, 1, .Release)
}

lifecycle_pool_check :: proc() {
	p: ks.Pool
	assert(ks.init(&p, 2, 1 << 20, lifecycle_enter, lifecycle_leave))
	r := ks.record_new(&p, 0, transmute([]u8)string("key"), 0, false, nil, 0)
	v := ks.value_new(&p, transmute([]u8)string("accepted"))
	assert(r != nil && v != nil)
	j := ks.Job{record = r, op = .Set, value = v}
	assert(ks.submit(&p, &j))
	ks.pause(&p)
	assert(intrinsics.atomic_load(&lifecycle_enters) == 2)
	assert(intrinsics.atomic_load(&lifecycle_leaves) == 0)
	assert(ks.active_workers(&p) == 2 && p.parked == 2 && ks.pending(&p) == 1)
	assert(r.exists && string(ks.value_data(r.value)) == "accepted")
	fd := ks.completion_fd(&p)
	assert(ks.resume(&p))
	ks.pause(&p)
	assert(intrinsics.atomic_load(&lifecycle_enters) == 2)
	ks.stop(&p)
	assert(ks.active_workers(&p) == 0 && intrinsics.atomic_load(&lifecycle_leaves) == 2)
	assert(ks.poll(&p) == &j && ks.poll(&p) == nil)
	ks.value_release(j.value)
	ks.value_release(j.result)
	assert(ks.record_free(&p, r))
	assert(ks.resume(&p) && ks.completion_fd(&p) == fd)
	ks.pause(&p)
	assert(intrinsics.atomic_load(&lifecycle_enters) == 4)
	ks.stop(&p)
	assert(intrinsics.atomic_load(&lifecycle_leaves) == 4 && ks.destroy(&p))
	c: cp.Pool
	assert(cp.init(&c, 2, lifecycle_enter, lifecycle_leave))
	jobs := [2]cp.Job{{procedure = lifecycle_compute}, {procedure = lifecycle_compute}}
	for &job in jobs { assert(cp.submit(&c, &job)) }
	cp.stop(&c)
	assert(cp.active_workers(&c) == 0 && intrinsics.atomic_load(&lifecycle_computed) == 2)
	assert(cp.poll(&c) != nil && cp.poll(&c) != nil && cp.poll(&c) == nil)
	assert(intrinsics.atomic_load(&lifecycle_enters) == 6 && intrinsics.atomic_load(&lifecycle_leaves) == 6)
	assert(cp.destroy(&c))
	intrinsics.atomic_store(&lifecycle_alive, 0)
	fmt.println("POOL|parked_callbacks_alive|joined_before_free|resume_hooks|accepted_completed")
}

lifecycle_fork_check :: proc() {
	assert(pthread_atfork(lifecycle_prepare, lifecycle_parent, lifecycle_child) == 0)
	parent_tid := i32(linux.gettid())
	assert(linux.rt_sigprocmask(.SIG_SETMASK, nil, &lifecycle_original_mask) == .NONE)
	for mask_class in 0 ..< 4 {
		mask: linux.Sig_Set
		if mask_class & 1 != 0 { mask[0] |= uint(1) << uint(i32(linux.Signal.SIGALRM) - 1) }
		if mask_class & 2 != 0 { mask[0] |= uint(1) << uint(i32(linux.Signal.SIGUSR1) - 1) }
		assert(linux.rt_sigprocmask(.SIG_SETMASK, &mask, nil) == .NONE)
		lifecycle_hooks = {}
		lifecycle_alarm_blocked = false
		diagnostic_main_tid = parent_tid
		diagnostic_timer = 123
		diagnostic_report_guard = 1
		diagnostic_assert_tid = 12
		diagnostic_working = 1
		diagnostic_deadline = 42
		parent_lazy_fd := lazy_efd
		assert(parent_lazy_fd >= 0 && aof_bio_thread != nil)
		pid, problem := runtime_fork()
		assert(problem == .NONE && pid >= 0)
		actual: linux.Sig_Set
		assert(linux.rt_sigprocmask(.SIG_SETMASK, nil, &actual) == .NONE && actual == mask)
		if pid == 0 {
			assert(lifecycle_alarm_blocked)
			assert(lifecycle_hooks == [3]i32{1, 0, 1})
			assert(diagnostic_main_tid == i32(linux.gettid()) && diagnostic_main_tid != parent_tid)
			assert(diagnostic_timer == -1 && diagnostic_report_guard == 0 && diagnostic_assert_tid == 0)
			assert(diagnostic_working == 0 && diagnostic_deadline == 0)
			assert(lifecycle_lazy_reset() && lifecycle_bio_reset())
			linux.exit_group(0)
		}
		assert(lifecycle_hooks == [3]i32{1, 1, 0})
		assert(lifecycle_alarm_blocked)
		assert(diagnostic_main_tid == parent_tid && diagnostic_timer == 123)
		assert(lazy_efd == parent_lazy_fd)
		status: u32
		waited, wait_problem := linux.wait4(pid, &status, {}, nil)
		assert(wait_problem == .NONE && waited == pid && status == 0)
	}
	assert(linux.rt_sigprocmask(.SIG_SETMASK, &lifecycle_original_mask, nil) == .NONE)
	diagnostic_timer = -1
	fmt.println("FORK|libc_atfork|four_exact_masks|child_tid_and_state_reset|parent_state_retained")
}

lifecycle_original_mask: linux.Sig_Set

main :: proc() {
	config_init()
	lifecycle_pool_check()
	cfg.syslog_enabled = true
	cfg.syslog_ident = "eski-lifecycle-owned-probe"
	runtime_operations_init()
	lazyfree_submit(Lazy_Job{release = lifecycle_release})
	lifecycle_wait(&lifecycle_callback_entered)
	queued, pending := lifecycle_lazy_counts()
	assert(queued == 0 && pending == 1)
	shutdown := thread.create_and_start(lifecycle_shutdown)
	assert(shutdown != nil)
	lifecycle_wait(&lifecycle_shutdown_started)
	ts := linux.Time_Spec{time_nsec = 20_000_000}
	linux.nanosleep(&ts, nil)
	assert(intrinsics.atomic_load_explicit(&lifecycle_shutdown_done, .Acquire) == 0)
	intrinsics.atomic_store_explicit(&lifecycle_callback_gate, 1, .Release)
	thread.join(shutdown)
	thread.destroy(shutdown)
	assert(!runtime_syslog_open && runtime_syslog_ident == nil)
	assert(!lazyfree_jobs_pending())
	fmt.println("SHUTDOWN|queued_zero_active_one|blocked_until_release|logger_after_callback")
	fds: [2]linux.Fd
	assert(linux.pipe2(&fds, {.CLOEXEC}) == .NONE)
	aof_bio_close(fds[1])
	aof_bio_before_fork()
	assert(lifecycle_bio_pending() == 0 && aof_bio_head == aof_bio_tail)
	linux.close(fds[0])
	lifecycle_fork_check()
	fmt.println("LIFECYCLE|PASS")
	linux.exit_group(0)
}

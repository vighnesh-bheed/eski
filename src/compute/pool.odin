package compute

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:sys/linux"
import "core:thread"

CAPACITY :: 64
MAX_WORKERS :: 64

Job_Proc :: #type proc "contextless" (job: ^Job)

Job_State :: enum u32 {
	Idle,
	Admitted,
	Queued,
	Running,
	Completed,
}

Job :: struct {
	procedure:  Job_Proc,
	data:       rawptr,
	elapsed_ns: i64,
	state:      Job_State,
	cancel_flag: u32,
}

Pool :: struct {
	mutex:       sync.Mutex,
	ready:       sync.Cond,
	threads:     [MAX_WORKERS]^thread.Thread,
	worker_enter: proc(),
	worker_leave: proc(),
	assertion_failure: runtime.Assertion_Failure_Proc,
	nthreads:    int,
	initialized: bool,
	accepting:   bool,
	stopping:    bool,
	fd:          linux.Fd,
	queued:      [CAPACITY]^Job,
	queue_head:  int,
	queue_len:   int,
	completed:   [CAPACITY]^Job,
	done_head:   int,
	done_len:    int,
	outstanding: int,
}

@(private = "file")
clock_ns :: proc "contextless" () -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

@(private = "file")
notify_completion :: proc "contextless" (fd: linux.Fd) {
	one := u64(1)
	for {
		_, err := linux.write(fd, ([^]u8)(&one)[:size_of(one)])
		if err != .EINTR {
			return
		}
	}
}

@(private = "file")
worker_main :: proc(t: ^thread.Thread) {
	p := (^Pool)(t.data)
	context.assertion_failure_proc = p.assertion_failure if p.assertion_failure != nil else context.assertion_failure_proc
	if p.worker_enter != nil { p.worker_enter() }
	defer { if p.worker_leave != nil { p.worker_leave() } }
	for {
		sync.mutex_lock(&p.mutex)
		for p.queue_len == 0 && !p.stopping {
			sync.cond_wait(&p.ready, &p.mutex)
		}
		if p.queue_len == 0 {
			sync.mutex_unlock(&p.mutex)
			return
		}
		job := p.queued[p.queue_head]
		p.queued[p.queue_head] = nil
		p.queue_head = (p.queue_head + 1) % CAPACITY
		p.queue_len -= 1
		intrinsics.atomic_store_explicit(&job.state, .Running, .Release)
		sync.mutex_unlock(&p.mutex)
		start := clock_ns()
		if !cancelled(job) {
			job.procedure(job)
		}
		job.elapsed_ns = max(clock_ns() - start, 0)
		sync.mutex_lock(&p.mutex)
		p.completed[(p.done_head + p.done_len) % CAPACITY] = job
		p.done_len += 1
		intrinsics.atomic_store_explicit(&job.state, .Completed, .Release)
		sync.mutex_unlock(&p.mutex)
		notify_completion(p.fd)
	}
}

init :: proc(p: ^Pool, workers: int, worker_enter: proc() = nil, worker_leave: proc() = nil, assertion_failure: runtime.Assertion_Failure_Proc = nil) -> bool {
	if p == nil || workers < 1 || workers > MAX_WORKERS {
		return false
	}
	sync.mutex_lock(&p.mutex)
	if p.nthreads != 0 || p.accepting {
		sync.mutex_unlock(&p.mutex)
		return false
	}
	was_initialized := p.initialized
	if !p.initialized {
		fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
		if err != .NONE {
			sync.mutex_unlock(&p.mutex)
			return false
		}
		p.fd = fd
		p.initialized = true
	}
	p.stopping = false
	p.worker_enter = worker_enter
	p.worker_leave = worker_leave
	p.assertion_failure = assertion_failure
	sync.mutex_unlock(&p.mutex)
	for i in 0 ..< workers {
		t := thread.create(worker_main, name = "eski-compute")
		if t == nil {
			stop(p)
			if !was_initialized {
				destroy(p)
			}
			return false
		}
		t.data = p
		sync.mutex_lock(&p.mutex)
		p.threads[i] = t
		p.nthreads = i + 1
		sync.mutex_unlock(&p.mutex)
		thread.start(t)
	}
	sync.mutex_lock(&p.mutex)
	p.accepting = true
	sync.mutex_unlock(&p.mutex)
	return true
}

submit :: proc "contextless" (p: ^Pool, job: ^Job) -> bool {
	if p == nil || job == nil || job.procedure == nil {
		return false
	}
	_, owned := intrinsics.atomic_compare_exchange_strong_explicit(&job.state, .Idle, .Admitted, .Acquire, .Relaxed)
	if !owned {
		return false
	}
	sync.mutex_lock(&p.mutex)
	if !p.accepting || p.outstanding == CAPACITY {
		sync.mutex_unlock(&p.mutex)
		intrinsics.atomic_store_explicit(&job.state, .Idle, .Release)
		return false
	}
	intrinsics.atomic_store_explicit(&job.cancel_flag, 0, .Relaxed)
	job.elapsed_ns = 0
	p.queued[(p.queue_head + p.queue_len) % CAPACITY] = job
	p.queue_len += 1
	p.outstanding += 1
	intrinsics.atomic_store_explicit(&job.state, .Queued, .Release)
	sync.cond_signal(&p.ready)
	sync.mutex_unlock(&p.mutex)
	return true
}

cancel :: proc "contextless" (job: ^Job) {
	if job != nil {
		intrinsics.atomic_store_explicit(&job.cancel_flag, 1, .Release)
	}
}

cancelled :: proc "contextless" (job: ^Job) -> bool {
	return job != nil && intrinsics.atomic_load_explicit(&job.cancel_flag, .Acquire) != 0
}

poll :: proc "contextless" (p: ^Pool) -> ^Job {
	if p == nil {
		return nil
	}
	sync.mutex_lock(&p.mutex)
	if p.done_len == 0 {
		sync.mutex_unlock(&p.mutex)
		return nil
	}
	job := p.completed[p.done_head]
	p.completed[p.done_head] = nil
	p.done_head = (p.done_head + 1) % CAPACITY
	p.done_len -= 1
	p.outstanding -= 1
	intrinsics.atomic_store_explicit(&job.state, .Idle, .Release)
	sync.mutex_unlock(&p.mutex)
	return job
}

drain_notifications :: proc "contextless" (p: ^Pool) {
	fd := completion_fd(p)
	if fd < 0 {
		return
	}
	buf: [8]u8
	for {
		_, err := linux.read(fd, buf[:])
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return
		}
	}
}

completion_fd :: proc "contextless" (p: ^Pool) -> linux.Fd {
	if p == nil {
		return -1
	}
	sync.mutex_lock(&p.mutex)
	fd := p.fd if p.initialized else linux.Fd(-1)
	sync.mutex_unlock(&p.mutex)
	return fd
}

active_workers :: proc "contextless" (p: ^Pool) -> int {
	if p == nil {
		return 0
	}
	sync.mutex_lock(&p.mutex)
	n := p.nthreads
	sync.mutex_unlock(&p.mutex)
	return n
}

pending :: proc "contextless" (p: ^Pool) -> int {
	if p == nil {
		return 0
	}
	sync.mutex_lock(&p.mutex)
	n := p.outstanding
	sync.mutex_unlock(&p.mutex)
	return n
}

stop :: proc(p: ^Pool) {
	if p == nil {
		return
	}
	sync.mutex_lock(&p.mutex)
	p.accepting = false
	p.stopping = true
	n := p.nthreads
	sync.cond_broadcast(&p.ready)
	sync.mutex_unlock(&p.mutex)
	for i in 0 ..< n {
		t := p.threads[i]
		thread.join(t)
		thread.destroy(t)
		p.threads[i] = nil
	}
	sync.mutex_lock(&p.mutex)
	p.nthreads = 0
	sync.mutex_unlock(&p.mutex)
}

destroy :: proc(p: ^Pool) -> bool {
	if p == nil {
		return true
	}
	stop(p)
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	if p.outstanding != 0 {
		return false
	}
	if p.initialized {
		linux.close(p.fd)
		p.fd = -1
		p.initialized = false
	}
	return true
}

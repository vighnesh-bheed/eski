package compute

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "core:testing"
import "core:thread"

Test_Data :: struct {
	calls:   u32,
	entered: ^u32,
	release: ^u32,
	value:   int,
	tid:     i64,
}

test_work :: proc "contextless" (job: ^Job) {
	d := (^Test_Data)(job.data)
	intrinsics.atomic_add_explicit(&d.calls, 1, .Relaxed)
	d.tid = i64(linux.gettid())
	if d.entered != nil {
		intrinsics.atomic_add_explicit(d.entered, 1, .Release)
	}
	if d.release != nil {
		for intrinsics.atomic_load_explicit(d.release, .Acquire) == 0 && !cancelled(job) {
			linux.sched_yield()
		}
	}
	d.value = 42
}

test_clock_ns :: proc "contextless" () -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

wait_for :: proc(value: ^u32, expected: u32) -> bool {
	deadline := test_clock_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(value, .Acquire) < expected {
		if test_clock_ns() >= deadline {
			return false
		}
		ts := linux.Time_Spec{time_nsec = 100_000}
		linux.nanosleep(&ts, nil)
	}
	return true
}

@(test)
pool_zero_and_invalid_lifecycle :: proc(t: ^testing.T) {
	p: Pool
	job := Job{procedure = test_work}
	testing.expect(t, completion_fd(&p) == -1)
	testing.expect(t, active_workers(&p) == 0 && pending(&p) == 0)
	testing.expect(t, poll(&p) == nil)
	testing.expect(t, !submit(&p, &job))
	testing.expect(t, !init(&p, 0) && !init(&p, MAX_WORKERS + 1))
	testing.expect(t, !init(nil, 1) && !submit(nil, &job) && !submit(&p, nil))
	testing.expect(t, completion_fd(nil) == -1 && active_workers(nil) == 0 && pending(nil) == 0)
	drain_notifications(&p)
	drain_notifications(nil)
	cancel(nil)
	testing.expect(t, !cancelled(nil))
	testing.expect(t, destroy(&p) && destroy(nil))
	testing.expect(t, init(&p, 1))
	testing.expect(t, !init(&p, 1))
	testing.expect(t, destroy(&p))
	testing.expect(t, completion_fd(&p) == -1)
	testing.expect(t, init(&p, 1) && destroy(&p))
}

@(test)
pool_capacity_includes_unpolled_completions :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 2))
	defer destroy(&p)
	data: [CAPACITY + 1]Test_Data
	jobs: [CAPACITY + 1]Job
	for &job, i in jobs {
		job.procedure = test_work
		job.data = &data[i]
	}
	for &job in jobs[:CAPACITY] {
		testing.expect(t, submit(&p, &job))
	}
	stop(&p)
	fd := completion_fd(&p)
	testing.expect(t, fd >= 0 && active_workers(&p) == 0 && pending(&p) == CAPACITY)
	testing.expect(t, !destroy(&p) && completion_fd(&p) == fd)
	testing.expect(t, init(&p, 1) && completion_fd(&p) == fd)
	jobs[CAPACITY].elapsed_ns = 17
	cancel(&jobs[CAPACITY])
	testing.expect(t, !submit(&p, &jobs[CAPACITY]))
	testing.expect(t, cancelled(&jobs[CAPACITY]) && jobs[CAPACITY].elapsed_ns == 17)
	first := poll(&p)
	testing.expect(t, first != nil && pending(&p) == CAPACITY - 1)
	testing.expect(t, submit(&p, &jobs[CAPACITY]) && !cancelled(&jobs[CAPACITY]))
	stop(&p)
	seen: [CAPACITY + 1]bool
	seen[(uintptr(first) - uintptr(&jobs[0])) / size_of(Job)] = true
	count := 1
	for job := poll(&p); job != nil; job = poll(&p) {
		i := (uintptr(job) - uintptr(&jobs[0])) / size_of(Job)
		testing.expect(t, i < len(jobs) && !seen[i])
		seen[i] = true
		count += 1
	}
	testing.expect(t, count == len(jobs) && pending(&p) == 0)
	for d in data {
		testing.expect(t, d.calls == 1 && d.value == 42)
	}
	notifications: u64
	nread, nerr := linux.read(fd, ([^]u8)(&notifications)[:size_of(notifications)])
	testing.expect(t, nread == 8 && nerr == .NONE && notifications == CAPACITY + 1)
	drain_notifications(&p)
	buf: [8]u8
	_, err := linux.read(fd, buf[:])
	testing.expect(t, err == .EAGAIN)
}

@(test)
pool_workers_overlap_without_coordinator_callbacks :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 2))
	defer destroy(&p)
	entered, release: u32
	data := [2]Test_Data{{entered = &entered, release = &release}, {entered = &entered, release = &release}}
	jobs := [2]Job{{procedure = test_work, data = &data[0]}, {procedure = test_work, data = &data[1]}}
	for &job in jobs {
		testing.expect(t, submit(&p, &job))
	}
	overlapped := wait_for(&entered, 2)
	intrinsics.atomic_store_explicit(&release, 1, .Release)
	stop(&p)
	testing.expect(t, overlapped)
	testing.expect(t, data[0].tid != data[1].tid && data[0].tid != i64(linux.gettid()) && data[1].tid != i64(linux.gettid()))
	for _ in jobs {
		job := poll(&p)
		testing.expect(t, job != nil && job.elapsed_ns >= 0)
	}
	testing.expect(t, poll(&p) == nil)
}

@(test)
pool_cancel_running_and_queued_jobs_acknowledges_ownership :: proc(t: ^testing.T) {
	p, other: Pool
	testing.expect(t, init(&p, 1) && init(&other, 1))
	defer destroy(&p)
	defer destroy(&other)
	entered, release: u32
	data := [2]Test_Data{{entered = &entered, release = &release}, {}}
	jobs := [2]Job{{procedure = test_work, data = &data[0]}, {procedure = test_work, data = &data[1]}}
	testing.expect(t, submit(&p, &jobs[0]))
	started := wait_for(&entered, 1)
	testing.expect(t, !submit(&p, &jobs[0]) && !submit(&other, &jobs[0]))
	testing.expect(t, submit(&p, &jobs[1]))
	cancel(&jobs[1])
	cancel(&jobs[0])
	stop(&p)
	testing.expect(t, started && data[0].calls == 1 && data[0].value == 42 && data[1].calls == 0)
	testing.expect(t, pending(&p) == 2 && cancelled(&jobs[0]) && cancelled(&jobs[1]))
	seen: [2]bool
	for _ in jobs {
		job := poll(&p)
		i := 0 if job == &jobs[0] else 1
		testing.expect(t, job != nil && (job == &jobs[0] || job == &jobs[1]) && !seen[i])
		seen[i] = true
	}
	testing.expect(t, poll(&p) == nil && pending(&p) == 0)
	data[1] = {}
	testing.expect(t, init(&p, 1) && submit(&p, &jobs[1]))
	stop(&p)
	testing.expect(t, poll(&p) == &jobs[1] && !cancelled(&jobs[1]) && data[1].calls == 1)
}

Fail_Allocator :: struct {
	remaining: int,
}

fail_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	state := (^Fail_Allocator)(allocator_data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		if state.remaining == 0 {
			return nil, .Out_Of_Memory
		}
		state.remaining -= 1
	}
	allocator := runtime.default_allocator()
	return allocator.procedure(allocator.data, mode, size, alignment, old_memory, old_size, loc)
}

init_with_allocation_failure :: proc(p: ^Pool, workers, allowed: int) -> bool {
	state := Fail_Allocator{remaining = allowed}
	saved := context.allocator
	context.allocator = runtime.Allocator{procedure = fail_allocator_proc, data = &state}
	result := init(p, workers)
	context.allocator = saved
	return result
}

@(test)
pool_partial_start_failure_cleans_up_and_preserves_completions :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, !init_with_allocation_failure(&p, 2, 1))
	testing.expect(t, active_workers(&p) == 0 && completion_fd(&p) == -1 && pending(&p) == 0)
	testing.expect(t, init(&p, 1))
	defer destroy(&p)
	data: Test_Data
	job := Job{procedure = test_work, data = &data}
	testing.expect(t, submit(&p, &job))
	stop(&p)
	fd := completion_fd(&p)
	testing.expect(t, !init_with_allocation_failure(&p, 2, 1))
	testing.expect(t, active_workers(&p) == 0 && completion_fd(&p) == fd && pending(&p) == 1)
	testing.expect(t, poll(&p) == &job && data.calls == 1)
	testing.expect(t, init(&p, 2))
	stop(&p)
	testing.expect(t, destroy(&p))
}

Producer :: struct {
	pool:     ^Pool,
	jobs:     []Job,
	accepted: []u32,
	finished: ^u32,
}

producer_main :: proc(data: rawptr) {
	p := (^Producer)(data)
	for &job, i in p.jobs {
		if submit(p.pool, &job) {
			intrinsics.atomic_store_explicit(&p.accepted[i], 1, .Release)
			if i % 3 == 0 {
				cancel(&job)
			}
		}
		linux.sched_yield()
	}
	intrinsics.atomic_add_explicit(p.finished, 1, .Release)
}

@(test)
pool_concurrent_submit_poll_cancel_and_stop_are_exactly_once :: proc(t: ^testing.T) {
	for _ in 0 ..< 16 {
		p: Pool
		testing.expect(t, init(&p, 4))
		data: [257]Test_Data
		jobs: [257]Job
		accepted: [257]u32
		for &job, i in jobs {
			job.procedure = test_work
			job.data = &data[i]
		}
		testing.expect(t, submit(&p, &jobs[256]))
		accepted[256] = 1
		finished: u32
		producers: [4]Producer
		threads: [4]^thread.Thread
		for &producer, i in producers {
			producer = Producer{pool = &p, jobs = jobs[i * 64:][:64], accepted = accepted[i * 64:][:64], finished = &finished}
			threads[i] = thread.create_and_start_with_data(&producer, producer_main)
		}
		seen: [257]bool
		completed := 0
		for _ in 0 ..< 32 {
			if job := poll(&p); job != nil {
				i := (uintptr(job) - uintptr(&jobs[0])) / size_of(Job)
				testing.expect(t, i < len(jobs) && !seen[i])
				seen[i] = true
				completed += 1
			}
			linux.sched_yield()
		}
		stop(&p)
		for worker in threads {
			thread.join(worker)
			thread.destroy(worker)
		}
		testing.expect(t, finished == 4)
		for job := poll(&p); job != nil; job = poll(&p) {
			i := (uintptr(job) - uintptr(&jobs[0])) / size_of(Job)
			testing.expect(t, i < len(jobs) && !seen[i])
			seen[i] = true
			completed += 1
		}
		admitted := 0
		for flag, i in accepted {
			admitted += int(flag)
			testing.expect(t, seen[i] == (flag == 1) && data[i].calls <= flag)
		}
		testing.expect(t, completed == admitted && pending(&p) == 0 && active_workers(&p) == 0)
		testing.expect(t, destroy(&p))
	}
}

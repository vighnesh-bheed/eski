package keyspace

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"

test_bytes :: proc "contextless" (text: string) -> []u8 {
	return transmute([]u8)text
}

expect_bytes :: proc(t: ^testing.T, actual, expected: []u8) {
	equal := len(actual) == len(expected)
	if equal && len(actual) > 0 {
		equal = runtime.memory_equal(raw_data(actual), raw_data(expected), len(actual))
	}
	testing.expect(t, equal)
}

test_now_ns :: proc "contextless" () -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}

release_job_refs :: proc(job: ^Job) {
	value_release(job.result)
	job.result = nil
	value_release(job.value)
	job.value = nil
}

@(test)
pool_rejects_invalid_lifecycle_and_zero_budget :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, completion_fd(&p) == -1 && active_workers(&p) == 0 && pending(&p) == 0 && memory_used(&p) == 0)
	testing.expect(t, poll(&p) == nil && !resume(&p))
	testing.expect(t, len(allocate(&p, 16)) == 0 && value_new(&p, nil) == nil)
	testing.expect(t, record_new(&p, 0, nil, 0, false, nil, 0) == nil)
	testing.expect(t, !init(&p, 0, 1024) && !init(&p, MAX_WORKERS + 1, 1024) && !init(&p, 1, -1))
	testing.expect(t, !init(nil, 1, 1024) && !submit(nil, nil) && !submit(&p, nil))
	testing.expect(t, completion_fd(nil) == -1 && pending(nil) == 0 && memory_used(nil) == 0)
	drain_notifications(&p)
	drain_notifications(nil)
	pause(nil)
	stop(nil)
	value_release(nil)
	testing.expect(t, value_retain(nil) == nil && len(value_data(nil)) == 0)
	testing.expect(t, free(nil, nil) && record_free(nil, nil) && destroy(nil) && destroy(&p))
	testing.expect(t, init(&p, 1, 0))
	testing.expect(t, !init(&p, 1, 0) && len(allocate(&p, 1)) == 0 && value_new(&p, test_bytes("x")) == nil)
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
	testing.expect(t, init(&p, 1, 1024) && destroy(&p))
}

@(test)
requested_budget_and_references_return_to_zero :: proc(t: ^testing.T) {
	p, other: Pool
	testing.expect(t, init(&p, 1, 4096) && init(&other, 1, 4096))
	defer destroy(&p)
	defer destroy(&other)
	regions: [64][]u8
	count := 0
	for count < len(regions) {
		region := allocate(&p, 64)
		if len(region) == 0 {
			break
		}
		regions[count] = region
		count += 1
		testing.expect(t, uintptr(raw_data(region)) % uintptr(align_of(Record)) == 0 && memory_used(&p) <= 4096)
	}
	testing.expect(t, count > 0 && count < len(regions))
	used := memory_used(&p)
	testing.expect(t, used >= count * 64 && len(allocate(&p, 64)) == 0)
	testing.expect(t, len(allocate(&p, -1)) == 0 && len(allocate(&p, max(int))) == 0 && memory_used(&p) == used)
	testing.expect(t, !free(&other, regions[0]) && !free(&p, regions[0][:63]) && memory_used(&p) == used)
	testing.expect(t, !destroy(&p))
	for region in regions[:count] {
		testing.expect(t, free(&p, region))
	}
	testing.expect(t, memory_used(&p) == 0 && resume(&p))
	input := [4]u8{'a', 0, 'b', 255}
	v := value_new(&p, input[:])
	empty := value_new(&p, nil)
	testing.expect(t, v != nil && empty != nil && len(value_data(empty)) == 0)
	charge := memory_used(&p)
	retained := value_retain(v)
	input[0] = 'z'
	value_release(v)
	expect_bytes(t, value_data(retained), []u8{'a', 0, 'b', 255})
	testing.expect(t, memory_used(&p) == charge && !destroy(&p))
	value_release(empty)
	value_release(retained)
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
}

@(test)
record_copies_seed_and_rolls_back_a_failed_seed_allocation :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 1, 4096))
	key := [3]u8{'k', 0, 'y'}
	seed := [3]u8{'v', 0, 'l'}
	r := record_new(&p, 3, key[:], 0, true, seed[:], 91)
	testing.expect(t, r != nil && !record_free(&p, r))
	key[0], seed[0] = 'x', 'x'
	pause(&p)
	testing.expect(t, r.db == 3 && r.owner == 0 && r.exists && r.clock == 91 && !r.changed && !r.touched)
	expect_bytes(t, test_bytes(r.key), []u8{'k', 0, 'y'})
	expect_bytes(t, value_data(r.value), []u8{'v', 0, 'l'})
	testing.expect(t, record_free(&p, r) && memory_used(&p) == 0)
	absent := record_new(&p, 0, nil, 0, false, nil, 0)
	testing.expect(t, absent != nil)
	charge := memory_used(&p)
	testing.expect(t, record_free(&p, absent) && destroy(&p))
	testing.expect(t, init(&p, 1, charge))
	testing.expect(t, record_new(&p, 0, nil, 0, true, test_bytes("seed"), 0) == nil && memory_used(&p) == 0)
	testing.expect(t, record_new(&p, -1, nil, 0, false, nil, 0) == nil && record_new(&p, 0, nil, 1, false, nil, 0) == nil)
	testing.expect(t, destroy(&p))
}

@(test)
same_shard_fifo_keeps_old_get_values_after_later_sets :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 2, 1 << 20))
	defer destroy(&p)
	records := [2]^Record{
		record_new(&p, 0, test_bytes("left\x00key"), 0, true, test_bytes("seed"), 1),
		record_new(&p, 1, nil, 1, true, test_bytes("seed"), 1),
	}
	testing.expect(t, records[0] != nil && records[1] != nil)
	jobs: [16]Job
	for round in 0 ..< 4 {
		for owner in 0 ..< 2 {
			index := round * 4 + owner * 2
			bytes := [3]u8{u8('A' + owner), u8('0' + round), 0}
			jobs[index] = Job{record = records[owner], op = .Set, value = value_new(&p, bytes[:]), clock = u32(index + 10), touch = true}
			jobs[index + 1] = Job{record = records[owner], op = .Get, clock = u32(index + 11), touch = true}
			testing.expect(t, jobs[index].value != nil && submit(&p, &jobs[index]) && submit(&p, &jobs[index + 1]))
		}
	}
	pause(&p)
	testing.expect(t, pending(&p) == len(jobs) && active_workers(&p) == 2)
	for r, owner in records {
		expected := [3]u8{u8('A' + owner), '3', 0}
		testing.expect(t, r.exists && r.changed && r.touched && r.clock == u32(23 + owner * 2))
		expect_bytes(t, value_data(r.value), expected[:])
		testing.expect(t, !record_free(&p, r))
	}
	seen: [16]bool
	retained: ^Value
	count := 0
	for job := poll(&p); job != nil; job = poll(&p) {
		index := int((uintptr(job) - uintptr(&jobs[0])) / size_of(Job))
		testing.expect(t, index >= 0 && index < len(jobs) && !seen[index])
		seen[index] = true
		count += 1
		if job.op == .Get {
			round := index / 4
			owner := index % 4 / 2
			expected := [3]u8{u8('A' + owner), u8('0' + round), 0}
			testing.expect(t, job.result_found && job.result != nil)
			expect_bytes(t, value_data(job.result), expected[:])
			if index == 1 {
				retained = job.result
				job.result = nil
			}
		}
		release_job_refs(job)
	}
	testing.expect(t, count == len(jobs) && retained != nil && pending(&p) == 0)
	for r in records {
		testing.expect(t, record_free(&p, r))
	}
	testing.expect(t, memory_used(&p) > 0 && !destroy(&p))
	expect_bytes(t, value_data(retained), []u8{'A', '0', 0})
	value_release(retained)
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
}

@(test)
missing_and_empty_values_preserve_creation_and_no_touch_semantics :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 1, 1 << 20))
	defer destroy(&p)
	r := record_new(&p, 0, nil, 0, false, nil, 7)
	testing.expect(t, r != nil)
	jobs := [3]Job{
		{record = r, op = .Get, clock = 10, touch = true},
		{record = r, op = .Set, value = value_new(&p, nil), clock = 20},
		{record = r, op = .Get, clock = 30},
	}
	for &job in jobs {
		testing.expect(t, submit(&p, &job))
	}
	pause(&p)
	testing.expect(t, r.exists && r.changed && r.touched && r.clock == 20 && len(value_data(r.value)) == 0)
	testing.expect(t, poll(&p) == &jobs[0] && !jobs[0].result_found && jobs[0].result == nil)
	testing.expect(t, poll(&p) == &jobs[1] && poll(&p) == &jobs[2] && jobs[2].result_found && jobs[2].result != nil)
	for &job in jobs {
		release_job_refs(&job)
	}
	testing.expect(t, resume(&p))
	setting := Job{record = r, op = .Set, value = value_new(&p, test_bytes("new")), clock = 40}
	reading := Job{record = r, op = .Get, clock = 50}
	testing.expect(t, submit(&p, &setting) && submit(&p, &reading))
	pause(&p)
	testing.expect(t, r.clock == 20 && poll(&p) == &setting && poll(&p) == &reading)
	expect_bytes(t, value_data(reading.result), test_bytes("new"))
	release_job_refs(&setting)
	release_job_refs(&reading)
	testing.expect(t, resume(&p))
	reading = Job{record = r, op = .Get, clock = 60, touch = true}
	testing.expect(t, submit(&p, &reading))
	pause(&p)
	testing.expect(t, r.clock == 60 && poll(&p) == &reading)
	release_job_refs(&reading)
	testing.expect(t, record_free(&p, r) && memory_used(&p) == 0 && destroy(&p))
}

@(test)
global_capacity_retains_completions_across_pause_stop_and_restart :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 2, 1 << 20))
	defer destroy(&p)
	r := record_new(&p, 0, test_bytes("missing"), 1, false, nil, 0)
	testing.expect(t, r != nil)
	jobs: [CAPACITY + 1]Job
	for &job in jobs {
		job.record = r
	}
	for &job in jobs[:CAPACITY] {
		testing.expect(t, submit(&p, &job))
	}
	pause(&p)
	fd := completion_fd(&p)
	testing.expect(t, fd >= 0 && pending(&p) == CAPACITY && !record_free(&p, r))
	testing.expect(t, resume(&p) && completion_fd(&p) == fd)
	jobs[CAPACITY].elapsed_ns = 17
	jobs[CAPACITY].result_found = true
	used := memory_used(&p)
	testing.expect(t, !submit(&p, &jobs[CAPACITY]) && jobs[CAPACITY].elapsed_ns == 17 && jobs[CAPACITY].result_found && memory_used(&p) == used)
	first := poll(&p)
	testing.expect(t, first != nil && submit(&p, &jobs[CAPACITY]))
	stop(&p)
	testing.expect(t, pending(&p) == CAPACITY && active_workers(&p) == 0 && completion_fd(&p) == fd)
	testing.expect(t, !destroy(&p) && resume(&p) && completion_fd(&p) == fd)
	stop(&p)
	seen: [CAPACITY + 1]bool
	seen[int((uintptr(first) - uintptr(&jobs[0])) / size_of(Job))] = true
	count := 1
	for job := poll(&p); job != nil; job = poll(&p) {
		index := int((uintptr(job) - uintptr(&jobs[0])) / size_of(Job))
		testing.expect(t, index >= 0 && index < len(jobs) && !seen[index] && !job.result_found && job.result == nil)
		seen[index] = true
		count += 1
	}
	testing.expect(t, count == len(jobs) && pending(&p) == 0)
	notifications: u64
	nread, err := linux.read(fd, (cast([^]u8)&notifications)[:size_of(notifications)])
	testing.expect(t, nread == 8 && err == .NONE && notifications == 1)
	drain_notifications(&p)
	buffer: [8]u8
	_, err = linux.read(fd, buffer[:])
	testing.expect(t, err == .EAGAIN)
	testing.expect(t, record_free(&p, r) && memory_used(&p) == 0 && destroy(&p))
}

read_notifications :: proc(fd: linux.Fd) -> u64 {
	count: u64
	_, err := linux.read(fd, (cast([^]u8)&count)[:size_of(count)])
	return count if err == .NONE else 0
}

@(test)
completions_notify_once_per_empty_ring_and_drain_in_one_batch :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 2, 1 << 20))
	defer destroy(&p)
	r := record_new(&p, 0, test_bytes("key"), 0, false, nil, 0)
	testing.expect(t, r != nil)
	fd := completion_fd(&p)
	jobs: [6]Job
	for &job in jobs[:3] {
		job.record = r
		testing.expect(t, submit(&p, &job))
	}
	pause(&p)
	testing.expect(t, p.parked == 2 && read_notifications(fd) == 1 && read_notifications(fd) == 0)
	out: [CAPACITY]^Job
	testing.expect(t, poll_all(&p, out[:]) == 3 && out[0] == &jobs[0] && out[1] == &jobs[1] && out[2] == &jobs[2])
	testing.expect(t, pending(&p) == 0 && poll(&p) == nil && poll_all(&p, out[:]) == 0 && jobs[2].state == .Idle)
	testing.expect(t, resume(&p) && resume(&p))
	for &job in jobs[3:] {
		job.record = r
		testing.expect(t, submit(&p, &job))
	}
	pause(&p)
	testing.expect(t, read_notifications(fd) == 1)
	testing.expect(t, poll_all(&p, out[:1]) == 1 && out[0] == &jobs[3] && pending(&p) == 2)
	testing.expect(t, poll_all(&p, out[:]) == 2 && out[0] == &jobs[4] && out[1] == &jobs[5] && pending(&p) == 0)
	drain_notifications(&p)
	testing.expect(t, read_notifications(fd) == 0 && record_free(&p, r) && memory_used(&p) == 0 && destroy(&p))
}

@(test)
rejection_keeps_inputs_and_accepted_writes_ignore_delivery_metadata :: proc(t: ^testing.T) {
	p, other: Pool
	testing.expect(t, init(&p, 1, 1 << 20) && init(&other, 1, 1 << 20))
	defer destroy(&p)
	defer destroy(&other)
	r := record_new(&p, 0, test_bytes("key"), 0, true, test_bytes("old"), 10)
	foreign_value := value_new(&other, test_bytes("foreign"))
	testing.expect(t, r != nil && foreign_value != nil)
	used := memory_used(&p)
	invalid := Job{record = r, op = .Set, value = foreign_value, elapsed_ns = 19, result_found = true}
	testing.expect(t, !submit(&p, &invalid) && invalid.state == .Idle && invalid.elapsed_ns == 19 && invalid.result_found && memory_used(&p) == used)
	expect_bytes(t, value_data(foreign_value), test_bytes("foreign"))
	invalid = Job{record = r, op = .Get, value = foreign_value}
	testing.expect(t, !submit(&p, &invalid))
	invalid = Job{record = r, result = foreign_value}
	testing.expect(t, !submit(&p, &invalid))
	invalid = Job{record = r, op = .Set}
	testing.expect(t, !submit(&p, &invalid))
	invalid = Job{}
	testing.expect(t, !submit(&p, &invalid))
	value_release(foreign_value)
	delivery_alive: u32 = 1
	setting := Job{record = r, op = .Set, value = value_new(&p, test_bytes("committed")), clock = 99, touch = true, data = &delivery_alive}
	testing.expect(t, setting.value != nil && submit(&p, &setting))
	intrinsics.atomic_store_explicit(&delivery_alive, 0, .Release)
	testing.expect(t, !submit(&p, &setting) && !submit(&other, &setting))
	stop(&p)
	testing.expect(t, r.exists && r.changed && r.clock == 99 && pending(&p) == 1)
	expect_bytes(t, value_data(r.value), test_bytes("committed"))
	testing.expect(t, poll(&p) == &setting)
	release_job_refs(&setting)
	testing.expect(t, record_free(&p, r) && memory_used(&p) == 0 && destroy(&p))
	testing.expect(t, memory_used(&other) == 0 && destroy(&other))
}

Test_Failing_Allocator :: struct {
	remaining: int,
}

test_failing_allocator :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	state := cast(^Test_Failing_Allocator)allocator_data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		if state.remaining == 0 {
			return nil, .Out_Of_Memory
		}
		state.remaining -= 1
	}
	allocator := runtime.default_allocator()
	return allocator.procedure(allocator.data, mode, size, alignment, old_memory, old_size, loc)
}

test_start_failure :: proc(p: ^Pool, initial: bool) -> bool {
	state := Test_Failing_Allocator{remaining = 1}
	saved := context.allocator
	context.allocator = runtime.Allocator{procedure = test_failing_allocator, data = &state}
	ok := init(p, 2, 1 << 20) if initial else resume(p)
	context.allocator = saved
	return ok
}

@(test)
partial_start_failure_preserves_stopped_record_and_completion_ownership :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, !test_start_failure(&p, true))
	testing.expect(t, active_workers(&p) == 0 && completion_fd(&p) == -1 && memory_used(&p) == 0)
	testing.expect(t, init(&p, 2, 1 << 20))
	r := record_new(&p, 0, test_bytes("key"), 1, false, nil, 0)
	setting := Job{record = r, op = .Set, value = value_new(&p, test_bytes("value")), clock = 5}
	testing.expect(t, r != nil && setting.value != nil && submit(&p, &setting))
	stop(&p)
	fd := completion_fd(&p)
	used := memory_used(&p)
	testing.expect(t, !test_start_failure(&p, false))
	testing.expect(t, active_workers(&p) == 0 && completion_fd(&p) == fd && pending(&p) == 1 && memory_used(&p) == used)
	testing.expect(t, !record_free(&p, r) && poll(&p) == &setting)
	expect_bytes(t, value_data(r.value), test_bytes("value"))
	release_job_refs(&setting)
	testing.expect(t, record_free(&p, r) && memory_used(&p) == 0 && destroy(&p))
}

Ref_Release :: struct {
	value: ^Value,
	gate:  ^u32,
}

release_from_thread :: proc(data: rawptr) {
	state := cast(^Ref_Release)data
	for intrinsics.atomic_load_explicit(state.gate, .Acquire) == 0 {
		linux.sched_yield()
	}
	value_release(state.value)
}

@(test)
last_value_reference_is_reclaimed_by_concurrent_owners :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 1, 1 << 20))
	defer destroy(&p)
	value := value_new(&p, test_bytes("shared\x00immutable"))
	testing.expect(t, value != nil && memory_used(&p) > 0)
	gate: u32
	owners: [4]Ref_Release
	threads: [4]^thread.Thread
	for &owner, i in owners {
		owner = Ref_Release{value = value_retain(value), gate = &gate}
		threads[i] = thread.create_and_start_with_data(&owner, release_from_thread)
		testing.expect(t, threads[i] != nil)
	}
	value_release(value)
	intrinsics.atomic_store_explicit(&gate, 1, .Release)
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
}

Shard_Producer :: struct {
	pool:     ^Pool,
	jobs:     []Job,
	finished: ^u32,
	rejected: int,
}

produce_shard_history :: proc(data: rawptr) {
	producer := cast(^Shard_Producer)data
	for &job in producer.jobs {
		if !submit(producer.pool, &job) {
			producer.rejected += 1
		}
		linux.sched_yield()
	}
	intrinsics.atomic_add_explicit(producer.finished, 1, .Release)
}

check_history_completion :: proc(t: ^testing.T, job: ^Job, jobs: []Job, seen: []bool) {
	index := int((uintptr(job) - uintptr(raw_data(jobs))) / size_of(Job))
	testing.expect(t, index >= 0 && index < len(jobs) && !seen[index])
	seen[index] = true
	if job.op == .Get {
		expected := [2]u8{u8('A' + index / 16), u8('0' + index % 16 / 2)}
		testing.expect(t, job.result_found)
		expect_bytes(t, value_data(job.result), expected[:])
	}
	release_job_refs(job)
}

@(test)
independent_shard_producers_and_coordinator_polling_preserve_each_history :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 4, 1 << 20))
	defer destroy(&p)
	records: [4]^Record
	jobs: [CAPACITY]Job
	for &record, owner in records {
		key := [1]u8{u8('A' + owner)}
		record = record_new(&p, owner, key[:], owner, false, nil, 0)
		testing.expect(t, record != nil)
		for round in 0 ..< 8 {
			index := owner * 16 + round * 2
			bytes := [2]u8{u8('A' + owner), u8('0' + round)}
			jobs[index] = Job{record = record, op = .Set, value = value_new(&p, bytes[:]), clock = u32(round + 1), touch = true}
			jobs[index + 1] = Job{record = record, op = .Get}
			testing.expect(t, jobs[index].value != nil)
		}
	}
	finished: u32
	producers: [4]Shard_Producer
	threads: [4]^thread.Thread
	for &producer, i in producers {
		producer = Shard_Producer{pool = &p, jobs = jobs[i * 16:][:16], finished = &finished}
		threads[i] = thread.create_and_start_with_data(&producer, produce_shard_history)
		testing.expect(t, threads[i] != nil)
	}
	seen: [CAPACITY]bool
	completed := 0
	deadline := test_now_ns() + 2_000_000_000
	for intrinsics.atomic_load_explicit(&finished, .Acquire) != 4 && test_now_ns() < deadline {
		if job := poll(&p); job != nil {
			check_history_completion(t, job, jobs[:], seen[:])
			completed += 1
		}
		linux.sched_yield()
	}
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	testing.expect(t, finished == 4)
	for producer in producers {
		testing.expect(t, producer.rejected == 0)
	}
	pause(&p)
	for job := poll(&p); job != nil; job = poll(&p) {
		check_history_completion(t, job, jobs[:], seen[:])
		completed += 1
	}
	testing.expect(t, completed == len(jobs) && pending(&p) == 0)
	for r, owner in records {
		expected := [2]u8{u8('A' + owner), '7'}
		expect_bytes(t, value_data(r.value), expected[:])
		testing.expect(t, r.clock == 8 && record_free(&p, r))
	}
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
}

multi_owner_increment :: proc "contextless" (job: ^Job) {
	for record in job.records { record.clock += 1 }
}

multi_owner_abort :: proc "contextless" (job: ^Job) {
	job.abort = true
}

@(test)
multi_owner_jobs_keep_fifo_across_reversed_and_duplicate_records :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 3, 1 << 20))
	records := [3]^Record{
		record_new(&p, 0, test_bytes("a"), 0, true, test_bytes("a"), 0),
		record_new(&p, 0, test_bytes("b"), 1, true, test_bytes("b"), 0),
		record_new(&p, 0, test_bytes("c"), 2, true, test_bytes("c"), 0),
	}
	plans := [4][3]^Record{
		{records[0], records[1], records[2]},
		{records[2], records[1], records[0]},
		{records[1], records[1], records[0]},
		{records[2], records[0], records[2]},
	}
	jobs: [4]Job
	for plan, i in plans {
		jobs[i] = Job{op = .Custom, record = plan[0], records = plans[i][:], executor = multi_owner_increment}
		testing.expect(t, submit(&p, &jobs[i]))
	}
	pause(&p)
	count := 0
	for job := poll(&p); job != nil; job = poll(&p) {
		testing.expect(t, !job.cancelled && job.arrived == job.participants && job.departed == job.participants)
		count += 1
	}
	testing.expect(t, count == 4 && records[0].clock == 4 && records[1].clock == 4 && records[2].clock == 4)
	for record in records { testing.expect(t, record_free(&p, record)) }
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
}

@(test)
failed_owner_job_cancels_following_work_before_mutation_and_can_resume :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 2, 1 << 20))
	records := [2]^Record{
		record_new(&p, 0, test_bytes("a"), 0, true, test_bytes("a"), 0),
		record_new(&p, 0, test_bytes("b"), 1, true, test_bytes("b"), 0),
	}
	first := Job{op = .Custom, record = records[0], records = records[:], executor = multi_owner_abort}
	second := Job{op = .Custom, record = records[1], records = records[:], executor = multi_owner_increment}
	testing.expect(t, submit(&p, &first))
	accepted := submit(&p, &second)
	pause(&p)
	count := 0
	for job := poll(&p); job != nil; job = poll(&p) { count += 1 }
	testing.expect(t, count == (2 if accepted else 1) && first.abort && (!accepted || second.cancelled))
	testing.expect(t, records[0].clock == 0 && records[1].clock == 0)
	testing.expect(t, resume(&p))
	third := Job{op = .Custom, record = records[0], records = records[:], executor = multi_owner_increment}
	testing.expect(t, submit(&p, &third))
	pause(&p)
	testing.expect(t, poll(&p) == &third && poll(&p) == nil && !third.cancelled)
	testing.expect(t, records[0].clock == 1 && records[1].clock == 1)
	for record in records { testing.expect(t, record_free(&p, record)) }
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
}

@(test)
external_object_reservations_share_the_pool_limit :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 1, 4096))
	testing.expect(t, !reserve_external(nil, 1) && !reserve_external(&p, -1))
	testing.expect(t, reserve_external(&p, 4000) && memory_used(&p) == 4000)
	testing.expect(t, !reserve_external(&p, 97) && len(allocate(&p, 128)) == 0)
	testing.expect(t, reserve_external(&p, 96) && memory_used(&p) == 4096)
	testing.expect(t, !destroy(&p))
	release_external(&p, 4096)
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
}

callback_enter_count: u32
callback_leave_count: u32
callback_context_count: u32

callback_assertion :: proc(prefix, message: string, location: runtime.Source_Code_Location) -> ! {
	runtime.default_assertion_failure_proc(prefix, message, location)
}

callback_enter :: proc() {
	intrinsics.atomic_add_explicit(&callback_enter_count, 1, .Relaxed)
	if context.assertion_failure_proc == callback_assertion {
		intrinsics.atomic_add_explicit(&callback_context_count, 1, .Relaxed)
	}
}

callback_leave :: proc() {
	intrinsics.atomic_add_explicit(&callback_leave_count, 1, .Relaxed)
	if context.assertion_failure_proc == callback_assertion {
		intrinsics.atomic_add_explicit(&callback_context_count, 1, .Relaxed)
	}
}

@(test)
pool_worker_callback_context_lifecycle :: proc(t: ^testing.T) {
	callback_enter_count, callback_leave_count, callback_context_count = 0, 0, 0
	p: Pool
	testing.expect(t, init(&p, 2, 1024 * 1024, callback_enter, callback_leave, callback_assertion))
	pause(&p)
	testing.expect(t, resume(&p))
	stop(&p)
	testing.expect(t, resume(&p))
	testing.expect(t, destroy(&p))
	testing.expect_value(t, callback_enter_count, u32(4))
	testing.expect_value(t, callback_leave_count, u32(4))
	testing.expect_value(t, callback_context_count, u32(8))
}

inline_context_count: u32

inline_context_probe :: proc(job: ^Job) {
	if context.assertion_failure_proc == callback_assertion && context.allocator.procedure == runtime.heap_allocator_proc && context.temp_allocator.procedure == runtime.nil_allocator_proc {
		intrinsics.atomic_add_explicit(&inline_context_count, 1, .Relaxed)
	}
	for record in job.records { record.clock += 1 }
}

inline_context_abort :: proc(job: ^Job) {
	job.abort = true
}

@(test)
coordinator_inline_execution_needs_an_empty_accepting_pool_and_halts_on_abort :: proc(t: ^testing.T) {
	inline_context_count = 0
	p: Pool
	testing.expect(t, init(&p, 2, 1 << 20, nil, nil, callback_assertion))
	records := [2]^Record{
		record_new(&p, 0, test_bytes("a"), 0, true, test_bytes("a"), 0),
		record_new(&p, 0, test_bytes("b"), 1, true, test_bytes("b"), 0),
	}
	missing := Job{op = .Custom, record = records[0], records = records[:]}
	empty := Job{op = .Custom, record = records[0], context_executor = inline_context_probe}
	testing.expect(t, !execute_inline(&p, &missing) && !execute_inline(&p, &empty) && !execute_inline(nil, &missing) && !execute_inline(&p, nil))
	first := Job{op = .Custom, record = records[0], records = records[:], context_executor = inline_context_probe}
	testing.expect(t, execute_inline(&p, &first))
	testing.expect(t, first.executed && !first.abort && !first.cancelled && first.state == .Idle && first.elapsed_ns == 0)
	testing.expect(t, pending(&p) == 0 && records[0].clock == 1 && records[1].clock == 1 && inline_context_count == 1)
	held := Job{op = .Custom, record = records[1], records = records[1:], executor = multi_owner_increment}
	testing.expect(t, submit(&p, &held))
	blocked := Job{op = .Custom, record = records[0], records = records[:], context_executor = inline_context_probe}
	testing.expect(t, !execute_inline(&p, &blocked) && blocked.state == .Idle && !blocked.executed)
	pause(&p)
	testing.expect(t, poll(&p) == &held && poll(&p) == nil && records[1].clock == 2)
	testing.expect(t, !execute_inline(&p, &blocked))
	testing.expect(t, resume(&p))
	testing.expect(t, execute_inline(&p, &blocked) && records[0].clock == 2 && records[1].clock == 3)
	failing := Job{op = .Custom, record = records[0], records = records[:], context_executor = inline_context_abort}
	testing.expect(t, execute_inline(&p, &failing) && failing.abort && failing.executed && records[0].clock == 2)
	after := Job{op = .Custom, record = records[0], records = records[:], context_executor = inline_context_probe}
	testing.expect(t, !execute_inline(&p, &after) && !submit(&p, &after) && after.state == .Idle)
	testing.expect(t, resume(&p) && !execute_inline(&p, &after))
	pause(&p)
	testing.expect(t, poll(&p) == nil && resume(&p))
	testing.expect(t, execute_inline(&p, &after) && records[0].clock == 3 && records[1].clock == 4)
	testing.expect_value(t, inline_context_count, u32(3))
	pause(&p)
	for record in records { testing.expect(t, record_free(&p, record)) }
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
}

wait_pool :: proc(p: ^Pool, parked, completed: int) -> bool {
	deadline := test_now_ns() + 2_000_000_000
	for test_now_ns() < deadline {
		sync.mutex_lock(&p.mutex)
		ready := p.parked == parked && p.done_len == completed
		sync.mutex_unlock(&p.mutex)
		if ready {
			return true
		}
		linux.sched_yield()
	}
	return false
}

owed_owners :: proc "contextless" (p: ^Pool) -> u64 {
	return intrinsics.atomic_load_explicit(&p.owed, .Relaxed)
}

@(test)
parked_owners_wait_for_one_deferred_signal_and_pause_or_stop_signal_owed_owners :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 2, 1 << 20))
	records := [2]^Record{
		record_new(&p, 0, test_bytes("a"), 0, true, test_bytes("a"), 0),
		record_new(&p, 0, test_bytes("b"), 1, true, test_bytes("b"), 0),
	}
	testing.expect(t, records[0] != nil && records[1] != nil && wait_pool(&p, 2, 0))
	base := signal_count(&p)
	first := Job{op = .Custom, record = records[0], records = records[:1], executor = multi_owner_increment}
	second := Job{op = .Custom, record = records[0], records = records[:1], executor = multi_owner_increment}
	testing.expect(t, submit(&p, &first) && submit(&p, &second))
	testing.expect(t, owed_owners(&p) == 1 && signal_count(&p) == base)
	signal_owed(&p)
	testing.expect(t, owed_owners(&p) == 0 && signal_count(&p) == base + 1)
	testing.expect(t, wait_pool(&p, 2, 2))
	testing.expect(t, poll(&p) == &first && poll(&p) == &second && poll(&p) == nil && records[0].clock == 2)
	signal_owed(&p)
	testing.expect(t, signal_count(&p) == base + 1)
	both := Job{op = .Custom, record = records[0], records = records[:], executor = multi_owner_increment}
	later := Job{op = .Custom, record = records[1], records = records[1:], executor = multi_owner_increment}
	testing.expect(t, submit(&p, &both) && submit(&p, &later))
	testing.expect(t, owed_owners(&p) == 3 && signal_count(&p) == base + 1)
	pause(&p)
	testing.expect(t, owed_owners(&p) == 0 && signal_count(&p) == base + 3 && pending(&p) == 2 && p.parked == 2)
	out: [3]^Job
	testing.expect(t, poll_all(&p, out[:]) == 2 && (out[0] == &both && out[1] == &later || out[0] == &later && out[1] == &both))
	testing.expect(t, records[0].clock == 3 && records[1].clock == 2 && !both.cancelled && !later.cancelled)
	testing.expect(t, resume(&p))
	stopped := Job{op = .Custom, record = records[1], records = records[1:], executor = multi_owner_increment}
	testing.expect(t, submit(&p, &stopped) && owed_owners(&p) == 2)
	stop(&p)
	testing.expect(t, owed_owners(&p) == 0 && signal_count(&p) == base + 4 && active_workers(&p) == 0)
	testing.expect(t, poll(&p) == &stopped && poll(&p) == nil && !stopped.cancelled && records[1].clock == 3)
	for record in records { testing.expect(t, record_free(&p, record)) }
	testing.expect(t, memory_used(&p) == 0 && destroy(&p))
}

@(test)
record_key_bytes_sit_at_a_fixed_offset_from_the_record :: proc(t: ^testing.T) {
	p: Pool
	testing.expect(t, init(&p, 2, 4096))
	key := [5]u8{'k', 0, 'e', 'y', 255}
	r := record_new(&p, 7, key[:], 1, false, nil, 0)
	testing.expect(t, r != nil)
	if r == nil { return }
	testing.expect(t, raw_data(record_key(r, len(key))) == raw_data(r.key) && len(record_key(r, len(key))) == len(r.key))
	expect_bytes(t, record_key(r, len(key)), key[:])
	record_prefetch(r, len(key))
	record_prefetch(r, 0)
	empty := record_new(&p, 0, nil, 0, false, nil, 0)
	testing.expect(t, empty != nil && len(record_key(empty, 0)) == 0)
	pause(&p)
	testing.expect(t, record_free(&p, r) && record_free(&p, empty) && memory_used(&p) == 0 && destroy(&p))
}

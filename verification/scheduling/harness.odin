package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:sys/linux"
import ks "keyspace"

VERSION :: "scheduling-verification"
REDIS_COMPAT_VERSION :: "7.4.0"

Harness_Data :: struct {
	entered: u32,
	release: u32,
	observed: [4]u32,
	count: int,
}

harness_bytes :: proc(text: string) -> []u8 { return transmute([]u8)text }

harness_gate :: proc "contextless" (job: ^ks.Job) {
	data := cast(^Harness_Data)job.data
	intrinsics.atomic_store_explicit(&data.entered, 1, .Release)
	for intrinsics.atomic_load_explicit(&data.release, .Acquire) == 0 { linux.sched_yield() }
	job.record.clock += 1
}

harness_increment :: proc "contextless" (job: ^ks.Job) {
	data := cast(^Harness_Data)job.data
	for r, i in job.records {
		data.observed[i] = r.clock
		r.clock += 1
		data.count += 1
	}
}

harness_abort :: proc "contextless" (job: ^ks.Job) {
	harness_gate(job)
	job.record.clock -= 1
	job.abort = true
}

harness_wait :: proc(flag: ^u32) {
	start, _ := linux.clock_gettime(.MONOTONIC)
	for intrinsics.atomic_load_explicit(flag, .Acquire) == 0 {
		now, _ := linux.clock_gettime(.MONOTONIC)
		assert(now.time_sec - start.time_sec < 5)
		linux.sched_yield()
	}
}

harness_pool :: proc() {
	p: ks.Pool
	assert(ks.init(&p, 2, 1 << 20))
	a := ks.record_new(&p, 0, harness_bytes("a"), 0, false, nil, 0)
	b := ks.record_new(&p, 0, harness_bytes("b"), 1, false, nil, 0)
	assert(a != nil && b != nil)
	gate: Harness_Data
	first := ks.Job{op = .Custom, record = a, records = []^ks.Record{a}, executor = harness_gate, data = &gate}
	second_data: Harness_Data
	second := ks.Job{op = .Custom, record = b, records = []^ks.Record{b}, executor = harness_increment, data = &second_data}
	assert(ks.submit(&p, &first))
	harness_wait(&gate.entered)
	assert(ks.submit(&p, &second))
	start, _ := linux.clock_gettime(.MONOTONIC)
	polled: ^ks.Job
	for polled == nil {
		polled = ks.poll(&p)
		now, _ := linux.clock_gettime(.MONOTONIC)
		assert(now.time_sec - start.time_sec < 5)
		linux.sched_yield()
	}
	assert(polled == &second && ks.pending(&p) == 1)
	assert(!ks.submit(&p, &first))
	intrinsics.atomic_store_explicit(&gate.release, 1, .Release)
	ks.pause(&p)
	assert(ks.poll(&p) == &first && ks.poll(&p) == nil && a.clock == 1 && b.clock == 1)
	invalid := ks.Job{op = .Set, record = a, elapsed_ns = 73, result_found = true}
	used := ks.memory_used(&p)
	assert(!ks.submit(&p, &invalid) && invalid.state == .Idle && invalid.elapsed_ns == 73 && invalid.result_found)
	assert(ks.memory_used(&p) == used && ks.pending(&p) == 0 && ks.resume(&p))
	plans := [3][3]^ks.Record{{a, b, a}, {b, a, b}, {a, a, b}}
	data: [3]Harness_Data
	jobs: [3]ks.Job
	for plan, i in plans {
		jobs[i] = ks.Job{op = .Custom, record = plan[0], records = plans[i][:], executor = harness_increment, data = &data[i]}
		assert(ks.submit(&p, &jobs[i]))
	}
	ks.pause(&p)
	assert(a.clock == 6 && b.clock == 5)
	assert(data[0].observed == [4]u32{1, 1, 2, 0})
	assert(data[1].observed == [4]u32{2, 3, 3, 0})
	assert(data[2].observed == [4]u32{4, 5, 4, 0})
	for i in 0 ..< 3 {
		job := ks.poll(&p)
		assert(job == &jobs[i] && job.participants == 2 && job.arrived == 2 && job.departed == 2)
	}
	assert(ks.poll(&p) == nil && ks.resume(&p))
	abort_gate: Harness_Data
	abort_job := ks.Job{op = .Custom, record = a, records = []^ks.Record{a, b}, executor = harness_abort, data = &abort_gate}
	assert(ks.submit(&p, &abort_job))
	harness_wait(&abort_gate.entered)
	cancel_data: Harness_Data
	cancel_job := ks.Job{op = .Custom, record = b, records = []^ks.Record{b, a}, executor = harness_increment, data = &cancel_data}
	assert(ks.submit(&p, &cancel_job))
	intrinsics.atomic_store_explicit(&abort_gate.release, 1, .Release)
	ks.pause(&p)
	assert(ks.poll(&p) == &abort_job && ks.poll(&p) == &cancel_job && ks.poll(&p) == nil)
	assert(abort_job.abort && cancel_job.cancelled && cancel_data.count == 0 && a.clock == 6 && b.clock == 5)
	assert(ks.resume(&p))
	final_data: Harness_Data
	final_job := ks.Job{op = .Custom, record = a, records = []^ks.Record{a, b}, executor = harness_increment, data = &final_data}
	assert(ks.submit(&p, &final_job))
	ks.pause(&p)
	assert(ks.poll(&p) == &final_job && !final_job.cancelled && a.clock == 7 && b.clock == 6)
	assert(ks.record_free(&p, a) && ks.record_free(&p, b))
	assert(ks.memory_used(&p) == 0 && ks.destroy(&p))
	fmt.println("POOL|out_of_order_completion|rejection|duplicate_admission|aliases|reverse_owners|pause_resume|abort_halt|cancel_before_mutation|resume_after_abort|clean")
}

harness_retry_count: int

harness_retry_handler :: proc(c: ^Conn, argv: [][]u8) {
	assert(c != nil && len(argv) == 2 && argv[1][0] == u8('0' + harness_retry_count))
	harness_retry_count += 1
	cmd_incr(c, argv)
}

harness_coordinator :: proc() {
	config_init()
	cfg.slowlog_log_slower_than = -1
	cfg.latency_tracking = false
	cfg.latency_monitor_threshold = 0
	db_count = 1
	db_init()
	srv.now_ms = 1000
	assert(ks.init(&keyspace_pool, 2, 1 << 20))
	keyspace_initialized = true
	st := Cmd_Hot{limit_ticks = max(u64)}
	command := Command{name = "incr", handler = harness_retry_handler, arity = 2}
	args: [3][2][]u8
	ids := [3][1]u8{{'0'}, {'1'}, {'2'}}
	tasks: [3]Keyspace_Task
	for &task, i in tasks {
		args[i] = {harness_bytes("INCR"), ids[i][:]}
		task = Keyspace_Task{sequence = u64(i), fd = 0, client_id = 71, token = 99, stats = &st, failed = true, rolled_back = true, command = &command, argv = args[i][:]}
		task.client.db = db_cur
		task.client.fd = -1
		task.job.data = &task
		if i > 0 { keyspace_completions[i] = &task }
	}
	keyspace_completion_count = 2
	keyspace_pending = 3
	keyspace_next_sequence = 3
	conn := Conn{id = 71, fd = 0, db = db_cur, keyspace_inflight = 3, keyspace_token = 99}
	srv.conns = make([dynamic]^Conn, 1)
	srv.conns[0] = &conn
	keyspace_conn_closed(&conn)
	assert(conn.keyspace_inflight == 0 && conn.keyspace_token == 0 && !conn.keyspace_ready && !tasks[0].job.cancelled)
	conn.id = 72
	keyspace_publish_completions(true)
	assert(keyspace_publish_sequence == 0 && keyspace_pending == 3 && harness_retry_count == 0)
	keyspace_completions[0] = &tasks[0]
	keyspace_completion_count = 3
	keyspace_publish_completions(false)
	assert(keyspace_publish_sequence == 0 && keyspace_pending == 3 && harness_retry_count == 0)
	keyspace_publish_completions(true)
	assert(keyspace_publish_sequence == 3 && keyspace_pending == 0 && keyspace_completion_count == 0)
	assert(harness_retry_count == 3 && len(keyspace_retries) == 0)
	keyspace_publish_completions(true)
	assert(harness_retry_count == 3)
	assert(conn.wlen == 0 && !conn.keyspace_ready && conn.keyspace_inflight == 0 && len(keyspace_ready) == 0)
	for i in 0 ..< 3 {
		reader := Conn{fd = -1, db = db_cur}
		cmd_get(&reader, args[i][:])
		assert(string(reader.wbuf[:reader.wlen]) == "$1\r\n1\r\n")
		runtime.heap_free(reader.wbuf)
	}
	live := Conn{id = 73, fd = 0, db = db_cur, keyspace_inflight = 3, keyspace_token = 100}
	srv.conns[0] = &live
	pipelined: [3]Keyspace_Task
	for &task, i in pipelined {
		task = Keyspace_Task{sequence = u64(3 + i), fd = 0, client_id = 73, token = 100, stats = &st, command = &command, argv = args[i][:], integer = i64(i + 1)}
		task.client.db = db_cur
		task.client.fd = -1
		task.job.data = &task
		if i > 0 { keyspace_completions[3 + i] = &task }
	}
	keyspace_completion_count = 2
	keyspace_pending = 3
	keyspace_next_sequence = 6
	keyspace_publish_completions(false)
	assert(keyspace_publish_sequence == 3 && live.wlen == 0 && live.keyspace_inflight == 3 && !live.keyspace_ready)
	keyspace_completions[3] = &pipelined[0]
	keyspace_completion_count = 3
	keyspace_publish_completions(false)
	assert(keyspace_publish_sequence == 6 && keyspace_pending == 0 && keyspace_completion_count == 0)
	assert(string(live.wbuf[:live.wlen]) == ":1\r\n:2\r\n:3\r\n" && live.keyspace_inflight == 0)
	assert(live.keyspace_ready && len(keyspace_ready) == 1 && keyspace_ready[0].id == 73)
	runtime.heap_free(live.wbuf)
	delete(keyspace_ready); keyspace_ready = nil
	delete(srv.conns); srv.conns = nil
	keyspace_initialized = false
	assert(ks.destroy(&keyspace_pool))
	fmt.println("COORDINATOR|failed_head_blocks|ordered_retry|disconnected_retry|exactly_once|delivery_drop|pipelined_inflight_order|single_resume_ticket")
}

harness_snapshot :: proc() {
	keyspace_pool = ks.Pool{initialized = true, configured = 2, paused = true, memory_limit = 1 << 20, fd = -1}
	a := ks.record_new(&keyspace_pool, 0, harness_bytes("a"), 0, true, harness_bytes("old-a"), 71)
	b := ks.record_new(&keyspace_pool, 0, harness_bytes("b"), 1, true, harness_bytes("old-b"), 72)
	records := []^ks.Record{a, b, a}
	argv := [][]u8{harness_bytes("MSET"), harness_bytes("a"), harness_bytes("x"), harness_bytes("b"), harness_bytes("y"), harness_bytes("a"), harness_bytes("z")}
	values: [3]^ks.Value
	results: [3]^ks.Value
	events: [32]Keyspace_Event
	poststates: [8]Keyspace_Poststate
	task := Keyspace_Task{op = .Mset, argv = argv, records = records, values = values[:], results = results[:], capture_poststate = true, event_storage = events[:], poststate_storage = poststates[:], now = 1000, limit = 1 << 20}
	job := ks.Job{data = &task}
	budget := len(records) * size_of(Keyspace_Undo) + 512
	reservation := keyspace_pool.memory_limit - ks.memory_used(&keyspace_pool) - budget
	assert(ks.reserve_external(&keyspace_pool, reservation))
	keyspace_capture_execute(&job)
	ks.release_external(&keyspace_pool, reservation)
	assert(task.failed && task.rolled_back && job.abort)
	assert(string(ks.value_data(a.value)) == "old-a" && string(ks.value_data(b.value)) == "old-b")
	assert(a.clock == 71 && b.clock == 72 && !a.changed && !b.changed)
	assert(task.dirty == 0 && len(task.events) == 0 && len(task.poststates) == 0)
	for value in task.values { ks.value_release(value) }
	for value in task.results { ks.value_release(value) }
	assert(ks.record_free(&keyspace_pool, a) && ks.record_free(&keyspace_pool, b))
	assert(ks.memory_used(&keyspace_pool) == 0)
	keyspace_pool = {}
	fmt.println("SNAPSHOT|actual_mutation_rollback|duplicate_aliases|unpublished_effects_discarded|balanced")
}

main :: proc() {
	harness_pool()
	harness_coordinator()
	harness_snapshot()
}

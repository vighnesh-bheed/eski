package main

import "base:runtime"
import "core:testing"
import ks "keyspace"

keyspace_fence_test_noop :: proc "contextless" (job: ^ks.Job) {}

keyspace_fence_test_settled :: proc(t: ^testing.T) {
	testing.expect(t, !keyspace_in_fence && !keyspace_replay_needed && !keyspace_timed)
	testing.expect_value(t, keyspace_records, 0)
	testing.expect_value(t, keyspace_pending, 0)
	testing.expect_value(t, keyspace_completion_count, 0)
	testing.expect_value(t, len(keyspace_retries), 0)
	testing.expect_value(t, keyspace_publish_sequence, keyspace_next_sequence)
	testing.expect_value(t, ks.pending(&keyspace_pool), 0)
	for head in keyspace_directory { testing.expect(t, head == nil) }
	for task in keyspace_completions { testing.expect(t, task == nil) }
	testing.expect(t, keyspace_fence_idle())
}

@(test)
private_keyspace_fence_idle_requires_every_counter_settled :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved_records, saved_pending, saved_count := keyspace_records, keyspace_pending, keyspace_completion_count
	saved_replay, saved_next, saved_publish := keyspace_replay_needed, keyspace_next_sequence, keyspace_publish_sequence
	saved_retries := keyspace_retries
	keyspace_retries = nil
	defer {
		keyspace_records, keyspace_pending, keyspace_completion_count = saved_records, saved_pending, saved_count
		keyspace_replay_needed, keyspace_next_sequence, keyspace_publish_sequence = saved_replay, saved_next, saved_publish
		keyspace_retries = saved_retries
	}
	testing.expect(t, keyspace_fence_idle())
	keyspace_records = 1
	testing.expect(t, !keyspace_fence_idle())
	keyspace_records = 0
	keyspace_pending = 1
	testing.expect(t, !keyspace_fence_idle())
	keyspace_pending = 0
	keyspace_completion_count = 1
	testing.expect(t, !keyspace_fence_idle())
	keyspace_completion_count = 0
	keyspace_replay_needed = true
	testing.expect(t, !keyspace_fence_idle())
	keyspace_replay_needed = false
	keyspace_next_sequence += 1
	testing.expect(t, !keyspace_fence_idle())
	keyspace_next_sequence -= 1
	append(&keyspace_retries, nil)
	testing.expect(t, !keyspace_fence_idle())
	delete(keyspace_retries)
	keyspace_retries = nil
	testing.expect(t, keyspace_fence_idle())
}

@(test)
private_keyspace_fence_fast_path_keeps_barrier_postconditions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect(t, !keyspace_initialized && !keyspace_pool.initialized)
	if keyspace_initialized || keyspace_pool.initialized { return }
	saved_pool := keyspace_pool
	saved_barriers, saved_completed, saved_submitted := keyspace_barriers, keyspace_completed, keyspace_submitted
	saved_next, saved_publish, saved_token := keyspace_next_sequence, keyspace_publish_sequence, keyspace_next_token
	saved_tracking, saved_threshold := cfg.latency_tracking, cfg.latency_monitor_threshold
	saved_commands := srv.stat_commands
	defer {
		keyspace_pool = saved_pool
		keyspace_barriers, keyspace_completed, keyspace_submitted = saved_barriers, saved_completed, saved_submitted
		keyspace_next_sequence, keyspace_publish_sequence, keyspace_next_token = saved_next, saved_publish, saved_token
		cfg.latency_tracking, cfg.latency_monitor_threshold = saved_tracking, saved_threshold
		srv.stat_commands = saved_commands
	}
	cfg.latency_tracking = false
	cfg.latency_monitor_threshold = 0
	testing.expect(t, ks.init(&keyspace_pool, 2, 1 << 20))
	keyspace_initialized = true
	defer {
		keyspace_initialized = false
		testing.expect(t, ks.destroy(&keyspace_pool))
	}
	barriers := keyspace_barriers
	keyspace_timed = true
	keyspace_fence()
	keyspace_fence_test_settled(t)
	testing.expect_value(t, keyspace_barriers, barriers)
	testing.expect(t, keyspace_pool.accepting && !keyspace_pool.paused)

	key := transmute([]u8)string("fence")
	r := ks.record_new(&keyspace_pool, 0, key, 1, false, nil, 0)
	testing.expect(t, r != nil)
	if r == nil { return }
	bucket := int(hash_bytes(key) & (KEYSPACE_BUCKETS - 1))
	r.caller_next = keyspace_directory[bucket]
	keyspace_directory[bucket] = r
	keyspace_records += 1
	keyspace_timed = true
	testing.expect(t, !keyspace_fence_idle())
	region := ks.allocate(&keyspace_pool, size_of(Keyspace_Task))
	testing.expect_value(t, len(region), size_of(Keyspace_Task))
	if len(region) == 0 { return }
	hot := Cmd_Hot{limit_ticks = max(u64)}
	hot.flags = {.Skip_Slowlog}
	command := Command{name = "fence"}
	argv := [][]u8{key}
	records := []^ks.Record{r}
	db := Db{id = 0}
	task := cast(^Keyspace_Task)raw_data(region)
	task^ = Keyspace_Task{region = region, op = .Key, fd = -1, stats = &hot, command = &command, argv = argv, records = records, sequence = keyspace_next_sequence, start = mono_now()}
	task.client = Conn{fd = -1, db = &db}
	task.job = ks.Job{op = .Custom, record = r, records = records, executor = keyspace_fence_test_noop, data = task}
	submitted := ks.submit(&keyspace_pool, &task.job)
	testing.expect(t, submitted)
	if !submitted {
		ks.free(&keyspace_pool, region)
		keyspace_fence()
		return
	}
	keyspace_next_sequence += 1
	keyspace_pending += 1
	completed := keyspace_completed
	keyspace_fence()
	keyspace_fence_test_settled(t)
	testing.expect_value(t, keyspace_barriers, barriers + 1)
	testing.expect_value(t, keyspace_completed, completed + 1)
	testing.expect(t, !keyspace_pool.accepting && keyspace_pool.paused)
	testing.expect_value(t, ks.memory_used(&keyspace_pool), 0)

	testing.expect(t, ks.resume(&keyspace_pool))
	keyspace_fence()
	keyspace_fence_test_settled(t)
	testing.expect_value(t, keyspace_barriers, barriers + 1)
	testing.expect(t, keyspace_pool.accepting && !keyspace_pool.paused)
	testing.expect_value(t, ks.memory_used(&keyspace_pool), 0)
}

package main

import "base:runtime"
import "core:slice"
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
	testing.expect_value(t, len(keyspace_index), 0)
	for slot in keyspace_index_fixed { testing.expect(t, slot.record == nil) }
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
	testing.expect(t, keyspace_index_reserve())
	keyspace_index_insert(hash_bytes(key), r)
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

keyspace_index_test_key :: proc(buffer: ^[24]u8, i: int) -> []u8 {
	copy(buffer[:], "index:")
	return buffer[:6 + format_i64(&buffer[6], i64(i))]
}

keyspace_index_test_insert :: proc(t: ^testing.T, buffer: ^[24]u8, i: int) -> (^ks.Record, int) {
	key := keyspace_index_test_key(buffer, i)
	db := i % 2
	hash := hash_bytes(key) ~ (u64(db) * WY_P1)
	testing.expect(t, keyspace_index_find(hash, key) == nil)
	used := ks.memory_used(&keyspace_pool)
	if !keyspace_index_reserve() { return nil, 0 }
	charge := ks.memory_used(&keyspace_pool) - used
	r := ks.record_new(&keyspace_pool, db, key, i % 2, false, nil, 0)
	testing.expect(t, r != nil)
	if r == nil { return nil, charge }
	keyspace_index_insert(hash, r)
	return r, charge
}

keyspace_index_test_found :: proc(t: ^testing.T, records: []^ks.Record) {
	buffer: [24]u8
	for r, i in records {
		key := keyspace_index_test_key(&buffer, i)
		db := i % 2
		testing.expect(t, keyspace_index_find(hash_bytes(key) ~ (u64(db) * WY_P1), key) == r)
		other := 1 - db
		testing.expect(t, keyspace_index_find(hash_bytes(key) ~ (u64(other) * WY_P1), key) == nil)
	}
}

@(test)
private_keyspace_record_index_grows_within_budget_and_resets_at_the_fence :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect(t, !keyspace_initialized && !keyspace_pool.initialized)
	if keyspace_initialized || keyspace_pool.initialized { return }
	saved_pool := keyspace_pool
	saved_barriers, saved_tracking, saved_threshold := keyspace_barriers, cfg.latency_tracking, cfg.latency_monitor_threshold
	defer {
		keyspace_pool = saved_pool
		keyspace_barriers, cfg.latency_tracking, cfg.latency_monitor_threshold = saved_barriers, saved_tracking, saved_threshold
	}
	cfg.latency_tracking = false
	cfg.latency_monitor_threshold = 0
	testing.expect(t, ks.init(&keyspace_pool, 2, 8 << 20))
	keyspace_initialized = true
	defer {
		keyspace_initialized = false
		testing.expect(t, ks.destroy(&keyspace_pool))
	}
	keyspace_fence_test_settled(t)
	records := make([]^ks.Record, 2 * KEYSPACE_INDEX_SLOTS)
	defer delete(records)
	buffer: [24]u8
	charged := 0
	for i in 0 ..< len(records) {
		charge: int
		records[i], charge = keyspace_index_test_insert(t, &buffer, i)
		if records[i] == nil { return }
		charged += charge
		testing.expect(t, 2 * keyspace_records <= len(keyspace_index_slots()))
		if i < KEYSPACE_INDEX_SLOTS / 2 {
			testing.expect_value(t, len(keyspace_index), 0)
			testing.expect_value(t, charge, 0)
		}
	}
	testing.expect_value(t, keyspace_records, len(records))
	testing.expect_value(t, len(keyspace_index), 4 * KEYSPACE_INDEX_SLOTS)
	for slot in keyspace_index_fixed { testing.expect(t, slot.record == nil) }
	bytes := len(keyspace_index) * size_of(Keyspace_Slot)
	testing.expect(t, charged >= bytes && charged - bytes <= 64)
	keyspace_index_test_found(t, records)
	barriers := keyspace_barriers
	keyspace_fence()
	keyspace_fence_test_settled(t)
	testing.expect_value(t, keyspace_barriers, barriers + 1)
	testing.expect_value(t, ks.memory_used(&keyspace_pool), 0)
	testing.expect(t, ks.resume(&keyspace_pool))

	full := KEYSPACE_INDEX_SLOTS / 2
	for i in 0 ..< full {
		records[i], _ = keyspace_index_test_insert(t, &buffer, i)
		if records[i] == nil { return }
	}
	testing.expect_value(t, len(keyspace_index), 0)
	used := ks.memory_used(&keyspace_pool)
	blocked := keyspace_pool.memory_limit - used - KEYSPACE_INDEX_SLOTS * size_of(Keyspace_Slot)
	testing.expect(t, ks.reserve_external(&keyspace_pool, blocked))
	testing.expect(t, !keyspace_index_reserve())
	testing.expect_value(t, ks.memory_used(&keyspace_pool), used + blocked)
	testing.expect_value(t, len(keyspace_index), 0)
	testing.expect_value(t, keyspace_records, full)
	keyspace_index_test_found(t, records[:full])
	ks.release_external(&keyspace_pool, blocked)
	testing.expect(t, keyspace_index_reserve())
	testing.expect_value(t, len(keyspace_index), 2 * KEYSPACE_INDEX_SLOTS)
	keyspace_index_test_found(t, records[:full])
	keyspace_fence()
	keyspace_fence_test_settled(t)
	testing.expect_value(t, ks.memory_used(&keyspace_pool), 0)
	testing.expect(t, ks.resume(&keyspace_pool))
}

@(test)
keyspace_key_indices_use_the_heap_only_beyond_the_fixed_buffer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	args: [2 * KEYSPACE_KEY_INDICES + 1][]u8
	args[0] = transmute([]u8)string("DEL")
	for &arg in args[1:] { arg = transmute([]u8)string("key") }
	cmd := lookup_command(args[0])
	testing.expect(t, cmd != nil)
	if cmd == nil { return }
	for count in ([?]int{1, KEYSPACE_KEY_INDICES - 1, KEYSPACE_KEY_INDICES, 2 * KEYSPACE_KEY_INDICES}) {
		argv := args[:count + 1]
		fixed: [KEYSPACE_KEY_INDICES]int
		indices := keyspace_key_indices(cmd_spec_lookup(cmd, argv), argv, &fixed)
		testing.expect_value(t, len(indices), count)
		testing.expect_value(t, raw_data(indices) == raw_data(fixed[:]), count < KEYSPACE_KEY_INDICES)
		for index, i in indices { testing.expect_value(t, index, i + 1) }
		delete(indices)
	}
}

@(test)
private_keyspace_directory_slot_matches_tag_length_and_key_bytes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect(t, !keyspace_initialized && !keyspace_pool.initialized)
	if keyspace_initialized || keyspace_pool.initialized { return }
	saved_pool := keyspace_pool
	saved_barriers, saved_tracking, saved_threshold := keyspace_barriers, cfg.latency_tracking, cfg.latency_monitor_threshold
	defer {
		keyspace_pool = saved_pool
		keyspace_barriers, cfg.latency_tracking, cfg.latency_monitor_threshold = saved_barriers, saved_tracking, saved_threshold
	}
	cfg.latency_tracking = false
	cfg.latency_monitor_threshold = 0
	tags: [1024]u32
	for &tag, db in tags { tag = u32(u64(db) * WY_P1) }
	slice.sort(tags[:])
	for i in 1 ..< len(tags) { testing.expect(t, tags[i - 1] < tags[i]) }
	testing.expect(t, ks.init(&keyspace_pool, 2, 1 << 20))
	keyspace_initialized = true
	defer {
		keyspace_initialized = false
		testing.expect(t, ks.destroy(&keyspace_pool))
	}
	key := transmute([]u8)string("alpha")
	home := 5
	hash := hash_bytes(key) ~ (u64(home) * WY_P1)
	r := ks.record_new(&keyspace_pool, home, key, 1, false, nil, 0)
	testing.expect(t, r != nil && keyspace_index_reserve())
	if r == nil { return }
	keyspace_index_insert(hash, r)
	found := 0
	for slot in keyspace_index_slots() {
		if slot.record != r { continue }
		found += 1
		testing.expect(t, slot.tag == u32(hash) && slot.length == u32(len(key)))
	}
	testing.expect_value(t, found, 1)
	testing.expect(t, keyspace_index_find(hash, key) == r)
	testing.expect(t, keyspace_index_find(hash, transmute([]u8)string("alphb")) == nil)
	testing.expect(t, keyspace_index_find(hash, transmute([]u8)string("alph")) == nil)
	testing.expect(t, keyspace_index_find(hash, transmute([]u8)string("alphaa")) == nil)
	testing.expect(t, keyspace_index_find(hash ~ 1, key) == nil)
	for db in 0 ..< 1024 {
		if db == home { continue }
		testing.expect(t, keyspace_index_find(hash_bytes(key) ~ (u64(db) * WY_P1), key) == nil)
	}
	small: [1]u8
	huge := (cast([^]u8)&small[0])[:int(max(u32)) + 1]
	testing.expect(t, keyspace_record(nil, huge) == nil && keyspace_records == 1)
	keyspace_index_prefetch([]u64{hash, hash ~ WY_P1, hash ~ 1})
	keyspace_fence()
	keyspace_fence_test_settled(t)
	testing.expect_value(t, ks.memory_used(&keyspace_pool), 0)
	testing.expect(t, ks.resume(&keyspace_pool))
}

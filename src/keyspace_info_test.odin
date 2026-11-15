package main

import "core:strings"
import "core:testing"

@(test)
the_keyspace_worker_counters_read_zero_below_the_top_and_show_to_the_top :: proc(t: ^testing.T) {
	kept_labels, kept_top := labels_on, access.top
	kept_threads, kept_pending, kept_records := keyspace_threads, keyspace_pending, keyspace_records
	kept_submitted, kept_completed, kept_gets, kept_sets := keyspace_submitted, keyspace_completed, keyspace_gets, keyspace_sets
	kept_fallbacks, kept_inline, kept_barriers, kept_ns := keyspace_fallbacks, keyspace_inline, keyspace_barriers, keyspace_worker_ns
	defer {
		labels_on, access.top = kept_labels, kept_top
		keyspace_threads, keyspace_pending, keyspace_records = kept_threads, kept_pending, kept_records
		keyspace_submitted, keyspace_completed, keyspace_gets, keyspace_sets = kept_submitted, kept_completed, kept_gets, kept_sets
		keyspace_fallbacks, keyspace_inline, keyspace_barriers, keyspace_worker_ns = kept_fallbacks, kept_inline, kept_barriers, kept_ns
	}
	keyspace_threads, keyspace_pending, keyspace_records = 4, 3, 5
	keyspace_submitted, keyspace_completed, keyspace_gets, keyspace_sets = 41, 38, 17, 19
	keyspace_fallbacks, keyspace_inline, keyspace_barriers, keyspace_worker_ns = 6, 9, 2, 777
	shown := [?]string{"keyspace_jobs_pending:3\r\n", "keyspace_records:5\r\n", "keyspace_jobs_submitted:41\r\n", "keyspace_jobs_completed:38\r\n", "keyspace_gets:17\r\n", "keyspace_sets:19\r\n", "keyspace_sync_fallbacks:6\r\n", "keyspace_inline:9\r\n", "keyspace_barriers:2\r\n", "keyspace_worker_nanoseconds:777\r\n"}
	hidden := [?]string{"keyspace_jobs_pending:0\r\n", "keyspace_memory_used:0\r\n", "keyspace_records:0\r\n", "keyspace_jobs_submitted:0\r\n", "keyspace_jobs_completed:0\r\n", "keyspace_gets:0\r\n", "keyspace_sets:0\r\n", "keyspace_sync_fallbacks:0\r\n", "keyspace_inline:0\r\n", "keyspace_barriers:0\r\n", "keyspace_worker_signals:0\r\n", "keyspace_worker_nanoseconds:0\r\n"}
	b := make([dynamic]u8, context.temp_allocator)
	labels_on, access.top = true, false
	keyspace_info(&b)
	text := string(b[:])
	testing.expect(t, strings.contains(text, "keyspace_threads_configured:4\r\n"), "a caller below the top reads the configured worker count")
	testing.expect(t, strings.contains(text, "keyspace_threads_active:4\r\n"), "a caller below the top reads the configured count for the active one")
	for line in hidden {
		testing.expectf(t, strings.contains(text, line), "a caller below the top should read %s", line)
	}
	clear(&b)
	labels_on, access.top = true, true
	keyspace_info(&b)
	for line in shown {
		testing.expectf(t, strings.contains(string(b[:]), line), "the top should read %s", line)
	}
	clear(&b)
	labels_on, access.top = false, false
	keyspace_info(&b)
	for line in shown {
		testing.expectf(t, strings.contains(string(b[:]), line), "a server without labels should read %s", line)
	}
}

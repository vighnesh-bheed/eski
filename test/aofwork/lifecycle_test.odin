package aofwork

import "base:runtime"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import j "../../src"

saved_cwd: [4096]u8

saved_cwd_len: int

enter_dir :: proc(dir: string) {
	n, _ := linux.getcwd(saved_cwd[:])
	saved_cwd_len = n
	for saved_cwd_len > 0 && saved_cwd[saved_cwd_len - 1] == 0 {
		saved_cwd_len -= 1
	}
	linux.chdir(cstr(dir))
	j.aof.dirname = "appendonlydir"
	j.aof_manifest_set({})
	j.aof.current_size = 0
	j.aof.base_size = 0
	j.aof.fsynced_size = 0
}

leave_dir :: proc() {
	if j.aof.state != .Disabled {
		j.aof_stop()
	}
	for j.aof_rewriting() {
		j.aof_kill_child()
	}
	j.aof.started = false
	j.aof.wanted = false
	j.aof.state = .Disabled
	j.aof.rewrite_scheduled = false
	j.aof.disable_auto_gc = false
	j.aof.preamble = true
	j.aof.auto_pct = 100
	j.aof.auto_min = 64 * 1024 * 1024
	j.aof_update_feed()
	j.aof_manifest_set({})
	linux.chdir(cstr(string(saved_cwd[:saved_cwd_len])))
}

wait_rewrite :: proc() -> bool {
	for _ in 0 ..< 2000 {
		j.persist_check_child()
		if !j.aof_rewriting() {
			return true
		}
		sleep_ms(5)
	}
	return false
}

wait_gone :: proc(path: string) -> bool {
	for _ in 0 ..< 400 {
		if !file_exists(path) {
			return true
		}
		sleep_ms(5)
	}
	return false
}

manifest_now :: proc() -> string {
	data, ok := read_file("appendonlydir/appendonly.aof.manifest")
	if !ok {
		return ""
	}
	return string(data)
}

@(test)
lifecycle_enable_rewrite_disable :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	dir := fresh_dir("lifecycle")
	enter_dir(dir)
	defer leave_dir()
	j.aof.started = true
	j.aof.state = .Disabled
	before := j.aof.stat_rewrites
	c := new_client(0)
	run(c, "SET", "k1", "v1")
	testing.expect_value(t, run(c, "BGREWRITEAOF"), "+Background append only file rewriting started\r\n")
	testing.expect(t, j.aof_start())
	testing.expect_value(t, j.aof.state, j.Aof_Status.Awaiting_Base)
	testing.expect(t, j.aof.feed)
	run(c, "SET", "during", "1")
	testing.expect(t, wait_rewrite())
	testing.expect_value(t, j.aof.state, j.Aof_Status.Enabled)
	testing.expect_value(t, j.aof.stat_rewrites - before, 2)
	testing.expect_value(t, manifest_now(), "file appendonly.aof.1.base.rdb seq 1 type b\nfile appendonly.aof.1.incr.aof seq 1 type i\n")
	j.aof_flush(true)
	incr, _ := read_file("appendonlydir/appendonly.aof.1.incr.aof")
	recs, _ := decode_records(incr)
	testing.expect_value(t, len(recs), 2)
	if len(recs) == 2 {
		testing.expect_value(t, joined(recs[1]), "SET during 1")
	}
	testing.expect_value(t, file_exists("appendonlydir/temp-appendonly.aof.incr"), false)

	testing.expect_value(t, run(c, "BGREWRITEAOF"), "+Background append only file rewriting started\r\n")
	testing.expect_value(t, run(c, "BGREWRITEAOF"), "-ERR Background append only file rewriting already in progress\r\n")
	testing.expect_value(t, run(c, "BGSAVE"), "-ERR Another child process is active (AOF?): can't BGSAVE right now. Use BGSAVE SCHEDULE in order to schedule a BGSAVE whenever possible.\r\n")
	b: [dynamic]u8
	defer delete(b)
	j.aof_info(&b)
	testing.expect(t, strings.contains(string(b[:]), "aof_rewrite_in_progress:1\r\n"))
	run(c, "SET", "k2", "v2")
	testing.expect(t, wait_rewrite())
	testing.expect_value(t, manifest_now(), "file appendonly.aof.2.base.rdb seq 2 type b\nfile appendonly.aof.2.incr.aof seq 2 type i\n")
	testing.expect(t, wait_gone("appendonlydir/appendonly.aof.1.base.rdb"))
	testing.expect(t, wait_gone("appendonlydir/appendonly.aof.1.incr.aof"))
	j.aof_flush(true)
	incr, _ = read_file("appendonlydir/appendonly.aof.2.incr.aof")
	recs, _ = decode_records(incr)
	testing.expect(t, len(recs) == 2 && joined(recs[1]) == "SET k2 v2")

	j.aof.preamble = false
	testing.expect_value(t, run(c, "BGREWRITEAOF"), "+Background append only file rewriting started\r\n")
	testing.expect(t, wait_rewrite())
	testing.expect_value(t, manifest_now(), "file appendonly.aof.3.base.aof seq 3 type b\nfile appendonly.aof.3.incr.aof seq 3 type i\n")
	base, _ := read_file("appendonlydir/appendonly.aof.3.base.aof")
	recs, _ = decode_records(base)
	testing.expect_value(t, len(recs), 4)
	testing.expect(t, len(recs) > 0 && joined(recs[0]) == "SELECT 0")
	run(c, "SET", "after", "1")
	j.aof_flush(true)
	testing.expect_value(t, j.aof.current_size, file_size("appendonlydir/appendonly.aof.3.base.aof") + file_size("appendonlydir/appendonly.aof.3.incr.aof"))

	digest_before := dataset_digest()
	pending := c.wlen
	j.aof_debug_loadaof(c)
	testing.expect_value(t, reply_of(c, pending), "+OK\r\n")
	c.wlen = 0
	testing.expect(t, digest_before == dataset_digest())
	testing.expect_value(t, db_size(0), 4)

	j.aof_stop()
	testing.expect_value(t, j.aof.state, j.Aof_Status.Disabled)
	testing.expect(t, !j.aof.feed)
	testing.expect_value(t, run(c, "BGREWRITEAOF"), "+Background append only file rewriting started\r\n")
	testing.expect(t, wait_rewrite())
	testing.expect_value(t, manifest_now(), "file appendonly.aof.4.base.aof seq 4 type b\n")
	testing.expect(t, wait_gone("appendonlydir/appendonly.aof.3.incr.aof"))
	testing.expect(t, j.aof_start())
	testing.expect(t, wait_rewrite())
	testing.expect_value(t, manifest_now(), "file appendonly.aof.5.base.aof seq 5 type b\nfile appendonly.aof.4.incr.aof seq 4 type i\n")
	clear(&b)
	j.aof_info(&b)
	testing.expect(t, strings.contains(string(b[:]), "aof_enabled:1\r\n"))
	testing.expect(t, strings.contains(string(b[:]), "aof_last_bgrewrite_status:ok\r\n"))
	base_size := file_size("appendonlydir/appendonly.aof.5.base.aof")
	testing.expect(t, strings.contains(string(b[:]), strings.concatenate({"aof_base_size:", int_text(base_size), "\r\n"}, context.temp_allocator)))

	j.aof.auto_min = 100
	j.aof.auto_pct = 100
	big := strings.repeat("x", 4096, context.temp_allocator)
	run(c, "SET", "big", big)
	j.aof_flush(true)
	j.aof_cron()
	testing.expect(t, j.aof_rewriting())
	testing.expect(t, wait_rewrite())
	testing.expect_value(t, manifest_now(), "file appendonly.aof.6.base.aof seq 6 type b\nfile appendonly.aof.5.incr.aof seq 5 type i\n")
	testing.expect(t, strings.contains(log_text(), "Starting automatic rewriting of AOF on "))
	testing.expect(t, strings.contains(log_text(), "Background append only file rewriting started by pid "))
	testing.expect(t, strings.contains(log_text(), "Background AOF rewrite finished successfully"))
}

@(test)
lifecycle_startup_paths :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	dir := fresh_dir("startup-fresh")
	enter_dir(dir)
	defer leave_dir()
	j.aof.wanted = true
	j.aof.started = false
	testing.expect(t, j.aof_startup())
	testing.expect_value(t, j.aof.state, j.Aof_Status.Enabled)
	testing.expect(t, j.aof.feed)
	testing.expect_value(t, manifest_now(), "file appendonly.aof.1.base.rdb seq 1 type b\nfile appendonly.aof.1.incr.aof seq 1 type i\n")
	testing.expect(t, strings.contains(log_text(), "Creating AOF base file appendonly.aof.1.base.rdb on server start"))
	testing.expect(t, strings.contains(log_text(), "Creating AOF incr file appendonly.aof.1.incr.aof on server start"))
	c := new_client(0)
	run(c, "SET", "persisted", "yes")
	run(c, "INCR", "counter")
	j.aof_shutdown()
	j.aof_stop()
	flush_all()
	j.aof.started = false
	j.aof.wanted = true
	testing.expect(t, j.aof_startup())
	testing.expect_value(t, run(c, "GET", "persisted"), "$3\r\nyes\r\n")
	testing.expect_value(t, run(c, "GET", "counter"), "$1\r\n1\r\n")
	testing.expect(t, strings.contains(log_text(), "Opening AOF incr file appendonly.aof.1.incr.aof on server start"))
	testing.expect(t, strings.contains(log_text(), "DB loaded from append only file: "))
	testing.expect_value(t, manifest_now(), "file appendonly.aof.1.base.rdb seq 1 type b\nfile appendonly.aof.1.incr.aof seq 1 type i\n")
}

@(test)
lifecycle_feed_reaches_file_with_fsync_policies :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	dir := fresh_dir("fsync-policies")
	enter_dir(dir)
	defer leave_dir()
	defer j.aof.fsync = .Everysec
	j.aof.wanted = true
	j.aof.started = false
	testing.expect(t, j.aof_startup())
	c := new_client(0)
	j.aof.fsync = .Always
	run(c, "SET", "a", "1")
	j.aof_flush_for_reply()
	testing.expect_value(t, len(j.aof.buf), 0)
	testing.expect_value(t, j.aof.fsynced_size, j.aof.current_size)
	j.aof.fsync = .Everysec
	run(c, "SET", "b", "2")
	j.aof.last_fsync_ms = 0
	j.aof_before_sleep()
	testing.expect_value(t, len(j.aof.buf), 0)
	for _ in 0 ..< 200 {
		if j.aof_bio_pending() == 0 {
			break
		}
		sleep_ms(5)
	}
	j.aof_cron()
	testing.expect_value(t, j.aof.fsynced_size, j.aof.current_size)
	j.aof.fsync = .No
	run(c, "SET", "c", "3")
	j.aof_before_sleep()
	j.aof_fsync_sync()
	testing.expect_value(t, j.aof.fsynced_size, j.aof.current_size)
	incr, _ := read_file("appendonlydir/appendonly.aof.1.incr.aof")
	recs, _ := decode_records(incr)
	testing.expect_value(t, len(recs), 4)
	j.aof.timestamps = true
	run(c, "SET", "d", "4")
	j.aof_flush(true)
	j.aof.timestamps = false
	incr, _ = read_file("appendonlydir/appendonly.aof.1.incr.aof")
	testing.expect(t, strings.contains(string(incr), "#TS:"))
	recs, _ = decode_records(incr)
	testing.expect_value(t, len(recs), 5)
}

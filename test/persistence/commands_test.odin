package persistence

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import j "../../src"
import ht "../../src/hashtype"
import "../../src/rdb"
import sm "../../src/streamtype"

wait_child :: proc() -> bool {
	for _ in 0 ..< 500 {
		if j.pst.child_pid == 0 {
			return true
		}
		ts := linux.Time_Spec {
			time_nsec = 10_000_000,
		}
		linux.nanosleep(&ts, nil)
		j.persist_cron()
	}
	return j.pst.child_pid == 0
}

info_persistence :: proc() -> []string {
	b: [dynamic]u8
	defer delete(b)
	context.allocator = runtime.heap_allocator()
	j.persist_info(&b)
	lines := strings.split(strings.clone(string(b[:]), context.temp_allocator), "\r\n", context.temp_allocator)
	return lines
}

info_field :: proc(name: string) -> string {
	for line in info_persistence() {
		if strings.has_prefix(line, name) && len(line) > len(name) && line[len(name)] == ':' {
			return line[len(name) + 1:]
		}
	}
	return "<missing>"
}

populate_all_types :: proc() {
	cmd("SET", "k1", "v")
	cmd("SET", "num", "12345")
	cmd("SET", "long", strings.repeat("abc", 100, context.temp_allocator))
	cmd("RPUSH", "l", "a", "b")
	cmd("SET", "e", "v", "EX", "1000")
	cmd("SADD", "si", "1", "2")
	cmd("SADD", "ss", "a", "b")
	cmd("ZADD", "z", "1", "a", "2.5", "b")
	cmd("HSET", "h", "f", "v", "g", "w")
	cmd("HPEXPIRE", "h", "100000", "FIELDS", "1", "f")
	cmd("XADD", "x", "1-1", "f", "v")
	cmd("XGROUP", "CREATE", "x", "g", "0")
	cmd("SELECT", "2")
	cmd("SET", "d", "hello")
	cmd("SELECT", "0")
}

@(test)
transcript_replies :: proc(t: ^testing.T) {
	server_reset()
	dir := test_dir()
	defer cleanup_dir(dir)
	enter_dir(dir)
	defer leave_dir()
	j.pst.lastsave = 1793094617
	expect_reply(t, cmd("LASTSAVE"), integer(1793094617), "lastsave")
	expect_reply(t, cmd("SAVE", "x"), "-ERR wrong number of arguments for 'save' command\r\n", "save arity")
	expect_reply(t, cmd("BGSAVE", "x"), "-ERR syntax error\r\n", "bgsave syntax")
	expect_reply(t, cmd("BGSAVE", "SCHEDULE", "x"), "-ERR syntax error\r\n", "bgsave syntax")
	expect_reply(t, cmd("LASTSAVE", "x"), "-ERR wrong number of arguments for 'lastsave' command\r\n", "lastsave arity")
	expect_reply(t, cmd("SHUTDOWN", "BOGUS"), "-ERR syntax error\r\n", "shutdown bogus")
	expect_reply(t, cmd("SHUTDOWN", "ABORT"), "-ERR No shutdown in progress.\r\n", "shutdown abort")
	expect_reply(t, cmd("SHUTDOWN", "NOSAVE", "SAVE"), "-ERR syntax error\r\n", "shutdown nosave save")
	expect_reply(t, cmd("SHUTDOWN", "ABORT", "NOW"), "-ERR syntax error\r\n", "shutdown abort now")
	expect_reply(t, cmd("DEBUG", "RELOAD", "BOGUS"), "-ERR DEBUG RELOAD only supports the MERGE, NOFLUSH and NOSAVE options.\r\n", "reload options")
	expect_reply(t, cmd("DEBUG", "DIGEST"), "+0000000000000000000000000000000000000000\r\n", "empty digest")
	expect_reply(t, cmd("SET", "k1", "v"), "+OK\r\n", "set")
	expect_reply(t, cmd("RPUSH", "l", "a", "b"), integer(2), "rpush")
	expect_reply(t, cmd("SET", "e", "v", "EX", "1000"), "+OK\r\n", "set ex")
	expect_reply(t, cmd("SAVE"), "+OK\r\n", "save")
	testing.expect(t, j.pst.lastsave >= unix_ms() / 1000 - 2)
	expect_reply(t, cmd("LASTSAVE"), integer(j.pst.lastsave), "lastsave after save")
	testing.expect_value(t, j.pst.dirty, 0)
	digest := cmd("DEBUG", "DIGEST")
	expect_reply(t, cmd("DEBUG", "RELOAD"), "+OK\r\n", "reload")
	expect_reply(t, cmd("DEBUG", "DIGEST"), digest, "digest after reload")
	expect_reply(t, cmd("DBSIZE"), integer(3), "dbsize")
	ttl := cmd("TTL", "e")
	testing.expectf(t, ttl == ":1000\r\n" || ttl == ":999\r\n", "ttl %q", ttl)
	expect_reply(t, cmd("SET", "after", "1"), "+OK\r\n", "set after")
	expect_reply(t, cmd("DEBUG", "RELOAD", "NOSAVE"), "+OK\r\n", "reload nosave")
	expect_reply(t, cmd("EXISTS", "after"), integer(0), "after gone")
	expect_reply(t, cmd("SET", "after2", "1"), "+OK\r\n", "set after2")
	expect_reply(t, cmd("DEBUG", "RELOAD", "NOSAVE", "NOFLUSH", "MERGE"), "+OK\r\n", "reload merge")
	expect_reply(t, cmd("EXISTS", "after2"), integer(1), "after2 kept")
	expect_reply(t, cmd("DEBUG", "RELOAD", "noflush", "merge", "nosave"), "+OK\r\n", "reload lowercase")
	expect_reply(t, cmd("FLUSHALL"), "+OK\r\n", "flushall")
	expect_reply(t, cmd("DEBUG", "DIGEST"), "+0000000000000000000000000000000000000000\r\n", "digest empty")
	expect_reply(t, cmd("SET", "d", "hello"), "+OK\r\n", "set d")
	expect_reply(t, cmd("DEBUG", "DIGEST"), "+955a851f78324ba95d6dbdea9ad1fa7b2b6091ff\r\n", "reference digest")
	expect_reply(t, cmd("DEBUG", "DIGEST-VALUE", "d"), "*1\r\n+36b23a1456b2dce2c3ed252c456761301dba8060\r\n", "reference value digest")
	expect_reply(t, cmd("DEBUG", "DIGEST-VALUE", "d", "nokey"), "*2\r\n+36b23a1456b2dce2c3ed252c456761301dba8060\r\n+0000000000000000000000000000000000000000\r\n", "missing key digest")
	expect_reply(t, cmd("SET", "k1", "v"), "+OK\r\n", "set k1")
	expect_reply(t, cmd("DEBUG", "DIGEST-VALUE", "k1"), "*1\r\n+d79ee9fe5d5ad902d7f6620efc3b07b75ddd742f\r\n", "reference k1 digest")
	expect_reply(t, cmd("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "1"), "+OK\r\n", "skip checksum")
	testing.expect(t, j.pst.skip_checksum)
	expect_reply(t, cmd("DEBUG", "SET-SKIP-CHECKSUM-VALIDATION", "0"), "+OK\r\n", "skip checksum off")
	testing.expect(t, !j.pst.skip_checksum)
	linux.unlink("dump.rdb")
	expect_reply(t, cmd("DEBUG", "RELOAD", "NOSAVE"), "-ERR Error trying to load the RDB dump, check server logs.\r\n", "reload without file")
	saved_dbfilename := j.cfg.dbfilename
	j.cfg.dbfilename = "no-such-directory/dump.rdb"
	dirty := j.pst.dirty
	expect_reply(t, cmd("SAVE"), "-ERR\r\n", "failing save")
	expect_reply(t, cmd("DEBUG", "RELOAD"), "-ERR\r\n", "failing reload save")
	j.cfg.dbfilename = saved_dbfilename
	testing.expect_value(t, j.pst.dirty, dirty)
	testing.expect(t, !j.pst.lastbgsave_err)
	testing.expect(t, !file_exists(join_path(dir, "no-such-directory")))
	server_reset()
}

@(test)
info_persistence_layout :: proc(t: ^testing.T) {
	server_reset()
	want := []string {
		"loading", "async_loading", "current_cow_peak", "current_cow_size", "current_cow_size_age", "current_fork_perc",
		"current_save_keys_processed", "current_save_keys_total", "rdb_changes_since_last_save", "rdb_bgsave_in_progress",
		"rdb_last_save_time", "rdb_last_bgsave_status", "rdb_last_bgsave_time_sec", "rdb_current_bgsave_time_sec",
		"rdb_saves", "rdb_last_cow_size", "rdb_last_load_keys_expired", "rdb_last_load_keys_loaded", "aof_enabled",
		"aof_rewrite_in_progress", "aof_rewrite_scheduled", "aof_last_rewrite_time_sec", "aof_current_rewrite_time_sec",
		"aof_last_bgrewrite_status", "aof_rewrites", "aof_rewrites_consecutive_failures", "aof_last_write_status",
		"aof_last_cow_size", "module_fork_in_progress", "module_fork_last_cow_size",
	}
	lines := info_persistence()
	testing.expect_value(t, lines[0], "# Persistence")
	names: [dynamic]string
	names.allocator = context.temp_allocator
	for line in lines[1:] {
		if len(line) == 0 {
			continue
		}
		colon := strings.index_byte(line, ':')
		append(&names, line[:colon] if colon >= 0 else line)
	}
	testing.expect_value(t, len(names), len(want))
	for name, i in want {
		if i < len(names) {
			testing.expectf(t, names[i] == name, "field %d is %s want %s", i, names[i], name)
		}
	}
	testing.expect_value(t, info_field("current_fork_perc"), "0.00")
	testing.expect_value(t, info_field("rdb_last_bgsave_status"), "ok")
	testing.expect_value(t, info_field("rdb_current_bgsave_time_sec"), "-1")
	whole := cmd("INFO", "persistence")
	testing.expect(t, strings.contains(whole, "# Persistence\r\nloading:0\r\nasync_loading:0\r\n"))
	j.pst.loading = true
	j.pst.loading_total = 1000
	j.pst.loading_loaded = 250
	j.pst.loading_start = unix_ms() / 1000
	loading := info_persistence()
	testing.expect_value(t, loading[1], "loading:1")
	testing.expect_value(t, info_field("loading_total_bytes"), "1000")
	testing.expect_value(t, info_field("loading_loaded_bytes"), "250")
	testing.expect_value(t, info_field("loading_loaded_perc"), "25.00")
	j.pst.loading = false
	server_reset()
}

@(test)
bgsave_lifecycle :: proc(t: ^testing.T) {
	server_reset()
	dir := test_dir()
	defer cleanup_dir(dir)
	enter_dir(dir)
	defer leave_dir()
	populate_all_types()
	saves := j.pst.stat_rdb_saves
	expect_reply(t, cmd("BGSAVE", "SCHEDULE"), "+Background saving started\r\n", "bgsave schedule idle")
	testing.expect(t, wait_child())
	testing.expect_value(t, info_field("rdb_last_bgsave_status"), "ok")
	testing.expect_value(t, info_field("rdb_bgsave_in_progress"), "0")
	testing.expect_value(t, j.pst.stat_rdb_saves, saves + 1)
	testing.expect_value(t, j.pst.dirty, 0)
	testing.expect(t, j.pst.save_time_last >= 0)
	data, ok := read_file(join_path(dir, "dump.rdb"))
	testing.expect(t, ok)
	w := walk_rdb(data)
	testing.expect(t, w.ok && w.stored == w.computed)
	testing.expect_value(t, len(w.keys), 11)
	walk_destroy(&w)
	delete(data)
	expect_reply(t, cmd("CONFIG", "SET", "rdb-key-save-delay", "200000"), "+OK\r\n", "key save delay")
	testing.expect_value(t, j.pst.key_save_delay, 200000)
	expect_reply(t, cmd("SET", "during", "1"), "+OK\r\n", "write before bgsave")
	expect_reply(t, cmd("BGSAVE"), "+Background saving started\r\n", "bgsave")
	expect_reply(t, cmd("BGSAVE"), "-ERR Background save already in progress\r\n", "bgsave twice")
	expect_reply(t, cmd("BGSAVE", "SCHEDULE"), "-ERR Background save already in progress\r\n", "schedule during")
	expect_reply(t, cmd("SAVE"), "-ERR Background save already in progress\r\n", "save during")
	ts := linux.Time_Spec {
		time_nsec = 300_000_000,
	}
	linux.nanosleep(&ts, nil)
	testing.expect_value(t, info_field("rdb_bgsave_in_progress"), "1")
	testing.expect_value(t, info_field("current_save_keys_total"), "12")
	processed := info_field("current_save_keys_processed")
	testing.expectf(t, processed != "0" && processed != "12", "processed %s", processed)
	current := info_field("rdb_current_bgsave_time_sec")
	testing.expectf(t, current == "0" || current == "1", "current bgsave time %s", current)
	expect_reply(t, cmd("SET", "while", "1"), "+OK\r\n", "write during bgsave")
	j.persist_kill_child()
	testing.expect_value(t, j.pst.child_pid, 0)
	testing.expect_value(t, info_field("rdb_last_bgsave_status"), "ok")
	testing.expect(t, j.pst.dirty >= 1)
	cmd("CONFIG", "SET", "rdb-key-save-delay", "0")
	j.pst.child_pid = 999999
	j.pst.child_aof = true
	expect_reply(t, cmd("BGSAVE"), "-ERR Another child process is active (AOF?): can't BGSAVE right now. Use BGSAVE SCHEDULE in order to schedule a BGSAVE whenever possible.\r\n", "aof child")
	expect_reply(t, cmd("BGSAVE", "SCHEDULE"), "+Background saving scheduled\r\n", "schedule behind aof")
	testing.expect(t, j.pst.bgsave_scheduled)
	expect_reply(t, cmd("SAVE"), "+OK\r\n", "save while aof child")
	j.pst.child_pid = 0
	j.pst.child_aof = false
	j.persist_cron()
	testing.expect(t, j.pst.child_pid != 0)
	testing.expect(t, !j.pst.bgsave_scheduled)
	testing.expect(t, wait_child())
	server_reset()
}

@(test)
write_gate_and_retry :: proc(t: ^testing.T) {
	server_reset()
	dir := test_dir()
	defer cleanup_dir(dir)
	enter_dir(dir)
	defer leave_dir()
	expect_reply(t, cmd("CONFIG", "SET", "save", "3600 1"), "+OK\r\n", "save params")
	testing.expect_value(t, len(j.pst.save_params), 1)
	cmd("SET", "k", "v")
	saved_dbfilename := j.cfg.dbfilename
	j.cfg.dbfilename = "no-such-directory/dump.rdb"
	expect_reply(t, cmd("BGSAVE"), "+Background saving started\r\n", "failing bgsave")
	testing.expect(t, wait_child())
	j.cfg.dbfilename = saved_dbfilename
	testing.expect_value(t, info_field("rdb_last_bgsave_status"), "err")
	testing.expect(t, j.pst.gate_active)
	misconf := strings.concatenate({"-", j.ERR_MISCONF, "\r\n"}, context.temp_allocator)
	expect_reply(t, cmd("SET", "blocked", "1"), misconf, "misconf")
	expect_reply(t, cmd("RPUSH", "blocked", "1"), misconf, "misconf rpush")
	expect_reply(t, cmd("GET", "k"), bulk("v"), "reads allowed")
	expect_reply(t, cmd("PING"), misconf, "misconf ping")
	expect_reply(t, cmd("PING", "hello"), misconf, "misconf ping with message")
	expect_reply(t, cmd("ECHO", "hi"), bulk("hi"), "echo allowed")
	expect_reply(t, cmd("CONFIG", "SET", "stop-writes-on-bgsave-error", "no"), "+OK\r\n", "stop writes off")
	expect_reply(t, cmd("SET", "blocked", "1"), "+OK\r\n", "writes allowed")
	expect_reply(t, cmd("PING"), "+PONG\r\n", "ping allowed without stop writes")
	expect_reply(t, cmd("CONFIG", "SET", "stop-writes-on-bgsave-error", "yes"), "+OK\r\n", "stop writes on")
	expect_reply(t, cmd("SET", "blocked", "2"), misconf, "misconf again")
	j.pst.lastsave = unix_ms() / 1000 - 7200
	j.pst.dirty = 5
	j.persist_cron()
	testing.expect_value(t, j.pst.child_pid, 0)
	j.pst.lastbgsave_try = unix_ms() / 1000 - 10
	j.persist_cron()
	testing.expect(t, j.pst.child_pid != 0)
	testing.expect(t, wait_child())
	testing.expect_value(t, info_field("rdb_last_bgsave_status"), "ok")
	expect_reply(t, cmd("SET", "blocked", "3"), "+OK\r\n", "writes after success")
	cmd("CONFIG", "SET", "save", "")
	j.pst.lastbgsave_err = true
	j.persist_update_gate()
	expect_reply(t, cmd("SET", "blocked", "4"), "+OK\r\n", "no params no misconf")
	j.pst.lastbgsave_err = false
	j.pst.loading = true
	j.persist_update_gate()
	expect_reply(t, cmd("SET", "x", "1"), "-LOADING Redis is loading the dataset in memory\r\n", "loading gate")
	expect_reply(t, cmd("GET", "x"), "-LOADING Redis is loading the dataset in memory\r\n", "loading gate read")
	testing.expect(t, strings.has_prefix(cmd("INFO", "persistence"), "$"))
	expect_reply(t, cmd("LASTSAVE"), integer(j.pst.lastsave), "lastsave while loading")
	j.pst.loading = false
	j.persist_update_gate()
	testing.expect(t, !j.pst.gate_active)
	flags := j.persist_cmd_flags(j.lookup_command(transmute([]u8)string("set")))
	testing.expect(t, .Write in flags && .Loading_Ok not_in flags)
	flags = j.persist_cmd_flags(j.lookup_command(transmute([]u8)string("info")))
	testing.expect(t, .Loading_Ok in flags && .Write not_in flags)
	testing.expect_value(t, j.persist_cmd_flags(nil), j.Persist_Cmd_Flags{})
	server_reset()
}

@(test)
dirty_counting :: proc(t: ^testing.T) {
	server_reset()
	expect_reply(t, cmd("FLUSHALL"), "+OK\r\n", "flush empty")
	testing.expect_value(t, j.pst.dirty, 0)
	cmd("SET", "a", "1")
	testing.expect_value(t, j.pst.dirty, 1)
	cmd("GET", "a")
	testing.expect_value(t, j.pst.dirty, 1)
	cmd("LPUSH", "a", "x")
	testing.expect_value(t, j.pst.dirty, 1)
	cmd("MSET", "b", "2", "c", "3")
	testing.expect_value(t, j.pst.dirty, 3)
	expect_reply(t, cmd("FLUSHALL"), "+OK\r\n", "flush three")
	testing.expect_value(t, j.pst.dirty, 6)
	cmd("SET", "a", "1")
	testing.expect_value(t, j.pst.dirty, 7)
	server_reset()
}

@(test)
save_parameter_grammar :: proc(t: ^testing.T) {
	server_reset()
	err := "-ERR CONFIG SET failed (possibly related to argument 'save') - Invalid save parameters\r\n"
	expect_reply(t, cmd("CONFIG", "GET", "save"), "*2\r\n$4\r\nsave\r\n$0\r\n\r\n", "default save")
	expect_reply(t, cmd("CONFIG", "SET", "save", "3600 1 300 100 60 10000"), "+OK\r\n", "three pairs")
	testing.expect_value(t, len(j.pst.save_params), 3)
	testing.expect_value(t, j.pst.save_params[2], j.Save_Param{seconds = 60, changes = 10000})
	expect_reply(t, cmd("CONFIG", "GET", "save"), "*2\r\n$4\r\nsave\r\n$23\r\n3600 1 300 100 60 10000\r\n", "get pairs")
	expect_reply(t, cmd("CONFIG", "SET", "save", ""), "+OK\r\n", "empty")
	testing.expect_value(t, len(j.pst.save_params), 0)
	for bad in ([]string{"10", "a b", "-1 5", "0 0", "10 x", "1 2 3"}) {
		expect_reply(t, cmd("CONFIG", "SET", "save", bad), err, bad)
		testing.expect_value(t, len(j.pst.save_params), 0)
	}
	expect_reply(t, cmd("CONFIG", "GET", "save"), "*2\r\n$4\r\nsave\r\n$0\r\n\r\n", "unchanged")
	expect_reply(t, cmd("CONFIG", "SET", "sanitize-dump-payload", "maybe"), "-ERR CONFIG SET failed (possibly related to argument 'sanitize-dump-payload') - argument(s) must be one of the following: no, yes, clients\r\n", "sanitize")
	expect_reply(t, cmd("CONFIG", "SET", "sanitize-dump-payload", "yes"), "+OK\r\n", "sanitize yes")
	testing.expect(t, j.persist_deep_sanitize(true) && j.persist_deep_sanitize(false))
	expect_reply(t, cmd("CONFIG", "SET", "sanitize-dump-payload", "clients"), "+OK\r\n", "sanitize clients")
	testing.expect(t, j.persist_deep_sanitize(true) && !j.persist_deep_sanitize(false))
	expect_reply(t, cmd("CONFIG", "SET", "sanitize-dump-payload", "no"), "+OK\r\n", "sanitize no")
	testing.expect(t, !j.persist_deep_sanitize(true))
	expect_reply(t, cmd("CONFIG", "SET", "rdbcompression", "no"), "+OK\r\n", "compression off")
	testing.expect(t, !j.pst.compression)
	expect_reply(t, cmd("CONFIG", "SET", "rdbcompression", "yes"), "+OK\r\n", "compression on")
	testing.expect(t, j.pst.compression)
	server_reset()
}

@(test)
cron_triggered_save :: proc(t: ^testing.T) {
	server_reset()
	dir := test_dir()
	defer cleanup_dir(dir)
	enter_dir(dir)
	defer leave_dir()
	cmd("CONFIG", "SET", "save", "100 3 1 1")
	j.pst.lastsave = unix_ms() / 1000
	cmd("SET", "a", "1")
	j.persist_cron()
	testing.expect_value(t, j.pst.child_pid, 0)
	j.pst.lastsave -= 5
	j.persist_cron()
	testing.expect(t, j.pst.child_pid != 0)
	testing.expect(t, wait_child())
	testing.expect_value(t, j.pst.dirty, 0)
	testing.expect(t, file_exists(join_path(dir, "dump.rdb")))
	cmd("SET", "b", "1")
	expect_reply(t, cmd("FLUSHALL"), "+OK\r\n", "flushall with save params")
	testing.expect_value(t, j.pst.dirty, 0)
	data, _ := read_file(join_path(dir, "dump.rdb"))
	w := walk_rdb(data)
	testing.expect(t, w.ok && len(w.keys) == 0 && len(w.dbs) == 0)
	walk_destroy(&w)
	delete(data)
	server_reset()
}

@(test)
save_file_framing :: proc(t: ^testing.T) {
	server_reset()
	dir := test_dir()
	defer cleanup_dir(dir)
	enter_dir(dir)
	defer leave_dir()
	populate_all_types()
	hset: [dynamic]string
	hset.allocator = context.temp_allocator
	append(&hset, "HSET", "bighash")
	for i in 0 ..< 600 {
		buf: [24]u8
		append(&hset, strings.concatenate({"f", itoa(buf[:], i64(i))}, context.temp_allocator), "value\x00suffix")
	}
	expect_reply(t, cmd(..hset[:]), integer(600), "bighash")
	modes := []struct {
		compress: bool,
		checksum: bool,
		policy:   j.Evict_Policy,
	}{{true, true, .Noeviction}, {false, true, .Allkeys_Lru}, {true, false, .Allkeys_Lfu}}
	for m in modes {
		j.pst.compression = m.compress
		j.pst.checksum = m.checksum
		j.maxmemory_policy = m.policy
		j.evict_policy_changed()
		expect_reply(t, cmd("SAVE"), "+OK\r\n", "save")
		data, ok := read_file(join_path(dir, "dump.rdb"))
		testing.expect(t, ok)
		w := walk_rdb(data)
		testing.expectf(t, w.ok, "walk %s", w.reason)
		testing.expect_value(t, w.version, 12)
		if m.checksum {
			testing.expect(t, w.stored == w.computed && w.stored != 0)
		} else {
			testing.expect_value(t, w.stored, 0)
		}
		names := []string{"redis-ver", "redis-bits", "ctime", "used-mem", "aof-base"}
		testing.expect_value(t, len(w.aux), len(names))
		for name, i in names {
			if i < len(w.aux) {
				testing.expect_value(t, w.aux[i].key, name)
			}
		}
		testing.expect_value(t, w.aux[0].val, "7.4.11")
		testing.expect_value(t, w.aux[4].val, "0")
		ctime, _ := rdb.string2ll(transmute([]u8)w.aux[2].val)
		testing.expect(t, abs(ctime - unix_ms() / 1000) <= 2)
		testing.expect_value(t, len(w.dbs), 2)
		testing.expect_value(t, w.dbs[0], Walk_Db{id = 0, size = 11, expires = 1})
		testing.expect_value(t, w.dbs[1], Walk_Db{id = 2, size = 1, expires = 0})
		for k in w.keys {
			db := &j.dbs[k.db]
			tb, i := j.persist_raw_locate(db, transmute([]u8)k.key)
			testing.expect(t, i >= 0)
			if i < 0 {
				continue
			}
			value: rdb.Writer
			rdb.writer_init_mem(&value, m.compress, false)
			j.persist_write_value(&value, transmute([]u8)k.key, j.persist_slot_value(db, &tb.slots[i].key, &tb.slots[i].val), true)
			testing.expectf(t, string(rdb.writer_bytes(&value)) == string(data[k.type_off:k.value_end]), "%s record differs", k.key)
			rdb.writer_destroy(&value)
			testing.expect_value(t, k.idle >= 0, m.policy == .Allkeys_Lru)
			testing.expect_value(t, k.freq >= 0, m.policy == .Allkeys_Lfu)
			if k.key == "e" {
				testing.expect(t, k.expire > unix_ms())
			} else {
				testing.expect_value(t, k.expire, -1)
			}
		}
		digest := cmd("DEBUG", "DIGEST")
		expect_reply(t, cmd("DEBUG", "RELOAD", "NOSAVE"), "+OK\r\n", "reload")
		expect_reply(t, cmd("DEBUG", "DIGEST"), digest, "digest after reload")
		expect_loaded_accounting(t)
		testing.expect(t, cmd("HPTTL", "h", "FIELDS", "1", "f") != "*1\r\n:-1\r\n")
		walk_destroy(&w)
		delete(data)
	}
	server_reset()
}

shutdown_args: []string

shutdown_child :: proc() {
	context.allocator = runtime.heap_allocator()
	reply := cmd(..shutdown_args)
	if reply == "-ERR Errors trying to SHUTDOWN. Check logs.\r\n" {
		linux.exit_group(5)
	}
	linux.exit_group(6)
}

signal_child :: proc() {
	context.allocator = runtime.heap_allocator()
	intrinsics.volatile_store(&j.persist_sig_last, i32(linux.Signal.SIGTERM))
	intrinsics.volatile_store(&j.persist_sig_pending, 1)
	j.persist_cron()
	linux.exit_group(6)
}

@(test)
shutdown_paths :: proc(t: ^testing.T) {
	server_reset()
	dir := test_dir()
	defer cleanup_dir(dir)
	enter_dir(dir)
	defer leave_dir()
	cmd("SET", "final", "v")
	path := join_path(dir, "dump.rdb")
	Case :: struct {
		args:   []string,
		params: string,
		bad:    bool,
		code:   int,
		file:   bool,
	}
	cases := []Case {
		{{"SHUTDOWN", "NOW", "FORCE", "NOSAVE"}, "", false, 0, false},
		{{"SHUTDOWN"}, "", false, 0, false},
		{{"SHUTDOWN", "NOSAVE"}, "3600 1", false, 0, false},
		{{"SHUTDOWN"}, "3600 1", false, 0, true},
		{{"SHUTDOWN", "SAVE"}, "", false, 0, true},
		{{"SHUTDOWN", "SAVE"}, "", true, 5, false},
		{{"SHUTDOWN", "SAVE", "FORCE"}, "", true, 0, false},
		{{"shutdown", "save", "now"}, "", false, 0, true},
	}
	saved_dbfilename := j.cfg.dbfilename
	for c in cases {
		linux.unlink(cstr(path))
		cmd("CONFIG", "SET", "save", c.params)
		if c.bad {
			j.cfg.dbfilename = "no-such-directory/dump.rdb"
		}
		shutdown_args = c.args
		exited, code := run_in_child(shutdown_child)
		j.cfg.dbfilename = saved_dbfilename
		testing.expectf(t, exited && code == c.code, "%v: exited %v code %d", c.args, exited, code)
		has := file_exists(path)
		testing.expectf(t, has == c.file, "%v: file %v", c.args, has)
	}
	cmd("CONFIG", "SET", "save", "3600 1")
	linux.unlink(cstr(path))
	exited, code := run_in_child(signal_child)
	testing.expect(t, exited && code == 0)
	testing.expect(t, file_exists(path))
	cmd("CONFIG", "SET", "save", "")
	server_reset()
}

@(test)
large_dataset_save_and_reload :: proc(t: ^testing.T) {
	server_reset()
	dir := test_dir()
	defer cleanup_dir(dir)
	enter_dir(dir)
	defer leave_dir()
	total := 0
	rehashing := 0
	for step in ([]int{3000, 9000, 25000, 70000}) {
		buf: [24]u8
		prefix := strings.concatenate({"p", itoa(buf[:], i64(step))}, context.temp_allocator)
		expect_reply(t, cmd("DEBUG", "POPULATE", itoa(buf[:], i64(step)), prefix, "8"), "+OK\r\n", "populate")
		total += step
		if j.dbs[0].rehash_idx >= 0 {
			rehashing += 1
		}
		expect_reply(t, cmd("SAVE"), "+OK\r\n", "save")
		data, ok := read_file(join_path(dir, "dump.rdb"))
		testing.expect(t, ok)
		w := walk_rdb(data)
		testing.expect(t, w.ok && w.stored == w.computed)
		testing.expect_value(t, len(w.keys), total)
		testing.expect_value(t, w.dbs[0].size, u64(total))
		walk_destroy(&w)
		delete(data)
	}
	digest := cmd("DEBUG", "DIGEST")
	expect_reply(t, cmd("DEBUG", "RELOAD"), "+OK\r\n", "reload")
	expect_reply(t, cmd("DBSIZE"), integer(i64(total)), "dbsize")
	expect_reply(t, cmd("DEBUG", "DIGEST"), digest, "digest")
	expect_reply(t, cmd("GET", "p70000:69999"), bulk("value:69"), "populated value")
	expect_reply(t, cmd("BGSAVE"), "+Background saving started\r\n", "bgsave")
	testing.expect(t, wait_child())
	testing.expect_value(t, info_field("rdb_last_bgsave_status"), "ok")
	data, _ := read_file(join_path(dir, "dump.rdb"))
	w := walk_rdb(data)
	testing.expect_value(t, len(w.keys), total)
	walk_destroy(&w)
	delete(data)
	log.infof("saves taken during an incremental rehash: %d", rehashing)
	server_reset()
}

expect_loaded_accounting :: proc(t: ^testing.T, loc := #caller_location) {
	db := &j.dbs[0]
	he := j.db_find_in(db, transmute([]u8)string("h"))
	if he != nil {
		h := cast(ht.Hash)j.entry_object(he, .Hash)
		testing.expectf(t, h.acct == ht.memory_usage(h) && h.acct > 0, "hash acct %d usage %d", h.acct, ht.memory_usage(h), loc = loc)
	}
	xe := j.db_find_in(db, transmute([]u8)string("x"))
	if xe != nil {
		x := cast(sm.Stream)j.entry_object(xe, .Stream)
		testing.expectf(t, x.acct == sm.memory_usage(x) && x.acct > 0, "stream acct %d usage %d", x.acct, sm.memory_usage(x), loc = loc)
	}
	big := j.db_find_in(db, transmute([]u8)string("bighash"))
	if big != nil {
		b := cast(ht.Hash)j.entry_object(big, .Hash)
		testing.expectf(t, ht.length(b) == 600 && b.acct == ht.memory_usage(b), "big hash %d fields acct %d usage %d", ht.length(b), b.acct, ht.memory_usage(b), loc = loc)
	}
}

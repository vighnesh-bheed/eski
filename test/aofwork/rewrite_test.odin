package aofwork

import "base:runtime"
import "core:strings"
import "core:testing"
import j "../../src"

build_fixed_dataset :: proc() {
	flush_all()
	c0 := new_client(0)
	run(c0, "SET", "s", "hello")
	run(c0, "PEXPIREAT", "s", "9999999999000")
	c1 := new_client(1)
	run(c1, "RPUSH", "l", "a", "b", "3")
	c2 := new_client(2)
	run(c2, "SADD", "st", "3", "1", "2")
	c3 := new_client(3)
	run(c3, "ZADD", "z", "1.5", "a", "-2", "b", "1e300", "c", "inf", "d")
	c4 := new_client(4)
	run(c4, "HSET", "h", "f1", "v1", "f2", "v2")
	c5 := new_client(5)
	run(c5, "HSET", "hx", "a", "1", "b", "2")
	run(c5, "HPEXPIREAT", "hx", "9999999999000", "FIELDS", "1", "a")
	c6 := new_client(6)
	run(c6, "XADD", "x", "1-1", "f", "v")
	run(c6, "XADD", "x", "2-1", "g", "w")
	run(c6, "XGROUP", "CREATE", "x", "grp", "0")
	run(c6, "XREADGROUP", "GROUP", "grp", "alice", "COUNT", "1", "STREAMS", "x", ">")
	run(c6, "XCLAIM", "x", "grp", "alice", "0", "1-1", "TIME", "1700000000000", "RETRYCOUNT", "4", "FORCE", "JUSTID")
	run(c6, "XGROUP", "CREATECONSUMER", "x", "grp", "bob")
	c7 := new_client(7)
	run(c7, "XADD", "e", "MAXLEN", "0", "5-5", "a", "b")
	c8 := new_client(8)
	items := make([dynamic]string, context.temp_allocator)
	append(&items, "RPUSH", "big")
	for i in 0 ..< 70 {
		append(&items, int_text(i64(i)))
	}
	run(c8, ..items[:])
}

RESP_BASE_EXPECTED :: []string {
	"SELECT 0",
	"SET s hello",
	"PEXPIREAT s 9999999999000",
	"SELECT 1",
	"RPUSH l a b 3",
	"SELECT 2",
	"SADD st 1 2 3",
	"SELECT 3",
	"ZADD z -2 b 1.5 a 1e+300 c inf d",
	"SELECT 4",
	"HMSET h f1 v1 f2 v2",
	"SELECT 5",
	"HMSET hx a 1",
	"HPEXPIREAT hx 9999999999000 FIELDS 1 a",
	"HMSET hx b 2",
	"SELECT 6",
	"XADD x 1-1 f v",
	"XADD x 2-1 g w",
	"XSETID x 2-1 ENTRIESADDED 2 MAXDELETEDID 0-0",
	"XGROUP CREATE x grp 1-1 ENTRIESREAD 1",
	"XCLAIM x grp alice 0 1-1 TIME 1700000000000 RETRYCOUNT 4 JUSTID FORCE",
	"XGROUP CREATECONSUMER x grp bob",
	"SELECT 7",
	"XADD e MAXLEN 0 5-5 x y",
	"XSETID e 5-5 ENTRIESADDED 1 MAXDELETEDID <id>",
	"SELECT 8",
}

dataset_digest :: proc() -> [20]u8 {
	d: [20]u8
	j.persist_dataset_digest(&d)
	return d
}

@(test)
rewrite_command_base_for_fixed_dataset :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	defer reset_dir()
	build_fixed_dataset()
	before := dataset_digest()
	dir := fresh_dir("rewrite-resp")
	path := path_join({dir, "appendonly.aof.1.base.aof"})
	testing.expect(t, j.aof_write_base_to(cstr(path), false))
	data, ok := read_file(path)
	testing.expect(t, ok)
	recs, good := decode_records(data)
	testing.expect(t, good)
	want := RESP_BASE_EXPECTED
	testing.expectf(t, len(recs) == len(want) + 2, "records %d", len(recs))
	for w, i in want {
		if i >= len(recs) {
			break
		}
		testing.expectf(t, record_matches(w, recs[i]), "record %d want %q got %q", i, w, joined(recs[i]))
	}
	if len(recs) == len(want) + 2 {
		first := recs[len(want)]
		second := recs[len(want) + 1]
		testing.expect_value(t, len(first), 66)
		testing.expect_value(t, len(second), 8)
		testing.expect_value(t, first[0], "RPUSH")
		testing.expect_value(t, first[2], "0")
		testing.expect_value(t, first[65], "63")
		testing.expect_value(t, second[2], "64")
		testing.expect_value(t, second[7], "69")
	}
	write_file(path_join({dir, "appendonly.aof.manifest"}), transmute([]u8)string("file appendonly.aof.1.base.aof seq 1 type b\n"))
	testing.expect_value(t, load_manifest_dir(dir), j.Aof_Load_Result.Ok)
	after := dataset_digest()
	testing.expect(t, before == after, "digest after reload differs")
	c6 := new_client(6)
	p := run(c6, "XPENDING", "x", "grp", "-", "+", "10")
	testing.expect(t, strings.contains(p, "alice") && strings.contains(p, ":4\r\n"), p)
	ci := run(c6, "XINFO", "CONSUMERS", "x", "grp")
	testing.expect(t, strings.contains(ci, "bob"), ci)
}

@(test)
rewrite_rdb_base_for_fixed_dataset :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	defer reset_dir()
	build_fixed_dataset()
	before := dataset_digest()
	dir := fresh_dir("rewrite-rdb")
	path := path_join({dir, "appendonly.aof.1.base.rdb"})
	testing.expect(t, j.aof_write_base_to(cstr(path), true))
	data, ok := read_file(path)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(string(data), "REDIS0012"))
	testing.expect(t, strings.contains(string(data), "\xfa\x08aof-base\xc0\x01"))
	testing.expect(t, strings.contains(string(data), "\xfa\x09redis-ver\x067.4.11"))
	write_file(path_join({dir, "appendonly.aof.manifest"}), transmute([]u8)string("file appendonly.aof.1.base.rdb seq 1 type b\nfile appendonly.aof.1.incr.aof seq 1 type i\n"))
	write_file(path_join({dir, "appendonly.aof.1.incr.aof"}), transmute([]u8)string("*2\r\n$6\r\nSELECT\r\n$1\r\n9\r\n*3\r\n$3\r\nSET\r\n$4\r\ntail\r\n$1\r\nt\r\n"))
	testing.expect_value(t, load_manifest_dir(dir), j.Aof_Load_Result.Ok)
	c9 := new_client(9)
	testing.expect_value(t, run(c9, "GET", "tail"), "$1\r\nt\r\n")
	run(c9, "DEL", "tail")
	after := dataset_digest()
	testing.expect(t, before == after, "digest after reload differs")
	testing.expect(t, strings.contains(log_text(), "RDB is base AOF"))
	testing.expect(t, strings.contains(log_text(), "DB loaded from base file appendonly.aof.1.base.rdb: "))
	testing.expect(t, strings.contains(log_text(), "DB loaded from incr file appendonly.aof.1.incr.aof: "))
}

@(test)
rewrite_empty_dataset :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	dir := fresh_dir("rewrite-empty")
	resp := path_join({dir, "empty.aof"})
	testing.expect(t, j.aof_write_base_to(cstr(resp), false))
	testing.expect_value(t, file_size(resp), 0)
	rdbp := path_join({dir, "empty.rdb"})
	testing.expect(t, j.aof_write_base_to(cstr(rdbp), true))
	data, _ := read_file(rdbp)
	testing.expect(t, strings.has_prefix(string(data), "REDIS0012"))
	testing.expect_value(t, data[len(data) - 9], 0xff)
}

@(test)
config_grammar_matches_reference :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	c := new_client(0)
	Pair :: struct {
		name:  string,
		value: string,
	}
	defaults := []Pair {
		{"appendonly", "no"},
		{"appendfilename", "appendonly.aof"},
		{"appenddirname", "appendonlydir"},
		{"appendfsync", "everysec"},
		{"aof-use-rdb-preamble", "yes"},
		{"aof-load-truncated", "yes"},
		{"aof-timestamp-enabled", "no"},
		{"aof-rewrite-incremental-fsync", "yes"},
		{"auto-aof-rewrite-percentage", "100"},
		{"auto-aof-rewrite-min-size", "67108864"},
		{"no-appendfsync-on-rewrite", "no"},
		{"aof-disable-auto-gc", "no"},
	}
	for p in defaults {
		want := strings.concatenate({"*2\r\n$", int_text(i64(len(p.name))), "\r\n", p.name, "\r\n$", int_text(i64(len(p.value))), "\r\n", p.value, "\r\n"}, context.temp_allocator)
		testing.expect_value(t, run(c, "CONFIG", "GET", p.name), want)
	}
	testing.expect_value(t, run(c, "CONFIG", "SET", "appendfsync", "sometimes"), "-ERR CONFIG SET failed (possibly related to argument 'appendfsync') - argument(s) must be one of the following: everysec, always, no\r\n")
	testing.expect_value(t, run(c, "CONFIG", "SET", "auto-aof-rewrite-percentage", "-1"), "-ERR CONFIG SET failed (possibly related to argument 'auto-aof-rewrite-percentage') - argument must be between 0 and 2147483647 inclusive\r\n")
	testing.expect_value(t, run(c, "CONFIG", "SET", "auto-aof-rewrite-min-size", "1kb"), "+OK\r\n")
	testing.expect_value(t, run(c, "CONFIG", "GET", "auto-aof-rewrite-min-size"), "*2\r\n$25\r\nauto-aof-rewrite-min-size\r\n$4\r\n1024\r\n")
	testing.expect_value(t, j.aof.auto_min, 1024)
	testing.expect_value(t, run(c, "CONFIG", "SET", "auto-aof-rewrite-percentage", "0"), "+OK\r\n")
	testing.expect_value(t, j.aof.auto_pct, 0)
	testing.expect_value(t, run(c, "CONFIG", "SET", "appendfsync", "always"), "+OK\r\n")
	testing.expect_value(t, j.aof.fsync, j.Aof_Fsync.Always)
	testing.expect_value(t, run(c, "CONFIG", "SET", "appendfsync", "no"), "+OK\r\n")
	testing.expect_value(t, j.aof.fsync, j.Aof_Fsync.No)
	testing.expect_value(t, run(c, "CONFIG", "SET", "aof-use-rdb-preamble", "no"), "+OK\r\n")
	testing.expect_value(t, j.aof.preamble, false)
	testing.expect_value(t, run(c, "CONFIG", "SET", "aof-load-truncated", "no"), "+OK\r\n")
	testing.expect_value(t, j.aof.load_truncated, false)
	testing.expect_value(t, run(c, "CONFIG", "SET", "aof-timestamp-enabled", "yes"), "+OK\r\n")
	testing.expect_value(t, j.aof.timestamps, true)
	testing.expect_value(t, run(c, "CONFIG", "SET", "no-appendfsync-on-rewrite", "yes"), "+OK\r\n")
	testing.expect_value(t, j.aof.no_fsync_on_rewrite, true)
	testing.expect_value(t, run(c, "CONFIG", "SET", "aof-disable-auto-gc", "yes"), "+OK\r\n")
	testing.expect_value(t, j.aof.disable_auto_gc, true)
	testing.expect_value(t, run(c, "CONFIG", "SET", "aof-rewrite-incremental-fsync", "no"), "+OK\r\n")
	testing.expect_value(t, j.aof.incremental_fsync, false)
	run(c, "CONFIG", "SET", "auto-aof-rewrite-min-size", "64mb")
	run(c, "CONFIG", "SET", "auto-aof-rewrite-percentage", "100")
	run(c, "CONFIG", "SET", "appendfsync", "everysec")
	run(c, "CONFIG", "SET", "aof-use-rdb-preamble", "yes")
	run(c, "CONFIG", "SET", "aof-load-truncated", "yes")
	run(c, "CONFIG", "SET", "aof-timestamp-enabled", "no")
	run(c, "CONFIG", "SET", "no-appendfsync-on-rewrite", "no")
	run(c, "CONFIG", "SET", "aof-disable-auto-gc", "no")
	run(c, "CONFIG", "SET", "aof-rewrite-incremental-fsync", "yes")
	testing.expect_value(t, j.aof.auto_min, 64 * 1024 * 1024)
	testing.expect_value(t, j.aof.fsync, j.Aof_Fsync.Everysec)
}

@(test)
info_fields_in_reference_order :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	b: [dynamic]u8
	defer delete(b)
	saved := j.aof.state
	defer j.aof.state = saved
	j.aof.state = .Off
	j.aof_info(&b)
	lines := strings.split_lines(strings.trim_space(string(b[:])), context.temp_allocator)
	off := []string{"aof_enabled", "aof_rewrite_in_progress", "aof_rewrite_scheduled", "aof_last_rewrite_time_sec", "aof_current_rewrite_time_sec", "aof_last_bgrewrite_status", "aof_rewrites", "aof_rewrites_consecutive_failures", "aof_last_write_status", "aof_last_cow_size", "module_fork_in_progress", "module_fork_last_cow_size"}
	testing.expect_value(t, len(lines), len(off))
	for name, i in off {
		if i < len(lines) {
			testing.expectf(t, strings.has_prefix(lines[i], strings.concatenate({name, ":"}, context.temp_allocator)), "line %d %q", i, lines[i])
		}
	}
	testing.expect(t, strings.contains(string(b[:]), "aof_enabled:0\r\n"))
	testing.expect(t, strings.contains(string(b[:]), "aof_current_rewrite_time_sec:-1\r\n"))
	testing.expect(t, strings.contains(string(b[:]), "aof_last_bgrewrite_status:ok\r\n"))
	clear(&b)
	j.aof.state = .On
	j.aof_info(&b)
	lines = strings.split_lines(strings.trim_space(string(b[:])), context.temp_allocator)
	on := []string{"aof_current_size", "aof_base_size", "aof_pending_rewrite", "aof_buffer_length", "aof_pending_bio_fsync", "aof_delayed_fsync"}
	testing.expect_value(t, len(lines), len(off) + len(on))
	for name, i in on {
		k := len(off) + i
		if k < len(lines) {
			testing.expectf(t, strings.has_prefix(lines[k], strings.concatenate({name, ":"}, context.temp_allocator)), "line %d %q", k, lines[k])
		}
	}
}

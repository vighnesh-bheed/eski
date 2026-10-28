package aofwork

import "base:runtime"
import "core:strings"
import "core:testing"
import j "../../src"

exec_line :: proc(c: ^j.Conn, args: ..string) -> string {
	argv := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		argv[i] = transmute([]u8)strings.clone(a, context.temp_allocator)
	}
	pending := c.wlen
	j.execute(c, argv)
	out := reply_of(c, pending)
	c.wlen = 0
	c.wpos = 0
	return out
}

dispatch_client :: proc(db: int = 0) -> ^j.Conn {
	c := new_client(db)
	j.acl_conn_init(c)
	return c
}

@(test)
dispatch_feed_integration :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("dispatch-feed")
	defer feed_off()
	c := dispatch_client()
	testing.expect_value(t, exec_line(c, "SET", "pk", "1"), "+OK\r\n")
	expect_records(t, {"SELECT 0", "SET pk 1"})
	exec_line(c, "MULTI")
	testing.expect_value(t, exec_line(c, "SET", "m1", "1"), "+QUEUED\r\n")
	exec_line(c, "INCR", "m2")
	testing.expect_value(t, len(j.aof.buf), 0)
	testing.expect_value(t, exec_line(c, "EXEC"), "*2\r\n+OK\r\n:1\r\n")
	expect_records(t, {"MULTI", "SET m1 1", "INCR m2", "EXEC"})
	testing.expect(t, !j.aof.in_tx && !j.aof.in_cmd)

	exec_line(c, "MULTI")
	exec_line(c, "GET", "m1")
	exec_line(c, "SET", "single", "1")
	exec_line(c, "EXEC")
	expect_records(t, {"SET single 1"})

	exec_line(c, "SET", "ex", "v", "PX", "20")
	clear(&j.aof.buf)
	sleep_ms(40)
	testing.expect_value(t, exec_line(c, "GET", "ex"), "$-1\r\n")
	expect_records(t, {"DEL ex"})

	exec_line(c, "SET", "ex2", "5", "PX", "20")
	clear(&j.aof.buf)
	sleep_ms(40)
	exec_line(c, "MULTI")
	exec_line(c, "INCR", "ex2")
	testing.expect_value(t, exec_line(c, "EXEC"), "*1\r\n:1\r\n")
	expect_records(t, {"MULTI", "DEL ex2", "INCR ex2", "EXEC"})

	exec_line(c, "PFADD", "hl", "a", "b")
	exec_line(c, "PFCOUNT", "hl")
	recs := take_records(t)
	testing.expect(t, len(recs) >= 1 && joined(recs[0]) == "PFADD hl a b")
	testing.expect(t, len(recs) == 1 || (len(recs) == 2 && joined(recs[1]) == "PFCOUNT hl"))

	testing.expect_value(t, exec_line(c, "SET", "oom", "1", "NX", "XX"), "-ERR syntax error\r\n")
	exec_line(c, "SET", "nx", "1")
	clear(&j.aof.buf)
	exec_line(c, "SET", "nx", "2", "NX")
	exec_line(c, "SET", "nx", "2", "NX", "GET")
	exec_line(c, "SET", "nx", "3", "XX", "GET", "EX", "100")
	recs = take_records(t)
	testing.expect_value(t, len(recs), 1)
	if len(recs) == 1 {
		testing.expect(t, record_matches("SET nx 3 PXAT <n>", recs[0]))
	}

	c1 := dispatch_client(1)
	exec_line(c1, "SET", "other", "1")
	exec_line(c, "SET", "back", "1")
	expect_records(t, {"SELECT 1", "SET other 1", "SELECT 0", "SET back 1"})
}

@(test)
dispatch_stream_groups_resp3_and_history :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("dispatch-streams")
	defer feed_off()
	c := dispatch_client()
	exec_line(c, "XADD", "s", "1-0", "f", "v")
	exec_line(c, "XADD", "s", "2-0", "f", "v")
	exec_line(c, "XGROUP", "CREATE", "s", "g", "0")
	clear(&j.aof.buf)
	c.resp = j.RESP3
	exec_line(c, "XREADGROUP", "GROUP", "g", "alice", "STREAMS", "s", ">")
	expect_records(t, {"MULTI", "XCLAIM s g alice 0 1-0 TIME <n> RETRYCOUNT 1 FORCE JUSTID LASTID 1-0", "XCLAIM s g alice 0 2-0 TIME <n> RETRYCOUNT 1 FORCE JUSTID LASTID 2-0", "XGROUP SETID s g 2-0 ENTRIESREAD 2", "EXEC"})
	exec_line(c, "XREADGROUP", "GROUP", "g", "alice", "STREAMS", "s", "0")
	expect_records(t, {"MULTI", "XCLAIM s g alice 0 1-0 TIME <n> RETRYCOUNT 2 FORCE JUSTID LASTID 2-0", "XCLAIM s g alice 0 2-0 TIME <n> RETRYCOUNT 2 FORCE JUSTID LASTID 2-0", "EXEC"})
	c.resp = j.RESP2
	exec_line(c, "XADD", "s", "3-0", "f", "v")
	clear(&j.aof.buf)
	exec_line(c, "XREADGROUP", "GROUP", "g", "bob", "NOACK", "STREAMS", "s", ">")
	expect_records(t, {"MULTI", "XGROUP SETID s g 3-0 ENTRIESREAD 3", "XGROUP CREATECONSUMER s g bob", "EXEC"})
	exec_line(c, "XREADGROUP", "GROUP", "g", "carol", "STREAMS", "s", ">")
	expect_records(t, {"XGROUP CREATECONSUMER s g carol"})
	exec_line(c, "XREADGROUP", "GROUP", "g", "carol", "STREAMS", "s", ">")
	expect_records(t, {})
	exec_line(c, "XACK", "s", "g", "1-0")
	exec_line(c, "XACK", "s", "g", "1-0")
	expect_records(t, {"XACK s g 1-0"})
	exec_line(c, "XDEL", "s", "2-0")
	clear(&j.aof.buf)
	exec_line(c, "XCLAIM", "s", "g", "dave", "0", "2-0")
	expect_records(t, {"MULTI", "XGROUP CREATECONSUMER s g dave", "XACK s g 2-0", "EXEC"})
}

@(test)
dispatch_config_and_debug :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	dir := fresh_dir("dispatch-config")
	enter_dir(dir)
	defer leave_dir()
	saved_debug := j.cfg.enable_debug_command
	j.cfg.enable_debug_command = 1
	defer j.cfg.enable_debug_command = saved_debug
	j.aof.started = true
	c := dispatch_client()
	exec_line(c, "SET", "before", "1")
	testing.expect_value(t, exec_line(c, "CONFIG", "SET", "appendonly", "yes"), "+OK\r\n")
	testing.expect_value(t, j.aof.state, j.Aof_State.Wait_Rewrite)
	exec_line(c, "SET", "during", "1")
	testing.expect(t, wait_rewrite())
	testing.expect_value(t, j.aof.state, j.Aof_State.On)
	testing.expect_value(t, exec_line(c, "CONFIG", "GET", "appendonly"), "*2\r\n$10\r\nappendonly\r\n$3\r\nyes\r\n")
	exec_line(c, "SET", "after", "1")
	j.aof_before_sleep()
	info := exec_line(c, "INFO", "persistence")
	testing.expect(t, strings.contains(info, "aof_enabled:1\r\n"))
	testing.expect(t, strings.contains(info, "aof_buffer_length:0\r\n"))
	digest := dataset_digest()
	testing.expect_value(t, exec_line(c, "DEBUG", "LOADAOF"), "+OK\r\n")
	testing.expect(t, digest == dataset_digest())
	testing.expect_value(t, db_size(0), 3)
	exec_line(c, "MULTI")
	exec_line(c, "BGREWRITEAOF")
	testing.expect_value(t, exec_line(c, "EXEC"), "*1\r\n+Background append only file rewriting scheduled\r\n")
	testing.expect(t, j.aof.rewrite_scheduled)
	j.aof_cron()
	testing.expect(t, j.aof_rewriting())
	testing.expect(t, wait_rewrite())
	testing.expect_value(t, manifest_now(), "file appendonly.aof.2.base.rdb seq 2 type b\nfile appendonly.aof.2.incr.aof seq 2 type i\n")
	testing.expect_value(t, exec_line(c, "CONFIG", "SET", "appendonly", "no"), "+OK\r\n")
	testing.expect_value(t, j.aof.state, j.Aof_State.Off)
	info = exec_line(c, "INFO", "persistence")
	testing.expect(t, strings.contains(info, "aof_enabled:0\r\n"))
	testing.expect(t, !strings.contains(info, "aof_current_size"))
	testing.expect_value(t, strings.count(info, "module_fork_in_progress"), 1)
}

package transactions

import "core:strings"
import "core:sys/linux"
import "core:testing"
import j "../../src"

@(test)
runtime_errors_do_not_stop_the_transaction :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	call(a, "SET", "k", "2")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "INCR k", "+QUEUED\r\n")
	expect_call(t, a, "LPUSH k x", "+QUEUED\r\n")
	expect_call(t, a, "INCR k", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*3\r\n:3\r\n-WRONGTYPE Operation against a key holding the wrong kind of value\r\n:4\r\n")
	expect_call(t, a, "GET k", "$1\r\n4\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "EXEC", "*0\r\n")
}

@(test)
blocking_commands_never_block_inside_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	expect_call(t, a, "MULTI", "+OK\r\n")
	for line in ([?]string{"BLPOP nolist 0", "BRPOPLPUSH nolist dst 0", "XREAD BLOCK 0 STREAMS nostream $", "WAIT 1 1", "MONITOR"}) {
		expect_call(t, a, line, "+QUEUED\r\n")
	}
	expect_call(t, a, "EXEC", "*5\r\n*-1\r\n$-1\r\n*-1\r\n:0\r\n-ERR MONITOR isn't allowed for DENY BLOCKING client\r\n")
	testing.expect(t, a.c.blocked == .None)
	testing.expect(t, !j.deny_blocking)
	testing.expect(t, .Monitor not_in a.c.flags)
}

@(test)
select_inside_exec_persists :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SELECT 2", "+QUEUED\r\n")
	expect_call(t, a, "SET db2 v", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*2\r\n+OK\r\n+OK\r\n")
	testing.expect_value(t, a.c.db.id, 2)
	testing.expect(t, j.db_cur == a.c.db)
	expect_call(t, a, "GET db2", "$1\r\nv\r\n")
	expect_call(t, a, "SELECT 0", "+OK\r\n")
	expect_call(t, a, "EXISTS db2", ":0\r\n")
}

@(test)
subscribe_notices_are_inlined :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	got := wire_many(a, {"MULTI"}, {"SUBSCRIBE", "ch"}, {"PING"}, {"UNSUBSCRIBE"}, {"EXEC"}, {"PING"})
	want := "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*3\r\n*3\r\n$9\r\nsubscribe\r\n$2\r\nch\r\n:1\r\n*2\r\n$4\r\npong\r\n$0\r\n\r\n*3\r\n$11\r\nunsubscribe\r\n$2\r\nch\r\n:0\r\n+PONG\r\n"
	testing.expect_value(t, got, want)
	testing.expect(t, j.ps_exec == nil)
}

@(test)
subscribed_client_notices_and_self_messages :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	b := open_client()
	defer close_client(a)
	defer close_client(b)
	testing.expect_value(t, wire(b, "SUBSCRIBE", "ch"), "*3\r\n$9\r\nsubscribe\r\n$2\r\nch\r\n:1\r\n")
	testing.expect_value(t, wire(a, "SUBSCRIBE", "other"), "*3\r\n$9\r\nsubscribe\r\n$5\r\nother\r\n:1\r\n")
	testing.expect_value(t, wire(a, "UNSUBSCRIBE"), "*3\r\n$11\r\nunsubscribe\r\n$5\r\nother\r\n:0\r\n")
	got := wire_many(a, {"MULTI"}, {"SUBSCRIBE", "ch"}, {"PUBLISH", "ch", "m"}, {"PSUBSCRIBE", "c*"}, {"UNSUBSCRIBE"}, {"PUNSUBSCRIBE"}, {"EXEC"})
	want := "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n" +
		"*5\r\n*3\r\n$9\r\nsubscribe\r\n$2\r\nch\r\n:1\r\n:2\r\n*3\r\n$10\r\npsubscribe\r\n$2\r\nc*\r\n:2\r\n" +
		"*3\r\n$11\r\nunsubscribe\r\n$2\r\nch\r\n:1\r\n*3\r\n$12\r\npunsubscribe\r\n$2\r\nc*\r\n:0\r\n" +
		"*3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$1\r\nm\r\n"
	testing.expect_value(t, got, want)
	testing.expect_value(t, wire(b, "PING"), "*3\r\n$7\r\nmessage\r\n$2\r\nch\r\n$1\r\nm\r\n*2\r\n$4\r\npong\r\n$0\r\n\r\n")
	testing.expect(t, j.ps_exec == nil)
}

@(test)
resp3_transaction_replies :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(a)
	hello := wire(a, "HELLO", "3")
	testing.expect(t, strings.has_prefix(hello, "%7\r\n"), hello)
	got := wire_many(a, {"MULTI"}, {"SUBSCRIBE", "c3"}, {"PING"}, {"UNSUBSCRIBE", "c3"}, {"EXEC"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*3\r\n>3\r\n$9\r\nsubscribe\r\n$2\r\nc3\r\n:1\r\n+PONG\r\n>3\r\n$11\r\nunsubscribe\r\n$2\r\nc3\r\n:0\r\n")
	testing.expect_value(t, wire(a, "WATCH", "r3"), "+OK\r\n")
	testing.expect_value(t, wire(w, "SET", "r3", "1"), "+OK\r\n")
	testing.expect_value(t, wire_many(a, {"MULTI"}, {"PING"}, {"EXEC"}), "+OK\r\n+QUEUED\r\n_\r\n")
	hello = wire(a, "HELLO", "2")
	testing.expect(t, strings.has_prefix(hello, "*14\r\n"), hello)
}

@(test)
auth_and_hello_inside_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	got := wire_many(a, {"MULTI"}, {"AUTH", "x"}, {"HELLO", "3"}, {"EXEC"})
	prefix := "+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n-ERR AUTH <password> called without any password configured for the default user. Are you sure your configuration is correct?\r\n%7\r\n"
	testing.expect(t, strings.has_prefix(got, prefix), got)
	testing.expect_value(t, a.c.resp, u8(j.RESP3))
	hello := wire(a, "HELLO", "2")
	testing.expect(t, strings.has_prefix(hello, "*14\r\n"), hello)
}

@(test)
client_reply_off_inside_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	got := wire_many(a, {"MULTI"}, {"PING"}, {"CLIENT", "REPLY", "OFF"}, {"PING"}, {"EXEC"}, {"PING"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*3\r\n+PONG\r\n")
	testing.expect(t, .Off in a.c.reply)
	testing.expect_value(t, wire(a, "CLIENT", "REPLY", "ON"), "+OK\r\n")
	got = wire_many(a, {"MULTI"}, {"ECHO", "x"}, {"CLIENT", "REPLY", "ON"}, {"ECHO", "y"}, {"CLIENT", "REPLY", "OFF"}, {"EXEC"}, {"ECHO", "hidden"}, {"CLIENT", "REPLY", "ON"}, {"ECHO", "after"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*4\r\n$1\r\nx\r\n+OK\r\n$1\r\ny\r\n+OK\r\n$5\r\nafter\r\n")
	got = wire_many(a, {"CLIENT", "REPLY", "OFF"}, {"MULTI"}, {"ECHO", "x"}, {"CLIENT", "REPLY", "ON"}, {"ECHO", "y"}, {"EXEC"}, {"ECHO", "after"})
	testing.expect_value(t, got, "+OK\r\n$1\r\ny\r\n$5\r\nafter\r\n")
	testing.expect(t, a.c.reply == {})
	got = wire_many(a, {"CLIENT", "REPLY", "OFF"}, {"MULTI"}, {"PING"}, {"EXEC"}, {"CLIENT", "REPLY", "ON"}, {"PING"})
	testing.expect_value(t, got, "+OK\r\n+PONG\r\n")
	testing.expect(t, a.c.reply == {})
}

@(test)
client_reply_skip_inside_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	got := wire_many(a, {"MULTI"}, {"CLIENT", "REPLY", "SKIP"}, {"PING"}, {"PING", "x"}, {"EXEC"}, {"PING", "y"}, {"PING", "z"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*3\r\n+PONG\r\n$1\r\nx\r\n$1\r\nz\r\n")
	got = wire_many(a, {"MULTI"}, {"PING", "a"}, {"CLIENT", "REPLY", "SKIP"}, {"PING", "b"}, {"EXEC"}, {"PING", "c"}, {"PING", "d"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*3\r\n$1\r\na\r\n$1\r\nb\r\n$1\r\nd\r\n")
	got = wire_many(a, {"MULTI"}, {"CLIENT", "REPLY", "SKIP"}, {"CLIENT", "REPLY", "SKIP"}, {"PING", "a"}, {"EXEC"}, {"PING", "b"}, {"PING", "c"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*3\r\n$1\r\na\r\n$1\r\nc\r\n")
	got = wire_many(a, {"MULTI"}, {"CLIENT", "REPLY", "SKIP"}, {"NOSUCH"}, {"EXEC"}, {"PING", "a"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n-ERR unknown command 'NOSUCH', with args beginning with: \r\n-EXECABORT Transaction discarded because of previous errors.\r\n$1\r\na\r\n")
	got = wire_many(a, {"MULTI"}, {"CLIENT", "REPLY", "SKIP"}, {"DISCARD"}, {"PING", "a"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+OK\r\n$1\r\na\r\n")
	got = wire_many(a, {"CLIENT", "REPLY", "SKIP"}, {"MULTI"}, {"ECHO", "x"}, {"EXEC"})
	testing.expect_value(t, got, "+QUEUED\r\n*1\r\n$1\r\nx\r\n")
	got = wire_many(a, {"MULTI"}, {"ECHO", "x"}, {"EXEC"}, {"ECHO", "y"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n*1\r\n$1\r\nx\r\n$1\r\ny\r\n")
	testing.expect(t, a.c.reply == {})
}

@(test)
client_reply_skip_around_subscribe :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	got := wire_many(a, {"MULTI"}, {"SUBSCRIBE", "tx:rc"}, {"CLIENT", "REPLY", "SKIP"}, {"SUBSCRIBE", "tx:rd"}, {"CLIENT", "REPLY", "ON"}, {"PING"}, {"EXEC"}, {"PING", "z"}, {"UNSUBSCRIBE", "tx:rc", "tx:rd"})
	want := "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n" +
		"*5\r\n*3\r\n$9\r\nsubscribe\r\n$5\r\ntx:rc\r\n:1\r\n*3\r\n$9\r\nsubscribe\r\n$5\r\ntx:rd\r\n:2\r\n+OK\r\n*2\r\n$4\r\npong\r\n$0\r\n\r\n" +
		"*3\r\n$11\r\nunsubscribe\r\n$5\r\ntx:rc\r\n:1\r\n*3\r\n$11\r\nunsubscribe\r\n$5\r\ntx:rd\r\n:0\r\n"
	testing.expect_value(t, got, want)
	testing.expect(t, a.c.reply == {})
}

@(test)
client_reply_on_does_not_cancel_an_armed_skip :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	got := wire_many(a, {"MULTI"}, {"CLIENT", "REPLY", "SKIP"}, {"CLIENT", "REPLY", "ON"}, {"EXEC"}, {"PING", "z"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n+OK\r\n")
	testing.expect(t, a.c.reply == {})
	got = wire_many(a, {"MULTI"}, {"CLIENT", "REPLY", "SKIP"}, {"PING", "a"}, {"CLIENT", "REPLY", "OFF"}, {"PING", "b"}, {"CLIENT", "REPLY", "ON"}, {"EXEC"}, {"PING", "z"}, {"PING", "y"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*5\r\n$1\r\na\r\n+OK\r\n$1\r\ny\r\n")
	testing.expect(t, a.c.reply == {})
	got = wire_many(a, {"CLIENT", "REPLY", "SKIP"}, {"CLIENT", "REPLY", "ON"}, {"PING", "z"})
	testing.expect_value(t, got, "+OK\r\n$1\r\nz\r\n")
	testing.expect(t, a.c.reply == {})
}

@(test)
push_frames_survive_reply_off_inside_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	got := wire_many(a, {"MULTI"}, {"SUBSCRIBE", "tx:rc"}, {"CLIENT", "REPLY", "OFF"}, {"SUBSCRIBE", "tx:rd"}, {"CLIENT", "REPLY", "ON"}, {"PING"}, {"EXEC"}, {"PING", "z"})
	want := "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n" +
		"*5\r\n*3\r\n$9\r\nsubscribe\r\n$5\r\ntx:rc\r\n:1\r\n*3\r\n$9\r\nsubscribe\r\n$5\r\ntx:rd\r\n:2\r\n+OK\r\n*2\r\n$4\r\npong\r\n$0\r\n\r\n" +
		"*2\r\n$4\r\npong\r\n$1\r\nz\r\n"
	testing.expect_value(t, got, want)
	testing.expect_value(t, wire(a, "UNSUBSCRIBE"), "*3\r\n$11\r\nunsubscribe\r\n$5\r\ntx:rc\r\n:1\r\n*3\r\n$11\r\nunsubscribe\r\n$5\r\ntx:rd\r\n:0\r\n")
	b := open_client()
	defer close_client(b)
	hello := wire(b, "HELLO", "3")
	testing.expect(t, strings.has_prefix(hello, "%7\r\n"), hello)
	got = wire_many(b, {"MULTI"}, {"SUBSCRIBE", "tx:rc"}, {"CLIENT", "REPLY", "OFF"}, {"SUBSCRIBE", "tx:rd"}, {"PUBLISH", "tx:rc", "m"}, {"CLIENT", "REPLY", "ON"}, {"PING"}, {"EXEC"}, {"PING", "z"})
	want = "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n" +
		"*6\r\n>3\r\n$9\r\nsubscribe\r\n$5\r\ntx:rc\r\n:1\r\n>3\r\n$9\r\nsubscribe\r\n$5\r\ntx:rd\r\n:2\r\n+OK\r\n+PONG\r\n" +
		">3\r\n$7\r\nmessage\r\n$5\r\ntx:rc\r\n$1\r\nm\r\n$1\r\nz\r\n"
	testing.expect_value(t, got, want)
	testing.expect_value(t, wire(b, "UNSUBSCRIBE"), ">3\r\n$11\r\nunsubscribe\r\n$5\r\ntx:rc\r\n:1\r\n>3\r\n$11\r\nunsubscribe\r\n$5\r\ntx:rd\r\n:0\r\n")
	hello = wire(b, "HELLO", "2")
	testing.expect(t, strings.has_prefix(hello, "*14\r\n"), hello)
	c := open_client()
	defer close_client(c)
	got = wire_many(c, {"CLIENT", "REPLY", "OFF"}, {"MULTI"}, {"SUBSCRIBE", "tx:off"}, {"PING"}, {"EXEC"}, {"CLIENT", "REPLY", "ON"}, {"UNSUBSCRIBE"})
	testing.expect_value(t, got, "*3\r\n$9\r\nsubscribe\r\n$6\r\ntx:off\r\n:1\r\n*3\r\n$11\r\nunsubscribe\r\n$6\r\ntx:off\r\n:0\r\n")
	testing.expect_value(t, wire(c, "PING"), "")
	testing.expect_value(t, wire(c, "CLIENT", "REPLY", "ON"), "+OK\r\n")
	testing.expect_value(t, wire(c, "PING"), "+PONG\r\n")
}

@(test)
dirty_counting :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(a)
	d0 := j.pst.dirty
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET d1 1", "+QUEUED\r\n")
	expect_call(t, a, "SET d2 2", "+QUEUED\r\n")
	expect_call(t, a, "GET d1", "+QUEUED\r\n")
	expect_call(t, a, "INCR d1", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*4\r\n+OK\r\n+OK\r\n$1\r\n1\r\n:2\r\n")
	testing.expect_value(t, j.pst.dirty - d0, 3)
	d0 = j.pst.dirty
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "GET d1", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*1\r\n$1\r\n2\r\n")
	testing.expect_value(t, j.pst.dirty - d0, 0)
	expect_call(t, a, "WATCH d1", "+OK\r\n")
	expect_call(t, w, "SET d1 x", "+OK\r\n")
	d0 = j.pst.dirty
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET d3 1", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*-1\r\n")
	testing.expect_value(t, j.pst.dirty - d0, 0)
	expect_call(t, a, "EXISTS d3", ":0\r\n")
}

@(test)
commandstats_and_errorstats :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	call(a, "CONFIG", "RESETSTAT")
	processed := j.srv.stat_commands
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET s 1", "+QUEUED\r\n")
	expect_call(t, a, "LPUSH s x", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*2\r\n+OK\r\n-WRONGTYPE Operation against a key holding the wrong kind of value\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET s", "-ERR wrong number of arguments for 'set' command\r\n")
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of previous errors.\r\n")
	stats := call(a, "INFO", "commandstats")
	testing.expect(t, strings.contains(stats, "cmdstat_set:calls=1,"), stats)
	testing.expect(t, strings.contains(stats, "rejected_calls=1,failed_calls=0\r\ncmdstat") || strings.contains(stats, "rejected_calls=1,failed_calls=0\r\n\r\n"), stats)
	testing.expect(t, strings.contains(stats, "cmdstat_lpush:calls=1,"), stats)
	testing.expect(t, strings.contains(stats, "cmdstat_exec:calls=2,"), stats)
	testing.expect(t, strings.contains(stats, "cmdstat_multi:calls=2,"), stats)
	errors := call(a, "INFO", "errorstats")
	testing.expect(t, strings.contains(errors, "errorstat_EXECABORT:count=1\r\n"), errors)
	testing.expect(t, strings.contains(errors, "errorstat_WRONGTYPE:count=1\r\n"), errors)
	testing.expect(t, strings.contains(errors, "errorstat_ERR:count=1\r\n"), errors)
	testing.expect_value(t, j.srv.stat_commands - processed, 8)
}

@(test)
nested_commands_reach_the_slowlog :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	call(a, "CONFIG", "SET", "slowlog-log-slower-than", "0")
	defer call(a, "CONFIG", "SET", "slowlog-log-slower-than", "10000")
	call(a, "SLOWLOG", "RESET")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET slowkey 1", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*1\r\n+OK\r\n")
	log := call(a, "SLOWLOG", "GET")
	testing.expect(t, strings.contains(log, "$3\r\nSET\r\n$7\r\nslowkey\r\n"), log)
	testing.expect(t, !strings.contains(log, "$4\r\nEXEC\r\n"), log)
}

@(test)
aof_staging_wraps_multiple_writes :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	fd, open_err := linux.open("/tmp/transactions-feed.aof", {.WRONLY, .CREAT, .TRUNC, .APPEND, .CLOEXEC}, {.IRUSR, .IWUSR})
	testing.expect(t, open_err == .NONE)
	saved_state := j.aof.state
	j.aof.fd = fd
	j.aof.state = .Enabled
	j.aof.loading = false
	j.aof.selected_db = -1
	j.aof.in_cmd = false
	j.aof.in_tx = false
	clear(&j.aof.buf)
	clear(&j.aof.stage)
	j.aof.stage_count = 0
	j.aof_update_feed()
	defer {
		linux.close(fd)
		linux.unlink("/tmp/transactions-feed.aof")
		j.aof.fd = -1
		j.aof.state = saved_state
		clear(&j.aof.buf)
		j.aof_update_feed()
	}
	call(a, "SET", "warm", "1")
	clear(&j.aof.buf)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET x 1", "+QUEUED\r\n")
	expect_call(t, a, "GET x", "+QUEUED\r\n")
	expect_call(t, a, "SET y 2", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*3\r\n+OK\r\n$1\r\n1\r\n+OK\r\n")
	testing.expect_value(t, string(j.aof.buf[:]), "*1\r\n$5\r\nMULTI\r\n*3\r\n$3\r\nSET\r\n$1\r\nx\r\n$1\r\n1\r\n*3\r\n$3\r\nSET\r\n$1\r\ny\r\n$1\r\n2\r\n*1\r\n$4\r\nEXEC\r\n")
	testing.expect(t, !j.aof.in_tx)
	clear(&j.aof.buf)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET x 3", "+QUEUED\r\n")
	expect_call(t, a, "GET y", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*2\r\n+OK\r\n$1\r\n2\r\n")
	testing.expect_value(t, string(j.aof.buf[:]), "*3\r\n$3\r\nSET\r\n$1\r\nx\r\n$1\r\n3\r\n")
	clear(&j.aof.buf)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "GET y", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*1\r\n$1\r\n2\r\n")
	testing.expect_value(t, string(j.aof.buf[:]), "")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SELECT 3", "+QUEUED\r\n")
	expect_call(t, a, "SET x 1", "+QUEUED\r\n")
	expect_call(t, a, "SELECT 0", "+QUEUED\r\n")
	expect_call(t, a, "SET y 1", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*4\r\n+OK\r\n+OK\r\n+OK\r\n+OK\r\n")
	testing.expect_value(t, string(j.aof.buf[:]), "*1\r\n$5\r\nMULTI\r\n*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n*3\r\n$3\r\nSET\r\n$1\r\nx\r\n$1\r\n1\r\n*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n*3\r\n$3\r\nSET\r\n$1\r\ny\r\n$1\r\n1\r\n*1\r\n$4\r\nEXEC\r\n")
	clear(&j.aof.buf)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET x 1", "+QUEUED\r\n")
	expect_call(t, a, "EXEC x", "-EXECABORT Transaction discarded because of: wrong number of arguments for 'exec' command\r\n")
	testing.expect_value(t, string(j.aof.buf[:]), "")
}

@(test)
oom_refusals :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(a)
	expect_call(t, w, "CONFIG SET maxmemory 1", "+OK\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET oom 1", "-OOM command not allowed when used memory > 'maxmemory'.\r\n")
	expect_call(t, a, "GET oom", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of previous errors.\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "GET oom", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*1\r\n$-1\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET oom 1", "-OOM command not allowed when used memory > 'maxmemory'.\r\n")
	expect_call(t, w, "CONFIG SET maxmemory 0", "+OK\r\n")
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of previous errors.\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET oom 1", "+QUEUED\r\n")
	expect_call(t, a, "GET oom", "+QUEUED\r\n")
	expect_call(t, w, "CONFIG SET maxmemory 1", "+OK\r\n")
	testing.expect(t, j.oom_denied(a.c, j.lookup_command(transmute([]u8)string("exec")), argv_of({"EXEC"})))
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of: OOM command not allowed when used memory > 'maxmemory'.\r\n")
	testing.expect(t, a.c.txf == {})
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "DISCARD", "+OK\r\n")
	expect_call(t, w, "CONFIG SET maxmemory 0", "+OK\r\n")
	expect_call(t, a, "EXISTS oom", ":0\r\n")
}

@(test)
persistence_refusals :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	saved_params := len(j.pst.save_params)
	defer {
		j.pst.lastbgsave_err = false
		j.pst.loading = false
		resize(&j.pst.save_params, saved_params)
		j.persist_update_gate()
	}
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET k v", "+QUEUED\r\n")
	expect_call(t, a, "GET k", "+QUEUED\r\n")
	j.pst.lastbgsave_err = true
	append(&j.pst.save_params, j.Save_Param{3600, 1})
	j.persist_update_gate()
	testing.expect(t, j.persist_writes_denied())
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of: " + j.ERR_MISCONF + "\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET k v", "-" + j.ERR_MISCONF + "\r\n")
	expect_call(t, a, "GET k", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of previous errors.\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "PING", "-" + j.ERR_MISCONF + "\r\n")
	expect_call(t, a, "DISCARD", "+OK\r\n")
	j.pst.lastbgsave_err = false
	j.persist_update_gate()
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "PING", "+QUEUED\r\n")
	expect_call(t, a, "GET k", "+QUEUED\r\n")
	j.pst.loading = true
	j.persist_update_gate()
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of: " + j.ERR_LOADING + "\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "GET k", "-" + j.ERR_LOADING + "\r\n")
	expect_call(t, a, "SELECT 0", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of previous errors.\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SELECT 0", "+QUEUED\r\n")
	expect_call(t, a, "EXEC", "*1\r\n+OK\r\n")
	j.pst.loading = false
	j.persist_update_gate()
	expect_call(t, a, "EXISTS k", ":0\r\n")
}

@(test)
acl_changes_are_checked_at_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(w)
	reset_server(w)
	expect_call(t, w, "ACL SETUSER txuser on nopass +@all ~* &*", "+OK\r\n")
	expect_call(t, a, "AUTH txuser x", "+OK\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET k 1", "+QUEUED\r\n")
	expect_call(t, a, "GET k", "+QUEUED\r\n")
	expect_call(t, w, "ACL SETUSER txuser -set", "+OK\r\n")
	testing.expect(t, a.c.acl_gate)
	expect_call(t, a, "EXEC", "*2\r\n-NOPERM ACLs rules changed between the moment the transaction was accumulated and the EXEC call. This command is no longer allowed for the following reason: no permission to execute the command or subcommand\r\n$-1\r\n")
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "SET k 1", "-NOPERM User txuser has no permissions to run the 'set' command\r\n")
	expect_call(t, a, "EXEC", "-EXECABORT Transaction discarded because of previous errors.\r\n")
	close_client(a)
	expect_call(t, w, "ACL DELUSER txuser", ":1\r\n")
	expect_call(t, w, "EXISTS k", ":0\r\n")
}

@(test)
quit_inside_multi_closes_and_releases :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(w)
	watching := j.watch_clients
	multis := j.tx_multi_count
	testing.expect_value(t, wire(a, "WATCH", "qk"), "+OK\r\n")
	testing.expect_value(t, j.watch_clients, watching + 1)
	got := wire_many(a, {"MULTI"}, {"SET", "qk", "1"}, {"QUIT"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+OK\r\n")
	testing.expect(t, !client_alive(a))
	testing.expect_value(t, j.watch_clients, watching)
	testing.expect_value(t, j.tx_multi_count, multis)
	expect_call(t, w, "EXISTS qk", ":0\r\n")
	close_client(a)
}

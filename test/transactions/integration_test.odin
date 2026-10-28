package transactions

import "core:fmt"
import "core:strings"
import "core:testing"
import j "../../src"

@(test)
stat_slots_match_command_stats :: proc(t: ^testing.T) {
	context.allocator = boot()
	seen := 0
	for &slot in j.cmd_table {
		if slot.cmd == nil {
			continue
		}
		seen += 1
		testing.expectf(t, j.stat_of(slot.cmd) == slot.stats, "stats for %s", slot.key)
	}
	testing.expect(t, seen > 200)
	for name in ([?]string{"multi", "exec", "discard", "watch", "unwatch"}) {
		cmd := j.lookup_command(transmute([]u8)name)
		testing.expectf(t, cmd != nil && cmd.name == name, "%s registered", name)
	}
}

@(test)
more_blocking_commands_inside_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	lines := [?]string {
		"BRPOP nolist 0",
		"BLMOVE nolist dst LEFT RIGHT 0",
		"BLMPOP 0 1 nolist LEFT",
		"BZPOPMIN nozset 0",
		"BZPOPMAX nozset 0",
		"BZMPOP 0 1 nozset MIN",
	}
	expect_call(t, a, "MULTI", "+OK\r\n")
	for line in lines {
		expect_call(t, a, line, "+QUEUED\r\n")
	}
	expect_call(t, a, "EXEC", "*6\r\n*-1\r\n$-1\r\n*-1\r\n*-1\r\n*-1\r\n*-1\r\n")
	testing.expect(t, a.c.blocked == .None)
	testing.expect_value(t, j.block_count(), 0)
}

@(test)
tracking_remembers_keys_read_inside_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	call(w, "SET", "tk1", "1")
	call(w, "SET", "tk2", "2")
	hello := wire(a, "HELLO", "3")
	testing.expect(t, strings.has_prefix(hello, "%7\r\n"), hello)
	expect_wire(t, a, "CLIENT TRACKING ON", "+OK\r\n")
	got := wire_many(a, {"MULTI"}, {"GET", "tk1"}, {"GET", "tk2"}, {"EXEC"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n$1\r\n1\r\n$1\r\n2\r\n")
	expect_wire(t, w, "SET tk2 3", "+OK\r\n")
	testing.expect_value(t, drain(a.peer), "")
	j.conn_flush(a.c)
	testing.expect_value(t, drain(a.peer), ">2\r\n$10\r\ninvalidate\r\n*1\r\n$3\r\ntk2\r\n")
	got = wire_many(a, {"MULTI"}, {"GET", "tk1"}, {"SET", "tk1", "9"}, {"EXEC"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n$1\r\n1\r\n+OK\r\n>2\r\n$10\r\ninvalidate\r\n*1\r\n$3\r\ntk1\r\n")
	expect_wire(t, a, "CLIENT TRACKING OFF", "+OK\r\n")
	hello = wire(a, "HELLO", "2")
	testing.expect(t, strings.has_prefix(hello, "*14\r\n"), hello)
}

@(test)
monitor_sees_nested_commands_in_order :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	m := open_client()
	defer close_client(a)
	defer close_client(m)
	expect_wire(t, m, "MONITOR", "+OK\r\n")
	got := wire_many(a, {"MULTI"}, {"SET", "mk", "1"}, {"GET", "mk"}, {"EXEC"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n+OK\r\n$1\r\n1\r\n")
	j.conn_flush(m.c)
	feed := drain(m.peer)
	multi := strings.index(feed, "\"MULTI\"")
	set := strings.index(feed, "\"SET\" \"mk\" \"1\"")
	get := strings.index(feed, "\"GET\" \"mk\"")
	exec := strings.index(feed, "\"EXEC\"")
	testing.expectf(t, multi >= 0 && set > multi && get > set && exec > get, "monitor order %q", feed)
	testing.expect_value(t, strings.count(feed, "\"SET\""), 1)
}

@(test)
killing_itself_inside_exec_closes_after_reply :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(w)
	reset_server(w)
	multis := j.tx_multi_count
	kill := fmt.tprintf("%d", a.c.id)
	got := wire_many(a, {"MULTI"}, {"SET", "x", "2"}, {"CLIENT", "KILL", "ID", kill, "SKIPME", "no"}, {"SET", "y", "3"}, {"PING"}, {"EXEC"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*4\r\n+OK\r\n:1\r\n")
	testing.expect_value(t, j.tx_multi_count, multis)
	testing.expect(t, j.tx_exec_conn == nil)
	close_client(a)
	expect_call(t, w, "GET x", "$1\r\n2\r\n")
	expect_call(t, w, "GET y", "$1\r\n3\r\n")
}

@(test)
keyspace_events_for_self_follow_the_exec_reply :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	call(a, "CONFIG", "SET", "notify-keyspace-events", "KEA")
	defer call(a, "CONFIG", "SET", "notify-keyspace-events", "")
	hello := wire(a, "HELLO", "3")
	testing.expect(t, strings.has_prefix(hello, "%7\r\n"), hello)
	expect_wire(t, a, "SUBSCRIBE __keyevent@0__:set", ">3\r\n$9\r\nsubscribe\r\n$18\r\n__keyevent@0__:set\r\n:1\r\n")
	got := wire_many(a, {"MULTI"}, {"SET", "ek", "1"}, {"GET", "ek"}, {"EXEC"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n+OK\r\n$1\r\n1\r\n>3\r\n$7\r\nmessage\r\n$18\r\n__keyevent@0__:set\r\n$2\r\nek\r\n")
	expect_wire(t, a, "UNSUBSCRIBE", ">3\r\n$11\r\nunsubscribe\r\n$18\r\n__keyevent@0__:set\r\n:0\r\n")
	hello = wire(a, "HELLO", "2")
	testing.expect(t, strings.has_prefix(hello, "*14\r\n"), hello)
}

@(test)
flushall_inside_exec_does_not_block :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	big := strings.repeat("v", 200000, context.temp_allocator)
	for i in 0 ..< 40 {
		call(a, "SET", fmt.tprintf("big%d", i), big)
		call(a, "RPUSH", fmt.tprintf("list%d", i), "a", "b", "c", big)
	}
	got := wire_many(a, {"MULTI"}, {"FLUSHALL"}, {"PING"}, {"DBSIZE"}, {"EXEC"}, {"PING"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*3\r\n+OK\r\n+PONG\r\n:0\r\n+PONG\r\n")
	testing.expect(t, a.c.blocked == .None)
	for i in 0 ..< 40 {
		call(a, "SET", fmt.tprintf("big%d", i), big)
	}
	got = wire_many(a, {"MULTI"}, {"FLUSHDB"}, {"DBSIZE"}, {"EXEC"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n+OK\r\n:0\r\n")
	testing.expect(t, a.c.blocked == .None)
}

@(test)
pause_write_holds_exec_only_with_writes :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "GET k", "+QUEUED\r\n")
	expect_call(t, w, "CLIENT PAUSE 100000 WRITE", "+OK\r\n")
	defer call(w, "CLIENT", "UNPAUSE")
	testing.expect(t, !j.pause_should_hold(a.c, argv_of({"EXEC"})))
	expect_call(t, a, "SET k 1", "+QUEUED\r\n")
	testing.expect(t, j.pause_should_hold(a.c, argv_of({"EXEC"})))
	expect_call(t, a, "DISCARD", "+OK\r\n")
	testing.expect(t, !j.pause_should_hold(a.c, argv_of({"EXEC"})))
}

@(test)
optin_caching_covers_the_whole_transaction :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	call(w, "SET", "oa", "1")
	call(w, "SET", "ob", "2")
	call(w, "SET", "oc", "3")
	hello := wire(a, "HELLO", "3")
	testing.expect(t, strings.has_prefix(hello, "%7\r\n"), hello)
	expect_wire(t, a, "CLIENT TRACKING ON OPTIN", "+OK\r\n")
	expect_wire(t, a, "CLIENT CACHING YES", "+OK\r\n")
	got := wire_many(a, {"MULTI"}, {"GET", "oa"}, {"GET", "ob"}, {"EXEC"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n$1\r\n1\r\n$1\r\n2\r\n")
	expect_wire(t, a, "GET oc", "$1\r\n3\r\n")
	expect_wire(t, w, "SET oa 9", "+OK\r\n")
	expect_wire(t, w, "SET ob 9", "+OK\r\n")
	expect_wire(t, w, "SET oc 9", "+OK\r\n")
	j.conn_flush(a.c)
	testing.expect_value(t, drain(a.peer), ">2\r\n$10\r\ninvalidate\r\n*1\r\n$2\r\noa\r\n>2\r\n$10\r\ninvalidate\r\n*1\r\n$2\r\nob\r\n")
	expect_wire(t, a, "CLIENT TRACKING OFF", "+OK\r\n")
	hello = wire(a, "HELLO", "2")
	testing.expect(t, strings.has_prefix(hello, "*14\r\n"), hello)
}

@(test)
caching_flag_inside_transaction_and_optout :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	for key in ([?]string{"qa", "qb", "qc", "qd"}) {
		call(w, "SET", key, "1")
	}
	hello := wire(a, "HELLO", "3")
	testing.expect(t, strings.has_prefix(hello, "%7\r\n"), hello)
	expect_wire(t, a, "CLIENT TRACKING ON OPTIN", "+OK\r\n")
	got := wire_many(a, {"MULTI"}, {"GET", "qa"}, {"CLIENT", "CACHING", "YES"}, {"GET", "qb"}, {"GET", "qc"}, {"EXEC"}, {"GET", "qd"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*4\r\n$1\r\n1\r\n+OK\r\n$1\r\n1\r\n$1\r\n1\r\n$1\r\n1\r\n")
	for key in ([?]string{"qa", "qb", "qc", "qd"}) {
		call(w, "SET", key, "2")
	}
	j.conn_flush(a.c)
	testing.expect_value(t, drain(a.peer), ">2\r\n$10\r\ninvalidate\r\n*1\r\n$2\r\nqb\r\n>2\r\n$10\r\ninvalidate\r\n*1\r\n$2\r\nqc\r\n")
	expect_wire(t, a, "CLIENT TRACKING OFF", "+OK\r\n")
	expect_wire(t, a, "CLIENT TRACKING ON OPTOUT", "+OK\r\n")
	expect_wire(t, a, "CLIENT CACHING NO", "+OK\r\n")
	got = wire_many(a, {"MULTI"}, {"GET", "qa"}, {"GET", "qb"}, {"EXEC"}, {"GET", "qc"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n*2\r\n$1\r\n2\r\n$1\r\n2\r\n$1\r\n2\r\n")
	for key in ([?]string{"qa", "qb", "qc"}) {
		call(w, "SET", key, "3")
	}
	j.conn_flush(a.c)
	testing.expect_value(t, drain(a.peer), ">2\r\n$10\r\ninvalidate\r\n*1\r\n$2\r\nqc\r\n")
	expect_wire(t, a, "CLIENT TRACKING OFF", "+OK\r\n")
	hello = wire(a, "HELLO", "2")
	testing.expect(t, strings.has_prefix(hello, "*14\r\n"), hello)
}

@(test)
monitor_feeds_aborted_exec_with_arguments :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	m := open_client()
	defer close_client(a)
	defer close_client(m)
	expect_wire(t, m, "MONITOR", "+OK\r\n")
	got := wire_many(a, {"GET"}, {"NOSUCH"}, {"DISCARD", "extra"}, {"MULTI", "extra"}, {"WATCH"}, {"SET", "a"})
	testing.expect(t, strings.count(got, "-ERR") == 6, got)
	got = wire_many(a, {"MULTI"}, {"MULTI"}, {"WATCH", "w"}, {"PING"}, {"EXEC"}, {"EXEC"}, {"EXEC", "extra"}, {"MULTI"}, {"EXEC", "extra"})
	want := "+OK\r\n-ERR MULTI calls can not be nested\r\n-ERR WATCH inside MULTI is not allowed\r\n+QUEUED\r\n*1\r\n+PONG\r\n" +
		"-ERR EXEC without MULTI\r\n-EXECABORT Transaction discarded because of: wrong number of arguments for 'exec' command\r\n" +
		"+OK\r\n-EXECABORT Transaction discarded because of: wrong number of arguments for 'exec' command\r\n"
	testing.expect_value(t, got, want)
	j.conn_flush(m.c)
	feed := drain(m.peer)
	lines: [dynamic]string
	lines.allocator = context.temp_allocator
	rest := feed
	for line in strings.split_lines_iterator(&rest) {
		bracket := strings.index(line, "] ")
		if bracket >= 0 {
			append(&lines, line[bracket + 2:])
		}
	}
	expected := [?]string{"\"MULTI\"", "\"MULTI\"", "\"WATCH\" \"w\"", "\"PING\"", "\"EXEC\"", "\"EXEC\"", "\"EXEC\" \"extra\"", "\"MULTI\"", "\"EXEC\" \"extra\""}
	testing.expectf(t, len(lines) == len(expected), "monitor feed %q", feed)
	for want_line, i in expected {
		if i < len(lines) {
			testing.expectf(t, strings.trim_right(lines[i], "\r") == want_line, "line %d: got %q want %q", i, lines[i], want_line)
		}
	}
}

INVALIDATE_B :: ">2\r\n$10\r\ninvalidate\r\n*1\r\n$1\r\nb\r\n"

@(test)
reads_inside_exec_are_tracked :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	for key, i in ([?]string{"a", "b", "c", "d"}) {
		call(w, "SET", key, fmt.tprintf("%d", i + 1))
	}
	hello := wire(a, "HELLO", "3")
	testing.expect(t, strings.has_prefix(hello, "%7\r\n"), hello)
	expect_wire(t, a, "CLIENT TRACKING on", "+OK\r\n")
	expect_wire(t, a, "GET a", "$1\r\n1\r\n")
	testing.expect_value(t, wire_many(a, {"MULTI"}, {"GET", "b"}, {"EXEC"}), "+OK\r\n+QUEUED\r\n*1\r\n$1\r\n2\r\n")
	testing.expect(t, .Multi not_in a.c.txf)
	expect_wire(t, w, "SET a 9", "+OK\r\n")
	j.conn_flush(a.c)
	testing.expect_value(t, drain(a.peer), ">2\r\n$10\r\ninvalidate\r\n*1\r\n$1\r\na\r\n")
	expect_wire(t, w, "SET b 9", "+OK\r\n")
	j.conn_flush(a.c)
	testing.expect_value(t, drain(a.peer), INVALIDATE_B)
	testing.expect_value(t, wire_many(a, {"MULTI"}, {"MGET", "c", "d"}, {"EXEC"}), "+OK\r\n+QUEUED\r\n*1\r\n*2\r\n$1\r\n3\r\n$1\r\n4\r\n")
	expect_wire(t, w, "SET c 9", "+OK\r\n")
	j.conn_flush(a.c)
	testing.expect_value(t, drain(a.peer), ">2\r\n$10\r\ninvalidate\r\n*1\r\n$1\r\nc\r\n")
	expect_wire(t, w, "SET d 9", "+OK\r\n")
	j.conn_flush(a.c)
	testing.expect_value(t, drain(a.peer), ">2\r\n$10\r\ninvalidate\r\n*1\r\n$1\r\nd\r\n")
	expect_wire(t, a, "CLIENT TRACKING off", "+OK\r\n")
	hello = wire(a, "HELLO", "2")
	testing.expect(t, strings.has_prefix(hello, "*14\r\n"), hello)
}

@(test)
lazy_expiry_invalidates_a_key_read_inside_exec :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	reset_server(a)
	saved_debug := j.cfg.enable_debug_command
	j.cfg.enable_debug_command = 1
	defer j.cfg.enable_debug_command = saved_debug
	hello := wire(a, "HELLO", "3")
	testing.expect(t, strings.has_prefix(hello, "%7\r\n"), hello)
	expect_wire(t, a, "CLIENT TRACKING on", "+OK\r\n")
	expect_wire(t, a, "DEBUG SET-ACTIVE-EXPIRE 0", "+OK\r\n")
	got := wire_many(a, {"MULTI"}, {"MSET", "x{t}", "1", "y{t}", "2"}, {"PEXPIRE", "y{t}", "100"}, {"GET", "y{t}"}, {"EXEC"})
	testing.expect_value(t, got, "+OK\r\n+QUEUED\r\n+QUEUED\r\n+QUEUED\r\n*3\r\n+OK\r\n:1\r\n$1\r\n2\r\n")
	settle(150)
	got = wire(a, "MGET", "x{t}", "y{t}")
	testing.expect_value(t, got, "*2\r\n$1\r\n1\r\n_\r\n>2\r\n$10\r\ninvalidate\r\n*1\r\n$4\r\ny{t}\r\n")
	expect_wire(t, a, "DEBUG SET-ACTIVE-EXPIRE 1", "+OK\r\n")
	expect_wire(t, a, "CLIENT TRACKING off", "+OK\r\n")
	hello = wire(a, "HELLO", "2")
	testing.expect(t, strings.has_prefix(hello, "*14\r\n"), hello)
}

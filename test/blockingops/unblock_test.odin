package blockingops

import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import eski "../../src"

@(test)
unblock_forms_for_every_block_type :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	a := connect()
	Form :: struct {
		args:   []string,
		btype:  eski.Block_Type,
		reason: string,
		want:   string,
	}
	unblocked :: "-UNBLOCKED client unblocked via CLIENT UNBLOCK\r\n"
	forms := []Form {
		{{"BLPOP", "l1", "l2", "0"}, .List, "", NULL_ARRAY},
		{{"BRPOP", "l1", "0"}, .List, "TIMEOUT", NULL_ARRAY},
		{{"BLMPOP", "0", "1", "l1", "RIGHT"}, .List, "error", unblocked},
		{{"BLMOVE", "l1", "l2", "LEFT", "LEFT", "0"}, .List, "timeout", NULL_ARRAY},
		{{"BRPOPLPUSH", "l1", "l2", "0"}, .List, "ERROR", unblocked},
		{{"BZPOPMIN", "z1", "0"}, .Zset, "", NULL_ARRAY},
		{{"BZPOPMAX", "z1", "z2", "0"}, .Zset, "ERROR", unblocked},
		{{"BZMPOP", "0", "2", "z1", "z2", "MAX", "COUNT", "3"}, .Zset, "TIMEOUT", NULL_ARRAY},
		{{"XREAD", "BLOCK", "0", "STREAMS", "s1", "$"}, .Stream, "ERROR", unblocked},
	}
	for f in forms {
		start_cmd(t, a, ..f.args)
		testing.expect_value(t, a.conn.blocked, f.btype)
		testing.expect_value(t, eski.block_by_type[f.btype], 1)
		testing.expect_value(t, info_field(w, "clients", "blocked_clients"), "1")
		if f.reason == "" {
			expect_call(t, w, ":1\r\n", "CLIENT", "UNBLOCK", id_of(a))
		} else {
			expect_call(t, w, ":1\r\n", "CLIENT", "UNBLOCK", id_of(a), f.reason)
		}
		expect_reply(t, a, f.want)
		testing.expect_value(t, a.conn.blocked, eski.Block_Type.None)
		testing.expect_value(t, eski.block_by_type[f.btype], 0)
		expect_call(t, w, ":0\r\n", "CLIENT", "UNBLOCK", id_of(a))
		expect_call(t, a, "+PONG\r\n", "PING")
	}
	hello := call(a, "HELLO", "3")
	testing.expect(t, strings.has_prefix(hello, "%7\r\n"), hello)
	delete(hello)
	start_cmd(t, a, "BZPOPMIN", "z1", "0")
	expect_call(t, w, ":1\r\n", "CLIENT", "UNBLOCK", id_of(a))
	expect_reply(t, a, "_\r\n")
	expect_call(t, a, "_\r\n", "BLPOP", "l1", "0.02")
	disconnect(a)
	disconnect(w)
	idle_state(t)
}

@(test)
unblock_kill_and_disconnect_release_everything :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	expect_call(t, w, OK, "XGROUP", "CREATE", "gk", "g", "$", "MKSTREAM")
	clients: [6]^Client
	for i in 0 ..< 6 {
		clients[i] = connect()
	}
	start_cmd(t, clients[0], "BLPOP", "k1", "k2", "k3", "0")
	start_cmd(t, clients[1], "BZPOPMIN", "k2", "z9", "10")
	start_cmd(t, clients[2], "XREADGROUP", "GROUP", "g", "c", "BLOCK", "0", "STREAMS", "gk", ">")
	start_cmd(t, clients[3], "XREAD", "BLOCK", "5000", "STREAMS", "gk", "k1", "$", "$")
	start_cmd(t, clients[4], "BLMOVE", "k3", "dst", "LEFT", "RIGHT", "0")
	start_cmd(t, clients[5], "XREADGROUP", "GROUP", "g", "d", "BLOCK", "0", "STREAMS", "gk", ">")
	testing.expect_value(t, eski.block_count(), 6)
	testing.expect_value(t, eski.block_total_keys(), 5)
	testing.expect_value(t, eski.block_total_nokey_keys(), 1)
	testing.expect_value(t, eski.block_nokey_clients, 2)
	expect_call(t, w, ":1\r\n", "CLIENT", "KILL", "ID", id_of(clients[2]))
	pump(3, 2)
	testing.expect_value(t, eski.block_count(), 5)
	testing.expect_value(t, eski.block_total_nokey_keys(), 1)
	testing.expect_value(t, eski.block_nokey_clients, 1)
	expect_call(t, w, ":1\r\n", "CLIENT", "KILL", "ID", id_of(clients[5]))
	pump(3, 2)
	testing.expect_value(t, eski.block_total_nokey_keys(), 0)
	disconnect(clients[0])
	testing.expect_value(t, eski.block_count(), 3)
	testing.expect_value(t, eski.block_total_keys(), 5)
	disconnect(clients[4])
	testing.expect_value(t, eski.block_total_keys(), 4)
	disconnect(clients[1])
	disconnect(clients[3])
	testing.expect_value(t, info_field(w, "clients", "blocked_clients"), "0")
	testing.expect_value(t, info_field(w, "clients", "total_blocking_keys"), "0")
	disconnect(clients[2])
	disconnect(clients[5])
	disconnect(w)
	idle_state(t)
}

@(test)
unblock_multi_never_blocks :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	e := connect()
	expect_call(t, e, OK, "MULTI")
	for args in ([][]string{{"BLMOVE", "nolist", "d", "LEFT", "RIGHT", "0"}, {"BRPOPLPUSH", "nolist", "d", "0"}, {"BZPOPMIN", "noz", "0"}, {"BZMPOP", "0", "1", "noz", "MIN"}, {"BRPOP", "nolist", "0"}, {"BLMPOP", "0", "1", "nolist", "RIGHT", "COUNT", "2"}}) {
		expect_call(t, e, "+QUEUED\r\n", ..args)
	}
	expect_call(t, e, "*6\r\n$-1\r\n$-1\r\n*-1\r\n*-1\r\n*-1\r\n*-1\r\n", "EXEC")
	expect_call(t, w, ":2\r\n", "LPUSH", "xlist", "foo", "bar")
	expect_call(t, e, OK, "MULTI")
	for _ in 0 ..< 3 {
		expect_call(t, e, "+QUEUED\r\n", "BRPOPLPUSH", "xlist", "target", "0")
	}
	expect_call(t, e, "+QUEUED\r\n", "LRANGE", "target", "0", "-1")
	expect_call(t, e, "*4\r\n$3\r\nfoo\r\n$3\r\nbar\r\n$-1\r\n*2\r\n$3\r\nbar\r\n$3\r\nfoo\r\n", "EXEC")
	expect_call(t, w, ":2\r\n", "ZADD", "zs", "1", "a", "2", "b")
	expect_call(t, e, OK, "MULTI")
	expect_call(t, e, "+QUEUED\r\n", "BZPOPMAX", "zs", "0")
	expect_call(t, e, "+QUEUED\r\n", "BZMPOP", "0", "1", "zs", "MIN", "COUNT", "5")
	expect_call(t, e, "+QUEUED\r\n", "BZPOPMIN", "zs", "0")
	expect_call(t, e, "*3\r\n*3\r\n$2\r\nzs\r\n$1\r\nb\r\n$1\r\n2\r\n*2\r\n$2\r\nzs\r\n*1\r\n*2\r\n$1\r\na\r\n$1\r\n1\r\n*-1\r\n", "EXEC")
	testing.expect_value(t, eski.block_count(), 0)
	disconnect(e)
	disconnect(w)
	idle_state(t)
}

@(test)
unblock_reply_off_suppresses_served_and_timeout_replies :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	e := connect()
	send(e, "CLIENT", "REPLY", "OFF")
	pump(3, 2)
	start_cmd(t, e, "BLPOP", "rm", "0")
	expect_call(t, w, ":1\r\n", "RPUSH", "rm", "v")
	expect_silent(t, e)
	send(e, "BZPOPMIN", "rz", "0.03")
	expect_silent(t, e, 120)
	start_cmd(t, e, "XREAD", "BLOCK", "0", "STREAMS", "rs", "$")
	expect_call(t, w, ":1\r\n", "CLIENT", "UNBLOCK", id_of(e), "ERROR")
	expect_silent(t, e)
	expect_call(t, e, OK, "CLIENT", "REPLY", "ON")
	expect_call(t, w, ":0\r\n", "EXISTS", "rm")
	disconnect(e)
	disconnect(w)
	idle_state(t)
}

@(test)
unblock_statistics_count_each_blocked_command_once :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	a := connect()
	expect_call(t, w, OK, "CONFIG", "RESETSTAT")
	processed, _ := strconv.parse_int(info_field(w, "stats", "total_commands_processed"))
	start_cmd(t, a, "BLPOP", "mylist", "0")
	expect_call(t, w, ":1\r\n", "LPUSH", "mylist", "1")
	expect_reply(t, a, pair("mylist", "1"))
	now_processed, _ := strconv.parse_int(info_field(w, "stats", "total_commands_processed"))
	testing.expect_value(t, now_processed - processed, 3)
	stat := info_field(w, "commandstats", "cmdstat_blpop")
	testing.expectf(t, strings.has_prefix(stat, "calls=1,"), "served blpop stats %q", stat)
	start_cmd(t, a, "BLPOP", "mylist", "0")
	expect_call(t, w, ":1\r\n", "CLIENT", "UNBLOCK", id_of(a), "TIMEOUT")
	expect_reply(t, a, NULL_ARRAY)
	stat = info_field(w, "commandstats", "cmdstat_blpop")
	testing.expectf(t, strings.has_prefix(stat, "calls=2,") && strings.has_suffix(stat, "failed_calls=0"), "timed out blpop stats %q", stat)
	start_cmd(t, a, "BLPOP", "mylist", "0")
	expect_call(t, w, ":1\r\n", "CLIENT", "UNBLOCK", id_of(a), "ERROR")
	expect_reply(t, a, "-UNBLOCKED client unblocked via CLIENT UNBLOCK\r\n")
	stat = info_field(w, "commandstats", "cmdstat_blpop")
	testing.expectf(t, strings.has_prefix(stat, "calls=3,") && strings.has_suffix(stat, "rejected_calls=0,failed_calls=1"), "failed blpop stats %q", stat)
	testing.expect_value(t, info_field(w, "errorstats", "errorstat_UNBLOCKED"), "count=1")
	testing.expect_value(t, info_field(w, "stats", "total_error_replies"), "1")
	expect_call(t, w, OK, "XGROUP", "CREATE", "mystream", "mygroup", "$", "MKSTREAM")
	start_cmd(t, a, "XREADGROUP", "GROUP", "mygroup", "Alice", "BLOCK", "0", "STREAMS", "mystream", ">")
	expect_call(t, w, OK, "XGROUP", "SETID", "mystream", "mygroup", "$")
	testing.expect_value(t, a.conn.blocked, eski.Block_Type.Stream)
	expect_call(t, w, ":1\r\n", "XGROUP", "DESTROY", "mystream", "mygroup")
	expect_reply(t, a, "-NOGROUP No such key 'mystream' or consumer group 'mygroup' in XREADGROUP with GROUP option\r\n")
	stat = info_field(w, "commandstats", "cmdstat_xreadgroup")
	testing.expectf(t, strings.has_prefix(stat, "calls=1,") && strings.has_suffix(stat, "rejected_calls=0,failed_calls=1"), "xreadgroup stats %q", stat)
	testing.expect_value(t, info_field(w, "errorstats", "errorstat_NOGROUP"), "count=1")
	testing.expect_value(t, info_field(w, "stats", "total_error_replies"), "2")
	disconnect(a)
	disconnect(w)
	idle_state(t)
}

@(test)
unblock_monitor_sees_blocking_command_once :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	a := connect()
	m := connect()
	expect_call(t, m, OK, "MONITOR")
	start_cmd(t, a, "BLPOP", "mq", "0")
	expect_call(t, w, ":1\r\n", "RPUSH", "mq", "v")
	expect_reply(t, a, pair("mq", "v"))
	expect_call(t, w, "+PONG\r\n", "PING")
	lines: [dynamic]string
	defer delete(lines)
	start := time.tick_now()
	for len(lines) < 3 && elapsed_ms(start) < 1000 {
		r := reply(m, 100)
		if r != "" {
			append(&lines, r)
		}
	}
	testing.expect_value(t, len(lines), 3)
	blpops := 0
	for l in lines {
		if strings.contains(l, "\"BLPOP\"") {
			blpops += 1
		}
	}
	testing.expect_value(t, blpops, 1)
	if len(lines) == 3 {
		testing.expect(t, strings.contains(lines[0], "\"BLPOP\" \"mq\" \"0\""), lines[0])
		testing.expect(t, strings.contains(lines[1], "\"RPUSH\" \"mq\" \"v\""), lines[1])
		testing.expect(t, strings.contains(lines[2], "\"PING\""), lines[2])
	}
	for l in lines {
		delete(l)
	}
	disconnect(m)
	disconnect(a)
	disconnect(w)
	idle_state(t)
}

@(test)
unblock_lazyfree_hold_parks_and_resumes :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	a := connect()
	eski.lazyfree_block(a.conn)
	testing.expect_value(t, a.conn.blocked, eski.Block_Type.Lazyfree)
	send(a, "PING")
	expect_call(t, w, ":0\r\n", "CLIENT", "UNBLOCK", id_of(a))
	expect_reply(t, a, OK)
	expect_reply(t, a, "+PONG\r\n")
	testing.expect_value(t, a.conn.blocked, eski.Block_Type.None)
	testing.expect_value(t, eski.lazy_blocked, 0)
	b := connect()
	eski.lazyfree_block(b.conn)
	disconnect(b)
	testing.expect_value(t, eski.lazy_blocked, 0)
	expect_call(t, w, "+PONG\r\n", "PING")
	expect_call(t, w, OK, "CONFIG", "SET", "lazyfree-lazy-user-flush", "yes")
	expect_call(t, w, ":3\r\n", "RPUSH", "big", "a", "b", "c")
	raw := strings.concatenate({string(encode("FLUSHALL", "SYNC")), string(encode("PING"))}, context.temp_allocator)
	send_raw(a, transmute([]u8)raw)
	expect_reply(t, a, OK)
	expect_reply(t, a, "+PONG\r\n")
	expect_call(t, w, OK, "CONFIG", "SET", "lazyfree-lazy-user-flush", "no")
	disconnect(a)
	disconnect(w)
	idle_state(t)
}

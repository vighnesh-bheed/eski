package sortwork

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

@(private)
many :: proc(head: []string, count: int, format: string, pairs: bool = false) -> []string {
	out := make([dynamic]string, 0, len(head) + 2 * count, context.temp_allocator)
	append(&out, ..head)
	for i in 0 ..< count {
		if pairs {
			append(&out, fmt.tprintf("%d", i))
		}
		append(&out, fmt.tprintf(format, i))
	}
	return out[:]
}

@(private)
content_of :: proc(s: ^Session, key: string) -> string {
	if reply_text(call(s, "TYPE", key)) == "+set" {
		return call(s, "SORT", key, "ALPHA")
	}
	node, _, ok := resp_parse(call(s, "HGETALL", key))
	if !ok {
		return ""
	}
	pairs := make([dynamic]string, 0, len(node.items) / 2, context.temp_allocator)
	for i := 0; i + 1 < len(node.items); i += 2 {
		field := node.items[i].text
		ttl := reply_text(call(s, "HPEXPIRETIME", key, "FIELDS", "1", field))
		append(&pairs, strings.concatenate({field, "=", node.items[i + 1].text, "@", ttl}, context.temp_allocator))
	}
	slice.sort(pairs[:])
	return strings.join(pairs[:], ",", context.temp_allocator)
}

@(private)
int_reply :: proc(got: string) -> (v: int, ok: bool) {
	node, _, parsed := resp_parse(got)
	if !parsed || node.kind != .Int {
		return 0, false
	}
	return int(node.num), true
}

@(test)
copy_preserves_every_encoding :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "SET", "str_int", "12345")
	call(&s, "SET", "str_emb", "short value")
	call(&s, "SET", "str_raw", strings.repeat("r", 100, context.temp_allocator))
	call(&s, "SET", "str_big", strings.repeat("b", 70000, context.temp_allocator))
	call(&s, "SET", "str_bin", "a\x00b\xff\r\n")
	call(&s, "SETBIT", "bits", "1000", "1")
	call(&s, "PFADD", "hll", "a", "b", "c")
	call(&s, "RPUSH", "list_lp", "a", "b", "1", "-2")
	call(&s, ..many({"RPUSH", "list_ql"}, 2000, "value-%d"))
	call(&s, "SADD", "set_int", "1", "2", "3")
	call(&s, "SADD", "set_lp", "a", "b", "c")
	call(&s, ..many({"SADD", "set_ht"}, 700, "m%d"))
	call(&s, "ZADD", "zset_lp", "1", "a", "2.5", "b", "-inf", "c")
	call(&s, ..many({"ZADD", "zset_sl"}, 300, "m%d", true))
	call(&s, "HSET", "hash_lp", "f", "v", "n", "12")
	call(&s, "HSET", "hash_lpex", "f", "v", "g", "w")
	call(&s, "HPEXPIRE", "hash_lpex", "500000", "FIELDS", "1", "f")
	call(&s, ..many({"HSET", "hash_ht"}, 600, "v%d", true))
	call(&s, "HEXPIRE", "hash_ht", "9000", "FIELDS", "2", "1", "2")
	call(&s, "GEOADD", "geo", "13.361389", "38.115556", "Palermo")
	call(&s, "XADD", "stream", "1-1", "f", "v")
	call(&s, "XADD", "stream", "2-1", "f", "w")
	call(&s, "XGROUP", "CREATE", "stream", "g", "0")
	call(&s, "XREADGROUP", "GROUP", "g", "alice", "COUNT", "1", "STREAMS", "stream", ">")
	keys := []string{"str_int", "str_emb", "str_raw", "str_big", "str_bin", "bits", "hll", "list_lp", "list_ql", "set_int", "set_lp", "set_ht", "zset_lp", "zset_sl", "hash_lp", "hash_lpex", "hash_ht", "geo", "stream"}
	for key in keys {
		copy_key := strings.concatenate({key, "_copy"}, context.temp_allocator)
		expect_reply(t, &s, ":1", "COPY", key, copy_key)
		expect_reply(t, &s, ":1", "COPY", key, key, "DB", "4")
		testing.expectf(t, call(&s, "OBJECT", "ENCODING", copy_key) == call(&s, "OBJECT", "ENCODING", key), "%s: encoding changed", key)
		if key == "set_ht" || key == "hash_ht" {
			source := content_of(&s, key)
			testing.expectf(t, content_of(&s, copy_key) == source, "%s: copy in the same database holds different content", key)
			call(&s, "SELECT", "4")
			testing.expectf(t, content_of(&s, key) == source, "%s: copy in database 4 holds different content", key)
			call(&s, "SELECT", "0")
		} else {
			source_dump := call(&s, "DUMP", key)
			testing.expectf(t, call(&s, "DUMP", copy_key) == source_dump, "%s: copy in the same database dumps differently", key)
			call(&s, "SELECT", "4")
			testing.expectf(t, call(&s, "DUMP", key) == source_dump, "%s: copy in database 4 dumps differently", key)
			call(&s, "SELECT", "0")
		}
		free_all(context.temp_allocator)
	}
	call(&s, "APPEND", "str_emb_copy", "!")
	call(&s, "INCR", "str_int_copy")
	call(&s, "SETRANGE", "str_big_copy", "0", "zz")
	expect_reply(t, &s, `"short value"`, "GET", "str_emb")
	expect_reply(t, &s, `"12345"`, "GET", "str_int")
	expect_reply(t, &s, `"bb"`, "GETRANGE", "str_big", "0", "1")
	for key in keys {
		call(&s, "DEL", key)
	}
	expect_reply(t, &s, ":2000", "LLEN", "list_ql_copy")
	expect_reply(t, &s, ":700", "SCARD", "set_ht_copy")
	expect_reply(t, &s, `["m299"]`, "ZRANGE", "zset_sl_copy", "-1", "-1")
	expect_reply(t, &s, ":600", "HLEN", "hash_ht_copy")
	expect_reply(t, &s, ":3", "PFCOUNT", "hll_copy")
	expect_reply(t, &s, ":1", "BITCOUNT", "bits_copy")
	expect_reply(t, &s, ":2", "XLEN", "stream_copy")
}

@(test)
copy_streams_are_independent :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "XADD", "x", "1-1", "f", "v")
	call(&s, "XADD", "x", "2-1", "f", "w")
	call(&s, "XADD", "x", "3-1", "f", "u")
	call(&s, "XGROUP", "CREATE", "x", "g1", "0")
	call(&s, "XREADGROUP", "GROUP", "g1", "alice", "COUNT", "2", "STREAMS", "x", ">")
	pause(5)
	call(&s, "XREADGROUP", "GROUP", "g1", "bob", "COUNT", "1", "STREAMS", "x", ">")
	pause(5)
	call(&s, "XCLAIM", "x", "g1", "carol", "0", "1-1")
	call(&s, "XGROUP", "CREATE", "x", "g2", "$", "ENTRIESREAD", "3")
	call(&s, "XGROUP", "CREATECONSUMER", "x", "g2", "dave")
	pause(5)
	expect_reply(t, &s, ":1", "COPY", "x", "x2")
	full := call(&s, "XINFO", "STREAM", "x", "FULL")
	testing.expectf(t, call(&s, "XINFO", "STREAM", "x2", "FULL") == full, "copied stream state differs:\n%s\n%s", reply_text(full), reply_text(call(&s, "XINFO", "STREAM", "x2", "FULL")))
	pending_args := []string{"XPENDING", "x", "g1", "-", "+", "10"}
	copied, _, _ := resp_parse(call(&s, "XPENDING", "x2", "g1", "-", "+", "10"))
	source_pending, _, _ := resp_parse(call(&s, ..pending_args))
	normalize(pending_args, &copied)
	normalize(pending_args, &source_pending)
	testing.expectf(t, render(copied) == render(source_pending), "pending entries differ: %s vs %s", render(copied), render(source_pending))
	expect_reply(t, &s, ":1", "XACK", "x2", "g1", "1-1")
	expect_reply(t, &s, `[:3, "1-1", "3-1", [["alice", "1"], ["bob", "1"], ["carol", "1"]]]`, "XPENDING", "x", "g1")
	expect_reply(t, &s, `[:2, "2-1", "3-1", [["alice", "1"], ["bob", "1"]]]`, "XPENDING", "x2", "g1")
	call(&s, "XCLAIM", "x2", "g1", "erin", "0", "3-1")
	expect_reply(t, &s, `[:3, "1-1", "3-1", [["alice", "1"], ["bob", "1"], ["carol", "1"]]]`, "XPENDING", "x", "g1")
	expect_reply(t, &s, ":1", "XGROUP", "DESTROY", "x2", "g2")
	expect_reply(t, &s, `[["name", "g1", "consumers", :3, "pending", :3, "last-delivered-id", "3-1", "entries-read", :3, "lag", :0], ["name", "g2", "consumers", :1, "pending", :0, "last-delivered-id", "3-1", "entries-read", :3, "lag", :0]]`, "XINFO", "GROUPS", "x")
	call(&s, "XADD", "x", "4-1", "f", "z")
	expect_reply(t, &s, ":3", "XLEN", "x2")
	expect_reply(t, &s, ":1", "XGROUP", "DELCONSUMER", "x2", "g1", "alice")
	expect_reply(t, &s, `[["name", "g1", "consumers", :3, "pending", :3, "last-delivered-id", "3-1", "entries-read", :3, "lag", :1], ["name", "g2", "consumers", :1, "pending", :0, "last-delivered-id", "3-1", "entries-read", :3, "lag", :1]]`, "XINFO", "GROUPS", "x")
	call(&s, "DEL", "x")
	expect_reply(t, &s, `[["1-1", ["f", "v"]], ["2-1", ["f", "w"]], ["3-1", ["f", "u"]]]`, "XRANGE", "x2", "-", "+")
	expect_reply(t, &s, `[:1, "3-1", "3-1", [["erin", "1"]]]`, "XPENDING", "x2", "g1")
}

@(test)
copy_hash_field_expiry_is_independent :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	for big in ([]bool{false, true}) {
		call(&s, "FLUSHALL")
		call(&s, "HSET", "h", "a", "1", "b", "2", "c", "3")
		if big {
			call(&s, ..many({"HSET", "h"}, 600, "v%d", true))
		}
		call(&s, "HPEXPIRE", "h", "100000", "FIELDS", "1", "a")
		call(&s, "HPEXPIRE", "h", "40", "FIELDS", "1", "c")
		expect_reply(t, &s, ":1", "COPY", "h", "h2")
		ttl := reply_text(call(&s, "HPTTL", "h2", "FIELDS", "3", "a", "b", "c"))
		parsed, ok := note_parse(ttl)
		testing.expectf(t, ok && len(parsed.items) == 3 && parsed.items[0].num > 99000 && parsed.items[1].num == -1 && parsed.items[2].num > 0 && parsed.items[2].num <= 40, "field ttls on the copy: %s", ttl)
		expect_reply(t, &s, `[:1]`, "HPERSIST", "h2", "FIELDS", "1", "a")
		source_ttl := reply_text(call(&s, "HTTL", "h", "FIELDS", "1", "a"))
		testing.expectf(t, source_ttl == "[:100]" || source_ttl == "[:99]", "source field ttl after persisting the copy: %s", source_ttl)
		pause(70)
		expect_reply(t, &s, `["1"]`, "HMGET", "h2", "a")
		expect_reply(t, &s, `[nil]`, "HMGET", "h2", "c")
		expect_reply(t, &s, `[nil]`, "HMGET", "h", "c")
		expect_reply(t, &s, `["1"]`, "HMGET", "h", "a")
		call(&s, "DEL", "h")
		expect_reply(t, &s, `"2"`, "HGET", "h2", "b")
	}
}

@(test)
copy_expiry_and_replace :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2, "KEA")
	defer close_session(&s)
	call(&s, "SET", "s", "v", "EX", "100")
	expect_reply(t, &s, ":1", "COPY", "s", "t", "DB", "3")
	call(&s, "SELECT", "3")
	ttl, _ := int_reply(call(&s, "TTL", "t"))
	testing.expectf(t, ttl >= 99 && ttl <= 100, "ttl in db 3: %d", ttl)
	call(&s, "SELECT", "0")
	call(&s, "SET", "d", "x", "EX", "50")
	expect_reply(t, &s, ":1", "COPY", "s", "d", "REPLACE")
	ttl, _ = int_reply(call(&s, "TTL", "d"))
	testing.expectf(t, ttl >= 99 && ttl <= 100, "ttl after replace: %d", ttl)
	call(&s, "SET", "gone", "x", "PX", "1")
	take_events(&s)
	pause(20)
	expect_reply(t, &s, ":1", "COPY", "s", "gone")
	expect_events(t, &s, "__keyspace@0__:gone expired | __keyevent@0__:expired gone | __keyspace@0__:gone copy_to | __keyevent@0__:copy_to gone")
	call(&s, "SET", "src_gone", "x", "PX", "1")
	take_events(&s)
	pause(20)
	expect_reply(t, &s, ":0", "COPY", "src_gone", "fresh_key")
	expect_events(t, &s, "__keyspace@0__:src_gone expired | __keyevent@0__:expired src_gone")
	expect_reply(t, &s, ":0", "EXISTS", "fresh_key")
	call(&s, "RPUSH", "l", "a")
	call(&s, "SADD", "dst", "x")
	take_events(&s)
	expect_reply(t, &s, ":0", "COPY", "l", "dst")
	expect_events(t, &s, "")
	expect_reply(t, &s, ":1", "COPY", "l", "dst", "replace", "db", "0")
	expect_events(t, &s, "__keyspace@0__:dst copy_to | __keyevent@0__:copy_to dst")
	expect_reply(t, &s, "+list", "TYPE", "dst")
	expect_reply(t, &s, "-ERR DB index is out of range", "COPY", "l", "dst", "DB", "16", "BOGUS")
	expect_reply(t, &s, "-ERR DB index is out of range", "COPY", "l", "dst", "DB", "16", "DB", "1")
	expect_reply(t, &s, "-ERR syntax error", "COPY", "l", "dst", "BOGUS", "DB", "16")
	expect_reply(t, &s, "-ERR syntax error", "COPY", "l", "dst", "REPLACE", "DB")
	expect_reply(t, &s, "-ERR value is not an integer or out of range", "COPY", "l", "dst", "DB", " 1")
	expect_reply(t, &s, "-ERR value is not an integer or out of range", "COPY", "l", "dst", "DB", "1.0")
	expect_reply(t, &s, "-ERR value is out of range, value must between -2147483648 and 2147483647", "COPY", "l", "dst", "DB", "-2147483649")
	expect_reply(t, &s, "-ERR DB index is out of range", "COPY", "l", "dst", "DB", "-2147483648")
	expect_reply(t, &s, "-ERR source and destination objects are the same", "COPY", "l", "l", "DB", "3", "DB", "0")
	expect_reply(t, &s, ":1", "COPY", "l", "l", "DB", "0", "DB", "3")
	expect_events(t, &s, "__keyspace@3__:l copy_to | __keyevent@3__:copy_to l")
}

@(test)
copy_access_clock_restarts :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "CONFIG", "SET", "maxmemory-policy", "allkeys-lfu")
	call(&s, "SET", "hot", "v")
	for _ in 0 ..< 200 {
		call(&s, "GET", "hot")
	}
	freq, _ := int_reply(call(&s, "OBJECT", "FREQ", "hot"))
	testing.expectf(t, freq > 5, "source frequency %d", freq)
	expect_reply(t, &s, ":1", "COPY", "hot", "cold")
	expect_reply(t, &s, ":5", "OBJECT", "FREQ", "cold")
	expect_reply(t, &s, ":1", "COPY", "hot", "cold3", "DB", "3")
	call(&s, "SELECT", "3")
	expect_reply(t, &s, ":5", "OBJECT", "FREQ", "cold3")
	call(&s, "SELECT", "0")
	call(&s, "CONFIG", "SET", "maxmemory-policy", "noeviction")
}

@(test)
copy_wakes_blocked_clients :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "RPUSH", "src", "a", "b")
	list_waiter := wire_peer(&s)
	wire_send(list_waiter, "BLPOP", "dst", "0")
	testing.expect(t, wire_take(list_waiter) == "")
	expect_reply(t, &s, ":1", "COPY", "src", "dst")
	got := reply_text(wire_take(list_waiter))
	testing.expectf(t, got == `["dst", "a"]`, "list waiter got %s", got)
	expect_reply(t, &s, `["b"]`, "LRANGE", "dst", "0", "-1")
	expect_reply(t, &s, `["a", "b"]`, "LRANGE", "src", "0", "-1")
	other_db := wire_peer(&s)
	wire_send(other_db, "SELECT", "2")
	testing.expect(t, wire_take(other_db) == "+OK\r\n")
	wire_send(other_db, "BRPOP", "q", "0")
	testing.expect(t, wire_take(other_db) == "")
	expect_reply(t, &s, ":1", "COPY", "src", "q", "DB", "2")
	got = reply_text(wire_take(other_db))
	testing.expectf(t, got == `["q", "b"]`, "list waiter in db 2 got %s", got)
	call(&s, "ZADD", "zsrc", "1", "a", "2", "b")
	zset_waiter := wire_peer(&s)
	wire_send(zset_waiter, "BZPOPMIN", "zq", "0")
	testing.expect(t, wire_take(zset_waiter) == "")
	second := wire_peer(&s)
	wire_send(second, "BZPOPMIN", "zq", "0")
	testing.expect(t, wire_take(second) == "")
	expect_reply(t, &s, ":1", "COPY", "zsrc", "zq")
	got = reply_text(wire_take(zset_waiter))
	testing.expectf(t, got == `["zq", "a", "1"]`, "first zset waiter got %s", got)
	got = reply_text(wire_take(second))
	testing.expectf(t, got == `["zq", "b", "2"]`, "second zset waiter got %s", got)
	expect_reply(t, &s, ":0", "EXISTS", "zq")
	expect_reply(t, &s, ":2", "ZCARD", "zsrc")
}

@(test)
copy_invalidates_watch_in_target_database :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "SET", "s", "v")
	watcher := peer(&s)
	expect_reply_on(t, watcher, "+OK", "SELECT", "3")
	expect_reply_on(t, watcher, "+OK", "WATCH", "k")
	expect_reply(t, &s, ":1", "COPY", "s", "k", "DB", "3")
	expect_reply_on(t, watcher, "+OK", "MULTI")
	expect_reply_on(t, watcher, "+QUEUED", "GET", "k")
	expect_reply_on(t, watcher, "nil", "EXEC")
	expect_reply_on(t, watcher, "+OK", "WATCH", "k")
	expect_reply(t, &s, ":0", "COPY", "s", "k", "DB", "3")
	expect_reply_on(t, watcher, "+OK", "MULTI")
	expect_reply_on(t, watcher, "+QUEUED", "GET", "k")
	expect_reply_on(t, watcher, `["v"]`, "EXEC")
}

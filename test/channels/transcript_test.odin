package channels

import "core:fmt"
import "core:strings"
import "core:testing"
import j "../../src"

HELP_LINES :: [?]string {
	"PUBSUB <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
	"CHANNELS [<pattern>]",
	"    Return the currently active channels matching a <pattern> (default: '*').",
	"NUMPAT",
	"    Return number of subscriptions to patterns.",
	"NUMSUB [<channel> ...]",
	"    Return the number of subscribers for the specified channels, excluding",
	"    pattern subscriptions(default: no channels).",
	"SHARDCHANNELS [<pattern>]",
	"    Return the currently active shard level channels matching a <pattern> (default: '*').",
	"SHARDNUMSUB [<shardchannel> ...]",
	"    Return the number of subscribers for the specified shard level channel(s)",
	"HELP",
	"    Print this help.",
}

wrong_args :: proc(name: string) -> string {
	return errline(cat("ERR wrong number of arguments for '", name, "' command"))
}

@(test)
transcript_subscribe_publish_introspection :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := dial()
	p := dial()
	defer release(a)
	defer release(p)

	testing.expect_value(t, send(a, "SUBSCRIBE", "c1"), notice("subscribe", "c1", 1))
	testing.expect_value(t, send(a, "SUBSCRIBE", "c1", "c2"), cat(notice("subscribe", "c1", 1), notice("subscribe", "c2", 2)))
	testing.expect_value(t, send(a, "PSUBSCRIBE", "c*", "d?"), cat(notice("psubscribe", "c*", 3), notice("psubscribe", "d?", 4)))
	testing.expect_value(t, send(a, "SSUBSCRIBE", "s1"), notice("ssubscribe", "s1", 1))

	testing.expect_value(t, send(p, "PUBLISH", "c1", "m1"), ":2\r\n")
	testing.expect_value(t, recv(a), cat(message("c1", "m1"), pmessage("c*", "c1", "m1")))
	testing.expect_value(t, send(p, "PUBLISH", "c9", "m2"), ":1\r\n")
	testing.expect_value(t, recv(a), pmessage("c*", "c9", "m2"))
	testing.expect_value(t, send(p, "PUBLISH", "d1", "m3"), ":1\r\n")
	testing.expect_value(t, recv(a), pmessage("d?", "d1", "m3"))
	testing.expect_value(t, send(p, "PUBLISH", "zzz", "m4"), ":0\r\n")
	testing.expect_value(t, recv(a), "")
	testing.expect_value(t, send(p, "SPUBLISH", "s1", "sm1"), ":1\r\n")
	testing.expect_value(t, recv(a), smessage("s1", "sm1"))
	testing.expect_value(t, send(p, "SPUBLISH", "c1", "sm2"), ":0\r\n")
	testing.expect_value(t, recv(a), "")

	channels := send(p, "PUBSUB", "CHANNELS")
	testing.expect(t, strings.has_prefix(channels, "*2\r\n"))
	expect_same(t, sorted_items(channels), {"c1", "c2"})
	expect_same(t, sorted_items(send(p, "PUBSUB", "channels", "c*")), {"c1", "c2"})
	testing.expect_value(t, send(p, "PUBSUB", "CHANNELS", "c2"), "*1\r\n$2\r\nc2\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "CHANNELS", "nomatch*"), "*0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMSUB"), "*0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMSUB", "c1", "nope", "c2"), "*6\r\n$2\r\nc1\r\n:1\r\n$4\r\nnope\r\n:0\r\n$2\r\nc2\r\n:1\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMPAT"), ":2\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "SHARDCHANNELS"), "*1\r\n$2\r\ns1\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "SHARDCHANNELS", "s*"), "*1\r\n$2\r\ns1\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "SHARDCHANNELS", "c*"), "*0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "SHARDNUMSUB", "s1", "x"), "*4\r\n$2\r\ns1\r\n:1\r\n$1\r\nx\r\n:0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "SHARDNUMSUB"), "*0\r\n")

	lines := HELP_LINES
	help := strings.builder_make(context.temp_allocator)
	strings.write_string(&help, head(len(lines)))
	for line in lines {
		strings.write_string(&help, cat("+", line, "\r\n"))
	}
	testing.expect_value(t, send(p, "PUBSUB", "HELP"), strings.to_string(help))
	testing.expect_value(t, send(p, "pubsub", "help"), strings.to_string(help))
	testing.expect_value(t, send(p, "PUBSUB", "BOGUS"), errline("ERR unknown subcommand 'BOGUS'. Try PUBSUB HELP."))
	testing.expect_value(t, send(p, "PUBSUB"), wrong_args("pubsub"))
	testing.expect_value(t, send(p, "PUBSUB", "NUMPAT", "x"), wrong_args("pubsub|numpat"))
	testing.expect_value(t, send(p, "PUBSUB", "HELP", "x"), wrong_args("pubsub|help"))
	testing.expect_value(t, send(p, "PUBSUB", "CHANNELS", "a", "b"), errline("ERR unknown subcommand or wrong number of arguments for 'CHANNELS'. Try PUBSUB HELP."))
	testing.expect_value(t, send(p, "pubsub", "channels", "a", "b"), errline("ERR unknown subcommand or wrong number of arguments for 'channels'. Try PUBSUB HELP."))
	testing.expect_value(t, send(p, "pubsub", "chAnnels", "a", "b", "c"), errline("ERR unknown subcommand or wrong number of arguments for 'chAnnels'. Try PUBSUB HELP."))
	testing.expect_value(t, send(p, "PUBSUB", "SHARDCHANNELS", "a", "b"), errline("ERR unknown subcommand or wrong number of arguments for 'SHARDCHANNELS'. Try PUBSUB HELP."))
	testing.expect_value(t, send(p, "pubsub", "shardchannels", "a", "b"), errline("ERR unknown subcommand or wrong number of arguments for 'shardchannels'. Try PUBSUB HELP."))
	testing.expect_value(t, send(p, "pubsub", "numpat", "x"), wrong_args("pubsub|numpat"))
	testing.expect_value(t, send(p, "pubsub", "Help", "x"), wrong_args("pubsub|help"))

	list := bulk_body(send(p, "CLIENT", "LIST"))
	line_a := client_line(list, a.conn.id)
	line_p := client_line(list, p.conn.id)
	testing.expectf(t, strings.contains(line_a, " flags=P ") && strings.contains(line_a, " sub=2 psub=2 ssub=1 "), "subscriber line %q", line_a)
	testing.expectf(t, strings.contains(line_a, " cmd=ssubscribe "), "subscriber line %q", line_a)
	testing.expectf(t, strings.contains(line_p, " flags=N ") && strings.contains(line_p, " sub=0 psub=0 ssub=0 "), "publisher line %q", line_p)

	testing.expect_value(t, info_field(bulk_body(send(p, "INFO", "clients")), "pubsub_clients"), "1")
	stats := bulk_body(send(p, "INFO", "stats"))
	testing.expect_value(t, info_field(stats, "pubsub_channels"), "2")
	testing.expect_value(t, info_field(stats, "pubsub_patterns"), "2")
	testing.expect_value(t, info_field(stats, "pubsubshard_channels"), "1")
}

@(test)
transcript_subscribed_mode_resp2 :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := dial()
	p := dial()
	defer release(a)
	defer release(p)

	send(a, "SUBSCRIBE", "c1", "c2")
	send(a, "PSUBSCRIBE", "c*", "d?")
	send(a, "SSUBSCRIBE", "s1")
	testing.expect_value(t, send(a, "PING"), pong(""))
	testing.expect_value(t, send(a, "PING", "hi"), pong("hi"))
	testing.expect_value(t, send(a, "GET", "x"), reject("get"))
	testing.expect_value(t, send(a, "SET", "x", "1"), reject("set"))
	testing.expect_value(t, send(a, "PUBLISH", "c1", "x"), reject("publish"))
	testing.expect_value(t, send(a, "PUBSUB", "NUMPAT"), reject("pubsub|numpat"))
	testing.expect_value(t, send(a, "CLIENT", "ID"), reject("client|id"))
	testing.expect_value(t, send(a, "MULTI"), reject("multi"))
	testing.expect_value(t, send(a, "HELLO", "2"), reject("hello"))
	testing.expect_value(t, send(a, "SUBSCRIBE", "c3"), notice("subscribe", "c3", 5))
	testing.expect_value(t, send(a, "RESET"), "+RESET\r\n")
	testing.expect(t, .Subscribed not_in a.conn.ps)
	testing.expect_value(t, send(a, "GET", "x"), "$-1\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMSUB", "c1", "c3"), "*4\r\n$2\r\nc1\r\n:0\r\n$2\r\nc3\r\n:0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMPAT"), ":0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "SHARDNUMSUB", "s1"), "*2\r\n$2\r\ns1\r\n:0\r\n")

	send(a, "SUBSCRIBE", "q")
	testing.expect_value(t, send(a, "QUIT"), "+OK\r\n")
	if alive(a) {
		j.conn_read(a.conn)
	}
	testing.expect_value(t, send(p, "PUBLISH", "q", "after-quit"), ":0\r\n")
}

@(test)
transcript_unsubscribe_forms_and_counts :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := dial()
	defer release(a)

	testing.expect_value(t, send(a, "SUBSCRIBE", "u1", "u2"), cat(notice("subscribe", "u1", 1), notice("subscribe", "u2", 2)))
	testing.expect_value(t, send(a, "PSUBSCRIBE", "p1"), notice("psubscribe", "p1", 3))
	testing.expect_value(t, send(a, "UNSUBSCRIBE", "u1"), notice("unsubscribe", "u1", 2))
	testing.expect_value(t, send(a, "UNSUBSCRIBE", "notsubscribed"), notice("unsubscribe", "notsubscribed", 2))
	testing.expect_value(t, send(a, "UNSUBSCRIBE"), notice("unsubscribe", "u2", 1))
	testing.expect_value(t, send(a, "PUNSUBSCRIBE"), notice("punsubscribe", "p1", 0))
	testing.expect_value(t, send(a, "UNSUBSCRIBE"), "*3\r\n$11\r\nunsubscribe\r\n$-1\r\n:0\r\n")
	testing.expect_value(t, send(a, "PUNSUBSCRIBE", "none"), notice("punsubscribe", "none", 0))
	testing.expect_value(t, send(a, "SUNSUBSCRIBE"), notice_nil("sunsubscribe", 0))
	testing.expect_value(t, send(a, "GET", "x"), "$-1\r\n")

	testing.expect_value(t, send(a, "SUBSCRIBE", "k1"), notice("subscribe", "k1", 1))
	testing.expect_value(t, send(a, "PSUBSCRIBE", "k*"), notice("psubscribe", "k*", 2))
	testing.expect_value(t, send(a, "SSUBSCRIBE", "sk1"), notice("ssubscribe", "sk1", 1))
	testing.expect_value(t, send(a, "UNSUBSCRIBE", "k1"), notice("unsubscribe", "k1", 1))
	testing.expect_value(t, send(a, "PUNSUBSCRIBE", "k*"), notice("punsubscribe", "k*", 0))
	testing.expect(t, .Subscribed in a.conn.ps)
	testing.expect_value(t, send(a, "SUNSUBSCRIBE", "sk1"), notice("sunsubscribe", "sk1", 0))
	testing.expect_value(t, send(a, "PING"), "+PONG\r\n")
	testing.expect(t, .Subscribed not_in a.conn.ps)
}

@(test)
transcript_resp3_push :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	r := dial()
	p := dial()
	defer release(r)
	defer release(p)

	testing.expect(t, strings.has_prefix(send(r, "HELLO", "3"), "%"))
	testing.expect_value(t, r.conn.resp, 3)
	testing.expect_value(t, send(r, "SUBSCRIBE", "r1"), ">3\r\n$9\r\nsubscribe\r\n$2\r\nr1\r\n:1\r\n")
	testing.expect_value(t, send(r, "PSUBSCRIBE", "r*"), notice("psubscribe", "r*", 2, true))
	testing.expect_value(t, send(r, "SSUBSCRIBE", "rs"), notice("ssubscribe", "rs", 1, true))
	testing.expect_value(t, send(p, "PUBLISH", "r1", "hello"), ":2\r\n")
	testing.expect_value(t, recv(r), ">3\r\n$7\r\nmessage\r\n$2\r\nr1\r\n$5\r\nhello\r\n>4\r\n$8\r\npmessage\r\n$2\r\nr*\r\n$2\r\nr1\r\n$5\r\nhello\r\n")
	testing.expect_value(t, send(p, "SPUBLISH", "rs", "shello"), ":1\r\n")
	testing.expect_value(t, recv(r), smessage("rs", "shello", true))
	testing.expect_value(t, send(r, "PING"), "+PONG\r\n")
	testing.expect_value(t, send(r, "GET", "x"), "_\r\n")
	testing.expect_value(t, send(r, "SET", "x", "1"), "+OK\r\n")
	testing.expect_value(t, send(r, "PUBLISH", "r1", "self"), cat(":2\r\n", message("r1", "self", true), pmessage("r*", "r1", "self", true)))
	testing.expect_value(t, send(r, "UNSUBSCRIBE"), notice("unsubscribe", "r1", 1, true))
	testing.expect_value(t, send(r, "PUNSUBSCRIBE"), notice("punsubscribe", "r*", 0, true))
	testing.expect_value(t, send(r, "SUNSUBSCRIBE"), notice("sunsubscribe", "rs", 0, true))
	testing.expect_value(t, send(r, "UNSUBSCRIBE"), notice_nil("unsubscribe", 0, true))
	testing.expect(t, .Subscribed not_in r.conn.ps)

	send(r, "SUBSCRIBE", "foo")
	testing.expect_value(t, send(r, "MULTI"), "+OK\r\n")
	testing.expect_value(t, send(r, "PING", "abc"), "+QUEUED\r\n")
	testing.expect_value(t, send(r, "PUBLISH", "foo", "bar"), "+QUEUED\r\n")
	testing.expect_value(t, send(r, "PUBLISH", "foo", "vaz"), "+QUEUED\r\n")
	testing.expect_value(t, send(r, "PING", "def"), "+QUEUED\r\n")
	testing.expect_value(t, send(r, "EXEC"), cat("*4\r\n", bulk("abc"), ":1\r\n:1\r\n", bulk("def"), message("foo", "bar", true), message("foo", "vaz", true)))
	testing.expect_value(t, send(r, "DEL", "x"), ":1\r\n")
}

@(test)
transcript_duplicates_and_patterns :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	bc := dial()
	p := dial()
	defer release(bc)
	defer release(p)

	testing.expect_value(t, send(bc, "SUBSCRIBE", "d", "d", "d"), cat(notice("subscribe", "d", 1), notice("subscribe", "d", 1), notice("subscribe", "d", 1)))
	testing.expect_value(t, send(p, "PUBSUB", "NUMSUB", "d"), "*2\r\n$1\r\nd\r\n:1\r\n")
	testing.expect_value(t, send(p, "PUBLISH", "d", "x"), ":1\r\n")
	testing.expect_value(t, recv(bc), message("d", "x"))
	want := cat(notice("psubscribe", "*", 2), notice("psubscribe", "d", 3), notice("psubscribe", "[ab]c", 4), notice("psubscribe", "a\\*", 5))
	testing.expect_value(t, send(bc, "PSUBSCRIBE", "*", "d", "[ab]c", "a\\*"), want)
	testing.expect_value(t, send(p, "PUBLISH", "a*", "y"), ":2\r\n")
	expect_same(t, sorted_frames(recv(bc)), sorted_frames(cat(pmessage("a\\*", "a*", "y"), pmessage("*", "a*", "y"))))
	testing.expect_value(t, send(p, "PUBLISH", "bc", "z"), ":2\r\n")
	expect_same(t, sorted_frames(recv(bc)), sorted_frames(cat(pmessage("[ab]c", "bc", "z"), pmessage("*", "bc", "z"))))
	testing.expect_value(t, send(p, "PUBLISH", "", "empty"), ":0\r\n")
	testing.expect_value(t, recv(bc), "")
	testing.expect_value(t, send(p, "PUBSUB", "NUMPAT"), ":4\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "CHANNELS", "*"), "*1\r\n$1\r\nd\r\n")
	testing.expect_value(t, send(bc, "PUNSUBSCRIBE", "*"), notice("punsubscribe", "*", 4))
	testing.expect_value(t, send(p, "PUBSUB", "NUMPAT"), ":3\r\n")
	testing.expect_value(t, send(bc, "RESET"), "+RESET\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMPAT"), ":0\r\n")

	testing.expect_value(t, send(bc, "SUBSCRIBE", ""), notice("subscribe", "", 1))
	testing.expect_value(t, send(p, "PUBSUB", "CHANNELS"), "*1\r\n$0\r\n\r\n")
	testing.expect_value(t, send(p, "PUBLISH", "", "empty"), ":1\r\n")
	testing.expect_value(t, recv(bc), message("", "empty"))
}

@(test)
transcript_keyspace_notifications :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := dial()
	p := dial()
	defer release(a)
	defer release(p)

	testing.expect_value(t, send(a, "SUBSCRIBE", "__keyspace@0__:kk", "n1"), cat(notice("subscribe", "__keyspace@0__:kk", 1), notice("subscribe", "n1", 2)))
	testing.expect_value(t, send(a, "PSUBSCRIBE", "n*", "__keyevent@0__:*"), cat(notice("psubscribe", "n*", 3), notice("psubscribe", "__keyevent@0__:*", 4)))
	testing.expect_value(t, send(p, "CONFIG", "SET", "notify-keyspace-events", "KEA"), "+OK\r\n")
	testing.expect_value(t, send(p, "PUBLISH", "n1", "both"), ":2\r\n")
	testing.expect_value(t, recv(a), cat(message("n1", "both"), pmessage("n*", "n1", "both")))
	testing.expect_value(t, send(p, "SET", "kk", "v"), "+OK\r\n")
	testing.expect_value(t, recv(a), cat(message("__keyspace@0__:kk", "set"), pmessage("__keyevent@0__:*", "__keyevent@0__:set", "kk")))
	testing.expect_value(t, send(p, "CONFIG", "SET", "notify-keyspace-events", ""), "+OK\r\n")
	testing.expect_value(t, send(p, "DEL", "kk"), ":1\r\n")
	testing.expect_value(t, recv(a), "")
}

@(test)
transcript_cleanup_kill_disconnect :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := dial()
	p := dial()
	defer release(a)
	defer release(p)

	send(a, "SUBSCRIBE", "n1", "n2")
	send(a, "PSUBSCRIBE", "n*", "x*")
	send(a, "SSUBSCRIBE", "sn")
	testing.expect_value(t, send(p, "PUBSUB", "NUMSUB", "n1"), "*2\r\n$2\r\nn1\r\n:1\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMPAT"), ":2\r\n")
	testing.expect(t, j.ps_memory > 0)
	hangup(a)
	testing.expect(t, !alive(a), "a disconnect closes the connection")
	testing.expect_value(t, send(p, "PUBSUB", "NUMSUB", "n1"), "*2\r\n$2\r\nn1\r\n:0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMPAT"), ":0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "CHANNELS"), "*0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "SHARDCHANNELS"), "*0\r\n")
	testing.expect_value(t, j.ps_memory, 0)
	testing.expect_value(t, len(j.ps_conns), 0)

	c := dial()
	defer release(c)
	testing.expect_value(t, send(c, "SUBSCRIBE", "kill1"), notice("subscribe", "kill1", 1))
	testing.expect_value(t, send(p, "CLIENT", "KILL", "TYPE", "pubsub"), ":1\r\n")
	testing.expect(t, !alive(c), "the killed subscriber is closed")
	drain(c)
	testing.expect(t, peer_closed(c), "the killed subscriber's socket is closed")
	testing.expect_value(t, send(p, "PUBSUB", "NUMSUB", "kill1"), "*2\r\n$5\r\nkill1\r\n:0\r\n")
	testing.expect_value(t, send(p, "PUBLISH", "kill1", "late"), ":0\r\n")
}

@(test)
output_buffer_limit_kills_subscriber :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	p := dial()
	d := dial()
	defer release(p)
	defer release(d)

	default_limits := cat("*2\r\n", bulk("client-output-buffer-limit"), bulk("normal 0 0 0 slave 268435456 67108864 60 pubsub 33554432 8388608 60"))
	testing.expect_value(t, send(p, "CONFIG", "GET", "client-output-buffer-limit"), default_limits)
	testing.expect_value(t, send(p, "CONFIG", "SET", "client-output-buffer-limit", "pubsub 100000 0 0"), "+OK\r\n")
	testing.expect_value(t, send(d, "SUBSCRIBE", "big"), notice("subscribe", "big", 1))
	before := j.stat_obuf_disconnections
	big := strings.repeat("x", 50000, context.temp_allocator)
	delivered := 0
	for _ in 0 ..< 6 {
		reply := send(p, "PUBLISH", "big", big)
		if reply == ":1\r\n" {
			delivered += 1
		} else {
			testing.expect_value(t, reply, ":0\r\n")
		}
	}
	testing.expect(t, delivered >= 2 && delivered < 6, "the undrained subscriber is dropped once over the hard limit")
	testing.expect(t, !alive(d))
	testing.expect_value(t, j.stat_obuf_disconnections, before + 1)
	testing.expect_value(t, send(p, "PUBSUB", "NUMSUB", "big"), "*2\r\n$3\r\nbig\r\n:0\r\n")
	testing.expect_value(t, send(p, "CONFIG", "SET", "client-output-buffer-limit", "pubsub 32mb 8mb 60"), "+OK\r\n")
	testing.expect_value(t, send(p, "CONFIG", "GET", "client-output-buffer-limit"), default_limits)
}

@(test)
transcript_errors_and_arities :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	p := dial()
	e := dial()
	defer release(p)
	defer release(e)

	testing.expect_value(t, send(p, "PUBLISH"), wrong_args("publish"))
	testing.expect_value(t, send(p, "PUBLISH", "x"), wrong_args("publish"))
	testing.expect_value(t, send(p, "PUBLISH", "x", "y", "z"), wrong_args("publish"))
	testing.expect_value(t, send(p, "SUBSCRIBE"), wrong_args("subscribe"))
	testing.expect_value(t, send(p, "PSUBSCRIBE"), wrong_args("psubscribe"))
	testing.expect_value(t, send(p, "SSUBSCRIBE"), wrong_args("ssubscribe"))
	testing.expect_value(t, send(p, "SPUBLISH", "x"), wrong_args("spublish"))
	testing.expect_value(t, send(p, "UNSUBSCRIBE", "a", "b"), cat(notice("unsubscribe", "a", 0), notice("unsubscribe", "b", 0)))
	testing.expect_value(t, send(p, "SUNSUBSCRIBE", "a"), notice("sunsubscribe", "a", 0))
	testing.expect_value(t, send(p, "PUNSUBSCRIBE"), notice_nil("punsubscribe", 0))
	testing.expect_value(t, send(p, "GET", "x"), "$-1\r\n")
	testing.expect(t, .Subscribed not_in p.conn.ps)

	testing.expect_value(t, send(e, "SSUBSCRIBE", "sh1", "sh2"), cat(notice("ssubscribe", "sh1", 1), notice("ssubscribe", "sh2", 2)))
	testing.expect_value(t, send(e, "GET", "x"), reject("get"))
	testing.expect_value(t, send(e, "SUBSCRIBE", "reg"), notice("subscribe", "reg", 1))
	testing.expect_value(t, send(e, "PING"), pong(""))
	testing.expect_value(t, send(e, "SUNSUBSCRIBE", "sh1"), notice("sunsubscribe", "sh1", 1))
	testing.expect_value(t, send(e, "SUNSUBSCRIBE"), notice("sunsubscribe", "sh2", 0))
	testing.expect_value(t, send(e, "GET", "x"), reject("get"))
	testing.expect_value(t, send(e, "UNSUBSCRIBE"), notice("unsubscribe", "reg", 0))
	testing.expect_value(t, send(e, "GET", "x"), "$-1\r\n")
}

@(test)
transcript_multi_exec :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	f := dial()
	defer release(f)

	testing.expect_value(t, send(f, "SET", "x", "1"), "+OK\r\n")
	testing.expect_value(t, send(f, "MULTI"), "+OK\r\n")
	testing.expect_value(t, send(f, "SUBSCRIBE", "m1"), "+QUEUED\r\n")
	testing.expect_value(t, send(f, "PING"), "+QUEUED\r\n")
	testing.expect_value(t, send(f, "EXEC"), cat("*2\r\n", notice("subscribe", "m1", 1), pong("")))
	testing.expect_value(t, send(f, "GET", "x"), reject("get"))
	testing.expect_value(t, send(f, "UNSUBSCRIBE"), notice("unsubscribe", "m1", 0))
	testing.expect_value(t, send(f, "GET", "x"), "$1\r\n1\r\n")

	testing.expect_value(t, send(f, "MULTI"), "+OK\r\n")
	send(f, "PING")
	send(f, "SUBSCRIBE", "m2", "m3")
	send(f, "PING", "x")
	send(f, "UNSUBSCRIBE", "m2")
	testing.expect_value(t, send(f, "EXEC"), cat("*4\r\n+PONG\r\n", notice("subscribe", "m2", 1), notice("subscribe", "m3", 2), pong("x"), notice("unsubscribe", "m2", 1)))
	testing.expect(t, .Subscribed in f.conn.ps)
	testing.expect_value(t, send(f, "RESET"), "+RESET\r\n")
	testing.expect_value(t, send(f, "DEL", "x"), ":1\r\n")
}

@(test)
acl_channel_change_kills_subscriber :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := dial()
	k := dial()
	p := dial()
	defer release(a)
	defer release(k)
	defer release(p)

	send(a, "SUBSCRIBE", "news")
	send(a, "PSUBSCRIBE", "n*")
	send(k, "SSUBSCRIBE", "allowed-shard")
	testing.expect_value(t, send(p, "ACL", "SETUSER", "default", "resetchannels", "&allowed*"), "+OK\r\n")
	testing.expect(t, a.conn.close_after, "the revoked subscriber is scheduled for closing")
	testing.expect(t, !k.conn.close_after, "the permitted subscriber is not scheduled for closing")
	recv(a)
	recv(k)
	testing.expect(t, !alive(a), "a subscriber whose channels are no longer permitted is killed")
	testing.expect(t, alive(k), "a subscriber whose channels stay permitted survives")
	testing.expect_value(t, send(p, "ACL", "SETUSER", "default", "allchannels"), "+OK\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMSUB", "news"), "*2\r\n$4\r\nnews\r\n:0\r\n")
	testing.expect_value(t, send(p, "PUBSUB", "NUMPAT"), ":0\r\n")
	testing.expect_value(t, send(p, "SPUBLISH", "allowed-shard", "ok"), ":1\r\n")
	testing.expect_value(t, recv(k), smessage("allowed-shard", "ok"))
	testing.expect_value(t, send(k, "SUNSUBSCRIBE"), notice("sunsubscribe", "allowed-shard", 0))
}

@(test)
tracking_invalidation_reaches_subscriber :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	s := dial()
	c := dial()
	w := dial()
	defer release(s)
	defer release(c)
	defer release(w)

	testing.expect_value(t, send(s, "SUBSCRIBE", "__redis__:invalidate"), notice("subscribe", "__redis__:invalidate", 1))
	testing.expect_value(t, send(c, "CLIENT", "TRACKING", "on", "REDIRECT", fmt.tprintf("%d", s.conn.id)), "+OK\r\n")
	testing.expect_value(t, send(c, "GET", "foo"), "$-1\r\n")
	testing.expect_value(t, send(w, "SET", "foo", "bar"), "+OK\r\n")
	testing.expect_value(t, recv(s), cat(head(3), bulk("message"), bulk("__redis__:invalidate"), head(1), bulk("foo")))
	testing.expect_value(t, send(c, "CLIENT", "TRACKING", "off"), "+OK\r\n")
	testing.expect_value(t, send(w, "DEL", "foo"), ":1\r\n")
	testing.expect_value(t, recv(s), "")
	testing.expect_value(t, send(s, "UNSUBSCRIBE"), notice("unsubscribe", "__redis__:invalidate", 0))
}

execabort :: proc(name: string) -> string {
	return errline(cat("EXECABORT Transaction discarded because of: Can't execute '", name, j.PS_REJECT_TAIL))
}

@(test)
subscribed_exec_aborts_transaction :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	f := dial()
	g := dial()
	defer release(f)
	defer release(g)

	testing.expect_value(t, send(f, "MULTI"), "+OK\r\n")
	testing.expect_value(t, send(f, "SUBSCRIBE", "m1"), "+QUEUED\r\n")
	testing.expect_value(t, send(f, "EXEC"), cat("*1\r\n", notice("subscribe", "m1", 1)))
	testing.expect_value(t, send(f, "MULTI"), reject("multi"))
	testing.expect_value(t, send(f, "GET", "x"), reject("get"))
	testing.expect_value(t, send(f, "EXEC"), execabort("exec"))
	testing.expect_value(t, f.conn.txf, bit_set[j.Tx_Flag;u8]{})
	testing.expect(t, .Subscribed in f.conn.ps)
	testing.expect_value(t, send(f, "UNSUBSCRIBE"), notice("unsubscribe", "m1", 0))
	testing.expect_value(t, send(f, "EXEC"), errline("ERR EXEC without MULTI"))
	testing.expect_value(t, send(f, "GET", "x"), "$-1\r\n")

	testing.expect_value(t, send(g, "SUBSCRIBE", "q"), notice("subscribe", "q", 1))
	j.cmd_multi(g.conn, words("MULTI"))
	testing.expect_value(t, recv(g), "+OK\r\n")
	testing.expect_value(t, g.conn.txf, bit_set[j.Tx_Flag;u8]{.Multi})
	testing.expect_value(t, send(g, "GET", "x"), reject("get"))
	testing.expect_value(t, g.conn.txf, bit_set[j.Tx_Flag;u8]{.Multi, .Dirty_Exec})
	testing.expect_value(t, send(g, "CLIENT", "NOPE"), errline("ERR unknown subcommand 'NOPE'. Try CLIENT HELP."))
	testing.expect_value(t, send(g, "PING"), "+QUEUED\r\n")
	testing.expect_value(t, send(g, "DISCARD"), reject("discard"))
	testing.expect_value(t, send(g, "EXEC"), execabort("exec"))
	testing.expect_value(t, g.conn.txf, bit_set[j.Tx_Flag;u8]{})
	testing.expect_value(t, j.tx_multi_count, 0)
	testing.expect(t, .Subscribed in g.conn.ps)
	testing.expect_value(t, send(g, "PING"), pong(""))
	testing.expect_value(t, send(g, "UNSUBSCRIBE"), notice("unsubscribe", "q", 0))
	testing.expect_value(t, send(g, "GET", "x"), "$-1\r\n")
}

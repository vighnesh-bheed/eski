package channels

import "core:strings"
import "core:testing"
import j "../../src"

@(test)
notice_bytes_resp2 :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := fake()
	defer fake_free(a)

	j.cmd_subscribe(a, words("SUBSCRIBE", "c1"))
	testing.expect_value(t, take(a), notice("subscribe", "c1", 1))
	testing.expect(t, .Subscribed in a.ps)
	testing.expect_value(t, len(j.ps_conns), 1)
	j.cmd_subscribe(a, words("SUBSCRIBE", "c1", "c2"))
	testing.expect_value(t, take(a), cat(notice("subscribe", "c1", 1), notice("subscribe", "c2", 2)))
	j.cmd_psubscribe(a, words("PSUBSCRIBE", "c*", "d?"))
	testing.expect_value(t, take(a), cat(notice("psubscribe", "c*", 3), notice("psubscribe", "d?", 4)))
	j.cmd_ssubscribe(a, words("SSUBSCRIBE", "s1"))
	testing.expect_value(t, take(a), notice("ssubscribe", "s1", 1))
	testing.expect_value(t, take(a), "")

	j.cmd_unsubscribe(a, words("UNSUBSCRIBE", "nope"))
	testing.expect_value(t, take(a), notice("unsubscribe", "nope", 4))
	j.cmd_punsubscribe(a, words("PUNSUBSCRIBE"))
	testing.expect_value(t, take(a), cat(notice("punsubscribe", "c*", 3), notice("punsubscribe", "d?", 2)))
	j.cmd_unsubscribe(a, words("UNSUBSCRIBE"))
	testing.expect_value(t, take(a), cat(notice("unsubscribe", "c1", 1), notice("unsubscribe", "c2", 0)))
	testing.expect(t, .Subscribed in a.ps, "a shard subscription keeps subscribed mode")
	j.cmd_unsubscribe(a, words("UNSUBSCRIBE"))
	testing.expect_value(t, take(a), notice_nil("unsubscribe", 0))
	j.cmd_sunsubscribe(a, words("SUNSUBSCRIBE"))
	testing.expect_value(t, take(a), notice("sunsubscribe", "s1", 0))
	testing.expect(t, .Subscribed not_in a.ps)
	testing.expect_value(t, len(j.ps_conns), 0)
	j.cmd_sunsubscribe(a, words("SUNSUBSCRIBE"))
	testing.expect_value(t, take(a), notice_nil("sunsubscribe", 0))
	j.cmd_punsubscribe(a, words("PUNSUBSCRIBE", "none"))
	testing.expect_value(t, take(a), notice("punsubscribe", "none", 0))
	j.cmd_unsubscribe(a, words("UNSUBSCRIBE", "a", "b"))
	testing.expect_value(t, take(a), cat(notice("unsubscribe", "a", 0), notice("unsubscribe", "b", 0)))
	testing.expect(t, .Subscribed not_in a.ps)
	testing.expect(t, j.ps_exec == nil)
}

@(test)
notice_bytes_resp3 :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	r := fake(3)
	defer fake_free(r)

	j.cmd_subscribe(r, words("SUBSCRIBE", "r1"))
	testing.expect_value(t, take(r), ">3\r\n$9\r\nsubscribe\r\n$2\r\nr1\r\n:1\r\n")
	testing.expect_value(t, take(r), "")
	j.cmd_psubscribe(r, words("PSUBSCRIBE", "r*"))
	testing.expect_value(t, take(r), ">3\r\n$10\r\npsubscribe\r\n$2\r\nr*\r\n:2\r\n")
	j.cmd_ssubscribe(r, words("SSUBSCRIBE", "rs"))
	testing.expect_value(t, take(r), notice("ssubscribe", "rs", 1, true))
	j.cmd_unsubscribe(r, words("UNSUBSCRIBE"))
	testing.expect_value(t, take(r), notice("unsubscribe", "r1", 1, true))
	j.cmd_punsubscribe(r, words("PUNSUBSCRIBE"))
	testing.expect_value(t, take(r), notice("punsubscribe", "r*", 0, true))
	j.cmd_sunsubscribe(r, words("SUNSUBSCRIBE"))
	testing.expect_value(t, take(r), notice("sunsubscribe", "rs", 0, true))
	j.cmd_unsubscribe(r, words("UNSUBSCRIBE"))
	testing.expect_value(t, take(r), ">3\r\n$11\r\nunsubscribe\r\n_\r\n:0\r\n")
	j.cmd_punsubscribe(r, words("PUNSUBSCRIBE"))
	testing.expect_value(t, take(r), notice_nil("punsubscribe", 0, true))
	testing.expect(t, .Subscribed not_in r.ps)
}

@(test)
message_bytes_both_protocols :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	r2 := fake(2)
	r3 := fake(3)
	p := fake(2)
	defer fake_free(r2)
	defer fake_free(r3)
	defer fake_free(p)

	for c in ([]^j.Conn{r2, r3}) {
		j.cmd_subscribe(c, words("SUBSCRIBE", "chan"))
		j.cmd_psubscribe(c, words("PSUBSCRIBE", "ch*"))
		j.cmd_ssubscribe(c, words("SSUBSCRIBE", "chan"))
		take(c)
	}

	j.cmd_publish(p, words("PUBLISH", "chan", "hello"))
	testing.expect_value(t, take(p), ":4\r\n")
	testing.expect_value(t, take(r2), "*3\r\n$7\r\nmessage\r\n$4\r\nchan\r\n$5\r\nhello\r\n*4\r\n$8\r\npmessage\r\n$3\r\nch*\r\n$4\r\nchan\r\n$5\r\nhello\r\n")
	testing.expect_value(t, take(r3), ">3\r\n$7\r\nmessage\r\n$4\r\nchan\r\n$5\r\nhello\r\n>4\r\n$8\r\npmessage\r\n$3\r\nch*\r\n$4\r\nchan\r\n$5\r\nhello\r\n")

	j.cmd_spublish(p, words("SPUBLISH", "chan", "sm"))
	testing.expect_value(t, take(p), ":2\r\n")
	testing.expect_value(t, take(r2), smessage("chan", "sm"))
	testing.expect_value(t, take(r3), smessage("chan", "sm", true))

	j.cmd_spublish(p, words("SPUBLISH", "chx", "none"))
	testing.expect_value(t, take(p), ":0\r\n")
	j.cmd_publish(p, words("PUBLISH", "chx", "pat"))
	testing.expect_value(t, take(p), ":2\r\n")
	testing.expect_value(t, take(r2), pmessage("ch*", "chx", "pat"))
	testing.expect_value(t, take(r3), pmessage("ch*", "chx", "pat", true))
	j.cmd_publish(p, words("PUBLISH", "zzz", "m4"))
	testing.expect_value(t, take(p), ":0\r\n")
	testing.expect_value(t, take(r2), "")
	testing.expect_value(t, take(r3), "")

	odd := "a\r\nb\x00c$*>"
	j.cmd_publish(p, words("PUBLISH", "chan", odd))
	testing.expect_value(t, take(p), ":4\r\n")
	testing.expect_value(t, take(r2), cat(message("chan", odd), pmessage("ch*", "chan", odd)))
	testing.expect_value(t, take(r3), cat(message("chan", odd, true), pmessage("ch*", "chan", odd, true)))
	j.cmd_publish(p, words("PUBLISH", "chan", ""))
	testing.expect_value(t, take(r2), cat(message("chan", ""), pmessage("ch*", "chan", "")))
	take(r3)
	take(p)

	big := strings.repeat("x", 200000, context.temp_allocator)
	testing.expect_value(t, j.pubsub_publish(u8s("chan"), u8s(big)), 4)
	testing.expect_value(t, take(r2), cat(message("chan", big), pmessage("ch*", "chan", big)))
	testing.expect_value(t, take(r3), cat(message("chan", big, true), pmessage("ch*", "chan", big, true)))
	testing.expect_value(t, j.ps_publish(u8s("chan"), u8s("k"), .Channel), 4)
	testing.expect_value(t, j.ps_publish(u8s("chan"), u8s("k"), .Shard), 2)
	take(r2)
	take(r3)

	j.pubsub_reset(r2)
	j.pubsub_reset(r3)
	testing.expect(t, .Subscribed not_in r2.ps && .Subscribed not_in r3.ps)
	j.cmd_publish(p, words("PUBLISH", "chan", "gone"))
	testing.expect_value(t, take(p), ":0\r\n")
	testing.expect_value(t, take(r2), "")
}

@(test)
pattern_matching_cases :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	sub := fake()
	other := fake()
	p := fake()
	defer fake_free(sub)
	defer fake_free(other)
	defer fake_free(p)

	j.cmd_subscribe(sub, words("SUBSCRIBE", "d", "d", "d"))
	testing.expect_value(t, take(sub), cat(notice("subscribe", "d", 1), notice("subscribe", "d", 1), notice("subscribe", "d", 1)))
	testing.expect_value(t, len(j.ps_maps[.Channel]["d"].subs), 1)
	j.cmd_publish(p, words("PUBLISH", "d", "x"))
	testing.expect_value(t, take(p), ":1\r\n")
	testing.expect_value(t, take(sub), message("d", "x"))

	j.cmd_psubscribe(sub, words("PSUBSCRIBE", "*", "d", "[ab]c", "a\\*"))
	want := cat(notice("psubscribe", "*", 2), notice("psubscribe", "d", 3), notice("psubscribe", "[ab]c", 4), notice("psubscribe", "a\\*", 5))
	testing.expect_value(t, take(sub), want)

	j.cmd_publish(p, words("PUBLISH", "a*", "y"))
	testing.expect_value(t, take(p), ":2\r\n")
	expect_same(t, sorted_frames(take(sub)), sorted_frames(cat(pmessage("a\\*", "a*", "y"), pmessage("*", "a*", "y"))))
	j.cmd_publish(p, words("PUBLISH", "bc", "z"))
	testing.expect_value(t, take(p), ":2\r\n")
	expect_same(t, sorted_frames(take(sub)), sorted_frames(cat(pmessage("[ab]c", "bc", "z"), pmessage("*", "bc", "z"))))
	j.cmd_publish(p, words("PUBLISH", "", "empty"))
	testing.expect_value(t, take(p), ":0\r\n")
	testing.expect_value(t, take(sub), "")
	j.cmd_publish(p, words("PUBLISH", "ab", "q"))
	testing.expect_value(t, take(p), ":1\r\n")
	testing.expect_value(t, take(sub), pmessage("*", "ab", "q"))

	j.cmd_publish(p, words("PUBLISH", "d", "both"))
	testing.expect_value(t, take(p), ":3\r\n")
	got := frames(take(sub))
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0], message("d", "both"))
		expect_same(t, sorted_frames(cat(got[1], got[2])), sorted_frames(cat(pmessage("*", "d", "both"), pmessage("d", "d", "both"))))
	}

	testing.expect_value(t, len(j.ps_maps[.Pattern]), 4)
	j.cmd_psubscribe(other, words("PSUBSCRIBE", "*", "?"))
	take(other)
	testing.expect_value(t, len(j.ps_maps[.Pattern]), 5)
	testing.expect_value(t, len(j.ps_maps[.Pattern]["*"].subs), 2)
	j.cmd_publish(p, words("PUBLISH", "x", "one"))
	testing.expect_value(t, take(p), ":3\r\n")
	testing.expect_value(t, take(sub), pmessage("*", "x", "one"))
	expect_same(t, sorted_frames(take(other)), sorted_frames(cat(pmessage("*", "x", "one"), pmessage("?", "x", "one"))))

	j.cmd_subscribe(other, words("SUBSCRIBE", "a*"))
	take(other)
	j.cmd_publish(p, words("PUBLISH", "ab", "lit"))
	testing.expect_value(t, take(p), ":2\r\n")
	testing.expect_value(t, take(other), pmessage("*", "ab", "lit"))
	take(sub)
	j.cmd_publish(p, words("PUBLISH", "a*", "lit"))
	testing.expect_value(t, take(p), ":4\r\n")
	other_got := frames(take(other))
	testing.expect_value(t, len(other_got), 2)
	if len(other_got) == 2 {
		testing.expect_value(t, other_got[0], message("a*", "lit"))
		testing.expect_value(t, other_got[1], pmessage("*", "a*", "lit"))
	}
	expect_same(t, sorted_frames(take(sub)), sorted_frames(cat(pmessage("a\\*", "a*", "lit"), pmessage("*", "a*", "lit"))))

	j.cmd_punsubscribe(sub, words("PUNSUBSCRIBE", "*"))
	testing.expect_value(t, take(sub), notice("punsubscribe", "*", 4))
	testing.expect_value(t, len(j.ps_maps[.Pattern]), 5)
	j.cmd_punsubscribe(other, words("PUNSUBSCRIBE", "*"))
	take(other)
	testing.expect_value(t, len(j.ps_maps[.Pattern]), 4)
	j.pubsub_reset(sub)
	j.pubsub_reset(other)
}

@(test)
unsubscribe_all_ordering :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	c := fake()
	defer fake_free(c)

	j.cmd_subscribe(c, words("SUBSCRIBE", "x3", "x1", "x5", "x2", "x4"))
	j.cmd_psubscribe(c, words("PSUBSCRIBE", "p2", "p1"))
	j.cmd_ssubscribe(c, words("SSUBSCRIBE", "s2", "s1", "s3"))
	take(c)
	j.cmd_unsubscribe(c, words("UNSUBSCRIBE", "x5"))
	testing.expect_value(t, take(c), notice("unsubscribe", "x5", 6))
	j.cmd_sunsubscribe(c, words("SUNSUBSCRIBE", "s1"))
	testing.expect_value(t, take(c), notice("sunsubscribe", "s1", 2))

	j.cmd_unsubscribe(c, words("UNSUBSCRIBE"))
	want := cat(notice("unsubscribe", "x3", 5), notice("unsubscribe", "x1", 4), notice("unsubscribe", "x2", 3), notice("unsubscribe", "x4", 2))
	testing.expect_value(t, take(c), want)
	j.cmd_subscribe(c, words("SUBSCRIBE", "late"))
	testing.expect_value(t, take(c), notice("subscribe", "late", 3))
	j.cmd_punsubscribe(c, words("PUNSUBSCRIBE"))
	testing.expect_value(t, take(c), cat(notice("punsubscribe", "p2", 2), notice("punsubscribe", "p1", 1)))
	j.cmd_sunsubscribe(c, words("SUNSUBSCRIBE"))
	testing.expect_value(t, take(c), cat(notice("sunsubscribe", "s2", 1), notice("sunsubscribe", "s3", 0)))
	testing.expect(t, .Subscribed in c.ps)
	j.cmd_unsubscribe(c, words("UNSUBSCRIBE"))
	testing.expect_value(t, take(c), notice("unsubscribe", "late", 0))
	testing.expect(t, .Subscribed not_in c.ps)

	j.cmd_subscribe(c, words("SUBSCRIBE", "q1", "q2"))
	j.cmd_psubscribe(c, words("PSUBSCRIBE", "q*"))
	take(c)
	j.cmd_punsubscribe(c, words("PUNSUBSCRIBE"))
	testing.expect_value(t, take(c), notice("punsubscribe", "q*", 2))
	j.cmd_unsubscribe(c, words("UNSUBSCRIBE", "q2", "q1"))
	testing.expect_value(t, take(c), cat(notice("unsubscribe", "q2", 1), notice("unsubscribe", "q1", 0)))
	testing.expect(t, .Subscribed not_in c.ps)
}

@(test)
allowed_command_set :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	allowed := [?]string{"subscribe", "ssubscribe", "psubscribe", "unsubscribe", "sunsubscribe", "punsubscribe", "PING", "quit", "Reset"}
	denied := [?]string{"get", "set", "publish", "spublish", "pubsub", "client", "hello", "multi", "exec", "select", "echo", "auth"}
	for name in allowed {
		cmd := j.lookup_command(u8s(name))
		testing.expectf(t, cmd != nil && j.ps_allowed(cmd), "%s must be allowed", name)
	}
	for name in denied {
		cmd := j.lookup_command(u8s(name))
		testing.expectf(t, cmd != nil && !j.ps_allowed(cmd), "%s must be rejected", name)
	}
	testing.expect(t, !j.ps_allowed(nil))

	get := j.lookup_command(u8s("get"))
	ping := j.lookup_command(u8s("ping"))
	c := fake()
	defer fake_free(c)
	testing.expect(t, !j.pubsub_rejects(c, get))
	j.cmd_ssubscribe(c, words("SSUBSCRIBE", "only-shard"))
	take(c)
	testing.expect(t, j.pubsub_rejects(c, get))
	testing.expect(t, !j.pubsub_rejects(c, ping))
	c.resp = 3
	testing.expect(t, !j.pubsub_rejects(c, get))
	c.resp = 2
	j.ps_reject(c, get, words("GET", "x"))
	testing.expect_value(t, take(c), reject("get"))
	client := j.lookup_command(u8s("client"))
	j.ps_reject(c, client, words("CLIENT", "LIST"))
	testing.expect_value(t, take(c), reject("client|list"))
	j.ps_reject(c, client, words("CLIENT", "NOPE"))
	testing.expect_value(t, take(c), errline("ERR unknown subcommand 'NOPE'. Try CLIENT HELP."))
	j.ps_reject(c, client, words("CLIENT", "ID", "extra"))
	testing.expect_value(t, take(c), errline("ERR wrong number of arguments for 'client|id' command"))
	exec := j.lookup_command(u8s("exec"))
	j.ps_reject(c, exec, words("EXEC"))
	testing.expect_value(t, take(c), errline(cat("EXECABORT Transaction discarded because of: Can't execute 'exec", j.PS_REJECT_TAIL)))
	testing.expect_value(t, c.txf, bit_set[j.Tx_Flag;u8]{})
	j.cmd_sunsubscribe(c, words("SUNSUBSCRIBE"))
	take(c)
	testing.expect(t, !j.pubsub_rejects(c, get))
}

@(test)
publish_does_not_allocate :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	subs: [4]^j.Conn
	for &c, i in subs {
		c = fake(3 if i % 2 == 0 else 2)
		j.cmd_subscribe(c, words("SUBSCRIBE", "hot", "warm"))
		j.cmd_psubscribe(c, words("PSUBSCRIBE", "h*", "*t", "x?"))
		j.cmd_ssubscribe(c, words("SSUBSCRIBE", "hot"))
		take(c)
	}
	payload := strings.repeat("p", 512, context.temp_allocator)
	for _ in 0 ..< 4 {
		j.ps_publish(u8s("hot"), u8s(payload), .Channel)
		j.ps_publish(u8s("hot"), u8s(payload), .Shard)
		for c in subs {
			take(c)
		}
	}
	calls := suite_track.total_allocation_count
	delivered := 0
	for _ in 0 ..< 1000 {
		delivered += j.ps_publish(u8s("hot"), u8s(payload), .Channel)
		delivered += j.ps_publish(u8s("hot"), u8s(payload), .Shard)
		delivered += j.ps_publish(u8s("cold"), u8s(payload), .Channel)
		for c in subs {
			c.wpos = 0
			c.wlen = 0
		}
	}
	testing.expect_value(t, suite_track.total_allocation_count, calls)
	testing.expect_value(t, delivered, 1000 * (4 * 3 + 4 + 0))
	for c in subs {
		fake_free(c)
	}
}

package channels

import "core:testing"
import j "../../src"

entry_cost :: proc(name: string) -> int {
	return j.PS_ENTRY_OVERHEAD + len(name)
}

subscribers :: proc(kind: j.Ps_Kind, name: string) -> []^j.Conn {
	e := j.ps_maps[kind][name]
	if e == nil {
		return nil
	}
	return e.subs[:]
}

conn_entries :: proc(c: ^j.Conn, kind: j.Ps_Kind) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if c.pubsub != nil {
		for e in c.pubsub.lists[kind] {
			append(&out, string(e.name))
		}
	}
	return out[:]
}

@(test)
registry_counts_and_duplicates :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := fake()
	c := fake()
	defer fake_free(a)
	defer fake_free(c)

	testing.expect(t, j.ps_subscribe(a, .Channel, u8s("news")))
	testing.expect(t, !j.ps_subscribe(a, .Channel, u8s("news")))
	testing.expect(t, j.ps_subscribe(a, .Channel, u8s("")))
	testing.expect(t, j.ps_subscribe(a, .Channel, u8s("\x00\xff bin")))
	testing.expect(t, j.ps_subscribe(a, .Pattern, u8s("n*")))
	testing.expect(t, !j.ps_subscribe(a, .Pattern, u8s("n*")))
	testing.expect(t, j.ps_subscribe(a, .Shard, u8s("news")))
	testing.expect(t, j.ps_subscribe(c, .Channel, u8s("news")))
	testing.expect(t, j.ps_subscribe(c, .Pattern, u8s("n*")))

	testing.expect_value(t, j.ps_count(a, .Channel), 3)
	testing.expect_value(t, j.ps_count(a, .Pattern), 1)
	testing.expect_value(t, j.ps_count(a, .Shard), 1)
	testing.expect_value(t, j.ps_total(a), 4)
	testing.expect_value(t, j.ps_list_len(a, .Channel), 3)
	testing.expect_value(t, j.ps_list_len(a, .Shard), 1)
	testing.expect_value(t, j.ps_total(c), 2)

	testing.expect_value(t, len(j.ps_maps[.Channel]), 3)
	testing.expect_value(t, len(j.ps_maps[.Pattern]), 1)
	testing.expect_value(t, len(j.ps_maps[.Shard]), 1)
	testing.expect_value(t, len(j.ps_patterns), 1)

	subs := subscribers(.Channel, "news")
	testing.expect_value(t, len(subs), 2)
	testing.expect(t, len(subs) == 2 && subs[0] == a && subs[1] == c, "subscribers keep subscription order")
	testing.expect_value(t, len(subscribers(.Shard, "news")), 1)
	testing.expect_value(t, len(subscribers(.Channel, "")), 1)
	testing.expect_value(t, len(subscribers(.Channel, "\x00\xff bin")), 1)
	expect_same(t, conn_entries(a, .Channel), {"news", "", "\x00\xff bin"})

	testing.expect(t, j.ps_unsubscribe(a, .Channel, u8s("news")))
	testing.expect(t, !j.ps_unsubscribe(a, .Channel, u8s("news")))
	testing.expect(t, !j.ps_unsubscribe(a, .Channel, u8s("never")))
	testing.expect(t, !j.ps_unsubscribe(a, .Pattern, u8s("news")))
	testing.expect_value(t, len(subscribers(.Channel, "news")), 1)
	testing.expect_value(t, len(subscribers(.Shard, "news")), 1)
	expect_same(t, conn_entries(a, .Channel), {"", "\x00\xff bin"})

	none := fake()
	testing.expect(t, !j.ps_unsubscribe(none, .Channel, u8s("news")))
	testing.expect_value(t, j.ps_count(none, .Channel), 0)
	testing.expect_value(t, j.ps_list_len(none, .Pattern), 0)
	testing.expect_value(t, j.ps_unsubscribe_all(none, .Shard, false), 0)
	fake_free(none)

	testing.expect_value(t, j.ps_unsubscribe_all(a, .Channel, false), 2)
	testing.expect_value(t, j.ps_unsubscribe_all(a, .Pattern, false), 1)
	testing.expect_value(t, j.ps_unsubscribe_all(a, .Shard, false), 1)
	testing.expect_value(t, j.ps_total(a), 0)
	testing.expect_value(t, len(subscribers(.Pattern, "n*")), 1)
	testing.expect_value(t, j.ps_unsubscribe_all(c, .Channel, false), 1)
	testing.expect_value(t, j.ps_unsubscribe_all(c, .Pattern, false), 1)
}

@(test)
registry_memory_accounting :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := fake()
	c := fake()
	defer fake_free(a)
	defer fake_free(c)

	j.ps_subscribe(a, .Channel, u8s("alpha"))
	testing.expect_value(t, j.ps_memory, entry_cost("alpha") + j.PS_SUB_OVERHEAD)
	j.ps_subscribe(a, .Channel, u8s("alpha"))
	testing.expect_value(t, j.ps_memory, entry_cost("alpha") + j.PS_SUB_OVERHEAD)
	j.ps_subscribe(c, .Channel, u8s("alpha"))
	testing.expect_value(t, j.ps_memory, entry_cost("alpha") + 2 * j.PS_SUB_OVERHEAD)
	j.ps_subscribe(a, .Pattern, u8s("al*"))
	j.ps_subscribe(a, .Shard, u8s("alpha"))
	j.ps_subscribe(c, .Shard, u8s(""))
	want := entry_cost("alpha") + 2 * j.PS_SUB_OVERHEAD
	want += entry_cost("al*") + j.PS_SUB_OVERHEAD
	want += entry_cost("alpha") + j.PS_SUB_OVERHEAD
	want += entry_cost("") + j.PS_SUB_OVERHEAD
	testing.expect_value(t, j.ps_memory, want)

	j.ps_unsubscribe(a, .Channel, u8s("alpha"))
	want -= j.PS_SUB_OVERHEAD
	testing.expect_value(t, j.ps_memory, want)
	j.ps_unsubscribe(c, .Channel, u8s("alpha"))
	want -= entry_cost("alpha") + j.PS_SUB_OVERHEAD
	testing.expect_value(t, j.ps_memory, want)
	testing.expect(t, j.ps_maps[.Channel]["alpha"] == nil, "empty channel entries are forgotten")

	j.pubsub_reset(a)
	j.pubsub_reset(c)
	testing.expect_value(t, j.ps_memory, 0)
	testing.expect_value(t, len(j.ps_maps[.Shard]), 0)
	testing.expect_value(t, len(j.ps_patterns), 0)
}

@(test)
registry_pattern_list_order :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	a := fake()
	c := fake()
	defer fake_free(a)
	defer fake_free(c)

	for p in ([]string{"p1", "p2", "p3", "p4"}) {
		j.ps_subscribe(a, .Pattern, u8s(p))
	}
	j.ps_subscribe(c, .Pattern, u8s("p2"))
	j.ps_subscribe(c, .Pattern, u8s("p5"))
	order :: proc() -> []string {
		out := make([dynamic]string, context.temp_allocator)
		for e in j.ps_patterns {
			append(&out, string(e.name))
		}
		return out[:]
	}
	expect_same(t, order(), {"p1", "p2", "p3", "p4", "p5"})
	j.ps_unsubscribe(a, .Pattern, u8s("p2"))
	expect_same(t, order(), {"p1", "p2", "p3", "p4", "p5"})
	j.ps_unsubscribe(a, .Pattern, u8s("p3"))
	expect_same(t, order(), {"p1", "p2", "p4", "p5"})
	expect_same(t, conn_entries(a, .Pattern), {"p1", "p4"})
	j.pubsub_reset(c)
	expect_same(t, order(), {"p1", "p4"})
	j.pubsub_reset(a)
	testing.expect_value(t, len(j.ps_patterns), 0)
}

@(test)
registry_allocations_return_to_baseline :: proc(t: ^testing.T) {
	context.allocator = suite_allocator()
	session(t)
	conns: [6]^j.Conn
	for &c, i in conns {
		c = fake(3 if i % 2 == 1 else 2)
	}
	warm :: proc(conns: []^j.Conn) {
		for c in conns {
			j.ps_subscribe(c, .Channel, u8s("warm"))
			j.ps_subscribe(c, .Pattern, u8s("w*"))
			j.ps_subscribe(c, .Shard, u8s("warm"))
		}
		j.ps_publish(u8s("warm"), u8s("x"), .Channel)
		j.ps_publish(u8s("warm"), u8s("x"), .Shard)
		for c in conns {
			j.pubsub_reset(c)
			take(c)
		}
	}
	warm(conns[:])
	baseline := live_allocations()

	names := [?]string{"a", "bb", "", "news.sport", "news.tech", "x\x00y", "ccc", "dd"}
	for round in 0 ..< 3 {
		for c, i in conns {
			for n, k in names {
				if (i + k + round) % 3 != 0 {
					j.ps_subscribe(c, .Channel, u8s(n))
					j.ps_subscribe(c, .Shard, u8s(n))
				}
			}
			j.ps_subscribe(c, .Pattern, u8s("news.*"))
			j.ps_subscribe(c, .Pattern, u8s("*"))
			j.ps_subscribe(c, .Pattern, u8s("?"))
		}
		for n in names {
			j.ps_publish(u8s(n), u8s("payload"), .Channel)
			j.ps_publish(u8s(n), u8s("payload"), .Shard)
		}
		for c, i in conns {
			if i % 2 == 0 {
				j.ps_unsubscribe_all(c, .Channel, false)
				j.ps_unsubscribe(c, .Pattern, u8s("*"))
			} else {
				for n in names {
					j.ps_unsubscribe(c, .Shard, u8s(n))
				}
			}
			j.pubsub_reset(c)
			take(c)
		}
		testing.expect_value(t, j.ps_memory, 0)
		testing.expect_value(t, live_allocations(), baseline)
	}
	for c in conns {
		j.ps_subscribe(c, .Channel, u8s("left"))
		j.ps_subscribe(c, .Pattern, u8s("l*"))
	}
	for c in conns {
		fake_free(c)
	}
	testing.expect_value(t, j.ps_memory, 0)
	testing.expect_value(t, len(suite_track.bad_free_array), 0)
}

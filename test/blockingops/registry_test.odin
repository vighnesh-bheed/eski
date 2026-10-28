package blockingops

import "core:testing"
import eski "../../src"

@(private = "file")
fake_seq: i64

fake_conn :: proc(dbi := 0) -> ^eski.Conn {
	fake_seq += 1
	c := new(eski.Conn)
	c.id = (i64(1) << 40) + fake_seq
	c.db = &eski.dbs[dbi]
	return c
}

drop_fake :: proc(c: ^eski.Conn) {
	eski.block_conn_closed(c)
	free(c)
}

keys_of :: proc(names: ..string) -> [][]u8 {
	out := make([][]u8, len(names), context.temp_allocator)
	for n, i in names {
		out[i] = transmute([]u8)n
	}
	return out
}

waiters_of :: proc(dbi: int, key: string) -> []^eski.Conn {
	bk, ok := eski.block_keys[dbi][key]
	if !ok {
		return nil
	}
	return bk.waiters[:]
}

@(test)
registry_type_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, eski.block_type_of(.List), eski.Block_Type.List)
	testing.expect_value(t, eski.block_type_of(.Zset), eski.Block_Type.Zset)
	testing.expect_value(t, eski.block_type_of(.Stream), eski.Block_Type.Stream)
	testing.expect_value(t, eski.block_type_of(.String), eski.Block_Type.None)
	testing.expect_value(t, eski.block_type_of(.Set), eski.Block_Type.None)
	testing.expect_value(t, eski.block_type_of(.Hash), eski.Block_Type.None)
	testing.expect(t, !eski.block_in_reexecution())
}

@(test)
registry_register_dedup_and_release :: proc(t: ^testing.T) {
	context.allocator = begin()
	idle_state(t)
	c1 := fake_conn()
	c2 := fake_conn()
	eski.block_for_keys(c1, .List, keys_of("a", "b", "a"), 0)
	testing.expect_value(t, c1.blocked, eski.Block_Type.List)
	testing.expect_value(t, len(c1.bstate.keys), 2)
	testing.expect_value(t, c1.bstate.keys[0], "a")
	testing.expect_value(t, c1.bstate.keys[1], "b")
	testing.expect_value(t, len(waiters_of(0, "a")), 1)
	eski.block_for_keys(c2, .Stream, keys_of("b"), 0, true)
	testing.expect_value(t, eski.block_count(), 2)
	testing.expect_value(t, eski.block_total_keys(), 2)
	testing.expect_value(t, eski.block_total_nokey_keys(), 1)
	testing.expect_value(t, eski.block_nokey_clients, 1)
	testing.expect_value(t, eski.block_work, 2)
	testing.expect_value(t, eski.block_by_type[.List], 1)
	testing.expect_value(t, eski.block_by_type[.Stream], 1)
	w := waiters_of(0, "b")
	testing.expect_value(t, len(w), 2)
	testing.expect(t, w[0] == c1 && w[1] == c2, "waiters keep blocking order")
	eski.block_for_keys(c1, .List, keys_of("z"), 0)
	testing.expect_value(t, len(c1.bstate.keys), 2)
	drop_fake(c1)
	testing.expect_value(t, len(waiters_of(0, "a")), 0)
	_, a_present := eski.block_keys[0]["a"]
	testing.expect(t, !a_present, "key with no waiters is freed")
	testing.expect_value(t, len(waiters_of(0, "b")), 1)
	testing.expect_value(t, eski.block_total_keys(), 1)
	testing.expect_value(t, eski.block_count(), 1)
	drop_fake(c2)
	idle_state(t)
}

@(test)
registry_signal_gating_and_ready_queue :: proc(t: ^testing.T) {
	context.allocator = begin()
	idle_state(t)
	c := fake_conn(1)
	eski.block_for_keys(c, .List, keys_of("k"), 0)
	eski.block_signal_key(&eski.dbs[1], transmute([]u8)string("k"), .Zset)
	testing.expect_value(t, len(eski.block_ready), 0)
	eski.block_signal_key(&eski.dbs[0], transmute([]u8)string("k"), .List)
	testing.expect_value(t, len(eski.block_ready), 0)
	eski.block_signal_key(&eski.dbs[1], transmute([]u8)string("other"), .List)
	testing.expect_value(t, len(eski.block_ready), 0)
	eski.block_signal_key(&eski.dbs[1], transmute([]u8)string("k"), .List)
	eski.block_signal_key(&eski.dbs[1], transmute([]u8)string("k"), .List)
	testing.expect_value(t, len(eski.block_ready), 1)
	testing.expect_value(t, eski.block_ready[0].db, 1)
	testing.expect_value(t, eski.block_ready[0].key, "k")
	testing.expect_value(t, eski.block_work, 2)
	testing.expect(t, eski.block_wait_ms(500) == 0, "pending ready keys make the loop poll")
	drop_fake(c)
	bk, kept := eski.block_keys[1]["k"]
	testing.expect(t, kept && bk.ready && len(bk.waiters) == 0, "ready key outlives its last waiter until served")
	testing.expect_value(t, eski.block_total_keys(), 0)
	eski.block_serve_ready()
	idle_state(t)
}

@(test)
registry_deadlines_bound_the_sleep :: proc(t: ^testing.T) {
	context.allocator = begin()
	idle_state(t)
	eski.update_clock()
	now := eski.srv.now_ms
	c1 := fake_conn()
	c2 := fake_conn()
	c3 := fake_conn()
	eski.block_for_keys(c1, .List, keys_of("d"), now + 500)
	testing.expect_value(t, eski.block_next_deadline, now + 500)
	eski.block_for_keys(c2, .Zset, keys_of("d"), now + 200)
	eski.block_for_keys(c3, .List, keys_of("d"), 0)
	testing.expect_value(t, eski.block_next_deadline, now + 200)
	testing.expect_value(t, eski.block_wait_ms(1000), 200)
	testing.expect_value(t, eski.block_wait_ms(50), 50)
	testing.expect_value(t, eski.block_wait_ms(-1), 200)
	saved := eski.srv.now_ms
	eski.srv.now_ms = now + 250
	testing.expect_value(t, eski.block_wait_ms(1000), 0)
	eski.srv.now_ms = saved
	drop_fake(c2)
	drop_fake(c1)
	drop_fake(c3)
	testing.expect_value(t, eski.block_wait_ms(1000), 200)
	eski.srv.now_ms = now + 250
	eski.block_handle_timeouts()
	eski.srv.now_ms = saved
	testing.expect_value(t, eski.block_next_deadline, 0)
	testing.expect_value(t, eski.block_wait_ms(1000), 1000)
	idle_state(t)
}

@(test)
registry_nokey_removal_and_scans :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	expect_call(t, w, OK, "SELECT", "3")
	expect_call(t, w, ":1\r\n", "RPUSH", "present", "v")
	expect_call(t, w, "$3\r\n1-1\r\n", "XADD", "stream", "1-1", "f", "v")
	expect_call(t, w, OK, "SELECT", "0")
	eski.block_note_removed()
	testing.expect(t, !eski.block_removed, "no nokey waiters, no recheck")
	lister := fake_conn(3)
	reader := fake_conn(3)
	eski.block_for_keys(lister, .List, keys_of("present", "absent"), 0)
	eski.block_for_keys(reader, .Stream, keys_of("stream", "gone"), 0, true)
	testing.expect_value(t, eski.block_total_nokey_keys(), 2)
	eski.block_note_removed()
	testing.expect(t, eski.block_removed, "nokey waiters arm the recheck")
	eski.block_check_removed()
	testing.expect(t, !eski.block_removed)
	testing.expect_value(t, len(eski.block_ready), 1)
	testing.expect_value(t, eski.block_ready[0].key, "gone")
	eski.block_scan_ready(&eski.dbs[3])
	names: [dynamic]string
	defer delete(names)
	for rk in eski.block_ready {
		append(&names, rk.key)
	}
	testing.expect_value(t, len(names), 3)
	has :: proc(names: []string, s: string) -> bool {
		for n in names {
			if n == s {
				return true
			}
		}
		return false
	}
	testing.expect(t, has(names[:], "present") && has(names[:], "stream") && has(names[:], "gone"), "scan queues present keys and nokey keys")
	testing.expect(t, !has(names[:], "absent"), "scan skips absent keys without nokey waiters")
	drop_fake(lister)
	drop_fake(reader)
	eski.block_serve_ready()
	eski.block_signal_existing(&eski.dbs[3], transmute([]u8)string("present"))
	testing.expect_value(t, len(eski.block_ready), 0)
	disconnect(w)
	idle_state(t)
}

@(test)
registry_signal_existing_uses_stored_type :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	expect_call(t, w, ":1\r\n", "SADD", "aset", "m")
	expect_call(t, w, ":1\r\n", "RPUSH", "alist", "m")
	c := fake_conn()
	eski.block_for_keys(c, .List, keys_of("aset", "alist", "nothing"), 0)
	eski.block_signal_existing(&eski.dbs[0], transmute([]u8)string("aset"))
	eski.block_signal_existing(&eski.dbs[0], transmute([]u8)string("nothing"))
	testing.expect_value(t, len(eski.block_ready), 0)
	eski.block_signal_existing(&eski.dbs[0], transmute([]u8)string("alist"))
	testing.expect_value(t, len(eski.block_ready), 1)
	drop_fake(c)
	eski.block_serve_ready()
	disconnect(w)
	idle_state(t)
}

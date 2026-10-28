package transactions

import "core:testing"
import j "../../src"

exec_ping :: proc(cl: Client) -> string {
	call(cl, "MULTI")
	call(cl, "PING")
	return call(cl, "EXEC")
}

PONG_ARRAY :: "*1\r\n+PONG\r\n"

NULL_ARRAY :: "*-1\r\n"

@(test)
watch_registration_and_counters :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	b := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(b)
	defer close_client(w)
	reset_server(w)
	keys := j.watch_total
	clients := j.watch_clients
	expect_call(t, a, "WATCH k1 k2 k1", "+OK\r\n")
	expect_call(t, a, "WATCH k2", "+OK\r\n")
	testing.expect_value(t, len(a.c.tx.watched), 2)
	testing.expect_value(t, j.watch_total, keys + 2)
	testing.expect_value(t, j.watch_clients, clients + 1)
	testing.expect(t, j.key_hooks)
	expect_call(t, b, "WATCH k2 k3", "+OK\r\n")
	testing.expect_value(t, j.watch_total, keys + 3)
	testing.expect_value(t, j.watch_clients, clients + 2)
	entry := j.watch_dbs[0]["k2"]
	testing.expect(t, entry != nil)
	testing.expect_value(t, len(entry.watchers), 2)
	for wt in entry.watchers {
		testing.expect_value(t, wt.c.tx.watched[wt.idx].key, "k2")
	}
	testing.expect_value(t, info_field(w, "clients", "watching_clients"), "2")
	testing.expect_value(t, info_field(w, "clients", "total_watched_keys"), "3")
	testing.expect_value(t, client_field(client_line(a, w), "watch"), "2")
	expect_call(t, a, "UNWATCH", "+OK\r\n")
	testing.expect_value(t, len(a.c.tx.watched), 0)
	testing.expect_value(t, j.watch_total, keys + 2)
	testing.expect_value(t, len(entry.watchers), 1)
	expect_call(t, b, "MULTI", "+OK\r\n")
	expect_call(t, b, "UNWATCH", "+QUEUED\r\n")
	expect_call(t, b, "EXEC", "*1\r\n+OK\r\n")
	testing.expect_value(t, j.watch_total, keys)
	testing.expect_value(t, j.watch_clients, clients)
	testing.expect(t, j.watch_dbs[0]["k2"] == nil)
	testing.expect_value(t, info_field(w, "clients", "watching_clients"), "0")
	testing.expect_value(t, info_field(w, "clients", "total_watched_keys"), "0")
}

@(test)
modifications_dirty_every_watcher :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	b := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(b)
	defer close_client(w)
	reset_server(w)
	Case :: struct {
		setup: string,
		write: string,
	}
	cases := [?]Case {
		{"SET wk seed", "SET wk seed"},
		{"SET wk seed", "SET wk 2"},
		{"SET wk seed", "EXPIRE wk 1000"},
		{"SET wk seed EX 100", "PERSIST wk"},
		{"SET wk seed", "APPEND wk x"},
		{"SET wk seed", "DEL wk"},
		{"SET wk seed", "RENAME wk wk2"},
		{"SET wk2 seed", "RENAME wk2 wk"},
		{"SET other seed", "RENAME other wk"},
		{"DEL wk", "LPUSH wk x"},
		{"SET wk seed", "UNLINK wk"},
		{"DEL wk", "HSET wk f v"},
		{"DEL wk", "SADD wk m"},
		{"DEL wk", "ZADD wk 1 m"},
		{"DEL wk", "XADD wk * f v"},
		{"SET wk seed", "SETBIT wk 0 1"},
		{"SET wk seed", "SETRANGE wk 0 x"},
		{"DEL wk", "PFADD wk a"},
		{"SET wk seed", "GETDEL wk"},
		{"SET wk 5", "INCRBY wk 0"},
		{"SET wk seed", "FLUSHDB"},
		{"SET wk seed", "FLUSHALL"},
	}
	for tc in cases {
		call(w, "DEL", "wk", "wk2", "other")
		call(w, ..split(tc.setup))
		call(a, "WATCH", "wk", "wk2")
		call(b, "WATCH", "wk")
		call(w, ..split(tc.write))
		testing.expectf(t, .Dirty_Cas in a.c.txf, "%s should dirty watcher a", tc.write)
		testing.expectf(t, .Dirty_Cas in b.c.txf, "%s should dirty watcher b", tc.write)
		testing.expectf(t, exec_ping(a) == NULL_ARRAY, "%s: exec a", tc.write)
		testing.expectf(t, exec_ping(b) == NULL_ARRAY, "%s: exec b", tc.write)
	}
	call(a, "WATCH", "wk")
	expect_call(t, a, "SET wk 3", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
}

@(test)
reads_and_misses_do_not_dirty :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	call(w, "SET", "wk", "1")
	call(a, "WATCH", "wk", "missing")
	for line in ([?]string{"GET wk", "EXISTS wk", "TTL wk", "DEL nonexist", "EXPIRE nonexist 10", "GET missing", "SET other 1", "DEL missing", "INCR other"}) {
		call(w, ..split(line))
	}
	testing.expect(t, a.c.txf == {})
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	testing.expect_value(t, len(a.c.tx.watched), 0)
	call(a, "WATCH", "missing")
	call(w, "SET", "missing", "1")
	call(w, "DEL", "missing")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
}

@(test)
dirty_clients_release_their_watches :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	keys := j.watch_total
	clients := j.watch_clients
	call(a, "WATCH", "x1", "x2", "x3")
	testing.expect_value(t, j.watch_total, keys + 3)
	call(w, "SET", "x2", "v")
	testing.expect(t, .Dirty_Cas in a.c.txf)
	testing.expect_value(t, len(a.c.tx.watched), 0)
	testing.expect_value(t, j.watch_total, keys)
	testing.expect_value(t, j.watch_clients, clients)
	testing.expect_value(t, client_field(client_line(a, w), "watch"), "0")
	expect_call(t, a, "WATCH x4", "+OK\r\n")
	testing.expect(t, .Dirty_Cas in a.c.txf)
	testing.expect_value(t, len(a.c.tx.watched), 0)
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	testing.expect(t, a.c.txf == {})
	testing.expect_value(t, j.watch_total, keys)
	call(a, "WATCH", "x1")
	call(w, "SET", "x1", "v")
	expect_call(t, a, "UNWATCH", "+OK\r\n")
	testing.expect(t, a.c.txf == {})
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
}

@(test)
watch_is_scoped_to_the_database :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	expect_call(t, a, "SELECT 3", "+OK\r\n")
	expect_call(t, a, "WATCH dbk", "+OK\r\n")
	testing.expect_value(t, a.c.tx.watched[0].db, 3)
	expect_call(t, w, "SET dbk 1", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	expect_call(t, a, "WATCH dbk", "+OK\r\n")
	expect_call(t, a, "SELECT 0", "+OK\r\n")
	expect_call(t, w, "SELECT 3", "+OK\r\n")
	expect_call(t, w, "SET dbk 2", "+OK\r\n")
	expect_call(t, w, "SELECT 0", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	expect_call(t, a, "WATCH mv", "+OK\r\n")
	expect_call(t, w, "SELECT 5", "+OK\r\n")
	expect_call(t, w, "SET mv 1", "+OK\r\n")
	expect_call(t, w, "MOVE mv 0", ":1\r\n")
	expect_call(t, w, "SELECT 0", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
}

@(test)
expiry_dirties_live_watched_keys :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	call(w, "SET", "ex", "1", "PX", "50")
	call(a, "WATCH", "ex")
	testing.expect(t, a.c.tx.watched[0].present)
	testing.expect(t, !a.c.tx.watched[0].expired)
	settle(80)
	testing.expect(t, j.watch_expired_since(a.c))
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	call(w, "SET", "ex2", "1", "PX", "50")
	call(a, "WATCH", "ex2")
	settle(80)
	expect_call(t, w, "GET ex2", "$-1\r\n")
	testing.expect(t, .Dirty_Cas in a.c.txf)
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	call(a, "WATCH", "ex3")
	call(w, "SET", "ex3", "1", "PX", "50")
	settle(80)
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	call(w, "SET", "ex4", "1", "PX", "50")
	call(a, "WATCH", "ex4")
	settle(80)
	for _ in 0 ..< 64 {
		j.db_active_expire()
	}
	exists, _ := j.db_key_state(&j.dbs[0], transmute([]u8)string("ex4"))
	testing.expect(t, !exists)
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	call(w, "SET", "ro", "1")
	call(a, "WATCH", "ro")
	expect_call(t, w, "GET ro", "$1\r\n1\r\n")
	expect_call(t, w, "EXPIRE ro 1000", ":1\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	call(w, "SET", "lv", "1", "EX", "100")
	call(a, "WATCH", "lv")
	settle(5)
	testing.expect(t, !j.watch_expired_since(a.c))
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
}

@(test)
stale_keys_do_not_dirty :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	saved := j.active_expire_enabled
	j.active_expire_enabled = false
	defer j.active_expire_enabled = saved
	call(w, "SET", "st", "1", "PX", "1")
	settle(10)
	call(a, "WATCH", "st")
	testing.expect(t, a.c.tx.watched[0].expired)
	testing.expect(t, !a.c.tx.watched[0].present)
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	call(w, "SET", "st", "1", "PX", "1")
	settle(10)
	call(a, "WATCH", "st")
	expect_call(t, w, "GET st", "$-1\r\n")
	testing.expect(t, a.c.txf == {})
	testing.expect(t, !a.c.tx.watched[0].expired)
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	call(w, "SET", "st", "1", "PX", "1")
	settle(10)
	call(a, "WATCH", "st")
	expect_call(t, w, "DEL st", ":0\r\n")
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	call(w, "SET", "st", "1", "PX", "1")
	settle(10)
	call(a, "WATCH", "st")
	call(w, "FLUSHDB")
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	call(w, "SET", "st", "1", "PX", "1")
	settle(10)
	call(a, "WATCH", "st")
	expect_call(t, w, "SET st 2", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	call(w, "SET", "st", "1", "PX", "1")
	settle(10)
	call(a, "WATCH", "st")
	call(w, "DEL", "st")
	expect_call(t, w, "SET st 3", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
}

@(test)
flush_dirties_existing_keys_only :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	expect_call(t, w, "SET fk 1", "+OK\r\n")
	expect_call(t, a, "WATCH fk", "+OK\r\n")
	expect_call(t, w, "FLUSHDB", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	expect_call(t, a, "WATCH fk", "+OK\r\n")
	expect_call(t, w, "FLUSHDB", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	expect_call(t, w, "SET fk 1", "+OK\r\n")
	expect_call(t, a, "WATCH fk", "+OK\r\n")
	expect_call(t, w, "FLUSHALL", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	expect_call(t, w, "SELECT 4", "+OK\r\n")
	expect_call(t, w, "SET fk 1", "+OK\r\n")
	expect_call(t, a, "WATCH fk", "+OK\r\n")
	expect_call(t, w, "FLUSHDB", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	expect_call(t, w, "SET fk 1", "+OK\r\n")
	expect_call(t, a, "WATCH fk", "+OK\r\n")
	expect_call(t, w, "FLUSHALL", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	expect_call(t, w, "SET fk 1", "+OK\r\n")
	expect_call(t, w, "SELECT 0", "+OK\r\n")
	expect_call(t, w, "SET fk 1", "+OK\r\n")
	expect_call(t, a, "SELECT 4", "+OK\r\n")
	expect_call(t, a, "WATCH fk", "+OK\r\n")
	expect_call(t, a, "SELECT 0", "+OK\r\n")
	expect_call(t, a, "WATCH fk", "+OK\r\n")
	expect_call(t, w, "FLUSHALL", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	call(w, "SET", "f1", "1")
	call(w, "SET", "f2", "1")
	call(a, "WATCH", "f1", "f2", "f3")
	j.watch_flush(nil)
	testing.expect(t, .Dirty_Cas in a.c.txf)
	testing.expect_value(t, len(a.c.tx.watched), 0)
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
}

@(test)
swapdb_dirties_keys_present_in_either_database :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(a)
	defer close_client(w)
	reset_server(w)
	saved := j.active_expire_enabled
	j.active_expire_enabled = false
	defer j.active_expire_enabled = saved
	expect_call(t, w, "SET sk 1", "+OK\r\n")
	expect_call(t, a, "WATCH sk", "+OK\r\n")
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	expect_call(t, a, "WATCH nosuch", "+OK\r\n")
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	call(w, "SELECT", "1")
	call(w, "SET", "arrive", "1")
	call(w, "SELECT", "0")
	expect_call(t, a, "WATCH arrive", "+OK\r\n")
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	call(w, "FLUSHALL")
	call(w, "SET", "stale0", "1", "PX", "1")
	call(w, "SELECT", "1")
	call(w, "SET", "stale1", "1", "PX", "1")
	call(w, "SET", "stale0", "1", "PX", "1")
	call(w, "SELECT", "0")
	settle(10)
	expect_call(t, a, "WATCH stale0 stale1", "+OK\r\n")
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	testing.expect(t, a.c.txf == {})
	for wk in a.c.tx.watched {
		testing.expectf(t, wk.expired, "%s should be flagged stale after the swap", wk.key)
	}
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	expect_call(t, w, "SELECT 2", "+OK\r\n")
	expect_call(t, w, "SET far 1", "+OK\r\n")
	expect_call(t, w, "SELECT 0", "+OK\r\n")
	expect_call(t, a, "WATCH far", "+OK\r\n")
	expect_call(t, w, "SWAPDB 1 2", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), PONG_ARRAY)
	call(w, "SET", "after", "1")
	expect_call(t, a, "WATCH after", "+OK\r\n")
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	expect_call(t, w, "SWAPDB 0 1", "+OK\r\n")
	expect_call(t, w, "SET after 2", "+OK\r\n")
	testing.expect_value(t, exec_ping(a), NULL_ARRAY)
}

@(test)
cleanup_on_reset_and_close :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	w := open_client()
	defer close_client(w)
	reset_server(w)
	keys := j.watch_total
	clients := j.watch_clients
	multis := j.tx_multi_count
	mem := j.tx_mem_total
	expect_wire(t, a, "WATCH i1 i2", "+OK\r\n")
	expect_wire(t, a, "MULTI", "+OK\r\n")
	expect_wire(t, a, "PING", "+QUEUED\r\n")
	testing.expect_value(t, j.tx_multi_count, multis + 1)
	testing.expect_value(t, j.watch_clients, clients + 1)
	expect_wire(t, a, "RESET", "+RESET\r\n")
	testing.expect(t, a.c.txf == {})
	testing.expect_value(t, j.tx_multi_count, multis)
	testing.expect_value(t, j.watch_total, keys)
	testing.expect_value(t, j.watch_clients, clients)
	testing.expect_value(t, j.tx_mem_total, mem)
	expect_wire(t, a, "EXEC", "-ERR EXEC without MULTI\r\n")
	expect_wire(t, a, "WATCH i1", "+OK\r\n")
	expect_wire(t, a, "MULTI", "+OK\r\n")
	expect_wire(t, a, "SET i1 1", "+QUEUED\r\n")
	testing.expect(t, a.c.tx != nil)
	close_client(a)
	testing.expect_value(t, j.tx_multi_count, multis)
	testing.expect_value(t, j.watch_total, keys)
	testing.expect_value(t, j.watch_clients, clients)
	testing.expect_value(t, j.tx_mem_total, mem)
	testing.expect_value(t, info_field(w, "clients", "watching_clients"), "0")
	testing.expect_value(t, info_field(w, "clients", "total_watched_keys"), "0")
	expect_call(t, w, "EXISTS i1", ":0\r\n")
	expect_call(t, w, "SET i1 1", "+OK\r\n")
}

@(test)
conn_closed_releases_state :: proc(t: ^testing.T) {
	context.allocator = boot()
	a := open_client()
	defer close_client(a)
	keys := j.watch_total
	multis := j.tx_multi_count
	call(a, "WATCH", "c1")
	call(a, "MULTI")
	call(a, "SET", "c1", "v")
	j.tx_conn_closed(a.c)
	testing.expect(t, a.c.tx == nil)
	testing.expect(t, a.c.txf == {})
	testing.expect_value(t, j.watch_total, keys)
	testing.expect_value(t, j.tx_multi_count, multis)
	j.tx_conn_closed(a.c)
	testing.expect(t, a.c.tx == nil)
	expect_call(t, a, "MULTI", "+OK\r\n")
	expect_call(t, a, "DISCARD", "+OK\r\n")
}

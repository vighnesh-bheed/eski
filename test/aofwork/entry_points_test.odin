package aofwork

import "base:runtime"
import "core:testing"
import j "../../src"

@(test)
external_entry_points_feed_records :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("entry-points")
	defer feed_off()
	j.db_cur = &j.dbs[0]
	j.aof_propagate_del(&j.dbs[2], transmute([]u8)string("evicted"), false)
	j.aof_propagate_del(&j.dbs[2], transmute([]u8)string("lazy"), true)
	expect_records(t, {"SELECT 2", "DEL evicted", "UNLINK lazy"})
	j.aof_mc_set(j.aof_bytes("mk"), j.aof_bytes("mv"), 0, false)
	j.aof_mc_set(j.aof_bytes("mk"), j.aof_bytes("mv"), 1793095251825, false)
	j.aof_mc_set(j.aof_bytes("mk"), j.aof_bytes("mv2"), 0, true)
	j.aof_mc_pexpireat(j.aof_bytes("mk"), 1793095251826)
	j.aof_mc_command(j.aof_bytes("DEL"), j.aof_bytes("mk"))
	expect_records(t, {"SELECT 0", "SET mk mv", "SET mk mv PXAT 1793095251825", "SET mk mv2 KEEPTTL", "PEXPIREAT mk 1793095251826", "DEL mk"})
	c := new_client(0)
	migrate := j.lookup_command(j.aof_bytes("migrate"))
	argv := [][]u8{j.aof_bytes("MIGRATE"), j.aof_bytes("h"), j.aof_bytes("1"), j.aof_bytes(""), j.aof_bytes("0"), j.aof_bytes("5"), j.aof_bytes("KEYS"), j.aof_bytes("a"), j.aof_bytes("b")}
	j.aof_cmd_begin(c, migrate, argv)
	j.aof_migrate_deleted(c, {j.aof_bytes("a"), j.aof_bytes("b")})
	c.wlen = 0
	j.aof_after_command(c, migrate, j.persist_cmd_flags(migrate), argv, 0)
	expect_records(t, {"DEL a b"})
	j.aof_cmd_begin(c, migrate, argv)
	j.aof_migrate_deleted(c, {})
	j.aof_after_command(c, migrate, j.persist_cmd_flags(migrate), argv, 0)
	expect_records(t, {})
	pf := j.lookup_command(j.aof_bytes("pfcount"))
	pfargv := [][]u8{j.aof_bytes("pfcount"), j.aof_bytes("x")}
	j.aof_cmd_begin(c, pf, pfargv)
	j.aof_emit(c, ..pfargv)
	j.aof_after_command(c, pf, j.persist_cmd_flags(pf), pfargv, 0)
	expect_records(t, {"pfcount x"})
	j.aof_defer_conn(c)
	j.aof_defer_conn(c)
	testing.expect_value(t, len(j.aof.deferred), 1)
	j.aof_before_sleep()
	testing.expect_value(t, len(j.aof.deferred), 0)
}

@(test)
expire_now_tracks_loading :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	j.update_clock()
	testing.expect_value(t, j.expire_now(), j.srv.now_ms)
	j.aof.loading = true
	testing.expect_value(t, j.expire_now(), 0)
	j.aof.loading = false
	j.aof.state = .Disabled
	j.aof.fd = -1
	j.aof_update_feed()
	testing.expect(t, !j.aof.feed)
	j.aof.state = .Awaiting_Base
	j.aof_update_feed()
	testing.expect(t, !j.aof.feed)
	j.aof.state = .Disabled
}

package aofwork

import "base:runtime"
import "core:strings"
import "core:testing"
import j "../../src"

@(test)
feed_selects_and_verbatim :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("feed-select")
	defer feed_off()
	c0 := new_client(0)
	c1 := new_client(1)
	run(c0, "set", "a", "1")
	run(c0, "rpush", "l", "x", "y")
	run(c0, "incr", "a")
	run(c1, "set", "b", "2")
	run(c1, "append", "b", "3")
	run(c0, "del", "nokey")
	run(c0, "get", "a")
	expect_records(t, {"SELECT 0", "set a 1", "rpush l x y", "incr a", "SELECT 1", "set b 2", "append b 3"})
	run(c1, "set", "b", "4")
	expect_records(t, {"set b 4"})
	j.aof.selected_db = -1
	run(c1, "set", "b", "5")
	expect_records(t, {"SELECT 1", "set b 5"})
}

@(test)
feed_translations_follow_reference :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("feed-translate")
	defer feed_off()
	j.update_clock()
	c := new_client(0)
	run(c, "set", "a", "1")
	run(c, "rpush", "l", "x", "y")
	run(c, "incr", "a")
	expect_records(t, {"SELECT 0", "set a 1", "rpush l x y", "incr a"})

	run(c, "SET", "e", "v", "EX", "100")
	recs := take_records(t)
	testing.expect_value(t, len(recs), 1)
	if len(recs) == 1 {
		testing.expect(t, record_matches("SET e v PXAT <n>", recs[0]))
		at, _ := j.parse_i64(transmute([]u8)recs[0][4])
		testing.expect_value(t, at, key_expire(0, "e"))
		testing.expect(t, at - j.srv.now_ms >= 99_000 && at - j.srv.now_ms <= 100_000)
	}

	run(c, "EXPIRE", "a", "1000")
	recs = take_records(t)
	testing.expect(t, len(recs) == 1 && record_matches("PEXPIREAT a <n>", recs[0]))
	if len(recs) == 1 {
		at, _ := j.parse_i64(transmute([]u8)recs[0][2])
		testing.expect_value(t, at, key_expire(0, "a"))
	}

	run(c, "hset", "h", "f", "v")
	run(c, "hpexpire", "h", "100000", "fields", "1", "f")
	recs = take_records(t)
	testing.expect_value(t, len(recs), 2)
	if len(recs) == 2 {
		testing.expect_value(t, joined(recs[0]), "hset h f v")
		testing.expect(t, record_matches("HPEXPIREAT h <n> fields 1 f", recs[1]))
	}

	run(c, "SPOP", "nokey")
	expect_records(t, {})
	run(c, "sadd", "s", "a", "b")
	pop := run(c, "SPOP", "s")
	recs = take_records(t)
	testing.expect_value(t, len(recs), 2)
	if len(recs) == 2 {
		testing.expect_value(t, joined(recs[0]), "sadd s a b")
		member := pop[strings.index(pop, "\r\n") + 2:]
		member = member[:strings.index(member, "\r\n")]
		testing.expect_value(t, joined(recs[1]), strings.concatenate({"SREM s ", member}, context.temp_allocator))
	}

	run(c, "INCRBYFLOAT", "f", "1.5")
	expect_records(t, {"SET f 1.5 KEEPTTL"})

	run(c, "SETEX", "se", "100", "v")
	run(c, "GETEX", "se", "PX", "5000")
	recs = take_records(t)
	testing.expect_value(t, len(recs), 2)
	if len(recs) == 2 {
		testing.expect(t, record_matches("SET se v PXAT <n>", recs[0]))
		testing.expect(t, record_matches("PEXPIREAT se <n>", recs[1]))
		at, _ := j.parse_i64(transmute([]u8)recs[1][2])
		testing.expect_value(t, at, key_expire(0, "se"))
	}
	run(c, "GETEX", "se")
	expect_records(t, {})

	id1 := run(c, "xadd", "x", "*", "f", "v")
	id2 := run(c, "xadd", "x", "maxlen", "1", "*", "f", "v")
	recs = take_records(t)
	testing.expect_value(t, len(recs), 2)
	if len(recs) == 2 {
		testing.expect_value(t, joined(recs[0]), strings.concatenate({"xadd x ", bulk_text(id1), " f v"}, context.temp_allocator))
		testing.expect_value(t, joined(recs[1]), strings.concatenate({"xadd x maxlen 1 ", bulk_text(id2), " f v"}, context.temp_allocator))
	}

	run(c, "pfadd", "hll", "a")
	expect_records(t, {"pfadd hll a"})
	run(c, "pfcount", "hll")
	recs = take_records(t)
	testing.expect(t, len(recs) == 0 || (len(recs) == 1 && joined(recs[0]) == "pfcount hll"))

	run(c, "DEL", "nokey")
	expect_records(t, {})
	run(c, "set", "big", "xyz")
	run(c, "append", "big", "y")
	run(c, "setrange", "big", "2", "zz")
	run(c, "bitfield", "bf", "set", "u8", "0", "5")
	run(c, "bitfield", "bf", "get", "u8", "0")
	run(c, "setbit", "bf", "20", "1")
	run(c, "copy", "a", "a2")
	run(c, "rename", "a2", "a3")
	run(c, "move", "a3", "1")
	run(c, "swapdb", "1", "2")
	expect_records(t, {"set big xyz", "append big y", "setrange big 2 zz", "bitfield bf set u8 0 5", "setbit bf 20 1", "copy a a2", "rename a2 a3", "move a3 1", "swapdb 1 2"})

	future := int_text(j.srv.now_ms + 100_000)
	run(c, "set", "px", "v", "pxat", future)
	expect_records(t, {strings.concatenate({"set px v pxat ", future}, context.temp_allocator)})

	run(c, "sort", "l", "alpha")
	run(c, "sort", "l", "alpha", "store", "l2")
	run(c, "LMPOP", "1", "l2", "LEFT")
	run(c, "BLPOP", "l2", "0.2")
	run(c, "LMPOP", "1", "l2", "LEFT")
	expect_records(t, {"sort l alpha store l2", "LPOP l2 1", "LPOP l2"})

	run(c, "zadd", "z", "1", "a", "2", "b")
	run(c, "zpopmin", "z")
	run(c, "BZPOPMAX", "z", "0.2")
	run(c, "zpopmin", "z")
	expect_records(t, {"zadd z 1 a 2 b", "zpopmin z", "ZPOPMAX z"})

	run(c, "SET", "sl", "v", "PX", "30")
	expect_records(t, {"SET sl v PXAT <n>"})
	sleep_ms(60)
	testing.expect_value(t, run(c, "GET", "sl"), "$-1\r\n")
	expect_records(t, {"DEL sl"})

	run(c, "lpush", "ll", "a", "b", "c")
	run(c, "lrem", "ll", "1", "a")
	run(c, "lrem", "ll", "1", "zzz")
	run(c, "ltrim", "ll", "0", "0")
	run(c, "lset", "ll", "0", "z")
	run(c, "hincrby", "h", "n", "2")
	run(c, "HINCRBYFLOAT", "h", "fl", "1.5")
	run(c, "hsetnx", "h", "g", "v")
	run(c, "hsetnx", "h", "g", "w")
	run(c, "zadd", "z", "1", "a")
	run(c, "zincrby", "z", "1", "a")
	run(c, "zadd", "z", "incr", "1", "a")
	run(c, "persist", "a")
	run(c, "persist", "a")
	expect_records(t, {"lpush ll a b c", "lrem ll 1 a", "ltrim ll 0 0", "lset ll 0 z", "hincrby h n 2", "HSET h fl 1.5", "hsetnx h g v", "zadd z 1 a", "zincrby z 1 a", "zadd z incr 1 a", "persist a"})

	run(c, "set", "a", "1")
	run(c, "EXPIREAT", "a", "9999999999")
	run(c, "persist", "a")
	expect_records(t, {"set a 1", "PEXPIREAT a 9999999999000", "persist a"})

	run(c, "GETDEL", "nokey")
	run(c, "set", "gd", "1")
	run(c, "GETDEL", "gd")
	expect_records(t, {"set gd 1", "DEL gd"})

	run(c, "flushdb")
	expect_records(t, {"flushdb"})
}

bulk_text :: proc(reply: string) -> string {
	i := strings.index(reply, "\r\n")
	if i < 0 {
		return reply
	}
	rest := reply[i + 2:]
	k := strings.index(rest, "\r\n")
	if k < 0 {
		return rest
	}
	return rest[:k]
}

@(test)
feed_streams_follow_reference :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("feed-streams")
	defer feed_off()
	c := new_client(0)
	run(c, "xadd", "x", "1-1", "f", "v")
	run(c, "xadd", "x", "1-2", "f", "v")
	run(c, "xgroup", "create", "x", "g", "$")
	run(c, "xadd", "x", "5-0", "f", "w")
	expect_records(t, {"SELECT 0", "xadd x 1-1 f v", "xadd x 1-2 f v", "xgroup create x g $", "xadd x 5-0 f w"})
	run(c, "XREADGROUP", "GROUP", "g", "c", "STREAMS", "x", ">")
	expect_records(t, {"MULTI", "XCLAIM x g c 0 5-0 TIME <n> RETRYCOUNT 1 FORCE JUSTID LASTID 5-0", "XGROUP SETID x g 5-0 ENTRIESREAD 3", "EXEC"})
	run(c, "XCLAIM", "x", "g", "d", "0", "5-0")
	expect_records(t, {"XCLAIM x g d 0 5-0 TIME <n> RETRYCOUNT 2 FORCE JUSTID LASTID 5-0"})
	run(c, "XREADGROUP", "GROUP", "g", "fresh", "STREAMS", "x", ">")
	expect_records(t, {"XGROUP CREATECONSUMER x g fresh"})
	run(c, "XAUTOCLAIM", "x", "g", "e", "0", "0-0")
	expect_records(t, {"XCLAIM x g e 0 5-0 TIME <n> RETRYCOUNT 3 FORCE JUSTID LASTID 5-0"})
	run(c, "xgroup", "setid", "x", "g", "0")
	run(c, "xack", "x", "g", "9-9")
	run(c, "xtrim", "x", "maxlen", "0")
	run(c, "xtrim", "x", "maxlen", "0")
	expect_records(t, {"xgroup setid x g 0", "xtrim x maxlen 0"})
	for i in 0 ..< 300 {
		run(c, "XADD", "big", "*", "n", int_text(i64(i)))
	}
	clear(&j.aof.buf)
	run(c, "XADD", "big", "MAXLEN", "~", "10", "LIMIT", "1000", "*", "n", "x")
	recs := take_records(t)
	testing.expect_value(t, len(recs), 1)
	if len(recs) == 1 {
		testing.expect(t, record_matches("XADD big MAXLEN = <n> LIMIT 1000 <id> n x", recs[0]), joined(recs[0]))
		want := strings.trim_space(run(c, "XLEN", "big"))
		testing.expect_value(t, recs[0][4], strings.trim_prefix(want, ":"))
	}
	run(c, "XTRIM", "big", "MINID", "~", "0-0")
	expect_records(t, {})
}

@(test)
feed_spop_batches_and_emptied_trims :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("feed-spop-trim")
	defer feed_off()
	c := new_client(0)
	members := make([dynamic]string, context.temp_allocator)
	append(&members, "SADD", "s")
	for i in 0 ..< 3000 {
		append(&members, strings.concatenate({"m", int_text(i64(10000 + i))}, context.temp_allocator))
	}
	run(c, ..members[:])
	take_records(t)
	run(c, "SPOP", "s", "2500")
	recs := take_records(t)
	testing.expect_value(t, len(recs), 5)
	if len(recs) == 5 {
		testing.expect_value(t, joined(recs[0]), "MULTI")
		testing.expect_value(t, len(recs[1]), 2 + 1024)
		testing.expect_value(t, len(recs[2]), 2 + 1024)
		testing.expect_value(t, len(recs[3]), 2 + 452)
		for rec in recs[1:4] {
			testing.expect_value(t, rec[0], "SREM")
			testing.expect_value(t, rec[1], "s")
		}
		testing.expect_value(t, joined(recs[4]), "EXEC")
	}
	run(c, "SPOP", "s", "300")
	recs = take_records(t)
	testing.expect_value(t, len(recs), 1)
	if len(recs) == 1 {
		testing.expect_value(t, len(recs[0]), 2 + 300)
	}
	run(c, "XADD", "st3", "MINID", "~", "50", "7-1", "f", "v")
	expect_records(t, {"XADD st3 MINID = 18446744073709551615-18446744073709551615 7-1 f v"})
	run(c, "XADD", "st", "1-1", "f", "v")
	run(c, "XADD", "st", "2-1", "f", "v")
	take_records(t)
	run(c, "XTRIM", "st", "MINID", "~", "50", "LIMIT", "100")
	expect_records(t, {"XTRIM st MINID = 18446744073709551615-18446744073709551615 LIMIT 100"})
	run(c, "XADD", "st", "3-1", "f", "v")
	take_records(t)
	run(c, "XTRIM", "st", "MAXLEN", "~", "0", "LIMIT", "100")
	expect_records(t, {"XTRIM st MAXLEN = 0 LIMIT 100"})
}

@(test)
feed_transactions_wrap :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("feed-multi")
	defer feed_off()
	c := new_client(0)
	exec_cmd := j.lookup_command(transmute([]u8)string("exec"))
	j.tx_exec_conn = c
	defer j.tx_exec_conn = nil
	j.aof_tx_begin(c, exec_cmd, {transmute([]u8)string("EXEC")})
	run(c, "SET", "m1", "1")
	run(c, "SET", "m2", "2")
	j.aof_tx_end()
	expect_records(t, {"MULTI", "SELECT 0", "SET m1 1", "SET m2 2", "EXEC"})
	j.aof_tx_begin(c, exec_cmd, {transmute([]u8)string("EXEC")})
	run(c, "SET", "m3", "3")
	run(c, "GET", "m3")
	j.aof_tx_end()
	expect_records(t, {"SET m3 3"})
}

@(test)
feed_restore_and_hash_expiry :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("feed-restore")
	defer feed_off()
	c := new_client(0)
	run(c, "set", "src", "v")
	dump := run(c, "DUMP", "src")
	payload := bulk_text(dump)
	clear(&j.aof.buf)
	run(c, "RESTORE", "r", "0", payload, "REPLACE")
	run(c, "RESTORE", "r2", "5000", payload)
	recs := take_records(t)
	testing.expect_value(t, len(recs), 2)
	if len(recs) == 2 {
		testing.expect_value(t, recs[0][0], "RESTORE")
		testing.expect_value(t, recs[0][2], "0")
		testing.expect_value(t, recs[0][4], "REPLACE")
		testing.expect(t, record_matches("RESTORE r2 <n> <any> ABSTTL", recs[1]))
		at, _ := j.parse_i64(transmute([]u8)recs[1][2])
		testing.expect_value(t, at, key_expire(0, "r2"))
	}
	run(c, "hset", "h", "a", "1", "b", "2", "c", "3")
	run(c, "HEXPIRE", "h", "100", "NX", "FIELDS", "3", "a", "b", "nofield")
	recs = take_records(t)
	testing.expect_value(t, len(recs), 2)
	if len(recs) == 2 {
		testing.expect(t, record_matches("HPEXPIREAT h <n> FIELDS 2 a b", recs[1]), joined(recs[1]))
	}
	run(c, "HPEXPIREAT", "h", "1", "FIELDS", "1", "c")
	expect_records(t, {"HDEL h c"})
	run(c, "HPERSIST", "h", "FIELDS", "1", "a")
	run(c, "HPERSIST", "h", "FIELDS", "1", "a")
	expect_records(t, {"HPERSIST h FIELDS 1 a"})
	run(c, "sadd", "s", "a", "b", "c")
	run(c, "SPOP", "s", "2")
	recs = take_records(t)
	testing.expect_value(t, len(recs), 2)
	if len(recs) == 2 {
		testing.expect(t, record_matches("SREM s <any> <any>", recs[1]))
	}
	run(c, "SPOP", "s", "5")
	expect_records(t, {"DEL s"})
	run(c, "rpush", "src2", "a", "b")
	run(c, "BLMOVE", "src2", "dst2", "LEFT", "RIGHT", "0")
	run(c, "BRPOPLPUSH", "src2", "dst2", "0")
	run(c, "BRPOPLPUSH", "src2", "dst2", "0.01")
	expect_records(t, {"rpush src2 a b", "LMOVE src2 dst2 LEFT RIGHT", "RPOPLPUSH src2 dst2"})
	run(c, "zadd", "zz", "1", "a", "2", "b", "3", "c")
	run(c, "ZMPOP", "1", "zz", "MAX", "COUNT", "2")
	run(c, "BZMPOP", "0", "1", "zz", "MIN")
	expect_records(t, {"zadd zz 1 a 2 b 3 c", "ZPOPMAX zz 2", "ZPOPMIN zz 1"})
}

package blockingops

import "core:testing"
import "core:time"
import eski "../../src"
import ld "../../src/ldfloat"

@(test)
timeout_conversion_table :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		valid: bool,
		ms:    i64,
		err:   string,
	}
	cases := []Case {
		{"0", true, 0, ""},
		{"-0", true, 0, ""},
		{"0.0", true, 0, ""},
		{"1", true, 1000, ""},
		{"+1", true, 1000, ""},
		{"1.", true, 1000, ""},
		{".1", true, 100, ""},
		{"00.1", true, 100, ""},
		{"0.1", true, 100, ""},
		{"0.05", true, 50, ""},
		{"1.5", true, 1500, ""},
		{"0.0015", true, 2, ""},
		{"0.0001", true, 1, ""},
		{"1e-400", true, 1, ""},
		{"2.5e1", true, 25000, ""},
		{"0x10", true, 16000, ""},
		{"9223372036854775", true, 9223372036854775000, ""},
		{"9223372036854776", true, 0, eski.ERR_TIMEOUT_RANGE},
		{"0x7FFFFFFFFFFFFF", true, 0, eski.ERR_TIMEOUT_RANGE},
		{"1e30", true, 0, eski.ERR_TIMEOUT_RANGE},
		{"inf", true, 0, eski.ERR_TIMEOUT_RANGE},
		{"+infinity", true, 0, eski.ERR_TIMEOUT_RANGE},
		{"-1", true, 0, eski.ERR_TIMEOUT_NEGATIVE},
		{"-0.001", true, 0, eski.ERR_TIMEOUT_NEGATIVE},
		{"-inf", true, 0, eski.ERR_TIMEOUT_NEGATIVE},
		{"x", false, 0, ""},
		{"", false, 0, ""},
		{" 1", false, 0, ""},
		{"1 ", false, 0, ""},
		{"nan", false, 0, ""},
		{"1s", false, 0, ""},
	}
	for c in cases {
		v, ok := ld.parse(transmute([]u8)c.text)
		testing.expectf(t, ok == c.valid, "%q parse validity %v", c.text, ok)
		if !ok {
			continue
		}
		ms, err := eski.block_timeout_ms(v)
		testing.expectf(t, ms == c.ms && err == c.err, "%q gave %v %q want %v %q", c.text, ms, err, c.ms, c.err)
	}
	ms, err := eski.block_timeout_ms(ld.nan())
	testing.expect_value(t, ms, 0)
	testing.expect_value(t, err, eski.ERR_TIMEOUT_NOT_FLOAT)
}

@(test)
timeout_parse_deadlines :: proc(t: ^testing.T) {
	context.allocator = begin()
	c := fake_conn()
	defer free(c)
	eski.update_clock()
	d, ok := eski.block_parse_timeout(c, transmute([]u8)string("0"))
	testing.expect(t, ok && d == 0, "zero means forever")
	d, ok = eski.block_parse_timeout(c, transmute([]u8)string("1.5"))
	testing.expect(t, ok && d == eski.srv.now_ms + 1500, "deadline is now plus milliseconds")
	d, ok = eski.block_parse_timeout(c, transmute([]u8)string("0.0001"))
	testing.expect(t, ok && d == eski.srv.now_ms + 1, "sub millisecond timeouts round up")
	testing.expect_value(t, c.wlen, 0)
}

@(test)
timeout_parse_errors_on_the_wire :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	expect_call(t, w, "-ERR timeout is out of range\r\n", "BLPOP", "l", "9223372036854775")
	expect_call(t, w, "-ERR timeout is out of range\r\n", "BRPOP", "l", "0x7FFFFFFFFFFFFF")
	expect_call(t, w, "-ERR timeout is negative\r\n", "BZPOPMAX", "z", "-inf")
	expect_call(t, w, "-ERR timeout is not a float or out of range\r\n", "BZPOPMIN", "z", "nan")
	expect_call(t, w, "-ERR timeout is not a float or out of range\r\n", "BLMOVE", "a", "b", "LEFT", "LEFT", "1s")
	expect_call(t, w, "-ERR timeout is negative\r\n", "BRPOPLPUSH", "a", "b", "-1")
	expect_call(t, w, "-ERR timeout is negative\r\n", "BLMPOP", "-1", "1", "l", "LEFT")
	expect_call(t, w, "-ERR timeout is out of range\r\n", "BZMPOP", "inf", "1", "z", "MIN")
	expect_call(t, w, "-ERR syntax error\r\n", "BLMOVE", "a", "b", "LEFT", "UP", "-1")
	expect_call(t, w, "-ERR numkeys should be greater than 0\r\n", "BLMPOP", "-1", "0", "l", "LEFT")
	disconnect(w)
	idle_state(t)
}

@(test)
timeout_many_clients_expire_on_their_own_deadlines :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	short := connect()
	long := connect()
	forever := connect()
	start := time.tick_now()
	start_cmd(t, long, "BLPOP", "tq", "0.3")
	start_cmd(t, short, "BRPOP", "tq", "0.1")
	start_cmd(t, forever, "BZPOPMIN", "tq", "0")
	expect_reply(t, short, NULL_ARRAY)
	first := elapsed_ms(start)
	testing.expectf(t, first >= 95 && first < 280, "short waiter returned after %v", first)
	testing.expect_value(t, long.conn.blocked, eski.Block_Type.List)
	expect_reply(t, long, NULL_ARRAY)
	second := elapsed_ms(start)
	testing.expectf(t, second >= 295 && second < 600, "long waiter returned after %v", second)
	testing.expect_value(t, forever.conn.blocked, eski.Block_Type.Zset)
	testing.expect_value(t, eski.block_next_deadline, 0)
	testing.expect_value(t, eski.block_count(), 1)
	expect_call(t, w, ":1\r\n", "CLIENT", "UNBLOCK", id_of(forever))
	expect_reply(t, forever, NULL_ARRAY)
	disconnect(forever)
	disconnect(long)
	disconnect(short)
	disconnect(w)
	idle_state(t)
}

@(test)
timeout_reexecution_keeps_the_first_deadline :: proc(t: ^testing.T) {
	context.allocator = begin()
	w := fresh()
	r1 := connect()
	r2 := connect()
	expect_call(t, w, OK, "XGROUP", "CREATE", "gq", "grp", "$", "MKSTREAM")
	start_cmd(t, r1, "XREADGROUP", "GROUP", "grp", "alice", "BLOCK", "0", "STREAMS", "gq", ">")
	start := time.tick_now()
	start_cmd(t, r2, "XREADGROUP", "GROUP", "grp", "alice", "BLOCK", "400", "STREAMS", "gq", ">")
	time.sleep(150 * time.Millisecond)
	expect_call(t, w, "$3\r\n5-1\r\n", "XADD", "gq", "5-1", "f", "v")
	expect_reply(t, r1, "*1\r\n*2\r\n$2\r\ngq\r\n*1\r\n*2\r\n$3\r\n5-1\r\n*2\r\n$1\r\nf\r\n$1\r\nv\r\n")
	testing.expect_value(t, r2.conn.blocked, eski.Block_Type.Stream)
	expect_reply(t, r2, NULL_ARRAY)
	ms := elapsed_ms(start)
	testing.expectf(t, ms >= 395 && ms < 520, "rearmed reader timed out after %v", ms)
	start = time.tick_now()
	start_cmd(t, r1, "BLPOP", "ek", "0.3")
	expect_call(t, w, OK, "SELECT", "5")
	expect_call(t, w, ":1\r\n", "RPUSH", "ek", "v")
	expect_call(t, w, ":1\r\n", "PEXPIRE", "ek", "20")
	expect_call(t, w, OK, "SELECT", "0")
	time.sleep(60 * time.Millisecond)
	expect_call(t, w, OK, "SWAPDB", "0", "5")
	expect_silent(t, r1, 30)
	testing.expect_value(t, r1.conn.blocked, eski.Block_Type.List)
	expect_reply(t, r1, NULL_ARRAY)
	ms = elapsed_ms(start)
	testing.expectf(t, ms >= 295 && ms < 520, "waiter on an expired key timed out after %v", ms)
	disconnect(r2)
	disconnect(r1)
	disconnect(w)
	idle_state(t)
}

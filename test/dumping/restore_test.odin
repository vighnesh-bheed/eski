package dumping

import "core:testing"
import eski "../../src"
import rdb "../../src/rdb"

OK_REPLY :: "+OK\r\n"
BUSYKEY_REPLY :: "-BUSYKEY Target key name already exists.\r\n"
SYNTAX_REPLY :: "-ERR syntax error\r\n"
NOT_INT_REPLY :: "-ERR value is not an integer or out of range\r\n"
PAYLOAD_REPLY :: "-ERR DUMP payload version or checksum are wrong\r\n"
BAD_FORMAT_REPLY :: "-ERR Bad data format\r\n"
TTL_REPLY :: "-ERR Invalid TTL value, must be >= 0\r\n"
IDLE_REPLY :: "-ERR Invalid IDLETIME value, must be >= 0\r\n"
FREQ_REPLY :: "-ERR Invalid FREQ value, must be >= 0 and <= 255\r\n"

restore :: proc(c: ^eski.Conn, key: string, ttl: string, payload: []u8, opts: ..string) -> string {
	argv := make([dynamic][]u8, heap())
	defer delete(argv)
	append(&argv, bytes("restore"), bytes(key), bytes(ttl), payload)
	for o in opts {
		append(&argv, bytes(o))
	}
	return run_argv(c, argv[:])
}

@(test)
restore_round_trip_busykey_and_replace :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	payload := hex_decode(OBSERVED_STRING)
	testing.expect_value(t, restore(c, "r1", "0", payload), OK_REPLY)
	testing.expect_value(t, run(c, "get", "r1"), "$5\r\nhello\r\n")
	testing.expect_value(t, run(c, "ttl", "r1"), ":-1\r\n")
	testing.expect_value(t, restore(c, "r1", "0", payload), BUSYKEY_REPLY)
	run(c, "set", "r1", "other")
	testing.expect_value(t, restore(c, "r1", "0", payload, "REPLACE"), OK_REPLY)
	testing.expect_value(t, run(c, "get", "r1"), "$5\r\nhello\r\n")
	testing.expect_value(t, restore(c, "r1", "0", payload, "REPLACE", "REPLACE"), OK_REPLY)
	testing.expect_value(t, restore(c, "r1", "0", payload, "replace", "absttl"), OK_REPLY)
}

@(test)
restore_relative_and_absolute_ttl :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	payload := hex_decode(OBSERVED_STRING)
	testing.expect_value(t, restore(c, "r2", "5000", payload), OK_REPLY)
	pttl, _ := int_of(run(c, "pttl", "r2"))
	testing.expectf(t, pttl > 4900 && pttl <= 5000, "relative ttl gave pttl %d", pttl)
	buf: [24]u8
	future := itoa(buf[:], eski.expire_now() + 60000)
	testing.expect_value(t, restore(c, "r3", future, payload, "ABSTTL"), OK_REPLY)
	pttl, _ = int_of(run(c, "pttl", "r3"))
	testing.expectf(t, pttl > 59000 && pttl <= 60000, "absolute ttl gave pttl %d", pttl)
	big: [24]u8
	far := itoa(big[:], 2569591501)
	testing.expect_value(t, restore(c, "r9", far, payload), OK_REPLY)
	pttl, _ = int_of(run(c, "pttl", "r9"))
	testing.expectf(t, pttl > 2569591501 - 2000 && pttl <= 2569591501, "ttl above 32 bits gave pttl %d", pttl)
	testing.expect_value(t, restore(c, "r10", "4611686018427387904", payload), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "r10"), ":1\r\n")
	pttl, _ = int_of(run(c, "pttl", "r10"))
	testing.expectf(t, pttl > 0, "huge ttl gave pttl %d", pttl)
	testing.expect_value(t, restore(c, "r11", "0", payload, "ABSTTL"), OK_REPLY)
	testing.expect_value(t, run(c, "pttl", "r11"), ":-1\r\n")
}

@(test)
restore_absttl_in_the_past :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	payload := hex_decode(OBSERVED_STRING)
	buf: [24]u8
	past := itoa(buf[:], eski.expire_now() - 1000)
	sub := subscribe_events(c, "KEA")
	before := eski.pst.dirty
	testing.expect_value(t, restore(c, "r4", past, payload, "ABSTTL"), OK_REPLY)
	testing.expect_value(t, eski.pst.dirty, before)
	testing.expect_value(t, take_events(sub), "")
	testing.expect_value(t, run(c, "exists", "r4"), ":0\r\n")
	testing.expect_value(t, restore(c, "r4", past, payload, "ABSTTL", "REPLACE"), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "r4"), ":0\r\n")
	testing.expect_value(t, eski.pst.dirty, before)
	run(c, "set", "r4", "old")
	take_events(sub)
	before = eski.pst.dirty
	testing.expect_value(t, restore(c, "r4", past, payload, "ABSTTL"), BUSYKEY_REPLY)
	testing.expect_value(t, restore(c, "r4", past, payload, "ABSTTL", "REPLACE"), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "r4"), ":0\r\n")
	testing.expect_value(t, eski.pst.dirty, before + 1)
	testing.expect_value(t, take_events(sub), event_frame("del", "r4"))
}

@(test)
restore_idletime_and_freq :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	payload := hex_decode(OBSERVED_STRING)
	testing.expect_value(t, restore(c, "r5", "0", payload, "IDLETIME", "1000"), OK_REPLY)
	idle, _ := int_of(run(c, "object", "idletime", "r5"))
	testing.expectf(t, idle >= 1000 && idle <= 1001, "idletime %d", idle)
	testing.expect_value(t, restore(c, "r5w", "0", payload, "IDLETIME", "16777214"), OK_REPLY)
	edge, _ := int_of(run(c, "object", "idletime", "r5w"))
	testing.expectf(t, edge >= 16777214 && edge <= 16777215, "idletime 16777214 reads back as %d", edge)
	testing.expect_value(t, restore(c, "r5x", "0", payload, "IDLETIME", "16777215"), OK_REPLY)
	wrapped, _ := int_of(run(c, "object", "idletime", "r5x"))
	testing.expectf(t, wrapped >= 0 && wrapped <= 1, "idletime 16777215 reads back as %d", wrapped)
	testing.expect_value(t, restore(c, "r5y", "0", payload, "IDLETIME", "20000000"), OK_REPLY)
	wrapped, _ = int_of(run(c, "object", "idletime", "r5y"))
	testing.expectf(t, wrapped >= 3222784 && wrapped <= 3222785, "idletime 20000000 reads back as %d", wrapped)
	testing.expect_value(t, restore(c, "r5h", "0", payload, "IDLETIME", "9223372036854775807"), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "r5h"), ":1\r\n")
	testing.expect_value(t, restore(c, "r5b", "0", payload, "FREQ", "100"), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "r5b"), ":1\r\n")
	run(c, "config", "set", "maxmemory-policy", "allkeys-lfu")
	testing.expect_value(t, restore(c, "r6", "0", payload, "FREQ", "200"), OK_REPLY)
	testing.expect_value(t, run(c, "object", "freq", "r6"), ":200\r\n")
	testing.expect_value(t, restore(c, "r6b", "0", payload, "IDLETIME", "50"), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "r6b"), ":1\r\n")
	testing.expect_value(t, restore(c, "r6c", "0", payload, "FREQ", "0"), OK_REPLY)
	testing.expect_value(t, run(c, "object", "freq", "r6c"), ":0\r\n")
	testing.expect_value(t, restore(c, "r6d", "0", payload, "FREQ", "255"), OK_REPLY)
	testing.expect_value(t, run(c, "object", "freq", "r6d"), ":255\r\n")
	run(c, "config", "set", "maxmemory-policy", "noeviction")
}

@(test)
restore_option_errors :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	payload := hex_decode(OBSERVED_STRING)
	testing.expect_value(t, restore(c, "r7", "0", payload, "FREQ", "300"), FREQ_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "FREQ", "-1"), FREQ_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "FREQ", "x"), NOT_INT_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "IDLETIME", "-5"), IDLE_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "IDLETIME", "x"), NOT_INT_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "IDLETIME"), SYNTAX_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "FREQ"), SYNTAX_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "IDLETIME", "5", "FREQ", "5"), SYNTAX_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "FREQ", "5", "IDLETIME", "5"), SYNTAX_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "IDLETIME", "5", "FREQ", "300"), SYNTAX_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "BOGUS"), SYNTAX_REPLY)
	testing.expect_value(t, restore(c, "r7", "0", payload, "REPLACE", "BOGUS"), SYNTAX_REPLY)
	testing.expect_value(t, restore(c, "r8", "-1", payload), TTL_REPLY)
	testing.expect_value(t, restore(c, "r8", "abc", payload), NOT_INT_REPLY)
	testing.expect_value(t, restore(c, "r8", "1.5", payload), NOT_INT_REPLY)
	testing.expect_value(t, restore(c, "r8", "-1", payload, "BOGUS"), SYNTAX_REPLY)
	testing.expect_value(t, restore(c, "r8", "-1", bytes("junk")), TTL_REPLY)
	testing.expect_value(t, run(c, "restore", "r8", "0"), "-ERR wrong number of arguments for 'restore' command\r\n")
	testing.expect_value(t, run(c, "exists", "r7", "r8"), ":0\r\n")
	testing.expect_value(t, restore(c, "r8", "0", payload, "REPLACE", "REPLACE"), OK_REPLY)
}

@(test)
restore_busykey_precedes_ttl_and_payload_checks :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	payload := hex_decode(OBSERVED_STRING)
	run(c, "set", "taken", "1")
	testing.expect_value(t, restore(c, "taken", "-1", payload), BUSYKEY_REPLY)
	testing.expect_value(t, restore(c, "taken", "abc", payload), BUSYKEY_REPLY)
	testing.expect_value(t, restore(c, "taken", "0", payload[:5]), BUSYKEY_REPLY)
	testing.expect_value(t, restore(c, "taken", "0", payload, "FREQ", "300"), FREQ_REPLY)
	testing.expect_value(t, restore(c, "taken", "0", payload[:5], "REPLACE"), PAYLOAD_REPLY)
	testing.expect_value(t, run(c, "get", "taken"), "$1\r\n1\r\n")
}

mutate :: proc(src: []u8, at: int, value: u8) -> []u8 {
	out := make([]u8, len(src), heap())
	copy(out, src)
	out[at] = value
	return out
}

@(test)
restore_rejects_corrupt_payloads :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	good := hex_decode(OBSERVED_STRING)
	n := len(good)
	extra := make([]u8, n + 1, heap())
	copy(extra, good)
	cases := [?][]u8 {
		good[:n - 1],
		good[:7],
		{},
		extra,
		mutate(good, 0, 0x01),
		mutate(good, 3, 'X'),
		mutate(good, n - 10, 13),
		mutate(good, n - 9, 1),
		mutate(good, n - 1, good[n - 1] ~ 0xff),
		mutate(good, n - 8, good[n - 8] ~ 0x01),
		good[:n - 8],
		good[:9],
		good[:DUMP_TRAILER],
	}
	for p, i in cases {
		testing.expectf(t, restore(c, "bad", "0", p, "REPLACE") == PAYLOAD_REPLY, "corrupt case %d was not rejected", i)
	}
	testing.expect_value(t, run(c, "exists", "bad"), ":0\r\n")
}

DUMP_TRAILER :: 10

seal :: proc(body: []u8, version: u8 = rdb.RDB_VERSION) -> []u8 {
	out := make([]u8, len(body) + DUMP_TRAILER, heap())
	copy(out, body)
	out[len(body)] = version
	out[len(body) + 1] = 0
	reseal(out)
	return out
}

@(test)
restore_rejects_well_sealed_garbage :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	cases := [?][]u8 {
		seal({}),
		seal({200}),
		seal({rdb.TYPE_MODULE_PRE_GA, 1}),
		seal({rdb.TYPE_STRING}),
		seal({rdb.TYPE_STRING, 15, 'h', 'i'}),
		seal({rdb.TYPE_STRING, 13, 'h', 'i'}),
		seal(hex_decode("1201020d0d000000020081610281")),
		seal(hex_decode("0b0c020000000300000001000200")),
		seal(hex_decode("ff")),
		hex_decode(OBSERVED_STRING)[1:],
	}
	for p, i in cases {
		testing.expectf(t, restore(c, "garbage", "0", p) == BAD_FORMAT_REPLY, "sealed garbage case %d was accepted", i)
	}
	testing.expect_value(t, run(c, "exists", "garbage"), ":0\r\n")
	run(c, "set", "garbage", "keep")
	testing.expect_value(t, restore(c, "garbage", "0", seal({200}), "REPLACE"), BAD_FORMAT_REPLY)
	testing.expect_value(t, run(c, "get", "garbage"), "$4\r\nkeep\r\n")
}

@(test)
restore_object_may_reach_into_the_trailer :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	payload := seal({rdb.TYPE_STRING, 5, 'a', 'b'})
	testing.expect_value(t, len(payload), 14)
	before := eski.pst.dirty
	testing.expect_value(t, restore(c, "y7", "0", payload), OK_REPLY)
	testing.expect_value(t, eski.pst.dirty, before + 1)
	value, _ := bulk_of(run(c, "get", "y7"))
	testing.expect_value(t, hex_encode(value), hex_encode({'a', 'b', rdb.RDB_VERSION, 0, payload[6]}))
	exact := seal({rdb.TYPE_STRING, 12, 'a', 'b'})
	testing.expect_value(t, restore(c, "y8", "0", exact), OK_REPLY)
	value, _ = bulk_of(run(c, "get", "y8"))
	testing.expect_value(t, len(value), 12)
	testing.expect_value(t, hex_encode(value[2:]), hex_encode(exact[4:]))
	testing.expect_value(t, restore(c, "y9", "0", seal({rdb.TYPE_STRING, 13, 'a', 'b'})), BAD_FORMAT_REPLY)
	testing.expect_value(t, run(c, "exists", "y9"), ":0\r\n")
	testing.expect_value(t, restore(c, "y10", "0", seal({rdb.TYPE_STRING, 1, 'a', 0xff, 0xfe, 0xfd})), OK_REPLY)
	testing.expect_value(t, run(c, "get", "y10"), "$1\r\na\r\n")
	list := hex_decode(OBSERVED_LIST)
	padded := make([dynamic]u8, heap())
	append(&padded, ..list[:len(list) - DUMP_TRAILER])
	append(&padded, 'j', 'u', 'n', 'k')
	testing.expect_value(t, restore(c, "y11", "0", seal(padded[:])), OK_REPLY)
	testing.expect_value(t, run(c, "lrange", "y11", "0", "-1"), "*2\r\n$1\r\na\r\n$1\r\nb\r\n")
}

@(test)
restore_relative_ttl_overflow_counts_as_expired :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	payload := hex_decode(OBSERVED_STRING)
	sub := subscribe_events(c, "KEA")
	before := eski.pst.dirty
	testing.expect_value(t, restore(c, "z5", "9223372036854775807", payload), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "z5"), ":0\r\n")
	testing.expect_value(t, eski.pst.dirty, before)
	testing.expect_value(t, take_events(sub), "")
	buf: [24]u8
	edge := itoa(buf[:], max(i64) - eski.expire_now() + 1)
	testing.expect_value(t, restore(c, "z5", edge, payload), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "z5"), ":0\r\n")
	testing.expect_value(t, restore(c, "z5", "9223372036854775807", payload, "REPLACE"), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "z5"), ":0\r\n")
	testing.expect_value(t, eski.pst.dirty, before)
	testing.expect_value(t, take_events(sub), "")
	run(c, "set", "z5", "old")
	take_events(sub)
	before = eski.pst.dirty
	testing.expect_value(t, restore(c, "z5", "9223372036854775807", payload), BUSYKEY_REPLY)
	testing.expect_value(t, restore(c, "z5", "9223372036854775807", payload, "REPLACE"), OK_REPLY)
	testing.expect_value(t, run(c, "exists", "z5"), ":0\r\n")
	testing.expect_value(t, eski.pst.dirty, before + 1)
	testing.expect_value(t, take_events(sub), event_frame("del", "z5"))
}

@(test)
restore_honours_skip_checksum_and_older_versions :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	good := hex_decode(OBSERVED_STRING)
	n := len(good)
	broken := mutate(good, n - 1, good[n - 1] ~ 0x5a)
	testing.expect_value(t, restore(c, "k", "0", broken), PAYLOAD_REPLY)
	eski.pst.skip_checksum = true
	testing.expect_value(t, restore(c, "k", "0", broken), OK_REPLY)
	testing.expect_value(t, run(c, "get", "k"), "$5\r\nhello\r\n")
	testing.expect_value(t, restore(c, "k2", "0", mutate(good, n - 10, 13)), PAYLOAD_REPLY)
	testing.expect_value(t, restore(c, "k3", "0", seal({200})), BAD_FORMAT_REPLY)
	eski.pst.skip_checksum = false
	testing.expect_value(t, restore(c, "k4", "0", broken), PAYLOAD_REPLY)
	testing.expect_value(t, restore(c, "k5", "0", seal(good[:n - DUMP_TRAILER], 9)), OK_REPLY)
	testing.expect_value(t, run(c, "get", "k5"), "$5\r\nhello\r\n")
}

@(test)
restore_preserves_encodings :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	seed_types(c)
	plain_big := dump_of(c, "big")
	run(c, "hpexpire", "h", "100000", "FIELDS", "1", "f")
	hash_ttl := dump_of(c, "h")
	cases := [?][4]string {
		{"copy:s", OBSERVED_STRING, "string", "embstr"},
		{"copy:i", OBSERVED_INT, "string", "int"},
		{"copy:l", OBSERVED_LIST, "list", "listpack"},
		{"copy:si", OBSERVED_INTSET, "set", "intset"},
		{"copy:ss", OBSERVED_SET, "set", "listpack"},
		{"copy:z", OBSERVED_ZSET, "zset", "listpack"},
		{"copy:h", OBSERVED_HASH, "hash", "listpack"},
		{"copy:x", OBSERVED_STREAM, "stream", "stream"},
		{"copy:lzf", OBSERVED_BIG_LZF, "string", "raw"},
	}
	for row in cases {
		testing.expectf(t, restore(c, row[0], "0", hex_decode(row[1])) == OK_REPLY, "restore %s failed", row[0])
		testing.expect_value(t, run(c, "type", row[0]), concat(concat("+", row[2]), "\r\n"))
		enc, _ := bulk_of(run(c, "object", "encoding", row[0]))
		testing.expectf(t, string(enc) == row[3], "%s encoding %s", row[0], string(enc))
	}
	testing.expect_value(t, restore(c, "copy:big", "0", plain_big), OK_REPLY)
	enc, _ := bulk_of(run(c, "object", "encoding", "copy:big"))
	testing.expect_value(t, string(enc), "raw")
	value, _ := bulk_of(run(c, "get", "copy:big"))
	testing.expect_value(t, string(value), HUNDRED_A)
	lzf_value, _ := bulk_of(run(c, "get", "copy:lzf"))
	testing.expect_value(t, string(lzf_value), HUNDRED_A)
	testing.expect_value(t, run(c, "lrange", "copy:l", "0", "-1"), "*2\r\n$1\r\na\r\n$1\r\nb\r\n")
	testing.expect_value(t, run(c, "xlen", "copy:x"), ":1\r\n")
	testing.expect_value(t, restore(c, "copy:hx", "0", hash_ttl), OK_REPLY)
	enc, _ = bulk_of(run(c, "object", "encoding", "copy:hx"))
	testing.expect_value(t, string(enc), "listpackex")
	field_ttl := run(c, "hpttl", "copy:hx", "FIELDS", "1", "f")
	remaining: i64 = -1
	if len(field_ttl) > 6 && field_ttl[:4] == "*1\r\n" {
		remaining, _ = int_of(field_ttl[4:])
	}
	testing.expectf(t, remaining > 98000 && remaining <= 100000, "hpttl after restore %q", field_ttl)
	testing.expect_value(t, hex_encode(dump_of(c, "copy:l")), OBSERVED_LIST)
	testing.expect_value(t, hex_encode(dump_of(c, "copy:x")), OBSERVED_STREAM)
}

@(test)
restore_counts_one_change_and_emits_restore_event :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	payload := hex_decode(OBSERVED_STRING)
	sub := subscribe_events(c, "KEA")
	before := eski.pst.dirty
	testing.expect_value(t, restore(c, "ev1", "1000", payload), OK_REPLY)
	testing.expect_value(t, eski.pst.dirty, before + 1)
	testing.expect_value(t, take_events(sub), event_frame("restore", "ev1"))
	testing.expect_value(t, restore(c, "ev1", "0", payload, "REPLACE"), OK_REPLY)
	testing.expect_value(t, eski.pst.dirty, before + 2)
	testing.expect_value(t, take_events(sub), event_frame("restore", "ev1"))
	testing.expect_value(t, restore(c, "ev1", "0", payload), BUSYKEY_REPLY)
	testing.expect_value(t, restore(c, "ev2", "0", payload[:4]), PAYLOAD_REPLY)
	testing.expect_value(t, eski.pst.dirty, before + 2)
	testing.expect_value(t, take_events(sub), "")
}

@(test)
restore_deep_sanitization_counts :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	list := hex_decode(OBSERVED_LIST)
	before := eski.stat_dump_sanitizations
	testing.expect_value(t, restore(c, "lr0", "0", list), OK_REPLY)
	testing.expect_value(t, eski.stat_dump_sanitizations, before)
	run(c, "config", "set", "sanitize-dump-payload", "yes")
	testing.expect_value(t, restore(c, "lr", "0", list), OK_REPLY)
	testing.expect_value(t, run(c, "lrange", "lr", "0", "-1"), "*2\r\n$1\r\na\r\n$1\r\nb\r\n")
	testing.expect_value(t, eski.stat_dump_sanitizations, before + 1)
	run(c, "config", "set", "sanitize-dump-payload", "clients")
	testing.expect_value(t, restore(c, "lr2", "0", list), OK_REPLY)
	testing.expect_value(t, eski.stat_dump_sanitizations, before + 2)
	run(c, "config", "set", "sanitize-dump-payload", "no")
}

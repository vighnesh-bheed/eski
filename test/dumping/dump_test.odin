package dumping

import "core:testing"
import eski "../../src"
import rdb "../../src/rdb"

OBSERVED_STRING :: "000568656c6c6f0c00a804ebb69f1ebe43"
OBSERVED_INT :: "00c02a0c004a8d683a7c49d119"
OBSERVED_LIST :: "1201020d0d0000000200816102816202ff0c00a39d3e49e96b25f8"
OBSERVED_INTSET :: "0b0c0200000002000000010002000c00a40f0c71cec1be67"
OBSERVED_SET :: "140a0a0000000100816102ff0c005576f6689e5a0cb4"
OBSERVED_ZSET :: "110c0c00000002008161020101ff0c006373fa782d83ad4b"
OBSERVED_HASH :: "100d0d0000000200816602817602ff0c00eb870984d97e96d4"
OBSERVED_STREAM :: "150110000000000000000100000000000000011d1d0000000a0001010001010181660200010201000100018176020401ff0101010101000001000c0047f32561afb1fbb3"
OBSERVED_BIG_LZF :: "00c3094064016161e057000161610c0023d581c74a476c38"

HUNDRED_A :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

seed_types :: proc(c: ^eski.Conn) {
	run(c, "set", "s", "hello")
	run(c, "set", "i", "42")
	run(c, "rpush", "l", "a", "b")
	run(c, "sadd", "si", "1", "2")
	run(c, "sadd", "ss", "a")
	run(c, "zadd", "z", "1", "a")
	run(c, "hset", "h", "f", "v")
	run(c, "xadd", "x", "1-1", "f", "v")
	run(c, "set", "big", HUNDRED_A)
}

@(test)
dump_framing_matches_observed_bytes :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	seed_types(c)
	cases := [?][2]string {
		{"s", OBSERVED_STRING},
		{"i", OBSERVED_INT},
		{"l", OBSERVED_LIST},
		{"si", OBSERVED_INTSET},
		{"ss", OBSERVED_SET},
		{"z", OBSERVED_ZSET},
		{"h", OBSERVED_HASH},
		{"x", OBSERVED_STREAM},
	}
	for pair in cases {
		testing.expectf(t, hex_encode(dump_of(c, pair[0])) == pair[1], "DUMP %s framing differs", pair[0])
	}
	run(c, "config", "set", "rdbcompression", "yes")
	testing.expect_value(t, hex_encode(dump_of(c, "big")), OBSERVED_BIG_LZF)
	run(c, "config", "set", "rdbcompression", "no")
	plain := dump_of(c, "big")
	testing.expect_value(t, len(plain), 113)
	testing.expect_value(t, plain[0], u8(0))
	testing.expect(t, eski.dump_verify(plain))
}

@(test)
dump_missing_key_is_nil :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	testing.expect_value(t, run(c, "dump", "missing"), "$-1\r\n")
	testing.expect_value(t, run(c, "dump"), "-ERR wrong number of arguments for 'dump' command\r\n")
	testing.expect_value(t, run(c, "dump", "a", "b"), "-ERR wrong number of arguments for 'dump' command\r\n")
}

@(test)
dump_counts_no_change_and_emits_no_event :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	run(c, "set", "ev1", "hello")
	sub := subscribe_events(c, "KEA")
	before := eski.pst.dirty
	testing.expect_value(t, hex_encode(dump_of(c, "ev1")), OBSERVED_STRING)
	testing.expect_value(t, eski.pst.dirty, before)
	testing.expect_value(t, take_events(sub), "")
}

@(test)
dump_hash_with_field_ttl_carries_absolute_expiry :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	run(c, "hset", "h", "f", "v")
	run(c, "hpexpire", "h", "100000", "FIELDS", "1", "f")
	got := dump_of(c, "h")
	testing.expect_value(t, len(got), 43)
	if len(got) != 43 {
		return
	}
	testing.expect_value(t, got[0], u8(rdb.TYPE_HASH_LISTPACK_EX))
	at: i64 = 0
	for i in 0 ..< 8 {
		at |= i64(got[1 + i]) << (8 * uint(i))
	}
	now := eski.expire_now()
	testing.expectf(t, at > now + 98000 && at <= now + 100000, "field expiry %d not near now+100000", at)
	stamp := got[1:9]
	want := make([dynamic]u8, heap())
	append(&want, rdb.TYPE_HASH_LISTPACK_EX)
	append(&want, ..stamp)
	append(&want, ..hex_decode("17170000000300816602817602f4"))
	append(&want, ..stamp)
	append(&want, ..hex_decode("09ff0c00"))
	sum := rdb.crc64(0, want[:])
	for i in 0 ..< 8 {
		append(&want, u8(sum >> (8 * uint(i))))
	}
	testing.expect_value(t, hex_encode(got), hex_encode(want[:]))
}

@(test)
dump_verify_checks_version_and_checksum :: proc(t: ^testing.T) {
	context.allocator = heap()
	fresh()
	good := hex_decode(OBSERVED_STRING)
	testing.expect(t, eski.dump_verify(good))
	testing.expect(t, !eski.dump_verify(good[:9]))
	testing.expect(t, !eski.dump_verify(nil))
	flipped := make([]u8, len(good), heap())
	copy(flipped, good)
	flipped[len(flipped) - 1] ~= 0x01
	testing.expect(t, !eski.dump_verify(flipped))
	newer := make([]u8, len(good), heap())
	copy(newer, good)
	newer[len(newer) - 10] = rdb.RDB_VERSION + 1
	testing.expect(t, !eski.dump_verify(newer))
	older := make([]u8, len(good), heap())
	copy(older, good)
	older[len(older) - 10] = 9
	reseal(older)
	testing.expect(t, eski.dump_verify(older))
	eski.pst.skip_checksum = true
	testing.expect(t, eski.dump_verify(flipped))
	testing.expect(t, !eski.dump_verify(newer))
	testing.expect(t, !eski.dump_verify(good[:9]))
	eski.pst.skip_checksum = false
}

@(test)
dump_payload_appends_self_contained_frames :: proc(t: ^testing.T) {
	context.allocator = heap()
	c := fresh()
	run(c, "set", "s", "hello")
	run(c, "rpush", "l", "a", "b")
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	defer rdb.writer_destroy(&w)
	rdb.put_raw(&w, bytes("junk"))
	e := eski.db_find(bytes("s"))
	eski.dump_payload(&w, bytes("s"), eski.persist_slot_value(&eski.dbs[0], e.kp, e.vp))
	mid := w.len
	f := eski.db_find(bytes("l"))
	eski.dump_payload(&w, bytes("l"), eski.persist_slot_value(&eski.dbs[0], f.kp, f.vp))
	all := rdb.writer_bytes(&w)
	testing.expect_value(t, hex_encode(all[4:mid]), OBSERVED_STRING)
	testing.expect_value(t, hex_encode(all[mid:]), OBSERVED_LIST)
}

reseal :: proc(p: []u8) {
	n := len(p)
	sum := rdb.crc64(0, p[:n - 8])
	for i in 0 ..< 8 {
		p[n - 8 + i] = u8(sum >> (8 * uint(i)))
	}
}

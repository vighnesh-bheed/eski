package persistence

import "core:encoding/hex"
import "core:strings"
import "core:testing"
import j "../../src"
import "../../src/rdb"

dump_hex :: proc(key: string) -> string {
	reply := cmd("DUMP", key)
	if !strings.has_prefix(reply, "$") || reply == "$-1\r\n" {
		return reply
	}
	start := strings.index(reply, "\r\n") + 2
	body := reply[start:len(reply) - 2]
	return string(hex.encode(transmute([]u8)body, context.temp_allocator))
}

from_hex :: proc(s: string) -> []u8 {
	out, _ := hex.decode(transmute([]u8)s, context.temp_allocator)
	return out
}

restore :: proc(key: string, ttl: string, payload: []u8, extra: ..string) -> string {
	argv := make([dynamic][]u8, context.temp_allocator)
	append(&argv, transmute([]u8)string("RESTORE"), transmute([]u8)key, transmute([]u8)ttl, payload)
	for e in extra {
		append(&argv, transmute([]u8)e)
	}
	return cmdv(argv[:])
}

frame :: proc(body: []u8, version: u16 = 12) -> []u8 {
	out := make([]u8, len(body) + 10, context.temp_allocator)
	copy(out, body)
	out[len(body)] = u8(version)
	out[len(body) + 1] = u8(version >> 8)
	crc := rdb.crc64(0, out[:len(body) + 2])
	for i in 0 ..< 8 {
		out[len(body) + 2 + i] = u8(crc >> (8 * uint(i)))
	}
	return out
}

@(test)
dump_payloads_match_reference :: proc(t: ^testing.T) {
	server_reset()
	expect_reply(t, cmd("CONFIG", "SET", "rdbcompression", "no"), "+OK\r\n", "compression off")
	cmd("SET", "s", "hello")
	testing.expect_value(t, dump_hex("s"), "000568656c6c6f0c00a804ebb69f1ebe43")
	cmd("SET", "i", "42")
	testing.expect_value(t, dump_hex("i"), "00c02a0c004a8d683a7c49d119")
	cmd("RPUSH", "l", "a", "b")
	testing.expect_value(t, dump_hex("l"), "1201020d0d0000000200816102816202ff0c00a39d3e49e96b25f8")
	cmd("SADD", "si", "1", "2")
	testing.expect_value(t, dump_hex("si"), "0b0c0200000002000000010002000c00a40f0c71cec1be67")
	cmd("SADD", "ss", "a")
	testing.expect_value(t, dump_hex("ss"), "140a0a0000000100816102ff0c005576f6689e5a0cb4")
	cmd("ZADD", "z", "1", "a")
	testing.expect_value(t, dump_hex("z"), "110c0c00000002008161020101ff0c006373fa782d83ad4b")
	cmd("HSET", "h", "f", "v")
	testing.expect_value(t, dump_hex("h"), "100d0d0000000200816602817602ff0c00eb870984d97e96d4")
	cmd("XADD", "x", "1-1", "f", "v")
	testing.expect_value(t, dump_hex("x"), "150110000000000000000100000000000000011d1d0000000a0001010001010181660200010201000100018176020401ff0101010101000001000c0047f32561afb1fbb3")
	expect_reply(t, cmd("DUMP", "missing"), "$-1\r\n", "missing")
	big := strings.repeat("a", 100, context.temp_allocator)
	cmd("SET", "big", big)
	expect_reply(t, cmd("CONFIG", "SET", "rdbcompression", "yes"), "+OK\r\n", "compression on")
	testing.expect_value(t, dump_hex("big"), "00c3094064016161e057000161610c0023d581c74a476c38")
	cmd("HPEXPIRE", "h", "100000", "FIELDS", "1", "f")
	hfe := from_hex(dump_hex("h"))
	testing.expect_value(t, len(hfe), 43)
	testing.expect_value(t, hfe[0], u8(rdb.TYPE_HASH_LISTPACK_EX))
	min_ms: i64
	for i in 0 ..< 8 {
		min_ms |= i64(hfe[1 + i]) << (8 * uint(i))
	}
	testing.expect(t, min_ms > unix_ms() && min_ms <= unix_ms() + 100_000)
	server_reset()
}

@(test)
restore_type_payloads :: proc(t: ^testing.T) {
	server_reset()
	Payload :: struct {
		key:      string,
		hex:      string,
		kind:     string,
		encoding: string,
	}
	payloads := []Payload {
		{"copy:i", "00c02a0c004a8d683a7c49d119", "+string\r\n", "int"},
		{"copy:l", "1201020d0d0000000200816102816202ff0c00a39d3e49e96b25f8", "+list\r\n", "listpack"},
		{"copy:si", "0b0c0200000002000000010002000c00a40f0c71cec1be67", "+set\r\n", "intset"},
		{"copy:ss", "140a0a0000000100816102ff0c005576f6689e5a0cb4", "+set\r\n", "listpack"},
		{"copy:z", "110c0c00000002008161020101ff0c006373fa782d83ad4b", "+zset\r\n", "listpack"},
		{"copy:x", "150110000000000000000100000000000000011d1d0000000a0001010001010181660200010201000100018176020401ff0101010101000001000c0047f32561afb1fbb3", "+stream\r\n", "stream"},
		{"copy:big", "00c3094064016161e057000161610c0023d581c74a476c38", "+string\r\n", "raw"},
		{"copy:s", "000568656c6c6f0c00a804ebb69f1ebe43", "+string\r\n", "embstr"},
	}
	for p in payloads {
		expect_reply(t, restore(p.key, "0", from_hex(p.hex)), "+OK\r\n", p.key)
		expect_reply(t, cmd("TYPE", p.key), p.kind, p.key)
		expect_reply(t, cmd("OBJECT", "ENCODING", p.key), bulk(p.encoding), p.key)
	}
	expect_reply(t, cmd("XINFO", "STREAM", "copy:x"), "*20\r\n$6\r\nlength\r\n:1\r\n$15\r\nradix-tree-keys\r\n:1\r\n$16\r\nradix-tree-nodes\r\n:2\r\n$17\r\nlast-generated-id\r\n$3\r\n1-1\r\n$20\r\nmax-deleted-entry-id\r\n$3\r\n0-0\r\n$13\r\nentries-added\r\n:1\r\n$23\r\nrecorded-first-entry-id\r\n$3\r\n1-1\r\n$6\r\ngroups\r\n:0\r\n$11\r\nfirst-entry\r\n*2\r\n$3\r\n1-1\r\n*2\r\n$1\r\nf\r\n$1\r\nv\r\n$10\r\nlast-entry\r\n*2\r\n$3\r\n1-1\r\n*2\r\n$1\r\nf\r\n$1\r\nv\r\n", "xinfo")
	expect_reply(t, cmd("GET", "copy:big"), bulk(strings.repeat("a", 100, context.temp_allocator)), "big value")
	expect_reply(t, cmd("LRANGE", "copy:l", "0", "-1"), "*2\r\n$1\r\na\r\n$1\r\nb\r\n", "list value")
	server_reset()
}

@(test)
restore_lru_and_rejections :: proc(t: ^testing.T) {
	server_reset()
	payload := from_hex("000568656c6c6f0c00a804ebb69f1ebe43")
	expect_reply(t, restore("r1", "0", payload), "+OK\r\n", "restore")
	expect_reply(t, cmd("GET", "r1"), bulk("hello"), "restored value")
	expect_reply(t, restore("r1", "0", payload), "-BUSYKEY Target key name already exists.\r\n", "busykey")
	expect_reply(t, restore("r1", "0", payload, "REPLACE"), "+OK\r\n", "replace")
	expect_reply(t, restore("r2", "5000", payload), "+OK\r\n", "ttl")
	pttl := cmd("PTTL", "r2")
	testing.expectf(t, pttl == ":5000\r\n" || pttl == ":4999\r\n", "pttl %q", pttl)
	expect_reply(t, restore("r5", "0", payload, "IDLETIME", "1000"), "+OK\r\n", "idletime")
	expect_reply(t, cmd("OBJECT", "IDLETIME", "r5"), integer(1000), "object idletime")
	expect_reply(t, cmd("CONFIG", "SET", "maxmemory-policy", "allkeys-lfu"), "+OK\r\n", "lfu")
	expect_reply(t, restore("r6", "0", payload, "FREQ", "200"), "+OK\r\n", "freq")
	expect_reply(t, cmd("OBJECT", "FREQ", "r6"), integer(200), "object freq")
	expect_reply(t, cmd("CONFIG", "SET", "maxmemory-policy", "noeviction"), "+OK\r\n", "noeviction")
	wrong := "-ERR DUMP payload version or checksum are wrong\r\n"
	mutated: [dynamic][]u8
	mutated.allocator = context.temp_allocator
	for n in 0 ..< len(payload) {
		append(&mutated, payload[:n])
	}
	for i in 0 ..< len(payload) {
		m := make([]u8, len(payload), context.temp_allocator)
		copy(m, payload)
		m[i] ~= 0x21
		append(&mutated, m)
	}
	longer := make([]u8, len(payload) + 1, context.temp_allocator)
	copy(longer, payload)
	append(&mutated, longer)
	append(&mutated, frame(from_hex("000568656c6c6f"), 13))
	append(&mutated, frame(from_hex("000568656c6c6f"), 0xFFFF))
	for m in mutated {
		expect_reply(t, restore("bad", "0", m, "REPLACE"), wrong, "mutated payload")
	}
	expect_reply(t, cmd("EXISTS", "bad"), integer(0), "nothing restored")
	older := frame(from_hex("000568656c6c6f"), 9)
	expect_reply(t, restore("old", "0", older), "+OK\r\n", "older version accepted")
	bad_data := "-ERR Bad data format\r\n"
	expect_reply(t, restore("bad", "0", frame(from_hex("003f68656c6c6f"))), bad_data, "short string")
	expect_reply(t, restore("bad", "0", frame(from_hex("1e0568656c6c6f"))), bad_data, "unknown type")
	expect_reply(t, restore("bad", "0", frame(from_hex("00c4"))), bad_data, "unknown string encoding")
	expect_reply(t, restore("bad", "0", frame(from_hex("00c3050a0000000000"))), bad_data, "corrupt lzf")
	expect_reply(t, restore("bad", "0", frame(from_hex("12010205000000"))), bad_data, "corrupt quicklist")
	for body in ([]string{"0598016140000000000000f03f", "059b016140000000000000f03f", "0498016101", "049c016101", "02b30161", "03b30161033132"}) {
		expect_reply(t, restore("bad", "0", frame(from_hex(body))), bad_data, body)
		expect_reply(t, restore("bad", "0", frame(from_hex(body)), "REPLACE"), bad_data, body)
	}
	expect_reply(t, cmd("EXISTS", "bad"), integer(0), "unknown count bytes restore nothing")
	dup_set := from_hex("140d0d0000000200816102816102ff")
	expect_reply(t, cmd("CONFIG", "SET", "sanitize-dump-payload", "yes"), "+OK\r\n", "sanitize yes")
	expect_reply(t, restore("dup", "0", frame(dup_set)), bad_data, "duplicate members with sanitize")
	expect_reply(t, restore("lr", "0", from_hex("1201020d0d0000000200816102816202ff0c00a39d3e49e96b25f8")), "+OK\r\n", "sanitized list")
	expect_reply(t, cmd("LRANGE", "lr", "0", "-1"), "*2\r\n$1\r\na\r\n$1\r\nb\r\n", "sanitized list value")
	expect_reply(t, cmd("CONFIG", "SET", "sanitize-dump-payload", "no"), "+OK\r\n", "sanitize no")
	server_reset()
}

@(test)
dump_round_trip_every_type :: proc(t: ^testing.T) {
	server_reset()
	populate_all_types()
	push := []string{"RPUSH", "biglist", "a", strings.repeat("b", 5000, context.temp_allocator), "c"}
	cmd(..push)
	keys := []string{"k1", "num", "long", "l", "e", "si", "ss", "z", "h", "x", "biglist"}
	for key in keys {
		payload := from_hex(dump_hex(key))
		testing.expect(t, len(payload) > 10)
		digest := cmd("DEBUG", "DIGEST-VALUE", key)
		target := strings.concatenate({"copy:", key}, context.temp_allocator)
		expect_reply(t, restore(target, "0", payload), "+OK\r\n", key)
		digest_copy := cmd("DEBUG", "DIGEST-VALUE", target)
		expect_reply(t, digest_copy, digest, key)
		testing.expect_value(t, dump_hex(target), dump_hex(key))
		if key == "h" {
			expect_reply(t, cmd("OBJECT", "ENCODING", target), bulk("listpackex"), "hfe encoding")
			testing.expect(t, cmd("HPTTL", target, "FIELDS", "1", "f") != "*1\r\n:-1\r\n")
		}
		r: rdb.Reader
		rdb.reader_init_mem(&r, payload[:len(payload) - 10], false)
		v := j.persist_load_object(&r, rdb.get_type(&r), true)
		testing.expect(t, rdb.ok(&r))
		testing.expect_value(t, rdb.reader_offset(&r), i64(len(payload) - 10))
		j.persist_free_loaded(v)
		rdb.reader_destroy(&r)
	}
	server_reset()
}

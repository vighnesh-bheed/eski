package groups_test

import rdb "../../src/rdb"
import st "../../src/streamtype"
import "core:encoding/hex"
import "core:testing"

TRANSCRIPT_DUMP :: "15011000000000000000010000000000000000408b8b0000003700090101010101816602000102010001000182763103040102010101000182763203040102010201000182763303040102010301000182763403040102010401000182763503040102010501000182763603040102010601000182763703040103010701000182763803040102010801000182763903040102010901000183763130040401ff090a00010008000a01016714000a05000000000000000400000000000000009547867ca101000005000000000000000500000000000000009547867ca101000004000000000000000700000000000000009547867ca101000007000000000000000900000000000000009547867ca101000005000000000000000a00000000000000009547867ca1010000070505616c6963659147867ca10100008f47867ca10100000003626f628c47867ca10100008c47867ca101000000056361726f6c9347867ca10100009347867ca10100000004646176659347867ca1010000ffffffffffffffff00046572696e9547867ca10100009547867ca10100000500000000000000040000000000000000000000000000000500000000000000000000000000000007000000000000000000000000000000090000000000000000000000000000000a00000000000000000c00895ae70aa10f7a03"

load_payload :: proc(payload: []u8) -> st.Stream {
	rd: rdb.Reader
	rdb.reader_init_mem(&rd, payload[1:len(payload) - 10], false)
	defer rdb.reader_destroy(&rd)
	return st.rdb_load(&rd, int(payload[0]), true)
}

save_payload :: proc(s: st.Stream) -> []u8 {
	w: rdb.Writer
	rdb.writer_init_mem(&w, false, false)
	defer rdb.writer_destroy(&w)
	rdb.put_u8(&w, st.rdb_type(s))
	st.rdb_save(&w, s)
	out := make([]u8, len(rdb.writer_bytes(&w)), context.temp_allocator)
	copy(out, rdb.writer_bytes(&w))
	return out
}

@(test)
transcript_dump_loads_groups_consumers_and_pending :: proc(t: ^testing.T) {
	payload, ok := hex.decode(transmute([]u8)string(TRANSCRIPT_DUMP), context.temp_allocator)
	testing.expect(t, ok)
	s := load_payload(payload)
	testing.expect(t, s != nil)
	defer st.destroy(s)
	testing.expect(t, same_strings(group_names(s), {"g"}))
	g := st.find_group(s, b("g"))
	testing.expect_value(t, g.delivered, id(20))
	testing.expect_value(t, g.reads, 10)
	expect_lag(t, s, g, 0)
	testing.expect(t, same_ids(pel_ids(g.pending), ids({4, 0}, {5, 0}, {7, 0}, {9, 0}, {10, 0})))
	testing.expect(t, same_strings(consumer_names(g), {"alice", "bob", "carol", "dave", "erin"}))
	erin := st.find_member(g, b("erin"))
	testing.expect_value(t, erin.owned.numele, 5)
	testing.expect_value(t, erin.seen_ms, 1793090537365)
	testing.expect_value(t, erin.active_ms, 1793090537365)
	dave := st.find_member(g, b("dave"))
	testing.expect_value(t, dave.active_ms, -1)
	testing.expect_value(t, dave.seen_ms, 1793090537363)
	n4 := st.find_delivery(g, id(4))
	testing.expect(t, n4.owner == erin && n4.times == 5 && n4.sent_ms == 1793090537365)
	testing.expect_value(t, st.find_delivery(g, id(5)).times, 4)
	again := save_payload(s)
	testing.expect_value(t, string(again), string(payload[:len(payload) - 10]))
}

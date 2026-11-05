package groups_test

import st "../../src/streamtype"
import "core:encoding/hex"
import "core:testing"

@(test)
lag_after_xsetid_sequence :: proc(t: ^testing.T) {
	s := st.create()
	defer st.destroy(s)
	add(t, s, 1, 1)
	add(t, s, 1, 2)
	g := st.add_group(s, b("g"), id(0), -1)
	st.group_set_id(g, id(1, 2), 2)
	expect_lag(t, s, g, 0)
	setid :: proc(s: st.Stream, x: st.ID, added: i64, md: st.ID) -> st.Error {
		a := st.Setid_Args{id = x, entries_added = added, max_deleted_id = md}
		return st.xsetid_apply(s, &a)
	}
	testing.expect_value(t, setid(s, id(1, 2), 0, id(0)), st.Error.Setid_Entries_Added)
	testing.expect_value(t, setid(s, id(1, 2), 1, id(0)), st.Error.Setid_Entries_Added)
	expect_lag(t, s, g, 0)
	setid(s, id(1, 2), 5, id(0))
	expect_lag(t, s, g, 3)
	setid(s, id(1, 2), 2, id(1, 1))
	expect_lag(t, s, g, 0)
	setid(s, id(1, 2), 2, id(1, 2))
	expect_lag(t, s, g, 0)
	setid(s, id(9, 9), 2, id(5))
	expect_lag_unknown(t, s, g)
	setid(s, id(9, 9), 2, id(1, 2))
	expect_lag_unknown(t, s, g)
	setid(s, id(9, 9), 2, id(0))
	expect_lag_unknown(t, s, g)
	setid(s, id(9, 9), 7, id(0))
	expect_lag_unknown(t, s, g)
	expect_read(t, g, 2)
	st.group_set_id(g, id(1, 1), 1)
	setid(s, id(1, 2), 2, id(0))
	expect_lag_unknown(t, s, g)
	setid(s, id(1, 2), 2, id(1, 1))
	expect_lag_unknown(t, s, g)
	setid(s, id(1, 2), 2, id(1, 2))
	expect_lag_unknown(t, s, g)
	expect_read(t, g, 1)
}

@(test)
lag_with_corrupt_header_values :: proc(t: ^testing.T) {
	s := st.create()
	defer st.destroy(s)
	add(t, s, 1, 1)
	add(t, s, 1, 2)
	g := st.add_group(s, b("g"), id(1, 2), 2)
	s.tomb = st.ID{max(u64), 0}
	expect_lag_unknown(t, s, g)
	s.tomb = id(5)
	expect_lag_unknown(t, s, g)
	s.tomb = id(1)
	expect_lag(t, s, g, 0)
	s.tomb = id(0, 5)
	expect_lag(t, s, g, 0)
	s.tomb = id(0)
	s.added = 0
	expect_lag(t, s, g, 0)
	s.added = 1
	expect_lag(t, s, g, -1)
	s.added = max(u64)
	expect_lag(t, s, g, -3)
	st.group_set_id(g, id(1, 2), -1)
	expect_lag_unknown(t, s, g)
	st.group_set_id(g, id(1, 1), -1)
	s.added = 7
	expect_lag(t, s, g, 1)
}

ORACLE_PAYLOADS := [?]struct {
	name:    string,
	payload: string,
	lag:     Maybe(i64),
} {
	{"header field maxdel_ms written as 82", "1501100000000000000001000000000000000126260000000f0002010001010181610200010201000100010101040102010001010102010401ff020102010182000201016701020201000000000000000100000000000000020068e5cf8b010000030101630068e5cf8b0100000068e5cf8b01000001000000000000000100000000000000020c000000000000000000", nil},
	{"header field maxdel_ms written as bf", "1501100000000000000001000000000000000126260000000f0002010001010181610200010201000100010101040102010001010102010401ff0201020101bf000201016701020201000000000000000100000000000000020068e5cf8b010000030101630068e5cf8b0100000068e5cf8b01000001000000000000000100000000000000020c000000000000000000", nil},
	{"header field maxdel_ms written as c5", "1501100000000000000001000000000000000126260000000f0002010001010181610200010201000100010101040102010001010102010401ff0201020101c5000201016701020201000000000000000100000000000000020068e5cf8b010000030101630068e5cf8b0100000068e5cf8b01000001000000000000000100000000000000020c000000000000000000", nil},
	{"header field added written as c0", "1501100000000000000001000000000000000126260000000f0002010001010181610200010201000100010101040102010001010102010401ff02010201010000c001016701020201000000000000000100000000000000020068e5cf8b010000030101630068e5cf8b0100000068e5cf8b01000001000000000000000100000000000000020c000000000000000000", 0},
	{"header field added written as c1", "1501100000000000000001000000000000000126260000000f0002010001010181610200010201000100010101040102010001010102010401ff02010201010000c101016701020201000000000000000100000000000000020068e5cf8b010000030101630068e5cf8b0100000068e5cf8b01000001000000000000000100000000000000020c000000000000000000", -1},
	{"header field added written as 82", "1501100000000000000001000000000000000126260000000f0002010001010181610200010201000100010101040102010001010102010401ff020102010100008201016701020201000000000000000100000000000000020068e5cf8b010000030101630068e5cf8b0100000068e5cf8b01000001000000000000000100000000000000020c000000000000000000", -3},
	{"header field maxdel_ms written as c1", "1501100000000000000001000000000000000126260000000f0002010001010181610200010201000100010101040102010001010102010401ff0201020101c1000201016701020201000000000000000100000000000000020068e5cf8b010000030101630068e5cf8b0100000068e5cf8b01000001000000000000000100000000000000020c000000000000000000", 0},
}

@(test)
lag_of_oracle_payloads_with_odd_headers :: proc(t: ^testing.T) {
	for c in ORACLE_PAYLOADS {
		payload, ok := hex.decode(transmute([]u8)c.payload, context.temp_allocator)
		testing.expect(t, ok)
		s := load_payload(payload)
		if s == nil {
			testing.expectf(t, false, "%s: payload did not load", c.name)
			continue
		}
		g := st.find_group(s, b("g"))
		lag, known := st.group_lag(s, g)
		want, has := c.lag.?
		testing.expectf(t, known == has && (!has || lag == want), "%s: lag %v known %v want %v", c.name, lag, known, c.lag)
		st.destroy(s)
	}
}

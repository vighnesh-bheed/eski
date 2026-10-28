package streams_test

import rx "../../src/rax"
import st "../../src/streamtype"
import "core:testing"

@(test)
corrupt_payloads_are_rejected :: proc(t: ^testing.T) {
	good := hex_decode(S1_DEL_ONE, context.temp_allocator)
	body := good[:len(good) - 10]
	for cut in 1 ..< len(body) - 1 {
		s, _ := load_payload(body[:cut], true)
		testing.expectf(t, s == nil, "truncated at %d accepted", cut)
		if s != nil {
			st.destroy(s)
		}
	}
	rejected := 0
	for k in 1 ..< len(body) {
		for x in ([]u8{0x01, 0x40, 0x80, 0xff}) {
			mutated := make([]u8, len(body), context.temp_allocator)
			copy(mutated, body)
			mutated[k] ~= x
			s, _ := load_payload(mutated, true)
			if s == nil {
				rejected += 1
				continue
			}
			collect(s, nil, nil, 0, false)
			collect(s, nil, nil, 0, true)
			xadd(s, "*", "f", "v")
			xtrim(s, "MAXLEN", "1")
			st.destroy(s)
		}
	}
	testing.expect(t, rejected > 0)
	bad_term := hex_decode(S1_DEL_ONE, context.temp_allocator)
	bad_term[36] = 0x01
	testing.expect(t, !st.validate_node(&bad_term[21], 74))
	bad_span := hex_decode(S1_DEL_ONE, context.temp_allocator)
	bad_span[47] = 0x05
	testing.expect(t, !st.validate_node(&bad_span[21], 74))
	loose := hex_decode(S1_DEL_ONE, context.temp_allocator)
	loose[25] = 0x7f
	loose[38] = 0x2e
	testing.expect(t, st.validate_node(&loose[21], 74))
	loose[27] = 0x04
	testing.expect(t, !st.validate_node(&loose[21], 74))
	fine := hex_decode(S1_DEL_ONE, context.temp_allocator)
	testing.expect(t, st.validate_node(&fine[21], 74))
}

@(private = "file")
FUZZ_DELETED_30 :: "150110000000000000000500000000000000051d1d0000000a0001011e01010181610200010201000100018162020401ff0105050505000001000c00112a12458b4dc3f0"

@(private = "file")
FUZZ_LIVE_51 :: "150110000000000000000500000000000000051d1d0000000a0033010001010181610200010201000100018162020401ff0105050505000001000c00112a12458b4dc3f0"

@(test)
legacy_types_record_the_first_entry :: proc(t: ^testing.T) {
	empty15 := []u8{15, 0, 0, 5, 5, 0}
	e15, _ := load_payload(empty15, true)
	testing.expect(t, e15 != nil && e15.first_id == st.ID_MAX && e15.last_id == st.ID{5, 5})
	empty19 := []u8{19, 0, 0, 5, 5, 0, 0, 0, 0, 0, 0}
	e19, _ := load_payload(empty19, true)
	testing.expect(t, e19 != nil && e19.first_id == st.ID_MIN)
	stored19 := []u8{19, 0, 0, 5, 5, 7, 7, 0, 0, 0, 0}
	k19, _ := load_payload(stored19, true)
	testing.expect(t, k19 != nil && k19.first_id == st.ID{7, 7})
	s := new_stream_from({{"XADD", "s", "1-1", "a", "1"}, {"XADD", "s", "1-2", "a", "2"}, {"XADD", "s", "1-3", "a", "3"}})
	defer st.destroy(s)
	testing.expect_value(t, st.xdel_apply(s, {st.ID{1, 1}}), 1)
	p21 := dump_payload(s, context.temp_allocator)
	body := p21[:len(p21) - 10]
	n := len(body)
	testing.expect(t, body[n - 9] == 2 && body[n - 6] == 1 && body[n - 5] == 2 && body[n - 1] == 0)
	p15 := make([dynamic]u8, context.temp_allocator)
	append(&p15, 15)
	append(&p15, ..body[1:n - 9])
	append(&p15, ..body[n - 9:n - 6])
	append(&p15, 0)
	f15, _ := load_payload(p15[:], true)
	testing.expect(t, f15 != nil && f15.first_id == st.ID{1, 2} && st.length(f15) == 2)
	p19 := make([]u8, n, context.temp_allocator)
	copy(p19, body)
	p19[0] = 19
	f19, _ := load_payload(p19, true)
	testing.expect(t, f19 != nil && f19.first_id == st.ID{1, 2})
	for x in ([]st.Stream{e15, e19, k19, f15, f19}) {
		if x != nil {
			st.destroy(x)
		}
	}
}

@(private = "file")
grouped_payload :: proc() -> []u8 {
	s := new_stream_from({{"XADD", "s", "1-1", "a", "1"}, {"XADD", "s", "1-2", "a", "2"}})
	defer st.destroy(s)
	cg := st.create_cg(s, bytes_of("g"), st.ID{1, 2}, 2)
	c := st.create_consumer(s, cg, bytes_of("c"), 1700000000000)
	st.group_deliver(s, cg, c, st.ID{1, 2}, false, 1700000000000)
	return dump_payload(s, context.temp_allocator)
}

@(test)
header_lengths_decode_leniently :: proc(t: ^testing.T) {
	base := grouped_payload()
	h := 20 + int(base[19])
	testing.expect(t, base[1] == 1 && base[h + 8] == 1 && base[h + 14] == 1 && base[h + 40] == 1 && base[h + 59] == 1)
	Field :: struct {
		name:   string,
		at:     int,
		accept: [5]bool,
	}
	all := [5]bool{true, true, true, true, true}
	counted := [5]bool{false, false, true, true, false}
	owner := [5]bool{false, false, false, true, false}
	fields := []Field {
		{"nodes", 1, owner},
		{"length", h, all},
		{"last_ms", h + 1, all},
		{"last_seq", h + 2, all},
		{"first_ms", h + 3, all},
		{"first_seq", h + 4, all},
		{"maxdel_ms", h + 5, all},
		{"maxdel_seq", h + 6, all},
		{"added", h + 7, all},
		{"groups", h + 8, counted},
		{"cg_ms", h + 11, all},
		{"cg_seq", h + 12, all},
		{"cg_read", h + 13, all},
		{"pel", h + 14, counted},
		{"pel_count", h + 39, all},
		{"consumers", h + 40, owner},
		{"cpel", h + 59, owner},
	}
	marks := [5]u8{0x82, 0xbf, 0xc0, 0xc1, 0xc5}
	for f in fields {
		for mark, i in marks {
			mutated := make([]u8, len(base), context.temp_allocator)
			copy(mutated, base)
			mutated[f.at] = mark
			s, _ := load_payload(mutated[:len(mutated) - 10], true)
			testing.expectf(t, (s != nil) == f.accept[i], "%s written as %x: accepted %v", f.name, mark, s != nil)
			if s != nil {
				collect(s, nil, nil, 0, false)
				st.destroy(s)
			}
		}
	}
	read :: proc(base: []u8, at: int, mark: u8) -> st.Stream {
		mutated := make([]u8, len(base), context.temp_allocator)
		copy(mutated, base)
		mutated[at] = mark
		s, _ := load_payload(mutated[:len(mutated) - 10], true)
		return s
	}
	a := read(base, h, 0x82)
	testing.expect(t, a != nil && st.length(a) == max(u64))
	b := read(base, h + 1, 0xc5)
	testing.expect(t, b != nil && b.last_id == st.ID{5, 2})
	c := read(base, h + 4, 0xbf)
	testing.expect(t, c != nil && c.first_id == st.ID{1, max(u64)})
	d := read(base, h + 7, 0xc0)
	testing.expect(t, d != nil && d.entries_added == 0)
	for x in ([]st.Stream{a, b, c, d}) {
		if x != nil {
			st.destroy(x)
		}
	}
}

@(test)
deep_loads_accept_what_the_reader_accepts :: proc(t: ^testing.T) {
	base := grouped_payload()
	lp := 20
	cases := [][2]int{{lp + 4, 0x7f}, {lp + 17, 0x2e}, {lp + 19, 0x05}}
	for m in cases {
		mutated := make([]u8, len(base), context.temp_allocator)
		copy(mutated, base)
		mutated[m[0]] = u8(m[1])
		s, _ := load_payload(mutated[:len(mutated) - 10], true)
		testing.expectf(t, s != nil, "node byte %d set to %x rejected", m[0] - lp, m[1])
		if s != nil {
			collect(s, nil, nil, 0, false)
			collect(s, nil, nil, 0, true)
			xadd(s, "*", "f", "v")
			xtrim(s, "MAXLEN", "1")
			st.destroy(s)
		}
	}
	recount := make([]u8, len(base), context.temp_allocator)
	copy(recount, base)
	recount[lp + 6] = 0x05
	miscounted, _ := load_payload(recount[:len(recount) - 10], true)
	testing.expect(t, miscounted == nil)
	if miscounted != nil {
		st.destroy(miscounted)
	}
	lax, _ := load_payload(recount[:len(recount) - 10], false)
	testing.expect(t, lax != nil)
	if lax != nil {
		st.destroy(lax)
	}
	for bad in ([]string{FUZZ_DELETED_30, FUZZ_LIVE_51}) {
		payload := hex_decode(bad, context.temp_allocator)
		body := payload[:len(payload) - 10]
		deep_bad, _ := load_payload(body, true)
		testing.expect(t, deep_bad == nil)
		if deep_bad != nil {
			st.destroy(deep_bad)
		}
		testing.expect(t, !st.validate_node(&payload[20], 29))
	}
	ttl := hex_decode(FUZZ_DELETED_30, context.temp_allocator)
	ttl[28] = 0x00
	fine, _ := load_payload(ttl[:len(ttl) - 10], true)
	testing.expect(t, fine != nil && st.length(fine) == 1)
	if fine != nil {
		st.destroy(fine)
	}
	empty := []u8{21, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0}
	deep, _ := load_payload(empty, true)
	testing.expect(t, deep == nil)
	shallow, _ := load_payload(empty, false)
	testing.expect(t, shallow != nil && st.length(shallow) == 2)
	if shallow != nil {
		st.destroy(shallow)
	}
	none := []u8{21, 0, 0, 1, 1, 0, 0xd8, 1, 1, 1, 0}
	ok, _ := load_payload(none, true)
	testing.expect(t, ok != nil && ok.first_id == st.ID{0, 24} && ok.max_deleted_entry_id == st.ID{1, 1})
	if ok != nil {
		st.destroy(ok)
	}
}

@(test)
groups_survive_codec :: proc(t: ^testing.T) {
	s := new_stream_from({{"XADD", "s", "1-1", "a", "1"}, {"XADD", "s", "2-2", "a", "2"}, {"XADD", "s", "3-3", "b", "3"}})
	defer st.destroy(s)
	g1 := st.create_cg(s, bytes_of("g1"), st.ID{0, 0}, st.SCG_INVALID_ENTRIES_READ)
	g2 := st.create_cg(s, bytes_of("12345"), st.ID{2, 2}, 2)
	alice := st.create_consumer(s, g1, bytes_of("alice"), 1000)
	bob := st.create_consumer(s, g1, bytes_of("-7"), 1100)
	st.group_deliver(s, g1, alice, st.ID{1, 1}, false, 2000)
	st.group_deliver(s, g1, bob, st.ID{2, 2}, false, 2100)
	st.group_deliver(s, g1, alice, st.ID{3, 3}, false, 2200)
	st.create_consumer(s, g2, bytes_of(""), 3000)
	payload := dump_payload(s, context.temp_allocator)
	back, consumed := load_payload(payload, true)
	testing.expect(t, back != nil && consumed == len(payload) - 10)
	if back == nil {
		return
	}
	defer st.destroy(back)
	testing.expect(t, string(dump_payload(back, context.temp_allocator)) == string(payload))
	cg := st.lookup_cg(back, bytes_of("g1"))
	testing.expect(t, cg != nil && cg.pel.numele == 3 && cg.consumers.numele == 2)
	a := st.lookup_consumer(cg, bytes_of("alice"))
	testing.expect(t, a != nil && a.pel.numele == 2 && a.seen_time == 1000 && a.active_time == 2200)
	testing.expect(t, st.lookup_cg(back, bytes_of("12345")).last_id == st.ID{2, 2})
	key: [16]u8
	st.encode_id(&key, st.ID{2, 2})
	v, found := rx.find(cg.pel, key[:])
	testing.expect(t, found && (^st.NACK)(v).consumer == st.lookup_consumer(cg, bytes_of("-7")))
}

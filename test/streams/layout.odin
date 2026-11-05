package streams_test

import st "../../src/streamtype"
import "core:fmt"
import "core:strings"
import "core:testing"

Node_Limits :: struct {
	bytes:   int,
	entries: i64,
}

set_limits :: proc(bytes: int, entries: i64) -> Node_Limits {
	old := Node_Limits{st.stream_node_max_bytes, st.stream_node_max_entries}
	st.stream_node_max_bytes = bytes
	st.stream_node_max_entries = entries
	return old
}

restore_limits :: proc(l: Node_Limits) {
	st.stream_node_max_bytes = l.bytes
	st.stream_node_max_entries = l.entries
}

xadd :: proc(s: st.Stream, parts: ..string) -> (st.ID, st.Error, i64) {
	argv := make([][]u8, len(parts) + 2, context.temp_allocator)
	argv[0] = bytes_of("XADD")
	argv[1] = bytes_of("k")
	for p, i in parts {
		argv[i + 2] = bytes_of(p)
	}
	spec, err := st.parse_xadd(argv)
	if err != .None {
		return {}, err, 0
	}
	id, aerr := st.xadd_apply(s, &spec, argv[spec.fields_at:], 1)
	if aerr != .None {
		return {}, aerr, 0
	}
	trimmed: i64
	if spec.trim.rule != .Off {
		trimmed = st.trim(s, &spec.trim)
	}
	return id, .None, trimmed
}

xtrim :: proc(s: st.Stream, parts: ..string) -> (i64, st.Error) {
	argv := make([][]u8, len(parts) + 2, context.temp_allocator)
	argv[0] = bytes_of("XTRIM")
	argv[1] = bytes_of("k")
	for p, i in parts {
		argv[i + 2] = bytes_of(p)
	}
	limits, err := st.parse_xtrim(argv)
	if err != .None {
		return 0, err
	}
	return st.trim(s, &limits), .None
}

xdel :: proc(s: st.Stream, ids: ..string) -> int {
	list := make([]st.ID, len(ids), context.temp_allocator)
	for a, i in ids {
		id, ok := st.parse_exact_id(bytes_of(a))
		assert(ok)
		list[i] = id
	}
	return st.xdel_apply(s, list)
}

expect_dump :: proc(t: ^testing.T, s: st.Stream, want_hex: string, label: string, loc := #caller_location) {
	got := dump_payload(s, context.temp_allocator)
	want := hex_decode(want_hex, context.temp_allocator)
	if string(got) != string(want) {
		sb: strings.Builder
		strings.builder_init(&sb, context.temp_allocator)
		for b in got {
			fmt.sbprintf(&sb, "%02x", b)
		}
		testing.expectf(t, false, "%s dump mismatch\n got  %s\n want %s", label, strings.to_string(sb), want_hex, loc = loc)
	}
	loaded, consumed := load_payload(want, true)
	testing.expectf(t, loaded != nil && consumed == len(want) - 10, "%s reload consumed %d of %d", label, consumed, len(want) - 10, loc = loc)
	if loaded != nil {
		again := dump_payload(loaded, context.temp_allocator)
		testing.expectf(t, string(again) == string(want), "%s reload re-encode differs", label, loc = loc)
		st.destroy(loaded)
	}
}

expect_info :: proc(t: ^testing.T, s: st.Stream, length: u64, keys: u64, nodes: u64, last: st.ID, maxdel: st.ID, added: u64, first: st.ID, loc := #caller_location) {
	testing.expect_value(t, st.length(s), length, loc = loc)
	testing.expect_value(t, st.node_count(s), keys, loc = loc)
	testing.expect_value(t, st.rax_nodes(s), nodes, loc = loc)
	testing.expect_value(t, s.top, last, loc = loc)
	testing.expect_value(t, s.tomb, maxdel, loc = loc)
	testing.expect_value(t, s.added, added, loc = loc)
	testing.expect_value(t, s.head, first, loc = loc)
}

@(test)
node_layout_matches_transcript :: proc(t: ^testing.T) {
	old := set_limits(4096, 100)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	xadd(s, "1-1", "a", "x")
	expect_dump(t, s, S1_ONE, "one entry")
	expect_info(t, s, 1, 1, 2, {1, 1}, {}, 1, {1, 1})
	xadd(s, "1-2", "a", "y")
	expect_dump(t, s, S1_TWO, "same fields")
	xadd(s, "2-0", "b", "z", "c", "w")
	expect_dump(t, s, S1_THREE, "different fields")
	xadd(s, "3-7", "a", "q")
	expect_dump(t, s, S1_FOUR, "master fields again")
	testing.expect_value(t, xdel(s, "1-2"), 1)
	expect_dump(t, s, S1_DEL_ONE, "one deleted")
	expect_info(t, s, 3, 1, 2, {3, 7}, {1, 2}, 4, {1, 1})
	testing.expect_value(t, xdel(s, "1-1", "9-9", "1-1"), 1)
	expect_dump(t, s, S1_DEL_TWO, "first deleted")
	expect_info(t, s, 2, 1, 2, {3, 7}, {1, 2}, 4, {2, 0})
	s2 := st.create()
	defer st.destroy(s2)
	xadd(s2, "5-5", "f", "")
	expect_dump(t, s2, S2_EMPTY_VALUE, "empty value")
	s3 := st.create()
	defer st.destroy(s3)
	xadd(s3, "0-1", strings.repeat("x", 70, context.temp_allocator), strings.repeat("y", 300, context.temp_allocator))
	expect_dump(t, s3, S3_LONG, "long strings")
	s4 := st.create()
	defer st.destroy(s4)
	xadd(s4, "1000000000000-18446744073709551615", "12345", "-7")
	expect_dump(t, s4, S4_BIG_IDS, "integer fields and big ids")
	xadd(s4, "18446744073709551615-18446744073709551615", "f", "v")
	expect_dump(t, s4, S4_MAX_ID, "maximal id")
	_, err, _ := xadd(s4, "*", "f", "v")
	testing.expect_value(t, err, st.Error.Id_Exhausted)
	testing.expect_value(t, st.error_message(err), "The stream has exhausted the last possible ID, unable to add more items")
}

@(test)
node_split_by_entries_and_bytes :: proc(t: ^testing.T) {
	old := set_limits(4096, 3)
	defer restore_limits(old)
	sn := st.create()
	defer st.destroy(sn)
	for i in 1 ..= 7 {
		xadd(sn, fmt.tprintf("%d-0", i), "f", fmt.tprintf("v%d", i))
	}
	expect_dump(t, sn, SN_ENTRY_SPLIT, "split by entries")
	expect_info(t, sn, 7, 3, 8, {7, 0}, {}, 7, {1, 0})
	restore_limits(Node_Limits{64, 100})
	sb := st.create()
	defer st.destroy(sb)
	for i in 1 ..= 5 {
		xadd(sb, fmt.tprintf("%d-0", i), "field", "valuevaluevaluevalue")
	}
	expect_dump(t, sb, SB_BYTE_SPLIT, "split by bytes")
	expect_info(t, sb, 5, 5, 12, {5, 0}, {}, 5, {1, 0})
	restore_limits(Node_Limits{4096, 0})
	sz := st.create()
	defer st.destroy(sz)
	for i in 1 ..< 300 {
		xadd(sz, fmt.tprintf("%d-0", i), "f", "v")
	}
	expect_info(t, sz, 299, 1, 2, {299, 0}, {}, 299, {1, 0})
	restore_limits(Node_Limits{31, 0})
	at_limit := st.create()
	defer st.destroy(at_limit)
	xadd(at_limit, "1-0", "f", "v")
	xadd(at_limit, "2-0", "f", "v")
	testing.expect_value(t, st.node_count(at_limit), 2)
	restore_limits(Node_Limits{32, 0})
	below_limit := st.create()
	defer st.destroy(below_limit)
	xadd(below_limit, "1-0", "f", "v")
	xadd(below_limit, "2-0", "f", "v")
	testing.expect_value(t, st.node_count(below_limit), 1)
	restore_limits(Node_Limits{1, 0})
	single := st.create()
	defer st.destroy(single)
	for i in 1 ..= 4 {
		xadd(single, fmt.tprintf("%d-0", i), "f", "v")
	}
	testing.expect_value(t, st.node_count(single), 4)
	restore_limits(Node_Limits{0, 0})
	unlimited := st.create()
	defer st.destroy(unlimited)
	for i in 1 ..= 5000 {
		xadd(unlimited, fmt.tprintf("%d-0", i), "f", "v")
	}
	testing.expect_value(t, st.node_count(unlimited), 1)
	testing.expect_value(t, st.length(unlimited), 5000)
	restore_limits(Node_Limits{4096, 2})
	deleted_tail := st.create()
	defer st.destroy(deleted_tail)
	xadd(deleted_tail, "1-0", "f", "v")
	xadd(deleted_tail, "2-0", "f", "v")
	xdel(deleted_tail, "2-0")
	xadd(deleted_tail, "3-0", "f", "v")
	testing.expect_value(t, st.node_count(deleted_tail), 2)
}

@(test)
radix_node_counts :: proc(t: ^testing.T) {
	old := set_limits(4096, 1)
	defer restore_limits(old)
	Case :: struct {
		ids:   []string,
		nodes: u64,
	}
	cases := []Case {
		{{}, 1},
		{{"1-0"}, 2},
		{{"1-0", "1-1"}, 4},
		{{"1-0", "4-0", "7-0"}, 8},
		{{"1-0", "2-0", "3-0", "4-0", "5-0"}, 12},
		{{"1-0", "6-0", "11-0", "16-0"}, 10},
		{{"6-0", "11-0", "16-0"}, 8},
		{{"1-0", "1-1", "2-0"}, 8},
		{{"256-0", "512-0"}, 6},
		{{"1-0", "18446744073709551615-0"}, 5},
	}
	for c in cases {
		s := st.create()
		for id in c.ids {
			xadd(s, id, "f", "v")
		}
		testing.expectf(t, st.rax_nodes(s) == c.nodes, "ids %v radix nodes %d want %d", c.ids, st.rax_nodes(s), c.nodes)
		st.destroy(s)
	}
}

@(test)
dup_and_memory :: proc(t: ^testing.T) {
	old := set_limits(4096, 4)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	for i in 1 ..= 20 {
		xadd(s, fmt.tprintf("%d-%d", i, i), "a", "1", "b", fmt.tprintf("%d", i * 7))
	}
	xdel(s, "3-3", "9-9")
	cg := st.add_group(s, bytes_of("g"), st.ID{5, 5}, 3)
	consumer := st.add_member(s, cg, bytes_of("alice"), 1000)
	st.group_deliver(s, cg, consumer, st.ID{6, 6}, false, 2000)
	d := st.dup(s)
	defer st.destroy(d)
	testing.expect(t, string(dump_payload(s, context.temp_allocator)) == string(dump_payload(d, context.temp_allocator)))
	testing.expect(t, st.memory_usage(s) > 0)
	testing.expect(t, st.memory_usage(d) > 0)
	xadd(d, "100-0", "x", "y")
	testing.expect(t, st.length(d) == st.length(s) + 1)
	infos: [dynamic]st.Node_Info
	defer delete(infos)
	st.node_listpacks(s, &infos)
	testing.expect_value(t, len(infos), 5)
	testing.expect(t, st.decode_id(infos[0].key[:]) == st.ID{1, 1})
	before := st.memory_usage(s)
	for i in 21 ..= 400 {
		xadd(s, fmt.tprintf("%d-%d", i, i), "a", "1", "b", "2")
	}
	testing.expect(t, st.memory_usage(s) > before)
	removed, _ := xtrim(s, "MAXLEN", "0")
	testing.expect(t, removed > 0)
	testing.expect_value(t, st.length(s), 0)
	testing.expect_value(t, st.node_count(s), 0)
	testing.expect(t, st.memory_usage(s) < before)
}

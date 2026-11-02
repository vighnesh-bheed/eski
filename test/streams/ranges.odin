package streams_test

import st "../../src/streamtype"
import "core:fmt"
import "core:strings"
import "core:testing"

collect :: proc(s: st.Stream, start: ^st.ID, end: ^st.ID, count: int, rev: bool) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	si: st.Iterator
	st.iterator_start(&si, s, start, end, rev)
	id: st.ID
	nf: i64
	n := 0
	for (count <= 0 || n < count) && st.iterator_get_id(&si, &id, &nf) {
		fmt.sbprintf(&sb, "%d-%d", id.ms, id.seq)
		for _ in 0 ..< nf {
			f, v := st.iterator_get_field(&si)
			fmt.sbprintf(&sb, " %s=%s", string(f), string(v))
		}
		strings.write_string(&sb, ";")
		n += 1
	}
	st.iterator_stop(&si)
	return strings.to_string(sb)
}

@(test)
range_walks_nodes_both_ways :: proc(t: ^testing.T) {
	old := set_limits(4096, 3)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	xadd(s, "1-0", "item", "0", "otherfield", "foo")
	xadd(s, "2-1", "item", "1", "otherfield", "foo")
	xadd(s, "3-2", "item", "2")
	xadd(s, "4-0", "item", "3")
	xadd(s, "5-1", "item", "4", "otherfield", "foo")
	xadd(s, "6-2", "item", "-12345678901")
	xadd(s, "7-0", "item", "007")
	testing.expect_value(t, collect(s, nil, nil, 0, false), "1-0 item=0 otherfield=foo;2-1 item=1 otherfield=foo;3-2 item=2;4-0 item=3;5-1 item=4 otherfield=foo;6-2 item=-12345678901;7-0 item=007;")
	testing.expect_value(t, collect(s, nil, nil, 0, true), "7-0 item=007;6-2 item=-12345678901;5-1 item=4 otherfield=foo;4-0 item=3;3-2 item=2;2-1 item=1 otherfield=foo;1-0 item=0 otherfield=foo;")
	a := st.ID{2, 1}
	b := st.ID{5, 0}
	testing.expect_value(t, collect(s, &a, &b, 0, false), "2-1 item=1 otherfield=foo;3-2 item=2;4-0 item=3;")
	testing.expect_value(t, collect(s, &a, &b, 0, true), "4-0 item=3;3-2 item=2;2-1 item=1 otherfield=foo;")
	testing.expect_value(t, collect(s, &a, &b, 2, true), "4-0 item=3;3-2 item=2;")
	testing.expect_value(t, collect(s, &b, &a, 0, false), "")
	start, end, _, _ := st.parse_range_args(args_of("XRANGE", "r", "(3-2", "(6-2"), false)
	testing.expect_value(t, collect(s, &start, &end, 0, false), "4-0 item=3;5-1 item=4 otherfield=foo;")
	start, end, _, _ = st.parse_range_args(args_of("XREVRANGE", "r", "(7", "(3"), true)
	testing.expect_value(t, collect(s, &start, &end, 0, true), "7-0 item=007;6-2 item=-12345678901;5-1 item=4 otherfield=foo;4-0 item=3;3-2 item=2;")
	start, end, _, _ = st.parse_range_args(args_of("XREVRANGE", "r", "(7-0", "(3-2"), true)
	testing.expect_value(t, collect(s, &start, &end, 0, true), "6-2 item=-12345678901;5-1 item=4 otherfield=foo;4-0 item=3;")
	xdel(s, "4-0", "5-1", "1-0")
	testing.expect_value(t, collect(s, nil, nil, 0, false), "2-1 item=1 otherfield=foo;3-2 item=2;6-2 item=-12345678901;7-0 item=007;")
	testing.expect_value(t, collect(s, nil, nil, 0, true), "7-0 item=007;6-2 item=-12345678901;3-2 item=2;2-1 item=1 otherfield=foo;")
	c := st.ID{4, 0}
	d := st.ID{5, 1}
	testing.expect_value(t, collect(s, &c, &d, 0, false), "")
	testing.expect_value(t, st.range_count(s, nil, nil, 0, false), 4)
	testing.expect_value(t, st.range_count(s, nil, nil, 3, true), 3)
	si: st.Iterator
	st.iterator_start(&si, s, nil, nil, false)
	si.skip_tombstones = false
	id: st.ID
	nf: i64
	all := 0
	for st.iterator_get_id(&si, &id, &nf) {
		all += 1
	}
	st.iterator_stop(&si)
	testing.expect_value(t, all, 7)
	st.iterator_start(&si, s, nil, nil, false)
	got := st.iterator_get_id(&si, &id, &nf)
	testing.expect(t, got && id == st.ID{2, 1} && nf == 2)
	st.iterator_skip_fields(&si, nf)
	got = st.iterator_get_id(&si, &id, &nf)
	testing.expect(t, got && id == st.ID{3, 2} && nf == 1)
	got = st.iterator_get_id(&si, &id, &nf)
	testing.expect(t, got && id == st.ID{6, 2})
	f, v := st.iterator_get_field(&si)
	testing.expect(t, string(f) == "item" && string(v) == "-12345678901")
	st.iterator_stop(&si)
	testing.expect(t, st.range_has_tombstones(s, nil, nil))
	after := st.ID{6, 0}
	testing.expect(t, !st.range_has_tombstones(s, &after, nil))
	before := st.ID{4, 0}
	testing.expect(t, st.range_has_tombstones(s, &before, nil))
}

@(test)
range_large_and_wide_values :: proc(t: ^testing.T) {
	old := set_limits(4096, 100)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	big := strings.repeat("z", 70000, context.temp_allocator)
	mid := strings.repeat("m", 5000, context.temp_allocator)
	xadd(s, "1-1", "big", big, "mid", mid)
	xadd(s, "1-2", "big", "1", "mid", "4096")
	xadd(s, "1-3", "big", "-4096", "mid", "-4097")
	xadd(s, "1-4", "n", "9223372036854775807", "m", "-9223372036854775808")
	xadd(s, "1-5", "n", "8388607", "m", "-8388609")
	si: st.Iterator
	st.iterator_start(&si, s, nil, nil, false)
	id: st.ID
	nf: i64
	values: [dynamic]string
	defer delete(values)
	for st.iterator_get_id(&si, &id, &nf) {
		for _ in 0 ..< nf {
			_, v := st.iterator_get_field(&si)
			append(&values, strings.clone(string(v), context.temp_allocator))
		}
	}
	st.iterator_stop(&si)
	testing.expect_value(t, len(values), 10)
	testing.expect(t, values[0] == big && values[1] == mid)
	testing.expect_value(t, values[2], "1")
	testing.expect_value(t, values[3], "4096")
	testing.expect_value(t, values[4], "-4096")
	testing.expect_value(t, values[5], "-4097")
	testing.expect_value(t, values[6], "9223372036854775807")
	testing.expect_value(t, values[7], "-9223372036854775808")
	testing.expect_value(t, values[8], "8388607")
	testing.expect_value(t, values[9], "-8388609")
	payload := dump_payload(s, context.temp_allocator)
	copy_s, consumed := load_payload(payload, true)
	testing.expect(t, copy_s != nil && consumed == len(payload) - 10)
	if copy_s != nil {
		testing.expect(t, string(dump_payload(copy_s, context.temp_allocator)) == string(payload))
		st.destroy(copy_s)
	}
}

@(test)
many_entries_stay_consistent :: proc(t: ^testing.T) {
	old := set_limits(4096, 100)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	fv := args_of("field", "value", "n", "1")
	args: st.Xadd_Spec
	for i in 0 ..< 70000 {
		_, err := st.xadd_apply(s, &args, fv, u64(1000 + i / 3))
		assert(err == .None)
	}
	testing.expect_value(t, st.length(s), 70000)
	testing.expect_value(t, st.node_count(s), 700)
	testing.expect_value(t, st.range_count(s, nil, nil, 0, false), 70000)
	testing.expect_value(t, st.range_count(s, nil, nil, 0, true), 70000)
	last := st.last_valid_id(s)
	testing.expect(t, last == s.last_id)
	restore_limits(Node_Limits{0, 0})
	u := st.create()
	defer st.destroy(u)
	for i in 0 ..< 70000 {
		_, err := st.xadd_apply(u, &args, fv, u64(1 + i))
		assert(err == .None)
	}
	testing.expect_value(t, st.node_count(u), 1)
	infos: [dynamic]st.Node_Info
	defer delete(infos)
	st.node_listpacks(u, &infos)
	header := u16(infos[0].lp[4]) | u16(infos[0].lp[5]) << 8
	testing.expect_value(t, header, 65535)
	testing.expect_value(t, st.range_count(u, nil, nil, 0, true), 70000)
	mid := st.ID{35000, 0}
	testing.expect(t, st.delete_item(u, mid))
	testing.expect(t, !st.entry_exists(u, mid))
	payload := dump_payload(u, context.temp_allocator)
	again, consumed := load_payload(payload, true)
	testing.expect(t, again != nil && consumed == len(payload) - 10)
	if again != nil {
		testing.expect_value(t, st.length(again), 69999)
		st.destroy(again)
	}
}

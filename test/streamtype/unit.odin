package streamtype_harness

import rx "../../src/rax"
import st "../../src/streamtype"
import "core:fmt"

b :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

id_str :: proc(id: st.ID) -> string {
	buf: [st.ID_TEXT_MAX]u8
	return fmt.tprint(string(st.format_id(&buf, id)))
}

Id_Form :: enum u8 {
	Sentinel,
	Exact,
	Xadd,
}

parse_in_form :: proc(s: []u8, form: Id_Form) -> (id: st.ID, given: bool, ok: bool) {
	switch form {
	case .Sentinel:
		id, ok = st.parse_id_or_sentinel(s, 0)
		given = true
	case .Exact:
		id, ok = st.parse_exact_id(s)
		given = true
	case .Xadd:
		mode: st.Xadd_Id_Mode
		id, mode, ok = st.parse_xadd_id(s)
		given = mode != .Generated_Seq
	}
	return
}

unit_ids :: proc() {
	Case :: struct {
		s:     string,
		form:  Id_Form,
		ok:    bool,
		want:  st.ID,
		given: bool,
	}
	MAX :: max(u64)
	cases := [?]Case {
		{"1-2", .Exact, true, {1, 2}, true},
		{"5", .Exact, true, {5, 0}, true},
		{"-", .Sentinel, true, {0, 0}, true},
		{"+", .Sentinel, true, {MAX, MAX}, true},
		{"-", .Exact, false, {}, true},
		{"+", .Exact, false, {}, true},
		{"007", .Exact, true, {7, 0}, true},
		{" 7", .Exact, true, {7, 0}, true},
		{"+7", .Exact, true, {7, 0}, true},
		{"7 ", .Exact, false, {}, true},
		{"-0", .Exact, false, {}, true},
		{"0--05", .Exact, true, {0, MAX - 4}, true},
		{"1--5", .Exact, false, {}, true},
		{"18446744073709551615-18446744073709551615", .Exact, true, {MAX, MAX}, true},
		{"18446744073709551616", .Exact, false, {}, true},
		{"1-*", .Xadd, true, {1, 0}, false},
		{"1-*", .Exact, false, {}, true},
		{"*", .Xadd, true, {0, 0}, true},
		{"*", .Exact, false, {}, true},
		{"", .Exact, false, {}, true},
		{"1-", .Exact, false, {}, true},
		{"0x10", .Exact, false, {}, true},
		{"1.5", .Exact, false, {}, true},
		{"5\x00junk", .Exact, true, {5, 0}, true},
		{"5-1\x00-9", .Exact, true, {5, 1}, true},
	}
	for c in cases {
		id, given, ok := parse_in_form(b(c.s), c.form)
		check(ok == c.ok, fmt.tprintf("parse %q ok=%v", c.s, ok))
		if ok && c.ok {
			check(id == c.want, fmt.tprintf("parse %q gave %s", c.s, id_str(id)))
			check(given == c.given, fmt.tprintf("parse %q seq_given=%v", c.s, given))
		}
	}
	long := make([]u8, 128)
	for i in 0 ..< len(long) {
		long[i] = '1'
	}
	_, ok := st.parse_exact_id(long)
	check(!ok, "128 byte id is rejected")
	id := st.ID{5, max(u64)}
	check(st.incr_id(&id) && id == st.ID{6, 0}, "incr carries into ms")
	id = st.ID_MAX
	check(!st.incr_id(&id) && id == st.ID_MIN, "incr of the max id wraps and fails")
	id = st.ID{6, 0}
	check(st.decr_id(&id) && id == st.ID{5, max(u64)}, "decr borrows from ms")
	id = st.ID_MIN
	check(!st.decr_id(&id) && id == st.ID_MAX, "decr of the min id wraps and fails")
	check(id_str(st.ID{1700000000000, 42}) == "1700000000000-42", "id formatting")
}

unit_stream :: proc() {
	saved_bytes := st.stream_node_max_bytes
	saved_entries := st.stream_node_max_entries
	defer {
		st.stream_node_max_bytes = saved_bytes
		st.stream_node_max_entries = saved_entries
	}
	st.stream_node_max_entries = 3
	s := st.create()
	defer st.destroy(s)
	fv := [][]u8{b("f"), b("v")}
	for i in 1 ..= 10 {
		use := st.ID{u64(i), 0}
		got, res := st.append_item(s, fv, &use, true, 0)
		check(res == .Ok && got == use, "append explicit id")
	}
	check(st.node_count(s) == 4, fmt.tprintf("ten entries at three per node make four nodes, got %d", st.node_count(s)))
	check(st.length(s) == 10, "length after appends")
	lo := st.ID{3, 0}
	hi := st.ID{7, 0}
	check(st.range_count(s, &lo, &hi, 0, false) == 5, "forward range count")
	check(st.range_count(s, &lo, &hi, 2, true) == 2, "reverse range count with a limit")
	check(st.delete_item(s, st.ID{4, 0}), "delete an entry")
	check(!st.delete_item(s, st.ID{4, 0}), "delete it again")
	check(st.length(s) == 9, "length after delete")
	check(st.range_count(s, &lo, &hi, 0, false) == 4, "range skips the tombstone")
	args := st.Trim_Spec {
		rule    = .Max_Len,
		max_len = 5,
		nearly  = true,
		limit   = 100,
	}
	removed := st.trim(s, &args)
	check(removed == 3, fmt.tprintf("approximate trim removes whole nodes only, got %d", removed))
	check(s.first_id == st.ID{5, 0}, "first id follows the trim")
	for i in 11 ..= 400 {
		use := st.ID{u64(i), 0}
		st.append_item(s, fv, &use, true, 0)
	}
	before := rx.memory(s.rax)
	check(before > 0, "rax memory is tracked")
	d := st.dup(s)
	check(st.node_count(d) == st.node_count(s) && st.rax_nodes(d) == st.rax_nodes(s), "dup keeps the node layout")
	check(st.memory_usage(d) > 0, "dup memory")
	st.destroy(d)
	_, res := st.append_item(s, fv, nil, false, 5)
	check(res == .Ok, "auto id below the last id increments the sequence")
	check(s.last_id == st.ID{400, 1}, fmt.tprintf("auto id is %s", id_str(s.last_id)))
	use := st.ID{400, 0}
	_, res = st.append_item(s, fv, &use, false, 0)
	check(res == .Ok && s.last_id == st.ID{400, 2}, "partial id continues the sequence")
	use = st.ID{399, 0}
	_, res = st.append_item(s, fv, &use, false, 0)
	check(res == .Id_Not_Greater, "partial id in the past fails")
}

unit_groups :: proc() {
	s := st.create()
	defer st.destroy(s)
	fv := [][]u8{b("f"), b("v")}
	for i in 1 ..= 5 {
		use := st.ID{u64(i), 0}
		st.append_item(s, fv, &use, true, 0)
	}
	before := s.cg_mem
	cg := st.create_cg(s, b("g"), st.ID_MIN, st.SCG_INVALID_ENTRIES_READ)
	check(cg != nil, "create a group")
	check(st.create_cg(s, b("g"), st.ID_MIN, 0) == nil, "duplicate group")
	lag, ok := st.cg_lag(s, cg)
	check(ok && lag == 5, fmt.tprintf("lag of a fresh group is the length, got %d", lag))
	alice := st.create_consumer(s, cg, b("alice"), 100)
	check(alice != nil && alice.seen_time == 100 && alice.active_time == -1, "consumer times")
	for i in 1 ..= 3 {
		st.group_deliver(s, cg, alice, st.ID{u64(i), 0}, false, 200)
	}
	check(cg.entries_read == 3 && cg.last_id == st.ID{3, 0}, fmt.tprintf("entries read %d", cg.entries_read))
	lag, ok = st.cg_lag(s, cg)
	check(ok && lag == 2, "lag after three reads")
	check(cg.pel.numele == 3 && alice.pel.numele == 3 && alice.active_time == 200, "pending entries")
	check(st.ack(s, cg, st.ID{2, 0}) && !st.ack(s, cg, st.ID{2, 0}), "ack once")
	check(st.xdel_apply(s, {st.ID{4, 0}}) == 1, "delete ahead of the group")
	lag, ok = st.cg_lag(s, cg)
	check(!ok, "lag is unknown with a tombstone ahead")
	args := st.Claim_Args {
		retrycount   = -1,
		deliverytime = -1,
	}
	claimed := make([dynamic]st.ID, context.temp_allocator)
	st.claim(s, cg, b("bob"), &args, {st.ID{1, 0}, st.ID{3, 0}, st.ID{9, 0}}, 300, &claimed)
	check(len(claimed) == 2 && alice.pel.numele == 0, fmt.tprintf("claimed %d", len(claimed)))
	bob := st.lookup_consumer(cg, b("bob"))
	check(bob != nil && bob.pel.numele == 2, "bob owns the claimed entries")
	st.group_deliver(s, cg, alice, st.ID{5, 0}, false, 400)
	st.xdel_apply(s, {st.ID{5, 0}})
	clear(&claimed)
	deleted := make([dynamic]st.ID, context.temp_allocator)
	cursor := st.autoclaim(s, cg, b("carol"), 0, st.ID_MIN, 2, false, 500, &claimed, &deleted)
	check(len(claimed) == 2 && len(deleted) == 0 && cursor == st.ID{5, 0}, fmt.tprintf("autoclaim cursor %v", cursor))
	clear(&claimed)
	cursor = st.autoclaim(s, cg, b("carol"), 0, cursor, 2, false, 500, &claimed, &deleted)
	check(len(claimed) == 0 && len(deleted) == 1 && cursor == st.ID_MIN, "autoclaim drops a deleted entry")
	d := st.dup(s)
	dcg := st.lookup_cg(d, b("g"))
	check(dcg != nil && dcg.pel.numele == cg.pel.numele && dcg.consumers.numele == cg.consumers.numele, "dup keeps groups")
	st.destroy(d)
	carol := st.lookup_consumer(cg, b("carol"))
	check(st.del_consumer(s, cg, carol) == 2 && cg.pel.numele == 0, "deleting a consumer drops its pending entries")
	check(st.destroy_cg(s, b("g")), "destroy the group")
	st.free_groups(s)
	check(s.cg_mem == before, fmt.tprintf("group memory returns to %d, got %d", before, s.cg_mem))
}

run_unit :: proc() -> bool {
	unit_ids()
	unit_stream()
	unit_groups()
	fmt.printfln("streamtype unit: %d checks, %d failures", checks, failures)
	free_all(context.temp_allocator)
	return failures == 0
}

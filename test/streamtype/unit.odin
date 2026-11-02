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

Parse_Expect :: struct {
	valid: bool,
	id:    st.ID,
}

Id_Vector :: struct {
	text:     string,
	xadd:     Parse_Expect,
	auto_seq: bool,
	start:    Parse_Expect,
	end:      Parse_Expect,
	strict:   Parse_Expect,
}

TOP :: max(u64)

id_ok :: proc(ms, seq: u64) -> Parse_Expect {
	return {true, {ms, seq}}
}

ID_BAD :: Parse_Expect{}

plain_id_vector :: proc(text: string, ms, seq: u64) -> Id_Vector {
	return {text, id_ok(ms, seq), false, id_ok(ms, seq), id_ok(ms, seq), id_ok(ms, seq)}
}

partial_id_vector :: proc(text: string, ms: u64) -> Id_Vector {
	return {text, id_ok(ms, 0), false, id_ok(ms, 0), id_ok(ms, TOP), id_ok(ms, 0)}
}

rejected_id_vector :: proc(text: string) -> Id_Vector {
	return {text, ID_BAD, false, ID_BAD, ID_BAD, ID_BAD}
}

check_id_parse :: proc(what: string, text: string, want: Parse_Expect, got: st.ID, ok: bool) {
	if !want.valid {
		check(!ok, fmt.tprintf("%s rejects %q", what, text))
		return
	}
	check(ok && got == want.id, fmt.tprintf("%s reads %q as %s, got ok=%v %s", what, text, id_str(want.id), ok, id_str(got)))
}

unit_ids :: proc() {
	padded_nul := make([]u8, 127)
	padded_nul[0] = '5'
	long_nul := make([]u8, 128)
	long_nul[0] = '5'
	zeros_127 := make([]u8, 127)
	zeros_128 := make([]u8, 128)
	for i in 0 ..< len(zeros_127) {
		zeros_127[i] = '0'
	}
	for i in 0 ..< len(zeros_128) {
		zeros_128[i] = '0'
	}
	zeros_127[126] = '5'
	zeros_128[127] = '5'
	vectors := [?]Id_Vector {
		plain_id_vector("1-2", 1, 2),
		partial_id_vector("5", 5),
		{"-", ID_BAD, false, id_ok(0, 0), id_ok(0, 0), ID_BAD},
		{"+", ID_BAD, false, id_ok(TOP, TOP), id_ok(TOP, TOP), ID_BAD},
		partial_id_vector("007", 7),
		partial_id_vector(" 7", 7),
		partial_id_vector("+7", 7),
		rejected_id_vector("7 "),
		rejected_id_vector("-0"),
		plain_id_vector("0--05", 0, TOP - 4),
		rejected_id_vector("1--5"),
		plain_id_vector("1--0", 1, 0),
		plain_id_vector("0-+5", 0, 5),
		plain_id_vector("+0-+5", 0, 5),
		plain_id_vector("18446744073709551615-18446744073709551615", TOP, TOP),
		rejected_id_vector("18446744073709551616"),
		rejected_id_vector("18446744073709551615-18446744073709551616"),
		{"1-*", id_ok(1, 0), true, ID_BAD, ID_BAD, ID_BAD},
		rejected_id_vector("*"),
		rejected_id_vector(""),
		rejected_id_vector("1-"),
		rejected_id_vector("-1"),
		rejected_id_vector("-5-5"),
		rejected_id_vector("1-2-3"),
		rejected_id_vector("0x10"),
		rejected_id_vector("1.5"),
		partial_id_vector("5\x00junk", 5),
		plain_id_vector("5-1\x00-9", 5, 1),
		plain_id_vector("\t3-4", 3, 4),
		plain_id_vector("3- 4", 3, 4),
		plain_id_vector("3-+4", 3, 4),
		partial_id_vector("9223372036854775808", 9223372036854775808),
		rejected_id_vector("-9223372036854775808"),
		plain_id_vector("1-18446744073709551615", 1, TOP),
		plain_id_vector("0-00", 0, 0),
		partial_id_vector(string(padded_nul), 5),
		rejected_id_vector(string(long_nul)),
		partial_id_vector(string(zeros_127), 5),
		rejected_id_vector(string(zeros_128)),
	}
	for v in vectors {
		got, mode, ok := st.parse_xadd_id(b(v.text))
		explicit := ok && mode != .Generated
		check_id_parse("XADD", v.text, v.xadd, got, explicit)
		if explicit && v.xadd.valid {
			seq_given := mode == .Explicit
			check(seq_given != v.auto_seq, fmt.tprintf("XADD %q sequence given=%v", v.text, seq_given))
		}
		got, ok = st.parse_id_or_sentinel(b(v.text), 0)
		check_id_parse("XRANGE start", v.text, v.start, got, ok)
		got, ok = st.parse_id_or_sentinel(b(v.text), TOP)
		check_id_parse("XRANGE end", v.text, v.end, got, ok)
		got, ok = st.parse_exact_id(b(v.text))
		check_id_parse("XDEL", v.text, v.strict, got, ok)
	}
	_, star_mode, star_ok := st.parse_xadd_id(b("*"))
	check(star_ok && star_mode == .Generated, "XADD reads * as a generated id")
	Step :: struct {
		from:    st.ID,
		to:      st.ID,
		forward: bool,
		ok:      bool,
	}
	steps := [?]Step {
		{{1, TOP}, {2, 0}, true, true},
		{{0, 0}, {0, 1}, true, true},
		{{18446744073709551615, 18446744073709551614}, {TOP, TOP}, true, true},
		{{2, 0}, {1, TOP}, false, true},
		{{TOP, TOP}, {TOP, TOP - 1}, false, true},
		{{9, 1}, {9, 0}, false, true},
		{{TOP, TOP}, {}, true, false},
		{{0, 0}, {}, false, false},
	}
	for s in steps {
		moved := s.from
		ok := st.incr_id(&moved) if s.forward else st.decr_id(&moved)
		direction := "next" if s.forward else "previous"
		if s.ok {
			check(ok && moved == s.to, fmt.tprintf("%s of %s is %s, got %s", direction, id_str(s.from), id_str(s.to), id_str(moved)))
		} else {
			check(!ok, fmt.tprintf("%s of %s does not exist", direction, id_str(s.from)))
		}
	}
	formats := [?]struct {
		id:   st.ID,
		text: string,
	} {
		{{TOP, TOP}, "18446744073709551615-18446744073709551615"},
		{{1, TOP}, "1-18446744073709551615"},
		{{9223372036854775808, 0}, "9223372036854775808-0"},
		{{0, 18446744073709551611}, "0-18446744073709551611"},
		{{0, 0}, "0-0"},
	}
	for f in formats {
		check(id_str(f.id) == f.text, fmt.tprintf("format %s", f.text))
	}
	delete(padded_nul)
	delete(long_nul)
	delete(zeros_127)
	delete(zeros_128)
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
	cg := st.create_cg(s, b("g"), st.ID_MIN, st.ENTRIES_READ_UNKNOWN)
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

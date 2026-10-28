package streams_test

import st "../../src/streamtype"
import "core:fmt"
import "core:testing"

@(test)
trimming_matches_transcript :: proc(t: ^testing.T) {
	old := set_limits(4096, 5)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	for i in 1 ..= 20 {
		xadd(s, fmt.tprintf("%d-0", i), "f", "v")
	}
	expect_info(t, s, 20, 4, 10, {20, 0}, {}, 20, {1, 0})
	n, err := xtrim(s, "MAXLEN", "~", "12")
	testing.expect(t, err == .None && n == 5)
	expect_info(t, s, 15, 3, 8, {20, 0}, {}, 20, {6, 0})
	n, err = xtrim(s, "MAXLEN", "12")
	testing.expect(t, err == .None && n == 3)
	expect_info(t, s, 12, 3, 8, {20, 0}, {}, 20, {9, 0})
	expect_dump(t, s, T_TRIMMED, "exact trim inside a node")
	n, _ = xtrim(s, "MINID", "~", "15-0")
	testing.expect_value(t, n, 2)
	testing.expect_value(t, st.length(s), 10)
	n, _ = xtrim(s, "MINID", "15-0")
	testing.expect_value(t, n, 4)
	start := st.ID_MIN
	end := st.ID_MAX
	testing.expect_value(t, st.range_count(s, &start, &end, 2, false), 2)
	testing.expect(t, s.first_id == st.ID{15, 0})
	n, _ = xtrim(s, "MAXLEN", "=", "3")
	testing.expect_value(t, n, 3)
	n, _ = xtrim(s, "MAXLEN", "~", "0", "LIMIT", "1")
	testing.expect_value(t, n, 0)
	n, _ = xtrim(s, "MAXLEN", "0")
	testing.expect_value(t, n, 3)
	expect_info(t, s, 0, 0, 1, {20, 0}, {}, 20, {})
	expect_dump(t, s, T_EMPTY, "emptied stream")
	xadd(s, "MAXLEN", "~", "2", "100-0", "f", "v")
	_, _, trimmed := xadd(s, "NOMKSTREAM", "MAXLEN", "1", "101-0", "f", "v")
	testing.expect_value(t, trimmed, 1)
	_, perr, _ := xadd(s, "MAXLEN", "0", "LIMIT", "5", "102-0", "f", "v")
	testing.expect_value(t, perr, st.Error.Limit_No_Approx)
	xadd(s, "MAXLEN", "~", "0", "LIMIT", "5", "103-0", "f", "v")
	xadd(s, "MINID", "=", "1000-0", "104-0", "f", "v")
	expect_info(t, s, 0, 0, 1, {104, 0}, {}, 24, {})
}

@(test)
approximate_trim_limit_counts_live_entries :: proc(t: ^testing.T) {
	old := set_limits(4096, 3)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	for i in 1 ..= 12 {
		xadd(s, fmt.tprintf("%d-0", i), "f", "v")
	}
	n, _ := xtrim(s, "MINID", "=", "3-0")
	testing.expect_value(t, n, 2)
	n, _ = xtrim(s, "MAXLEN", "~", "0", "LIMIT", "1")
	testing.expect_value(t, n, 1)
	n, _ = xtrim(s, "MAXLEN", "~", "0", "LIMIT", "5")
	testing.expect_value(t, n, 3)
	n, _ = xtrim(s, "MAXLEN", "~", "0", "LIMIT", "0")
	testing.expect_value(t, n, 6)
	testing.expect_value(t, st.length(s), 0)
	for i in 20 ..< 40 {
		xadd(s, fmt.tprintf("%d-0", i), "f", "v")
	}
	n, _ = xtrim(s, "MAXLEN", "~", "10")
	testing.expect_value(t, n, 9)
	n, _ = xtrim(s, "MINID", "~", "33")
	testing.expect_value(t, n, 3)
	testing.expect(t, s.first_id == st.ID{32, 0})
	restore_limits(Node_Limits{4096, 0})
	u := st.create()
	defer st.destroy(u)
	for i in 1 ..= 30 {
		xadd(u, fmt.tprintf("%d-0", i), "f", "v")
	}
	n, _ = xtrim(u, "MAXLEN", "~", "0")
	testing.expect_value(t, n, 30)
}

@(test)
trim_parsing_defaults :: proc(t: ^testing.T) {
	old := set_limits(4096, 7)
	defer restore_limits(old)
	args, _, err := st.parse_add_trim_args(args_of("XTRIM", "k", "maxlen", "~", "5"), false)
	testing.expect(t, err == .None && args.approx_trim && args.limit == 700 && args.maxlen == 5)
	testing.expect_value(t, args.trim_strategy_arg_idx, 4)
	args, _, err = st.parse_add_trim_args(args_of("XTRIM", "k", "MINID", "9-1"), false)
	testing.expect(t, err == .None && !args.approx_trim && args.limit == 0 && args.minid == st.ID{9, 1})
	testing.expect_value(t, args.trim_strategy_arg_idx, 3)
	args, _, err = st.parse_add_trim_args(args_of("XTRIM", "k", "MAXLEN", "~", "1", "LIMIT", "1", "LIMIT", "0"), false)
	testing.expect(t, err == .None && args.limit == 0)
	args, _, err = st.parse_add_trim_args(args_of("XTRIM", "k", "MAXLEN\x00x", "17"), false)
	testing.expect(t, err == .None && args.maxlen == 17)
	idpos: int
	args, idpos, err = st.parse_add_trim_args(args_of("XADD", "k", "nomkstream", "maxlen", "~", "5", "*", "f", "v"), true)
	testing.expect(t, err == .None && args.no_mkstream && idpos == 6 && !args.id_given)
	args, idpos, err = st.parse_add_trim_args(args_of("XADD", "k", "*\x00x", "f", "v"), true)
	testing.expect(t, err == .None && idpos == 2 && !args.id_given)
	args, idpos, err = st.parse_add_trim_args(args_of("XADD", "k", "MINID", "~", "18", "LIMIT", "0", "101", "f", "v"), true)
	testing.expect(t, err == .None && idpos == 7 && args.id == st.ID{101, 0} && args.limit == 0)
	st.trim_limit_relaxed = true
	args, _, err = st.parse_add_trim_args(args_of("XTRIM", "k", "MAXLEN", "=", "3", "LIMIT", "10"), false)
	st.trim_limit_relaxed = false
	testing.expect(t, err == .None && args.limit == 0)
}

@(test)
deletion_tracks_first_and_nodes :: proc(t: ^testing.T) {
	old := set_limits(4096, 3)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	for i in 1 ..= 9 {
		xadd(s, fmt.tprintf("%d-0", i), "f", fmt.tprintf("%d", i))
	}
	testing.expect_value(t, xdel(s, "1-0"), 1)
	testing.expect(t, s.first_id == st.ID{2, 0})
	testing.expect_value(t, xdel(s, "2-0", "3-0"), 2)
	testing.expect_value(t, st.node_count(s), 2)
	testing.expect(t, s.first_id == st.ID{4, 0})
	testing.expect(t, s.max_deleted_entry_id == st.ID{3, 0})
	testing.expect_value(t, xdel(s, "5-0", "5-0", "100-0"), 1)
	testing.expect(t, s.max_deleted_entry_id == st.ID{5, 0})
	testing.expect_value(t, xdel(s, "4-0"), 1)
	testing.expect(t, s.max_deleted_entry_id == st.ID{5, 0})
	testing.expect(t, s.first_id == st.ID{6, 0})
	testing.expect(t, !st.entry_exists(s, st.ID{4, 0}))
	testing.expect(t, st.entry_exists(s, st.ID{6, 0}))
	testing.expect(t, !st.entry_exists(s, st.ID{6, 1}))
	testing.expect_value(t, st.length(s), 4)
	testing.expect(t, st.last_valid_id(s) == st.ID{9, 0})
	testing.expect_value(t, xdel(s, "9-0"), 1)
	testing.expect(t, st.last_valid_id(s) == st.ID{8, 0})
	testing.expect(t, s.last_id == st.ID{9, 0})
	testing.expect(t, st.get_edge_id(s, false, false) == st.ID{9, 0})
	testing.expect(t, st.get_edge_id(s, true, false) == st.ID{4, 0})
	testing.expect(t, st.delete_item(s, st.ID{6, 0}))
	testing.expect(t, !st.delete_item(s, st.ID{6, 0}))
	testing.expect(t, s.first_id == st.ID{7, 0})
	xdel(s, "7-0", "8-0")
	testing.expect_value(t, st.length(s), 0)
	testing.expect_value(t, st.node_count(s), 0)
	testing.expect(t, s.first_id == st.ID_MIN)
	testing.expect(t, st.get_edge_id(s, true, true) == st.ID_MAX)
	testing.expect(t, st.get_edge_id(s, false, true) == st.ID_MIN)
	xadd(s, "10-0", "f", "v")
	testing.expect(t, s.first_id == st.ID{10, 0})
}

@(test)
iterator_removal_keeps_walking :: proc(t: ^testing.T) {
	old := set_limits(4096, 4)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	for i in 1 ..= 10 {
		xadd(s, fmt.tprintf("%d-0", i), "f", "v")
	}
	si: st.Iterator
	st.iterator_start(&si, s, nil, nil, false)
	id: st.ID
	nf: i64
	seen := 0
	for st.iterator_get_id(&si, &id, &nf) {
		seen += 1
		if id.ms % 2 == 0 {
			st.iterator_remove_entry(&si, &id)
		}
	}
	st.iterator_stop(&si)
	testing.expect_value(t, seen, 10)
	testing.expect_value(t, st.length(s), 5)
	st.iterator_start(&si, s, nil, nil, true)
	seen = 0
	for st.iterator_get_id(&si, &id, &nf) {
		seen += 1
		st.iterator_remove_entry(&si, &id)
	}
	st.iterator_stop(&si)
	testing.expect_value(t, seen, 5)
	testing.expect_value(t, st.length(s), 0)
	testing.expect_value(t, st.node_count(s), 0)
}

@(test)
change_counting_cases_from_transcript :: proc(t: ^testing.T) {
	old := set_limits(4096, 100)
	defer restore_limits(old)
	s := st.create()
	defer st.destroy(s)
	changes := 0
	id, err, trimmed := xadd(s, "1-0", "f", "v")
	testing.expect(t, err == .None && id == st.ID{1, 0} && trimmed == 0)
	changes += 1
	id, err, trimmed = xadd(s, "MAXLEN", "1", "2-0", "f", "v")
	testing.expect(t, err == .None && trimmed == 1)
	changes += 1
	id, err, trimmed = xadd(s, "MAXLEN", "~", "0", "3-0", "f", "v")
	testing.expect(t, err == .None && trimmed == 2)
	changes += 1
	id, err, trimmed = xadd(s, "NOMKSTREAM", "MAXLEN", "1", "4-0", "f", "v")
	testing.expect(t, err == .None && trimmed == 0 && id == st.ID{4, 0})
	changes += 1
	deleted := xdel(s, "4-0")
	testing.expect_value(t, deleted, 1)
	if deleted > 0 {
		changes += 1
	}
	deleted = xdel(s, "4-0")
	testing.expect_value(t, deleted, 0)
	if deleted > 0 {
		changes += 1
	}
	deleted = xdel(s, "9-9")
	testing.expect_value(t, deleted, 0)
	removed, terr := xtrim(s, "MAXLEN", "0")
	testing.expect(t, terr == .None && removed == 0)
	if removed > 0 {
		changes += 1
	}
	a, perr := st.parse_xsetid_args(args_of("XSETID", "ev", "50-0"))
	testing.expect(t, perr == .None && st.xsetid_apply(s, &a) == .None)
	changes += 1
	a, perr = st.parse_xsetid_args(args_of("XSETID", "ev", "50-0", "ENTRIESADDED", "7"))
	testing.expect(t, perr == .None && st.xsetid_apply(s, &a) == .None)
	changes += 1
	id, err, _ = xadd(s, "51-0", "f", "v")
	testing.expect(t, err == .None && id == st.ID{51, 0})
	changes += 1
	testing.expect_value(t, changes, 8)
	testing.expect_value(t, s.entries_added, 8)
	removed, _ = xtrim(s, "MAXLEN", "0")
	testing.expect_value(t, removed, 1)
	removed, _ = xtrim(s, "MAXLEN", "0")
	testing.expect_value(t, removed, 0)
	e2 := st.create()
	defer st.destroy(e2)
	_, err, trimmed = xadd(e2, "MAXLEN", "0", "1-0", "f", "v")
	testing.expect(t, err == .None && trimmed == 1 && st.length(e2) == 0)
}

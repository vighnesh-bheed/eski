package streams_test

import st "../../src/streamtype"
import "core:testing"

Err_Case :: struct {
	argv: []string,
	err:  st.Error,
}

@(test)
add_and_trim_errors :: proc(t: ^testing.T) {
	cases := []Err_Case {
		{{"XADD", "e", "0-0", "f", "v"}, .Id_Zero},
		{{"XADD", "e", "0", "f", "v"}, .Id_Zero},
		{{"XADD", "e", "abc", "f", "v"}, .Invalid_ID},
		{{"XADD", "e", "1-", "f", "v"}, .Invalid_ID},
		{{"XADD", "e", "-1", "f", "v"}, .Invalid_ID},
		{{"XADD", "e", "18446744073709551616-0", "f", "v"}, .Invalid_ID},
		{{"XADD", "e", "*", "f"}, .Xadd_Arity},
		{{"XADD", "t", "*", "f", "v", "g"}, .Xadd_Arity},
		{{"XADD", "t", "0-0", "f", "v", "g"}, .Xadd_Arity},
		{{"XADD", "t", "MAXLEN", "5", "21"}, .Xadd_Arity},
		{{"XADD", "t", "MAXLEN", "1", "f", "v"}, .Invalid_ID},
		{{"XADD", "t", "NOMKSTREAM", "f", "v"}, .Invalid_ID},
		{{"XADD", "t", "FOO", "f", "v"}, .Invalid_ID},
		{{"XADD", "e", "MAXLEN", "*", "f", "v"}, .Not_Integer},
		{{"XADD", "e", "MAXLEN", "-1", "*", "f", "v"}, .Maxlen_Negative},
		{{"XADD", "e", "MAXLEN", "~", "*", "f", "v"}, .Not_Integer},
		{{"XADD", "e", "LIMIT", "5", "*", "f", "v"}, .Limit_No_Strategy},
		{{"XADD", "e", "MAXLEN", "5", "LIMIT", "5", "*", "f", "v"}, .Limit_No_Approx},
		{{"XADD", "e", "MAXLEN", "5", "MINID", "5", "*", "f", "v"}, .Maxlen_Minid},
		{{"XADD", "e", "MINID", "abc", "*", "f", "v"}, .Invalid_ID},
		{{"XADD", "e", "MAXLEN", "5", "LIMIT", "-1", "*", "f", "v"}, .Limit_Negative},
		{{"XADD", "e", "MAXLEN", "~", "5", "LIMIT", "x", "*", "f", "v"}, .Not_Integer},
		{{"XADD", "e", "BOGUS", "*", "f", "v"}, .Invalid_ID},
		{{"XTRIM", "t", "MAXLEN", "abc"}, .Not_Integer},
		{{"XTRIM", "t", "MAXLEN", "-1"}, .Maxlen_Negative},
		{{"XTRIM", "t", "MAXLEN", "~"}, .Not_Integer},
		{{"XTRIM", "t", "MAXLEN", "="}, .Not_Integer},
		{{"XTRIM", "t", "MINID", "abc"}, .Invalid_ID},
		{{"XTRIM", "t", "MINID", "-"}, .Invalid_ID},
		{{"XTRIM", "t", "MINID", "+"}, .Invalid_ID},
		{{"XTRIM", "t", "MINID", "5-*"}, .Invalid_ID},
		{{"XTRIM", "t", "MAXLEN", "1", "MINID", "1"}, .Maxlen_Minid},
		{{"XTRIM", "t", "MINID", "1", "MAXLEN", "1"}, .Maxlen_Minid},
		{{"XTRIM", "t", "MAXLEN", "1", "LIMIT", "10"}, .Limit_No_Approx},
		{{"XTRIM", "t", "MAXLEN", "=", "1", "LIMIT", "10"}, .Limit_No_Approx},
		{{"XTRIM", "t", "LIMIT", "10"}, .Limit_No_Strategy},
		{{"XTRIM", "t", "LIMIT", "0"}, .Xtrim_No_Strategy},
		{{"XTRIM", "t", "LIMIT", "-1"}, .Limit_Negative},
		{{"XTRIM", "t", "LIMIT", "abc"}, .Not_Integer},
		{{"XTRIM", "t", "MAXLEN", "=", "1", "FOO"}, .Syntax},
		{{"XTRIM", "t", "NOMKSTREAM", "MAXLEN", "1"}, .Syntax},
	}
	for c in cases {
		argv := args_of(..c.argv)
		err: st.Error
		if c.argv[0] == "XADD" {
			_, err = st.parse_xadd(argv)
		} else {
			_, err = st.parse_xtrim(argv)
		}
		testing.expectf(t, err == c.err, "%v => %v want %v", c.argv, err, c.err)
	}
	Message :: struct {
		e: st.Error,
		m: string,
	}
	messages := []Message {
		{.Id_Zero, "The ID specified in XADD must be greater than 0-0"},
		{.Invalid_ID, "Invalid stream ID specified as stream command argument"},
		{.Xadd_Arity, "wrong number of arguments for 'xadd' command"},
		{.Not_Integer, "value is not an integer or out of range"},
		{.Maxlen_Negative, "The MAXLEN argument must be >= 0."},
		{.Limit_No_Strategy, "syntax error, LIMIT cannot be used without specifying a trimming strategy"},
		{.Limit_No_Approx, "syntax error, LIMIT cannot be used without the special ~ option"},
		{.Maxlen_Minid, "syntax error, MAXLEN and MINID options at the same time are not compatible"},
		{.Limit_Negative, "The LIMIT argument must be >= 0."},
		{.Xtrim_No_Strategy, "syntax error, XTRIM must be called with a trimming strategy"},
		{.Syntax, "syntax error"},
		{.Id_Too_Small, "The ID specified in XADD is equal or smaller than the target stream top item"},
	}
	for msg in messages {
		testing.expect_value(t, st.error_message(msg.e), msg.m)
		testing.expect(t, !st.error_has_prefix(msg.e))
	}
	testing.expect(t, st.error_has_prefix(.Busygroup))
	testing.expect_value(t, st.error_message(.Busygroup), "BUSYGROUP Consumer Group name already exists")
}

@(test)
range_errors :: proc(t: ^testing.T) {
	Range_Case :: struct {
		argv:  []string,
		err:   st.Error,
		start: st.ID,
		end:   st.ID,
		count: i64,
	}
	cases := []Range_Case {
		{{"XRANGE", "r", "-", "+"}, .None, st.ID_MIN, st.ID_MAX, -1},
		{{"XRANGE", "r", "(3-1", "(3"}, .None, {3, 2}, {3, MAXU - 1}, -1},
		{{"XREVRANGE", "r", "(3", "(3-1"}, .None, {3, 2}, {3, MAXU - 1}, -1},
		{{"XRANGE", "r", "0", "5"}, .None, {0, 0}, {5, MAXU}, -1},
		{{"XRANGE", "r", "-", "+", "count", "2", "COUNT", "1"}, .None, st.ID_MIN, st.ID_MAX, 1},
		{{"XRANGE", "r", "-", "+", "COUNT", "0"}, .None, st.ID_MIN, st.ID_MAX, 0},
		{{"XRANGE", "r", "-", "+", "COUNT", "-5"}, .None, st.ID_MIN, st.ID_MAX, 0},
		{{"XRANGE", "r", "-", "+", "COUNT", "abc"}, .Not_Integer, {}, {}, 0},
		{{"XRANGE", "r", "-", "+", "COUNT"}, .Syntax, {}, {}, 0},
		{{"XRANGE", "r", "-", "-", "LIMIT", "1"}, .Syntax, {}, {}, 0},
		{{"XRANGE", "r", "x", "+"}, .Invalid_ID, {}, {}, 0},
		{{"XRANGE", "r", "(", "+"}, .Invalid_ID, {}, {}, 0},
		{{"XRANGE", "r", "(-", "+"}, .Invalid_ID, {}, {}, 0},
		{{"XRANGE", "r", "-", "(+"}, .Invalid_ID, {}, {}, 0},
		{{"XRANGE", "r", "((5", "+"}, .Invalid_ID, {}, {}, 0},
		{{"XRANGE", "r", "5-*", "+"}, .Invalid_ID, {}, {}, 0},
		{{"XRANGE", "r", "(18446744073709551615-18446744073709551615", "+"}, .Invalid_Start, {}, {}, 0},
		{{"XRANGE", "r", "-", "(0-0"}, .Invalid_End, {}, {}, 0},
		{{"XRANGE", "r", "-", "(0-0", "LIMIT", "1"}, .Invalid_End, {}, {}, 0},
		{{"XRANGE", "r", "(-", "(0-0", "COUNT", "1"}, .Invalid_ID, {}, {}, 0},
		{{"XREVRANGE", "r", "(0-0", "-", "LIMIT", "1"}, .Invalid_End, {}, {}, 0},
		{{"XREVRANGE", "r", "-", "(18446744073709551615-18446744073709551615"}, .Invalid_Start, {}, {}, 0},
	}
	for c in cases {
		start, end, count, err := st.parse_range_args(args_of(..c.argv), c.argv[0] == "XREVRANGE")
		testing.expectf(t, err == c.err, "%v => %v want %v", c.argv, err, c.err)
		if err == .None && c.err == .None {
			testing.expectf(t, start == c.start && end == c.end && count == c.count, "%v => %v %v %d", c.argv, start, end, count)
		}
	}
	testing.expect_value(t, st.error_message(.Invalid_Start), "invalid start ID for the interval")
	testing.expect_value(t, st.error_message(.Invalid_End), "invalid end ID for the interval")
}

@(test)
xread_errors :: proc(t: ^testing.T) {
	Read_Case :: struct {
		argv:  []string,
		group: bool,
		err:   st.Error,
	}
	cases := []Read_Case {
		{{"XREAD", "STREAMS", "a", "b", "0"}, false, .Unbalanced_Xread},
		{{"XREAD", "a", "b", "c"}, false, .Syntax},
		{{"XREAD", "COUNT", "1", "a", "STREAMS", "a", "0"}, false, .Syntax},
		{{"XREAD", "COUNT", "1", "STREAMS"}, false, .Syntax},
		{{"XREAD", "COUNT", "abc", "STREAMS", "a", "0"}, false, .Not_Integer},
		{{"XREAD", "BLOCK", "abc", "STREAMS", "a", "0"}, false, .Timeout_Not_Int},
		{{"XREAD", "BLOCK", "1.5", "STREAMS", "a", "0"}, false, .Timeout_Not_Int},
		{{"XREAD", "BLOCK", "-1", "STREAMS", "a", "0"}, false, .Timeout_Negative},
		{{"XREAD", "BLOCK", "9223372036854775807", "STREAMS", "a", "0"}, false, .Timeout_Range},
		{{"XREAD", "GROUP", "g", "c", "STREAMS", "a", "0"}, false, .Group_Option},
		{{"XREAD", "GROUP", "g", "STREAMS", "a", "0"}, false, .Group_Option},
		{{"XREAD", "NOACK", "STREAMS", "a", "0"}, false, .Noack_Option},
		{{"XREADGROUP", "COUNT", "1", "NOACK", "STREAMS", "q", ">"}, true, .Missing_Group},
		{{"XREADGROUP", "GROUP", "g", "c1", "COUNT", "1", "STREAMS", "q"}, true, .Unbalanced_Xreadgroup},
		{{"XREADGROUP", "GROUP", "g", "c1", "FOO", "STREAMS", "q", ">"}, true, .Syntax},
		{{"XREADGROUP", "NOACK", "GROUP", "g", "c4", "STREAMS", "q", ">"}, true, .None},
		{{"XREAD", "STREAMS", "a", "0"}, false, .None},
	}
	for c in cases {
		_, err := st.parse_xread_args(args_of(..c.argv), 1000, c.group)
		testing.expectf(t, err == c.err, "%v => %v want %v", c.argv, err, c.err)
	}
	a, err := st.parse_xread_args(args_of("XREAD", "COUNT", "1", "COUNT", "-2", "BLOCK", "0", "STREAMS", "x", "y", "1", "2"), 1000, false)
	testing.expect(t, err == .None && a.count == 0 && a.timeout == 0 && a.keys_at == 8 && a.key_count == 2)
	a, err = st.parse_xread_args(args_of("XREAD", "BLOCK", "250", "STREAMS", "x", "1"), 1000, false)
	testing.expect(t, err == .None && a.timeout == 1250)
	a, err = st.parse_xread_args(args_of("XREAD", "STREAMS", "x", "1"), 1000, false)
	testing.expect(t, err == .None && a.timeout == -1 && a.count == 0)
	a, err = st.parse_xread_args(args_of("XREADGROUP", "GROUP", "g", "c5", "GROUP", "h", "c6", "NOACK", "STREAMS", "q", "0"), 1000, true)
	testing.expect(t, err == .None && a.group_arg == 5 && a.noack)
	testing.expect_value(t, st.error_message(.Unbalanced_Xread), "Unbalanced 'xread' list of streams: for each stream key an ID or '$' must be specified.")
	testing.expect_value(t, st.error_message(.Gt_Id), "The > ID can be specified only when calling XREADGROUP using the GROUP <group> <consumer> option.")
	testing.expect_value(t, st.error_message(.Timeout_Range), "timeout is out of range")
}

@(test)
xsetid_rules :: proc(t: ^testing.T) {
	Setid_Case :: struct {
		argv: []string,
		err:  st.Error,
	}
	parse_cases := []Setid_Case {
		{{"XSETID", "s", "abc"}, .Invalid_ID},
		{{"XSETID", "s", "-"}, .Invalid_ID},
		{{"XSETID", "s", "5-*"}, .Invalid_ID},
		{{"XSETID", "s", "1-1", "0"}, .Syntax},
		{{"XSETID", "s", "1-1", "0-0"}, .Syntax},
		{{"XSETID", "s", "1-1", "ENTRIESADDED"}, .Syntax},
		{{"XSETID", "s", "1-1", "ENTRIESADDED", "abc"}, .Not_Integer},
		{{"XSETID", "s", "7-0", "ENTRIESADDED", "9223372036854775808"}, .Not_Integer},
		{{"XSETID", "s", "1-1", "ENTRIESADDED", "-1", "MAXDELETEDID", "0-0"}, .Entries_Added_Negative},
		{{"XSETID", "s", "1-1", "MAXDELETEDID", "2-0"}, .Setid_Max_Deleted},
		{{"XSETID", "s", "1-1", "MAXDELETEDID", "abc"}, .Invalid_ID},
		{{"XSETID", "s", "1-1", "MAXDELETEDID"}, .Syntax},
		{{"XSETID", "s", "6", "entriesadded", "11", "maxdeletedid", "5-9", "ENTRIESADDED", "12"}, .None},
	}
	for c in parse_cases {
		_, err := st.parse_xsetid_args(args_of(..c.argv))
		testing.expectf(t, err == c.err, "%v => %v want %v", c.argv, err, c.err)
	}
	s := new_stream_from({{"XADD", "s", "5-1", "a", "1"}, {"XADD", "s", "5-2", "a", "2"}, {"XADD", "s", "5-3", "a", "3"}})
	defer st.destroy(s)
	apply :: proc(s: st.Stream, parts: ..string) -> st.Error {
		a, err := st.parse_xsetid_args(args_of(..parts))
		if err != .None {
			return err
		}
		return st.xsetid_apply(s, &a)
	}
	testing.expect_value(t, apply(s, "XSETID", "s", "5-2"), st.Error.Setid_Top)
	testing.expect_value(t, apply(s, "XSETID", "s", "5-3", "ENTRIESADDED", "2"), st.Error.Setid_Entries_Added)
	testing.expect_value(t, apply(s, "XSETID", "s", "5-3", "ENTRIESADDED", "3"), st.Error.None)
	testing.expect_value(t, apply(s, "XSETID", "s", "6", "ENTRIESADDED", "10", "MAXDELETEDID", "5-9"), st.Error.None)
	testing.expect(t, s.last_id == st.ID{6, 0} && s.entries_added == 10 && s.max_deleted_entry_id == st.ID{5, 9})
	testing.expect_value(t, apply(s, "XSETID", "s", "5-8"), st.Error.Setid_Current_Max_Deleted)
	testing.expect_value(t, apply(s, "XSETID", "s", "5-9"), st.Error.None)
	testing.expect_value(t, apply(s, "XSETID", "s", "7-0", "MAXDELETEDID", "0-0"), st.Error.None)
	testing.expect(t, s.max_deleted_entry_id == st.ID{5, 9})
	testing.expect_value(t, apply(s, "XSETID", "s", "100-0", "ENTRIESADDED", "3", "MAXDELETEDID", "0-0"), st.Error.None)
	testing.expect_value(t, apply(s, "XSETID", "s", "1-1", "ENTRIESADDED", "1"), st.Error.Setid_Current_Max_Deleted)
	testing.expect_value(t, apply(s, "XSETID", "s", "5-8", "MAXDELETEDID", "5-1"), st.Error.Setid_Current_Max_Deleted)
	testing.expect_value(t, apply(s, "XSETID", "s", "5-8", "MAXDELETEDID", "5-9"), st.Error.Setid_Max_Deleted)
	d := new_stream_from({{"XADD", "d", "5-1", "a", "1"}, {"XADD", "d", "5-2", "a", "2"}, {"XADD", "d", "5-3", "a", "3"}})
	defer st.destroy(d)
	testing.expect_value(t, st.xdel_apply(d, {st.ID{5, 3}}), 1)
	testing.expect(t, d.max_deleted_entry_id == st.ID{5, 3} && d.length == 2)
	testing.expect_value(t, apply(d, "XSETID", "d", "5-1"), st.Error.Setid_Current_Max_Deleted)
	testing.expect_value(t, apply(d, "XSETID", "d", "5-2"), st.Error.Setid_Current_Max_Deleted)
	testing.expect_value(t, apply(d, "XSETID", "d", "5-2", "ENTRIESADDED", "0"), st.Error.Setid_Current_Max_Deleted)
	testing.expect_value(t, apply(d, "XSETID", "d", "5-3"), st.Error.None)
	n := new_stream_from({{"XADD", "n", "5-1", "a", "1"}, {"XADD", "n", "5-2", "a", "2"}})
	defer st.destroy(n)
	testing.expect_value(t, apply(n, "XSETID", "n", "5-1", "ENTRIESADDED", "1"), st.Error.Setid_Top)
	testing.expect_value(t, apply(n, "XSETID", "n", "5-2", "ENTRIESADDED", "1"), st.Error.Setid_Entries_Added)
	testing.expect_value(t, st.error_message(.Setid_Top), "The ID specified in XSETID is smaller than the target stream top item")
	testing.expect_value(t, st.error_message(.Setid_Entries_Added), "The entries_added specified in XSETID is smaller than the target stream length")
	testing.expect_value(t, st.error_message(.Setid_Current_Max_Deleted), "The ID specified in XSETID is smaller than current max_deleted_entry_id")
	testing.expect_value(t, st.error_message(.Setid_Max_Deleted), "The ID specified in XSETID is smaller than the provided max_deleted_entry_id")
	testing.expect_value(t, st.error_message(.Entries_Added_Negative), "entries_added must be positive")
	testing.expect_value(t, st.error_message(.No_Such_Key), "no such key")
}

@(test)
xinfo_and_group_option_errors :: proc(t: ^testing.T) {
	Opt_Case :: struct {
		opts:  []string,
		err:   st.Error,
		full:  bool,
		count: i64,
	}
	cases := []Opt_Case {
		{{}, .None, false, 0},
		{{"FULL"}, .None, true, 10},
		{{"full"}, .None, true, 10},
		{{"FULL", "COUNT", "0"}, .None, true, 0},
		{{"FULL", "COUNT", "-1"}, .None, true, 0},
		{{"FULL", "COUNT", "3"}, .None, true, 3},
		{{"FULL", "COUNT"}, .Subcommand_Syntax, false, 0},
		{{"FULL", "COUNT", "abc"}, .Not_Integer, false, 0},
		{{"FULLX"}, .Subcommand_Syntax, false, 0},
		{{"FULL", "COUNTX", "1"}, .Subcommand_Syntax, false, 0},
		{{"FULL", "1", "2"}, .Subcommand_Syntax, false, 0},
		{{"x"}, .Subcommand_Syntax, false, 0},
		{{"FULL", "COUNT", "1", "x"}, .Subcommand_Syntax, false, 0},
	}
	for c in cases {
		full, count, err := st.parse_xinfo_stream_opts(args_of(..c.opts))
		testing.expectf(t, err == c.err, "%v => %v want %v", c.opts, err, c.err)
		if err == .None {
			testing.expectf(t, full == c.full && count == c.count, "%v => %v %d", c.opts, full, count)
		}
	}
	Group_Case :: struct {
		argv:     []string,
		err:      st.Error,
		mkstream: bool,
		read:     i64,
	}
	group_cases := []Group_Case {
		{{"XGROUP", "CREATE", "s", "g", "0"}, .None, false, -1},
		{{"XGROUP", "CREATE", "s", "g3", "1-2", "ENTRIESREAD", "2"}, .None, false, 2},
		{{"XGROUP", "CREATE", "s", "g4", "0", "ENTRIESREAD", "-1"}, .None, false, -1},
		{{"XGROUP", "CREATE", "s", "g5", "0", "ENTRIESREAD", "-3"}, .Entries_Read_Value, false, 0},
		{{"XGROUP", "CREATE", "s", "g5", "0", "ENTRIESREAD", "abc"}, .Not_Integer, false, 0},
		{{"XGROUP", "CREATE", "s", "g5", "0", "ENTRIESREAD"}, .Subcommand_Syntax, false, 0},
		{{"XGROUP", "CREATE", "s", "g5", "0", "MKSTREAM", "ENTRIESREAD", "5"}, .None, true, 5},
		{{"XGROUP", "CREATE", "s", "g6", "0", "FOO"}, .Subcommand_Syntax, false, 0},
		{{"XGROUP", "SETID", "s", "g3", "0", "MKSTREAM"}, .Subcommand_Syntax, false, 0},
		{{"XGROUP", "SETID", "s", "g3", "0", "ENTRIESREAD", "1", "x"}, .Subcommand_Syntax, false, 0},
		{{"XGROUP", "SETID", "s", "g3", "0", "ENTRIESREAD", "-2"}, .Entries_Read_Value, false, 0},
		{{"XGROUP", "CREATECONSUMER", "s", "g1", "alice"}, .None, false, -1},
		{{"XGROUP", "DESTROY", "s", "g1"}, .None, false, -1},
	}
	for c in group_cases {
		mk, read, err := st.parse_xgroup_opts(args_of(..c.argv))
		testing.expectf(t, err == c.err, "%v => %v want %v", c.argv, err, c.err)
		if err == .None {
			testing.expectf(t, mk == c.mkstream && read == c.read, "%v => %v %d", c.argv, mk, read)
		}
	}
	testing.expect_value(t, st.error_message(.Entries_Read_Value), "value for ENTRIESREAD must be positive or -1")
}

@(test)
pending_and_claim_parsing :: proc(t: ^testing.T) {
	Pending_Case :: struct {
		argv:     []string,
		err:      st.Error,
		justinfo: bool,
		minidle:  i64,
		start:    st.ID,
		end:      st.ID,
		count:    i64,
		consumer: int,
	}
	cases := []Pending_Case {
		{{"XPENDING", "p", "g"}, .None, true, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "-", "+", "10"}, .None, false, 0, st.ID_MIN, st.ID_MAX, 10, 0},
		{{"XPENDING", "p", "g", "-", "+", "10", "alice"}, .None, false, 0, st.ID_MIN, st.ID_MAX, 10, 6},
		{{"XPENDING", "p", "g", "-", "+", "10", "alice", "extra"}, .None, false, 0, st.ID_MIN, st.ID_MAX, 10, 6},
		{{"XPENDING", "p", "g", "(2", "(5", "10"}, .None, false, 0, {2, 1}, {5, MAXU - 1}, 10, 0},
		{{"XPENDING", "p", "g", "-", "+", "-1"}, .None, false, 0, st.ID_MIN, st.ID_MAX, 0, 0},
		{{"XPENDING", "p", "g", "IDLE", "200", "-", "+", "10"}, .None, false, 200, st.ID_MIN, st.ID_MAX, 10, 0},
		{{"XPENDING", "p", "g", "IDLE", "0", "1-0", "+", "5", "bob"}, .None, false, 0, {1, 0}, st.ID_MAX, 5, 8},
		{{"XPENDING", "p", "g", "-", "+", "abc"}, .Not_Integer, false, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "abc", "+", "10"}, .Invalid_ID, false, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "-", "abc", "10"}, .Invalid_ID, false, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "(18446744073709551615-18446744073709551615", "+", "10"}, .Invalid_Start, false, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "-", "(0-0", "10"}, .Invalid_End, false, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "IDLE", "abc", "-", "+", "10"}, .Not_Integer, false, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "IDLE", "10", "-", "+"}, .Syntax, false, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "-", "+"}, .Syntax, false, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "-"}, .Syntax, false, 0, {}, {}, 0, 0},
		{{"XPENDING", "p", "g", "IDLE", "0", "-", "+", "10", "alice", "extra"}, .Syntax, false, 0, {}, {}, 0, 0},
	}
	for c in cases {
		a, err := st.parse_xpending_args(args_of(..c.argv))
		testing.expectf(t, err == c.err, "%v => %v want %v", c.argv, err, c.err)
		if err == .None && c.err == .None {
			ok := a.justinfo == c.justinfo && a.minidle == c.minidle && a.consumer_idx == c.consumer
			if !c.justinfo {
				ok = ok && a.start == c.start && a.end == c.end && a.count == c.count
			}
			testing.expectf(t, ok, "%v => %v", c.argv, a)
		}
	}
	Claim_Case :: struct {
		argv: []string,
		err:  st.Error,
		bad:  int,
		ids:  int,
	}
	claims := []Claim_Case {
		{{"XCLAIM", "p", "g", "dave", "200", "1-0", "2-0", "7-0"}, .None, 0, 3},
		{{"XCLAIM", "p", "g", "dave", "0", "1-0", "LASTID", "abc"}, .Invalid_ID, 0, 1},
		{{"XCLAIM", "p", "g", "dave", "0", "1-0", "IDLE", "abc"}, .Claim_Idle, 0, 1},
		{{"XCLAIM", "p", "g", "dave", "0", "1-0", "TIME", "x"}, .Claim_Time, 0, 1},
		{{"XCLAIM", "p", "g", "dave", "0", "1-0", "RETRYCOUNT", "x"}, .Claim_Retry, 0, 1},
		{{"XCLAIM", "p", "g", "dave", "0", "1-0", "FOO"}, .Claim_Option, 6, 1},
		{{"XCLAIM", "p", "g", "dave", "0", "1-0", "IDLE"}, .Claim_Option, 6, 1},
		{{"XCLAIM", "p", "g", "dave", "abc", "1-0"}, .Claim_Min_Idle, 0, 0},
		{{"XCLAIM", "p", "g", "dave", "0", "abc"}, .Claim_Option, 5, 0},
		{{"XCLAIM", "p", "g", "dave", "0", "1-0", "1-0", "JUSTID", "FORCE", "RETRYCOUNT", "-3"}, .None, 0, 2},
	}
	for c in claims {
		ids: [dynamic]st.ID
		defer delete(ids)
		a, bad, err := st.parse_xclaim_args(args_of(..c.argv), 5000, &ids)
		testing.expectf(t, err == c.err && bad == c.bad && len(ids) == c.ids, "%v => %v bad=%d ids=%d", c.argv, err, bad, len(ids))
		_ = a
	}
	ids: [dynamic]st.ID
	defer delete(ids)
	a, _, err := st.parse_xclaim_args(args_of("XCLAIM", "p", "g", "d", "-5", "4-0", "IDLE", "5000", "RETRYCOUNT", "9", "JUSTID", "LASTID", "50-0"), 6000, &ids)
	testing.expect(t, err == .None && a.minidle == 0 && a.deliverytime == 1000 && a.retrycount == 9 && a.justid && a.last_id == st.ID{50, 0})
	clear(&ids)
	a, _, err = st.parse_xclaim_args(args_of("XCLAIM", "p", "g", "d", "0", "4-0", "TIME", "1000", "FORCE"), 6000, &ids)
	testing.expect(t, err == .None && a.deliverytime == 1000 && a.force && a.retrycount == -1)
	Auto_Case :: struct {
		argv: []string,
		err:  st.Error,
	}
	autos := []Auto_Case {
		{{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT", "2"}, .None},
		{{"XAUTOCLAIM", "p", "g", "frank", "0", "(1-0"}, .None},
		{{"XAUTOCLAIM", "p", "g", "frank", "0", "(18446744073709551615-18446744073709551615"}, .Invalid_Start},
		{{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT", "0"}, .Count_Positive},
		{{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT", "abc"}, .Count_Positive},
		{{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT", "576460752303423488"}, .Count_Positive},
		{{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "COUNT"}, .Syntax},
		{{"XAUTOCLAIM", "p", "g", "frank", "0", "-", "FOO"}, .Syntax},
		{{"XAUTOCLAIM", "p", "g", "frank", "abc", "-"}, .Autoclaim_Min_Idle},
		{{"XAUTOCLAIM", "p", "g", "frank", "0", "abc"}, .Invalid_ID},
	}
	for c in autos {
		_, aerr := st.parse_xautoclaim_args(args_of(..c.argv))
		testing.expectf(t, aerr == c.err, "%v => %v want %v", c.argv, aerr, c.err)
	}
	auto, aerr := st.parse_xautoclaim_args(args_of("XAUTOCLAIM", "p", "g", "x", "-9", "5", "JUSTID"))
	testing.expect(t, aerr == .None && auto.minidle == 0 && auto.start == st.ID{5, 0} && auto.count == 100 && auto.justid)
	testing.expect_value(t, st.error_message(.Count_Positive), "COUNT must be > 0")
	testing.expect_value(t, st.error_message(.Claim_Min_Idle), "Invalid min-idle-time argument for XCLAIM")
	testing.expect_value(t, st.error_message(.Autoclaim_Min_Idle), "Invalid min-idle-time argument for XAUTOCLAIM")
}

@(test)
config_parameters :: proc(t: ^testing.T) {
	old := set_limits(4096, 100)
	defer restore_limits(old)
	p := st.config_param(bytes_of("stream-node-max-entries"))
	testing.expect_value(t, p, st.Config_Param.Node_Max_Entries)
	q := st.config_param(bytes_of("STREAM-NODE-MAX-BYTES"))
	testing.expect_value(t, q, st.Config_Param.Node_Max_Bytes)
	testing.expect_value(t, st.config_param(bytes_of("stream-node")), st.Config_Param.None)
	Cfg_Case :: struct {
		p:   st.Config_Param,
		s:   string,
		v:   i64,
		err: string,
	}
	cases := []Cfg_Case {
		{.Node_Max_Entries, "-1", 0, st.CONFIG_RANGE_ERROR},
		{.Node_Max_Entries, "abc", 0, "argument couldn't be parsed into an integer"},
		{.Node_Max_Entries, "9223372036854775807", max(i64), ""},
		{.Node_Max_Entries, "9223372036854775808", 0, "argument couldn't be parsed into an integer"},
		{.Node_Max_Bytes, "1x", 0, "argument must be a memory value"},
		{.Node_Max_Bytes, "-1", 0, "argument must be a memory value"},
		{.Node_Max_Bytes, "1kb", 1024, ""},
		{.Node_Max_Bytes, "2k", 2000, ""},
		{.Node_Max_Bytes, "1gb", 1073741824, ""},
		{.Node_Max_Bytes, "3MB", 3145728, ""},
		{.Node_Max_Bytes, "7", 7, ""},
		{.Node_Max_Bytes, "9223372036854775808", 0, st.CONFIG_RANGE_ERROR},
	}
	for c in cases {
		v, err := st.config_parse(c.p, bytes_of(c.s))
		testing.expectf(t, err == c.err && (err != "" || v == c.v), "%v %q => %d %q", c.p, c.s, v, err)
	}
	st.config_apply(.Node_Max_Entries, 7)
	st.config_apply(.Node_Max_Bytes, 200)
	testing.expect_value(t, st.config_value(.Node_Max_Entries), 7)
	testing.expect_value(t, st.config_value(.Node_Max_Bytes), 200)
	testing.expect_value(t, st.stream_node_max_entries, 7)
	testing.expect_value(t, st.stream_node_max_bytes, 200)
	testing.expect_value(t, st.CONFIG_NAMES[.Node_Max_Bytes], "stream-node-max-bytes")
}

@(test)
argument_helpers :: proc(t: ^testing.T) {
	testing.expect(t, st.eq_nocase(bytes_of("MaxLen"), "maxlen"))
	testing.expect(t, !st.eq_nocase(bytes_of("maxlen\x00"), "maxlen"))
	testing.expect_value(t, string(st.cstr(bytes_of("ab\x00cd"))), "ab")
	testing.expect_value(t, string(st.cstr(bytes_of("abcd"))), "abcd")
	testing.expect(t, st.is_byte(bytes_of("$"), '$'))
	testing.expect(t, st.is_byte(bytes_of("$\x00x"), '$'))
	testing.expect(t, !st.is_byte(bytes_of("$x"), '$'))
	testing.expect(t, !st.is_byte(bytes_of(""), '$'))
	testing.expect_value(t, st.WRONGTYPE_ERROR, "WRONGTYPE Operation against a key holding the wrong kind of value")
}

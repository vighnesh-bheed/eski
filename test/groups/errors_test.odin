package groups_test

import st "../../src/streamtype"
import "core:strings"
import "core:testing"

argv_of :: proc(line: string) -> [][]u8 {
	parts := strings.split(line, " ", context.temp_allocator)
	out := make([][]u8, len(parts), context.temp_allocator)
	for p, i in parts {
		out[i] = transmute([]u8)p
	}
	return out
}

wire :: proc(e: st.Error) -> string {
	if st.error_has_prefix(e) {
		return st.error_message(e)
	}
	return strings.concatenate({"ERR ", st.error_message(e)}, context.temp_allocator)
}

@(test)
group_error_strings_match_the_transcript :: proc(t: ^testing.T) {
	testing.expect_value(t, wire(.Xgroup_No_Key), "ERR The XGROUP subcommand requires the key to exist. Note that for CREATE you may want to use the MKSTREAM option to create an empty stream automatically.")
	testing.expect_value(t, wire(.Busygroup), "BUSYGROUP Consumer Group name already exists")
	testing.expect_value(t, wire(.Entries_Read_Value), "ERR value for ENTRIESREAD must be positive or -1")
	testing.expect_value(t, wire(.Not_Integer), "ERR value is not an integer or out of range")
	testing.expect_value(t, wire(.Invalid_ID), "ERR Invalid stream ID specified as stream command argument")
	testing.expect_value(t, wire(.Dollar_Group), "ERR The $ ID is meaningless in the context of XREADGROUP: you want to read the history of this consumer by specifying a proper ID, or use the > ID to get new messages. The $ ID would just return an empty result set.")
	testing.expect_value(t, wire(.Plus_Group), "ERR The + ID is meaningless in the context of XREADGROUP: you want to read the history of this consumer by specifying a proper ID, or use the > ID to get new messages. The + ID would just return an empty result set.")
	testing.expect_value(t, wire(.Missing_Group), "ERR Missing GROUP option for XREADGROUP")
	testing.expect_value(t, wire(.Unbalanced_Xreadgroup), "ERR Unbalanced 'xreadgroup' list of streams: for each stream key an ID or '>' must be specified.")
	testing.expect_value(t, wire(.Claim_Min_Idle), "ERR Invalid min-idle-time argument for XCLAIM")
	testing.expect_value(t, wire(.Claim_Idle), "ERR Invalid IDLE option argument for XCLAIM")
	testing.expect_value(t, wire(.Claim_Time), "ERR Invalid TIME option argument for XCLAIM")
	testing.expect_value(t, wire(.Claim_Retry), "ERR Invalid RETRYCOUNT option argument for XCLAIM")
	testing.expect_value(t, wire(.Autoclaim_Min_Idle), "ERR Invalid min-idle-time argument for XAUTOCLAIM")
	testing.expect_value(t, wire(.Count_Positive), "ERR COUNT must be > 0")
	testing.expect_value(t, wire(.Syntax), "ERR syntax error")
	testing.expect_value(t, wire(.Invalid_Start), "ERR invalid start ID for the interval")
	testing.expect_value(t, wire(.Invalid_End), "ERR invalid end ID for the interval")
	testing.expect_value(t, wire(.Timeout_Negative), "ERR timeout is negative")
	testing.expect_value(t, wire(.Timeout_Not_Int), "ERR timeout is not an integer or out of range")
	testing.expect_value(t, wire(.No_Such_Key), "ERR no such key")
}

@(test)
nogroup_and_claim_option_messages :: proc(t: ^testing.T) {
	buf := make([dynamic]u8, context.temp_allocator)
	st.append_nogroup_error(&buf, .For_Key_Name, b("nokey"), b("nog"))
	testing.expect_value(t, string(buf[:]), "NOGROUP No such consumer group 'nog' for key name 'nokey'")
	clear(&buf)
	st.append_nogroup_error(&buf, .Key_Or_Group, b("missing"), b("g"))
	testing.expect_value(t, string(buf[:]), "NOGROUP No such key 'missing' or consumer group 'g'")
	clear(&buf)
	st.append_nogroup_error(&buf, .Xreadgroup, b("s"), b("nog"))
	testing.expect_value(t, string(buf[:]), "NOGROUP No such key 's' or consumer group 'nog' in XREADGROUP with GROUP option")
	clear(&buf)
	st.append_claim_option_error(&buf, b("BOGUS"))
	testing.expect_value(t, string(buf[:]), "ERR Unrecognized XCLAIM option 'BOGUS'")
}

@(test)
xgroup_help_lines :: proc(t: ^testing.T) {
	want := []string {
		"XGROUP <subcommand> [<arg> [value] [opt] ...]. Subcommands are:",
		"CREATE <key> <groupname> <id|$> [option]",
		"    Create a new consumer group. Options are:",
		"    * MKSTREAM",
		"      Create the empty stream if it does not exist.",
		"    * ENTRIESREAD entries_read",
		"      Set the group's entries_read counter (internal use).",
		"CREATECONSUMER <key> <groupname> <consumer>",
		"    Create a new consumer in the specified group.",
		"DELCONSUMER <key> <groupname> <consumer>",
		"    Remove the specified consumer.",
		"DESTROY <key> <groupname>",
		"    Remove the specified group.",
		"SETID <key> <groupname> <id|$> [ENTRIESREAD entries_read]",
		"    Set the current group ID and entries_read counter.",
		"HELP",
		"    Print this help.",
	}
	testing.expect_value(t, len(st.XGROUP_HELP), len(want))
	for line, i in want {
		testing.expect_value(t, st.XGROUP_HELP[i], line)
	}
}

@(test)
xgroup_option_parsing :: proc(t: ^testing.T) {
	cases := []struct {
		line:     string,
		mkstream: bool,
		read:     i64,
		err:      st.Error,
	} {
		{"XGROUP CREATE s g 0", false, -1, .None},
		{"XGROUP CREATE s g $ MKSTREAM", true, -1, .None},
		{"XGROUP CREATE s g 0 ENTRIESREAD 5", false, 5, .None},
		{"XGROUP CREATE s g 0 MKSTREAM ENTRIESREAD 5", true, 5, .None},
		{"XGROUP CREATE s g 0 ENTRIESREAD -1", false, -1, .None},
		{"XGROUP CREATE s g 0 ENTRIESREAD -2", false, -1, .Entries_Read_Value},
		{"XGROUP CREATE s g 0 ENTRIESREAD x", false, -1, .Not_Integer},
		{"XGROUP CREATE s g 0 ENTRIESREAD", false, -1, .Subcommand_Syntax},
		{"XGROUP CREATE s g 0 BOGUS", false, -1, .Subcommand_Syntax},
		{"XGROUP SETID s g 0 MKSTREAM", false, -1, .Subcommand_Syntax},
		{"XGROUP SETID s g $ ENTRIESREAD 3", false, 3, .None},
		{"XGROUP SETID s g 0 ENTRIESREAD 1 x", false, 1, .Subcommand_Syntax},
	}
	for c in cases {
		m, er, err := st.parse_xgroup_opts(argv_of(c.line))
		testing.expectf(t, err == c.err, "%s: err %v want %v", c.line, err, c.err)
		if c.err == .None {
			testing.expectf(t, m == c.mkstream && er == c.read, "%s: got %v %v", c.line, m, er)
		}
	}
	testing.expect(t, len(argv_of("XGROUP CREATE s g6 0 MKSTREAM MKSTREAM ENTRIESREAD 1")) > st.XGROUP_CREATE_MAX_ARGS)
	testing.expect(t, len(argv_of("XGROUP CREATE s g 0 MKSTREAM ENTRIESREAD 5")) <= st.XGROUP_CREATE_MAX_ARGS)
}

@(test)
xpending_xclaim_xautoclaim_parsing :: proc(t: ^testing.T) {
	pend := []struct {
		line: string,
		err:  st.Error,
	} {
		{"XPENDING s g", .None},
		{"XPENDING s g - + 10", .None},
		{"XPENDING s g - +", .Syntax},
		{"XPENDING s g x + 1", .Invalid_ID},
		{"XPENDING s g IDLE x - + 10", .Not_Integer},
		{"XPENDING s g IDLE 10 - +", .Syntax},
		{"XPENDING s g (18446744073709551615-18446744073709551615 + 10", .Invalid_Start},
		{"XPENDING s g - (0-0 10", .Invalid_End},
		{"XPENDING s g - + abc", .Not_Integer},
		{"XPENDING s g IDLE 0 - + 10 alice extra", .Syntax},
	}
	for c in pend {
		_, err := st.parse_xpending_args(argv_of(c.line))
		testing.expectf(t, err == c.err, "%s: err %v want %v", c.line, err, c.err)
	}
	p, _ := st.parse_xpending_args(argv_of("XPENDING s g IDLE -1 (1-0 + 2 bob"))
	testing.expect(t, p.minidle == 0 && p.start == id(1, 1) && p.end == st.ID_MAX && p.count == 2 && p.consumer_idx == 8)
	claims := []struct {
		line: string,
		bad:  int,
		err:  st.Error,
	} {
		{"XCLAIM s g c x 8-0", 0, .Claim_Min_Idle},
		{"XCLAIM s g c 0 abc", 5, .Claim_Option},
		{"XCLAIM s g c 0 8-0 BOGUS", 6, .Claim_Option},
		{"XCLAIM s g c 0 8-0 IDLE", 6, .Claim_Option},
		{"XCLAIM s g c 0 8-0 IDLE abc", 0, .Claim_Idle},
		{"XCLAIM s g c 0 8-0 TIME x", 0, .Claim_Time},
		{"XCLAIM s g c 0 8-0 RETRYCOUNT x", 0, .Claim_Retry},
		{"XCLAIM s g c 0 8-0 LASTID abc", 0, .Invalid_ID},
		{"XCLAIM s g c 0 8-0 IDLE -1", 0, .None},
		{"XCLAIM s g c 0 8-0 RETRYCOUNT -1", 0, .None},
	}
	for c in claims {
		got := make([dynamic]st.ID, context.temp_allocator)
		_, bad, err := st.parse_xclaim_args(argv_of(c.line), T0, &got)
		testing.expectf(t, err == c.err, "%s: err %v want %v", c.line, err, c.err)
		if c.err == .Claim_Option {
			testing.expectf(t, bad == c.bad, "%s: bad %v want %v", c.line, bad, c.bad)
		}
	}
	got := make([dynamic]st.ID, context.temp_allocator)
	a, _, _ := st.parse_xclaim_args(argv_of("XCLAIM s g c -5 1-0 2-0 IDLE 5000 RETRYCOUNT 7 FORCE JUSTID LASTID 20-0"), T0, &got)
	testing.expect(t, same_ids(got[:], ids({1, 0}, {2, 0})))
	testing.expect(t, a.idle_floor == 0 && a.stamp == T0 - 5000 && a.tries == 7 && .Force in a.flags && .Ids_Only in a.flags && a.raise_to == id(20))
	auto := []struct {
		line: string,
		err:  st.Error,
	} {
		{"XAUTOCLAIM s g c 0 0", .None},
		{"XAUTOCLAIM s g c 0 0 COUNT 0", .Count_Positive},
		{"XAUTOCLAIM s g c 0 0 COUNT -1", .Count_Positive},
		{"XAUTOCLAIM s g c 0 0 COUNT abc", .Count_Positive},
		{"XAUTOCLAIM s g c 0 0 COUNT 576460752303423488", .Count_Positive},
		{"XAUTOCLAIM s g c 0 0 COUNT 576460752303423487", .None},
		{"XAUTOCLAIM s g c 0 0 COUNT 9999999999", .None},
		{"XAUTOCLAIM s g c 0 0 COUNT", .Syntax},
		{"XAUTOCLAIM s g c 0 0 BOGUS", .Syntax},
		{"XAUTOCLAIM s g c x 0", .Autoclaim_Min_Idle},
		{"XAUTOCLAIM s g c 0 x", .Invalid_ID},
		{"XAUTOCLAIM s g c 0 (18446744073709551615-18446744073709551615", .Invalid_Start},
	}
	for c in auto {
		_, err := st.parse_xautoclaim_args(argv_of(c.line))
		testing.expectf(t, err == c.err, "%s: err %v want %v", c.line, err, c.err)
	}
	ac, _ := st.parse_xautoclaim_args(argv_of("XAUTOCLAIM s g c -1 (1-0 JUSTID"))
	testing.expect(t, ac.minidle == 0 && ac.start == id(1, 1) && ac.count == 100 && ac.justid)
}

@(test)
xreadgroup_option_parsing :: proc(t: ^testing.T) {
	cases := []struct {
		line: string,
		err:  st.Error,
	} {
		{"XREADGROUP GROUP g c STREAMS s >", .None},
		{"XREADGROUP GROUP g c COUNT 1 STREAMS s", .Unbalanced_Xreadgroup},
		{"XREADGROUP COUNT 1 NOACK STREAMS q >", .Missing_Group},
		{"XREADGROUP GROUP g c BOGUS STREAMS s >", .Syntax},
		{"XREADGROUP GROUP g c COUNT x STREAMS s >", .Not_Integer},
		{"XREADGROUP GROUP g c BLOCK -1 STREAMS s >", .Timeout_Negative},
		{"XREADGROUP GROUP g c BLOCK x STREAMS s >", .Timeout_Not_Int},
	}
	for c in cases {
		_, err := st.parse_xread_args(argv_of(c.line), T0, true)
		testing.expectf(t, err == c.err, "%s: err %v want %v", c.line, err, c.err)
	}
	a, _ := st.parse_xread_args(argv_of("XREADGROUP GROUP g c5 GROUP h c6 NOACK COUNT -3 STREAMS q r 0 >"), T0, true)
	testing.expect(t, a.group_arg == 5 && a.noack && a.count == 0 && a.key_count == 2 && a.timeout == -1)
}

package stringwork

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"
import j "../../src"
import fc "../../src/fpconv"

@(test)
inline_string_sections_resp2 :: proc(t: ^testing.T) {
	context.allocator = heap()
	replay_text(t, "inline strings resp2", INLINE_STRING_CASES, 2, true)
}

@(test)
inline_string_sections_resp3 :: proc(t: ^testing.T) {
	context.allocator = heap()
	replay_text(t, "inline strings resp3", INLINE_STRING_CASES, 3, true)
}

@(test)
inline_ifeq_resp2 :: proc(t: ^testing.T) {
	context.allocator = heap()
	replay_text(t, "inline ifeq resp2", INLINE_IFEQ_CASES, 2, true)
}

@(test)
inline_ifeq_resp3 :: proc(t: ^testing.T) {
	context.allocator = heap()
	replay_text(t, "inline ifeq resp3", INLINE_IFEQ_CASES, 3, true)
}

@(test)
inline_lcs_types_resp2 :: proc(t: ^testing.T) {
	context.allocator = heap()
	replay_text(t, "inline lcs types resp2", INLINE_LCS_TYPE_CASES, 2, false)
}

@(test)
inline_lcs_types_resp3 :: proc(t: ^testing.T) {
	context.allocator = heap()
	replay_text(t, "inline lcs types resp3", INLINE_LCS_TYPE_CASES, 3, false)
}

@(test)
inline_score_arithmetic_resp2 :: proc(t: ^testing.T) {
	context.allocator = heap()
	replay_text(t, "inline scores resp2", INLINE_SCORE_CASES, 2, false)
}

@(test)
inline_score_arithmetic_resp3 :: proc(t: ^testing.T) {
	context.allocator = heap()
	replay_text(t, "inline scores resp3", INLINE_SCORE_CASES, 3, false)
}

inline_sections_present :: proc(t: ^testing.T, text: string, names: []string) {
	for name in names {
		testing.expectf(t, strings.contains(text, strings.concatenate({"## ", name, "\n"})), "inline cases lack section %q", name)
	}
}

@(test)
inline_cases_cover_every_section :: proc(t: ^testing.T) {
	context.allocator = heap()
	inline_sections_present(t, INLINE_STRING_CASES, {
		"SET and GET basics",
		"SET conditions and GET option",
		"SET expiry options",
		"GETEX",
		"GETDEL GETSET SETNX SETEX PSETEX",
		"MGET MSET MSETNX",
		"APPEND STRLEN",
		"SETRANGE",
		"GETRANGE SUBSTR",
		"INCR DECR INCRBY DECRBY",
		"INCRBYFLOAT",
		"LCS",
		"DEBUG and encodings",
	})
	inline_sections_present(t, INLINE_IFEQ_CASES, {"IFEQ"})
	testing.expect(t, strings.contains(INLINE_LCS_TYPE_CASES, "LCS l s BOGUS => -ERR The specified keys must contain string values\n"))
	testing.expect(t, strings.contains(INLINE_LCS_TYPE_CASES, "LCS missing missing BOGUS => -ERR syntax error\n"))
	inline_sections_present(t, INLINE_SCORE_CASES, {"scores arithmetic that produces rounding", "bit patterns through DEBUG and ZSCAN"})
	testing.expect(t, len(DOUBLE_CASES) > 150)
}

encode_score :: proc(text: string, resp: u8) -> string {
	if resp == 3 {
		return strings.concatenate({",", text, "\r\n"})
	}
	b: [dynamic]u8
	put_bulk(&b, bytes_of(text))
	return string(b[:])
}

@(test)
format_double_matches_every_observed_score :: proc(t: ^testing.T) {
	context.allocator = heap()
	checked := 0
	for dc in DOUBLE_CASES {
		if len(dc.error) > 0 {
			continue
		}
		buf: [fc.DOUBLE_STR_MAX]u8
		n := fc.format_double(buf[:], transmute(f64)dc.bits)
		testing.expectf(t, string(buf[:n]) == dc.incr, "%s (bits %x): got %q want %q", dc.text, dc.bits, string(buf[:n]), dc.incr)
		checked += 1
	}
	testing.expect(t, checked > 150)
}

@(test)
observed_scores_through_the_request_path :: proc(t: ^testing.T) {
	context.allocator = heap()
	for resp in ([?]u8{2, 3}) {
		s := open_session(resp, false)
		for dc in DOUBLE_CASES {
			call(&s, "del", "z", "zi", "zz")
			added := call(&s, "zadd", "z", dc.text, "m")
			if len(dc.error) > 0 {
				testing.expectf(t, added == strings.concatenate({dc.error, "\r\n"}), "resp%d ZADD %s: got %q want %q", resp, dc.text, added, dc.error)
				continue
			}
			testing.expectf(t, added == ":1\r\n", "resp%d ZADD %s: got %q", resp, dc.text, added)
			score := call(&s, "zscore", "z", "m")
			want_score := encode_score(dc.score, resp)
			testing.expectf(t, score == want_score, "resp%d ZSCORE after ZADD %s: got %q want %q", resp, dc.text, score, want_score)
			incr := call(&s, "zincrby", "zi", dc.text, "n")
			want_incr := encode_score(dc.incr, resp)
			testing.expectf(t, incr == want_incr, "resp%d ZINCRBY %s: got %q want %q", resp, dc.text, incr, want_incr)
			via_add := call(&s, "zadd", "zz", "incr", dc.text, "n")
			testing.expectf(t, via_add == want_incr, "resp%d ZADD INCR %s: got %q want %q", resp, dc.text, via_add, want_incr)
		}
		close_session(&s)
	}
}

Layout_Case :: struct {
	value: f64,
	text:  string,
}

layout_cases := [?]Layout_Case {
	{0, "0"},
	{-0.0, "-0"},
	{1, "1"},
	{-1.5, "-1.5"},
	{1e15, "1000000000000000"},
	{1e18, "1000000000000000000"},
	{9223372036854774784, "9223372036854775000"},
	{-9223372036854774784, "-9223372036854775000"},
	{9223372036854775808, "9223372036854776000"},
	{-9223372036854775808, "-9223372036854776000"},
	{18446744073709551616, "18446744073709552000"},
	{1e19, "1e+19"},
	{1e20, "1e+20"},
	{1e23, "99999999999999990000000"},
	{1.2345678901234567e23, "123456789012345670000000"},
	{1.2345678901234568e24, "1.2345678901234568e+24"},
	{1.5e22, "1.5e+22"},
	{0.5, "0.5"},
	{0.001, "0.001"},
	{0.000123, "0.000123"},
	{0.0000123, "1.23e-5"},
	{0.0001234, "1.234e-4"},
	{0.0012345678901234567, "0.0012345678901234567"},
	{0.00012345678901234567, "1.2345678901234567e-4"},
	{1234.5678901234567, "1234.5678901234567"},
	{12345.678901234567, "1.2345678901234567e+4"},
	{1125899906842624.5, "1125899906842624.5"},
	{5e-324, "5e-324"},
	{1e-323, "1e-323"},
	{2.2250738585072014e-308, "2.2250738585072014e-308"},
	{1.7976931348623157e308, "1.7976931348623157e+308"},
	{-1.7976931348623157e308, "-1.7976931348623157e+308"},
	{1091036846056886.25, "1091036846056886.2"},
	{32729196762592e6, "32729196762592002000"},
	{311647958776e8, "31164795877600002000"},
}

@(test)
format_double_layout_thresholds :: proc(t: ^testing.T) {
	for lc in layout_cases {
		buf: [fc.DOUBLE_STR_MAX]u8
		n := fc.format_double(buf[:], lc.value)
		testing.expectf(t, string(buf[:n]) == lc.text, "%v: got %q want %q", lc.value, string(buf[:n]), lc.text)
	}
	inf := transmute(f64)u64(0x7FF0_0000_0000_0000)
	buf: [fc.DOUBLE_STR_MAX]u8
	n := fc.format_double(buf[:], inf)
	testing.expect_value(t, string(buf[:n]), "inf")
	n = fc.format_double(buf[:], -inf)
	testing.expect_value(t, string(buf[:n]), "-inf")
}

reference_digit_cases := [?]Layout_Case {
	{0.001298, "0.0012979999999999999"},
	{1e23, "99999999999999990000000"},
	{21902787442141.9375, "21902787442141.937"},
	{71196096364590.875, "71196096364590.87"},
}

@(test)
format_double_matches_reference_grisu_digits :: proc(t: ^testing.T) {
	context.allocator = heap()
	for rc in reference_digit_cases {
		buf: [fc.DOUBLE_STR_MAX]u8
		n := fc.format_double(buf[:], rc.value)
		testing.expectf(t, string(buf[:n]) == rc.text, "%v: got %q want %q", rc.value, string(buf[:n]), rc.text)
	}
	for resp in ([?]u8{2, 3}) {
		s := open_session(resp, false)
		for text, i in ([?]string{"0.001298", "1e23"}) {
			call(&s, "del", "z")
			call(&s, "zadd", "z", text, "m")
			got := call(&s, "zscore", "z", "m")
			want := encode_score(reference_digit_cases[i].text, resp)
			testing.expectf(t, got == want, "resp%d ZSCORE after ZADD %s: got %q want %q", resp, text, got, want)
		}
		close_session(&s)
	}
}

Bound_Case :: struct {
	text:  string,
	reply: string,
}

integer_bound_cases := [?]Bound_Case {
	{"4611686018427386880", "4611686018427386880"},
	{"4611686018427387392", "4611686018427387392"},
	{"4611686018427387903", "4611686018427387904"},
	{"4611686018427387904", "4611686018427387904"},
	{"4611686018427388928", "4611686018427389000"},
	{"4611686018427389952", "4611686018427390000"},
	{"4611686018427391999", "4611686018427392000"},
	{"-4611686018427386880", "-4611686018427386880"},
	{"-4611686018427387904", "-4611686018427387904"},
	{"-4611686018427388928", "-4611686018427389000"},
	{"2305843009213693952", "2305843009213693952"},
	{"2305843009213693953", "2305843009213693952"},
	{"9007199254740993", "9007199254740992"},
	{"1152921504606846976", "1152921504606846976"},
	{"1152921504606846977", "1152921504606846976"},
	{"4611686018427387904.5", "4611686018427387904"},
	{"4.611686018427388e18", "4611686018427387904"},
	{"3e18", "3000000000000000000"},
	{"4e18", "4000000000000000000"},
	{"5e18", "5e+18"},
	{"4611686018427000000", "4611686018426999808"},
	{"4611686018427387000", "4611686018427386880"},
	{"9223372036854775807", "9223372036854776000"},
	{"9223372036854775808", "9223372036854776000"},
	{"-9223372036854775808", "-9223372036854776000"},
	{"18446744073709551616", "18446744073709552000"},
	{"1e19", "1e+19"},
	{"1e20", "1e+20"},
}

@(test)
format_double_exact_integers_stop_at_two_pow_62 :: proc(t: ^testing.T) {
	context.allocator = heap()
	for bc in integer_bound_cases {
		v, ok := strconv.parse_f64(bc.text)
		testing.expectf(t, ok, "cannot parse %s", bc.text)
		buf: [fc.DOUBLE_STR_MAX]u8
		n := fc.format_double(buf[:], v)
		testing.expectf(t, string(buf[:n]) == bc.reply, "%s: got %q want %q", bc.text, string(buf[:n]), bc.reply)
	}
	for resp in ([?]u8{2, 3}) {
		s := open_session(resp, false)
		for bc in integer_bound_cases {
			call(&s, "del", "z", "zi")
			added := call(&s, "zadd", "z", bc.text, "m")
			testing.expectf(t, added == ":1\r\n", "resp%d ZADD %s: got %q", resp, bc.text, added)
			want := encode_score(bc.reply, resp)
			score := call(&s, "zscore", "z", "m")
			testing.expectf(t, score == want, "resp%d ZSCORE after ZADD %s: got %q want %q", resp, bc.text, score, want)
			incr := call(&s, "zincrby", "zi", bc.text, "m")
			testing.expectf(t, incr == want, "resp%d ZINCRBY %s: got %q want %q", resp, bc.text, incr, want)
		}
		close_session(&s)
	}
}

next_random :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	state^ = x
	return x
}

@(test)
format_double_round_trips :: proc(t: ^testing.T) {
	context.allocator = heap()
	state: u64 = 0x9E37_79B9_7F4A_7C15
	failures := 0
	for _ in 0 ..< 200_000 {
		bits := next_random(&state)
		if bits & 0x7FF0_0000_0000_0000 == 0x7FF0_0000_0000_0000 {
			continue
		}
		v := transmute(f64)bits
		buf: [fc.DOUBLE_STR_MAX]u8
		n := fc.format_double(buf[:], v)
		back, ok := strconv.parse_f64(string(buf[:n]))
		if !ok || transmute(u64)back != bits || n > 25 {
			failures += 1
			if failures < 10 {
				testing.expectf(t, false, "bits %x formatted %q did not round trip", bits, string(buf[:n]))
			}
		}
	}
	text_buf: [80]u8
	for _ in 0 ..< 100_000 {
		mantissa := i64(next_random(&state) % 1_000_000_000_000_000) + 1
		exponent := i64(next_random(&state) % 61) - 30
		digits := strconv.write_int(text_buf[:], mantissa, 10)
		source := strings.concatenate({digits, "e", strconv.write_int(text_buf[32:], exponent, 10)})
		v, _ := strconv.parse_f64(source)
		buf: [fc.DOUBLE_STR_MAX]u8
		n := fc.format_double(buf[:], v)
		out := string(buf[:n])
		back, _ := strconv.parse_f64(out)
		exact := v <= 4611686018427387904.0 && f64(i64(v)) == v
		if back != v || (exact && out != strconv.write_int(text_buf[48:], i64(v), 10)) {
			failures += 1
			if failures < 10 {
				testing.expectf(t, false, "%s formatted as %q does not round trip or is not the exact integer", source, out)
			}
		}
	}
	testing.expect_value(t, failures, 0)
}

Resp_Node :: struct {
	kind:  u8,
	value: i64,
	text:  string,
	items: [dynamic]Resp_Node,
}

parse_resp :: proc(data: string, at: ^int) -> Resp_Node {
	node := Resp_Node {
		kind = data[at^],
	}
	switch node.kind {
	case ':':
		node.value = read_number(data, at)
	case '$':
		size := int(read_number(data, at))
		node.text = data[at^:at^ + size]
		at^ += size + 2
	case '*', '%':
		count := int(read_number(data, at))
		if node.kind == '%' {
			count *= 2
		}
		for _ in 0 ..< count {
			append(&node.items, parse_resp(data, at))
		}
	case:
		end := strings.index(data[at^:], "\r\n")
		node.text = data[at^ + 1:at^ + end]
		at^ += end + 2
	}
	return node
}

model_lcs_length :: proc(a, b: []u8) -> int {
	prev := make([]int, len(b) + 1)
	cur := make([]int, len(b) + 1)
	defer delete(prev)
	defer delete(cur)
	for i in 1 ..= len(a) {
		for k in 1 ..= len(b) {
			if a[i - 1] == b[k - 1] {
				cur[k] = prev[k - 1] + 1
			} else {
				cur[k] = max(prev[k], cur[k - 1])
			}
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

is_subsequence :: proc(small, big: string) -> bool {
	k := 0
	for i in 0 ..< len(big) {
		if k < len(small) && big[i] == small[k] {
			k += 1
		}
	}
	return k == len(small)
}

@(test)
lcs_agrees_with_an_independent_model :: proc(t: ^testing.T) {
	context.allocator = heap()
	state: u64 = 0x0123_4567_89AB_CDEF
	for resp in ([?]u8{2, 3}) {
		s := open_session(resp, false)
		for round in 0 ..< 60 {
			la := int(next_random(&state) % 400)
			lb := int(next_random(&state) % 400)
			spread := u64(1 + round % 6)
			a := make([]u8, la)
			b := make([]u8, lb)
			for i in 0 ..< la {
				a[i] = u8('a' + next_random(&state) % spread)
			}
			for i in 0 ..< lb {
				b[i] = u8('a' + next_random(&state) % spread)
			}
			call_argv(&s, {bytes_of("set"), bytes_of("ka"), a})
			call_argv(&s, {bytes_of("set"), bytes_of("kb"), b})
			want := model_lcs_length(a, b)
			length, _ := int_reply(call(&s, "lcs", "ka", "kb", "len"))
			testing.expectf(t, length == i64(want), "round %d: LEN %d want %d", round, length, want)
			text_reply := call(&s, "lcs", "ka", "kb")
			at := 0
			text := parse_resp(text_reply, &at).text
			testing.expectf(t, len(text) == want && is_subsequence(text, string(a)) && is_subsequence(text, string(b)), "round %d: LCS string %q is not a common subsequence of length %d", round, text, want)
			idx_reply := call(&s, "lcs", "ka", "kb", "idx", "withmatchlen")
			at = 0
			root := parse_resp(idx_reply, &at)
			testing.expectf(t, at == len(idx_reply) && len(root.items) == 4, "round %d: IDX reply shape %q", round, idx_reply)
			if len(root.items) != 4 {
				continue
			}
			testing.expect_value(t, root.items[0].text, "matches")
			testing.expect_value(t, root.items[2].text, "len")
			testing.expect_value(t, root.items[3].value, i64(want))
			total := 0
			last_a := la
			last_b := lb
			for m in root.items[1].items {
				a_from := int(m.items[0].items[0].value)
				a_to := int(m.items[0].items[1].value)
				b_from := int(m.items[1].items[0].value)
				b_to := int(m.items[1].items[1].value)
				size := int(m.items[2].value)
				ok := a_to - a_from + 1 == size && b_to - b_from + 1 == size && a_to < last_a && b_to < last_b
				ok = ok && string(a[a_from:a_to + 1]) == string(b[b_from:b_to + 1])
				testing.expectf(t, ok, "round %d: bad range a[%d..%d] b[%d..%d] len %d", round, a_from, a_to, b_from, b_to, size)
				total += size
				last_a = a_from
				last_b = b_from
			}
			testing.expectf(t, total == want, "round %d: ranges cover %d of %d", round, total, want)
			delete(a)
			delete(b)
		}
		close_session(&s)
	}
}

pinned_stat_settings := [?][2]string {
	{"latency-tracking", "no"},
	{"slowlog-log-slower-than", "-1"},
	{"latency-monitor-threshold", "0"},
}

config_value :: proc(s: ^Session, name: string) -> string {
	reply := call(s, "config", "get", name)
	at := 0
	node := parse_resp(reply, &at)
	if len(node.items) != 2 {
		return ""
	}
	return node.items[1].text
}

@(test)
hot_commands_allocate_nothing_through_the_context :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2, false)
	defer close_session(&s)
	saved: [len(pinned_stat_settings)]string
	for setting, i in pinned_stat_settings {
		saved[i] = config_value(&s, setting[0])
		testing.expect_value(t, call(&s, "config", "set", setting[0], setting[1]), "+OK\r\n")
	}
	defer for setting, i in pinned_stat_settings {
		call(&s, "config", "set", setting[0], saved[i])
	}
	slab := make([]u8, 16 << 20)
	defer delete(slab)
	set_argv := [][]u8{bytes_of("set"), bytes_of("hot"), bytes_of("value")}
	get_argv := [][]u8{bytes_of("get"), bytes_of("hot")}
	incr_argv := [][]u8{bytes_of("incr"), bytes_of("counter")}
	append_argv := [][]u8{bytes_of("append"), bytes_of("log"), bytes_of("entry")}
	slow_argv := [][]u8{bytes_of("append"), bytes_of("bulk"), slab}
	for _ in 0 ..< 4 {
		call_argv(&s, set_argv)
		call_argv(&s, get_argv)
		call_argv(&s, incr_argv)
		call_argv(&s, append_argv)
	}
	call_argv(&s, slow_argv)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, heap(), heap())
	defer mem.tracking_allocator_destroy(&track)
	c := s.conn
	{
		context.allocator = mem.tracking_allocator(&track)
		for round in 0 ..< 200 {
			for argv in ([?][][]u8{set_argv, get_argv, incr_argv, append_argv}) {
				c.wlen = 0
				j.db_cur = c.db
				j.execute(c, argv)
			}
			if round % 100 == 0 {
				c.wlen = 0
				j.db_cur = c.db
				j.execute(c, slow_argv)
			}
		}
	}
	testing.expectf(t, track.total_allocation_count == 0, "hot commands made %d context allocations", track.total_allocation_count)
	testing.expect_value(t, call(&s, "get", "counter"), "$3\r\n204\r\n")
	testing.expect_value(t, call(&s, "strlen", "bulk"), ":50331648\r\n")
}

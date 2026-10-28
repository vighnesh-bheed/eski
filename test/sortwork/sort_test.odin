package sortwork

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

@(private)
bulk_note :: proc(s: string) -> string {
	return render(Node{kind = .Bulk, text = s})
}

@(private)
array_note :: proc(items: []string) -> string {
	parts := make([dynamic]string, 0, len(items), context.temp_allocator)
	for x in items {
		append(&parts, bulk_note(x))
	}
	return strings.concatenate({"[", strings.join(parts[:], ", ", context.temp_allocator), "]"}, context.temp_allocator)
}

@(test)
sort_score_texts :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	accepted := []string {
		"",
		" 2",
		"\t3",
		"\n4",
		"\v5",
		"\f6",
		"\r7",
		"+1",
		"-0",
		"00",
		".5",
		"5.",
		"+.5",
		"-.5e1",
		"1e3",
		"1E3",
		"1e+3",
		"1e-3",
		"inf",
		"-inf",
		"+inf",
		"INF",
		"Infinity",
		"-INFINITY",
		"1\x00junk",
		"\x00",
		"\x00abc",
		" 2\x00 ",
		"4.9e-300",
		"1.7976931348623157e308",
		"0e999999",
		"0.000",
		"123456789012345678901234567890",
		"2.2250738585072014e-308",
		"12345678901234567890",
		"9007199254740993",
		"0x10",
		"0X1A",
		"0x1p3",
		"-0x1A",
		" 0x1a",
		"0x.8",
		"0x1.",
		"0x1P-3",
		"0x1p+3",
		"0x0",
		"0x0p99999",
		"0x00000000000000000000001",
		"0xFFFFFFFFFFFFFFFFFFFF",
		"0x1p1023",
		"0x1.fffffffffffffp1023",
		"0x1p-1022",
		"0x1A\x00tail",
	}
	rejected := []string {
		"2 ",
		"2 \x00",
		"abc",
		"nan",
		"-nan",
		"NaN",
		"1,5",
		"1e",
		"1e+",
		"1e-",
		".",
		"+",
		"-",
		" ",
		"\t",
		"\x01",
		"1e400",
		"-1e400",
		"1e-400",
		"4e-320",
		"infx",
		"infinit",
		"infinityy",
		"in",
		"1_000",
		"--1",
		"+-1",
		"1.2.3",
		"e5",
		"\xc2\xa01",
		"0x",
		"0x.",
		"0xg",
		"0x1g",
		"0x1p",
		"0x1p+",
		"0x1p1024",
		"0x1.fffffffffffff8p1023",
		"0x1p-1023",
		"0x1p-1080",
		"0x 1",
		"0x1 ",
		"0x1.2.3",
		"0x_1",
		"4.9e-324",
	}
	for text in accepted {
		call(&s, "DEL", "k")
		call(&s, "RPUSH", "k", text)
		expect_reply(t, &s, array_note({text}), "SORT", "k")
	}
	for text in rejected {
		call(&s, "DEL", "k")
		call(&s, "RPUSH", "k", text)
		expect_reply(t, &s, "-ERR One or more scores can't be converted into double", "SORT", "k")
		expect_reply(t, &s, array_note({text}), "SORT", "k", "ALPHA")
		expect_reply(t, &s, array_note({text}), "SORT", "k", "BY", "nosort")
	}
	call(&s, "DEL", "k")
	call(&s, "RPUSH", "k", "1e3", " 2", "-inf", "inf", ".5", "5.", "-0", "\x00", "", "1\x00junk")
	expect_reply(t, &s, array_note({"-inf", "", "\x00", "-0", ".5", "1\x00junk", " 2", "5.", "1e3", "inf"}), "SORT", "k")
	expect_reply(t, &s, array_note({"inf", "1e3", "5.", " 2", "1\x00junk", ".5", "-0", "\x00", "", "-inf"}), "SORT", "k", "DESC")
	call(&s, "DEL", "k")
	call(&s, "RPUSH", "k", "0x1A", "25", "0x1.8p1", "3", "0x1.00000000000008p0", "1", "0x1.00000000000008000001p0", "1.0000000000000002", "0x1.fffffffffffff7ffp0", "0x2p0")
	expect_reply(t, &s, `["0x1.00000000000008p0", "1", "0x1.00000000000008000001p0", "1.0000000000000002", "0x1.fffffffffffff7ffp0", "0x2p0", "0x1.8p1", "3", "25", "0x1A"]`, "SORT", "k")
	call(&s, "RPUSH", "k", "nan")
	expect_reply(t, &s, "-ERR One or more scores can't be converted into double", "SORT", "k", "LIMIT", "0", "0")
	expect_reply(t, &s, "-ERR One or more scores can't be converted into double", "SORT", "k", "STORE", "dst")
	expect_reply(t, &s, ":0", "EXISTS", "dst")
}

@(test)
sort_alpha_text_rules :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "RPUSH", "b", "a\x00b", "a\x00a", "a", "a\x00", "\xff", "\x00", "B")
	expect_reply(t, &s, array_note({"\x00", "B", "a\x00b", "a\x00a", "a", "a\x00", "\xff"}), "SORT", "b", "ALPHA")
	expect_reply(t, &s, array_note({"\xff", "a\x00b", "a\x00a", "a", "a\x00", "B", "\x00"}), "SORT", "b", "ALPHA", "DESC")
	expect_reply(t, &s, array_note({"a\x00b", "a\x00a"}), "SORT", "b", "ALPHA", "LIMIT", "2", "2")
	expect_reply(t, &s, ":7", "SORT", "b", "ALPHA", "STORE", "o")
	expect_reply(t, &s, array_note({"\x00", "B", "a", "a\x00", "a\x00a", "a\x00b", "\xff"}), "LRANGE", "o", "0", "-1")
	expect_reply(t, &s, ":7", "SORT", "b", "ALPHA", "DESC", "STORE", "o")
	expect_reply(t, &s, array_note({"\xff", "a\x00b", "a\x00a", "a\x00", "a", "B", "\x00"}), "LRANGE", "o", "0", "-1")
	call(&s, "RPUSH", "e", "x", "y", "z", "q")
	call(&s, "MSET", "w_x", "k\x00b", "w_y", "k\x00a", "w_z", "k")
	expect_reply(t, &s, `["q", "x", "y", "z"]`, "SORT", "e", "BY", "w_*", "ALPHA")
	expect_reply(t, &s, `["x", "y", "z", "q"]`, "SORT", "e", "BY", "w_*", "ALPHA", "DESC")
	expect_reply(t, &s, ":4", "SORT", "e", "BY", "w_*", "ALPHA", "STORE", "o")
	expect_reply(t, &s, `["q", "z", "y", "x"]`, "LRANGE", "o", "0", "-1")
	expect_reply(t, &s, ":4", "SORT", "e", "BY", "w_*", "ALPHA", "DESC", "STORE", "o")
	expect_reply(t, &s, `["x", "y", "z", "q"]`, "LRANGE", "o", "0", "-1")
	call(&s, "SADD", "st", "b", "a\x00", "a", "c")
	expect_reply(t, &s, ":4", "SORT", "st", "BY", "nosort", "STORE", "o")
	expect_reply(t, &s, array_note({"a", "a\x00", "b", "c"}), "LRANGE", "o", "0", "-1")
	expect_reply(t, &s, ":2", "SORT", "st", "BY", "nosort", "DESC", "LIMIT", "1", "2", "STORE", "o")
	expect_reply(t, &s, array_note({"b", "a\x00"}), "LRANGE", "o", "0", "-1")
}

@(private)
Tie_Row :: struct {
	member:  string,
	pos:     int,
	present: bool,
	weight:  string,
	score:   f64,
}

@(private)
c_view :: proc(s: string) -> string {
	if i := strings.index_byte(s, 0); i >= 0 {
		return s[:i]
	}
	return s
}

@(private)
tie_rows :: proc(s: ^Session, n: int, numeric: bool) -> []Tie_Row {
	call(s, "FLUSHALL")
	rows := make([]Tie_Row, n, context.temp_allocator)
	alpha_classes := []string{"", "b", "a\x00z", "a", "b", "c"}
	numeric_classes := []string{"", "2", "1.0", "1", "-1", " 3"}
	numeric_scores := []f64{0, 2, 1, 1, -1, 3}
	for i in 0 ..< n {
		member := fmt.tprintf("m%03d", (i * 37) % n)
		class := i % 6
		rows[i] = Tie_Row{member = member, pos = i, present = class != 0}
		call(s, "RPUSH", "l", member)
		if class != 0 {
			value := numeric_classes[class] if numeric else alpha_classes[class]
			rows[i].weight = value
			rows[i].score = numeric_scores[class]
			call(s, "SET", strings.concatenate({"w_", member}, context.temp_allocator), value)
			call(s, "HSET", strings.concatenate({"h_", member}, context.temp_allocator), "f", value)
		}
	}
	return rows
}

@(private)
alpha_ascending :: proc(a: Tie_Row, b: Tie_Row) -> bool {
	if a.present != b.present {
		return !a.present
	}
	return a.present && a.weight < b.weight
}

@(private)
alpha_descending :: proc(a: Tie_Row, b: Tie_Row) -> bool {
	return alpha_ascending(b, a)
}

@(private)
members_of :: proc(rows: []Tie_Row) -> []string {
	out := make([]string, len(rows), context.temp_allocator)
	for r, i in rows {
		out[i] = r.member
	}
	return out
}

@(private)
window :: proc(items: []string, offset: int, count: int) -> []string {
	start := max(offset, 0)
	if count == 0 || start >= len(items) {
		return nil
	}
	end := len(items) if count < 0 else min(len(items), start + count)
	return items[start:end]
}

@(test)
sort_alpha_ties_keep_input_order :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	for n in ([]int{7, 40, 301}) {
		rows := tie_rows(&s, n, false)
		for whole in ([]bool{false, true}) {
			for desc in ([]bool{false, true}) {
				ordered := slice.clone(rows, context.temp_allocator)
				if !whole {
					for &r in ordered {
						r.weight = c_view(r.weight)
					}
				}
				slice.stable_sort_by(ordered, alpha_descending if desc else alpha_ascending)
				expected := members_of(ordered)
				direction := "DESC" if desc else "ASC"
				for pattern in ([]string{"w_*", "h_*->f"}) {
					if whole {
						for limit in ([][2]int{{0, -1}, {0, 3}, {2, 5}, {n / 2, 7}, {1, -1}, {n - 3, 10}}) {
							call(&s, "SORT", "l", "BY", pattern, "ALPHA", direction, "LIMIT", itoa(limit[0]), itoa(limit[1]), "STORE", "dst")
							expect_reply(t, &s, array_note(window(expected, limit[0], limit[1])), "LRANGE", "dst", "0", "-1")
						}
						continue
					}
					expect_reply(t, &s, array_note(expected), "SORT", "l", "BY", pattern, "ALPHA", direction)
					for limit in ([][2]int{{0, 3}, {2, 5}, {n / 2, 7}, {1, -1}, {-2, 4}, {n - 3, 10}, {n + 1, 3}, {0, 0}}) {
						expect_reply(t, &s, array_note(window(expected, limit[0], limit[1])), "SORT", "l", "BY", pattern, "ALPHA", direction, "LIMIT", itoa(limit[0]), itoa(limit[1]))
						expect_reply(t, &s, array_note(window(expected, limit[0], limit[1])), "SORT_RO", "l", "BY", pattern, "ALPHA", direction, "LIMIT", itoa(limit[0]), itoa(limit[1]))
					}
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

@(test)
sort_numeric_ties_use_element_bytes :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	for n in ([]int{7, 40, 301}) {
		rows := tie_rows(&s, n, true)
		ordered := slice.clone(rows, context.temp_allocator)
		slice.sort_by(ordered, proc(a, b: Tie_Row) -> bool {
			if a.score != b.score {
				return a.score < b.score
			}
			return a.member < b.member
		})
		ascending := members_of(ordered)
		descending := slice.clone(ascending, context.temp_allocator)
		slice.reverse(descending)
		for pattern in ([]string{"w_*", "h_*->f"}) {
			expect_reply(t, &s, array_note(ascending), "SORT", "l", "BY", pattern)
			expect_reply(t, &s, array_note(descending), "SORT", "l", "BY", pattern, "DESC")
			for limit in ([][2]int{{0, 3}, {2, 5}, {n / 2, 7}, {1, -1}, {n - 3, 10}}) {
				expect_reply(t, &s, array_note(window(ascending, limit[0], limit[1])), "SORT", "l", "BY", pattern, "LIMIT", itoa(limit[0]), itoa(limit[1]))
				expect_reply(t, &s, array_note(window(descending, limit[0], limit[1])), "SORT", "l", "BY", pattern, "DESC", "LIMIT", itoa(limit[0]), itoa(limit[1]))
			}
		}
		free_all(context.temp_allocator)
	}
}

@(test)
sort_limit_edges :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "RPUSH", "l", "5", "3", "1", "4", "2")
	call(&s, "ZADD", "z", "1", "a", "2", "b", "3", "c", "4", "d", "5", "e")
	call(&s, "SADD", "st", "1", "2", "3", "4", "5")
	expect_reply(t, &s, `["3", "4", "5"]`, "SORT", "l", "LIMIT", "2", "9223372036854775807")
	expect_reply(t, &s, `[]`, "SORT", "l", "LIMIT", "9223372036854775807", "9223372036854775807")
	expect_reply(t, &s, `["1"]`, "SORT", "l", "LIMIT", "-9223372036854775808", "1")
	expect_reply(t, &s, `["5"]`, "SORT", "l", "LIMIT", "4", "1")
	expect_reply(t, &s, `[]`, "SORT", "l", "LIMIT", "5", "1")
	expect_reply(t, &s, `["4", "5"]`, "SORT", "l", "LIMIT", "3", "-7")
	expect_reply(t, &s, `["1", "2", "3", "4", "5"]`, "SORT", "l", "LIMIT", "-9223372036854775808", "-9223372036854775808")
	expect_reply(t, &s, `["2", "1"]`, "SORT", "l", "LIMIT", "3", "9223372036854775807", "DESC")
	expect_reply(t, &s, `["1", "4", "2"]`, "SORT", "l", "BY", "nosort", "LIMIT", "2", "9223372036854775807")
	expect_reply(t, &s, `["4", "1", "3"]`, "SORT", "l", "BY", "nosort", "DESC", "LIMIT", "1", "3")
	expect_reply(t, &s, `[]`, "SORT", "l", "BY", "nosort", "LIMIT", "0", "0")
	expect_reply(t, &s, `[]`, "SORT", "l", "BY", "nosort", "LIMIT", "9", "1")
	expect_reply(t, &s, `["c", "d", "e"]`, "SORT", "z", "BY", "nosort", "LIMIT", "2", "9223372036854775807")
	expect_reply(t, &s, `["d", "c"]`, "SORT", "z", "BY", "nosort", "DESC", "LIMIT", "1", "2")
	expect_reply(t, &s, `[]`, "SORT", "z", "BY", "nosort", "LIMIT", "5", "2")
	expect_reply(t, &s, `["2", "3"]`, "SORT", "st", "BY", "nosort", "LIMIT", "1", "2")
	expect_reply(t, &s, `["2", "3"]`, "SORT", "st", "BY", "nosort", "DESC", "LIMIT", "1", "2")
	expect_reply(t, &s, ":2", "SORT", "st", "BY", "nosort", "DESC", "LIMIT", "1", "2", "STORE", "o")
	expect_reply(t, &s, `["4", "3"]`, "LRANGE", "o", "0", "-1")
	expect_reply(t, &s, ":0", "SORT", "st", "BY", "nosort", "LIMIT", "5", "2", "STORE", "o")
	expect_reply(t, &s, ":0", "EXISTS", "o")
}

@(test)
sort_pattern_shapes :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "RPUSH", "p", "a", "b")
	call(&s, "SET", "k_a", "1")
	call(&s, "SET", "k_b", "12345")
	call(&s, "HSET", "h_a", "f", "2", "f->g", "3", "f*", "6")
	call(&s, "HSET", "h_b", "f", "700")
	call(&s, "SET", "h_a->", "4")
	call(&s, "SET", "a->a", "5")
	call(&s, "SET", "a", "7")
	expect_reply(t, &s, `["1", "12345"]`, "SORT", "p", "BY", "nosort", "GET", "k_*")
	expect_reply(t, &s, `["2", "700"]`, "SORT", "p", "BY", "nosort", "GET", "h_*->f")
	expect_reply(t, &s, `["3", nil]`, "SORT", "p", "BY", "nosort", "GET", "h_*->f->g")
	expect_reply(t, &s, `["4", nil]`, "SORT", "p", "BY", "nosort", "GET", "h_*->")
	expect_reply(t, &s, `["5", nil]`, "SORT", "p", "BY", "nosort", "GET", "a->*")
	expect_reply(t, &s, `["6", nil]`, "SORT", "p", "BY", "nosort", "GET", "h_*->f*")
	expect_reply(t, &s, `["7", nil]`, "SORT", "p", "BY", "nosort", "GET", "*")
	expect_reply(t, &s, `[nil, nil]`, "SORT", "p", "BY", "nosort", "GET", "k_a")
	expect_reply(t, &s, `[nil, nil]`, "SORT", "p", "BY", "nosort", "GET", "h_a->f")
	expect_reply(t, &s, `["a", "b"]`, "SORT", "p", "BY", "nosort", "GET", "#")
	expect_reply(t, &s, `[nil, nil]`, "SORT", "p", "BY", "nosort", "GET", "##")
	expect_reply(t, &s, `[nil, nil]`, "SORT", "p", "BY", "nosort", "GET", "h_*")
	expect_reply(t, &s, `[nil, nil]`, "SORT", "p", "BY", "nosort", "GET", "k_*->f")
	expect_reply(t, &s, `["a", "1", "2", "b", "12345", "700"]`, "SORT", "p", "BY", "nosort", "GET", "#", "GET", "k_*", "GET", "h_*->f")
	expect_reply(t, &s, `["b", "a"]`, "SORT", "p", "BY", "k_*", "DESC")
	expect_reply(t, &s, `["b", "a"]`, "SORT", "p", "BY", "h_*->f", "DESC")
	expect_reply(t, &s, `["b", "a"]`, "SORT", "p", "BY", "h_*->f", "ALPHA", "DESC")
	expect_reply(t, &s, `["a", "b"]`, "SORT", "p", "BY", "h_*->f", "ALPHA")
	expect_reply(t, &s, `["b", "a"]`, "SORT", "p", "BY", "#", "DESC")
	expect_reply(t, &s, `["b", "a"]`, "SORT", "p", "BY", "k_a", "DESC")
	expect_reply(t, &s, `["a", "b"]`, "SORT", "p", "BY", "k_*", "BY", "nosort")
	call(&s, "SADD", "w_a", "x")
	call(&s, "LPUSH", "w_b", "x")
	expect_reply(t, &s, `["a", "b"]`, "SORT", "p", "BY", "w_*")
	expect_reply(t, &s, `["b", "a"]`, "SORT", "p", "BY", "w_*", "DESC")
	expect_reply(t, &s, `[nil, nil]`, "SORT", "p", "BY", "nosort", "GET", "w_*")
	large := strings.repeat("v", 70000, context.temp_allocator)
	call(&s, "RPUSH", "q", "c", "d")
	call(&s, "SET", "k_c", large)
	call(&s, "HSET", "h_d", "f", large)
	expect_reply(t, &s, strings.concatenate({"[", bulk_note(large), ", nil, nil, ", bulk_note(large), "]"}, context.temp_allocator), "SORT", "q", "BY", "nosort", "GET", "k_*", "GET", "h_*->f")
	expect_reply(t, &s, ":4", "SORT", "q", "BY", "nosort", "GET", "k_*", "GET", "h_*->f", "STORE", "o")
	expect_reply(t, &s, array_note({large, "", "", large}), "LRANGE", "o", "0", "-1")
	call(&s, "SET", "k_d", strings.concatenate({large, "w"}, context.temp_allocator))
	expect_reply(t, &s, `["c", "d"]`, "SORT", "q", "BY", "k_*", "ALPHA")
	expect_reply(t, &s, `["d", "c"]`, "SORT", "q", "BY", "k_*", "ALPHA", "DESC")
}

@(test)
sort_hash_field_expiry_through_get :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2, "KEA")
	defer close_session(&s)
	call(&s, "RPUSH", "p", "a", "b")
	call(&s, "HSET", "h_a", "f", "1", "g", "2")
	call(&s, "HSET", "h_b", "f", "3")
	call(&s, "HPEXPIRE", "h_a", "1", "FIELDS", "1", "f")
	call(&s, "HPEXPIRE", "h_b", "1", "FIELDS", "1", "f")
	take_events(&s)
	pause(30)
	expect_reply(t, &s, `["a", nil, "2", "b", nil, nil]`, "SORT", "p", "BY", "nosort", "GET", "#", "GET", "h_*->f", "GET", "h_*->g")
	expect_events(t, &s, "__keyspace@0__:h_a hexpired | __keyevent@0__:hexpired h_a | __keyspace@0__:h_b hexpired | __keyevent@0__:hexpired h_b | __keyspace@0__:h_b del | __keyevent@0__:del h_b")
	expect_reply(t, &s, ":0", "EXISTS", "h_b")
}

@(test)
sort_store_details :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2, "KEA")
	defer close_session(&s)
	call(&s, "RPUSH", "l", "3", "1", "2")
	call(&s, "SET", "dst", "v", "PX", "1")
	take_events(&s)
	pause(20)
	expect_reply(t, &s, ":0", "SORT", "missing", "STORE", "dst")
	expect_events(t, &s, "__keyspace@0__:dst del | __keyevent@0__:del dst")
	expect_reply(t, &s, ":0", "EXISTS", "dst")
	call(&s, "SET", "out3", "v", "PX", "1")
	take_events(&s)
	pause(20)
	expect_reply(t, &s, ":3", "SORT", "l", "STORE", "out3")
	expect_events(t, &s, "__keyspace@0__:out3 expired | __keyevent@0__:expired out3 | __keyspace@0__:out3 sortstore | __keyevent@0__:sortstore out3")
	expect_reply(t, &s, ":-1", "PTTL", "out3")
	expect_reply(t, &s, ":0", "SORT", "missing", "STORE", "dst")
	expect_events(t, &s, "")
	other := peer(&s)
	expect_reply_on(t, other, "+OK", "WATCH", "dst")
	expect_reply(t, &s, ":3", "SORT", "l", "STORE", "dst")
	expect_events(t, &s, "__keyspace@0__:dst sortstore | __keyevent@0__:sortstore dst")
	expect_reply_on(t, other, "+OK", "MULTI")
	expect_reply_on(t, other, "+QUEUED", "GET", "x")
	expect_reply_on(t, other, "nil", "EXEC")
	call(&s, "CONFIG", "SET", "notify-keyspace-events", "Kl")
	expect_reply(t, &s, ":3", "SORT", "l", "STORE", "dst")
	expect_events(t, &s, "__keyspace@0__:dst sortstore")
	expect_reply(t, &s, ":0", "SORT", "missing", "STORE", "dst")
	expect_events(t, &s, "")
	call(&s, "CONFIG", "SET", "notify-keyspace-events", "Kg")
	expect_reply(t, &s, ":3", "SORT", "l", "STORE", "dst")
	expect_events(t, &s, "")
	expect_reply(t, &s, ":0", "SORT", "missing", "STORE", "dst")
	expect_events(t, &s, "__keyspace@0__:dst del")
	call(&s, "CONFIG", "SET", "notify-keyspace-events", "KEA")
	big := make([dynamic]string, 0, 210, context.temp_allocator)
	append(&big, "RPUSH", "wide")
	for i in 0 ..< 200 {
		append(&big, fmt.tprintf("%03d%s", i, strings.repeat("x", 97, context.temp_allocator)))
	}
	call(&s, ..big[:])
	take_events(&s)
	expect_reply(t, &s, ":200", "SORT", "wide", "ALPHA", "DESC", "STORE", "wout")
	expect_reply(t, &s, `"quicklist"`, "OBJECT", "ENCODING", "wout")
	expect_reply(t, &s, ":3", "SORT", "wide", "ALPHA", "LIMIT", "0", "3", "STORE", "wout")
	expect_reply(t, &s, `"listpack"`, "OBJECT", "ENCODING", "wout")
	take_events(&s)
	expect_reply(t, &s, "+OK", "SELECT", "1")
	call(&s, "RPUSH", "l1", "b", "a")
	take_events(&s)
	expect_reply(t, &s, ":2", "SORT", "l1", "ALPHA", "STORE", "o1")
	expect_events(t, &s, "__keyspace@1__:o1 sortstore | __keyevent@1__:sortstore o1")
	expect_reply(t, &s, `["a", "b"]`, "LRANGE", "o1", "0", "-1")
	expect_reply(t, &s, "+OK", "SELECT", "0")
	expect_reply(t, &s, ":0", "EXISTS", "o1")
	waiter := wire_peer(&s)
	wire_send(waiter, "BLPOP", "fresh", "0")
	testing.expect(t, wire_take(waiter) == "")
	expect_reply(t, &s, ":3", "SORT", "l", "DESC", "STORE", "fresh")
	got := reply_text(wire_take(waiter))
	testing.expectf(t, got == `["fresh", "3"]`, "blocked pop after SORT STORE: %s", got)
	expect_reply(t, &s, `["2", "1"]`, "LRANGE", "fresh", "0", "-1")
	expect_reply(t, &s, "+OK", "MULTI")
	expect_reply(t, &s, "+QUEUED", "SORT", "l", "STORE", "tx")
	expect_reply(t, &s, "+QUEUED", "SORT_RO", "tx", "DESC")
	expect_reply(t, &s, `[:3, ["3", "2", "1"]]`, "EXEC")
}

@(test)
sort_acl_scope :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "RPUSH", "ids", "2", "1")
	call(&s, "MSET", "w_1", "10", "w_2", "5")
	expect_reply(t, &s, "+OK", "ACL", "SETUSER", "writer", "on", "nopass", "+@all", "~ids", "%W~*")
	expect_reply(t, &s, "+OK", "ACL", "SETUSER", "both", "on", "nopass", "+@all", "~ids", "%R~*")
	expect_reply(t, &s, "+OK", "ACL", "SETUSER", "picky", "on", "nopass", "+@all", "~ids", "(+@all ~*)")
	expect_reply(t, &s, "+OK", "ACL", "SETUSER", "narrow", "on", "nopass", "+@all", "~ids", "(+get ~*)")
	expect_reply(t, &s, "+OK", "AUTH", "writer", "x")
	expect_reply(t, &s, "-ERR BY option of SORT denied due to insufficient ACL permissions.", "SORT", "ids", "BY", "w_*")
	expect_reply(t, &s, "-ERR GET option of SORT denied due to insufficient ACL permissions.", "SORT_RO", "ids", "GET", "#")
	expect_reply(t, &s, `["2", "1"]`, "SORT", "ids", "BY", "nosort")
	expect_reply(t, &s, "+OK", "AUTH", "both", "x")
	expect_reply(t, &s, `["2", "1"]`, "SORT", "ids", "BY", "w_*")
	expect_reply(t, &s, `["5", "10"]`, "SORT_RO", "ids", "BY", "w_*", "GET", "w_*")
	expect_reply(t, &s, "+OK", "AUTH", "picky", "x")
	expect_reply(t, &s, `["2", "1"]`, "SORT", "ids", "BY", "w_*")
	expect_reply(t, &s, "+OK", "AUTH", "narrow", "x")
	expect_reply(t, &s, "-ERR BY option of SORT denied due to insufficient ACL permissions.", "SORT", "ids", "BY", "w_*")
	expect_reply(t, &s, "+OK", "AUTH", "default", "x")
	expect_reply(t, &s, ":4", "ACL", "DELUSER", "writer", "both", "picky", "narrow")
	internal := peer(&s)
	saved := internal.user
	internal.user = nil
	expect_reply_on(t, internal, ":2", "SORT", "ids", "BY", "w_*", "GET", "#", "STORE", "o")
	internal.user = saved
	expect_reply(t, &s, `["2", "1"]`, "LRANGE", "o", "0", "-1")
}

@(test)
sort_large_inputs :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	n := 100_000
	args := make([dynamic]string, 0, n + 2, context.temp_allocator)
	append(&args, "RPUSH", "big")
	for i in 0 ..< n {
		append(&args, fmt.tprintf("item-%d", (i * 7919) % n))
	}
	expect_reply(t, &s, fmt.tprintf(":%d", n), ..args[:])
	start := time.now()
	expect_reply(t, &s, `["item-0", "item-1", "item-10"]`, "SORT", "big", "ALPHA", "LIMIT", "0", "3")
	expect_reply(t, &s, `["item-99999", "item-99998", "item-99997"]`, "SORT", "big", "ALPHA", "DESC", "LIMIT", "0", "3")
	got := call(&s, "SORT", "big", "ALPHA")
	testing.expect(t, strings.has_prefix(got, "*100000\r\n$6\r\nitem-0\r\n$6\r\nitem-1\r\n$7\r\nitem-10\r\n"))
	expect_reply(t, &s, fmt.tprintf(":%d", n), "SORT", "big", "ALPHA", "STORE", "bigout")
	expect_reply(t, &s, `"item-99999"`, "LINDEX", "bigout", "-1")
	call(&s, "DEL", "nums")
	args2 := make([dynamic]string, 0, n + 2, context.temp_allocator)
	append(&args2, "RPUSH", "nums")
	for i in 0 ..< n {
		append(&args2, fmt.tprintf("%d.5", (i * 7919) % n))
	}
	call(&s, ..args2[:])
	expect_reply(t, &s, `["0.5", "1.5", "2.5"]`, "SORT", "nums", "LIMIT", "0", "3")
	expect_reply(t, &s, `["99999.5", "99998.5"]`, "SORT", "nums", "DESC", "LIMIT", "0", "2")
	expect_reply(t, &s, `["50000.5", "50001.5"]`, "SORT", "nums", "LIMIT", "50000", "2")
	elapsed := time.since(start)
	testing.expectf(t, elapsed < 20 * time.Second, "large sorts took %v", elapsed)
}

@(private)
changes :: proc(s: ^Session) -> int {
	text := call(s, "INFO", "persistence")
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.has_prefix(line, "rdb_changes_since_last_save:") {
			n, _ := strconv.parse_int(strings.trim_right(line[len("rdb_changes_since_last_save:"):], "\r"))
			return n
		}
	}
	return -1
}

@(private)
expect_changes :: proc(t: ^testing.T, s: ^Session, delta: int, want: string, args: ..string, loc := #caller_location) {
	before := changes(s)
	expect_reply(t, s, want, ..args, loc = loc)
	after := changes(s)
	testing.expectf(t, before >= 0 && after - before == delta, "%v: changes went from %d to %d, want +%d", args, before, after, delta, loc = loc)
}

@(test)
sort_and_copy_change_counts :: proc(t: ^testing.T) {
	context.allocator = heap()
	s := open_session(2)
	defer close_session(&s)
	call(&s, "RPUSH", "l", "5", "4", "3", "2", "1")
	call(&s, "RPUSH", "bad", "1", "x")
	call(&s, "SET", "str", "v")
	expect_changes(t, &s, 5, ":5", "SORT", "l", "STORE", "out")
	expect_changes(t, &s, 2, ":2", "SORT", "l", "LIMIT", "0", "2", "GET", "missing_*", "STORE", "out")
	expect_changes(t, &s, 1, ":0", "SORT", "l", "LIMIT", "0", "0", "STORE", "out")
	expect_changes(t, &s, 0, ":0", "SORT", "l", "LIMIT", "0", "0", "STORE", "out")
	expect_changes(t, &s, 0, ":0", "SORT", "missing", "STORE", "out")
	expect_changes(t, &s, 0, `["1", "2", "3", "4", "5"]`, "SORT", "l")
	expect_changes(t, &s, 0, `["1", "2", "3", "4", "5"]`, "SORT_RO", "l")
	expect_changes(t, &s, 0, "-ERR One or more scores can't be converted into double", "SORT", "bad", "STORE", "out")
	expect_changes(t, &s, 0, "-WRONGTYPE Operation against a key holding the wrong kind of value", "SORT", "str", "STORE", "out")
	expect_changes(t, &s, 0, "-ERR syntax error", "SORT", "l", "STORE")
	expect_changes(t, &s, 1, ":1", "COPY", "l", "l2")
	expect_changes(t, &s, 0, ":0", "COPY", "l", "l2")
	expect_changes(t, &s, 1, ":1", "COPY", "l", "l2", "REPLACE")
	expect_changes(t, &s, 1, ":1", "COPY", "l", "l2", "DB", "5")
	expect_changes(t, &s, 0, ":0", "COPY", "missing", "z")
	expect_changes(t, &s, 0, "-ERR source and destination objects are the same", "COPY", "l", "l")
	expect_changes(t, &s, 0, "-ERR syntax error", "COPY", "l", "l3", "BOGUS")
	call(&s, "SET", "gone", "v", "PX", "1")
	pause(20)
	expect_changes(t, &s, 1, ":0", "SORT", "missing", "STORE", "gone")
}

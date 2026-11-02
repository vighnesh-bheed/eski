package hashtype_harness

import ht "../../src/hashtype"
import ld "../../src/ldfloat"
import lp "../../src/listpack"
import "core:encoding/hex"
import "core:fmt"
import "core:hash"
import "core:strconv"
import "core:strings"
import "core:time"

LP_CASES_TXT :: #load("../listpack/cases.txt", string)
LP_TABLE_TXT :: #load("../listpack/redis_table.txt", string)

b :: #force_inline proc(s: string) -> []u8 {
	return transmute([]u8)s
}

vstr :: proc(v: ht.Value) -> string {
	buf: [lp.LP_INTBUF_SIZE]u8
	return strings.clone(string(ht.value_bytes(v, &buf)), context.temp_allocator)
}

NOW :: u64(1_800_000_000_000)

get_s :: proc(h: ht.Hash, f: string, now: u64 = NOW) -> (string, bool) {
	v, res := ht.get(h, b(f), now)
	if res != .Ok {
		return "", false
	}
	return vstr(v), true
}

ex :: proc(h: ht.Hash, f: string, now: u64 = NOW) -> bool {
	ok, _ := ht.exists(h, b(f), now)
	return ok
}

slen :: proc(h: ht.Hash, f: string, now: u64 = NOW) -> int {
	n, _ := ht.field_strlen(h, b(f), now)
	return n
}

set_config :: proc(entries, value: int) {
	ht.hash_max_listpack_entries = entries
	ht.hash_max_listpack_value = value
}

unit_basic :: proc() {
	set_config(128, 64)
	h := ht.create()
	defer ht.destroy(h)
	check(ht.length(h) == 0 && h.encoding == .Listpack, "new hash empty listpack")
	check(ht.encoding_name(h) == "listpack", "encoding name listpack")
	args := [?][]u8{b("a"), b("1"), b("b"), b("hello"), b("a"), b("2"), b("c"), b("")}
	check(ht.hset(h, args[:]) == 3, "hset created count with duplicate field")
	v, ok := get_s(h, "a")
	check(ok && v == "2", "hget updated value")
	raw, _ := ht.get(h, b("a"), NOW)
	check(raw.is_int && raw.ival == 2, "123 style values stored as integers")
	v, ok = get_s(h, "c")
	check(ok && v == "", "empty value")
	check(!ex(h, "zz") && ex(h, "b"), "exists")
	check(slen(h, "b") == 5 && slen(h, "a") == 1 && slen(h, "zz") == 0, "strlen")
	check(!ht.hsetnx(h, b("a"), b("9"), NOW) && ht.hsetnx(h, b("d"), b("-9223372036854775808"), NOW), "hsetnx")
	check(slen(h, "d") == 20, "strlen of int encoded min i64")
	d, emptied := ht.hdel(h, {b("a"), b("zz"), b("a")})
	check(d == 1 && !emptied, "hdel counts once")
	d, emptied = ht.hdel(h, {b("b"), b("c"), b("d"), b("e")})
	check(d == 3 && emptied, "hdel empties")
	h2 := ht.create()
	defer ht.destroy(h2)
	ht.hset(h2, {b("x"), b("1"), b("y"), b("2"), b("z"), b("3")})
	d, emptied = ht.hdel(h2, {b("x"), b("y"), b("z"), b("x")})
	check(d == 3 && emptied, "hdel stops when empty")
}

expect_encoding :: proc(pairs: int, maxlen: int, entries: int, value: int) -> ht.Encoding {
	if pairs > entries || maxlen > value {
		return .Hashtable
	}
	return .Listpack
}

unit_conversions :: proc() {
	for cfg in ([?][2]int{{128, 64}, {4, 8}, {1, 1}, {0, 0}, {16, 0}, {16, 3}}) {
		set_config(cfg[0], cfg[1])
		entries, value := cfg[0], cfg[1]
		h3 := ht.create()
		ok := true
		maxlen := 0
		for i in 0 ..< entries + 1 {
			f := b(tp(i))
			maxlen = max(maxlen, len(f))
			ht.hset(h3, {f, nil})
			ok = ok && h3.encoding == expect_encoding(i + 1, maxlen, entries, value)
		}
		check(ok, fmt.tprintf("entries threshold %v", cfg))
		ht.destroy(h3)
		h4 := ht.create()
		ht.hset(h4, {nil, b(strings.repeat("v", value, context.temp_allocator))})
		check(h4.encoding == expect_encoding(1, value, entries, value), fmt.tprintf("value at limit %v", cfg))
		ht.hset(h4, {b("g"), b(strings.repeat("v", value + 1, context.temp_allocator))})
		check(h4.encoding == .Hashtable, fmt.tprintf("value over limit converts %v", cfg))
		_, emptied := ht.hdel(h4, {b("g")})
		check(!emptied && h4.encoding == .Hashtable, "never converts back")
		ht.destroy(h4)
		h5 := ht.create()
		pairs := make([dynamic][]u8, context.temp_allocator)
		for i in 0 ..< entries + 1 {
			append(&pairs, nil, b(tp(i)))
		}
		created := ht.hset(h5, pairs[:])
		check(created == 1 && h5.encoding == .Hashtable && ht.length(h5) == 1, fmt.tprintf("pair count over limit converts before write %v", cfg))
		ht.destroy(h5)
		h6 := ht.create()
		_, err := ht.incrby(h6, b(strings.repeat("k", value + 1, context.temp_allocator)), 1, NOW)
		check(err == .None && h6.encoding == .Hashtable, "hincrby long field converts")
		ht.destroy(h6)
	}
	set_config(128, 64)
}

unit_incr :: proc() {
	set_config(128, 64)
	h := ht.create()
	defer ht.destroy(h)
	v, err := ht.incrby(h, b("n"), 5, NOW)
	check(v == 5 && err == .None, "incrby new")
	ht.set(h, b("s"), b(" 11"))
	_, err = ht.incrby(h, b("s"), 1, NOW)
	check(err == .Hash_Value_Not_Integer && ht.error_message(err) == "hash value is not an integer", "incrby not integer")
	ht.set(h, b("m"), b("-9223372036854775484"))
	v, err = ht.incrby(h, b("m"), -1, NOW)
	check(v == -9223372036854775485 && err == .None, "incrby near min")
	_, err = ht.incrby(h, b("m"), -10000, NOW)
	check(err == .Increment_Overflow && ht.error_message(err) == "increment or decrement would overflow", "incrby overflow")
	ht.set(h, b("x"), b("9223372036854775807"))
	_, err = ht.incrby(h, b("x"), 1, NOW)
	check(err == .Increment_Overflow, "incrby overflow max")
	_, perr := ht.parse_incrby_increment(b("1.5"))
	check(perr == .Value_Not_Integer && ht.error_message(perr) == "value is not an integer or out of range", "incrby arg")
	buf := make([]u8, ld.MAX_LONG_DOUBLE_CHARS)
	defer delete(buf)
	steps := [?][2]string{{"1.23", "1.23"}, {"0.77", "2"}, {"-0.1", "1.9"}, {"10.5", "12.4"}, {"-12.4", "0"}, {"1e20", "100000000000000000000"}, {"-1e20", "0"}, {"0.0000005", "0.0000005"}, {"0x1p-3", "0.1250005"}}
	for st in steps {
		inc, ierr := ht.parse_incrbyfloat_increment(b(st[0]))
		r, e := ht.incrbyfloat(h, b("fl"), inc, buf, NOW)
		check(ierr == .None && e == .None && string(r) == st[1], fmt.tprintf("incrbyfloat %s -> %s got %s", st[0], st[1], string(r)))
	}
	got, _ := get_s(h, "fl")
	check(got == "0.1250005", "incrbyfloat stored value")
	_, perr2 := ht.parse_incrbyfloat_increment(b("inf"))
	check(perr2 == .Value_Nan_Or_Infinity && ht.error_message(perr2) == "value is NaN or Infinity", "incrbyfloat inf arg")
	_, perr2 = ht.parse_incrbyfloat_increment(b("nan"))
	check(perr2 == .Value_Not_Float && ht.error_message(perr2) == "value is not a valid float", "incrbyfloat nan arg")
	_, perr2 = ht.parse_incrbyfloat_increment(b(" 1"))
	check(perr2 == .Value_Not_Float, "incrbyfloat leading space")
	ht.set(h, b("inf"), b("inf"))
	one, _ := ht.parse_incrbyfloat_increment(b("1"))
	_, e2 := ht.incrbyfloat(h, b("inf"), one, buf, NOW)
	check(e2 == .Increment_Nan_Or_Infinity && ht.error_message(e2) == "increment would produce NaN or Infinity", "incrbyfloat stored inf")
	ht.set(h, b("nul"), b("1\x002"))
	_, e2 = ht.incrbyfloat(h, b("nul"), one, buf, NOW)
	check(e2 == .Hash_Value_Not_Float && ht.error_message(e2) == "hash value is not a float", "incrbyfloat embedded nul")
	big, _ := ht.parse_incrbyfloat_increment(b("1e70"))
	_, e2 = ht.incrbyfloat(h, b("n"), big, buf, NOW)
	check(e2 == .None && h.encoding == .Hashtable, "incrbyfloat long result converts")
}

unit_scan_guarantee :: proc() {
	set_config(128, 64)
	lp.lp_srand(12345)
	rounds := 300
	ok := true
	scans := 0
	growths, shrinks := 0, 0
	for r in 0 ..< rounds {
		h := ht.create()
		base := 50 + r % 400
		pairs := make([dynamic][]u8, context.temp_allocator)
		for i in 0 ..< base {
			append(&pairs, b(tp("stable:", i)), b(tp(i)))
		}
		ht.hset(h, pairs[:])
		if h.encoding == .Listpack {
			ht.convert(h)
		}
		stable := make(map[string]bool, 16, context.temp_allocator)
		for i in 0 ..< base {
			stable[tp("stable:", i)] = true
		}
		seen := make(map[string]bool, 16, context.temp_allocator)
		out := make([dynamic]ht.Value, context.temp_allocator)
		opts := ht.Scan_Options {
			count     = 1 + r % 17,
			no_values = r % 2 == 0,
		}
		cursor: u64 = 0
		churn := 0
		for {
			cap_before := h.table.cap
			clear(&out)
			cursor = ht.scan(h, cursor, opts, &out, NOW)
			step := 1 if opts.no_values else 2
			for i := 0; i < len(out); i += step {
				seen[vstr(out[i])] = true
			}
			scans += 1
			if cursor == 0 {
				break
			}
			switch r % 3 {
			case 0:
				for _ in 0 ..< 1 + int(lp.lp_rand() % 40) {
					ht.set(h, b(tp("churn:", churn)), b("x"))
					churn += 1
				}
			case 1:
				for _ in 0 ..< 1 + int(lp.lp_rand() % 40) {
					if churn > 0 {
						churn -= 1
						ht.delete_field(h, b(tp("churn:", churn)))
					} else {
						ht.set(h, b(tp("churn:", churn)), b("x"))
						churn += 1
					}
				}
				if lp.lp_rand() % 3 == 0 {
					for k in 0 ..< 200 {
						ht.set(h, b(tp("burst:", r, ":", k)), b("y"))
					}
				} else {
					for k in 0 ..< 200 {
						ht.delete_field(h, b(tp("burst:", r, ":", k)))
					}
				}
			case 2:
				if lp.lp_rand() % 2 == 0 {
					for k in 0 ..< 300 {
						ht.set(h, b(tp("burst:", k)), b("y"))
					}
				} else {
					for k in 0 ..< 300 {
						ht.delete_field(h, b(tp("burst:", k)))
					}
				}
			}
			if h.table.cap > cap_before {
				growths += 1
			} else if h.table.cap < cap_before {
				shrinks += 1
			}
		}
		for f in stable {
			if f not_in seen {
				ok = false
			}
		}
		ht.destroy(h)
		free_all(context.temp_allocator)
	}
	check(ok, "hscan returns every field present for the whole scan despite growth and shrink")
	check(growths > 0 && shrinks > 0, "scan guarantee test exercised both growth and shrink")
	fmt.printfln("    scan guarantee: %d rounds, %d scan calls, %d growths and %d shrinks mid-scan", rounds, scans, growths, shrinks)
}

unit_random :: proc() {
	set_config(128, 64)
	lp.lp_srand(777)
	for enc in 0 ..< 2 {
		h := ht.create()
		defer ht.destroy(h)
		for i in 0 ..< 10 {
			ht.set(h, b(tp("f", i)), b(tp(i)))
		}
		if enc == 1 {
			ht.convert(h)
		}
		fields := make([dynamic]ht.Value, context.temp_allocator)
		values := make([dynamic]ht.Value, context.temp_allocator)
		counts: [10]int
		for _ in 0 ..< 2000 {
			clear(&fields)
			clear(&values)
			ht.random_unique(h, 3, true, &fields, &values)
			if len(fields) != 3 {
				check(false, "unique count")
				break
			}
			for f, i in fields {
				name := vstr(f)
				n, _ := strconv.parse_int(name[1:])
				counts[n] += 1
				check(vstr(values[i]) == name[1:], "unique value pairs")
			}
			check(vstr(fields[0]) != vstr(fields[1]) && vstr(fields[1]) != vstr(fields[2]) && vstr(fields[0]) != vstr(fields[2]), "unique distinct")
		}
		chi := 0.0
		for c in counts {
			d := f64(c) - 600.0
			chi += d * d / 600.0
		}
		check(chi < 40, fmt.tprintf("unique distribution chi square %.2f encoding %d", chi, enc))
		clear(&fields)
		clear(&values)
		ht.random_with_repeats(h, 2500, true, &fields, &values)
		check(len(fields) == 2500 && len(values) == 2500, "repeats count over sample limit")
		rc: [10]int
		for f, i in fields {
			name := vstr(f)
			n, _ := strconv.parse_int(name[1:])
			rc[n] += 1
			check(vstr(values[i]) == name[1:], "repeat value pairs")
		}
		chi = 0
		for c in rc {
			d := f64(c) - 250.0
			chi += d * d / 250.0
		}
		check(chi < 40, fmt.tprintf("repeat distribution chi square %.2f encoding %d", chi, enc))
		clear(&fields)
		clear(&values)
		ht.random_unique(h, 50, false, &fields, &values)
		check(len(fields) == 10 && len(values) == 0, "count above size returns all")
		if enc == 0 {
			for f, i in fields {
				check(vstr(f) == tp("f", i), "listpack whole hash keeps listpack order")
			}
		}
		f, v := ht.random_element(h)
		check(vstr(v) == vstr(f)[1:], "random element pair")
	}
	big := ht.create()
	defer ht.destroy(big)
	for i in 0 ..< 1000 {
		ht.set(big, b(tp("k", i)), b("v"))
	}
	fields := make([dynamic]ht.Value, context.temp_allocator)
	values := make([dynamic]ht.Value, context.temp_allocator)
	ht.random_unique(big, 900, false, &fields, &values)
	seen := make(map[string]bool, 16, context.temp_allocator)
	for f in fields {
		seen[vstr(f)] = true
	}
	check(len(fields) == 900 && len(seen) == 900, "case 3 subtract strategy distinct")
	clear(&fields)
	clear(&seen)
	ht.random_unique(big, 20, false, &fields, &values)
	for f in fields {
		seen[vstr(f)] = true
	}
	check(len(fields) == 20 && len(seen) == 20, "case 4 sampling strategy distinct")
	free_all(context.temp_allocator)
}

unit_byte_table :: proc() {
	expected := make(map[string]string, 16, context.temp_allocator)
	for line in strings.split_lines(LP_TABLE_TXT, context.temp_allocator) {
		i := strings.index_byte(line, '|')
		if i > 0 {
			expected[line[:i]] = line[i + 1:]
		}
	}
	matched, total := 0, 0
	for line in strings.split_lines(LP_CASES_TXT, context.temp_allocator) {
		if len(line) == 0 {
			continue
		}
		f := strings.split_n(line, "|", 4, context.temp_allocator)
		if strings.has_prefix(f[0], "big_") {
			continue
		}
		e, _ := strconv.parse_int(f[1])
		v, _ := strconv.parse_int(f[2])
		set_config(e, v)
		h := ht.create()
		for op in strings.split(f[3], ";", context.temp_allocator) {
			parts := strings.split(op, " ", context.temp_allocator)
			field := token_bytes(parts[1])
			if parts[0] == "set" {
				args := [2][]u8{field, token_bytes(parts[2])}
				ht.hset(h, args[:])
			} else {
				ht.hdel(h, {field})
			}
		}
		total += 1
		want := expected[f[0]]
		raw := ht.listpack_bytes(h)
		same := false
		if strings.has_prefix(want, "crc32:") {
			parts := strings.split(want, ":", context.temp_allocator)
			crc, _ := strconv.parse_u64_of_base(parts[1], 16)
			n, _ := strconv.parse_int(parts[2])
			same = len(raw) == n && u64(hash.crc32(raw)) == crc
		} else {
			same = string(hex.encode(raw, context.temp_allocator)) == want
		}
		if check(h.encoding == .Listpack && same, f[0]) {
			matched += 1
		}
		ht.destroy(h)
	}
	set_config(128, 64)
	fmt.printfln("    hashtype listpack bytes vs Redis table: %d/%d", matched, total)
	free_all(context.temp_allocator)
}

token_bytes :: proc(t: string) -> []u8 {
	if t == "@e" {
		return nil
	}
	if strings.has_prefix(t, "@r:") {
		parts := strings.split(t, ":", context.temp_allocator)
		n, _ := strconv.parse_int(parts[2])
		return b(strings.repeat(parts[1], n, context.temp_allocator))
	}
	if strings.has_prefix(t, "@h:") {
		out, _ := hex.decode(b(t[3:]), context.temp_allocator)
		return out
	}
	return b(t)
}

unit_match_and_cursor :: proc() {
	cases := [?]struct {
		pat, str: string,
		want:     bool,
	} {
		{"*", "", false},
		{"*", "abc", true},
		{"**", "", false},
		{"", "", true},
		{"", "a", false},
		{"a*", "a", true},
		{"a*b", "axxb", true},
		{"a*b", "axxbc", false},
		{"h?llo", "hello", true},
		{"h?llo", "hllo", false},
		{"h[ae]llo", "hallo", true},
		{"h[^e]llo", "hello", false},
		{"h[a-b]llo", "hbllo", true},
		{"h[b-a]llo", "hallo", true},
		{"\\*", "*", true},
		{"\\*", "a", false},
		{"f[", "f[", false},
		{"f[", "fa", false},
		{"[]", "]", false},
		{"*[0-9]", "f12", true},
		{"*f*f*", "xfyfz", true},
		{"a\\", "a\\", true},
		{"[\\]]", "]", true},
	}
	for c in cases {
		check(ht.matches_pattern(b(c.pat), b(c.str), false) == c.want, fmt.tprintf("match %q %q", c.pat, c.str))
	}
	check(ht.matches_pattern(b("HeLLo"), b("hello"), true), "match nocase")
	cursors := [?]struct {
		s:  string,
		v:  u64,
		ok: bool,
	} {
		{"0", 0, true},
		{"123", 123, true},
		{"-1", 0, false},
		{"abc", 0, false},
		{"", 0, false},
		{" 7", 7, true},
		{"+7", 7, true},
		{"-0", 0, true},
		{"007", 7, true},
		{"18446744073709551615", max(u64), true},
		{"18446744073709551616", 0, false},
		{"-18446744073709551615", 1, true},
		{"5\x00junk", 5, true},
		{"7 ", 0, false},
	}
	for c in cursors {
		v, ok := ht.parse_scan_cursor(b(c.s))
		check(ok == c.ok && (!ok || v == c.v), fmt.tprintf("cursor %q", c.s))
	}
	opts, err := ht.parse_scan_options({b("count"), b("5"), b("MATCH"), b("*"), b("NoValues")}, true)
	check(err == .None && opts.count == 5 && !opts.use_pattern && opts.no_values, "scan options")
	_, err = ht.parse_scan_options({b("COUNT"), b("0")}, true)
	check(err == .Syntax, "count 0 syntax")
	_, err = ht.parse_scan_options({b("COUNT"), b("x")}, true)
	check(err == .Value_Not_Integer, "count not integer")
	_, err = ht.parse_scan_options({b("MATCH")}, true)
	check(err == .Syntax, "match without argument")
	_, err = ht.parse_scan_options({b("NOVALUES")}, false)
	check(err == .Novalues_Only_Hscan && ht.error_message(err) == "NOVALUES option can only be used in HSCAN", "novalues outside hscan")
	ra, rerr := ht.parse_hrandfield_args({b("-9223372036854775808")})
	check(rerr == .Hrandfield_Count_Range && ht.error_message(rerr) == "value is out of range, value must between -9223372036854775807 and 9223372036854775807", "hrandfield range")
	ra, rerr = ht.parse_hrandfield_args({b("-9223372036854770000"), b("withvalues")})
	check(rerr == .Value_Out_Of_Range, "hrandfield withvalues range")
	ra, rerr = ht.parse_hrandfield_args({b("4611686018427387903"), b("WITHVALUES")})
	check(rerr == .None && ra.with_values && ra.count == 4611686018427387903, "hrandfield withvalues max")
	ra, rerr = ht.parse_hrandfield_args({b("5"), b("WITHVALUES"), b("x")})
	check(rerr == .Syntax, "hrandfield extra arg")
}

unit_memory :: proc() {
	set_config(128, 64)
	h := ht.create()
	defer ht.destroy(h)
	m0 := ht.memory_usage(h)
	for i in 0 ..< 100 {
		ht.set(h, b(tp("field", i)), b(tp("value", i)))
	}
	m1 := ht.memory_usage(h)
	check(m1 > m0 && m1 >= len(ht.listpack_bytes(h)), "listpack memory grows")
	ht.convert(h)
	m2 := ht.memory_usage(h)
	check(m2 > m1, "hashtable memory larger than listpack")
	for i in 0 ..< 100 {
		ht.delete_field(h, b(tp("field", i)))
	}
	check(ht.length(h) == 0 && ht.memory_usage(h) < m2, "memory shrinks after deletes")
	d := ht.create()
	defer ht.destroy(d)
	ht.set(d, b("a"), b("1"))
	c, _ := ht.duplicate(d)
	check(string(ht.listpack_bytes(c)) == string(ht.listpack_bytes(d)), "duplicate listpack bytes")
	ht.destroy(c)
	ht.convert(d)
	c, _ = ht.duplicate(d)
	v, ok := get_s(c, "a")
	check(c.encoding == .Hashtable && ok && v == "1", "duplicate hashtable")
	ht.destroy(c)
	free_all(context.temp_allocator)
}

unit_iteration :: proc() {
	set_config(128, 64)
	for enc in 0 ..< 2 {
		h := ht.create()
		want := make(map[string]string, 16, context.temp_allocator)
		for i in 0 ..< 300 {
			f := tp(i * 7 - 300) if i % 2 == 0 else tp("name", i)
			ht.set(h, b(f), b(tp(i)))
			want[f] = tp(i)
			if enc == 0 && i == 100 {
				break
			}
		}
		it := ht.iterator(h)
		n := 0
		ok := true
		for ht.next(&it) {
			f := vstr(ht.current_field(&it))
			ok = ok && want[f] == vstr(ht.current_value(&it))
			n += 1
		}
		check(ok && n == len(want) && n == ht.length(h), fmt.tprintf("iteration covers hash encoding %v", h.encoding))
		ht.destroy(h)
	}
	free_all(context.temp_allocator)
}

run_unit :: proc() -> bool {
	start := time.tick_now()
	steps := [?]struct {
		name: string,
		fn:   proc(),
	} {
		{"bounded member migration", unit_resize},
		{"basic operations", unit_basic},
		{"listpack to hashtable conversions", unit_conversions},
		{"hincrby and hincrbyfloat", unit_incr},
		{"iteration", unit_iteration},
		{"hscan guarantee under rehash", unit_scan_guarantee},
		{"hrandfield selection", unit_random},
		{"listpack bytes vs Redis table", unit_byte_table},
		{"match, cursor and argument parsing", unit_match_and_cursor},
		{"memory accounting and duplicate", unit_memory},
		{"listpackex capture replay", unit_lpex_table},
	}
	for s in steps {
		before := checks
		t := time.tick_now()
		s.fn()
		fmt.printfln("  %-40s %-6d checks  %.1f ms", s.name, checks - before, time.duration_milliseconds(time.tick_since(t)))
	}
	fmt.printfln("hashtype-test unit: %d checks, %d failures (%.0f ms)", checks, failures, time.duration_milliseconds(time.tick_since(start)))
	return failures == 0
}

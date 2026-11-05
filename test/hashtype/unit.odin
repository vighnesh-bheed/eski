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
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	return strings.clone(string(ht.value_bytes(v, &buf)), context.temp_allocator)
}

NOW :: u64(1_800_000_000_000)

get_s :: proc(h: ht.Hash, f: string, now: u64 = NOW) -> (string, bool) {
	v, read := ht.get(h, b(f), now)
	if .Live not_in read {
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

HRANDFIELD_FIXTURE := [?][2]string{{"a", "1"}, {"b", "2"}, {"c", "3"}, {"d", "4"}, {"e", "5"}, {"6", "f"}, {"7", "g"}, {"8", "h"}, {"9", "i"}, {"10", "j"}}

Fixture_Tally :: [len(HRANDFIELD_FIXTURE)]int

fixture_slot :: proc(field: string) -> int {
	for pair, i in HRANDFIELD_FIXTURE {
		if pair[0] == field {
			return i
		}
	}
	return -1
}

tally_chi_square :: proc(tally: Fixture_Tally) -> f64 {
	draws := 0
	for n in tally {
		draws += n
	}
	expected := f64(draws) / f64(len(tally))
	sum := 0.0
	for n in tally {
		gap := f64(n) - expected
		sum += gap * gap / expected
	}
	return sum
}

Draw_Report :: struct {
	tally:     Fixture_Tally,
	strangers:   int,
	unpaired:  int,
	repeated:  bool,
	all_found: bool,
}

inspect_draw :: proc(fields, values: []ht.Value, with_values: bool) -> (r: Draw_Report) {
	for f, i in fields {
		slot := fixture_slot(vstr(f))
		if slot < 0 {
			r.strangers += 1
			continue
		}
		if r.tally[slot] > 0 {
			r.repeated = true
		}
		r.tally[slot] += 1
		if with_values && (i >= len(values) || vstr(values[i]) != HRANDFIELD_FIXTURE[slot][1]) {
			r.unpaired += 1
		}
	}
	r.all_found = true
	for n in r.tally {
		r.all_found = r.all_found && n > 0
	}
	return
}

fixture_hash :: proc(encoding: string) -> ht.Hash {
	h := ht.create()
	for pair in HRANDFIELD_FIXTURE {
		ht.set(h, b(pair[0]), b(pair[1]))
	}
	if encoding == "hashtable" {
		ht.convert(h)
	}
	return h
}

hrandfield_single_field :: proc(h: ht.Hash, label: string) {
	seen: Fixture_Tally
	paired := true
	for _ in 0 ..< 100 {
		f, v := ht.random_element(h)
		slot := fixture_slot(vstr(f))
		if slot < 0 {
			paired = false
			continue
		}
		paired = paired && vstr(v) == HRANDFIELD_FIXTURE[slot][1]
		seen[slot] += 1
	}
	missing := 0
	for n in seen {
		missing += 1 if n == 0 else 0
	}
	check(paired && missing == 0, fmt.tprintf("%s: a hundred single draws return paired fixture fields and reach all of them", label))
}

hrandfield_negative_counts :: proc(h: ht.Hash, label: string, fields, values: ^[dynamic]ht.Value) {
	for amount in ([]int{20, 1001}) {
		for with_values in ([]bool{false, true}) {
			clear(fields)
			clear(values)
			ht.random_with_repeats(h, amount, with_values, fields, values)
			r := inspect_draw(fields[:], values[:], with_values)
			want_values := amount if with_values else 0
			check(len(fields) == amount && len(values) == want_values && r.strangers == 0 && r.unpaired == 0, fmt.tprintf("%s: count -%d withvalues=%v returns exactly %d fixture entries", label, amount, with_values, amount))
		}
	}
	clear(fields)
	clear(values)
	ht.random_with_repeats(h, 1000, false, fields, values)
	r := inspect_draw(fields[:], values[:], false)
	chi := tally_chi_square(r.tally)
	check(r.repeated && chi < 40, fmt.tprintf("%s: count -1000 repeats fields and stays uniform, chi square %.2f", label, chi))
	union_tally: Fixture_Tally
	rounds := 0
	for ; rounds < 1000; rounds += 1 {
		clear(fields)
		clear(values)
		ht.random_with_repeats(h, 3, rounds % 2 == 0, fields, values)
		step := inspect_draw(fields[:], values[:], rounds % 2 == 0)
		covered := true
		for n, i in step.tally {
			union_tally[i] += n
			covered = covered && union_tally[i] > 0
		}
		if covered {
			break
		}
	}
	check(rounds < 1000, fmt.tprintf("%s: repeated count -3 draws eventually return every field", label))
}

hrandfield_positive_counts :: proc(h: ht.Hash, label: string, encoding: string, fields, values: ^[dynamic]ht.Value) {
	clear(fields)
	clear(values)
	ht.random_unique(h, 0, true, fields, values)
	check(len(fields) == 0 && len(values) == 0, fmt.tprintf("%s: count 0 returns nothing", label))
	for amount in ([]int{10, 20}) {
		clear(fields)
		clear(values)
		ht.random_unique(h, amount, true, fields, values)
		r := inspect_draw(fields[:], values[:], true)
		check(len(fields) == len(HRANDFIELD_FIXTURE) && !r.repeated && r.all_found && r.unpaired == 0, fmt.tprintf("%s: count %d returns the whole hash once with values", label, amount))
		if encoding == "listpack" {
			in_order := true
			for f, i in fields {
				in_order = in_order && vstr(f) == HRANDFIELD_FIXTURE[i][0]
			}
			check(in_order, fmt.tprintf("%s: count %d returns a listpack hash in insertion order", label, amount))
		}
	}
	for amount in ([]int{8, 2}) {
		union_tally: Fixture_Tally
		unique, sized, clean := true, true, true
		for round in 0 ..< 1000 / amount {
			with_values := round % 2 == 0
			clear(fields)
			clear(values)
			ht.random_unique(h, amount, with_values, fields, values)
			r := inspect_draw(fields[:], values[:], with_values)
			unique = unique && !r.repeated
			sized = sized && len(fields) == amount && len(values) == (amount if with_values else 0)
			clean = clean && r.strangers == 0 && r.unpaired == 0
			for n, i in r.tally {
				union_tally[i] += n
			}
		}
		covered := true
		for n in union_tally {
			covered = covered && n > 0
		}
		chi := tally_chi_square(union_tally)
		check(unique && sized && clean, fmt.tprintf("%s: count %d returns that many distinct fixture fields", label, amount))
		check(covered && chi < 40, fmt.tprintf("%s: count %d draws cover the hash uniformly, chi square %.2f", label, amount, chi))
	}
}

hrandfield_large_table :: proc(fields, values: ^[dynamic]ht.Value) {
	h := ht.create()
	defer ht.destroy(h)
	for i in 0 ..< 300 {
		ht.set(h, b(tp("member:", i)), b(tp(i * 3)))
	}
	ht.convert(h)
	for amount in ([]int{299, 250, 120, 30, 1}) {
		clear(fields)
		clear(values)
		ht.random_unique(h, amount, true, fields, values)
		names := make(map[string]bool, 16, context.temp_allocator)
		paired := true
		for f, i in fields {
			name := vstr(f)
			names[name] = true
			n, parsed := strconv.parse_int(name[len("member:"):])
			paired = paired && parsed && i < len(values) && vstr(values[i]) == tp(n * 3)
		}
		check(len(fields) == amount && len(names) == amount && paired, fmt.tprintf("hashtable of 300: count %d returns distinct paired members", amount))
	}
}

unit_random :: proc() {
	set_config(128, 64)
	lp.lp_srand(20261101)
	fields := make([dynamic]ht.Value, context.temp_allocator)
	values := make([dynamic]ht.Value, context.temp_allocator)
	for encoding in ([]string{"listpack", "hashtable"}) {
		h := fixture_hash(encoding)
		defer ht.destroy(h)
		label := fmt.tprintf("hrandfield %s", encoding)
		check(ht.encoding_name(h) == encoding, fmt.tprintf("%s fixture encoding", label))
		hrandfield_single_field(h, label)
		hrandfield_negative_counts(h, label, &fields, &values)
		hrandfield_positive_counts(h, label, encoding, &fields, &values)
	}
	hrandfield_large_table(&fields, &values)
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

Glob_Vector :: struct {
	pattern, subject: string,
	matches:          bool,
}

KEYS_GLOB_VECTORS := [?]Glob_Vector {
		{"h?llo", "hello", true},
		{"h?llo", "hallo", true},
		{"h?llo", "hxllo", true},
		{"h?llo", "hllo", false},
		{"h*llo", "hllo", true},
		{"h*llo", "heeeello", true},
		{"h*llo", "hellox", false},
		{"h[ae]llo", "hello", true},
		{"h[ae]llo", "hallo", true},
		{"h[ae]llo", "hillo", false},
		{"h[^e]llo", "hallo", true},
		{"h[^e]llo", "hbllo", true},
		{"h[^e]llo", "hello", false},
		{"h[a-b]llo", "hallo", true},
		{"h[a-b]llo", "hbllo", true},
		{"h[a-b]llo", "hcllo", false},
		{"h[b-a]llo", "hallo", true},
		{"h[b-a]llo", "hcllo", false},
		{"*", "abc", true},
		{"*", "x", true},
		{"**", "ab", true},
		{"a*", "a", true},
		{"*a", "a", true},
		{"a*b*c", "aXbYc", true},
		{"a*b*c", "aXbY", false},
		{"\\*", "*", true},
		{"\\*", "a", false},
		{"\\?", "?", true},
		{"\\?", "a", false},
		{"a\\", "a\\", true},
		{"a\\", "a", false},
		{"[]", "]", false},
		{"[]", "[", false},
		{"[]]", "]", false},
		{"[]a]", "a", false},
		{"[]a]", "]", false},
		{"f[", "f[", false},
		{"f[", "fa", false},
		{"f[a", "fa", true},
		{"f[a-", "fa", true},
		{"f[a-", "f-", true},
		{"[\\]]", "]", true},
		{"[\\]]", "\\", false},
		{"[a\\-z]", "-", true},
		{"[a\\-z]", "b", false},
		{"[a-]", "-", false},
		{"[a-]", "a", true},
		{"[-a]", "-", true},
		{"[!a]", "!", true},
		{"[!a]", "b", false},
		{"[^]", "^", true},
		{"[^]]", "x", false},
		{"[^]]", "]", false},
		{"*[0-9]", "f12", true},
		{"*[0-9]", "f1x", false},
		{"*f*f*", "xfyfz", true},
		{"*f*f*", "xfyz", false},
		{"[A-Z]", "q", false},
		{"[a-z]", "Q", false},
		{"?", "\xff", true},
		{"[\x80-\xff]", "\xaa", true},
		{"a[bc", "ab", true},
		{"a[bc", "a[bc", false},
		{"*\\", "x\\", true},
		{"\\", "\\", true},
		{"\\a", "a", true},
		{"[[]", "[", true},
		{"[*]", "*", true},
		{"[*]", "x", false},
		{"[?]", "?", true},
		{"[?]", "x", false},
		{"a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false},
}

Cursor_Vector :: struct {
	text:   string,
	cursor: u64,
	valid:  bool,
}

SCAN_CURSOR_VECTORS := [?]Cursor_Vector {
	{"0", 0, true},
	{"7", 7, true},
	{" 7", 7, true},
	{"\t5", 5, true},
	{"\x0b9", 9, true},
	{"\r\n5", 5, true},
	{"+7", 7, true},
	{"007", 7, true},
	{"-0", 0, true},
	{"-01", max(u64), true},
	{" -1", max(u64), true},
	{"-1", 0, false},
	{"-9223372036854775808", 0, false},
	{"-9223372036854775809", 9223372036854775807, true},
	{"-18446744073709551615", 1, true},
	{"-18446744073709551616", 0, false},
	{"18446744073709551615", max(u64), true},
	{"18446744073709551616", 0, false},
	{"00000000000000000000000000018446744073709551615", max(u64), true},
	{"-0000000000000000000001", max(u64), true},
	{"5\x00junk", 5, true},
	{"\x005", 0, false},
	{"5 ", 0, false},
	{"7 ", 0, false},
	{"", 0, false},
	{" ", 0, false},
	{"-", 0, false},
	{"+", 0, false},
	{"+-5", 0, false},
	{"- 5", 0, false},
	{"abc", 0, false},
	{"0x10", 0, false},
	{"1e3", 0, false},
}

Scan_Option_Vector :: struct {
	args:    []string,
	is_hash: bool,
	err:     ht.Error,
}

as_args :: proc(words: []string) -> [][]u8 {
	out := make([][]u8, len(words), context.temp_allocator)
	for w, i in words {
		out[i] = b(w)
	}
	return out
}

Hrandfield_Vector :: struct {
	args:        []string,
	err:         ht.Error,
	count:       i64,
	with_values: bool,
}

unit_match_and_cursor :: proc() {
	glob_agree := 0
	for v in KEYS_GLOB_VECTORS {
		if check(ht.matches_pattern(b(v.pattern), b(v.subject), false) == v.matches, fmt.tprintf("KEYS %q against %q", v.pattern, v.subject)) {
			glob_agree += 1
		}
	}
	fmt.printfln("    glob vectors agreeing with the reference KEYS: %d/%d", glob_agree, len(KEYS_GLOB_VECTORS))
	nocase := [?]Glob_Vector{{"HeLLo", "hello", true}, {"H[A-E]LLO", "hallo", true}, {"h?LLO", "HxLlo", true}, {"*LO", "hello", true}, {"[^E]llo", "ello", false}, {"h[^E]llo", "hEllo", false}, {"h[^E]llo", "hallo", true}, {"HELLO", "help", false}}
	for v in nocase {
		check(ht.matches_pattern(b(v.pattern), b(v.subject), true) == v.matches, fmt.tprintf("nocase %q against %q", v.pattern, v.subject))
	}
	check(ht.matches_pattern(b("[^E]llo"), b("ello"), false), "case sensitive negated class keeps other case")
	for v in SCAN_CURSOR_VECTORS {
		cursor, valid := ht.parse_scan_cursor(b(v.text))
		check(valid == v.valid && (!valid || cursor == v.cursor), fmt.tprintf("cursor %q gives %v %d", v.text, valid, cursor))
	}
	scan_options := [?]Scan_Option_Vector {
		{{"COUNT", "0"}, true, .Syntax},
		{{"COUNT", "-3"}, true, .Syntax},
		{{"COUNT", "x"}, true, .Value_Not_Integer},
		{{"MATCH"}, true, .Syntax},
		{{"COUNT"}, true, .Syntax},
		{{"bogus"}, true, .Syntax},
		{{"COUNT", "x", "bogus"}, true, .Value_Not_Integer},
		{{"bogus", "COUNT", "x"}, true, .Syntax},
		{{"NOVALUES"}, false, .Novalues_Only_Hscan},
		{{"NOVALUES"}, true, .None},
		{{"novalues", "COUNT", "5", "MATCH", "*"}, true, .None},
	}
	for v in scan_options {
		_, err := ht.parse_scan_options(as_args(v.args), v.is_hash)
		check(err == v.err, fmt.tprintf("scan options %v hash=%v gives %v", v.args, v.is_hash, err))
	}
	defaults, derr := ht.parse_scan_options(nil, true)
	check(derr == .None && defaults.count == 10 && !defaults.use_pattern && !defaults.no_values, "scan options default to count 10 without a pattern")
	opts, oerr := ht.parse_scan_options(as_args({"match", "f*", "Count", "250", "NOVALUES"}), true)
	check(oerr == .None && opts.count == 250 && opts.use_pattern && string(opts.pattern) == "f*" && opts.no_values, "scan options keep count, pattern and novalues")
	opts, oerr = ht.parse_scan_options(as_args({"MATCH", "*"}), false)
	check(oerr == .None && !opts.use_pattern, "a lone star pattern needs no matching")
	check(ht.error_message(.Novalues_Only_Hscan) == "NOVALUES option can only be used in HSCAN", "novalues message")
	hrandfield_cases := [?]Hrandfield_Vector {
		{{}, .None, 0, false},
		{{"0"}, .None, 0, false},
		{{"0", "WITHVALUES"}, .None, 0, true},
		{{"-9223372036854775807"}, .None, -9223372036854775807, false},
		{{"9223372036854775807"}, .None, 9223372036854775807, false},
		{{"-9223372036854775808"}, .Hrandfield_Count_Range, 0, false},
		{{"-9223372036854775808", "WITHVALUES"}, .Hrandfield_Count_Range, 0, false},
		{{"-9223372036854770000", "withvalues"}, .Value_Out_Of_Range, 0, false},
		{{"4611686018427387903", "WITHVALUES"}, .None, 4611686018427387903, true},
		{{"-4611686018427387903", "WithValues"}, .None, -4611686018427387903, true},
		{{"4611686018427387904", "WITHVALUES"}, .Value_Out_Of_Range, 0, false},
		{{"-4611686018427387904", "WITHVALUES"}, .Value_Out_Of_Range, 0, false},
		{{"5", "WITHVALUES", "x"}, .Syntax, 0, false},
		{{"5", "bogus"}, .Syntax, 0, false},
		{{"x"}, .Value_Not_Integer, 0, false},
		{{"x", "WITHVALUES"}, .Value_Not_Integer, 0, false},
	}
	for v in hrandfield_cases {
		got, err := ht.parse_hrandfield_args(as_args(v.args))
		ok := err == v.err
		if ok && err == .None {
			ok = got.count == v.count && got.with_values == v.with_values && got.has_count == (len(v.args) > 0)
		}
		check(ok, fmt.tprintf("hrandfield arguments %v gives %v", v.args, err))
	}
	check(ht.error_message(.Hrandfield_Count_Range) == "value is out of range, value must between -9223372036854775807 and 9223372036854775807", "hrandfield count range message")
	check(ht.error_message(.Value_Out_Of_Range) == "value is out of range", "hrandfield withvalues range message")
	free_all(context.temp_allocator)
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

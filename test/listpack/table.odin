package main

import lp "../../src/listpack"
import "core:encoding/hex"
import "core:fmt"
import "core:hash"
import "core:strconv"
import "core:strings"

CASES_TXT :: #load("cases.txt", string)
REDIS_TABLE_TXT :: #load("redis_table.txt", string)

Table_Case :: struct {
	name:    string,
	entries: int,
	value:   int,
	ops:     []string,
}

parse_token :: proc(t: string, allocator := context.temp_allocator) -> []u8 {
	if t == "@e" {
		return nil
	}
	if strings.has_prefix(t, "@r:") {
		parts := strings.split(t, ":", context.temp_allocator)
		n, _ := strconv.parse_int(parts[2])
		out := make([]u8, n, allocator)
		for i in 0 ..< n {
			out[i] = parts[1][0]
		}
		return out
	}
	if strings.has_prefix(t, "@h:") {
		out, _ := hex.decode(transmute([]u8)t[3:], allocator)
		return out
	}
	return transmute([]u8)t
}

load_cases :: proc() -> [dynamic]Table_Case {
	out := make([dynamic]Table_Case)
	for line in strings.split_lines(CASES_TXT, context.temp_allocator) {
		if len(line) == 0 {
			continue
		}
		f := strings.split_n(line, "|", 4)
		e, _ := strconv.parse_int(f[1])
		v, _ := strconv.parse_int(f[2])
		append(&out, Table_Case{name = f[0], entries = e, value = v, ops = strings.split(f[3], ";")})
	}
	return out
}

load_expected :: proc() -> (m: map[string]string, version: string) {
	m = make(map[string]string)
	for line in strings.split_lines(REDIS_TABLE_TXT, context.temp_allocator) {
		if len(line) == 0 {
			continue
		}
		i := strings.index_byte(line, '|')
		if line[:i] == "redis_version" {
			version = line[i + 1:]
			continue
		}
		m[line[:i]] = line[i + 1:]
	}
	return
}

replay_listpack :: proc(c: Table_Case) -> [^]u8 {
	l := lp.lp_new(0)
	for op in c.ops {
		parts := strings.split(op, " ", context.temp_allocator)
		f := parse_token(parts[1])
		switch parts[0] {
		case "set":
			v := parse_token(parts[2])
			fptr := lp.lp_first(l)
			if fptr != nil {
				fptr = lp.lp_find(l, fptr, f, 1)
			}
			if fptr != nil {
				vptr := lp.lp_next(l, fptr)
				l = lp.lp_replace(l, &vptr, v)
			} else {
				l = lp.lp_append(l, f)
				l = lp.lp_append(l, v)
			}
		case "del":
			fptr := lp.lp_first(l)
			if fptr != nil {
				fptr = lp.lp_find(l, fptr, f, 1)
			}
			if fptr != nil {
				l = lp.lp_delete_range_with_entry(l, &fptr, 2)
			}
		}
		free_all(context.temp_allocator)
	}
	return l
}

expected_matches :: proc(want: string, got: []u8) -> bool {
	if strings.has_prefix(want, "crc32:") {
		parts := strings.split(want, ":", context.temp_allocator)
		crc, _ := strconv.parse_u64_of_base(parts[1], 16)
		n, _ := strconv.parse_int(parts[2])
		return len(got) == n && u64(hash.crc32(got)) == crc
	}
	h := hex.encode(got, context.temp_allocator)
	return string(h) == want
}

run_redis_table :: proc() {
	check(hash.crc32(transmute([]u8)string("123456789")) == 0xCBF43926, "crc32 matches zlib")
	cases := load_cases()
	defer {
		for c in cases {
			delete(c.ops)
		}
		delete(cases)
	}
	expected, version := load_expected()
	defer delete(expected)
	check(len(cases) == len(expected), "table covers every case")
	matched := 0
	for c in cases {
		want, ok := expected[c.name]
		if !check(ok, c.name) {
			continue
		}
		l := replay_listpack(c)
		got := lp.lp_view(l)
		if check(expected_matches(want, got), c.name) {
			matched += 1
		} else if len(got) < 200 {
			fmt.eprintfln("    %s\n      redis %s\n      eski %s", c.name, want, hex.encode(got, context.temp_allocator))
		}
		check(lp.lp_validate_integrity(l, u64(len(got)), true, nil, nil), c.name)
		lp.lp_free(l)
		free_all(context.temp_allocator)
	}
	fmt.printfln("    byte table: %d/%d cases identical to Redis %s DUMP listpacks", matched, len(cases), version)
}

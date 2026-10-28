package hashtype_harness

import ht "../../src/hashtype"
import "core:encoding/hex"
import "core:fmt"
import "core:strconv"
import "core:strings"

Hfe_Env :: struct {
	reg:  ht.Registry,
	now:  u64,
	ints: [dynamic]i64,
	key:  string,
}

LPEX_CASES_TXT :: #load("lpex_cases.txt", string)
LPEX_TABLE_TXT :: #load("lpex_table.txt", string)

unit_lpex_table :: proc() {
	expected := make(map[string][]string, 16, context.temp_allocator)
	version := ""
	for line in strings.split_lines(LPEX_TABLE_TXT, context.temp_allocator) {
		if len(line) == 0 {
			continue
		}
		f := strings.split(line, "|", context.temp_allocator)
		if f[0] == "redis_version" {
			version = f[1]
			continue
		}
		expected[f[0]] = f[1:]
	}
	env := Hfe_Env {
		now  = NOW,
		ints = make([dynamic]i64),
		key  = "k",
	}
	defer {
		ht.registry_destroy(&env.reg)
		delete(env.ints)
	}
	matched, total := 0, 0
	for line in strings.split_lines(LPEX_CASES_TXT, context.temp_allocator) {
		if len(line) == 0 {
			continue
		}
		f := strings.split_n(line, "|", 4, context.temp_allocator)
		e, _ := strconv.parse_int(f[1])
		v, _ := strconv.parse_int(f[2])
		set_config(e, v)
		h := ht.create()
		for op in strings.split(f[3], ";", context.temp_allocator) {
			parts := strings.split(op, " ", context.temp_allocator)
			switch parts[0] {
			case "set":
				args := [2][]u8{token_bytes(parts[1]), token_bytes(parts[2])}
				ht.hset(h, args[:])
			case "del":
				ht.hdel(h, {token_bytes(parts[1])})
			case "incr":
				n, _ := strconv.parse_i64(parts[2])
				ht.incrby(h, token_bytes(parts[1]), n, env.now)
			case "persist":
				names := strings.split(parts[1], ",", context.temp_allocator)
				fs := make([][]u8, len(names), context.temp_allocator)
				for name, i in names {
					fs[i] = token_bytes(name)
				}
				clear(&env.ints)
				ht.persist_fields(h, fs, env.now, &env.ints)
			case "pxat":
				at, _ := strconv.parse_u64(parts[1])
				cond := ht.Expire_Condition.None
				switch parts[2] {
				case "NX":
					cond = .NX
				case "XX":
					cond = .XX
				case "GT":
					cond = .GT
				case "LT":
					cond = .LT
				}
				names := strings.split(parts[3], ",", context.temp_allocator)
				fs := make([][]u8, len(names), context.temp_allocator)
				for name, i in names {
					fs[i] = token_bytes(name)
				}
				clear(&env.ints)
				ht.expire_fields(&env.reg, &env.key, h, fs, at, cond, env.now, &env.ints)
			}
		}
		total += 1
		want := expected[f[0]]
		got_hex := string(hex.encode(ht.listpack_bytes(h), context.temp_allocator))
		header := tp(ht.dump_min_expire(h))
		typ := "25" if h.encoding == .Listpack_Ex else ("16" if h.encoding == .Listpack else "?")
		if check(want != nil && ht.encoding_name(h) == want[0] && typ == want[1] && header == want[2] && got_hex == want[3], fmt.tprintf("listpackex table %s", f[0])) {
			matched += 1
		}
		ht.destroy(h)
	}
	set_config(128, 64)
	fmt.printfln("    listpackex DUMP table: %d/%d cases identical (encoding, rdb type, min expire header, listpack bytes) to Redis %s", matched, total, version)
}

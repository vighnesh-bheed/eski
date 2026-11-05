package listtype_harness

import lp "../../src/listpack"
import lt "../../src/listtype"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Stat :: struct {
	total:    int,
	mismatch: int,
}

Mode :: enum {
	Exact,
	Dump_Listpack,
	Dump_Quicklist,
	Dump_Missing,
	Dump_String,
	Debug_Object,
	Ignored,
}

RDB_TYPE_LIST_QUICKLIST_2 :: 18
RDB_VERSION :: 12
CRC64_POLY :: u64(0x95ac9329ac4bc9b5)

Compare_State :: struct {
	m:          Model,
	stats:      map[string]Stat,
	modes:      [Mode]int,
	nodes:      [Mode]int,
	plain:      int,
	mismatches: int,
	shown:      int,
}

label_of :: proc(args: [][]u8) -> string {
	name := strings.to_upper(string(args[0]), context.temp_allocator)
	if (name == "OBJECT" || name == "CONFIG" || name == "DEBUG") && len(args) > 1 {
		return fmt.tprintf("%s %s", name, strings.to_upper(string(args[1]), context.temp_allocator))
	}
	return name
}

short :: proc(b: []u8, n := 160) -> string {
	s := fmt.tprintf("%q", string(b[:min(len(b), n)]))
	if len(b) > n {
		return fmt.tprintf("%s...(%d bytes)", s, len(b))
	}
	return s
}

record :: proc(cs: ^Compare_State, idx: int, args: [][]u8, mode: Mode, ok: bool, redis: []u8, mine: []u8, why: string = "") {
	label := label_of(args)
	st := cs.stats[label]
	st.total += 1
	cs.modes[mode] += 1
	if !ok {
		st.mismatch += 1
		cs.mismatches += 1
		if cs.shown < 25 {
			cs.shown += 1
			parts := make([dynamic]string, context.temp_allocator)
			for a in args {
				append(&parts, short(a, 40))
			}
			fmt.eprintfln("MISMATCH #%d [%v] %s %s", idx, mode, strings.join(parts[:], " ", context.temp_allocator), why)
			fmt.eprintfln("  redis: %s", short(redis))
			fmt.eprintfln("  model: %s", short(mine))
		}
	}
	if label not_in cs.stats {
		cs.stats[strings.clone(label)] = st
	} else {
		cs.stats[label] = st
	}
}

crc64 :: proc(data: []u8) -> u64 {
	crc: u64 = 0
	for b in data {
		crc ~= u64(b)
		for _ in 0 ..< 8 {
			if crc & 1 != 0 {
				crc = (crc >> 1) ~ CRC64_POLY
			} else {
				crc >>= 1
			}
		}
	}
	return crc
}

rdb_put_len :: proc(out: ^[dynamic]u8, n: int) {
	switch {
	case n < 1 << 6:
		append(out, u8(n))
	case n < 1 << 14:
		append(out, u8(((n >> 8) & 0x3F) | 0x40), u8(n & 0xFF))
	case n <= int(max(u32)):
		append(out, 0x80, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	case:
		append(out, 0x81)
		for k := 56; k >= 0; k -= 8 {
			append(out, u8(n >> uint(k)))
		}
	}
}

rdb_put_string :: proc(out: ^[dynamic]u8, s: []u8) {
	if len(s) <= 11 {
		v: i64
		if lp.lp_string_to_int64(s, &v) {
			switch {
			case v >= -(1 << 7) && v <= (1 << 7) - 1:
				append(out, 0xC0, u8(v))
				return
			case v >= -(1 << 15) && v <= (1 << 15) - 1:
				append(out, 0xC1, u8(v), u8(v >> 8))
				return
			case v >= -(1 << 31) && v <= (1 << 31) - 1:
				append(out, 0xC2, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
				return
			}
		}
	}
	rdb_put_len(out, len(s))
	append(out, ..s)
}

dump_trailer :: proc(out: ^[dynamic]u8) {
	append(out, RDB_VERSION, 0)
	crc := crc64(out[:])
	for k in 0 ..< 8 {
		append(out, u8(crc >> uint(8 * k)))
	}
}

expected_string_dump :: proc(s: []u8) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, 0)
	rdb_put_string(&out, s)
	dump_trailer(&out)
	return out[:]
}

expected_dump :: proc(l: lt.List) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	nodes := make([dynamic][]u8, context.temp_allocator)
	plain := make([dynamic]bool, context.temp_allocator)
	lt.node_listpacks(l, &nodes, &plain)
	append(&out, RDB_TYPE_LIST_QUICKLIST_2)
	rdb_put_len(&out, len(nodes))
	for n, i in nodes {
		rdb_put_len(&out, 1 if plain[i] else 2)
		rdb_put_string(&out, n)
	}
	dump_trailer(&out)
	return out[:]
}

compare_dump :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	k := lookup(&cs.m, args[1])
	if rr.kind == .Null {
		record(cs, idx, args, .Dump_Missing, k == nil, rr.raw, nil, "redis has no key")
		return
	}
	if rr.kind != .Bulk || k == nil {
		record(cs, idx, args, .Exact, false, rr.raw, nil, "model has no key")
		return
	}
	if k.kind == .String {
		mine := expected_string_dump(k.str)
		record(cs, idx, args, .Dump_String, string(rr.str) == string(mine), rr.str, mine, "string dump differs")
		return
	}
	mine := expected_dump(k.list)
	mode := Mode.Dump_Quicklist if k.list.encoding == .Quicklist else Mode.Dump_Listpack
	ok := string(rr.str) == string(mine)
	if ok {
		nodes := make([dynamic][]u8, context.temp_allocator)
		plain := make([dynamic]bool, context.temp_allocator)
		lt.node_listpacks(k.list, &nodes, &plain)
		cs.nodes[mode] += len(nodes)
		for p in plain {
			if p {
				cs.plain += 1
			}
		}
	}
	record(cs, idx, args, mode, ok, rr.str, mine, "dump bytes differ")
}

debug_object_fields :: proc(s: []u8) -> string {
	if len(s) == 0 || s[0] != '+' {
		return string(s)
	}
	parts := strings.split(string(s), " ", context.temp_allocator)
	keep := make([dynamic]string, context.temp_allocator)
	for p in parts {
		if strings.has_prefix(p, "encoding:") || strings.has_prefix(p, "ql_") {
			append(&keep, strings.trim_right(p, "\r\n"))
		}
	}
	return strings.join(keep[:], " ", context.temp_allocator)
}

compare_debug_object :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	mine := strings.clone(string(exec(&cs.m, args)), context.temp_allocator)
	a := debug_object_fields(rr.raw)
	b := debug_object_fields(transmute([]u8)mine)
	record(cs, idx, args, .Debug_Object, a == b, transmute([]u8)a, transmute([]u8)b, "debug object fields differ")
}

run_compare :: proc(dir: string, server := false) -> bool {
	replies_name := "eski.out" if server else "redis.out"
	script, serr := os.read_entire_file(fmt.tprintf("%s/script.resp", dir), context.allocator)
	if serr != nil {
		fmt.eprintln("cannot read script.resp")
		return false
	}
	redis, rerr := os.read_entire_file(fmt.tprintf("%s/%s", dir, replies_name), context.allocator)
	if rerr != nil {
		fmt.eprintln("cannot read", replies_name)
		return false
	}
	cmds, ok := parse_commands(script)
	if !ok {
		fmt.eprintln("malformed script")
		return false
	}
	saved_size := lt.list_max_listpack_size
	saved_depth := lt.list_compress_depth
	saved_threshold := lt.plain_node_threshold
	cs := Compare_State {
		m     = model_make(),
		stats = make(map[string]Stat),
	}
	pos := 0
	for args, idx in cmds {
		rr, next, rok := parse_reply(redis, pos, context.temp_allocator)
		if !rok {
			fmt.eprintfln("cannot parse reply %d at byte %d", idx, pos)
			return false
		}
		pos = next
		upper := strings.to_upper(string(args[0]), context.temp_allocator)
		arity, known := arity_of(lower_name(args[0]))
		if !known || (arity > 0 && len(args) != arity) || (arity < 0 && len(args) < -arity) {
			upper = ""
		}
		switch {
		case upper == "DUMP":
			compare_dump(&cs, idx, args, rr)
		case upper == "HELLO":
			exec(&cs.m, args)
			record(&cs, idx, args, .Ignored, true, nil, nil)
		case upper == "DEBUG" && len(args) == 3 && eq_upper(args[1], "OBJECT"):
			compare_debug_object(&cs, idx, args, rr)
		case:
			mine := exec(&cs.m, args)
			record(&cs, idx, args, .Exact, string(mine) == string(rr.raw), rr.raw, mine)
		}
		free_all(context.temp_allocator)
	}
	if pos != len(redis) {
		fmt.eprintfln("%s has %d trailing bytes", replies_name, len(redis) - pos)
		cs.mismatches += 1
	}
	labels := make([dynamic]string)
	defer delete(labels)
	for k in cs.stats {
		append(&labels, k)
	}
	slice.sort(labels[:])
	fmt.printfln("%s replies checked against the model", "eski" if server else "redis")
	fmt.println("command                          count   mismatches")
	total := 0
	for l in labels {
		st := cs.stats[l]
		total += st.total
		fmt.printfln("%-32s %-7d %d", l, st.total, st.mismatch)
	}
	fmt.printfln("%-32s %-7d %d", "TOTAL", total, cs.mismatches)
	fmt.println("comparison modes:")
	for mode in Mode {
		fmt.printfln("  %-16v %d", mode, cs.modes[mode])
	}
	fmt.printfln("dump nodes compared: listpack %d, quicklist %d (plain %d)", cs.nodes[.Dump_Listpack], cs.nodes[.Dump_Quicklist], cs.plain)
	for k in cs.stats {
		delete(k)
	}
	delete(cs.stats)
	model_destroy(&cs.m)
	for a in cmds {
		delete(a)
	}
	delete(cmds)
	delete(script)
	delete(redis)
	lt.list_max_listpack_size = saved_size
	lt.list_compress_depth = saved_depth
	lt.plain_node_threshold = saved_threshold
	return cs.mismatches == 0
}

eq_upper :: proc(a: []u8, b: string) -> bool {
	return strings.to_upper(string(a), context.temp_allocator) == b
}

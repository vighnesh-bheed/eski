package zsettype_harness

import lp "../../src/listpack"
import zt "../../src/zsettype"
import ht "../../src/hashtype"
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
	Dump_Skiplist,
	Dump_Missing,
	Zrandmember_Rules,
	Zscan_Exact,
	Zscan_Union,
	Ignored,
}

Compare_State :: struct {
	m:          Model,
	stats:      map[string]Stat,
	modes:      [Mode]int,
	mismatches: int,
	shown:      int,
}

label_of :: proc(args: [][]u8) -> string {
	name := strings.to_upper(string(args[0]), context.temp_allocator)
	if (name == "OBJECT" || name == "CONFIG") && len(args) > 1 {
		return fmt.tprintf("%s %s", name, strings.to_upper(string(args[1]), context.temp_allocator))
	}
	return name
}

short :: proc(b: []u8, n := 200) -> string {
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

le_u64 :: proc(p: []u8) -> u64 {
	v: u64
	for i in 0 ..< 8 {
		v |= u64(p[i]) << uint(8 * i)
	}
	return v
}

rdb_len :: proc(p: []u8, i: int) -> (n: int, enc: bool, next: int, ok: bool) {
	if i >= len(p) {
		return
	}
	b0 := p[i]
	switch b0 >> 6 {
	case 0:
		return int(b0 & 0x3F), false, i + 1, true
	case 1:
		if i + 1 >= len(p) {
			return
		}
		return int(b0 & 0x3F) << 8 | int(p[i + 1]), false, i + 2, true
	case 2:
		if b0 == 0x80 && i + 5 <= len(p) {
			return int(p[i + 1]) << 24 | int(p[i + 2]) << 16 | int(p[i + 3]) << 8 | int(p[i + 4]), false, i + 5, true
		}
		if b0 == 0x81 && i + 9 <= len(p) {
			v := 0
			for k in 1 ..= 8 {
				v = v << 8 | int(p[i + k])
			}
			return v, false, i + 9, true
		}
		return
	case 3:
		return int(b0 & 0x3F), true, i + 1, true
	}
	return
}

rdb_string :: proc(p: []u8, i: int) -> (s: string, next: int, ok: bool) {
	n, enc, j, lok := rdb_len(p, i)
	if !lok {
		return
	}
	if enc {
		switch n {
		case 0:
			if j + 1 > len(p) {
				return
			}
			return fmt.tprint(i8(p[j])), j + 1, true
		case 1:
			if j + 2 > len(p) {
				return
			}
			return fmt.tprint(i16(u16(p[j]) | u16(p[j + 1]) << 8)), j + 2, true
		case 2:
			if j + 4 > len(p) {
				return
			}
			return fmt.tprint(i32(u32(p[j]) | u32(p[j + 1]) << 8 | u32(p[j + 2]) << 16 | u32(p[j + 3]) << 24)), j + 4, true
		}
		return
	}
	if j + n > len(p) {
		return
	}
	return string(p[j:j + n]), j + n, true
}

Pair :: struct {
	member: string,
	bits:   u64,
}

model_pairs :: proc(z: zt.Zset) -> [dynamic]Pair {
	out := make([dynamic]Pair, context.temp_allocator)
	it := zt.iter_make(z, false)
	item: zt.Item
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	for zt.iter_next(&it, &item) {
		append(&out, Pair{strings.clone(string(zt.item_bytes(&item, &buf)), context.temp_allocator), transmute(u64)item.score})
	}
	return out
}

compare_dump :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	z, found, wrong := lookup_zset(&cs.m, args[1])
	if rr.kind == .Null {
		record(cs, idx, args, .Dump_Missing, !found, rr.raw, nil, "redis has no key")
		return
	}
	if rr.kind != .Bulk || len(rr.str) < 11 {
		record(cs, idx, args, .Exact, false, rr.raw, nil, "unexpected dump reply")
		return
	}
	if !found || wrong {
		record(cs, idx, args, .Exact, false, rr.raw, nil, "model has no zset")
		return
	}
	p := rr.str
	trailer := p[len(p) - 10:]
	body := p[:len(p) - 10]
	version_ok := trailer[0] == 12 && trailer[1] == 0
	switch body[0] {
	case 17:
		n, enc, j, ok := rdb_len(body, 1)
		ok = ok && !enc && j + n == len(body)
		mine := zt.listpack_bytes(z)
		same := ok && version_ok && z.encoding == .Listpack && string(body[j:]) == string(mine)
		record(cs, idx, args, .Dump_Listpack, same, body[j:] if ok else body, mine, "listpack bytes differ")
	case 5:
		count, enc, j, ok := rdb_len(body, 1)
		ok = ok && !enc
		got := make([dynamic]Pair, context.temp_allocator)
		for _ in 0 ..< count {
			if !ok {
				break
			}
			m: string
			m, j, ok = rdb_string(body, j)
			if !ok || j + 8 > len(body) {
				ok = false
				break
			}
			append(&got, Pair{m, le_u64(body[j:j + 8])})
			j += 8
		}
		ok = ok && j == len(body) && version_ok && z.encoding == .Skiplist
		want := model_pairs(z)
		slice.sort_by(got[:], proc(a, b: Pair) -> bool {return a.member < b.member})
		slice.sort_by(want[:], proc(a, b: Pair) -> bool {return a.member < b.member})
		ok = ok && len(got) == len(want)
		for i := 0; ok && i < len(got); i += 1 {
			ok = got[i].member == want[i].member && got[i].bits == want[i].bits
		}
		gs := make([dynamic]string, context.temp_allocator)
		ws := make([dynamic]string, context.temp_allocator)
		for it in got {
			append(&gs, fmt.tprintf("%q=%x", it.member, it.bits))
		}
		for it in want {
			append(&ws, fmt.tprintf("%q=%x", it.member, it.bits))
		}
		record(cs, idx, args, .Dump_Skiplist, ok, transmute([]u8)strings.join(gs[:], ",", context.temp_allocator), transmute([]u8)strings.join(ws[:], ",", context.temp_allocator), "skiplist contents differ")
	case:
		record(cs, idx, args, .Exact, false, rr.raw, nil, "unexpected rdb type")
	}
}

double_text :: proc(v: f64) -> string {
	buf: [zt.D2STRING_MAX]u8
	n := zt.d2string(buf[:], v)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

check_zrandmember :: proc(z: zt.Zset, r: Reply, count: i64, withscores: bool, resp: int) -> (ok: bool, why: string) {
	pairs := model_pairs(z)
	scores := make(map[string]string, 16, context.temp_allocator)
	order := make(map[string]int, 16, context.temp_allocator)
	for p, i in pairs {
		scores[p.member] = double_text(transmute(f64)p.bits)
		order[p.member] = i
	}
	size := len(pairs)
	uniq := count > 0
	n := int(count) if uniq else int(-count)
	expected := n if !uniq || n == 1 else min(n, size)
	if r.kind != .Array {
		return false, "not an array"
	}
	got_m := make([dynamic]string, context.temp_allocator)
	got_s := make([dynamic]string, context.temp_allocator)
	if withscores && resp == 2 {
		if len(r.elems) != expected * 2 {
			return false, "wrong flat length"
		}
		for i := 0; i < len(r.elems); i += 2 {
			append(&got_m, string(r.elems[i].str))
			append(&got_s, string(r.elems[i + 1].str))
		}
	} else if withscores {
		if len(r.elems) != expected {
			return false, "wrong resp3 length"
		}
		for e in r.elems {
			if e.kind != .Array || len(e.elems) != 2 || e.elems[0].kind != .Bulk || e.elems[1].kind != .Double {
				return false, "resp3 pair shape"
			}
			append(&got_m, string(e.elems[0].str))
			append(&got_s, string(e.elems[1].str))
		}
	} else {
		if len(r.elems) != expected {
			return false, "wrong length"
		}
		for e in r.elems {
			if e.kind != .Bulk {
				return false, "not bulk"
			}
			append(&got_m, string(e.str))
		}
	}
	for mm, i in got_m {
		s, member := scores[mm]
		if !member {
			return false, "not a member"
		}
		if withscores && got_s[i] != s {
			return false, "score mismatch"
		}
	}
	if uniq && n > 1 {
		seen := make(map[string]bool, 16, context.temp_allocator)
		for mm in got_m {
			if mm in seen {
				return false, "duplicate in unique result"
			}
			seen[mm] = true
		}
		if z.encoding == .Listpack && n < size {
			for i in 1 ..< len(got_m) {
				if order[got_m[i]] <= order[got_m[i - 1]] {
					return false, "listpack order not preserved"
				}
			}
		}
	}
	return true, ""
}

compare_zrandmember :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	z, found, wrong := lookup_zset(&cs.m, args[1])
	mine := strings.clone(string(exec(&cs.m, args)), context.temp_allocator)
	if len(args) >= 3 {
		count, withscores, err := zt.parse_zrandmember(args)
		if err != .None || !found || wrong || count == 0 || (count > 1 && int(count) >= zt.length(z)) {
			record(cs, idx, args, .Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
			return
		}
		mr, _, mok := parse_reply(transmute([]u8)mine, 0, context.temp_allocator)
		rok, rwhy := check_zrandmember(z, rr, count, withscores, cs.m.resp)
		mok2, mwhy := check_zrandmember(z, mr, count, withscores, cs.m.resp)
		record(cs, idx, args, .Zrandmember_Rules, rok && mok && mok2, rr.raw, transmute([]u8)mine, fmt.tprintf("redis:%s model:%s", rwhy, mwhy))
		return
	}
	if !found || wrong {
		record(cs, idx, args, .Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
		return
	}
	pairs := model_pairs(z)
	ok := false
	for p in pairs {
		if rr.kind == .Bulk && string(rr.str) == p.member {
			ok = true
		}
	}
	record(cs, idx, args, .Zrandmember_Rules, ok, rr.raw, transmute([]u8)mine)
}

scan_pages_model :: proc(m: ^Model, args: [][]u8) -> []u8 {
	pages := make([dynamic]u8, context.temp_allocator)
	cur := make([][]u8, len(args), context.temp_allocator)
	copy(cur, args)
	count := 0
	for count < 100000 {
		page := strings.clone(string(exec(m, cur)), context.temp_allocator)
		append(&pages, page)
		count += 1
		r, _, ok := parse_reply(transmute([]u8)page, 0, context.temp_allocator)
		if !ok || r.kind != .Array || len(r.elems) != 2 || string(r.elems[0].str) == "0" {
			break
		}
		cur[2] = r.elems[0].str
	}
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, fmt.tprintf("*%d\r\n", count))
	append(&out, ..pages[:])
	return out[:]
}

scan_union_ok :: proc(wrapper: Reply, z: zt.Zset, opts: ht.Scan_Options, complete: bool) -> (ok: bool, why: string) {
	expected := make(map[string]string, 16, context.temp_allocator)
	for p in model_pairs(z) {
		if !opts.use_pattern || ht.matches_pattern(opts.pattern, transmute([]u8)p.member, false) {
			buf: [zt.G17_MAX]u8
			n := zt.format_g17(buf[:], transmute(f64)p.bits)
			expected[p.member] = strings.clone(string(buf[:n]), context.temp_allocator)
		}
	}
	seen := make(map[string]bool, 16, context.temp_allocator)
	if wrapper.kind != .Array || len(wrapper.elems) == 0 {
		return false, "bad wrapper"
	}
	for page, pi in wrapper.elems {
		if page.kind != .Array || len(page.elems) != 2 || page.elems[0].kind != .Bulk || page.elems[1].kind != .Array {
			return false, "bad page"
		}
		last := pi == len(wrapper.elems) - 1
		if (string(page.elems[0].str) == "0") != last {
			return false, "cursor sequence"
		}
		els := page.elems[1].elems
		if len(els) % 2 != 0 {
			return false, "odd page"
		}
		for i := 0; i < len(els); i += 2 {
			mm := string(els[i].str)
			s, member := expected[mm]
			if !member {
				return false, "unexpected member"
			}
			if string(els[i + 1].str) != s {
				return false, "score text mismatch"
			}
			seen[mm] = true
		}
	}
	if complete && len(seen) != len(expected) {
		return false, "missed members"
	}
	return true, ""
}

compare_zscan :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	z, found, wrong := lookup_zset(&cs.m, args[1])
	mine := scan_pages_model(&cs.m, args)
	start, cok := ht.parse_scan_cursor(args[2])
	opts, oerr := ht.parse_scan_options(args[3:], false)
	if !found || wrong || !cok || oerr != .None || z.encoding != .Skiplist {
		record(cs, idx, args, .Zscan_Exact, string(mine) == string(rr.raw), rr.raw, mine)
		return
	}
	mr, _, _ := parse_reply(mine, 0, context.temp_allocator)
	rok, rwhy := scan_union_ok(rr, z, opts, start == 0)
	mok, mwhy := scan_union_ok(mr, z, opts, start == 0)
	record(cs, idx, args, .Zscan_Union, rok && mok, rr.raw, mine, fmt.tprintf("redis:%s model:%s", rwhy, mwhy))
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
			if upper == "ZSCAN" {
				mine := fmt.tprintf("*1\r\n%s", string(exec(&cs.m, args)))
				record(&cs, idx, args, .Zscan_Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
				free_all(context.temp_allocator)
				continue
			}
			upper = ""
		}
		switch upper {
		case "DUMP":
			compare_dump(&cs, idx, args, rr)
		case "HELLO":
			exec(&cs.m, args)
			record(&cs, idx, args, .Ignored, true, nil, nil)
		case "ZSCAN":
			compare_zscan(&cs, idx, args, rr)
		case "ZRANDMEMBER":
			compare_zrandmember(&cs, idx, args, rr)
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
	fmt.println("command                  count   mismatches")
	total := 0
	for l in labels {
		st := cs.stats[l]
		total += st.total
		fmt.printfln("%-24s %-7d %d", l, st.total, st.mismatch)
	}
	fmt.printfln("%-24s %-7d %d", "TOTAL", total, cs.mismatches)
	fmt.println("comparison modes:")
	for mode in Mode {
		fmt.printfln("  %-20v %d", mode, cs.modes[mode])
	}
	for k in cs.stats {
		delete(k)
	}
	delete(cs.stats)
	model_destroy(&cs.m)
	delete(cmds)
	delete(script)
	delete(redis)
	return cs.mismatches == 0
}

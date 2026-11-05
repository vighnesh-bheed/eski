package settype_harness

import ht "../../src/hashtype"
import lp "../../src/listpack"
import st "../../src/settype"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Stat :: struct {
	total:    int,
	mismatch: int,
}

Mode :: enum {
	Exact,
	Unordered,
	Dump_Intset,
	Dump_Listpack,
	Dump_Listpack_Unordered,
	Dump_Hashtable,
	Dump_Missing,
	Spop_Rules,
	Srandmember_Rules,
	Sscan_Exact,
	Sscan_Unordered,
	Sscan_Union,
	Dump_Resync,
	Encoding_Resync,
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

short :: proc(b: []u8, n := 160) -> string {
	s := fmt.tprintf("%q", string(b[:min(len(b), n)]))
	if len(b) > n {
		return fmt.tprintf("%s...(%d bytes)", s, len(b))
	}
	return s
}

record :: proc(cs: ^Compare_State, idx: int, args: [][]u8, mode: Mode, ok: bool, redis: []u8, mine: []u8, why: string = "") {
	label := label_of(args)
	stat := cs.stats[label]
	stat.total += 1
	cs.modes[mode] += 1
	if !ok {
		stat.mismatch += 1
		cs.mismatches += 1
		if cs.shown < 25 {
			cs.shown += 1
			parts := make([dynamic]string, context.temp_allocator)
			for a in args {
				append(&parts, short(a, 40))
			}
			fmt.eprintfln("MISMATCH #%d [%v] %s %s", idx, mode, strings.join(parts[:], " ", context.temp_allocator), why)
			fmt.eprintfln("  reply: %s", short(redis))
			fmt.eprintfln("  model: %s", short(mine))
		}
	}
	if label not_in cs.stats {
		cs.stats[strings.clone(label)] = stat
	} else {
		cs.stats[label] = stat
	}
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

listpack_strings :: proc(b: []u8) -> (out: [dynamic]string, ok: bool) {
	out = make([dynamic]string, context.temp_allocator)
	if len(b) < 7 || !lp.lp_validate_integrity(raw_data(b), u64(len(b)), true, nil, nil) {
		return out, false
	}
	p := lp.lp_first(raw_data(b))
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	for p != nil {
		e := lp.lp_get_entry(p)
		append(&out, strings.clone(string(lp.entry_bytes(e, &buf)), context.temp_allocator))
		p = lp.lp_next(raw_data(b), p)
	}
	return out, true
}

same_sorted :: proc(a, b: [dynamic]string) -> bool {
	if len(a) != len(b) {
		return false
	}
	slice.sort(a[:])
	slice.sort(b[:])
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

compare_dump :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	k := lookup(&cs.m, args[1])
	if rr.kind == .Null {
		record(cs, idx, args, .Dump_Missing, k == nil, rr.raw, nil, "redis has no key")
		return
	}
	if rr.kind != .Bulk || len(rr.str) < 11 {
		record(cs, idx, args, .Exact, false, rr.raw, nil, "unexpected dump reply")
		return
	}
	if k == nil || k.kind != .Set {
		record(cs, idx, args, .Exact, false, rr.raw, nil, "model has no set")
		return
	}
	s := k.set
	p := rr.str
	trailer := p[len(p) - 10:]
	body := p[:len(p) - 10]
	version_ok := trailer[0] == 12 && trailer[1] == 0
	if k.ambiguous {
		resync_from_dump(cs, idx, args, k, body, version_ok)
		return
	}
	switch body[0] {
	case 11:
		n, enc, j, ok := rdb_len(body, 1)
		ok = ok && !enc && j + n == len(body) && version_ok && s.encoding == .Intset
		mine := st.raw_bytes(s)
		got := body[j:] if ok else body
		record(cs, idx, args, .Dump_Intset, ok && string(got) == string(mine), got, mine, "intset bytes differ")
	case 20:
		n, enc, j, ok := rdb_len(body, 1)
		ok = ok && !enc && j + n == len(body) && version_ok && s.encoding == .Listpack
		mine := st.raw_bytes(s)
		got := body[j:] if ok else body
		if !k.tainted {
			record(cs, idx, args, .Dump_Listpack, ok && string(got) == string(mine), got, mine, "listpack bytes differ")
			return
		}
		a, aok := listpack_strings(got)
		b, bok := listpack_strings(mine)
		record(cs, idx, args, .Dump_Listpack_Unordered, ok && aok && bok && len(got) == len(mine) && same_sorted(a, b), got, mine, "listpack contents differ")
	case 2:
		count, enc, j, ok := rdb_len(body, 1)
		ok = ok && !enc && version_ok
		got := make([dynamic]string, context.temp_allocator)
		for _ in 0 ..< count {
			if !ok {
				break
			}
			v: string
			v, j, ok = rdb_string(body, j)
			append(&got, v)
		}
		ok = ok && j == len(body) && s.encoding == .Hashtable
		want := set_members(s)
		ok = ok && same_sorted(got, want)
		record(cs, idx, args, .Dump_Hashtable, ok, transmute([]u8)strings.join(got[:], ",", context.temp_allocator), transmute([]u8)strings.join(want[:], ",", context.temp_allocator), "hashtable contents differ")
	case:
		record(cs, idx, args, .Exact, false, rr.raw, nil, "unexpected rdb type")
	}
}

resync_from_dump :: proc(cs: ^Compare_State, idx: int, args: [][]u8, k: ^Key, body: []u8, version_ok: bool) {
	want := set_members(k.set)
	switch body[0] {
	case 20:
		n, enc, j, ok := rdb_len(body, 1)
		ok = ok && !enc && j + n == len(body) && version_ok
		got, gok := listpack_strings(body[j:] if ok else body)
		ok = ok && gok && same_sorted(got, want)
		record(cs, idx, args, .Dump_Resync, ok, body, nil, "listpack contents differ")
		if ok {
			ns := st.create_listpack()
			lp.lp_free(ns.data)
			ns.data = lp.lp_dup(raw_data(body[j:]))
			st.destroy(k.set)
			k.set = ns
			k.tainted = false
		}
	case 2:
		count, enc, j, ok := rdb_len(body, 1)
		ok = ok && !enc && version_ok
		got := make([dynamic]string, context.temp_allocator)
		for _ in 0 ..< count {
			if !ok {
				break
			}
			v: string
			v, j, ok = rdb_string(body, j)
			append(&got, v)
		}
		ok = ok && j == len(body) && same_sorted(got, want)
		record(cs, idx, args, .Dump_Resync, ok, body, nil, "hashtable contents differ")
		if ok && k.set.encoding != .Hashtable {
			st.convert(k.set, .Hashtable)
		}
	case:
		record(cs, idx, args, .Dump_Resync, false, body, nil, "unexpected rdb type")
	}
	k.ambiguous = false
}

resync_encoding :: proc(cs: ^Compare_State, idx: int, args: [][]u8, k: ^Key, rr: Reply) {
	got := string(rr.str) if rr.kind == .Bulk else ""
	ok := got == "listpack" || got == "hashtable"
	record(cs, idx, args, .Encoding_Resync, ok, rr.raw, nil, "ambiguous encoding must be listpack or hashtable")
	if ok {
		target := st.Encoding.Listpack if got == "listpack" else st.Encoding.Hashtable
		if k.set.encoding != target {
			st.convert(k.set, target)
			k.tainted = true
		}
	}
	k.ambiguous = false
}

flat_strings :: proc(r: Reply, out: ^[dynamic]string) -> bool {
	for e in r.elems {
		if e.kind != .Bulk {
			return false
		}
		append(out, string(e.str))
	}
	return true
}

compare_unordered :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply, mine: []u8) {
	mr, _, mok := parse_reply(mine, 0, context.temp_allocator)
	a := make([dynamic]string, context.temp_allocator)
	b := make([dynamic]string, context.temp_allocator)
	ok := mok && mr.kind == rr.kind && len(mr.elems) == len(rr.elems) && flat_strings(rr, &a) && flat_strings(mr, &b)
	ok = ok && same_sorted(a, b)
	record(cs, idx, args, .Unordered, ok, rr.raw, mine)
}

member_index :: proc(s: st.Set) -> map[string]int {
	idx := make(map[string]int, 16, context.temp_allocator)
	for v, i in set_members(s) {
		idx[v] = i
	}
	return idx
}

check_popped :: proc(r: Reply, k: ^Key, count: int, uniq: bool, want: Kind) -> (got: [dynamic]string, ok: bool, why: string) {
	got = make([dynamic]string, context.temp_allocator)
	if r.kind != want {
		return got, false, "wrong reply type"
	}
	if len(r.elems) != count {
		return got, false, "wrong length"
	}
	if !flat_strings(r, &got) {
		return got, false, "not bulk"
	}
	idx := member_index(k.set)
	for g in got {
		if g not_in idx {
			return got, false, "not a member"
		}
	}
	if !uniq {
		return got, true, ""
	}
	seen := make(map[string]bool, 16, context.temp_allocator)
	for g in got {
		if g in seen {
			return got, false, "duplicate"
		}
		seen[g] = true
	}
	if k.set.encoding == .Listpack && !k.tainted {
		for i in 1 ..< len(got) {
			if idx[got[i]] <= idx[got[i - 1]] {
				return got, false, "listpack order not preserved"
			}
		}
	}
	return got, true, ""
}

compare_spop :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	mine := strings.clone(string(exec(&cs.m, args)), context.temp_allocator)
	if !cs.m.random {
		if cs.m.unstable {
			compare_unordered(cs, idx, args, rr, transmute([]u8)mine)
		} else {
			record(cs, idx, args, .Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
		}
		return
	}
	k := lookup(&cs.m, args[1])
	if len(args) == 2 {
		ok := rr.kind == .Bulk && st.is_member(k.set, rr.str)
		record(cs, idx, args, .Spop_Rules, ok, rr.raw, nil, "not a member")
		if ok {
			one := [1][]u8{rr.str}
			spop_apply(&cs.m, args[1], one[:], 1)
		}
		return
	}
	count, _ := spop_count_arg(args[2])
	size := st.size(k.set)
	got, ok, why := check_popped(rr, k, int(count), true, .Set if cs.m.resp >= 3 else .Array)
	if ok && k.set.encoding == .Intset && (size - int(count)) * SPOP_KEEP_FACTOR <= int(count) {
		for i in 1 ..< len(got) {
			a, _ := strconv.parse_i64(got[i - 1])
			b, _ := strconv.parse_i64(got[i])
			if b <= a {
				ok = false
				why = "intset order not preserved"
			}
		}
	}
	record(cs, idx, args, .Spop_Rules, ok, rr.raw, nil, why)
	if ok {
		popped := make([][]u8, len(got), context.temp_allocator)
		for g, i in got {
			popped[i] = transmute([]u8)g
		}
		spop_apply(&cs.m, args[1], popped, int(count))
	}
}

compare_srandmember :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	mine := strings.clone(string(exec(&cs.m, args)), context.temp_allocator)
	if !cs.m.random {
		if cs.m.unstable {
			compare_unordered(cs, idx, args, rr, transmute([]u8)mine)
		} else {
			record(cs, idx, args, .Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
		}
		return
	}
	k := lookup(&cs.m, args[1])
	if len(args) == 2 {
		ok := rr.kind == .Bulk && st.is_member(k.set, rr.str)
		record(cs, idx, args, .Srandmember_Rules, ok, rr.raw, nil, "not a member")
		return
	}
	l, _ := parse_i64(args[2])
	uniq := l > 1
	n := int(l) if l > 0 else int(-l)
	_, ok, why := check_popped(rr, k, n, uniq, .Array)
	record(cs, idx, args, .Srandmember_Rules, ok, rr.raw, nil, why)
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

scan_union_ok :: proc(wrapper: Reply, s: st.Set, opts: ht.Scan_Options, full: bool) -> (ok: bool, why: string) {
	expected := make(map[string]bool, 16, context.temp_allocator)
	for v in set_members(s) {
		if !opts.use_pattern || ht.matches_pattern(opts.pattern, transmute([]u8)v, false) {
			expected[v] = true
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
		for e in page.elems[1].elems {
			f := string(e.str)
			if e.kind != .Bulk || f not_in expected {
				return false, "unexpected element"
			}
			seen[f] = true
		}
	}
	if full && len(seen) != len(expected) {
		return false, "missed elements"
	}
	return true, ""
}

compare_sscan :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	k, found, wrong := lookup_set(&cs.m, args[1])
	mine := scan_pages_model(&cs.m, args)
	cursor, cok := ht.parse_scan_cursor(args[2])
	opts, oerr := ht.parse_scan_options(args[3:], false)
	if !found || wrong || !cok || oerr != .None {
		record(cs, idx, args, .Sscan_Exact, string(mine) == string(rr.raw), rr.raw, mine)
		return
	}
	if k.set.encoding == .Hashtable {
		mr, _, _ := parse_reply(mine, 0, context.temp_allocator)
		rok, rwhy := scan_union_ok(rr, k.set, opts, cursor == 0)
		mok, mwhy := scan_union_ok(mr, k.set, opts, cursor == 0)
		record(cs, idx, args, .Sscan_Union, rok && mok, rr.raw, mine, fmt.tprintf("reply:%s model:%s", rwhy, mwhy))
		return
	}
	if !k.tainted {
		record(cs, idx, args, .Sscan_Exact, string(mine) == string(rr.raw), rr.raw, mine)
		return
	}
	mr, _, _ := parse_reply(mine, 0, context.temp_allocator)
	ok := rr.kind == .Array && len(rr.elems) == 1 && mr.kind == .Array && len(mr.elems) == 1
	if ok {
		a := make([dynamic]string, context.temp_allocator)
		b := make([dynamic]string, context.temp_allocator)
		rp := rr.elems[0]
		mp := mr.elems[0]
		ok = len(rp.elems) == 2 && len(mp.elems) == 2 && string(rp.elems[0].str) == "0" && flat_strings(rp.elems[1], &a) && flat_strings(mp.elems[1], &b) && same_sorted(a, b)
	}
	record(cs, idx, args, .Sscan_Unordered, ok, rr.raw, mine)
}

run_compare :: proc(dir: string, server := false) -> bool {
	replies_name := "eski.out" if server else "redis.out"
	script, serr := os.read_entire_file(fmt.tprintf("%s/script.resp", dir), context.allocator)
	if serr != nil {
		fmt.eprintln("cannot read script.resp")
		return false
	}
	replies, rerr := os.read_entire_file(fmt.tprintf("%s/%s", dir, replies_name), context.allocator)
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
	saved := [3]int{st.set_max_intset_entries, st.set_max_listpack_entries, st.set_max_listpack_value}
	pos := 0
	for args, idx in cmds {
		rr, next, rok := parse_reply(replies, pos, context.temp_allocator)
		if !rok {
			fmt.eprintfln("cannot parse reply %d at byte %d", idx, pos)
			return false
		}
		pos = next
		upper := strings.to_upper(string(args[0]), context.temp_allocator)
		arity, known := arity_of(lower_name(args[0]))
		if !known || (arity > 0 && len(args) != arity) || (arity < 0 && len(args) < -arity) {
			if upper == "SSCAN" {
				mine := fmt.tprintf("*1\r\n%s", string(exec(&cs.m, args)))
				record(&cs, idx, args, .Sscan_Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
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
		case "SSCAN":
			compare_sscan(&cs, idx, args, rr)
		case "SPOP":
			compare_spop(&cs, idx, args, rr)
		case "SRANDMEMBER":
			compare_srandmember(&cs, idx, args, rr)
		case "OBJECT":
			if len(args) == 3 {
				if k := lookup(&cs.m, args[2]); k != nil && k.kind == .Set && k.ambiguous {
					resync_encoding(&cs, idx, args, k, rr)
					break
				}
			}
			mine := strings.clone(string(exec(&cs.m, args)), context.temp_allocator)
			record(&cs, idx, args, .Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
		case:
			mine := strings.clone(string(exec(&cs.m, args)), context.temp_allocator)
			if cs.m.unstable {
				compare_unordered(&cs, idx, args, rr, transmute([]u8)mine)
			} else {
				record(&cs, idx, args, .Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
			}
		}
		free_all(context.temp_allocator)
	}
	if pos != len(replies) {
		fmt.eprintfln("%s has %d trailing bytes", replies_name, len(replies) - pos)
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
		stat := cs.stats[l]
		total += stat.total
		fmt.printfln("%-24s %-7d %d", l, stat.total, stat.mismatch)
	}
	fmt.printfln("%-24s %-7d %d", "TOTAL", total, cs.mismatches)
	fmt.println("comparison modes:")
	for mode in Mode {
		fmt.printfln("  %-24v %d", mode, cs.modes[mode])
	}
	for k in cs.stats {
		delete(k)
	}
	delete(cs.stats)
	model_destroy(&cs.m)
	delete(cmds)
	delete(script)
	delete(replies)
	st.set_max_intset_entries = saved[0]
	st.set_max_listpack_entries = saved[1]
	st.set_max_listpack_value = saved[2]
	return cs.mismatches == 0
}

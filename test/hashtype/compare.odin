package hashtype_harness

import ht "../../src/hashtype"
import lp "../../src/listpack"
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
	Dump_Listpack,
	Dump_Listpack_Ex,
	Dump_Listpack_Ex_Tolerant,
	Dump_Hashtable,
	Dump_Hashtable_Ttl,
	Dump_Missing,
	Ttl_Exact,
	Ttl_Tolerant,
	Unordered,
	Hrandfield_Rules,
	Hscan_Exact,
	Hscan_Union,
	Ignored,
}

TOLERANCE_MS :: 250
TOLERANCE_S :: 1

Compare_State :: struct {
	now:        u64,
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

value_string :: proc(v: ht.Value) -> string {
	buf: [lp.LP_INTBUF_SIZE]u8
	return strings.clone(string(ht.value_bytes(v, &buf)), context.temp_allocator)
}

model_pairs :: proc(h: ht.Hash, now: u64 = 0) -> (fields: [dynamic]string, values: map[string]string) {
	fields = make([dynamic]string, context.temp_allocator)
	values = make(map[string]string, 16, context.temp_allocator)
	it := ht.iterator(h)
	for ht.next(&it) {
		if now != 0 && ht.current_expire(&it) < now {
			continue
		}
		f := value_string(ht.current_field(&it))
		append(&fields, f)
		values[f] = value_string(ht.current_value(&it))
	}
	return
}

near :: proc(a, b: i64, tol: i64) -> bool {
	d := a - b
	return d <= tol && d >= -tol
}

lpex_tolerant_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) || len(a) < 7 {
		return false
	}
	if !lp.lp_validate_integrity(raw_data(a), u64(len(a)), true, nil, nil) || !lp.lp_validate_integrity(raw_data(b), u64(len(b)), true, nil, nil) {
		return false
	}
	pa := lp.lp_first(raw_data(a))
	pb := lp.lp_first(raw_data(b))
	idx := 0
	for pa != nil && pb != nil {
		ea := lp.lp_get_entry(pa)
		eb := lp.lp_get_entry(pb)
		if idx % 3 == 2 {
			if ea.sval != nil || eb.sval != nil {
				return false
			}
			if ea.lval != eb.lval && (ea.lval == 0 || eb.lval == 0 || !near(ea.lval, eb.lval, TOLERANCE_MS)) {
				return false
			}
		} else {
			fa: [lp.LP_INTBUF_SIZE]u8
			fb: [lp.LP_INTBUF_SIZE]u8
			if string(lp.entry_bytes(ea, &fa)) != string(lp.entry_bytes(eb, &fb)) {
				return false
			}
		}
		pa = lp.lp_next(raw_data(a), pa)
		pb = lp.lp_next(raw_data(b), pb)
		idx += 1
	}
	return pa == nil && pb == nil
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
	p := rr.str
	if k == nil || k.kind != .Hash {
		record(cs, idx, args, .Exact, false, rr.raw, nil, "model has no hash")
		return
	}
	h := k.hash
	trailer := p[len(p) - 10:]
	body := p[:len(p) - 10]
	version_ok := trailer[0] == 12 && trailer[1] == 0
	switch body[0] {
	case 16:
		n, enc, j, ok := rdb_len(body, 1)
		ok = ok && !enc && j + n == len(body)
		mine := ht.listpack_bytes(h)
		same := ok && version_ok && h.encoding == .Listpack && string(body[j:]) == string(mine)
		record(cs, idx, args, .Dump_Listpack, same, body[j:] if ok else body, mine, "listpack bytes differ")
	case 25:
		if len(body) < 10 || h.encoding != .Listpack_Ex {
			record(cs, idx, args, .Dump_Listpack_Ex, false, body, nil, "model is not listpackex")
			return
		}
		rmin := le_u64(body[1:9])
		n, enc, j, ok := rdb_len(body, 9)
		ok = ok && !enc && j + n == len(body) && version_ok
		mine := ht.listpack_bytes(h)
		mmin := ht.dump_min_expire(h)
		got := body[j:] if ok else body
		if ok && rmin == mmin && string(got) == string(mine) {
			record(cs, idx, args, .Dump_Listpack_Ex, true, got, mine)
			return
		}
		tol := ok && (rmin == mmin || (rmin != 0 && mmin != 0 && near(i64(rmin), i64(mmin), TOLERANCE_MS))) && lpex_tolerant_equal(got, mine)
		record(cs, idx, args, .Dump_Listpack_Ex_Tolerant, tol, transmute([]u8)fmt.tprintf("min=%d %x", rmin, got), transmute([]u8)fmt.tprintf("min=%d %x", mmin, mine), "listpackex differs")
	case 4, 24:
		with_ttl := body[0] == 24
		pos := 1
		rmin: u64 = 0
		if with_ttl {
			rmin = le_u64(body[1:9])
			pos = 9
		}
		count, enc, j, ok := rdb_len(body, pos)
		ok = ok && !enc
		Item :: struct {
			f, v:   string,
			expire: i64,
		}
		got := make([dynamic]Item, context.temp_allocator)
		for _ in 0 ..< count {
			if !ok {
				break
			}
			ttl := 0
			if with_ttl {
				ttl, enc, j, ok = rdb_len(body, j)
				ok = ok && !enc
				if !ok {
					break
				}
			}
			f, v: string
			f, j, ok = rdb_string(body, j)
			if !ok {
				break
			}
			v, j, ok = rdb_string(body, j)
			append(&got, Item{f, v, i64(rmin) + i64(ttl) - 1 if ttl != 0 else -1})
		}
		ok = ok && j == len(body) && version_ok && h.encoding == .Hashtable
		want := make([dynamic]Item, context.temp_allocator)
		mmin := ht.min_expire(h, true)
		if h.encoding == .Hashtable {
			it := ht.iterator(h)
			for ht.next(&it) {
				e := ht.current_expire(&it)
				append(&want, Item{value_string(ht.current_field(&it)), value_string(ht.current_value(&it)), i64(e) if e != ht.EB_EXPIRE_TIME_INVALID else -1})
			}
		}
		ok = ok && with_ttl == (mmin != ht.EB_EXPIRE_TIME_INVALID)
		if with_ttl {
			ok = ok && near(i64(rmin), i64(mmin), TOLERANCE_MS)
		}
		slice.sort_by(got[:], proc(a, b: Item) -> bool {return a.f < b.f})
		slice.sort_by(want[:], proc(a, b: Item) -> bool {return a.f < b.f})
		ok = ok && len(got) == len(want)
		for i := 0; ok && i < len(got); i += 1 {
			ok = got[i].f == want[i].f && got[i].v == want[i].v && (got[i].expire == want[i].expire || (got[i].expire > 0 && want[i].expire > 0 && near(got[i].expire, want[i].expire, TOLERANCE_MS)))
		}
		gs := make([dynamic]string, context.temp_allocator)
		ws := make([dynamic]string, context.temp_allocator)
		for it in got {
			append(&gs, fmt.tprintf("%q=%q@%d", it.f, it.v, it.expire))
		}
		for it in want {
			append(&ws, fmt.tprintf("%q=%q@%d", it.f, it.v, it.expire))
		}
		record(cs, idx, args, .Dump_Hashtable_Ttl if with_ttl else .Dump_Hashtable, ok, transmute([]u8)strings.join(gs[:], ",", context.temp_allocator), transmute([]u8)strings.join(ws[:], ",", context.temp_allocator), "hashtable contents differ")
	case:
		record(cs, idx, args, .Exact, false, rr.raw, nil, "unexpected rdb type")
	}
}

compare_ttl :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply, seconds: bool) {
	mine := strings.clone(string(exec(&cs.m, args, cs.now)), context.temp_allocator)
	if mine == string(rr.raw) {
		record(cs, idx, args, .Ttl_Exact, true, rr.raw, transmute([]u8)mine)
		return
	}
	mr, _, mok := parse_reply(transmute([]u8)mine, 0, context.temp_allocator)
	ok := mok && mr.kind == .Array && rr.kind == .Array && len(mr.elems) == len(rr.elems)
	tol: i64 = TOLERANCE_S if seconds else TOLERANCE_MS
	for i := 0; ok && i < len(mr.elems); i += 1 {
		a, b := rr.elems[i], mr.elems[i]
		ok = a.kind == .Integer && b.kind == .Integer && (a.num == b.num || (a.num >= 0 && b.num >= 0 && near(a.num, b.num, tol)))
	}
	record(cs, idx, args, .Ttl_Tolerant, ok, rr.raw, transmute([]u8)mine)
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

compare_unordered :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply, mine: []u8, pairs: bool) {
	mr, _, mok := parse_reply(mine, 0, context.temp_allocator)
	a := make([dynamic]string, context.temp_allocator)
	b := make([dynamic]string, context.temp_allocator)
	ok := mok && mr.kind == rr.kind && len(mr.elems) == len(rr.elems) && flat_strings(rr, &a) && flat_strings(mr, &b)
	if ok && pairs {
		pa := make([dynamic]string, context.temp_allocator)
		pb := make([dynamic]string, context.temp_allocator)
		for i := 0; i + 1 < len(a); i += 2 {
			append(&pa, fmt.tprintf("%q=%q", a[i], a[i + 1]))
			append(&pb, fmt.tprintf("%q=%q", b[i], b[i + 1]))
		}
		a, b = pa, pb
	}
	slice.sort(a[:])
	slice.sort(b[:])
	for i := 0; ok && i < len(a); i += 1 {
		ok = a[i] == b[i]
	}
	record(cs, idx, args, .Unordered, ok, rr.raw, mine)
}

check_hrandfield :: proc(h: ht.Hash, r: Reply, count: i64, with_values: bool, resp: int) -> (ok: bool, why: string) {
	fields, values := model_pairs(h)
	order := make(map[string]int, 16, context.temp_allocator)
	for f, i in fields {
		order[f] = i
	}
	size := len(fields)
	uniq := count > 0
	n := int(count) if uniq else int(-count)
	expected := n if !uniq || n == 1 else min(n, size)
	if r.kind != .Array {
		return false, "not an array"
	}
	got_f := make([dynamic]string, context.temp_allocator)
	got_v := make([dynamic]string, context.temp_allocator)
	if with_values && resp == 2 {
		if len(r.elems) != expected * 2 {
			return false, "wrong flat length"
		}
		for i := 0; i < len(r.elems); i += 2 {
			if r.elems[i].kind != .Bulk || r.elems[i + 1].kind != .Bulk {
				return false, "not bulk"
			}
			append(&got_f, string(r.elems[i].str))
			append(&got_v, string(r.elems[i + 1].str))
		}
	} else if with_values {
		if len(r.elems) != expected {
			return false, "wrong resp3 length"
		}
		for e in r.elems {
			if e.kind != .Array || len(e.elems) != 2 || e.elems[0].kind != .Bulk || e.elems[1].kind != .Bulk {
				return false, "resp3 pair shape"
			}
			append(&got_f, string(e.elems[0].str))
			append(&got_v, string(e.elems[1].str))
		}
	} else {
		if len(r.elems) != expected {
			return false, "wrong length"
		}
		for e in r.elems {
			if e.kind != .Bulk {
				return false, "not bulk"
			}
			append(&got_f, string(e.str))
		}
	}
	for f, i in got_f {
		v, member := values[f]
		if !member {
			return false, "not a member"
		}
		if with_values && got_v[i] != v {
			return false, "value mismatch"
		}
	}
	if uniq && n > 1 {
		seen := make(map[string]bool, 16, context.temp_allocator)
		for f in got_f {
			if f in seen {
				return false, "duplicate in unique result"
			}
			seen[f] = true
		}
		if h.encoding != .Hashtable {
			for i in 1 ..< len(got_f) {
				if order[got_f[i]] <= order[got_f[i - 1]] {
					return false, "listpack order not preserved"
				}
			}
		}
	}
	return true, ""
}

compare_hrandfield :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	h, found, wrong := lookup_hash_read(&cs.m, args[1])
	if len(args) >= 3 {
		a, err := ht.parse_hrandfield_args(args[2:])
		if err == .None && found && !wrong && ht.expire_if_needed(h, cs.now) {
			model_delete_key(&cs.m, args[1])
			found = false
		}
		if err != .None || !found || wrong || a.count == 0 {
			mine := exec(&cs.m, args, cs.now)
			record(cs, idx, args, .Exact, string(mine) == string(rr.raw), rr.raw, mine)
			return
		}
		mine := strings.clone(string(exec(&cs.m, args, cs.now)), context.temp_allocator)
		mr, _, mok := parse_reply(transmute([]u8)mine, 0, context.temp_allocator)
		rok, rwhy := check_hrandfield(h, rr, a.count, a.with_values, cs.m.resp)
		mok2, mwhy := check_hrandfield(h, mr, a.count, a.with_values, cs.m.resp)
		ok := rok && mok && mok2
		if ok && a.count > 0 && int(a.count) >= ht.length(h) && h.encoding != .Hashtable {
			ok = mine == string(rr.raw)
		}
		record(cs, idx, args, .Hrandfield_Rules, ok, rr.raw, transmute([]u8)mine, fmt.tprintf("redis:%s model:%s", rwhy, mwhy))
		return
	}
	if found && !wrong && ht.expire_if_needed(h, cs.now) {
		model_delete_key(&cs.m, args[1])
		found = false
	}
	if !found || wrong {
		mine := exec(&cs.m, args, cs.now)
		record(cs, idx, args, .Exact, string(mine) == string(rr.raw), rr.raw, mine)
		return
	}
	_, values := model_pairs(h)
	mine := strings.clone(string(exec(&cs.m, args, cs.now)), context.temp_allocator)
	mr, _, _ := parse_reply(transmute([]u8)mine, 0, context.temp_allocator)
	ok := rr.kind == .Bulk && string(rr.str) in values && mr.kind == .Bulk && string(mr.str) in values
	record(cs, idx, args, .Hrandfield_Rules, ok, rr.raw, transmute([]u8)mine)
}

scan_pages_model :: proc(m: ^Model, args: [][]u8, now: u64) -> []u8 {
	pages := make([dynamic]u8, context.temp_allocator)
	cur := make([][]u8, len(args), context.temp_allocator)
	copy(cur, args)
	count := 0
	for count < 100000 {
		page := strings.clone(string(exec(m, cur, now)), context.temp_allocator)
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

scan_union_ok :: proc(wrapper: Reply, h: ht.Hash, opts: ht.Scan_Options, now: u64) -> (ok: bool, why: string) {
	fields, values := model_pairs(h, now)
	expected := make(map[string]bool, 16, context.temp_allocator)
	for f in fields {
		if !opts.use_pattern || ht.string_match_len(opts.pattern, transmute([]u8)f, false) {
			expected[f] = true
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
		step := 1 if opts.no_values else 2
		if len(els) % step != 0 {
			return false, "odd page"
		}
		for i := 0; i < len(els); i += step {
			f := string(els[i].str)
			if f not_in expected {
				return false, "unexpected field"
			}
			if !opts.no_values && string(els[i + 1].str) != values[f] {
				return false, "value mismatch"
			}
			seen[f] = true
		}
	}
	if len(seen) != len(expected) {
		return false, "missed fields"
	}
	return true, ""
}

compare_hscan :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	h, found, wrong := lookup_hash_read(&cs.m, args[1])
	enc := h.encoding if found && !wrong else ht.Encoding.Listpack
	mine := scan_pages_model(&cs.m, args, cs.now)
	_, cok := ht.parse_scan_cursor(args[2])
	opts, oerr := ht.parse_scan_options(args[3:], true)
	if !found || wrong || !cok || oerr != .None || enc != .Hashtable {
		record(cs, idx, args, .Hscan_Exact, string(mine) == string(rr.raw), rr.raw, mine)
		return
	}
	mr, _, _ := parse_reply(mine, 0, context.temp_allocator)
	rok, rwhy := scan_union_ok(rr, h, opts, cs.now)
	mok, mwhy := scan_union_ok(mr, h, opts, cs.now)
	record(cs, idx, args, .Hscan_Union, rok && mok, rr.raw, mine, fmt.tprintf("redis:%s model:%s", rwhy, mwhy))
}

run_compare :: proc(dir: string, server := false) -> bool {
	replies_name := "eski.out" if server else "redis.out"
	times_name := "eski_times.txt" if server else "times.txt"
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
	times_raw, terr := os.read_entire_file(fmt.tprintf("%s/%s", dir, times_name), context.allocator)
	if terr != nil {
		fmt.eprintln("cannot read", times_name)
		return false
	}
	defer delete(times_raw)
	times := make([dynamic]u64)
	defer delete(times)
	for line in strings.split_lines(string(times_raw), context.temp_allocator) {
		if len(line) > 0 {
			v, _ := strconv.parse_u64(line)
			append(&times, v)
		}
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
	if len(times) != len(cmds) {
		fmt.eprintfln("times.txt has %d entries for %d commands", len(times), len(cmds))
		return false
	}
	pos := 0
	for args, idx in cmds {
		cs.now = times[idx]
		cs.m.now = cs.now
		run_active_expire(&cs.m)
		rr, next, rok := parse_reply(redis, pos, context.temp_allocator)
		if !rok {
			fmt.eprintfln("cannot parse redis reply %d at byte %d", idx, pos)
			return false
		}
		pos = next
		upper := strings.to_upper(string(args[0]), context.temp_allocator)
		arity, known := arity_of(lower_name(args[0]))
		if !known || (arity > 0 && len(args) != arity) || (arity < 0 && len(args) < -arity) {
			if upper == "HSCAN" {
				mine := fmt.tprintf("*1\r\n%s", string(exec(&cs.m, args, cs.now)))
				record(&cs, idx, args, .Hscan_Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
				free_all(context.temp_allocator)
				continue
			}
			upper = ""
		}
		switch upper {
		case "DUMP":
			compare_dump(&cs, idx, args, rr)
		case "HELLO":
			exec(&cs.m, args, cs.now)
			record(&cs, idx, args, .Ignored, true, nil, nil)
		case "HTTL", "HEXPIRETIME":
			compare_ttl(&cs, idx, args, rr, true)
		case "HPTTL", "HPEXPIRETIME":
			compare_ttl(&cs, idx, args, rr, false)
		case "HSCAN":
			compare_hscan(&cs, idx, args, rr)
		case "HRANDFIELD":
			compare_hrandfield(&cs, idx, args, rr)
		case "HGETALL", "HKEYS", "HVALS":
			h, found, wrong := lookup_hash_read(&cs.m, args[1])
			mine := strings.clone(string(exec(&cs.m, args, cs.now)), context.temp_allocator)
			if found && !wrong && h.encoding == .Hashtable {
				compare_unordered(&cs, idx, args, rr, transmute([]u8)mine, strings.to_upper(string(args[0]), context.temp_allocator) == "HGETALL")
			} else {
				record(&cs, idx, args, .Exact, mine == string(rr.raw), rr.raw, transmute([]u8)mine)
			}
		case:
			mine := exec(&cs.m, args, cs.now)
			record(&cs, idx, args, .Exact, string(mine) == string(rr.raw), rr.raw, mine)
		}
		free_all(context.temp_allocator)
	}
	if pos != len(redis) {
		fmt.eprintfln("redis.out has %d trailing bytes", len(redis) - pos)
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
	fmt.printfln("model active expiry removed %d fields", cs.m.active_fields)
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

package streamtype_harness

import lp "../../src/listpack"
import rx "../../src/rax"
import st "../../src/streamtype"
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
	Time_Tolerant,
	Dump_Stream,
	Dump_Stream_Groups,
	Dump_String,
	Dump_Missing,
	Debug_Object,
	Memory_Usage,
	Ignored,
}

RDB_TYPE_STREAM_LISTPACKS_3 :: 21
TOLERANCE_MS :: 250
RDB_VERSION :: 12
CRC64_POLY :: u64(0x95ac9329ac4bc9b5)

Compare_State :: struct {
	m:            Model,
	stats:        map[string]Stat,
	modes:        [Mode]int,
	nodes:        int,
	multi_node:   int,
	max_nodes:    int,
	dump_bytes:   int,
	tombstones:   int,
	samefields:   int,
	plainfields:  int,
	clock_hints:  int,
	dump_groups:  int,
	dump_consumers: int,
	dump_nacks:   int,
	dump_exact:   int,
	mismatches:   int,
	shown:        int,
}

label_of :: proc(args: [][]u8) -> string {
	name := strings.to_upper(string(args[0]), context.temp_allocator)
	if (name == "OBJECT" || name == "CONFIG" || name == "DEBUG" || name == "MEMORY" || name == "XINFO") && len(args) > 1 {
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
	stt := cs.stats[label]
	stt.total += 1
	cs.modes[mode] += 1
	if !ok {
		stt.mismatch += 1
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
		cs.stats[strings.clone(label)] = stt
	} else {
		cs.stats[label] = stt
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

rdb_put_len :: proc(out: ^[dynamic]u8, n: u64) {
	switch {
	case n < 1 << 6:
		append(out, u8(n))
	case n < 1 << 14:
		append(out, u8(((n >> 8) & 0x3F) | 0x40), u8(n & 0xFF))
	case n <= u64(max(u32)):
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
	rdb_put_len(out, u64(len(s)))
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

expected_stream_dump :: proc(s: st.Stream, nodes: []st.Node_Info) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, RDB_TYPE_STREAM_LISTPACKS_3)
	rdb_put_len(&out, u64(len(nodes)))
	for &n in nodes {
		rdb_put_string(&out, n.key[:])
		rdb_put_string(&out, n.lp)
	}
	rdb_put_len(&out, s.live)
	rdb_put_len(&out, s.top.ms)
	rdb_put_len(&out, s.top.seq)
	rdb_put_len(&out, s.head.ms)
	rdb_put_len(&out, s.head.seq)
	rdb_put_len(&out, s.tomb.ms)
	rdb_put_len(&out, s.tomb.seq)
	rdb_put_len(&out, s.added)
	rdb_put_len(&out, st.group_count(s))
	if s.groups != nil {
		gi: rx.Iterator
		rx.start(&gi, s.groups)
		rx.seek(&gi, "^")
		for rx.next(&gi) {
			cg := (^st.Group)(gi.data)
			rdb_put_string(&out, rx.key(&gi))
			rdb_put_len(&out, cg.delivered.ms)
			rdb_put_len(&out, cg.delivered.seq)
			rdb_put_len(&out, u64(cg.reads))
			rdb_put_len(&out, cg.pending.numele)
			pi: rx.Iterator
			rx.start(&pi, cg.pending)
			rx.seek(&pi, "^")
			for rx.next(&pi) {
				nack := (^st.Delivery)(pi.data)
				append(&out, ..rx.key(&pi))
				rdb_put_ms(&out, nack.sent_ms)
				rdb_put_len(&out, nack.times)
			}
			rx.stop(&pi)
			rdb_put_len(&out, cg.members.numele)
			ci: rx.Iterator
			rx.start(&ci, cg.members)
			rx.seek(&ci, "^")
			for rx.next(&ci) {
				c := (^st.Member)(ci.data)
				rdb_put_string(&out, rx.key(&ci))
				rdb_put_ms(&out, c.seen_ms)
				rdb_put_ms(&out, c.active_ms)
				rdb_put_len(&out, c.owned.numele)
				ki: rx.Iterator
				rx.start(&ki, c.owned)
				rx.seek(&ki, "^")
				for rx.next(&ki) {
					append(&out, ..rx.key(&ki))
				}
				rx.stop(&ki)
			}
			rx.stop(&ci)
		}
		rx.stop(&gi)
	}
	dump_trailer(&out)
	return out[:]
}

rdb_put_ms :: proc(out: ^[dynamic]u8, v: i64) {
	u := u64(v)
	for k in 0 ..< 8 {
		append(out, u8(u >> uint(8 * k)))
	}
}

Dump_Nack :: struct {
	id:    string,
	time:  i64,
	count: u64,
}

Dump_Consumer :: struct {
	name:   string,
	seen:   i64,
	active: i64,
	pel:    [dynamic]string,
}

Dump_Group :: struct {
	name:         string,
	last_ms:      u64,
	last_seq:     u64,
	entries_read: u64,
	pel:          [dynamic]Dump_Nack,
	consumers:    [dynamic]Dump_Consumer,
}

rdb_read_len :: proc(p: []u8, i: int) -> (v: u64, enc: bool, next: int, ok: bool) {
	if i >= len(p) {
		return
	}
	b0 := p[i]
	switch b0 >> 6 {
	case 0:
		return u64(b0 & 0x3F), false, i + 1, true
	case 1:
		if i + 1 >= len(p) {
			return
		}
		return u64(b0 & 0x3F) << 8 | u64(p[i + 1]), false, i + 2, true
	case 2:
		if b0 == 0x80 && i + 5 <= len(p) {
			for k in 1 ..= 4 {
				v = v << 8 | u64(p[i + k])
			}
			return v, false, i + 5, true
		}
		if b0 == 0x81 && i + 9 <= len(p) {
			for k in 1 ..= 8 {
				v = v << 8 | u64(p[i + k])
			}
			return v, false, i + 9, true
		}
		return
	case 3:
		return u64(b0 & 0x3F), true, i + 1, true
	}
	return
}

rdb_read_string :: proc(p: []u8, i: int) -> (str: string, next: int, ok: bool) {
	n, enc, j, lok := rdb_read_len(p, i)
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
	if j + int(n) > len(p) {
		return
	}
	return string(p[j:j + int(n)]), j + int(n), true
}

rdb_read_ms :: proc(p: []u8, i: int) -> (v: i64, next: int, ok: bool) {
	if i + 8 > len(p) {
		return
	}
	u: u64
	for k in 0 ..< 8 {
		u |= u64(p[i + k]) << uint(8 * k)
	}
	return i64(u), i + 8, true
}

parse_stream_payload :: proc(p: []u8) -> (groups_at: int, groups: [dynamic]Dump_Group, ok: bool) {
	groups = make([dynamic]Dump_Group, context.temp_allocator)
	if len(p) < 11 || p[0] != RDB_TYPE_STREAM_LISTPACKS_3 {
		return
	}
	body := p[:len(p) - 10]
	nodes, _, i, lok := rdb_read_len(body, 1)
	if !lok {
		return
	}
	sok: bool
	for _ in 0 ..< nodes {
		_, i, sok = rdb_read_string(body, i)
		if !sok {
			return
		}
		_, i, sok = rdb_read_string(body, i)
		if !sok {
			return
		}
	}
	for _ in 0 ..< 8 {
		_, _, i, lok = rdb_read_len(body, i)
		if !lok {
			return
		}
	}
	groups_at = i
	ngroups: u64
	ngroups, _, i, lok = rdb_read_len(body, i)
	if !lok {
		return
	}
	for _ in 0 ..< ngroups {
		g: Dump_Group
		g.pel = make([dynamic]Dump_Nack, context.temp_allocator)
		g.consumers = make([dynamic]Dump_Consumer, context.temp_allocator)
		g.name, i, sok = rdb_read_string(body, i)
		if !sok {
			return
		}
		g.last_ms, _, i, lok = rdb_read_len(body, i)
		g.last_seq, _, i, lok = rdb_read_len(body, i)
		g.entries_read, _, i, lok = rdb_read_len(body, i)
		npel: u64
		npel, _, i, lok = rdb_read_len(body, i)
		if !lok {
			return
		}
		for _ in 0 ..< npel {
			if i + 16 > len(body) {
				return
			}
			n: Dump_Nack
			n.id = string(body[i:i + 16])
			i += 16
			n.time, i, sok = rdb_read_ms(body, i)
			if !sok {
				return
			}
			n.count, _, i, lok = rdb_read_len(body, i)
			if !lok {
				return
			}
			append(&g.pel, n)
		}
		nc: u64
		nc, _, i, lok = rdb_read_len(body, i)
		if !lok {
			return
		}
		for _ in 0 ..< nc {
			c: Dump_Consumer
			c.pel = make([dynamic]string, context.temp_allocator)
			c.name, i, sok = rdb_read_string(body, i)
			if !sok {
				return
			}
			c.seen, i, sok = rdb_read_ms(body, i)
			c.active, i, sok = rdb_read_ms(body, i)
			if !sok {
				return
			}
			cp: u64
			cp, _, i, lok = rdb_read_len(body, i)
			if !lok {
				return
			}
			for _ in 0 ..< cp {
				if i + 16 > len(body) {
					return
				}
				append(&c.pel, string(body[i:i + 16]))
				i += 16
			}
			append(&g.consumers, c)
		}
		append(&groups, g)
	}
	ok = i == len(body)
	return
}

near_time :: proc(a, b: i64) -> bool {
	if a == -1 || b == -1 {
		return a == b
	}
	d := a - b
	return d <= TOLERANCE_MS && d >= -TOLERANCE_MS
}

compare_group_payloads :: proc(cs: ^Compare_State, redis: []u8, mine: []u8) -> (ok: bool, why: string) {
	ra, rg, rok := parse_stream_payload(redis)
	ma, mg, mok := parse_stream_payload(mine)
	if !rok || !mok {
		return false, "cannot parse a stream payload"
	}
	if ra != ma || string(redis[:ra]) != string(mine[:ma]) {
		return false, "listpack nodes or stream metadata differ"
	}
	crc := crc64(redis[:len(redis) - 8])
	for k in 0 ..< 8 {
		if redis[len(redis) - 8 + k] != u8(crc >> uint(8 * k)) {
			return false, "redis payload checksum does not verify"
		}
	}
	if len(rg) != len(mg) {
		return false, "group count differs"
	}
	for g, gi in rg {
		h := mg[gi]
		if g.name != h.name || g.last_ms != h.last_ms || g.last_seq != h.last_seq || g.entries_read != h.entries_read || len(g.pel) != len(h.pel) || len(g.consumers) != len(h.consumers) {
			return false, fmt.tprintf("group %q header differs", g.name)
		}
		for n, ni in g.pel {
			o := h.pel[ni]
			if n.id != o.id || n.count != o.count || !near_time(n.time, o.time) {
				return false, fmt.tprintf("group %q pending entry %d differs", g.name, ni)
			}
		}
		for c, ci in g.consumers {
			d := h.consumers[ci]
			if c.name != d.name || len(c.pel) != len(d.pel) || !near_time(c.seen, d.seen) || !near_time(c.active, d.active) {
				return false, fmt.tprintf("group %q consumer %q differs", g.name, c.name)
			}
			for id, ii in c.pel {
				if id != d.pel[ii] {
					return false, fmt.tprintf("consumer %q pending list differs", c.name)
				}
			}
		}
		cs.dump_groups += 1
		cs.dump_consumers += len(g.consumers)
		cs.dump_nacks += len(g.pel)
	}
	return true, ""
}

count_entry_flags :: proc(cs: ^Compare_State, nodes: []st.Node_Info) {
	for &n in nodes {
		p := raw_data(n.lp)
		e := lp.lp_first(p)
		e = lp.lp_next(p, e)
		e = lp.lp_next(p, e)
		mfc := st.lp_get_integer(e)
		for _ in 0 ..= mfc {
			e = lp.lp_next(p, e)
		}
		e = lp.lp_next(p, e)
		for e != nil {
			marks := transmute(st.Entry_Marks)u8(st.lp_get_integer(e))
			if .Tombstone in marks {
				cs.tombstones += 1
			}
			if .Shared_Fields in marks {
				cs.samefields += 1
			} else {
				cs.plainfields += 1
			}
			e = lp.lp_next(p, e)
			e = lp.lp_next(p, e)
			e = lp.lp_next(p, e)
			nf := mfc
			skip := mfc
			if .Shared_Fields not_in marks {
				nf = st.lp_get_integer(e)
				e = lp.lp_next(p, e)
				skip = nf * 2
			}
			for _ in 0 ..< skip {
				e = lp.lp_next(p, e)
			}
			e = lp.lp_next(p, e)
		}
	}
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
	nodes := make([dynamic]st.Node_Info, context.temp_allocator)
	st.node_listpacks(k.stream, &nodes)
	mine := expected_stream_dump(k.stream, nodes[:])
	ok := string(rr.str) == string(mine)
	mode := Mode.Dump_Stream
	why := "dump bytes differ"
	if ok {
		cs.dump_exact += 1
	}
	if st.group_count(k.stream) > 0 {
		mode = .Dump_Stream_Groups
		ok, why = compare_group_payloads(cs, rr.str, mine)
	}
	if ok {
		cs.nodes += len(nodes)
		cs.dump_bytes += len(mine)
		cs.max_nodes = max(cs.max_nodes, len(nodes))
		if len(nodes) > 1 {
			cs.multi_node += 1
		}
		count_entry_flags(cs, nodes[:])
	}
	record(cs, idx, args, mode, ok, rr.str, mine, why)
}

time_key :: proc(r: Reply) -> bool {
	if r.kind != .Bulk {
		return false
	}
	k := string(r.str)
	return k == "idle" || k == "inactive" || k == "seen-time" || k == "active-time"
}

tolerant_pending :: proc(a, b: Reply, at: int) -> bool {
	if a.kind != b.kind || len(a.elems) != len(b.elems) {
		return false
	}
	for e, i in a.elems {
		f := b.elems[i]
		if e.kind != .Array || f.kind != .Array || len(e.elems) != len(f.elems) {
			return tolerant_equal(e, f)
		}
		for x, j in e.elems {
			y := f.elems[j]
			if j == at && len(e.elems) == at + 2 && x.kind == .Integer && y.kind == .Integer {
				if !near_time(x.num, y.num) {
					return false
				}
			} else if !tolerant_equal(x, y) {
				return false
			}
		}
	}
	return true
}

tolerant_equal :: proc(a, b: Reply) -> bool {
	if a.kind != b.kind {
		return false
	}
	#partial switch a.kind {
	case .Array, .Map, .Set, .Push, .Attribute:
		if len(a.elems) != len(b.elems) {
			return false
		}
		for e, i in a.elems {
			f := b.elems[i]
			if i > 0 && time_key(a.elems[i - 1]) && e.kind == .Integer && f.kind == .Integer {
				if !near_time(e.num, f.num) {
					return false
				}
				continue
			}
			if i > 0 && a.elems[i - 1].kind == .Bulk && string(a.elems[i - 1].str) == "radix-tree-nodes" && e.kind == .Integer && f.kind == .Integer {
				continue
			}
			if i > 0 && a.elems[i - 1].kind == .Bulk && string(a.elems[i - 1].str) == "pending" && e.kind == .Array {
				if len(e.elems) > 0 && e.elems[0].kind == .Array {
					at := 2 if len(e.elems[0].elems) == 4 else 1
					if !tolerant_pending(e, f, at) {
						return false
					}
					continue
				}
			}
			if !tolerant_equal(e, f) {
				return false
			}
		}
		return true
	}
	return string(a.raw) == string(b.raw)
}

compare_timed :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply, xpending: bool) {
	mine := strings.clone(string(exec(&cs.m, args)), context.temp_allocator)
	if mine == string(rr.raw) {
		record(cs, idx, args, .Exact, true, rr.raw, transmute([]u8)mine)
		return
	}
	mr, _, mok := parse_reply(transmute([]u8)mine, 0, context.temp_allocator)
	ok := mok
	if ok {
		if xpending && rr.kind == .Array && len(rr.elems) > 0 && rr.elems[0].kind == .Array && len(rr.elems[0].elems) == 4 {
			ok = tolerant_pending(rr, mr, 2)
		} else {
			ok = tolerant_equal(rr, mr)
		}
	}
	record(cs, idx, args, .Time_Tolerant, ok, rr.raw, transmute([]u8)mine, "differs beyond the time tolerance")
}

debug_object_fields :: proc(s: []u8) -> string {
	if len(s) == 0 || s[0] != '+' {
		return string(s)
	}
	parts := strings.split(string(s), " ", context.temp_allocator)
	keep := make([dynamic]string, context.temp_allocator)
	for p in parts {
		if strings.has_prefix(p, "encoding:") {
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

compare_memory :: proc(cs: ^Compare_State, idx: int, args: [][]u8, rr: Reply) {
	mine := strings.clone(string(exec(&cs.m, args)), context.temp_allocator)
	mr, _, _ := parse_reply(transmute([]u8)mine, 0, context.temp_allocator)
	ok := mr.kind == rr.kind && (rr.kind != .Integer || rr.num > 0)
	record(cs, idx, args, .Memory_Usage, ok, rr.raw, transmute([]u8)mine, "memory usage shape differs")
}

apply_clock_hint :: proc(cs: ^Compare_State, rr: Reply) {
	if rr.kind != .Bulk {
		return
	}
	id, ok := st.parse_exact_id(rr.str)
	if ok {
		cs.m.now = id.ms
		cs.clock_hints += 1
	}
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
	times_name := "eski_times.txt" if server else "times.txt"
	times_raw, terr := os.read_entire_file(fmt.tprintf("%s/%s", dir, times_name), context.allocator)
	if terr != nil {
		fmt.eprintln("cannot read", times_name)
		return false
	}
	defer delete(times_raw)
	times := make([dynamic]i64)
	defer delete(times)
	for line in strings.split_lines(string(times_raw), context.temp_allocator) {
		if len(line) > 0 {
			v, _ := strconv.parse_i64(line)
			append(&times, v)
		}
	}
	if len(times) != len(cmds) {
		fmt.eprintfln("%s has %d entries for %d commands", times_name, len(times), len(cmds))
		return false
	}
	saved_bytes := st.stream_node_max_bytes
	saved_entries := st.stream_node_max_entries
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
		cs.m.time = times[idx]
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
		case upper == "DEBUG" && len(args) == 3 && eq_lower(args[1], "object"):
			compare_debug_object(&cs, idx, args, rr)
		case upper == "MEMORY":
			compare_memory(&cs, idx, args, rr)
		case upper == "__SLEEP__":
			record(&cs, idx, args, .Ignored, string(rr.raw) == "+SLEPT\r\n", rr.raw, nil)
		case upper == "XPENDING":
			compare_timed(&cs, idx, args, rr, true)
		case upper == "XINFO" && len(args) >= 2 && (eq_lower(args[1], "consumers") || eq_lower(args[1], "stream")):
			compare_timed(&cs, idx, args, rr, false)
		case:
			if upper == "XADD" {
				apply_clock_hint(&cs, rr)
			}
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
		stt := cs.stats[l]
		total += stt.total
		fmt.printfln("%-32s %-7d %d", l, stt.total, stt.mismatch)
	}
	fmt.printfln("%-32s %-7d %d", "TOTAL", total, cs.mismatches)
	fmt.println("comparison modes:")
	for mode in Mode {
		fmt.printfln("  %-16v %d", mode, cs.modes[mode])
	}
	fmt.printfln("XADD replies whose ID set the model clock for automatic IDs: %d", cs.clock_hints)
	fmt.printfln("dump nodes compared: %d listpack nodes in %d stream payloads (%d bytes), %d payloads with several nodes, at most %d nodes in one", cs.nodes, cs.modes[.Dump_Stream], cs.dump_bytes, cs.multi_node, cs.max_nodes)
	fmt.printfln("entries inside the compared nodes: %d with SAMEFIELDS, %d with their own fields, %d tombstones", cs.samefields, cs.plainfields, cs.tombstones)
	fmt.printfln("dump payloads byte identical: %d of %d; group sections compared: %d groups, %d consumers, %d pending entries (timestamps within %d ms)", cs.dump_exact, cs.modes[.Dump_Stream] + cs.modes[.Dump_Stream_Groups], cs.dump_groups, cs.dump_consumers, cs.dump_nacks, TOLERANCE_MS)
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
	st.stream_node_max_bytes = saved_bytes
	st.stream_node_max_entries = saved_entries
	return cs.mismatches == 0
}

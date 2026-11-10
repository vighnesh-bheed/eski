package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import bm "../../src/bm25std"
import lb "../../src/label"
import ps "../../src/postings"
import rt "../../src/retrieve"
import rr "../../src/roaring"
import rf "../../src/rrf"
import so "../../src/sorted"
import sv "../../src/svbyte"
import ts "../../src/termstats"

nat :: proc(s: string) -> int {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok && v >= 0)
	return int(v)
}

integer :: proc(s: string) -> int {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok)
	return int(v)
}

hex64 :: proc(s: string) -> u64 {
	v, ok := strconv.parse_u64(s, 16)
	assert(ok)
	return v
}

nats :: proc(s: string, allocator := context.allocator) -> [dynamic]u32 {
	out := make([dynamic]u32, allocator)
	if s == "-" {
		return out
	}
	parts := strings.split(s, ",")
	defer delete(parts)
	for p in parts {
		append(&out, u32(nat(p)))
	}
	return out
}

unhex :: proc(s: string) -> []u8 {
	if s == "-" {
		return nil
	}
	out := make([]u8, len(s) / 2)
	for i in 0 ..< len(out) {
		v, ok := strconv.parse_u64(s[2 * i:2 * i + 2], 16)
		assert(ok)
		out[i] = u8(v)
	}
	return out
}

write_hex :: proc(b: ^strings.Builder, bytes: []u8) {
	if len(bytes) == 0 {
		strings.write_byte(b, '-')
		return
	}
	for x in bytes {
		fmt.sbprintf(b, "%02x", x)
	}
}

write_nats :: proc(b: ^strings.Builder, xs: []u32) {
	if len(xs) == 0 {
		strings.write_byte(b, '-')
		return
	}
	for x, i in xs {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%d", x)
	}
}

write_bool :: proc(b: ^strings.Builder, v: bool) {
	strings.write_byte(b, '1' if v else '0')
}

write_f64 :: proc(b: ^strings.Builder, v: f64) {
	fmt.sbprintf(b, "%016x", transmute(u64)v)
}

checksum :: proc(xs: []u32) -> u64 {
	p := u64(1) << 61 - 1
	acc := u64(0)
	for x, i in xs {
		acc = (acc + u64(i + 1) * u64(x) % p) % p
	}
	return acc
}

layout :: proc(b: ^strings.Builder, bm: ^rr.Bitmap) {
	if len(bm.keys) == 0 {
		strings.write_byte(b, '-')
		return
	}
	for k, i in bm.keys {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		c := &bm.containers[i]
		switch c.kind {
		case .Array:
			fmt.sbprintf(b, "%d:a:%d", k, c.cardinality)
		case .Bitset:
			fmt.sbprintf(b, "%d:b:%d", k, c.cardinality)
		case .Run:
			fmt.sbprintf(b, "%d:r%d:%d", k, len(c.values) / 2, c.cardinality)
		}
	}
}

describe :: proc(b: ^strings.Builder, bm: ^rr.Bitmap) {
	layout(b, bm)
	n := rr.cardinality(bm)
	vals := make([]u32, n)
	defer delete(vals)
	got := rr.to_array(bm, vals)
	assert(got == n)
	lo, lok := rr.minimum(bm)
	hi, hok := rr.maximum(bm)
	fmt.sbprintf(b, "|%d|", n)
	if lok {
		fmt.sbprintf(b, "%d", lo)
	} else {
		strings.write_byte(b, '-')
	}
	strings.write_byte(b, '|')
	if hok {
		fmt.sbprintf(b, "%d", hi)
	} else {
		strings.write_byte(b, '-')
	}
	fmt.sbprintf(b, "|%d", checksum(vals))
}

perr :: proc(e: ps.Error) -> string {
	switch e {
	case .None:
		return "ok"
	case .Out_Of_Order:
		return "order"
	case .Invalid_Posting:
		return "invalid"
	case .Out_Of_Memory:
		return "oom"
	}
	return "?"
}

lerr :: proc(e: lb.Error) -> string {
	#partial switch e {
	case .None:
		return "ok"
	case .Overflow:
		return "overflow"
	case .Underflow:
		return "underflow"
	case .Invalid_Label:
		return "invalid"
	}
	return "?"
}

State :: struct {
	bitmaps:  [4]rr.Bitmap,
	lists:    [16]ps.List,
	arrays:   [16][dynamic]u32,
	deleted:  rr.Bitmap,
	required: ps.Fields,
	weights:  [dynamic]f64,
	table:    lb.Table,
	vis:      lb.Visibility,
	stats:    ts.Stats,
}

Node :: struct {
	kind:     u8,
	index:    int,
	weight:   int,
	slop:     int,
	in_order: bool,
	kids:     [dynamic]^Node,
	cursor:   ^rt.Cursor,
}

Parser :: struct {
	text: string,
	at:   int,
}

parse_number :: proc(p: ^Parser) -> int {
	neg := false
	if p.text[p.at] == '-' {
		neg = true
		p.at += 1
	}
	v := 0
	for p.at < len(p.text) && p.text[p.at] >= '0' && p.text[p.at] <= '9' {
		v = v * 10 + int(p.text[p.at] - '0')
		p.at += 1
	}
	return -v if neg else v
}

parse_node :: proc(p: ^Parser) -> ^Node {
	n := new(Node)
	n.kind = p.text[p.at]
	p.at += 1
	switch n.kind {
	case 'a', 't':
		n.index = parse_number(p)
		assert(p.text[p.at] == '.')
		p.at += 1
		n.weight = parse_number(p)
		return n
	case 'p':
		n.slop = parse_number(p)
		assert(p.text[p.at] == 'o')
		p.at += 1
		n.in_order = parse_number(p) == 1
	}
	assert(p.text[p.at] == '[')
	p.at += 1
	for {
		append(&n.kids, parse_node(p))
		c := p.text[p.at]
		p.at += 1
		if c == ']' {
			break
		}
		assert(c == ',')
	}
	return n
}

build :: proc(st: ^State, n: ^Node) -> ^rt.Cursor {
	switch n.kind {
	case 'a':
		a := new(rt.Array_Cursor)
		rt.array_cursor_init(a, st.arrays[n.index][:], &st.deleted, rt.leaf(.Term, st.weights[n.weight]))
		n.cursor = &a.base
	case 't':
		t := new(rt.Term_Cursor)
		rt.term_cursor_init(t, &st.lists[n.index], &st.deleted, st.required, rt.leaf(.Term, st.weights[n.weight]))
		n.cursor = &t.base
	case 'i', 'l', 'k':
		kids := make([dynamic]^rt.Cursor)
		for k in n.kids {
			append(&kids, build(st, k))
		}
		strategy := rt.Strategy.Auto if n.kind == 'i' else (rt.Strategy.Leapfrog if n.kind == 'l' else rt.Strategy.Block)
		ix := new(rt.Intersection)
		assert(rt.intersection_init(ix, kids[:], nil, 1, strategy) == .None)
		n.cursor = &ix.base
	case 'u', 'f':
		kids := make([dynamic]^rt.Cursor)
		for k in n.kids {
			append(&kids, build(st, k))
		}
		u := new(rt.Union)
		assert(rt.union_init(u, kids[:], 1, .Sum if n.kind == 'u' else .First) == .None)
		n.cursor = &u.base
	case 'd':
		inc := build(st, n.kids[0])
		exc := build(st, n.kids[1])
		x := new(rt.Difference)
		rt.difference_init(x, inc, exc)
		n.cursor = &x.base
	case 'p':
		kids := make([dynamic]^rt.Cursor)
		for k in n.kids {
			append(&kids, build(st, k))
		}
		ph := new(rt.Phrase)
		assert(rt.phrase_init(ph, kids[:], n.slop, n.in_order) == .None)
		n.cursor = &ph.base
	}
	return n.cursor
}

prepare_leaves :: proc(st: ^State, n: ^Node, scorer: ^rt.Scorer) {
	switch n.kind {
	case 'a':
		a := (^rt.Array_Cursor)(n.cursor)
		rt.prepare(scorer, &a.leaf, a.cost)
	case 't':
		t := (^rt.Term_Cursor)(n.cursor)
		rt.prepare(scorer, &t.leaf, t.cost)
	case:
		for k in n.kids {
			prepare_leaves(st, k, scorer)
		}
	}
}

doc_length :: proc(id: u32) -> u32 {
	return id * 7 % 13 + 1
}

doc_score :: proc(id: u32) -> f32 {
	scores := [4]f32{1, 0.5, 0.75, 2}
	return scores[id % 4]
}

documents :: proc(ctx: rawptr, id: u32) -> (rt.Document, bool) {
	return rt.Document{id = id, length = doc_length(id), score = doc_score(id)}, true
}

Collected :: struct {
	docs:   [dynamic]u32,
	scores: [dynamic]f64,
}

collect_all :: proc(ctx: rawptr, doc: u32, score: f64) -> rt.Error {
	c := (^Collected)(ctx)
	append(&c.docs, doc)
	append(&c.scores, score)
	return .None
}

state_labels :: proc(st: ^State, f: []string, at: int) -> lb.Label {
	level := nat(f[at])
	comps := nats(f[at + 1])
	defer delete(comps)
	ids := make([dynamic]int)
	defer delete(ids)
	for c in comps {
		append(&ids, int(c))
	}
	l, ok := lb.label_make(level, ..ids[:])
	assert(ok)
	return l
}

row :: proc(st: ^State, line: string, b: ^strings.Builder, heap: runtime.Allocator) {
	f := strings.split(line, " ")
	strings.builder_reset(b)
	switch f[0] {
	case "SE":
		vals := nats(f[1])
		out := make([]u8, sv.max_encoded(len(vals)) + 16)
		size := sv.encode(vals[:], out)
		strings.write_string(b, "SE|")
		write_hex(b, out[:size])
		fmt.sbprintf(b, "|%d|%d|", size, sv.encoded_length(out[:size], len(vals)))
		dec := make([]u32, len(vals))
		used := sv.decode_reference(out[:size + 16], dec)
		write_nats(b, dec)
		k := sv.kernels_for(sv.best_level())
		dec2 := make([]u32, len(vals))
		used2 := k.decode(out[:size + 16], dec2)
		strings.write_byte(b, '|')
		write_nats(b, dec2)
		fmt.sbprintf(b, "|%d|%d", used, used2)
	case "SD":
		prev := u32(nat(f[1]))
		vals := nats(f[2])
		out := make([]u8, sv.max_encoded(len(vals)) + 16)
		size := sv.encode_delta(vals[:], prev, out)
		strings.write_string(b, "SD|")
		write_hex(b, out[:size])
		dec := make([]u32, len(vals))
		used := sv.decode_delta_reference(out[:size + 16], dec, prev)
		k := sv.kernels_for(sv.best_level())
		dec2 := make([]u32, len(vals))
		used2 := k.decode_delta(out[:size + 16], dec2, prev)
		fmt.sbprintf(b, "|%d|", size)
		write_nats(b, dec)
		strings.write_byte(b, '|')
		write_nats(b, dec2)
		fmt.sbprintf(b, "|%d|%d", used, used2)
	case "SX":
		n := nat(f[1])
		data := unhex(f[2])
		fmt.sbprintf(b, "SX|%d|", sv.encoded_length(data, n))
		dec := make([]u32, n)
		used := sv.decode_reference(data, dec)
		write_nats(b, dec)
		k := sv.kernels_for(sv.best_level())
		dec2 := make([]u32, n)
		used2 := k.decode(data, dec2)
		strings.write_byte(b, '|')
		write_nats(b, dec2)
		fmt.sbprintf(b, "|%d|%d", used, used2)
	case "SW":
		vals := nats(f[1])
		out := make([]u8, sv.max_encoded(len(vals)) + 4)
		w: sv.Writer
		sv.writer_init(&w, out, len(vals))
		for v in vals {
			sv.writer_put(&w, v)
		}
		strings.write_string(b, "SW|")
		write_hex(b, out[:w.pos])
		fmt.sbprintf(b, "|%d", w.pos)
	case "QA":
		x := nats(f[1])
		y := nats(f[2])
		room := max(len(x), len(y)) + 8
		o := make([]u32, room)
		strings.write_string(b, "QA|")
		write_nats(b, o[:so.intersect_reference(x[:], y[:], o)])
		strings.write_byte(b, '|')
		write_nats(b, o[:so.intersect_merge(x[:], y[:], o)])
		strings.write_byte(b, '|')
		write_nats(b, o[:so.intersect_gallop(x[:], y[:], o)])
		strings.write_byte(b, '|')
		write_nats(b, o[:so.intersect_gallop(y[:], x[:], o)])
		strings.write_byte(b, '|')
		write_nats(b, o[:so.intersect(x[:], y[:], o)])
		strings.write_byte(b, '|')
		k := so.kernels_for(so.best_level())
		o2 := make([]u32, min(len(x), len(y)))
		write_nats(b, o2[:k.intersect(x[:], y[:], o2)])
		fmt.sbprintf(b, "|%d|", so.intersect_count(x[:], y[:]))
		u := make([]u32, len(x) + len(y))
		write_nats(b, u[:so.union_merge(x[:], y[:], u)])
		strings.write_byte(b, '|')
		write_nats(b, o[:so.difference_merge(x[:], y[:], o)])
		strings.write_byte(b, '|')
		write_bool(b, so.is_strict(x[:]))
	case "QB":
		x := nats(f[1])
		t := u32(nat(f[2]))
		from := nat(f[3])
		fmt.sbprintf(b, "QB|%d|%d|%d", so.lower_bound(x[:], t), so.upper_bound(x[:], t), so.gallop(x[:], from, t))
	case "RX":
		rr.clear(&st.bitmaps[nat(f[1])])
		strings.write_string(b, "RX")
	case "RA":
		added, e := rr.add(&st.bitmaps[nat(f[1])], u32(nat(f[2])))
		assert(e == .None)
		strings.write_string(b, "RA|")
		write_bool(b, added)
	case "RR":
		removed, e := rr.remove(&st.bitmaps[nat(f[1])], u32(nat(f[2])))
		assert(e == .None)
		strings.write_string(b, "RR|")
		write_bool(b, removed)
	case "RC":
		strings.write_string(b, "RC|")
		write_bool(b, rr.contains(&st.bitmaps[nat(f[1])], u32(nat(f[2]))))
	case "RF":
		bmp := &st.bitmaps[nat(f[1])]
		start := nat(f[2])
		count := nat(f[3])
		step := nat(f[4])
		for i in 0 ..< count {
			_, e := rr.add(bmp, u32(start + i * step))
			assert(e == .None)
		}
		fmt.sbprintf(b, "RF|%d", rr.cardinality(bmp))
	case "RO":
		op := rr.Op.And
		switch f[1] {
		case "or":
			op = .Or
		case "andnot":
			op = .Andnot
		}
		out := &st.bitmaps[nat(f[4])]
		tmp: rr.Bitmap
		rr.init(&tmp, heap)
		assert(rr.combine(op, &st.bitmaps[nat(f[2])], &st.bitmaps[nat(f[3])], &tmp) == .None)
		rr.destroy(out)
		out^ = tmp
		strings.write_string(b, "RO|")
		describe(b, out)
	case "RN":
		n, e := rr.and_cardinality(&st.bitmaps[nat(f[1])], &st.bitmaps[nat(f[2])])
		assert(e == .None)
		fmt.sbprintf(b, "RN|%d", n)
	case "RP":
		changed, e := rr.run_optimize(&st.bitmaps[nat(f[1])])
		assert(e == .None)
		strings.write_string(b, "RP|")
		write_bool(b, changed)
		strings.write_byte(b, '|')
		describe(b, &st.bitmaps[nat(f[1])])
	case "RS":
		bmp := &st.bitmaps[nat(f[1])]
		out := make([]u8, rr.serialized_size(bmp))
		n := rr.serialize(bmp, out)
		strings.write_string(b, "RS|")
		write_hex(b, out[:n])
	case "RD":
		data := unhex(f[1])
		tmp: rr.Bitmap
		rr.init(&tmp)
		used, e := rr.deserialize(&tmp, data)
		if e != .None {
			strings.write_string(b, "RD|invalid")
		} else {
			fmt.sbprintf(b, "RD|%d|", used)
			describe(b, &tmp)
		}
		rr.destroy(&tmp)
	case "RL":
		strings.write_string(b, "RL|")
		describe(b, &st.bitmaps[nat(f[1])])
	case "RE":
		strings.write_string(b, "RE|")
		write_bool(b, rr.equal(&st.bitmaps[nat(f[1])], &st.bitmaps[nat(f[2])]))
	case "RT":
		it: rr.Iterator
		rr.iterator_init(&it, &st.bitmaps[nat(f[1])])
		ops := strings.split(f[2], ",")
		strings.write_string(b, "RT|")
		for o, i in ops {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			v: u32
			ok: bool
			if o == "n" {
				v, ok = rr.next(&it)
			} else {
				v, ok = rr.advance(&it, u32(nat(o)))
			}
			if ok {
				fmt.sbprintf(b, "%d", v)
			} else {
				strings.write_byte(b, '-')
			}
		}
	case "AR":
		k := nat(f[1])
		delete(st.arrays[k])
		st.arrays[k] = nats(f[2], heap)
		strings.write_string(b, "AR")
	case "DL":
		rr.clear(&st.deleted)
		ds := nats(f[1])
		for d in ds {
			rr.add(&st.deleted, d)
		}
		strings.write_string(b, "DL")
	case "RQ":
		v, ok := strconv.parse_u64(f[1], 16)
		assert(ok)
		st.required = ps.Fields(v)
		strings.write_string(b, "RQ")
	case "WT":
		clear(&st.weights)
		parts := strings.split(f[1], ",")
		for p in parts {
			append(&st.weights, transmute(f64)hex64(p))
		}
		strings.write_string(b, "WT")
	case "PL":
		k := nat(f[1])
		ps.destroy(&st.lists[k])
		lay := ps.layout_make(nat(f[2]), f[3] == "1")
		ps.init(&st.lists[k], lay, heap)
		fmt.sbprintf(b, "PL|%d", lay.field_words)
	case "PA":
		k := nat(f[1])
		mv, ok := strconv.parse_u128(f[4], 16)
		assert(ok)
		counts := nats(f[5])
		positions := nats(f[6])
		p := ps.Posting{doc = u32(nat(f[2])), frequency = u32(nat(f[3])), fields = ps.Fields(mv), counts = counts[:], positions = positions[:]}
		e := ps.append_posting(&st.lists[k], p)
		fmt.sbprintf(b, "PA|%s|%d|%d|%d", perr(e), ps.length(&st.lists[k]), len(st.lists[k].blocks), st.lists[k].tail_count)
	case "PC":
		l := &st.lists[nat(f[1])]
		c: ps.Cursor
		ps.cursor_init(&c, l, &st.deleted, st.required)
		strings.write_string(b, "PC|")
		first := true
		for d := ps.next(&c); d != ps.END; d = ps.next(&c) {
			if !first {
				strings.write_byte(b, ';')
			}
			first = false
			pos := make([dynamic]u32)
			if l.layout.positions {
				ps.cursor_positions(&c, ps.ALL_FIELDS, &pos)
			}
			fmt.sbprintf(b, "%d:%d:%x:", d, ps.frequency(&c), ps.fields_of(&c))
			write_nats(b, pos[:])
		}
		if first {
			strings.write_byte(b, '-')
		}
	case "PV":
		l := &st.lists[nat(f[1])]
		c: ps.Cursor
		ps.cursor_init(&c, l, &st.deleted, st.required)
		targets := nats(f[2])
		strings.write_string(b, "PV|")
		for t, i in targets {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			d := ps.advance(&c, t)
			if d == ps.END {
				strings.write_byte(b, '-')
			} else {
				fmt.sbprintf(b, "%d", d)
			}
		}
	case "PK":
		l := &st.lists[nat(f[1])]
		Removed :: struct {
			docs: [dynamic]u32,
		}
		r: Removed
		cb :: proc(ctx: rawptr, doc: u32) {
			append(&(^Removed)(ctx).docs, doc)
		}
		dropped, e := ps.collect(l, &st.deleted, cb, &r)
		assert(e == .None)
		fmt.sbprintf(b, "PK|%d|", dropped)
		write_nats(b, r.docs[:])
		fmt.sbprintf(b, "|%d", ps.length(l))
	case "PW":
		in_order := f[1] == "1"
		slop := integer(f[2])
		groups := strings.split(f[3], ";")
		lists := make([][]u32, len(groups))
		for g, i in groups {
			xs := nats(g)
			lists[i] = xs[:]
		}
		heads := make([]int, len(lists))
		strings.write_string(b, "PW|")
		write_bool(b, rt.ordered_window(lists, slop))
		strings.write_byte(b, '|')
		write_bool(b, rt.unordered_window(lists, slop, heads))
		_ = in_order
	case "T", "TP":
		p := Parser{text = f[1]}
		root := parse_node(&p)
		cur := build(st, root)
		out := make([dynamic]u32)
		assert(rt.collect_docs(cur, &out) == .None)
		fmt.sbprintf(b, "%s|", f[0])
		write_nats(b, out[:])
	case "TA":
		p := Parser{text = f[1]}
		root := parse_node(&p)
		cur := build(st, root)
		targets := nats(f[2])
		strings.write_string(b, "TA|")
		for t, i in targets {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			d := rt.advance(cur, t)
			if d == rt.END {
				strings.write_byte(b, '-')
			} else {
				fmt.sbprintf(b, "%d", d)
			}
		}
	case "TS":
		documents_n := u64(nat(f[1]))
		total_length := u64(nat(f[2]))
		p := Parser{text = f[3]}
		root := parse_node(&p)
		cur := build(st, root)
		params := bm.params_default()
		scorer := bm.scorer(&params)
		rt.begin(&scorer, rt.Collection{documents = documents_n, total_length = total_length})
		prepare_leaves(st, root, &scorer)
		col: Collected
		collector := rt.Collector{ctx = &col, collect = collect_all}
		_, e := rt.run(cur, &scorer, documents, nil, &collector)
		assert(e == .None)
		strings.write_string(b, "TS|")
		if len(col.docs) == 0 {
			strings.write_byte(b, '-')
		}
		for d, i in col.docs {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, "%d:", d)
			write_f64(b, col.scores[i])
		}
	case "LB":
		id, e := lb.table_intern(&st.table, state_labels(st, f, 1))
		assert(e == .None)
		fmt.sbprintf(b, "LB|%d", id)
	case "LV":
		lb.visibility_destroy(&st.vis)
		assert(lb.visibility_build(&st.vis, &st.table, state_labels(st, f, 1), heap) == .None)
		fmt.sbprintf(b, "LV|%d", st.vis.built)
	case "SA":
		term := u32(nat(f[1]))
		id := lb.Id(nat(f[2]))
		e := ts.term_add(&st.stats, term, id, u32(nat(f[3])))
		fmt.sbprintf(b, "SA|%s|%d|%d", lerr(e), ts.term_total(&st.stats, term), ts.term_count(&st.stats, term, id))
	case "SR":
		term := u32(nat(f[1]))
		id := lb.Id(nat(f[2]))
		e := ts.term_remove(&st.stats, term, id, u32(nat(f[3])))
		fmt.sbprintf(b, "SR|%s|%d|%d", lerr(e), ts.term_total(&st.stats, term), ts.term_count(&st.stats, term, id))
	case "SF":
		ts.term_forget(&st.stats, u32(nat(f[1])))
		fmt.sbprintf(b, "SF|%d", ts.term_total(&st.stats, u32(nat(f[1]))))
	case "DA":
		e := ts.document_add(&st.stats, lb.Id(nat(f[1])), u32(nat(f[2])))
		t := ts.totals(&st.stats)
		fmt.sbprintf(b, "DA|%s|%d|%d", lerr(e), t.documents, t.total_length)
	case "DX":
		e := ts.document_remove(&st.stats, lb.Id(nat(f[1])), u32(nat(f[2])))
		t := ts.totals(&st.stats)
		fmt.sbprintf(b, "DX|%s|%d|%d", lerr(e), t.documents, t.total_length)
	case "SV":
		term := u32(nat(f[1]))
		fmt.sbprintf(b, "SV|%d|%d", ts.term_visible(&st.stats, term, &st.vis), ts.term_total(&st.stats, term))
	case "ST":
		v := ts.totals_visible(&st.stats, &st.vis)
		t := ts.totals(&st.stats)
		fmt.sbprintf(b, "ST|%d|%d|%d|%d", v.documents, v.total_length, t.documents, t.total_length)
	case "BI":
		strings.write_string(b, "BI|")
		write_f64(b, bm.idf(u64(nat(f[1])), u64(nat(f[2]))))
	case "BM":
		params := bm.params_default()
		scorer := bm.scorer(&params)
		rt.begin(&scorer, rt.Collection{documents = u64(nat(f[1])), total_length = u64(nat(f[2]))})
		l := rt.leaf(.Term, transmute(f64)hex64(f[4]))
		rt.prepare(&scorer, &l, u64(nat(f[3])))
		s := rt.Scoring{scorer = &scorer, doc = rt.Document{id = 1, length = u32(nat(f[6])), score = f32(transmute(f64)hex64(f[7]))}}
		c := rt.leaf_score(&s, &l, rt.Hit{frequency = u32(nat(f[5]))})
		final := rt.finish(&s, c, nil)
		strings.write_string(b, "BM|")
		write_f64(b, l.prepared)
		strings.write_byte(b, '|')
		write_f64(b, params.average_length)
		strings.write_byte(b, '|')
		write_f64(b, c)
		strings.write_byte(b, '|')
		write_f64(b, final)
	case "FU":
		params := rf.Params{constant = transmute(f64)hex64(f[1]), window = integer(f[2])}
		groups := strings.split(f[3], ";")
		branches := make([][]rt.Ranked, len(groups))
		for g, i in groups {
			xs := nats(g)
			rs := make([]rt.Ranked, len(xs))
			for x, j in xs {
				rs[j] = rt.Ranked{doc = x}
			}
			branches[i] = rs
		}
		out := make([dynamic]rt.Ranked)
		assert(rf.fuse(&params, branches, &out) == .None)
		strings.write_string(b, "FU|")
		if len(out) == 0 {
			strings.write_byte(b, '-')
		}
		for r, i in out {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, "%d:", r.doc)
			write_f64(b, r.score)
		}
	case "TK":
		k := integer(f[1])
		t: rt.Top_K
		assert(rt.top_k_init(&t, k) == .None)
		if f[2] != "-" {
			items := strings.split(f[2], ",")
			for it in items {
				kv := strings.split(it, ":")
				assert(rt.top_k_push(&t, u32(nat(kv[0])), transmute(f64)hex64(kv[1])) == .None)
			}
		}
		out := make([dynamic]rt.Ranked)
		assert(rt.top_k_results(&t, &out) == .None)
		fmt.sbprintf(b, "TK|%d|", t.total)
		if len(out) == 0 {
			strings.write_byte(b, '-')
		}
		for r, i in out {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, "%d:", r.doc)
			write_f64(b, r.score)
		}
		strings.write_byte(b, '|')
		write_f64(b, rt.top_k_threshold(&t))
	case:
		panic("unknown case")
	}
}

main :: proc() {
	heap := context.allocator
	assert(len(os.args) == 2)
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	lines := strings.split(string(input), "\n")
	st := new(State)
	for &bm in st.bitmaps {
		rr.init(&bm)
	}
	for &l in st.lists {
		ps.init(&l, ps.layout_make(1, true))
	}
	rr.init(&st.deleted)
	st.weights = make([dynamic]f64)
	append(&st.weights, 1)
	assert(lb.table_init(&st.table) == .None)
	assert(lb.visibility_build(&st.vis, &st.table, lb.BOTTOM) == .None)
	ts.init(&st.stats)
	b := strings.builder_make()
	for line in lines {
		if len(line) == 0 {
			continue
		}
		context.allocator = context.temp_allocator
		row(st, line, &b, heap)
		fmt.println(strings.to_string(b))
		free_all(context.temp_allocator)
	}
}

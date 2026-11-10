package vsettype

import "core:fmt"
import "core:testing"
import "../hnsw"
import lbl "../label"
import "../rax"
import "../vmath"

Scheme :: struct {
	table:  lbl.Table,
	ids:    [dynamic]lbl.Id,
	views:  [dynamic]^lbl.Visibility,
	stream: [dynamic]u64,
}

scheme_init :: proc(sc: ^Scheme, r: ^Test_Rng, levels: int, compartments: int, want: int) {
	lbl.table_init(&sc.table)
	append(&sc.ids, lbl.BOTTOM_ID)
	for tries := 0; len(sc.ids) < want && tries < 1000; tries += 1 {
		l: lbl.Label
		l.level = u8(test_below(r, levels))
		for c in 0 ..< compartments {
			if test_below(r, 3) == 0 {
				lbl.compartment_add(&l, c)
			}
		}
		id, err := lbl.table_intern(&sc.table, l)
		if err != .None {
			continue
		}
		known := false
		for x in sc.ids {
			known = known || x == id
		}
		if !known {
			append(&sc.ids, id)
		}
	}
	for id in sc.ids {
		v := new(lbl.Visibility)
		l, _ := lbl.table_label(&sc.table, id)
		lbl.visibility_build(v, &sc.table, l)
		append(&sc.views, v)
		append(&sc.stream, stream_seed(id) ~ 0x5A5A)
	}
}

scheme_destroy :: proc(sc: ^Scheme) {
	for v in sc.views {
		lbl.visibility_destroy(v)
		free(v)
	}
	delete(sc.views)
	delete(sc.ids)
	delete(sc.stream)
	lbl.table_destroy(&sc.table)
}

scheme_access :: proc(sc: ^Scheme, i: int, top := false) -> Access {
	return Access{label = sc.ids[i], visibility = sc.views[i], table = &sc.table, stream = &sc.stream[i], top = top}
}

scheme_index :: proc(sc: ^Scheme, id: lbl.Id) -> int {
	for x, i in sc.ids {
		if x == id {
			return i
		}
	}
	return -1
}

scheme_sees :: proc(sc: ^Scheme, reader: int, id: lbl.Id) -> bool {
	return lbl.visible(sc.views[reader], id)
}

check_labelled :: proc(t: ^testing.T, s: Vset) -> bool {
	if s.lab == nil {
		return check_invariants(t, s)
	}
	ok := true
	fail :: proc(t: ^testing.T, ok: ^bool, text: string) {
		testing.expect(t, false, text)
		ok^ = false
	}
	lab := s.lab
	if s.core.count != 0 || s.core.elements != nil {
		fail(t, &ok, "the core of a labelled set holds elements")
	}
	total := 0
	live := 0
	for id in 0 ..< lab.id_high {
		p := lab.by_id[id]
		if p == nil {
			continue
		}
		live += 1
		if p.id != id {
			fail(t, &ok, fmt.tprintf("partition %d records id %d", id, p.id))
		}
		if p.count == 0 {
			fail(t, &ok, fmt.tprintf("partition %d is empty but kept", id))
		}
		if part_at_label(s, p.label) != p {
			fail(t, &ok, fmt.tprintf("partition %d is not found by its label %d", id, p.label))
		}
		total += p.count
		if !check_partition(t, s, p) {
			ok = false
		}
	}
	if live != int(lab.sorted_len) {
		fail(t, &ok, fmt.tprintf("%d live partitions, %d sorted", live, lab.sorted_len))
	}
	for i in 1 ..< int(lab.sorted_len) {
		if lab.sorted[i - 1].label >= lab.sorted[i].label {
			fail(t, &ok, "sorted partitions out of order")
		}
	}
	if total != lab.total {
		fail(t, &ok, fmt.tprintf("partitions hold %d, total says %d", total, lab.total))
	}
	copies := 0
	multis := 0
	it: rax.Iterator
	rax.start(&it, s.names)
	rax.seek(&it, "^")
	for rax.next(&it) {
		key := rax.key(&it)
		one: Ref
		list := name_decode(it.data, &one)
		if u64(uintptr(it.data)) & NAME_MULTI != 0 {
			multis += 1
			c := (^Copies)(uintptr(u64(uintptr(it.data)) &~ NAME_MULTI))
			if c.count < 2 || c.index >= lab.multi_len || lab.multis[c.index] != c {
				fail(t, &ok, "copies block not registered")
			}
		}
		for r, i in list {
			copies += 1
			p := part_by_id(s, r.part)
			if p == nil || int(r.slot) >= int(p.arena.high) || !vmath.arena_is_live(&p.arena, r.slot) {
				fail(t, &ok, fmt.tprintf("name %q refers to a dead copy", string(key)))
				continue
			}
			if string(part_element_name(p, r.slot)) != string(key) {
				fail(t, &ok, fmt.tprintf("name %q refers to element %q", string(key), string(part_element_name(p, r.slot))))
			}
			for q in list[:i] {
				if ref_label(s, q) == p.label {
					fail(t, &ok, fmt.tprintf("name %q has two copies at label %d", string(key), p.label))
				}
			}
		}
	}
	rax.stop(&it)
	if multis != int(lab.multi_len) {
		fail(t, &ok, fmt.tprintf("%d multi names, %d registered", multis, lab.multi_len))
	}
	if copies != total {
		fail(t, &ok, fmt.tprintf("name map holds %d copies, partitions %d", copies, total))
	}
	if ledger_balance(s) != 0 {
		fail(t, &ok, fmt.tprintf("ledger is off by %d bytes", ledger_balance(s)))
	}
	return ok
}

check_partition :: proc(t: ^testing.T, s: Vset, p: ^Partition) -> bool {
	ok := true
	if int(p.arena.live) != p.count {
		testing.expectf(t, false, "partition %d arena %d count %d", p.id, p.arena.live, p.count)
		ok = false
	}
	switch p.mode {
	case .Flat:
		if p.graph.slots != 0 || p.graph.cap != 0 {
			testing.expectf(t, false, "flat partition %d holds graph slots", p.id)
			ok = false
		}
	case .Graph, .Pinned:
		if hnsw.size(&p.graph) != p.count || int(p.arena.high) != p.graph.slots {
			testing.expectf(t, false, "partition %d graph %d slots %d high %d count %d", p.id, hnsw.size(&p.graph), p.graph.slots, p.arena.high, p.count)
			ok = false
		}
		a := p.arena.free
		g := p.graph.free_head
		for a != vmath.NIL_SLOT || g != hnsw.NONE {
			if a != g {
				testing.expectf(t, false, "partition %d free lists diverge at %d against %d", p.id, a, g)
				return false
			}
			a = vmath.free_next(p.arena.norms[a])
			next := hnsw.word_get(p.graph.links0[int(g) * p.graph.row:], 0, p.graph.width)
			g = hnsw.NONE if next == hnsw.width_none(p.graph.width) else next
		}
	}
	attrs := 0
	for i in 0 ..< p.count {
		slot := p.order[i]
		e := &p.elements[slot]
		if int(e.pos) != i {
			testing.expectf(t, false, "partition %d slot %d records position %d at %d", p.id, slot, e.pos, i)
			ok = false
		}
		if e.attr.blob != nil {
			attrs += 1
		}
		one: Ref
		found := false
		for r in names_lookup(s, e.name[:e.len], &one) {
			found = found || r == Ref{slot = slot, part = p.id}
		}
		if !found {
			testing.expectf(t, false, "partition %d slot %d is not in the name map", p.id, slot)
			ok = false
		}
	}
	if attrs != int(p.attributes) {
		testing.expectf(t, false, "partition %d attributes %d counted %d", p.id, p.attributes, attrs)
		ok = false
	}
	if c := part_charge(s, p); c != nil && c.bytes != part_block_bytes(p) {
		testing.expectf(t, false, "partition %d charge %d blocks %d", p.id, c.bytes, part_block_bytes(p))
		ok = false
	}
	return ok
}

Limits :: struct {
	flat:   int,
	shrink: int,
}

limits_set :: proc(flat: int, shrink: int) -> Limits {
	old := Limits{flat = flat_limit, shrink = shrink_limit}
	flat_limit = flat
	shrink_limit = shrink
	return old
}

limits_restore :: proc(old: Limits) {
	flat_limit = old.flat
	shrink_limit = old.shrink
}

labelled_add :: proc(s: Vset, a: ^Access, name: string, x: []f32, sc: ^Scratch, quant := Quant.Q8, attr := "", set_attr := false) -> (Change, Failure) {
	req := Add_Request{name = bytes_of(name), vector = x, quant = quant, attr = bytes_of(attr), set_attr = set_attr}
	return add_at(s, a, &req, sc)
}

new_labelled :: proc(t: ^testing.T, a: ^Access, dim: int, quant := Quant.Q8) -> Vset {
	x := make([]f32, dim, context.temp_allocator)
	req := Add_Request{vector = x, quant = quant}
	s, f := create_at(&req, a)
	testing.expect_value(t, f.err, Error.None)
	return s
}

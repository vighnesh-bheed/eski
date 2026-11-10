package vsettype

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:testing"
import lbl "../label"
import "../vmath"

Oracle_Copy :: struct {
	name:     string,
	label:    lbl.Id,
	vector:   []f32,
	attr:     string,
	has_attr: bool,
	born:     int,
}

Oracle :: struct {
	copies: [dynamic]Oracle_Copy,
	born:   int,
	scheme: ^Scheme,
	quant:  Quant,
	dim:    int,
}

oracle_destroy :: proc(o: ^Oracle) {
	for c in o.copies {
		delete(c.name)
		delete(c.vector)
		delete(c.attr)
	}
	delete(o.copies)
}

oracle_rank :: proc(o: ^Oracle, id: lbl.Id) -> [2]int {
	l, _ := lbl.table_label(&o.scheme.table, id)
	return {int(l.level), lbl.compartment_count(l)}
}

oracle_higher :: proc(o: ^Oracle, a: ^Oracle_Copy, b: ^Oracle_Copy) -> bool {
	ra := oracle_rank(o, a.label)
	rb := oracle_rank(o, b.label)
	if ra != rb {
		return ra[0] > rb[0] || ra[0] == rb[0] && ra[1] > rb[1]
	}
	return a.born < b.born
}

oracle_exact :: proc(o: ^Oracle, name: string, l: lbl.Id) -> int {
	for &c, i in o.copies {
		if c.name == name && c.label == l {
			return i
		}
	}
	return -1
}

oracle_visible_other :: proc(o: ^Oracle, reader: int, name: string) -> int {
	own := o.scheme.ids[reader]
	best := -1
	for &c, i in o.copies {
		if c.name != name || c.label == own || !scheme_sees(o.scheme, reader, c.label) {
			continue
		}
		if best < 0 || oracle_higher(o, &c, &o.copies[best]) {
			best = i
		}
	}
	return best
}

oracle_resolve :: proc(o: ^Oracle, reader: int, name: string) -> int {
	if i := oracle_exact(o, name, o.scheme.ids[reader]); i >= 0 {
		return i
	}
	return oracle_visible_other(o, reader, name)
}

oracle_view :: proc(o: ^Oracle, reader: int, out: ^[dynamic]int) {
	clear(out)
	for c, i in o.copies {
		if oracle_resolve(o, reader, c.name) == i {
			append(out, i)
		}
	}
}

oracle_has_label :: proc(o: ^Oracle, l: lbl.Id) -> bool {
	for c in o.copies {
		if c.label == l {
			return true
		}
	}
	return false
}

oracle_attr_value :: proc(c: ^Oracle_Copy) -> (int, bool) {
	if !c.has_attr || len(c.attr) < 7 {
		return 0, false
	}
	return strconv.parse_int(c.attr[5:len(c.attr) - 1])
}

oracle_accept :: proc(c: ^Oracle_Copy, filter: int) -> bool {
	if filter == 0 {
		return true
	}
	v, ok := oracle_attr_value(c)
	if !ok {
		return false
	}
	return v > 2 if filter == 1 else v == 1
}

FILTER_TEXTS :: [3]string{"", ".a > 2", ".a == 1"}

Oracle_Run :: struct {
	t:      ^testing.T,
	o:      Oracle,
	scheme: Scheme,
	s:      Vset,
	sc:     Scratch,
	r:      Test_Rng,
	names:  [dynamic]string,
	view:   [dynamic]int,
	hits:   [dynamic]Hit,
	refs:   [dynamic]Ref,
	links:  Links,
	stats:  Oracle_Stats,
}

Oracle_Stats :: struct {
	refused:  int,
	forced:   int,
	checks:   int,
	shadowed: int,
	graphs:   int,
	parts:    int,
}

oracle_op :: proc(run: ^Oracle_Run) -> bool {
	t := run.t
	o := &run.o
	r := &run.r
	w := test_below(r, len(run.scheme.ids))
	a := scheme_access(&run.scheme, w)
	own := run.scheme.ids[w]
	name := run.names[test_below(r, len(run.names))]
	op := test_below(r, 10)
	exact := oracle_exact(o, name, own)
	other := oracle_visible_other(o, w, name)
	x := make([]f32, o.dim, context.temp_allocator)
	random_vector(r, x)
	if test_below(r, 6) == 0 {
		for &v in x {
			v = 0.5
		}
	}
	attr := fmt.tprintf(`{{"a":%d}}`, test_below(r, 5))
	if test_below(r, 7) == 0 {
		attr = ""
	}
	switch {
	case op < 6:
		set_attr := test_below(r, 2) == 0
		if run.s == nil {
			req := Add_Request{name = bytes_of(name), vector = x, quant = o.quant}
			created, f := create_at(&req, &a)
			if !testing.expect_value(t, f.err, Error.None) {
				return false
			}
			run.s = created
		}
		had_label := oracle_has_label(o, own)
		ch, f := labelled_add(run.s, &a, name, x, &run.sc, o.quant, attr, set_attr)
		if exact >= 0 {
			c := &o.copies[exact]
			delete(c.vector)
			c.vector = slice.clone(x)
			if set_attr {
				delete(c.attr)
				c.attr = fmt.aprintf("%s", attr)
				c.has_attr = len(attr) > 0
			}
			testing.expectf(t, f.err == .None && !ch.added, "update %q at %d: %v %v", name, own, f.err, ch)
		} else if other >= 0 {
			run.stats.refused += 1
			testing.expectf(t, f.err == .Name_In_Use && f.label == o.copies[other].label, "add %q at %d should be refused at %d: %v %v", name, own, o.copies[other].label, f.err, f.label)
		} else {
			for c in o.copies {
				if c.name == name {
					run.stats.forced += 1
					break
				}
			}
			append(&o.copies, Oracle_Copy{name = fmt.aprintf("%s", name), label = own, vector = slice.clone(x), attr = fmt.aprintf("%s", attr), has_attr = set_attr, born = o.born})
			o.born += 1
			testing.expectf(t, f.err == .None && ch.added && ch.label_new == !had_label, "add %q at %d: %v %v", name, own, f.err, ch)
		}
	case op < 8 && run.s != nil:
		ch, f := remove_at(run.s, &a, bytes_of(name), &run.sc)
		if exact >= 0 {
			c := o.copies[exact]
			ordered_remove(&o.copies, exact)
			delete(c.name)
			delete(c.vector)
			delete(c.attr)
			testing.expectf(t, f.err == .None && ch.found && ch.label_gone == !oracle_has_label(o, own) && ch.emptied == (len(o.copies) == 0), "remove %q at %d: %v %v", name, own, f.err, ch)
		} else if other >= 0 {
			testing.expectf(t, f.err == .Name_In_Use && f.label == o.copies[other].label, "remove %q at %d should be refused: %v", name, own, f.err)
		} else {
			testing.expectf(t, f.err == .None && !ch.found, "remove %q at %d should miss: %v %v", name, own, f.err, ch)
		}
	case op < 9 && run.s != nil:
		ch, f := set_attribute_at(run.s, &a, bytes_of(name), bytes_of(attr))
		if exact >= 0 {
			c := &o.copies[exact]
			delete(c.attr)
			c.attr = fmt.aprintf("%s", attr)
			c.has_attr = len(attr) > 0
			testing.expectf(t, f.err == .None && ch.found, "setattr %q at %d: %v", name, own, f.err)
		} else if other >= 0 {
			testing.expectf(t, f.err == .Name_In_Use && f.label == o.copies[other].label, "setattr %q at %d should be refused: %v", name, own, f.err)
		} else {
			testing.expectf(t, f.err == .None && !ch.found, "setattr %q at %d should miss", name, own)
		}
	case run.s != nil:
		removed, rc := remove_label(run.s, own)
		emptied := rc.emptied
		testing.expect(t, rc.label_gone == (removed > 0) && rc.found == (removed > 0))
		want := 0
		for i := len(o.copies) - 1; i >= 0; i -= 1 {
			if o.copies[i].label == own {
				c := o.copies[i]
				ordered_remove(&o.copies, i)
				delete(c.name)
				delete(c.vector)
				delete(c.attr)
				want += 1
			}
		}
		testing.expectf(t, removed == want && emptied == (len(o.copies) == 0), "remove label %d: %d %v against %d", own, removed, emptied, want)
	}
	if run.s != nil && len(o.copies) == 0 {
		destroy(run.s)
		run.s = nil
	}
	return true
}

oracle_check_reader :: proc(run: ^Oracle_Run, reader: int) -> bool {
	t := run.t
	o := &run.o
	s := run.s
	a := scheme_access(&run.scheme, reader)
	v, err := view_open(s, &a, &run.sc)
	testing.expect_value(t, err, Error.None)
	oracle_view(o, reader, &run.view)
	run.stats.checks += 1
	run.stats.parts = max(run.stats.parts, len(v.parts))
	for vp in v.parts {
		run.stats.shadowed += len(vp.shadow)
		if vp.part.mode == .Graph {
			run.stats.graphs += 1
		}
	}
	ok := testing.expectf(t, view_size(&v) == len(run.view), "reader %d sees %d, model %d", reader, view_size(&v), len(run.view))
	attrs := 0
	for i in run.view {
		if o.copies[i].has_attr {
			attrs += 1
		}
	}
	info := view_info(&v)
	ok = testing.expectf(t, info.size == len(run.view) && info.attributes_count == attrs, "reader %d info %v, model %d %d", reader, info, len(run.view), attrs) && ok
	elem := quant_elem(o.quant)
	for name in run.names {
		ref, found := view_find(&v, bytes_of(name))
		want := oracle_resolve(o, reader, name)
		if want < 0 {
			ok = testing.expectf(t, !found, "reader %d finds hidden %q", reader, name) && ok
			continue
		}
		if !testing.expectf(t, found && ref_label(s, ref) == o.copies[want].label, "reader %d resolves %q to %v, model label %d", reader, name, ref, o.copies[want].label) {
			ok = false
			continue
		}
		c := &o.copies[want]
		enc := make([]u8, vmath.elem_vector_bytes(elem, o.dim), context.temp_allocator)
		norm, _ := vmath.encode(elem, c.vector, enc)
		raw := ref_raw_embedding(s, ref)
		ok = testing.expectf(t, string(raw.data) == string(enc) && transmute(u32)raw.norm == transmute(u32)vmath.stored_norm(norm), "reader %d copy of %q holds another vector", reader, name) && ok
		text, has := ref_attribute(s, ref)
		ok = testing.expectf(t, has == c.has_attr && (!has || text == c.attr), "reader %d attribute of %q is %q", reader, name, text) && ok
	}
	clear(&run.refs)
	view_range(&v, {kind = .Min}, {kind = .Max}, -1, &run.refs)
	sorted := make([dynamic]string, context.temp_allocator)
	for i in run.view {
		append(&sorted, o.copies[i].name)
	}
	slice.sort_by(sorted[:], proc(a, b: string) -> bool {
		return lex_compare(transmute([]u8)a, transmute([]u8)b) < 0
	})
	same := len(run.refs) == len(sorted)
	for ref, i in run.refs {
		same = same && i < len(sorted) && string(ref_name(s, ref)) == sorted[i]
	}
	ok = testing.expectf(t, same, "reader %d range differs", reader) && ok
	q := make([]f32, o.dim, context.temp_allocator)
	random_vector(&run.r, q)
	filter := test_below(&run.r, 3)
	count := 1 + test_below(&run.r, 12)
	if len(v.parts) > 0 {
		words := make([]u64, vmath.query_bytes(&v.parts[0].part.arena) / 8 + 1, context.temp_allocator)
		qe, encoded := vmath.query_encode(&v.parts[0].part.arena, q, slice.to_bytes(words))
		testing.expect(t, encoded)
		expected := make([dynamic]Named_Hit, context.temp_allocator)
		for i in run.view {
			c := &o.copies[i]
			if !oracle_accept(c, filter) {
				continue
			}
			ref, _ := view_find(&v, bytes_of(c.name))
			p := ref_part(s, ref)
			append(&expected, Named_Hit{score = vmath.arena_query_score(&p.arena, qe, ref.slot), name = transmute([]u8)c.name})
		}
		slice.sort_by(expected[:], named_better)
		texts := FILTER_TEXTS
		for truth in ([]bool{true, false}) {
			req := Search_Request{kind = .Vector, vector = q, count = count, truth = truth, filter = texts[filter], use_filter = filter > 0}
			clear(&run.hits)
			f := view_search(&v, &req, &run.sc, &run.hits)
			testing.expect_value(t, f.err, Error.None)
			if !truth && !all_flat(&v) {
				ok = check_hits_shape(t, s, &v, run.hits[:], count) && ok
				continue
			}
			n := min(count, len(expected))
			match := len(run.hits) == n
			for h, i in run.hits {
				match = match && i < n && string(hit_name(s, h)) == string(expected[i].name) && transmute(u64)h.score == transmute(u64)expected[i].score
			}
			ok = testing.expectf(t, match, "reader %d search truth %v filter %d count %d differs: %d hits, %d expected", reader, truth, filter, count, len(run.hits), n) && ok
		}
	}
	clear(&run.refs)
	want := 1 + test_below(&run.r, 6)
	view_random_distinct(&v, want, &run.refs)
	seen := make(map[string]bool, context.temp_allocator)
	good := len(run.refs) == min(want, len(run.view))
	for ref in run.refs {
		name := string(ref_name(s, ref))
		back, found := view_find(&v, transmute([]u8)name)
		good = good && found && back == ref && !seen[name]
		seen[name] = true
	}
	ok = testing.expectf(t, good, "reader %d sample is not a distinct subset of the view", reader) && ok
	for i in run.view {
		name := o.copies[i].name
		if !view_links(&v, bytes_of(name), &run.sc, &run.links) {
			ok = testing.expectf(t, false, "reader %d has no links for %q", reader, name) && ok
			continue
		}
		self, _ := view_find(&v, bytes_of(name))
		for ref in run.links.refs {
			back, found := view_find(&v, ref_name(s, ref))
			ok = testing.expectf(t, ref.part == self.part && ref != self && found && back == ref, "reader %d link of %q is not a resolved copy in its partition", reader, name) && ok
		}
	}
	return ok
}

all_flat :: proc(v: ^View) -> bool {
	for vp in v.parts {
		if vp.part.mode != .Flat {
			return false
		}
	}
	return true
}

check_hits_shape :: proc(t: ^testing.T, s: Vset, v: ^View, hits: []Hit, count: int) -> bool {
	ok := len(hits) <= count
	seen := make(map[string]bool, context.temp_allocator)
	for h, i in hits {
		name := string(hit_name(s, h))
		back, found := view_find(v, transmute([]u8)name)
		ok = ok && found && back == hit_ref(h) && !seen[name]
		seen[name] = true
		if i > 0 {
			ok = ok && named_better(Named_Hit{score = hits[i - 1].score, name = hit_name(s, hits[i - 1]), part = hits[i - 1].part, slot = hits[i - 1].slot}, Named_Hit{score = h.score, name = hit_name(s, h), part = h.part, slot = h.slot})
		}
	}
	return testing.expectf(t, ok, "graph search hits are not distinct resolved copies in order")
}

oracle_run :: proc(t: ^testing.T, seed: u64, quant: Quant, dim: int, steps: int, levels: int, compartments: int, labels: int, flat: int, shrink: int) {
	old := limits_set(flat, shrink)
	defer limits_restore(old)
	run := new(Oracle_Run)
	defer free(run)
	run.t = t
	run.r = Test_Rng{state = seed}
	scheme_init(&run.scheme, &run.r, levels, compartments, labels)
	defer scheme_destroy(&run.scheme)
	run.o = Oracle{scheme = &run.scheme, quant = quant, dim = dim}
	defer oracle_destroy(&run.o)
	scratch_init(&run.sc)
	defer scratch_destroy(&run.sc)
	defer delete(run.view)
	defer delete(run.hits)
	defer delete(run.refs)
	defer links_destroy(&run.links)
	defer {
		for n in run.names {
			delete(n)
		}
		delete(run.names)
	}
	for i in 0 ..< 24 {
		append(&run.names, fmt.aprintf("n%d", i))
	}
	append(&run.names, fmt.aprintf(""))
	append(&run.names, fmt.aprintf("n1\x00"))
	for step in 0 ..< steps {
		if !oracle_op(run) {
			break
		}
		if run.s != nil && (step % 17 == 0 || step == steps - 1) {
			if !check_labelled(t, run.s) {
				break
			}
			failed := false
			for reader in 0 ..< len(run.scheme.ids) {
				if !oracle_check_reader(run, reader) {
					failed = true
				}
			}
			if failed {
				testing.expectf(t, false, "seed %x failed at step %d", seed, step)
				break
			}
		}
		free_all(context.temp_allocator)
	}
	if run.s != nil {
		destroy(run.s)
	}
	log.infof("oracle %x %v: %d reader checks, %d refusals, %d forced copies, %d shadowed copies seen, %d graph partitions seen, up to %d visible partitions", seed, quant, run.stats.checks, run.stats.refused, run.stats.forced, run.stats.shadowed, run.stats.graphs, run.stats.parts)
}

@(test)
labelled_views_match_the_model :: proc(t: ^testing.T) {
	oracle_run(t, 0xA11CE, .Q8, 4, 900, 3, 2, 7, FLAT_LIMIT_DEFAULT, SHRINK_LIMIT_DEFAULT)
	oracle_run(t, 0xB0B, .NOQUANT, 3, 900, 2, 3, 9, FLAT_LIMIT_DEFAULT, SHRINK_LIMIT_DEFAULT)
	oracle_run(t, 0xC0FFEE, .BIN, 16, 700, 4, 1, 6, FLAT_LIMIT_DEFAULT, SHRINK_LIMIT_DEFAULT)
}

@(test)
labelled_views_match_the_model_across_graph_partitions :: proc(t: ^testing.T) {
	oracle_run(t, 0xD1CE, .Q8, 4, 1200, 2, 2, 5, 6, 2)
	oracle_run(t, 0xE66, .NOQUANT, 5, 1200, 3, 1, 4, 4, 1)
}

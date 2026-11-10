package vsettype

import "core:fmt"
import "core:log"
import "core:slice"
import "core:testing"
import lbl "../label"
import "../vmath"

OWNERS_TESTED :: 4

Owned_Copy :: struct {
	name:     string,
	label:    lbl.Id,
	owner:    Owner,
	vector:   []f32,
	attr:     string,
	has_attr: bool,
	born:     int,
}

Owner_Model :: struct {
	copies: [dynamic]Owned_Copy,
	born:   int,
	scheme: ^Scheme,
	quant:  Quant,
	dim:    int,
}

Owner_Run :: struct {
	t:       ^testing.T,
	o:       Owner_Model,
	scheme:  Scheme,
	streams: [dynamic][OWNERS_TESTED]u64,
	s:       Vset,
	sc:      Scratch,
	r:       Test_Rng,
	names:   [dynamic]string,
	view:    [dynamic]int,
	hits:    [dynamic]Hit,
	refs:    [dynamic]Ref,
	links:   Links,
	stats:   Owner_Stats,
}

Owner_Stats :: struct {
	refused:      int,
	refused_own:  int,
	forced:       int,
	checks:       int,
	shadowed:     int,
	graphs:       int,
	own_graphs:   int,
	compact:      int,
	scope_drops:  int,
	owner_drops:  int,
	cross_shadow: int,
}

owner_model_destroy :: proc(m: ^Owner_Model) {
	for c in m.copies {
		delete(c.name)
		delete(c.vector)
		delete(c.attr)
	}
	delete(m.copies)
}

model_rank :: proc(m: ^Owner_Model, id: lbl.Id) -> [3]int {
	l, _ := lbl.table_label(&m.scheme.table, id)
	return {int(l.level), lbl.compartment_count(l), int(l.trust)}
}

model_higher :: proc(m: ^Owner_Model, a: ^Owned_Copy, b: ^Owned_Copy) -> bool {
	ra := model_rank(m, a.label)
	rb := model_rank(m, b.label)
	if ra != rb {
		for i in 0 ..< 3 {
			if ra[i] != rb[i] {
				return ra[i] > rb[i]
			}
		}
	}
	if a.owner != b.owner {
		return a.owner != SHARED
	}
	return a.born < b.born
}

model_exact :: proc(m: ^Owner_Model, name: string, l: lbl.Id, o: Owner) -> int {
	for &c, i in m.copies {
		if c.name == name && c.label == l && c.owner == o {
			return i
		}
	}
	return -1
}

model_sees :: proc(m: ^Owner_Model, reader: int, o: Owner, c: ^Owned_Copy) -> bool {
	return (c.owner == SHARED || c.owner == o) && scheme_sees(m.scheme, reader, c.label)
}

model_visible_other :: proc(m: ^Owner_Model, reader: int, o: Owner, name: string) -> int {
	own := m.scheme.ids[reader]
	if o != SHARED {
		if i := model_exact(m, name, own, SHARED); i >= 0 {
			return i
		}
	}
	best := -1
	for &c, i in m.copies {
		if c.name != name || (c.label == own && c.owner == o) || !model_sees(m, reader, o, &c) {
			continue
		}
		if best < 0 || model_higher(m, &c, &m.copies[best]) {
			best = i
		}
	}
	return best
}

model_resolve :: proc(m: ^Owner_Model, reader: int, o: Owner, name: string) -> int {
	if i := model_exact(m, name, m.scheme.ids[reader], o); i >= 0 {
		return i
	}
	return model_visible_other(m, reader, o, name)
}

model_view :: proc(m: ^Owner_Model, reader: int, o: Owner, out: ^[dynamic]int) {
	clear(out)
	for c, i in m.copies {
		if model_resolve(m, reader, o, c.name) == i {
			append(out, i)
		}
	}
}

model_has_scope :: proc(m: ^Owner_Model, l: lbl.Id, o: Owner) -> bool {
	for c in m.copies {
		if c.label == l && c.owner == o {
			return true
		}
	}
	return false
}

model_scope_card :: proc(m: ^Owner_Model, l: lbl.Id, o: Owner) -> int {
	n := 0
	for c in m.copies {
		if c.label == l && c.owner == o {
			n += 1
		}
	}
	return n
}

model_drop :: proc(m: ^Owner_Model, i: int) {
	c := m.copies[i]
	ordered_remove(&m.copies, i)
	delete(c.name)
	delete(c.vector)
	delete(c.attr)
}

run_access :: proc(run: ^Owner_Run, reader: int, o: Owner, top := false) -> Access {
	a := scheme_access(&run.scheme, reader, top)
	a.owner = o
	if o != SHARED {
		a.stream = &run.streams[reader][int(o)]
	}
	return a
}

pick_owner :: proc(r: ^Test_Rng) -> Owner {
	if test_below(r, 3) == 0 {
		return SHARED
	}
	return Owner(1 + test_below(r, OWNERS_TESTED - 1))
}

expect_refusal :: proc(t: ^testing.T, f: Failure, c: ^Owned_Copy, what: string, name: string) -> bool {
	return testing.expectf(t, f.err == .Name_In_Use && f.label == c.label && f.owner == c.owner, "%s %q should be refused at %d/%d: %v %d/%d", what, name, c.label, c.owner, f.err, f.label, f.owner)
}

owner_op :: proc(run: ^Owner_Run) -> bool {
	t := run.t
	m := &run.o
	r := &run.r
	w := test_below(r, len(run.scheme.ids))
	o := pick_owner(r)
	a := run_access(run, w, o)
	own := run.scheme.ids[w]
	name := run.names[test_below(r, len(run.names))]
	op := test_below(r, 14)
	exact := model_exact(m, name, own, o)
	other := model_visible_other(m, w, o, name)
	x := make([]f32, m.dim, context.temp_allocator)
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
	case op < 8:
		set_attr := test_below(r, 2) == 0
		if run.s == nil {
			req := Add_Request{name = bytes_of(name), vector = x, quant = m.quant}
			created, f := create_at(&req, &a)
			if !testing.expect_value(t, f.err, Error.None) {
				return false
			}
			run.s = created
		}
		had := model_has_scope(m, own, o)
		ch, f := labelled_add(run.s, &a, name, x, &run.sc, m.quant, attr, set_attr)
		if exact >= 0 {
			c := &m.copies[exact]
			delete(c.vector)
			c.vector = slice.clone(x)
			if set_attr {
				delete(c.attr)
				c.attr = fmt.aprintf("%s", attr)
				c.has_attr = len(attr) > 0
			}
			testing.expectf(t, f.err == .None && !ch.added, "update %q at %d/%d: %v %v", name, own, o, f.err, ch)
		} else if other >= 0 {
			run.stats.refused += 1
			if m.copies[other].owner != SHARED {
				run.stats.refused_own += 1
			}
			expect_refusal(t, f, &m.copies[other], "add", name)
		} else {
			for c in m.copies {
				if c.name == name {
					run.stats.forced += 1
					break
				}
			}
			append(&m.copies, Owned_Copy{name = fmt.aprintf("%s", name), label = own, owner = o, vector = slice.clone(x), attr = fmt.aprintf("%s", attr), has_attr = set_attr, born = m.born})
			m.born += 1
			testing.expectf(t, f.err == .None && ch.added && ch.label_new == !had, "add %q at %d/%d: %v %v", name, own, o, f.err, ch)
		}
	case op < 10 && run.s != nil:
		ch, f := remove_at(run.s, &a, bytes_of(name), &run.sc)
		if exact >= 0 {
			model_drop(m, exact)
			testing.expectf(t, f.err == .None && ch.found && ch.label_gone == !model_has_scope(m, own, o) && ch.emptied == (len(m.copies) == 0), "remove %q at %d/%d: %v %v", name, own, o, f.err, ch)
		} else if other >= 0 {
			expect_refusal(t, f, &m.copies[other], "remove", name)
		} else {
			testing.expectf(t, f.err == .None && !ch.found, "remove %q at %d/%d should miss: %v %v", name, own, o, f.err, ch)
		}
	case op < 11 && run.s != nil:
		ch, f := set_attribute_at(run.s, &a, bytes_of(name), bytes_of(attr))
		if exact >= 0 {
			c := &m.copies[exact]
			delete(c.attr)
			c.attr = fmt.aprintf("%s", attr)
			c.has_attr = len(attr) > 0
			testing.expectf(t, f.err == .None && ch.found, "setattr %q at %d/%d: %v", name, own, o, f.err)
		} else if other >= 0 {
			expect_refusal(t, f, &m.copies[other], "setattr", name)
		} else {
			testing.expectf(t, f.err == .None && !ch.found, "setattr %q at %d/%d should miss", name, own, o)
		}
	case op < 12 && run.s != nil:
		removed, rc := remove_scope(run.s, own, o)
		want := 0
		for i := len(m.copies) - 1; i >= 0; i -= 1 {
			if m.copies[i].label == own && m.copies[i].owner == o {
				model_drop(m, i)
				want += 1
			}
		}
		run.stats.scope_drops += 1
		testing.expectf(t, removed == want && rc.found == (want > 0) && rc.label_gone == (want > 0) && rc.emptied == (len(m.copies) == 0), "remove scope %d/%d: %d %v against %d", own, o, removed, rc, want)
	case op < 13 && run.s != nil && o != SHARED:
		labels := make([dynamic]lbl.Id, context.temp_allocator)
		removed, rc := remove_owner(run.s, o, &labels)
		want := 0
		for i := len(m.copies) - 1; i >= 0; i -= 1 {
			if m.copies[i].owner == o {
				model_drop(m, i)
				want += 1
			}
		}
		run.stats.owner_drops += 1
		testing.expectf(t, removed == want && rc.found == (want > 0) && rc.emptied == (len(m.copies) == 0), "remove owner %d: %d %v against %d", o, removed, rc, want)
		for l in labels {
			testing.expect(t, !has_scope(run.s, l, o))
		}
	case run.s != nil:
		to := test_below(r, len(run.scheme.ids))
		target := run_access(run, to, o)
		gone, fresh, f := relabel_at(run.s, &a, &target, bytes_of(name), &run.sc)
		dest := run.scheme.ids[to]
		if exact >= 0 {
			if blocker := model_exact(m, name, dest, o); blocker >= 0 {
				testing.expectf(t, f.err == .Name_In_Use && f.label == dest && f.owner == o, "relabel %q %d/%d to %d over its own copy: %v", name, own, o, dest, f.err)
			} else {
				had := model_has_scope(m, dest, o)
				c := &m.copies[exact]
				c.label = dest
				c.born = m.born
				m.born += 1
				testing.expectf(t, f.err == .None && gone == !model_has_scope(m, own, o) && fresh == !had, "relabel %q %d/%d to %d: %v %v %v", name, own, o, dest, f.err, gone, fresh)
			}
		} else if other >= 0 {
			expect_refusal(t, f, &m.copies[other], "relabel", name)
		} else {
			testing.expectf(t, f.err == .Element_Not_Found, "relabel %q %d/%d should miss: %v", name, own, o, f.err)
		}
	}
	if run.s != nil && len(m.copies) == 0 {
		testing.expect_value(t, card(run.s), 0)
		destroy(run.s)
		run.s = nil
	}
	return true
}

owner_check_reader :: proc(run: ^Owner_Run, reader: int, o: Owner) -> bool {
	t := run.t
	m := &run.o
	s := run.s
	a := run_access(run, reader, o)
	v, err := view_open(s, &a, &run.sc)
	testing.expect_value(t, err, Error.None)
	model_view(m, reader, o, &run.view)
	run.stats.checks += 1
	for vp in v.parts {
		run.stats.shadowed += len(vp.shadow)
		if vp.part.mode == .Graph {
			run.stats.graphs += 1
			if vp.part.owner != SHARED {
				run.stats.own_graphs += 1
			}
		}
		if vp.part.kind == .Compact {
			run.stats.compact += 1
		}
		if vp.part.owner != SHARED && len(vp.shadow) > 0 {
			run.stats.cross_shadow += 1
		}
		if !testing.expectf(t, vp.part.owner == SHARED || vp.part.owner == o, "reader %d/%d view holds owner %d", reader, o, vp.part.owner) {
			return false
		}
	}
	ok := testing.expectf(t, view_size(&v) == len(run.view), "reader %d/%d sees %d, model %d", reader, o, view_size(&v), len(run.view))
	ok = testing.expectf(t, has_visible(s, &a) == (len(run.view) > 0), "reader %d/%d has_visible %v, model %d", reader, o, has_visible(s, &a), len(run.view)) && ok
	attrs := 0
	for i in run.view {
		if m.copies[i].has_attr {
			attrs += 1
		}
	}
	info := view_info(&v)
	ok = testing.expectf(t, info.size == len(run.view) && info.attributes_count == attrs, "reader %d/%d info %v, model %d %d", reader, o, info, len(run.view), attrs) && ok
	elem := quant_elem(m.quant)
	for name in run.names {
		ref, found := view_find(&v, bytes_of(name))
		want := model_resolve(m, reader, o, name)
		if want < 0 {
			ok = testing.expectf(t, !found, "reader %d/%d finds hidden %q", reader, o, name) && ok
			continue
		}
		c := &m.copies[want]
		if !testing.expectf(t, found && ref_label(s, ref) == c.label && ref_owner(s, ref) == c.owner, "reader %d/%d resolves %q to %v, model %d/%d", reader, o, name, ref, c.label, c.owner) {
			ok = false
			continue
		}
		enc := make([]u8, vmath.elem_vector_bytes(elem, m.dim), context.temp_allocator)
		norm, _ := vmath.encode(elem, c.vector, enc)
		raw := ref_raw_embedding(s, ref)
		ok = testing.expectf(t, string(raw.data) == string(enc) && transmute(u32)raw.norm == transmute(u32)vmath.stored_norm(norm), "reader %d/%d copy of %q holds another vector", reader, o, name) && ok
		text, has := ref_attribute(s, ref)
		ok = testing.expectf(t, has == c.has_attr && (!has || text == c.attr), "reader %d/%d attribute of %q is %q", reader, o, name, text) && ok
	}
	clear(&run.refs)
	view_range(&v, {kind = .Min}, {kind = .Max}, -1, &run.refs)
	sorted := make([dynamic]string, context.temp_allocator)
	for i in run.view {
		append(&sorted, m.copies[i].name)
	}
	slice.sort_by(sorted[:], proc(a, b: string) -> bool {
		return lex_compare(transmute([]u8)a, transmute([]u8)b) < 0
	})
	same := len(run.refs) == len(sorted)
	for ref, i in run.refs {
		same = same && i < len(sorted) && string(ref_name(s, ref)) == sorted[i]
	}
	ok = testing.expectf(t, same, "reader %d/%d range differs", reader, o) && ok
	if len(sorted) > 2 {
		lo := sorted[1]
		clear(&run.refs)
		view_range(&v, {kind = .Exclusive, value = bytes_of(lo)}, {kind = .Inclusive, value = bytes_of(sorted[len(sorted) - 1])}, 2, &run.refs)
		part_ok := len(run.refs) == min(2, len(sorted) - 2)
		for ref, i in run.refs {
			part_ok = part_ok && string(ref_name(s, ref)) == sorted[2 + i]
		}
		ok = testing.expectf(t, part_ok, "reader %d/%d bounded range differs", reader, o) && ok
	}
	q := make([]f32, m.dim, context.temp_allocator)
	random_vector(&run.r, q)
	filter := test_below(&run.r, 3)
	count := 1 + test_below(&run.r, 12)
	if len(v.parts) > 0 {
		words := make([]u64, vmath.query_bytes(&v.parts[0].part.arena) / 8 + 1, context.temp_allocator)
		qe, encoded := vmath.query_encode(&v.parts[0].part.arena, q, slice.to_bytes(words))
		testing.expect(t, encoded)
		expected := make([dynamic]Named_Hit, context.temp_allocator)
		for i in run.view {
			c := &m.copies[i]
			copy_model := Oracle_Copy{name = c.name, label = c.label, vector = c.vector, attr = c.attr, has_attr = c.has_attr, born = c.born}
			if !oracle_accept(&copy_model, filter) {
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
			ok = testing.expectf(t, match, "reader %d/%d search truth %v filter %d count %d differs: %d hits, %d expected", reader, o, truth, filter, count, len(run.hits), n) && ok
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
	ok = testing.expectf(t, good, "reader %d/%d sample is not a distinct subset of the view", reader, o) && ok
	for i in run.view {
		name := m.copies[i].name
		if !view_links(&v, bytes_of(name), &run.sc, &run.links) {
			ok = testing.expectf(t, false, "reader %d/%d has no links for %q", reader, o, name) && ok
			continue
		}
		self, _ := view_find(&v, bytes_of(name))
		for ref in run.links.refs {
			back, found := view_find(&v, ref_name(s, ref))
			ok = testing.expectf(t, ref.part == self.part && ref != self && found && back == ref, "reader %d/%d link of %q is not a resolved copy in its partition", reader, o, name) && ok
		}
	}
	top, has_top := top_visible_scope(s, &a)
	if len(run.view) == 0 {
		ok = testing.expectf(t, !has_top || has_scope(s, top.label, top.owner), "reader %d/%d top scope without data", reader, o) && ok
	} else {
		ok = testing.expectf(t, has_top && (top.owner == SHARED || top.owner == o) && has_scope(s, top.label, top.owner) && scheme_sees(&run.scheme, reader, top.label), "reader %d/%d top scope %v", reader, o, top) && ok
	}
	return ok
}

owner_check_scopes :: proc(run: ^Owner_Run) -> bool {
	t := run.t
	ok := true
	for id in run.scheme.ids {
		for k in 0 ..< OWNERS_TESTED {
			o := Owner(k)
			want := model_scope_card(&run.o, id, o)
			ok = testing.expectf(t, has_scope(run.s, id, o) == (want > 0) && scope_card(run.s, id, o) == want, "scope %d/%d holds %d, model %d", id, o, scope_card(run.s, id, o), want) && ok
			if want == 0 {
				ok = testing.expectf(t, scope_memory(run.s, id, o) == 0, "empty scope %d/%d has memory", id, o) && ok
			} else {
				ok = testing.expectf(t, scope_memory(run.s, id, o) > 0, "scope %d/%d has no memory", id, o) && ok
			}
		}
	}
	shared := 0
	for c in run.o.copies {
		if c.owner == SHARED {
			shared += 1
		}
	}
	ok = testing.expectf(t, card(run.s) == len(run.o.copies), "card %d model %d", card(run.s), len(run.o.copies)) && ok
	return ok
}

owner_oracle_run :: proc(t: ^testing.T, seed: u64, quant: Quant, dim: int, steps: int, levels: int, compartments: int, labels: int, flat: int, shrink: int) {
	old := limits_set(flat, shrink)
	defer limits_restore(old)
	run := new(Owner_Run)
	defer free(run)
	run.t = t
	run.r = Test_Rng{state = seed}
	scheme_init(&run.scheme, &run.r, levels, compartments, labels, 3)
	defer scheme_destroy(&run.scheme)
	for i in 0 ..< len(run.scheme.ids) {
		row: [OWNERS_TESTED]u64
		for k in 0 ..< OWNERS_TESTED {
			row[k] = stream_seed(run.scheme.ids[i]) ~ (u64(k + 1) * 0xA5A5_5A5A_0F0F_F0F1)
		}
		append(&run.streams, row)
	}
	defer delete(run.streams)
	run.o = Owner_Model{scheme = &run.scheme, quant = quant, dim = dim}
	defer owner_model_destroy(&run.o)
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
	for i in 0 ..< 18 {
		append(&run.names, fmt.aprintf("n%d", i))
	}
	append(&run.names, fmt.aprintf(""))
	append(&run.names, fmt.aprintf("n1\x00"))
	for step in 0 ..< steps {
		if !owner_op(run) {
			break
		}
		if run.s != nil && (step % 13 == 0 || step == steps - 1) {
			if !check_labelled(t, run.s) || !owner_check_scopes(run) {
				testing.expectf(t, false, "seed %x broke its invariants at step %d", seed, step)
				break
			}
			failed := false
			for reader in 0 ..< len(run.scheme.ids) {
				for k in 0 ..< OWNERS_TESTED {
					if !owner_check_reader(run, reader, Owner(k)) {
						failed = true
					}
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
	st := run.stats
	log.infof("owner oracle %x %v: %d reader checks, %d refusals (%d naming an own copy), %d forced copies, %d shadowed copies seen, %d graph partitions seen (%d owned), %d compact partitions seen, %d owned partitions with shadows, %d scope drops, %d owner drops", seed, quant, st.checks, st.refused, st.refused_own, st.forced, st.shadowed, st.graphs, st.own_graphs, st.compact, st.cross_shadow, st.scope_drops, st.owner_drops)
}

@(test)
owner_views_match_the_model :: proc(t: ^testing.T) {
	owner_oracle_run(t, 0x0A11CE, .Q8, 4, 900, 3, 2, 6, FLAT_LIMIT_DEFAULT, SHRINK_LIMIT_DEFAULT)
	owner_oracle_run(t, 0x0B0B, .NOQUANT, 3, 900, 2, 3, 7, FLAT_LIMIT_DEFAULT, SHRINK_LIMIT_DEFAULT)
	owner_oracle_run(t, 0x0C0FFEE, .BIN, 16, 700, 4, 1, 5, FLAT_LIMIT_DEFAULT, SHRINK_LIMIT_DEFAULT)
}

@(test)
owner_views_match_the_model_across_graph_partitions :: proc(t: ^testing.T) {
	owner_oracle_run(t, 0x0D1CE, .Q8, 4, 1400, 2, 2, 4, 5, 2)
	owner_oracle_run(t, 0x0E66, .NOQUANT, 5, 1400, 3, 1, 4, 4, 1)
}

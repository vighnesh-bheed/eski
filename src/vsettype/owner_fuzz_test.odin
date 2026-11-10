package vsettype

import "core:log"
import "core:testing"
import lbl "../label"

Owner_Fuzz :: struct {
	using fuzz: Fuzz,
	streams:    [dynamic][OWNERS_TESTED]u64,
	owners:     [8]int,
}

owner_fuzz_access :: proc(f: ^Owner_Fuzz, top := false) -> Access {
	i := test_below(&f.r, len(f.scheme.ids))
	o := pick_owner(&f.r)
	a := scheme_access(&f.scheme, i, top)
	a.owner = o
	if o != SHARED {
		a.stream = &f.streams[i][int(o)]
	}
	return a
}

owner_fuzz_read :: proc(f: ^Owner_Fuzz) {
	t := f.t
	s := f.s
	a := owner_fuzz_access(f, test_below(&f.r, 9) == 0)
	v, err := view_open(s, &a, &f.sc)
	testing.expect_value(t, err, Error.None)
	for vp in v.parts {
		testing.expect(t, vp.part.owner == SHARED || vp.part.owner == a.owner)
	}
	f.counts[4] += 1
	switch test_below(&f.r, 6) {
	case 0, 1:
		req := Search_Request{kind = .Vector, vector = fuzz_vector(f), count = 1 + test_below(&f.r, 30), ef = test_below(&f.r, 3) * 40, truth = test_below(&f.r, 3) == 0, epsilon = 0.5, use_epsilon = test_below(&f.r, 4) == 0, filter = ".a >= 2", use_filter = test_below(&f.r, 3) == 0, filter_ef = test_below(&f.r, 3) * 15}
		if test_below(&f.r, 4) == 0 {
			req.kind = .Element
			req.element = bytes_of(fuzz_name(f))
		}
		clear(&f.hits)
		failed := view_search(&v, &req, &f.sc, &f.hits)
		if failed.err == .None {
			check_hits_shape(t, s, &v, f.hits[:], req.count)
		} else {
			testing.expectf(t, failed.err == .Element_Not_Found && req.kind == .Element, "search failed with %v", failed.err)
		}
	case 2:
		name := fuzz_name(f)
		if view_links(&v, bytes_of(name), &f.sc, &f.links) {
			self, _ := view_find(&v, bytes_of(name))
			for r in f.links.refs {
				back, found := view_find(&v, ref_name(s, r))
				testing.expect(t, found && back == r && r.part == self.part && r != self)
			}
		}
	case 3:
		clear(&f.refs)
		view_random_distinct(&v, test_below(&f.r, 12), &f.refs)
		view_random_repeats(&v, test_below(&f.r, 5), &f.refs)
		for r in f.refs {
			back, found := view_find(&v, ref_name(s, r))
			testing.expect(t, found && back == r)
		}
	case 4:
		clear(&f.refs)
		lo := Lex_Bound{kind = Lex_Kind(test_below(&f.r, 4)), value = bytes_of(fuzz_name(f))}
		hi := Lex_Bound{kind = Lex_Kind(test_below(&f.r, 4)), value = bytes_of(fuzz_name(f))}
		view_range(&v, lo, hi, test_below(&f.r, 8) - 1, &f.refs)
		for r, i in f.refs {
			if i > 0 {
				testing.expect(t, lex_compare(ref_name(s, f.refs[i - 1]), ref_name(s, r)) < 0)
			}
			back, found := view_find(&v, ref_name(s, r))
			testing.expect(t, found && back == r)
		}
	case:
		info := view_info(&v)
		testing.expect(t, info.size == view_size(&v) && info.attributes_count >= 0 && info.attributes_count <= info.size)
		testing.expect(t, view_memory(&v) >= 0 && view_serialized_size(&v) >= 0)
		testing.expect(t, a.top || view_memory(&v) == expected_memory_of(&v))
		testing.expect(t, has_visible(s, &a) == (view_size(&v) > 0))
	}
}

owner_fuzz_step :: proc(f: ^Owner_Fuzz) {
	t := f.t
	if f.s == nil {
		w := owner_fuzz_access(f)
		req := fuzz_request(f, fuzz_name(f))
		if test_below(&f.r, 4) == 0 {
			s, failed := create_for(&req)
			testing.expect_value(f.t, failed.err, Error.None)
			for _ in 0 ..< 1 + test_below(&f.r, 30) {
				more := fuzz_request(f, fuzz_name(f))
				add(s, &more, &f.sc)
			}
			f.s = s
			return
		}
		s, failed := create_at(&req, &w)
		testing.expect_value(f.t, failed.err, Error.None)
		add_at(s, &w, &req, &f.sc)
		f.s = s
		if card(s) == 0 {
			destroy(s)
			f.s = nil
		}
		return
	}
	s := f.s
	w := owner_fuzz_access(f)
	emptied := false
	switch test_below(&f.r, 24) {
	case 0 ..= 7:
		req := fuzz_request(f, fuzz_name(f))
		ch, failed := add_at(s, &w, &req, &f.sc)
		testing.expect(t, failed.err == .None || failed.err == .Name_In_Use)
		if failed.err == .Name_In_Use {
			testing.expect(t, failed.owner == SHARED || failed.owner == w.owner)
		}
		emptied = ch.emptied
		f.counts[0] += 1
	case 8 ..= 10:
		ch, _ := remove_at(s, &w, bytes_of(fuzz_name(f)), &f.sc)
		emptied = ch.emptied
	case 11:
		set_attribute_at(s, &w, bytes_of(fuzz_name(f)), bytes_of(`{"a":3}`))
	case 12:
		req := fuzz_request(f, fuzz_name(f))
		plan: Cas_Plan
		if cas_prepare_at(s, &w, &req, &plan, &f.sc).err == .None {
			if test_below(&f.r, 2) == 0 {
				other := fuzz_request(f, fuzz_name(f))
				add_at(s, &w, &other, &f.sc)
			}
			ch, _ := cas_commit_at(s, &w, &plan, &f.sc)
			emptied = ch.emptied
		}
		cas_discard(&plan)
		f.counts[1] += 1
	case 13:
		if test_below(&f.r, 3) == 0 {
			_, rc := remove_scope(s, w.label, w.owner)
			emptied = rc.emptied
		}
	case 14:
		if w.owner != SHARED && test_below(&f.r, 3) == 0 {
			labels := make([dynamic]lbl.Id, context.temp_allocator)
			_, rc := remove_owner(s, w.owner, &labels)
			emptied = rc.emptied
			for l in labels {
				testing.expect(t, !has_scope(s, l, w.owner))
			}
			f.owners[0] += 1
		}
	case 15:
		at := test_below(&f.r, len(f.scheme.ids))
		to := scheme_access(&f.scheme, at)
		to.owner = w.owner
		if w.owner != SHARED {
			to.stream = &f.streams[at][int(w.owner)]
		}
		relabel_at(s, &w, &to, bytes_of(fuzz_name(f)), &f.sc)
		emptied = card(s) == 0
	case 16:
		if s.lab != nil && (s.lab.sorted_len > 0 || s.lab.owners != nil) {
			labels := make([dynamic]lbl.Id, context.temp_allocator)
			if w.owner == SHARED {
				labels_present(s, &labels)
			} else {
				owner_labels(s, w.owner, &labels)
			}
			l := labels[test_below(&f.r, len(labels))] if len(labels) > 0 else lbl.ID_NONE
			if len(labels) > 0 && card(s) > scope_card(s, l, w.owner) {
				part, sch, err := split_scope(s, l, w.owner)
				testing.expect_value(t, err, Error.None)
				testing.expect(t, sch.label_gone && !sch.emptied)
				check_labelled(t, part)
				check_labelled(t, s)
				testing.expect(t, has_scope(part, l, w.owner) && !has_scope(s, l, w.owner))
				testing.expect_value(t, absorb(s, part), Error.None)
				testing.expect(t, card(part) == 0 && has_scope(s, l, w.owner))
				destroy(part)
				f.counts[2] += 1
			}
		}
	case:
		owner_fuzz_read(f)
	}
	if emptied || card(s) == 0 {
		destroy(s)
		f.s = nil
	}
}

owner_fuzz_run :: proc(t: ^testing.T, seed: u64, steps: int) {
	f := new(Owner_Fuzz)
	defer free(f)
	f.t = t
	f.r = Test_Rng{state = seed}
	scheme_init(&f.scheme, &f.r, 3, 2, 6, 2)
	defer scheme_destroy(&f.scheme)
	for i in 0 ..< len(f.scheme.ids) {
		row: [OWNERS_TESTED]u64
		for k in 0 ..< OWNERS_TESTED {
			row[k] = stream_seed(f.scheme.ids[i]) ~ (u64(k + 9) * 0x2545F4914F6CDD1D)
		}
		append(&f.streams, row)
	}
	defer delete(f.streams)
	scratch_init(&f.sc)
	defer scratch_destroy(&f.sc)
	defer delete(f.hits)
	defer delete(f.refs)
	defer delete(f.labels)
	defer links_destroy(&f.links)
	f.quant = Quant(test_below(&f.r, 3))
	f.dim = 2 + test_below(&f.r, 8)
	if test_below(&f.r, 4) == 0 {
		f.reduce = f.dim + 3 + test_below(&f.r, 6)
	}
	most := 0
	for step in 0 ..< steps {
		owner_fuzz_step(f)
		if f.s != nil {
			most = max(most, owner_count(f.s))
		}
		if f.s != nil && step % 25 == 0 {
			if !check_set(t, f.s) {
				testing.expectf(t, false, "owner fuzz seed %x broke at step %d", seed, step)
				break
			}
		}
		free_all(context.temp_allocator)
	}
	if f.s != nil {
		check_set(t, f.s)
		destroy(f.s)
	}
	log.infof("owner fuzz %x %v dim %d reduce %d: %d adds, %d cas, %d split and absorb, %d forgets, %d reads, up to %d owners", seed, f.quant, f.dim, f.reduce, f.counts[0], f.counts[1], f.counts[2], f.owners[0], f.counts[4], most)
}

@(test)
owner_operations_survive_fuzzing :: proc(t: ^testing.T) {
	old := limits_set(6, 2)
	defer limits_restore(old)
	for seed in ([]u64{0x0F1, 0x0F2, 0x0F3, 0x0F4, 0x0F5, 0x0F6, 0x0F7, 0x0F8}) {
		owner_fuzz_run(t, seed, 2500)
	}
}

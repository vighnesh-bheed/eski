package vsettype

import "core:fmt"
import "core:log"
import "core:testing"
import lbl "../label"

Fuzz :: struct {
	t:      ^testing.T,
	r:      Test_Rng,
	scheme: Scheme,
	sc:     Scratch,
	s:      Vset,
	quant:  Quant,
	dim:    int,
	reduce: int,
	hits:   [dynamic]Hit,
	refs:   [dynamic]Ref,
	labels: [dynamic]lbl.Id,
	links:  Links,
	counts: [8]int,
}

fuzz_name :: proc(f: ^Fuzz) -> string {
	switch test_below(&f.r, 6) {
	case 0:
		return ""
	case 1:
		return fmt.tprintf("x%d\x00", test_below(&f.r, 4))
	}
	return fmt.tprintf("k%d", test_below(&f.r, 40))
}

fuzz_vector :: proc(f: ^Fuzz) -> []f32 {
	n := f.reduce if f.reduce > 0 else f.dim
	x := make([]f32, n, context.temp_allocator)
	random_vector(&f.r, x)
	if test_below(&f.r, 8) == 0 {
		for &v in x {
			v = 0.25
		}
	}
	if test_below(&f.r, 20) == 0 {
		for &v in x {
			v = 0
		}
	}
	return x
}

fuzz_request :: proc(f: ^Fuzz, name: string) -> Add_Request {
	req := Add_Request{name = bytes_of(name), vector = fuzz_vector(f), quant = f.quant, ef = test_below(&f.r, 3) * 30}
	if f.reduce > 0 {
		req.reduce = f.dim
	}
	if test_below(&f.r, 2) == 0 {
		req.set_attr = true
		req.attr = bytes_of(fmt.tprintf(`{{"a":%d}}`, test_below(&f.r, 5)) if test_below(&f.r, 6) != 0 else "")
	}
	return req
}

fuzz_create :: proc(f: ^Fuzz) {
	w := scheme_access(&f.scheme, test_below(&f.r, len(f.scheme.ids)))
	req := fuzz_request(f, fuzz_name(f))
	if test_below(&f.r, 3) == 0 {
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
}

fuzz_read :: proc(f: ^Fuzz) {
	t := f.t
	s := f.s
	a := scheme_access(&f.scheme, test_below(&f.r, len(f.scheme.ids)), test_below(&f.r, 9) == 0)
	v, err := view_open(s, &a, &f.sc)
	testing.expect_value(t, err, Error.None)
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
		}
	case:
		info := view_info(&v)
		testing.expect(t, info.size == view_size(&v) && info.attributes_count >= 0 && info.attributes_count <= info.size)
		testing.expect(t, view_memory(&v) >= 0 && view_serialized_size(&v) >= 0)
		testing.expect(t, a.top || view_memory(&v) == expected_memory_of(&v))
	}
}

fuzz_step :: proc(f: ^Fuzz) {
	t := f.t
	if f.s == nil {
		fuzz_create(f)
		return
	}
	s := f.s
	w := scheme_access(&f.scheme, test_below(&f.r, len(f.scheme.ids)))
	emptied := false
	switch test_below(&f.r, 20) {
	case 0 ..= 6:
		req := fuzz_request(f, fuzz_name(f))
		ch, failed := add_at(s, &w, &req, &f.sc)
		testing.expect(t, failed.err == .None || failed.err == .Name_In_Use)
		emptied = ch.emptied
		f.counts[0] += 1
	case 7 ..= 9:
		ch, _ := remove_at(s, &w, bytes_of(fuzz_name(f)), &f.sc)
		emptied = ch.emptied
	case 10:
		set_attribute_at(s, &w, bytes_of(fuzz_name(f)), bytes_of(`{"a":3}`))
	case 11:
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
	case 12:
		if test_below(&f.r, 4) == 0 {
			_, rc := remove_label(s, w.label)
			emptied = rc.emptied
			if emptied {
				destroy(s)
				f.s = nil
				return
			}
		}
	case 13:
		if s.lab != nil && s.lab.sorted_len > 1 {
			l := s.lab.sorted[test_below(&f.r, int(s.lab.sorted_len))].label
			part, sch, err := split_label(s, l)
			testing.expect(t, sch.label_gone && !sch.emptied)
			testing.expect_value(t, err, Error.None)
			check_labelled(t, part)
			check_labelled(t, s)
			testing.expect_value(t, absorb(s, part), Error.None)
			destroy(part)
			f.counts[2] += 1
		}
	case:
		fuzz_read(f)
	}
	if emptied || card(s) == 0 {
		destroy(s)
		f.s = nil
	}
}

fuzz_run :: proc(t: ^testing.T, seed: u64, steps: int) {
	f := new(Fuzz)
	defer free(f)
	f.t = t
	f.r = Test_Rng{state = seed}
	scheme_init(&f.scheme, &f.r, 3, 2, 7)
	defer scheme_destroy(&f.scheme)
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
	for step in 0 ..< steps {
		fuzz_step(f)
		if f.s != nil && step % 25 == 0 {
			if !check_labelled(t, f.s) {
				testing.expectf(t, false, "fuzz seed %x broke at step %d", seed, step)
				break
			}
		}
		free_all(context.temp_allocator)
	}
	if f.s != nil {
		check_labelled(t, f.s)
		destroy(f.s)
	}
	log.infof("fuzz %x %v dim %d reduce %d: %d adds, %d cas, %d split and absorb, %d reads", seed, f.quant, f.dim, f.reduce, f.counts[0], f.counts[1], f.counts[2], f.counts[4])
}

@(test)
labelled_operations_survive_fuzzing :: proc(t: ^testing.T) {
	old := limits_set(6, 2)
	defer limits_restore(old)
	for seed in ([]u64{0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8}) {
		fuzz_run(t, seed, 2500)
	}
}

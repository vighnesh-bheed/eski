package vsettype

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"

view_digest :: proc(s: Vset, a: ^Access, names: []string, queries: [][]f32, sc: ^Scratch, links: ^Links) -> string {
	b := strings.builder_make(context.temp_allocator)
	if s == nil {
		return "missing"
	}
	a.stream^ = 0xFEED
	v, _ := view_open(s, a, sc)
	fmt.sbprintf(&b, "size %d info %v memory %d serialized %d exists %v\n", view_size(&v), view_info(&v), view_memory(&v), view_serialized_size(&v), has_visible(s, a))
	top, has_top := top_visible_label(s, a)
	fmt.sbprintf(&b, "top %d %v\n", top, has_top)
	refs := make([dynamic]Ref, context.temp_allocator)
	view_range(&v, {kind = .Min}, {kind = .Max}, -1, &refs)
	fmt.sbprintf(&b, "range")
	for r in refs {
		fmt.sbprintf(&b, " %q", string(ref_name(s, r)))
	}
	fmt.sbprintf(&b, "\n")
	clear(&refs)
	view_range(&v, {kind = .Inclusive, value = bytes_of("n1")}, {kind = .Exclusive, value = bytes_of("n3")}, 3, &refs)
	fmt.sbprintf(&b, "subrange %d\n", len(refs))
	for name in names {
		r, ok := view_find(&v, bytes_of(name))
		if !ok {
			fmt.sbprintf(&b, "%q absent\n", name)
			continue
		}
		raw := ref_raw_embedding(s, r)
		text, has := ref_attribute(s, r)
		fmt.sbprintf(&b, "%q label %d raw %x %x attr %v %q\n", name, ref_label(s, r), raw.data, transmute(u32)raw.norm, has, text)
	}
	hits := make([dynamic]Hit, context.temp_allocator)
	for q, qi in queries {
		for count in ([]int{3, 17}) {
			for mode in 0 ..< 3 {
				req := Search_Request{kind = .Vector, vector = q, count = count, truth = mode == 1, filter = ".a > 1", use_filter = mode == 2}
				clear(&hits)
				f := view_search(&v, &req, sc, &hits)
				fmt.sbprintf(&b, "q%d c%d m%d %v: %s\n", qi, count, mode, f.err, hits_text(s, hits[:]))
			}
		}
	}
	for name in names[:4] {
		req := Search_Request{kind = .Element, element = bytes_of(name), count = 6}
		clear(&hits)
		f := view_search(&v, &req, sc, &hits)
		fmt.sbprintf(&b, "ele %q %v: %s\n", name, f.err, hits_text(s, hits[:]))
	}
	clear(&refs)
	for _ in 0 ..< 3 {
		if r, ok := view_random_member(&v); ok {
			append(&refs, r)
		}
	}
	view_random_distinct(&v, 4, &refs)
	view_random_repeats(&v, 5, &refs)
	view_random_distinct(&v, 1000, &refs)
	fmt.sbprintf(&b, "random")
	for r in refs {
		fmt.sbprintf(&b, " %q", string(ref_name(s, r)))
	}
	fmt.sbprintf(&b, "\n")
	for name in names {
		if !view_links(&v, bytes_of(name), sc, links) {
			continue
		}
		self, _ := view_find(&v, bytes_of(name))
		fmt.sbprintf(&b, "links %q", name)
		start := 0
		for end in links.ends {
			fmt.sbprintf(&b, " [")
			for r in links.refs[start:end] {
				fmt.sbprintf(&b, "%q/%x ", string(ref_name(s, r)), transmute(u32)ref_link_score(s, self, r))
			}
			fmt.sbprintf(&b, "]")
			start = end
		}
		fmt.sbprintf(&b, "\n")
	}
	return strings.to_string(b)
}

@(test)
hidden_writes_never_change_a_readers_view :: proc(t: ^testing.T) {
	old := limits_set(10, 3)
	defer limits_restore(old)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	links: Links
	defer links_destroy(&links)
	compared := 0
	mixed := 0
	hidden_graphs := 0
	for seed in ([]u64{0x51, 0x52, 0x53, 0x54}) {
		r := Test_Rng{state = seed}
		scheme: Scheme
		scheme_init(&scheme, &r, 3, 2, 8)
		defer scheme_destroy(&scheme)
		dim := 5
		quant := Quant(seed % 3)
		names := make([dynamic]string)
		defer {
			for n in names {
				delete(n)
			}
			delete(names)
		}
		for i in 0 ..< 30 {
			append(&names, fmt.aprintf("n%d", i))
		}
		queries := make([][]f32, 3)
		defer {
			for q in queries {
				delete(q)
			}
			delete(queries)
		}
		for &q in queries {
			q = make([]f32, dim)
			random_vector(&r, q)
		}
		x := make([]f32, dim)
		defer delete(x)
		creator := scheme_access(&scheme, 0)
		s := new_labelled(t, &creator, dim, quant)
		write :: proc(s: Vset, a: ^Access, r: ^Test_Rng, names: []string, x: []f32, quant: Quant, sc: ^Scratch, bulk: bool) {
			random_vector(r, x)
			name := names[test_below(r, len(names))]
			if bulk {
				name = fmt.tprintf("bulk%d", test_below(r, 60))
			}
			switch test_below(r, 10) {
			case 0 ..= 6:
				labelled_add(s, a, name, x, sc, quant, fmt.tprintf(`{{"a":%d}}`, test_below(r, 4)), test_below(r, 2) == 0)
			case 7, 8:
				remove_at(s, a, bytes_of(name), sc)
			case:
				set_attribute_at(s, a, bytes_of(name), bytes_of(fmt.tprintf(`{{"a":%d}}`, test_below(r, 4))))
			}
		}
		for _ in 0 ..< 400 {
			a := scheme_access(&scheme, test_below(&r, len(scheme.ids)))
			write(s, &a, &r, names[:], x, quant, &sc, false)
			free_all(context.temp_allocator)
		}
		check_labelled(t, s)
		for reader in 0 ..< len(scheme.ids) {
			hidden := make([dynamic]int)
			defer delete(hidden)
			for i in 0 ..< len(scheme.ids) {
				if !scheme_sees(&scheme, reader, scheme.ids[i]) {
					append(&hidden, i)
				}
			}
			ra := scheme_access(&scheme, reader)
			if len(hidden) == 0 || !has_visible(s, &ra) {
				continue
			}
			before := strings.clone(view_digest(s, &ra, names[:], queries, &sc, &links))
			defer delete(before)
			for step in 0 ..< 300 {
				a := scheme_access(&scheme, hidden[test_below(&r, len(hidden))])
				if step % 97 == 96 {
					remove_label(s, a.label)
				} else {
					write(s, &a, &r, names[:], x, quant, &sc, step % 3 == 0)
				}
				free_all(context.temp_allocator)
			}
			check_labelled(t, s)
			for m in 0 ..< s.lab.multi_len {
				c := s.lab.multis[m]
				seen_visible, seen_hidden := false, false
				for e in copies_entries(c)[:c.count] {
					if scheme_sees(&scheme, reader, ref_label(s, e)) {
						seen_visible = true
					} else {
						seen_hidden = true
					}
				}
				if seen_visible && seen_hidden {
					mixed += 1
				}
			}
			for i in 0 ..< s.lab.sorted_len {
				p := s.lab.sorted[i]
				if p.mode == .Graph && !scheme_sees(&scheme, reader, p.label) {
					hidden_graphs += 1
				}
			}
			after := view_digest(s, &ra, names[:], queries, &sc, &links)
			testing.expectf(t, before == after, "seed %x reader %d: hidden writes changed the view\n%s", seed, reader, digest_difference(before, after))
			compared += 1
			own := scheme_access(&scheme, reader)
			_, wf := labelled_add(s, &own, "witness", x, &sc, quant)
			testing.expect_value(t, wf.err, Error.None)
			testing.expectf(t, view_digest(s, &ra, names[:], queries, &sc, &links) != after, "seed %x reader %d: the digest ignores a visible write", seed, reader)
			remove_at(s, &own, bytes_of("witness"), &sc)
			free_all(context.temp_allocator)
		}
		destroy(s)
	}
	testing.expect(t, compared >= 8)
	log.infof("resolution determinism: %d readers compared before and after 300 hidden writes each; %d names with visible and hidden copies, %d hidden graph partitions at comparison time", compared, mixed, hidden_graphs)
}

digest_difference :: proc(a: string, b: string) -> string {
	x := strings.split_lines(a, context.temp_allocator)
	y := strings.split_lines(b, context.temp_allocator)
	out := strings.builder_make(context.temp_allocator)
	for i in 0 ..< max(len(x), len(y)) {
		l := x[i] if i < len(x) else ""
		r := y[i] if i < len(y) else ""
		if l != r {
			fmt.sbprintf(&out, "- %s\n+ %s\n", l, r)
		}
	}
	return strings.to_string(out)
}

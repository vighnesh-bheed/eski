package vsettype

import "core:fmt"
import "core:log"
import "core:slice"
import "core:testing"
import lbl "../label"
import "../vmath"

Lattice :: struct {
	table:  lbl.Table,
	ids:    [8]lbl.Id,
	views:  [8]lbl.Visibility,
	stream: [8]u64,
	n:      int,
}

lattice_init :: proc(l: ^Lattice, labels: []lbl.Label) {
	lbl.table_init(&l.table)
	l.n = len(labels)
	for x, i in labels {
		id, _ := lbl.table_intern(&l.table, x)
		l.ids[i] = id
	}
	for x, i in labels {
		lbl.visibility_build(&l.views[i], &l.table, x)
		l.stream[i] = 0x1234 + u64(i)
	}
}

lattice_destroy :: proc(l: ^Lattice) {
	for i in 0 ..< l.n {
		lbl.visibility_destroy(&l.views[i])
	}
	lbl.table_destroy(&l.table)
}

lattice_access :: proc(l: ^Lattice, i: int) -> Access {
	return Access{label = l.ids[i], visibility = &l.views[i], table = &l.table, stream = &l.stream[i]}
}

compartments_label :: proc(level: int, compartments: ..int) -> lbl.Label {
	x, _ := lbl.label_make(level, ..compartments)
	return x
}

hits_text :: proc(s: Vset, hits: []Hit) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	for h in hits {
		append(&b, ..transmute([]u8)fmt.tprintf("%s/%x ", string(hit_name(s, h)), transmute(u64)h.score))
	}
	return string(b[:])
}

@(test)
merge_of_partitions_is_exact :: proc(t: ^testing.T) {
	old := limits_set(40, 10)
	defer limits_restore(old)
	l: Lattice
	lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(0, 2), compartments_label(0, 3), compartments_label(1, 0, 1, 2, 3)})
	defer lattice_destroy(&l)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x9E6}
	quants := []Quant{.Q8, .NOQUANT, .BIN}
	sizes := []int{7, 90, 25, 160}
	compared := 0
	for quant in quants {
		dim := 6 if quant != .BIN else 64
		top := lattice_access(&l, 5)
		s := new_labelled(t, &top, dim, quant)
		x := make([]f32, dim)
		shared := make([]f32, dim)
		random_vector(&r, shared)
		for n, part in sizes {
			a := lattice_access(&l, part + 1)
			for k in 0 ..< n {
				if k % 9 == 0 {
					copy(x, shared)
				} else {
					random_vector(&r, x)
				}
				name := fmt.tprintf("p%d_%03d", part, k)
				_, f := labelled_add(s, &a, name, x, &sc, quant, fmt.tprintf(`{{"a":%d}}`, k % 5), true)
				testing.expect_value(t, f.err, Error.None)
			}
		}
		check_labelled(t, s)
		graphs := 0
		for i in 0 ..< s.lab.sorted_len {
			if s.lab.sorted[i].mode == .Graph {
				graphs += 1
			}
		}
		testing.expect_value(t, graphs, 2)
		tv, _ := view_open(s, &top, &sc)
		top_hits := make([dynamic]Hit)
		defer delete(top_hits)
		own := make([dynamic]Hit)
		defer delete(own)
		merged := make([dynamic]Named_Hit)
		defer delete(merged)
		q := make([]f32, dim)
		defer delete(q)
		for round in 0 ..< 120 {
			if round % 4 == 0 {
				copy(q, shared)
			} else {
				random_vector(&r, q)
			}
			count := 1 + test_below(&r, 40)
			filtered := round % 3 == 0
			truth := round % 5 == 0
			req := Search_Request{kind = .Vector, vector = q, count = count, ef = test_below(&r, 3) * 30, truth = truth, filter = ".a > 1", use_filter = filtered, filter_ef = test_below(&r, 2) * 25, epsilon = 0.4, use_epsilon = round % 7 == 0}
			clear(&top_hits)
			tv, _ = view_open(s, &top, &sc)
			testing.expect_value(t, view_search(&tv, &req, &sc, &top_hits).err, Error.None)
			clear(&merged)
			plain := req
			plain.use_epsilon = false
			for part in 0 ..< len(sizes) {
				a := lattice_access(&l, part + 1)
				v, _ := view_open(s, &a, &sc)
				clear(&own)
				testing.expect_value(t, view_search(&v, &plain, &sc, &own).err, Error.None)
				for h in own {
					append(&merged, Named_Hit{score = h.score, name = hit_name(s, h), seq = h.seq, slot = h.slot, part = h.part})
				}
			}
			slice.sort_by(merged[:], named_better)
			want := make([dynamic]Hit, context.temp_allocator)
			for h in merged[:min(count, len(merged))] {
				if req.use_epsilon && !(h.score >= 1 - req.epsilon) {
					continue
				}
				append(&want, Hit{score = h.score, seq = h.seq, slot = h.slot, part = h.part})
			}
			got_text := hits_text(s, top_hits[:])
			want_text := hits_text(s, want[:])
			testing.expectf(t, got_text == want_text, "%v round %d count %d filter %v truth %v:\n got %s\nwant %s", quant, round, count, filtered, truth, got_text, want_text)
			if truth {
				brute := make([dynamic]Named_Hit, context.temp_allocator)
				words := make([]u64, vmath.query_bytes(&tv.parts[0].part.arena) / 8 + 1, context.temp_allocator)
				qe, _ := vmath.query_encode(&tv.parts[0].part.arena, q, slice.to_bytes(words))
				for vp in tv.parts {
					p := vp.part
					for i in 0 ..< p.count {
						slot := p.order[i]
						if filtered && !filter_text_accepts(p, slot) {
							continue
						}
						append(&brute, named_hit(p, vmath.arena_query_score(&p.arena, qe, slot), slot))
					}
				}
				slice.sort_by(brute[:], named_better)
				exact := make([dynamic]Hit, context.temp_allocator)
				for h in brute[:min(count, len(brute))] {
					if req.use_epsilon && !(h.score >= 1 - req.epsilon) {
						continue
					}
					append(&exact, Hit{score = h.score, slot = h.slot, part = h.part})
				}
				testing.expectf(t, got_text == hits_text(s, exact[:]), "%v round %d truth differs from the brute force", quant, round)
			}
			compared += 1
			free_all(context.temp_allocator)
		}
		delete(x)
		delete(shared)
		destroy(s)
	}
	log.infof("merge exactness: %d searches over four partitions, two of them graphs, compared with the merge of each partition's own result", compared)
}

filter_text_accepts :: proc(p: ^Partition, slot: u32) -> bool {
	text, ok := part_element_attribute(p, slot)
	if !ok || len(text) < 7 {
		return false
	}
	return text[5] > '1'
}

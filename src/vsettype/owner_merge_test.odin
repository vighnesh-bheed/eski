package vsettype

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:testing"
import "../vmath"

@(test)
merge_of_own_and_shared_partitions_is_exact :: proc(t: ^testing.T) {
	old := limits_set(40, 10)
	defer limits_restore(old)
	l: Owner_Lattice
	owner_lattice_init(&l, {compartments_label(0), compartments_label(0, 0), compartments_label(0, 1), compartments_label(0, 2), compartments_label(0, 3), compartments_label(1, 0, 1, 2, 3)})
	defer lattice_destroy(&l.lattice)
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	r := Test_Rng{state = 0x0E6}
	sizes := []int{7, 90, 25, 160}
	owners := []Owner{SHARED, SHARED, 1, 1}
	compared := 0
	for quant in ([]Quant{.Q8, .NOQUANT, .BIN}) {
		dim := 6 if quant != .BIN else 64
		top := owner_access(&l, 5, 1)
		s := new_labelled(t, &top, dim, quant)
		x := make([]f32, dim)
		tied := make([]f32, dim)
		random_vector(&r, tied)
		for n, part in sizes {
			a := owner_access(&l, part + 1, owners[part])
			for k in 0 ..< n {
				if k % 9 == 0 {
					copy(x, tied)
				} else {
					random_vector(&r, x)
				}
				_, f := labelled_add(s, &a, fmt.tprintf("p%d_%03d", part, k), x, &sc, quant, fmt.tprintf(`{{"a":%d}}`, k % 5), true)
				testing.expect_value(t, f.err, Error.None)
			}
		}
		for part in 2 ..< 4 {
			noise := owner_access(&l, part + 1, 2)
			for k in 0 ..< 60 {
				if k % 3 == 0 {
					copy(x, tied)
				} else {
					random_vector(&r, x)
				}
				labelled_add(s, &noise, fmt.tprintf("p%d_%03d", part, k), x, &sc, quant, `{"a":4}`, true)
			}
		}
		check_labelled(t, s)
		testing.expect(t, part_at_scope(s, l.ids[2], SHARED).mode == .Graph && part_at_scope(s, l.ids[4], 1).mode == .Graph && part_at_scope(s, l.ids[4], 1).kind == .Block)
		testing.expect(t, part_at_scope(s, l.ids[3], 1).kind == .Compact && part_at_scope(s, l.ids[4], 2).mode == .Graph)
		top_hits := make([dynamic]Hit)
		own := make([dynamic]Hit)
		merged := make([dynamic]Named_Hit)
		q := make([]f32, dim)
		for round in 0 ..< 120 {
			if round % 4 == 0 {
				copy(q, tied)
			} else {
				random_vector(&r, q)
			}
			count := 1 + test_below(&r, 40)
			filtered := round % 3 == 0
			truth := round % 5 == 0
			req := Search_Request{kind = .Vector, vector = q, count = count, ef = test_below(&r, 3) * 30, truth = truth, filter = ".a > 1", use_filter = filtered, filter_ef = test_below(&r, 2) * 25, epsilon = 0.4, use_epsilon = round % 7 == 0}
			clear(&top_hits)
			tv, _ := view_open(s, &top, &sc)
			testing.expect_value(t, len(tv.parts), 4)
			testing.expect_value(t, view_search(&tv, &req, &sc, &top_hits).err, Error.None)
			got := strings.clone(hits_text(s, top_hits[:]), context.temp_allocator)
			brute := make([dynamic]Named_Hit, context.temp_allocator)
			if truth {
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
			}
			clear(&merged)
			plain := req
			plain.use_epsilon = false
			for part in 0 ..< len(sizes) {
				a := owner_access(&l, part + 1, owners[part])
				v, _ := view_open(s, &a, &sc)
				testing.expect_value(t, len(v.parts), 1)
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
			testing.expectf(t, got == hits_text(s, want[:]), "%v round %d count %d filter %v truth %v:\n got %s\nwant %s", quant, round, count, filtered, truth, got, hits_text(s, want[:]))
			if truth {
				exact := make([dynamic]Hit, context.temp_allocator)
				for h in brute[:min(count, len(brute))] {
					if req.use_epsilon && !(h.score >= 1 - req.epsilon) {
						continue
					}
					append(&exact, Hit{score = h.score, slot = h.slot, part = h.part})
				}
				testing.expectf(t, got == hits_text(s, exact[:]), "%v round %d truth differs from the brute force", quant, round)
			}
			for h in top_hits {
				testing.expect(t, ref_owner(s, hit_ref(h)) != 2)
			}
			compared += 1
			free_all(context.temp_allocator)
		}
		delete(top_hits)
		delete(own)
		delete(merged)
		delete(q)
		delete(x)
		delete(tied)
		destroy(s)
	}
	log.infof("owner merge exactness: %d searches over two shared and two own partitions, two of them graphs, beside another owner's partitions, compared with the merge of each partition's own result", compared)
}

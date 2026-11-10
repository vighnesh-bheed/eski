package label

import "core:fmt"
import "core:testing"
import hn "../hnsw"
import vf "../vfilter"

Plane :: struct {
	xs: [dynamic][2]f32,
}

Plane_Query :: struct {
	plane: ^Plane,
	at:    [2]f32,
}

plane_distance :: proc(ctx: rawptr, a, b: u32) -> f32 {
	p := (^Plane)(ctx)
	d := p.xs[a] - p.xs[b]
	return d.x * d.x + d.y * d.y
}

plane_query :: proc(ctx: rawptr, slot: u32) -> f32 {
	q := (^Plane_Query)(ctx)
	d := q.plane.xs[slot] - q.at
	return d.x * d.x + d.y * d.y
}

@(test)
gate_adapts_to_the_index_accept_shape :: proc(t: ^testing.T) {
	accept: hn.Accept_Proc = gate_accept
	filtered: hn.Accept_Proc = filter_gate_accept
	own: Accept_Proc = accept
	testing.expect(t, accept != nil && filtered != nil && own != nil)
	tb: Table
	table_init(&tb)
	defer table_destroy(&tb)
	low, _ := label_make(1)
	high, _ := label_make(3, 2)
	low_id, _ := table_intern(&tb, low)
	high_id, _ := table_intern(&tb, high)
	reader, _ := label_make(2, 2)
	v: Visibility
	visibility_build(&v, &tb, reader)
	defer visibility_destroy(&v)
	labels := []Id{BOTTOM_ID, low_id, high_id, low_id, Id(3), ID_NONE}
	g := gate_make(&v, labels)
	want := []bool{true, true, false, true, false, false}
	for w, slot in want {
		testing.expect_value(t, accept(&g, u32(slot)), w)
	}
	testing.expect(t, !accept(&g, u32(len(labels))))
	testing.expect(t, !accept(&g, max(u32)))
	program, _, err := vf.compile(".f == 1")
	testing.expect_value(t, err, vf.Compile_Error.None)
	defer vf.program_destroy(&program)
	attributes := make([]vf.Attribute, 4)
	defer {
		for &a in attributes {
			vf.attribute_destroy(&a)
		}
		delete(attributes)
	}
	attributes[0], _ = vf.attribute_make(`{"f":1}`)
	attributes[1], _ = vf.attribute_make(`{"f":0}`)
	attributes[2], _ = vf.attribute_make(`{"f":1}`)
	attributes[3], _ = vf.attribute_make(`{"g":1}`)
	fg := filter_gate_make(g, &program, slice_attribute, &attributes)
	want_filtered := []bool{true, false, false, false, false, false}
	for w, slot in want_filtered {
		testing.expect_value(t, filtered(&fg, u32(slot)), w)
	}
	open := filter_gate_make(g, nil, nil, nil)
	for w, slot in want {
		testing.expect_value(t, filtered(&open, u32(slot)), w)
	}
	blind := filter_gate_make(g, &program, nil, nil)
	for slot in 0 ..< len(labels) {
		testing.expect(t, !filtered(&blind, u32(slot)))
	}
	constant, _, cerr := vf.compile("1")
	testing.expect_value(t, cerr, vf.Compile_Error.None)
	defer vf.program_destroy(&constant)
	always := filter_gate_make(g, &constant, slice_attribute, &attributes)
	for w, slot in want {
		testing.expect_value(t, filtered(&always, u32(slot)), w && slot < len(attributes))
	}
}

@(test)
filtered_index_searches_return_only_visible_slots :: proc(t: ^testing.T) {
	count :: 3_000
	plane: Plane
	defer delete(plane.xs)
	ix: hn.Index
	params := hn.params_default()
	params.seed = 0x1AB31
	testing.expect_value(t, hn.init(&ix, params, plane_distance, &plane, context.allocator), hn.Error.None)
	defer hn.destroy(&ix)
	s: hn.Scratch
	hn.scratch_init(&s, context.allocator)
	defer hn.scratch_destroy(&s)
	tb: Table
	table_init(&tb)
	defer table_destroy(&tb)
	c: Config
	us_config(t, &c)
	defer config_destroy(&c)
	r := Rng{0x5EA6C4}
	labels := make([dynamic]Id)
	defer delete(labels)
	attributes := make([dynamic]vf.Attribute)
	defer {
		for &a in attributes {
			vf.attribute_destroy(&a)
		}
		delete(attributes)
	}
	for i in 0 ..< count {
		slot, err := hn.reserve(&ix)
		testing.expect_value(t, err, hn.Error.None)
		testing.expect_value(t, int(slot), i)
		x := [2]f32{f32(rng_below(&r, 2000)) / 10, f32(rng_below(&r, 2000)) / 10}
		if i % 40 >= 1 && i % 40 <= 4 {
			x = plane.xs[i - i % 40]
		}
		append(&plane.xs, x)
		id, _ := table_intern(&tb, random_label(&r, len(US_LEVELS), len(US_COMPARTMENTS), 2))
		append(&labels, id)
		attribute, _ := vf.attribute_make(fmt.tprintf(`{{"band":%d}}`, rng_below(&r, 4)))
		append(&attributes, attribute)
		testing.expect_value(t, hn.insert(&ix, &s, slot), hn.Error.None)
	}
	testing.expect(t, ix.twins > 0)
	program, _, err := vf.compile(".band >= 2")
	testing.expect_value(t, err, vf.Compile_Error.None)
	defer vf.program_destroy(&program)
	attribute_slice := attributes[:]
	readers := [?]Label{BOTTOM, {level = 2, compartments = {0b011, 0, 0, 0}}, {level = 3, compartments = {0b11111, 0, 0, 0}}, {level = 1, compartments = {0b100, 0, 0, 0}}}
	out: [20]hn.Candidate
	truth: [20]hn.Candidate
	ranged := make([dynamic]hn.Candidate)
	defer delete(ranged)
	returned, matched, expected := 0, 0, 0
	for reader in readers {
		v: Visibility
		visibility_build(&v, &tb, reader)
		g := gate_make(&v, labels[:])
		fg := filter_gate_make(g, &program, slice_attribute, &attribute_slice)
		for q in 0 ..< 40 {
			pq := Plane_Query{&plane, {f32(rng_below(&r, 2000)) / 10, f32(rng_below(&r, 2000)) / 10}}
			for budget in ([]int{0, 30, 400}) {
				for which in 0 ..< 2 {
					accept: hn.Accept_Proc = gate_accept if which == 0 else filter_gate_accept
					actx: rawptr = &g if which == 0 else &fg
					n, _, serr := hn.search_filtered(&ix, &s, plane_query, &pq, len(out), 64, accept, actx, budget, out[:])
					testing.expect_value(t, serr, hn.Error.None)
					returned += n
					for cand in out[:n] {
						id := labels[cand.id]
						testing.expect(t, dominates(reader, tb.labels[id]))
						if which == 1 {
							testing.expect(t, vf.evaluate(&program, &attributes[cand.id]))
						}
					}
					if budget == 0 && q % 4 == 0 {
						m, _ := hn.brute_force(&ix, &s, plane_query, &pq, len(truth), truth[:], accept, actx)
						expected += m
						for cand in truth[:m] {
							testing.expect(t, dominates(reader, tb.labels[labels[cand.id]]))
							for got in out[:n] {
								if got.id == cand.id {
									matched += 1
									break
								}
							}
						}
						rn, rerr := hn.search_range(&ix, &s, plane_query, &pq, hn.range_default(100), 64, &ranged, accept, actx)
						testing.expect_value(t, rerr, hn.Error.None)
						for cand in ranged[:rn] {
							testing.expect(t, dominates(reader, tb.labels[labels[cand.id]]))
						}
						bn, _ := hn.brute_force_range(&ix, &s, plane_query, &pq, hn.range_default(100), &ranged, accept, actx)
						for cand in ranged[:bn] {
							testing.expect(t, dominates(reader, tb.labels[labels[cand.id]]))
						}
					}
				}
			}
		}
		visibility_destroy(&v)
	}
	testing.expect(t, returned > 0)
	testing.expectf(t, f64(matched) >= 0.9 * f64(expected), "graph search found %d of %d brute-force results", matched, expected)
}

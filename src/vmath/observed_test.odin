package vmath

import "core:math"
import "core:slice"
import "core:strconv"
import "core:testing"

Scored_Name :: struct {
	name:  string,
	score: f64,
}

check_vemb :: proc(t: ^testing.T, elem: Elem, values: []string, id: int) {
	x := parse_vector(values)
	a: Arena
	testing.expect_value(t, arena_init(&a, elem, .Cosine, len(x)), nil)
	defer arena_destroy(&a)
	slot, err := arena_insert(&a, x)
	testing.expect_value(t, err, nil)
	leaves := observed_leaves(t, id)
	if len(leaves) > 0 && (leaves[0] == "f32" || leaves[0] == "int8" || leaves[0] == "bin") {
		testing.expectf(t, leaves[0] == elem_name(elem), "case %d names %s", id, leaves[0])
		testing.expect_value(t, len(leaves), 4 if elem == .Int8 else 3)
		if len(leaves) < 3 {
			return
		}
		testing.expectf(t, string(arena_bytes(&a, slot)) == leaves[1], "case %d stored bytes differ", id)
		testing.expectf(t, same_f64(f64(arena_norm(&a, slot)), parse_reply_f64(t, leaves[2])), "case %d norm %v against %s", id, arena_norm(&a, slot), leaves[2])
		if elem == .Int8 && len(leaves) == 4 {
			testing.expectf(t, same_f64(f64(arena_range(&a, slot)), parse_reply_f64(t, leaves[3])), "case %d range %v against %s", id, arena_range(&a, slot), leaves[3])
		}
		return
	}
	out := make([]f32, len(x), context.temp_allocator)
	arena_decode(&a, slot, out)
	testing.expect_value(t, len(leaves), len(x))
	for v, i in out {
		if i < len(leaves) {
			testing.expectf(t, same_f64(f64(v), parse_reply_f64(t, leaves[i])), "case %d component %d: %v against %s", id, i, v, leaves[i])
		}
	}
}

check_vsim :: proc(t: ^testing.T, elem: Elem, set: []Named_Vector, query: []string, ele: string, id: int, ordered: bool) {
	a: Arena
	build_arena(t, &a, elem, set)
	defer arena_destroy(&a)
	q: Query
	if ele != "" {
		scratch := make([]f32, a.dim, context.temp_allocator)
		buf, _ := query_alloc(&a, context.temp_allocator)
		ok: bool
		q, ok = query_rebuild(&a, arena_slot_of(set, ele), scratch, buf)
		testing.expect(t, ok)
	} else {
		buf, _ := query_alloc(&a, context.temp_allocator)
		ok: bool
		q, ok = query_encode(&a, parse_vector(query), buf)
		testing.expect(t, ok)
	}
	ours := make([]Scored_Name, len(set), context.temp_allocator)
	for v, i in set {
		ours[i] = {v.name, arena_query_score(&a, q, u32(i))}
	}
	leaves := observed_leaves(t, id)
	testing.expectf(t, len(leaves) % 2 == 0 && len(leaves) > 0, "case %d has %d leaves", id, len(leaves))
	for i := 0; i + 1 < len(leaves); i += 2 {
		slot := arena_slot_of(set, leaves[i])
		testing.expectf(t, slot != NIL_SLOT, "case %d names unknown element %s", id, leaves[i])
		if slot == NIL_SLOT {
			continue
		}
		want := parse_reply_f64(t, leaves[i + 1])
		testing.expectf(t, same_f64(ours[slot].score, want), "case %d element %s: %v against %s", id, leaves[i], ours[slot].score, leaves[i + 1])
	}
	if ordered {
		slice.stable_sort_by(ours, proc(x: Scored_Name, y: Scored_Name) -> bool {
			return x.score > y.score
		})
		testing.expect_value(t, len(leaves), 2 * len(ours))
		for i := 0; i < len(ours) && 2 * i < len(leaves); i += 1 {
			testing.expectf(t, ours[i].name == leaves[2 * i], "case %d position %d: %s against %s", id, i, ours[i].name, leaves[2 * i])
		}
	}
}

check_vlinks :: proc(t: ^testing.T, elem: Elem, set: []Named_Vector, node: string, id: int) {
	a: Arena
	build_arena(t, &a, elem, set)
	defer arena_destroy(&a)
	x := arena_slot_of(set, node)
	leaves := observed_leaves(t, id)
	testing.expect(t, len(leaves) > 0 && len(leaves) % 2 == 0)
	for i := 0; i + 1 < len(leaves); i += 2 {
		y := arena_slot_of(set, leaves[i])
		if y == NIL_SLOT {
			testing.expectf(t, false, "case %d names unknown element %s", id, leaves[i])
			continue
		}
		ours := edge_score(arena_score(&a, x, y))
		testing.expectf(t, same_f64(f64(ours), parse_reply_f64(t, leaves[i + 1])), "case %d edge %s-%s: %v against %s", id, node, leaves[i], ours, leaves[i + 1])
	}
}

@(test)
observed_vemb_values_and_raw :: proc(t: ^testing.T) {
	qa := []string{"0.1", "-0.2", "0.3", "0.4"}
	qb := []string{"1", "2", "3", "4"}
	qc := []string{"-1", "0", "0", "0"}
	qd := []string{"0", "0", "0", "0.001"}
	Vemb :: struct {
		elem:   Elem,
		values: []string,
		ids:    []int,
	}
	checks := []Vemb{
		{.Int8, {"1", "0"}, {98, 99, 209, 210}},
		{.Int8, {"0.5", "0.1"}, {100, 101, 211, 212}},
		{.F32, {"1", "0"}, {102, 103, 179, 213, 214, 290}},
		{.Bin, {"1", "0"}, {104, 105, 215, 216}},
		{.Int8, {"0", "1"}, {902}},
		{.Int8, {"1", "1"}, {904}},
		{.F32, qa, {912, 913, 914}},
		{.F32, qb, {915, 916, 917}},
		{.F32, qc, {918, 919, 920}},
		{.F32, qd, {921, 922, 923}},
		{.Int8, qa, {926, 927, 928}},
		{.Int8, qb, {929, 930, 931}},
		{.Int8, qc, {932, 933, 934}},
		{.Int8, qd, {935, 936, 937}},
		{.Bin, qa, {940, 941, 942}},
		{.Bin, qb, {943, 944, 945}},
		{.Bin, qc, {946, 947, 948}},
		{.Bin, qd, {949, 950, 951}},
	}
	count := 0
	for c in checks {
		for id in c.ids {
			check_vemb(t, c.elem, c.values, id)
			count += 1
		}
	}
	testing.expect_value(t, count, 56)
}

@(test)
observed_vsim_scores :: proc(t: ^testing.T) {
	basic := []Named_Vector{{"a", {"1", "0"}}, {"b", {"0", "1"}}, {"c", {"1", "1"}}, {"d", {"-1", "0"}}}
	variant := []Named_Vector{{"a", {"1", "0"}}, {"b", {"0", "1"}}, {"c", {"1", "1"}}, {"d", {"-1", "0"}}, {"e", {"0.5", "0.1"}}, {"f", {"0.5", "0.1"}}, {"g", {"0.5", "0.1"}}, {"h", {"0.5", "0.1"}}}
	eps := []Named_Vector{{"a", {"1", "0"}}, {"b", {"0", "1"}}, {"c", {"1", "1"}}, {"d", {"-1", "0"}}, {"e", {"0.5", "0.1"}}}
	degenerate := []Named_Vector{{"a", {"1", "0"}}, {"b", {"0", "1"}}, {"c", {"1", "1"}}, {"d", {"-1", "0"}}, {"e", {"inf", "0"}}}
	axes := []Named_Vector{{"x", {"1", "0", "0"}}, {"y", {"0", "1", "0"}}, {"z", {"1", "1", "1"}}, {"w", {"-1", "-1", "0"}}}
	four := []Named_Vector{{"a", {"0.1", "-0.2", "0.3", "0.4"}}, {"b", {"1", "2", "3", "4"}}, {"c", {"-1", "0", "0", "0"}}, {"d", {"0", "0", "0", "0.001"}}}
	tie := []Named_Vector{{"t0", {"0", "1"}}, {"t1", {"0", "1"}}, {"t2", {"0", "1"}}, {"t3", {"0", "1"}}, {"t4", {"0", "1"}}, {"t5", {"0", "1"}}, {"far", {"1", "0"}}}
	single := []Named_Vector{{"a", {"1", "0"}}}
	check_vsim(t, .Int8, variant, nil, "a", 113, false)
	check_vsim(t, .Int8, variant, nil, "a", 124, true)
	check_vsim(t, .Bin, single, {"1", "0"}, "", 132, true)
	check_vsim(t, .F32, single, {"1", "0"}, "", 133, true)
	check_vsim(t, .F32, axes, {"1", "2", "3"}, "", 893, true)
	check_vsim(t, .F32, axes, {"1", "2", "3"}, "", 894, true)
	check_vsim(t, .Int8, axes, {"1", "2", "3"}, "", 895, true)
	check_vsim(t, .Int8, axes, {"1", "2", "3"}, "", 896, true)
	check_vsim(t, .F32, basic, {"1", "0"}, "", 897, true)
	check_vsim(t, .F32, basic, nil, "a", 899, true)
	check_vsim(t, .F32, four, {"0.1", "-0.2", "0.3", "0.4"}, "", 924, true)
	check_vsim(t, .Int8, four, {"0.1", "-0.2", "0.3", "0.4"}, "", 938, true)
	check_vsim(t, .Bin, four, {"0.1", "-0.2", "0.3", "0.4"}, "", 952, true)
	check_vsim(t, .F32, tie, {"0", "1"}, "", 966, true)
	check_vsim(t, .Int8, eps, {"1", "0"}, "", 969, true)
	check_vsim(t, .Int8, degenerate, {"inf", "0"}, "", 448, false)
	check_vsim(t, .Int8, degenerate, {"0", "0"}, "", 449, false)
	check_vsim(t, .Int8, degenerate, {"inf", "0"}, "", 747, false)
	check_vsim(t, .Int8, degenerate, {"0", "0"}, "", 748, false)
}

@(test)
observed_vlinks_edge_scores :: proc(t: ^testing.T) {
	basic := []Named_Vector{{"a", {"1", "0"}}, {"b", {"0", "1"}}, {"c", {"1", "1"}}, {"d", {"-1", "0"}}}
	variant := []Named_Vector{{"a", {"1", "0"}}, {"b", {"0", "1"}}, {"c", {"1", "1"}}, {"d", {"-1", "0"}}, {"e", {"0.5", "0.1"}}, {"f", {"0.5", "0.1"}}, {"g", {"0.5", "0.1"}}, {"h", {"0.5", "0.1"}}}
	check_vlinks(t, .Int8, variant, "a", 135)
	check_vlinks(t, .F32, basic, "a", 898)
}

replay_values :: proc(set: []Replay_Vector, index: int) -> []f32 {
	for v in set {
		if v.index == index {
			out := make([]f32, 8, context.temp_allocator)
			for b, i in v.bits {
				out[i] = transmute(f32)b
			}
			return out
		}
	}
	return nil
}

replay_arena :: proc(t: ^testing.T, a: ^Arena, elem: Elem, set: []Replay_Vector) {
	testing.expect_value(t, arena_init(a, elem, .Cosine, 8), nil)
	for v in set {
		_, err := arena_insert(a, replay_values(set, v.index))
		testing.expect_value(t, err, nil)
	}
}

replay_slot :: proc(set: []Replay_Vector, index: int) -> u32 {
	for v, i in set {
		if v.index == index {
			return u32(i)
		}
	}
	return NIL_SLOT
}

@(test)
observed_replay_eight_dimensions_f32 :: proc(t: ^testing.T) {
	a: Arena
	replay_arena(t, &a, .F32, REPLAY_BIGQ[:])
	defer arena_destroy(&a)
	e0 := replay_slot(REPLAY_BIGQ[:], 0)
	for s in REPLAY_BIGQ_E0_SCORES {
		y := replay_slot(REPLAY_BIGQ[:], s.neighbour)
		score := arena_score(&a, e0, y)
		testing.expectf(t, same_f64(score, parse_reply_f64(t, s.vsim)), "e0-e%d score %v against %s", s.neighbour, score, s.vsim)
		testing.expectf(t, same_f64(f64(edge_score(score)), parse_reply_f64(t, s.vlinks)), "e0-e%d edge %v against %s", s.neighbour, edge_score(score), s.vlinks)
	}
}

seq_dot :: proc(a: []f32, b: []f32) -> f32 {
	s: f32
	for i in 0 ..< len(a) {
		s = s + a[i] * b[i]
	}
	return s
}

@(test)
observed_sequential_accumulation_misses_eight_dimensions :: proc(t: ^testing.T) {
	seq_unit :: proc(x: []f32) -> []f32 {
		n := math.sqrt(seq_dot(x, x))
		out := make([]f32, len(x), context.temp_allocator)
		for v, i in x {
			out[i] = v / n
		}
		return out
	}
	e0 := seq_unit(replay_values(REPLAY_BIGQ[:], 0))
	matched := 0
	for s in REPLAY_BIGQ_E0_SCORES {
		score := score_from_distance(distance_from_dot(seq_dot(e0, seq_unit(replay_values(REPLAY_BIGQ[:], s.neighbour)))))
		if same_f64(score, parse_reply_f64(t, s.vsim)) {
			matched += 1
		}
	}
	testing.expect_value(t, matched, 3)
}

@(test)
observed_replay_eight_dimensions_int8_edges :: proc(t: ^testing.T) {
	Edge_Case :: struct {
		id:   int,
		set:  []Replay_Vector,
		node: int,
	}
	edge_cases := []Edge_Case{{981, REPLAY_BIG[:], 0}, {984, REPLAY_BIG[:], 1}, {988, REPLAY_BIGM4[:], 0}, {991, REPLAY_BIGM4[:], 1}}
	total := 0
	matched := 0
	for c in edge_cases {
		a: Arena
		replay_arena(t, &a, .Int8, c.set)
		x := replay_slot(c.set, c.node)
		leaves := observed_leaves(t, c.id)
		for i := 0; i + 1 < len(leaves); i += 2 {
			index, ok := strconv.parse_int(leaves[i][1:])
			testing.expect(t, ok)
			y := replay_slot(c.set, index)
			testing.expect(t, y != NIL_SLOT)
			ours := edge_score(arena_score(&a, x, y))
			want := f32(parse_reply_f64(t, leaves[i + 1]))
			total += 1
			if ours == want {
				matched += 1
			} else {
				testing.expectf(t, false, "case %d edge e%d-e%d: %v against %v", c.id, c.node, index, ours, want)
			}
		}
		arena_destroy(&a)
	}
	testing.expect_value(t, total, 80)
	testing.expect_value(t, matched, 80)
}

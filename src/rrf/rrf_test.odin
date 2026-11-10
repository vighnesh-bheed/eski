package rrf

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:testing"
import "../retrieve"

Fused_Row :: struct {
	doc:   u32,
	value: string,
}

Fusion_Case :: struct {
	id:       int,
	constant: f64,
	window:   int,
	vector:   []u32,
	rows:     []Fused_Row,
}

TEXT_BRANCH := [?]u32{1, 6, 2, 8, 4}

L2_BRANCH := [?]u32{5, 2, 3, 7, 4, 8, 1, 6}

FUSION_CASES := [?]Fusion_Case {
	{id = 2156, constant = 1, window = 20, vector = L2_BRANCH[:], rows = {{1, "0.625"}, {2, "0.583333333333"}, {5, "0.5"}, {6, "0.444444444444"}, {8, "0.342857142857"}, {4, "0.333333333333"}, {3, "0.25"}, {7, "0.2"}}},
	{id = 2157, constant = 60, window = 2, vector = L2_BRANCH[:], rows = {{1, "0.016393442623"}, {5, "0.016393442623"}, {2, "0.0161290322581"}, {6, "0.0161290322581"}}},
	{id = 2158, constant = 10, window = 3, vector = L2_BRANCH[:], rows = {{2, "0.160256410256"}, {1, "0.0909090909091"}, {5, "0.0909090909091"}, {6, "0.0833333333333"}, {3, "0.0769230769231"}}},
	{id = 2159, constant = 60, window = 20, vector = L2_BRANCH[:], rows = {{2, "0.0320020481311"}, {1, "0.0313188157573"}, {6, "0.030834914611"}, {8, "0.0307765151515"}, {4, "0.0307692307692"}, {5, "0.016393442623"}, {3, "0.015873015873"}, {7, "0.015625"}}},
	{id = 2160, constant = 60, window = 20, vector = {5, 2, 3}, rows = {{2, "0.0320020481311"}, {1, "0.016393442623"}, {5, "0.016393442623"}, {6, "0.0161290322581"}, {3, "0.015873015873"}, {8, "0.015625"}, {4, "0.0153846153846"}}},
	{id = 2161, constant = 60, window = 20, vector = {5, 2, 3, 7, 4}, rows = {{2, "0.0320020481311"}, {4, "0.0307692307692"}, {1, "0.016393442623"}, {5, "0.016393442623"}, {6, "0.0161290322581"}, {3, "0.015873015873"}, {7, "0.015625"}, {8, "0.015625"}}},
	{id = 2171, constant = 60, window = 20, vector = {1, 2, 3, 4, 5, 6, 7, 8}, rows = {{1, "0.0327868852459"}, {2, "0.0320020481311"}, {6, "0.0312805474096"}, {4, "0.0310096153846"}, {8, "0.0303308823529"}, {3, "0.015873015873"}, {5, "0.0153846153846"}, {7, "0.0149253731343"}}},
	{id = 2174, constant = 60, window = 20, vector = {5, 3, 7, 1}, rows = {{1, "0.032018442623"}, {5, "0.016393442623"}, {3, "0.0161290322581"}, {6, "0.0161290322581"}, {2, "0.015873015873"}, {7, "0.015873015873"}, {8, "0.015625"}, {4, "0.0153846153846"}}},
}

ranked :: proc(docs: []u32) -> []retrieve.Ranked {
	out := make([]retrieve.Ranked, len(docs), context.temp_allocator)
	for d, i in docs {
		out[i] = retrieve.Ranked{doc = d, score = f64(len(docs) - i)}
	}
	return out
}

@(test)
fusion_reproduces_the_recorded_hybrid_rankings :: proc(t: ^testing.T) {
	for fc in FUSION_CASES {
		p := Params{constant = fc.constant, window = fc.window}
		f := fusion(&p)
		branches := [?][]retrieve.Ranked{ranked(TEXT_BRANCH[:]), ranked(fc.vector)}
		out := make([dynamic]retrieve.Ranked, context.temp_allocator)
		testing.expect_value(t, retrieve.fuse(&f, branches[:], &out), retrieve.Error.None)
		if !testing.expectf(t, len(out) == len(fc.rows), "case %d: %d fused rows, want %d", fc.id, len(out), len(fc.rows)) {
			continue
		}
		for row, i in fc.rows {
			want, _ := strconv.parse_f64(row.value)
			printed, _ := strconv.parse_f64(fmt.tprintf("%.12g", out[i].score))
			testing.expectf(t, out[i].doc == row.doc && printed == want, "case %d rank %d: doc %d %.17g, want doc %d %s", fc.id, i, out[i].doc, out[i].score, row.doc, row.value)
		}
		free_all(context.temp_allocator)
	}
	d := params_default()
	testing.expect(t, d.constant == 60 && d.window == 20)
}

@(test)
fusion_matches_a_brute_force_sum :: proc(t: ^testing.T) {
	state := u64(0xF05E)
	next_rand :: proc(s: ^u64, n: int) -> int {
		s^ += 0x9E37_79B9_7F4A_7C15
		z := s^
		z = (z ~ z >> 30) * 0xBF58_476D_1CE4_E5B9
		z = (z ~ z >> 27) * 0x94D0_49BB_1331_11EB
		return int((z ~ z >> 31) % u64(n))
	}
	for _ in 0 ..< 300 {
		count := 1 + next_rand(&state, 3)
		branches := make([][]retrieve.Ranked, count, context.temp_allocator)
		for b in 0 ..< count {
			seen := make(map[u32]bool, 16, context.temp_allocator)
			docs := make([dynamic]u32, context.temp_allocator)
			for _ in 0 ..< next_rand(&state, 40) {
				d := u32(1 + next_rand(&state, 60))
				if !(d in seen) {
					seen[d] = true
					append(&docs, d)
				}
			}
			branches[b] = ranked(docs[:])
		}
		p := Params{constant = f64(next_rand(&state, 100)), window = next_rand(&state, 30) - 2}
		want := make(map[u32]f64, 64, context.temp_allocator)
		for b in branches {
			n := len(b) if p.window <= 0 else min(len(b), p.window)
			for r in 0 ..< n {
				want[b[r].doc] = want[b[r].doc] + 1.0 / (p.constant + f64(r + 1))
			}
		}
		f := fusion(&p)
		out := make([dynamic]retrieve.Ranked, context.temp_allocator)
		retrieve.fuse(&f, branches, &out)
		testing.expect_value(t, len(out), len(want))
		expected := make([dynamic]retrieve.Ranked, context.temp_allocator)
		for doc, v in want {
			append(&expected, retrieve.Ranked{doc = doc, score = v})
		}
		retrieve.sort_ranked(expected[:])
		testing.expect(t, slice.equal(out[:], expected[:]))
		free_all(context.temp_allocator)
	}
}

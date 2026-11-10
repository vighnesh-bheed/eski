package hnsw

import "core:math"
import "core:testing"

Points :: struct {
	dim:    int,
	data:   [dynamic]f32,
	cosine: bool,
	calls:  int,
}

Point_Query :: struct {
	points: ^Points,
	q:      []f32,
}

Accept_Mod :: struct {
	modulus: u32,
	calls:   int,
}

points_init :: proc(p: ^Points, dim: int, cosine: bool, expected: int) {
	p^ = Points{dim = dim, cosine = cosine}
	p.data = make([dynamic]f32, 0, expected * dim)
}

points_destroy :: proc(p: ^Points) {
	delete(p.data)
}

points_get :: #force_inline proc(p: ^Points, slot: u32) -> []f32 #no_bounds_check {
	at := int(slot) * p.dim
	return p.data[at:at + p.dim]
}

points_set :: proc(p: ^Points, slot: u32, v: []f32) {
	need := (int(slot) + 1) * p.dim
	if len(p.data) < need {
		resize(&p.data, need)
	}
	copy(points_get(p, slot), v)
}

cosine_distance :: proc(a, b: []f32) -> f32 #no_bounds_check {
	dot: f32
	for i in 0 ..< len(a) {
		dot += a[i] * b[i]
	}
	return 1 - dot
}

l2_distance :: proc(a, b: []f32) -> f32 #no_bounds_check {
	sum: f32
	for i in 0 ..< len(a) {
		d := a[i] - b[i]
		sum += d * d
	}
	return sum
}

vector_distance :: #force_inline proc(p: ^Points, a, b: []f32) -> f32 {
	return p.cosine ? cosine_distance(a, b) : l2_distance(a, b)
}

points_distance :: proc(ctx: rawptr, a, b: u32) -> f32 {
	p := (^Points)(ctx)
	p.calls += 1
	return vector_distance(p, points_get(p, a), points_get(p, b))
}

point_query_distance :: proc(ctx: rawptr, slot: u32) -> f32 {
	q := (^Point_Query)(ctx)
	return vector_distance(q.points, q.q, points_get(q.points, slot))
}

mix_slot :: proc "contextless" (slot: u32) -> u32 {
	x := u64(slot) * 0x9E3779B97F4A7C15
	return u32(x >> 40)
}

accept_mod :: proc(ctx: rawptr, slot: u32) -> bool {
	a := (^Accept_Mod)(ctx)
	a.calls += 1
	return mix_slot(slot) % a.modulus == 0
}

gaussian :: proc(state: ^u64) -> f32 {
	u1 := rng_uniform(state)
	u2 := rng_uniform(state)
	return f32(math.sqrt(-2 * math.ln(u1)) * math.cos(2 * math.PI * u2))
}

normalize :: proc(v: []f32) {
	n: f32
	for x in v {
		n += x * x
	}
	n = math.sqrt(n)
	if n > 0 {
		for &x in v {
			x /= n
		}
	}
}

random_unit :: proc(state: ^u64, v: []f32) {
	for &x in v {
		x = gaussian(state)
	}
	normalize(v)
}

random_clustered :: proc(state: ^u64, centers: []f32, dim: int, sigma: f32, v: []f32) {
	c := int(rng_next(state) % u64(len(centers) / dim))
	for i in 0 ..< dim {
		v[i] = centers[c * dim + i] + sigma * gaussian(state)
	}
}

test_params :: proc(m: int, ef_construction: int, seed: u64) -> Params {
	p := params_default()
	p.m = m
	p.ef_construction = ef_construction
	p.seed = seed
	return p
}

add_point :: proc(t: ^testing.T, ix: ^Index, s: ^Scratch, p: ^Points, v: []f32) -> u32 {
	slot, err := reserve(ix)
	testing.expect_value(t, err, Error.None)
	points_set(p, slot, v)
	testing.expect_value(t, insert(ix, s, slot), Error.None)
	return slot
}

measure_recall :: proc(ix: ^Index, s: ^Scratch, p: ^Points, queries: []f32, k: int, ef: int) -> f64 {
	ann := make([]Candidate, k)
	defer delete(ann)
	truth := make([]Candidate, k)
	defer delete(truth)
	hits := 0
	total := 0
	for qi in 0 ..< len(queries) / p.dim {
		pq := Point_Query{p, queries[qi * p.dim:(qi + 1) * p.dim]}
		n, _ := search(ix, s, point_query_distance, &pq, k, ef, ann)
		m, _ := brute_force(ix, s, point_query_distance, &pq, k, truth)
		total += m
		for i in 0 ..< n {
			for j in 0 ..< m {
				if ann[i].id == truth[j].id {
					hits += 1
					break
				}
			}
		}
	}
	return f64(hits) / f64(max(total, 1))
}

make_queries :: proc(state: ^u64, count, dim: int) -> []f32 {
	q := make([]f32, count * dim)
	for i in 0 ..< count {
		random_unit(state, q[i * dim:(i + 1) * dim])
	}
	return q
}

check_graph :: proc(t: ^testing.T, ix: ^Index) -> bool {
	ok := true
	top := -1
	buf := make([]u32, 1 << 16)
	defer delete(buf)
	twins := 0
	for i in 0 ..< ix.slots {
		slot := u32(i)
		if ix.twin_link != nil && !is_live(ix, slot) && ix.twin_link[slot] != NONE {
			ok = false
		}
		if is_twin(ix, slot) {
			twins += 1
			if !twin_well_formed(ix, slot) {
				ok = false
			}
			continue
		}
		if !is_live(ix, slot) {
			continue
		}
		if next_twin(ix, slot) != NONE && (!is_twin(ix, next_twin(ix, slot)) || twin_prev(ix, next_twin(ix, slot)) != slot) {
			ok = false
		}
		level := int(ix.levels[slot])
		top = max(top, level)
		for l in 0 ..= level {
			if list_count(ix, slot, l) > layer_cap(ix, l) {
				ok = false
			}
			links := layer_links(ix, slot, l, buf)
			for v, a in links {
				if v == slot || !is_node(ix, v) || int(ix.levels[v]) < l {
					ok = false
					continue
				}
				for w in links[a + 1:] {
					if w == v {
						ok = false
					}
				}
				if !list_contains(ix, v, l, slot) {
					ok = false
				}
			}
		}
	}
	if ix.live > 0 {
		if !is_node(ix, ix.entry) || int(ix.levels[ix.entry]) != ix.max_level || top != ix.max_level {
			ok = false
		}
	} else if ix.entry != NONE {
		ok = false
	}
	if twins != ix.twins {
		ok = false
	}
	testing.expect(t, ok, "graph invariants hold: caps, live targets, no duplicates, reciprocal links, entry at max level, well-formed twin lists")
	return ok
}

twin_well_formed :: proc(ix: ^Index, slot: u32) -> bool {
	if ix.degree0[slot] != 0 || ix.upper_at[slot] != NONE {
		return false
	}
	prev := twin_prev(ix, slot)
	if !is_live(ix, prev) || ix.twin_link[prev] != slot {
		return false
	}
	next := ix.twin_link[slot]
	if next != NONE && (!is_twin(ix, next) || twin_prev(ix, next) != slot) {
		return false
	}
	at := slot
	for steps := 0; is_twin(ix, at); steps += 1 {
		if steps > ix.slots {
			return false
		}
		at = twin_prev(ix, at)
	}
	return is_node(ix, at) && twin_head(ix, slot) == at
}

reachable_at :: proc(ix: ^Index, layer: int) -> (reached: int, present: int) {
	if ix.entry == NONE {
		return 0, 0
	}
	for i in 0 ..< ix.slots {
		if is_live(ix, u32(i)) && node_level(ix, u32(i)) >= layer {
			present += 1
		}
	}
	seen := make([]bool, ix.slots)
	defer delete(seen)
	queue := make([dynamic]u32, 0, 64)
	defer delete(queue)
	buf := make([]u32, ix.m0)
	defer delete(buf)
	start := ix.entry
	seen[start] = true
	append(&queue, start)
	for head := 0; head < len(queue); head += 1 {
		reached += 1
		for v in layer_links(ix, queue[head], layer, buf) {
			if !seen[v] {
				seen[v] = true
				append(&queue, v)
			}
		}
		if layer == 0 {
			for v := next_twin(ix, queue[head]); v != NONE; v = next_twin(ix, v) {
				if !seen[v] {
					seen[v] = true
					append(&queue, v)
				}
			}
		}
	}
	return reached, present
}

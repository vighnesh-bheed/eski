package flatindex

import "core:math"
import "core:slice"
import "core:testing"
import "../vmath"

TEST_DIMS :: [?]int{1, 2, 3, 7, 8, 9, 16, 17, 31, 32, 33, 40, 64, 65, 128}

ALL_ELEMS :: [?]vmath.Elem{.F32, .F64, .F16, .BF16, .Int8, .U8}

ALL_METRICS :: [?]vmath.Metric{.L2, .IP, .Cosine}

Model :: struct {
	elem:   vmath.Elem,
	metric: vmath.Metric,
	dim:    int,
	ids:    [dynamic]u32,
	blobs:  map[u32][]u8,
}

model_init :: proc(m: ^Model, spec: Spec) {
	m^ = Model{elem = spec.elem, metric = spec.metric, dim = spec.dim}
	m.ids = make([dynamic]u32)
	m.blobs = make(map[u32][]u8)
}

model_destroy :: proc(m: ^Model) {
	for _, b in m.blobs {
		delete(b)
	}
	delete(m.blobs)
	delete(m.ids)
}

model_put :: proc(m: ^Model, id: u32, blob: []u8) {
	if old, ok := m.blobs[id]; ok {
		delete(old)
	} else {
		i, _ := slice.binary_search(m.ids[:], id)
		inject_at(&m.ids, i, id)
	}
	m.blobs[id] = slice.clone(blob)
}

model_del :: proc(m: ^Model, id: u32) -> bool {
	old, ok := m.blobs[id]
	if !ok {
		return false
	}
	delete(old)
	delete_key(&m.blobs, id)
	i, _ := slice.binary_search(m.ids[:], id)
	ordered_remove(&m.ids, i)
	return true
}

ref_lanes32 :: proc(q: []f32, s: []f32, l2: bool, fused: bool) -> f32 {
	n := len(q)
	acc: [4][8]f32
	step :: proc(acc: ^f32, x: f32, y: f32, l2: bool, fused: bool) {
		if l2 {
			d := y - x
			acc^ = vmath.fma_f32(d, d, acc^) if fused else acc^ + d * d
		} else {
			acc^ = vmath.fma_f32(x, y, acc^) if fused else acc^ + y * x
		}
	}
	r := n % 32
	m := r % 8
	for j in 0 ..< m {
		step(&acc[0][j], q[j], s[j], l2, fused)
	}
	i := m
	for k := 1; i < r; k += 1 {
		for j in 0 ..< 8 {
			step(&acc[k][j], q[i + j], s[i + j], l2, fused)
		}
		i += 8
	}
	for ; i < n; i += 32 {
		for u in 0 ..< 4 {
			for j in 0 ..< 8 {
				step(&acc[u][j], q[i + 8 * u + j], s[i + 8 * u + j], l2, fused)
			}
		}
	}
	v: [8]f32
	for j in 0 ..< 8 {
		v[j] = (acc[0][j] + acc[1][j]) + (acc[2][j] + acc[3][j])
	}
	t := v[0]
	for j in 1 ..< 8 {
		t = t + v[j]
	}
	return t
}

ref_bf16_sum :: proc(q: []f32, s: []f32, l2: bool) -> f32 {
	n := len(q)
	term :: proc(x: f32, y: f32, l2: bool) -> f32 {
		if l2 {
			d := x - y
			return d * d
		}
		return x * y
	}
	if n < 32 {
		t: f32
		for i in 0 ..< n {
			t = t + term(q[i], s[i], l2)
		}
		return t
	}
	lo := [8]int{0, 1, 2, 3, 8, 9, 10, 11}
	hi := [8]int{4, 5, 6, 7, 12, 13, 14, 15}
	acc: [8]f32
	r := n % 16
	for lanes in ([][8]int{lo, hi}) {
		for j in 0 ..< 8 {
			if lanes[j] < r {
				acc[j] = acc[j] + term(q[lanes[j]], s[lanes[j]], l2)
			}
		}
	}
	for i := r; i < n; i += 16 {
		for lanes in ([][8]int{lo, hi}) {
			for j in 0 ..< 8 {
				acc[j] = acc[j] + term(q[i + lanes[j]], s[i + lanes[j]], l2)
			}
		}
	}
	t := acc[0]
	for j in 1 ..< 8 {
		t = t + acc[j]
	}
	return t
}

ref_f64_sum :: proc(q: []f64, s: []f64, l2: bool) -> f64 {
	n := len(q)
	acc: [2][4]f64
	term :: proc(x: f64, y: f64, l2: bool) -> f64 {
		if l2 {
			d := y - x
			return d * d
		}
		return y * x
	}
	r := n % 8
	m := r % 4
	for j in 0 ..< m {
		acc[0][j] = acc[0][j] + term(q[j], s[j], l2)
	}
	i := m
	if r - m >= 4 {
		for j in 0 ..< 4 {
			acc[1][j] = acc[1][j] + term(q[i + j], s[i + j], l2)
		}
		i += 4
	}
	for ; i < n; i += 8 {
		for u in 0 ..< 2 {
			for j in 0 ..< 4 {
				acc[u][j] = acc[u][j] + term(q[i + 4 * u + j], s[i + 4 * u + j], l2)
			}
		}
	}
	v: [4]f64
	for j in 0 ..< 4 {
		v[j] = acc[0][j] + acc[1][j]
	}
	return ((v[0] + v[1]) + v[2]) + v[3]
}

widen :: proc(b: []u8, elem: vmath.Elem) -> []f32 {
	h := vmath.u16_view(b)
	out := make([]f32, len(h), context.temp_allocator)
	for v, i in h {
		out[i] = vmath.bf16_to_f32(v) if elem == .BF16 else vmath.f16_to_f32(v)
	}
	return out
}

ref_distance :: proc(elem: vmath.Elem, metric: vmath.Metric, q: []u8, qaux: f32, s: []u8, saux: f32) -> f64 {
	l2 := metric == .L2
	#partial switch elem {
	case .F32:
		d := ref_lanes32(vmath.f32_view(q), vmath.f32_view(s), l2, false)
		return f64(d if l2 else 1 - d)
	case .F16:
		d := ref_lanes32(widen(q, .F16), widen(s, .F16), l2, true)
		return f64(d if l2 else 1 - d)
	case .BF16:
		d := ref_bf16_sum(widen(q, .BF16), widen(s, .BF16), l2)
		return f64(d if l2 else 1 - d)
	case .F64:
		d := ref_f64_sum(vmath.f64_view(q), vmath.f64_view(s), l2)
		return d if l2 else 1 - d
	case .Int8, .U8:
		dot: i64
		sq: i64
		for i in 0 ..< len(q) {
			x := i64(i8(q[i])) if elem == .Int8 else i64(q[i])
			y := i64(i8(s[i])) if elem == .Int8 else i64(s[i])
			dot += x * y
			sq += (x - y) * (x - y)
		}
		switch metric {
		case .L2:
			return f64(f32(sq))
		case .IP:
			return f64(f32(1 - dot))
		case .Cosine:
			return f64(1 - f32(dot) / (qaux * saux))
		}
	}
	return 0
}

encoded :: proc(elem: vmath.Elem, metric: vmath.Metric, blob: []u8) -> (out: []u8, aux: f32) {
	out = make([]u8, len(blob), context.temp_allocator)
	aux = vmath.search_encode(elem, metric, blob, out)
	return
}

Oracle_Filter :: struct {
	accept: Accept_Proc,
	ctx:    rawptr,
	allow:  map[u32]bool,
	use:    bool,
}

oracle_hits :: proc(m: ^Model, qy: ^Query, f: ^Oracle_Filter, ix: ^Index = nil) -> [dynamic]Hit {
	out := make([dynamic]Hit, context.temp_allocator)
	qb := query_bytes(qy)
	for id in m.ids {
		if f != nil {
			if f.use && !f.allow[id] {
				continue
			}
			if f.accept != nil && !f.accept(f.ctx, id) {
				continue
			}
		}
		s, aux := encoded(m.elem, m.metric, m.blobs[id])
		d := ref_distance(m.elem, m.metric, qb, qy.q.aux, s, aux)
		if d != d && ix != nil {
			kd, ok := distance(ix, qy, id)
			if ok {
				d = kd
			}
		}
		append(&out, Hit{id = id, dist = d})
	}
	slice.sort_by(out[:], oracle_less)
	return out
}

oracle_knn :: proc(m: ^Model, qy: ^Query, k: int, f: ^Oracle_Filter = nil, ix: ^Index = nil) -> []Hit {
	all := oracle_hits(m, qy, f, ix)
	return all[:clamp(k, 0, len(all))]
}

oracle_range :: proc(m: ^Model, qy: ^Query, radius: f64, f: ^Oracle_Filter = nil, ix: ^Index = nil, limit := -1, order := Order.Distance) -> []Hit {
	bound := radius if m.elem == .F64 else f64(f32(radius))
	all := oracle_hits(m, qy, f, ix)
	out := make([dynamic]Hit, context.temp_allocator)
	for h in all {
		if h.dist <= bound {
			append(&out, h)
		}
	}
	res := out[:]
	if limit >= 0 && limit < len(res) {
		res = res[:limit]
	}
	if order == .Id {
		slice.sort_by(res, oracle_id_less)
	}
	return res
}

oracle_less :: proc(a, b: Hit) -> bool {
	an, bn := a.dist != a.dist, b.dist != b.dist
	if an != bn {
		return bn
	}
	if !an && a.dist != b.dist {
		return a.dist < b.dist
	}
	return a.id < b.id
}

oracle_id_less :: proc(a, b: Hit) -> bool {
	return a.id < b.id
}

same_bits :: proc(a, b: f64) -> bool {
	if a != a && b != b {
		return true
	}
	return transmute(u64)a == transmute(u64)b
}

expect_hits :: proc(t: ^testing.T, got: []Hit, want: []Hit, what: string, loc := #caller_location) -> bool {
	if len(got) != len(want) {
		testing.expectf(t, false, "%s: %d hits, want %d", what, len(got), len(want), loc = loc)
		return false
	}
	for i in 0 ..< len(got) {
		if got[i].id != want[i].id || !same_bits(got[i].dist, want[i].dist) {
			testing.expectf(t, false, "%s: hit %d is %v (%x), want %v (%x)", what, i, got[i], transmute(u64)got[i].dist, want[i], transmute(u64)want[i].dist, loc = loc)
			return false
		}
	}
	return true
}

rand_below :: proc(r: ^vmath.Rng, n: int) -> int {
	return int(vmath.rng_next(r) % u64(max(n, 1)))
}

random_blob :: proc(r: ^vmath.Rng, elem: vmath.Elem, dim: int, wide: bool, allocator := context.temp_allocator) -> []u8 {
	b := make([]u8, vmath.elem_vector_bytes(elem, dim), allocator)
	for i in 0 ..< dim {
		x := vmath.rng_next(r)
		#partial switch elem {
		case .F32:
			v := f32(2 * vmath.rng_f64(r) - 1)
			if wide {
				v = transmute(f32)u32(((x >> 63) << 31) | ((100 + ((x >> 23) % 50)) << 23) | (x & 0x7FFFFF))
			}
			vmath.f32_view(b)[i] = v
		case .F64:
			v := 2 * vmath.rng_f64(r) - 1
			if wide {
				v = transmute(f64)(((x >> 63) << 63) | ((1000 + ((x >> 52) % 50)) << 52) | (x & ((u64(1) << 52) - 1)))
			}
			vmath.f64_view(b)[i] = v
		case .F16:
			vmath.u16_view(b)[i] = u16(((x >> 63) << 15) | ((x >> 10) % 30) << 10 | (x & 0x3FF))
		case .BF16:
			vmath.u16_view(b)[i] = u16(((x >> 63) << 15) | ((100 + ((x >> 7) % 50)) << 7) | (x & 0x7F))
		case .Int8, .U8:
			b[i] = u8(x >> 56)
		}
	}
	return b
}

nan_blob :: proc(elem: vmath.Elem, dim: int, at: int, allocator := context.temp_allocator) -> []u8 {
	b := make([]u8, vmath.elem_vector_bytes(elem, dim), allocator)
	#partial switch elem {
	case .F32:
		vmath.f32_view(b)[at] = transmute(f32)u32(0x7FC00000)
	case .F64:
		vmath.f64_view(b)[at] = transmute(f64)u64(0x7FF8000000000000)
	case .F16:
		vmath.u16_view(b)[at] = 0x7E00
	case .BF16:
		vmath.u16_view(b)[at] = 0x7FC0
	}
	return b
}

zero_blob :: proc(elem: vmath.Elem, dim: int, allocator := context.temp_allocator) -> []u8 {
	return make([]u8, vmath.elem_vector_bytes(elem, dim), allocator)
}

supported_levels :: proc() -> bit_set[vmath.Level] {
	out: bit_set[vmath.Level]
	cpu := vmath.cpu_detect()
	for level in vmath.Level {
		if vmath.level_supported(level, cpu) {
			out += {level}
		}
	}
	return out
}

check_layout :: proc(t: ^testing.T, ix: ^Index, loc := #caller_location) -> bool {
	live := 0
	dead := 0
	prev: u32
	have_prev := false
	ok := true
	testing.expect_value(t, len(ix.firsts), len(ix.blocks), loc = loc)
	for &blk, b in ix.blocks {
		if blk.used == 0 || blk.used > len(blk.ids) || len(blk.ids) > ix.block || int(blk.arena.cap) < len(blk.ids) || int(blk.arena.high) != blk.used {
			testing.expectf(t, false, "block %d: used %d cap %d arena cap %d high %d block %d", b, blk.used, len(blk.ids), blk.arena.cap, blk.arena.high, ix.block, loc = loc)
			return false
		}
		if ix.firsts[b] != blk.ids[0] {
			testing.expectf(t, false, "block %d: first %d, ids[0] %d", b, ix.firsts[b], blk.ids[0], loc = loc)
			ok = false
		}
		bl := 0
		for l in 0 ..< blk.used {
			if have_prev && blk.ids[l] <= prev {
				testing.expectf(t, false, "block %d slot %d: id %d after %d", b, l, blk.ids[l], prev, loc = loc)
				ok = false
			}
			prev = blk.ids[l]
			have_prev = true
			if !is_dead(&blk, l) {
				bl += 1
			}
		}
		for l in blk.used ..< len(blk.dead) * 64 {
			if is_dead(&blk, l) {
				testing.expectf(t, false, "block %d: dead bit %d beyond used %d", b, l, blk.used, loc = loc)
				ok = false
				break
			}
		}
		if bl != blk.live || bl == 0 {
			testing.expectf(t, false, "block %d: live %d counted %d", b, blk.live, bl, loc = loc)
			ok = false
		}
		live += bl
		dead += blk.used - bl
	}
	if live != ix.count || dead != ix.dead {
		testing.expectf(t, false, "count %d dead %d, counted %d and %d", ix.count, ix.dead, live, dead, loc = loc)
		ok = false
	}
	return ok
}

check_contents :: proc(t: ^testing.T, ix: ^Index, m: ^Model, loc := #caller_location) -> bool {
	if !testing.expect_value(t, ix.count, len(m.ids), loc = loc) {
		return false
	}
	for id in m.ids {
		data, aux, ok := stored(ix, id)
		if !ok {
			testing.expectf(t, false, "id %d missing", id, loc = loc)
			return false
		}
		want, waux := encoded(m.elem, m.metric, m.blobs[id])
		if !slice.equal(data, want) || transmute(u32)aux != transmute(u32)waux {
			testing.expectf(t, false, "id %d stored bytes differ", id, loc = loc)
			return false
		}
	}
	n := 0
	for &blk in ix.blocks {
		for l in 0 ..< blk.used {
			if !is_dead(&blk, l) {
				if _, ok := m.blobs[blk.ids[l]]; !ok {
					testing.expectf(t, false, "id %d present but deleted", blk.ids[l], loc = loc)
					return false
				}
				n += 1
			}
		}
	}
	return testing.expect_value(t, n, len(m.ids), loc = loc)
}

hash_id :: proc "contextless" (id: u32, salt: u64) -> u64 {
	x := u64(id) * 0x9E3779B97F4A7C15 + salt
	x = (x ~ (x >> 30)) * 0xBF58476D1CE4E5B9
	x = (x ~ (x >> 27)) * 0x94D049BB133111EB
	return x ~ (x >> 31)
}

Select :: struct {
	salt:     u64,
	percent:  u64,
	calls:    int,
}

select_accept :: proc(ctx: rawptr, id: u32) -> bool {
	s := (^Select)(ctx)
	s.calls += 1
	return hash_id(id, s.salt) % 100 < s.percent
}

finite :: proc(x: f64) -> bool {
	return !math.is_nan(x) && !math.is_inf(x)
}

package flatindex

import "core:math/bits"
import "../roaring"
import "../vmath"

Sink_Mode :: enum u8 {
	Top,
	Range,
	Range_Top,
}

Sink :: struct {
	out:      ^[dynamic]Hit,
	start:    int,
	k:        int,
	radius:   f64,
	worst:    u64,
	worst_id: u32,
	mode:     Sink_Mode,
	err:      Error,
}

Chunk :: struct {
	slots: [CHUNK]u32,
	ids:   [CHUNK]u32,
	d32:   [CHUNK]f32,
	d64:   [CHUNK]f64,
	n:     int,
	block: int,
}

dist_key :: #force_inline proc "contextless" (d: f64) -> u64 {
	if d != d {
		return max(u64)
	}
	if d == 0 {
		return u64(1) << 63
	}
	b := transmute(u64)d
	return ~b if b >> 63 != 0 else b | (u64(1) << 63)
}

hit_before :: #force_inline proc "contextless" (a, b: Hit) -> bool {
	ka, kb := dist_key(a.dist), dist_key(b.dist)
	return ka < kb || (ka == kb && a.id < b.id)
}

id_before :: #force_inline proc "contextless" (a, b: Hit) -> bool {
	return a.id < b.id || (a.id == b.id && hit_before(a, b))
}

heap_up :: proc "contextless" (h: []Hit, at: int) #no_bounds_check {
	i := at
	x := h[i]
	for i > 0 {
		parent := (i - 1) >> 1
		if !hit_before(h[parent], x) {
			break
		}
		h[i] = h[parent]
		i = parent
	}
	h[i] = x
}

heap_down :: proc "contextless" (h: []Hit, at: int) #no_bounds_check {
	n := len(h)
	i := at
	x := h[i]
	for {
		child := 2 * i + 1
		if child >= n {
			break
		}
		if child + 1 < n && hit_before(h[child], h[child + 1]) {
			child += 1
		}
		if !hit_before(x, h[child]) {
			break
		}
		h[i] = h[child]
		i = child
	}
	h[i] = x
}

heap_sort :: proc "contextless" (h: []Hit) {
	for end := len(h) - 1; end > 0; end -= 1 {
		h[0], h[end] = h[end], h[0]
		heap_down(h[:end], 0)
	}
}

sort_hits :: proc "contextless" (h: []Hit, order := Order.Distance) {
	n := len(h)
	before := hit_before if order == .Distance else id_before
	for start := n / 2 - 1; start >= 0; start -= 1 {
		sift_by(h, start, n, before)
	}
	for end := n - 1; end > 0; end -= 1 {
		h[0], h[end] = h[end], h[0]
		sift_by(h, 0, end, before)
	}
}

sift_by :: proc "contextless" (h: []Hit, at: int, n: int, before: proc "contextless" (a, b: Hit) -> bool) #no_bounds_check {
	i := at
	x := h[i]
	for {
		child := 2 * i + 1
		if child >= n {
			break
		}
		if child + 1 < n && before(h[child], h[child + 1]) {
			child += 1
		}
		if !before(x, h[child]) {
			break
		}
		h[i] = h[child]
		i = child
	}
	h[i] = x
}

sink_heap :: #force_inline proc "contextless" (s: ^Sink) -> []Hit {
	return s.out[s.start:]
}

sink_refresh :: #force_inline proc "contextless" (s: ^Sink) {
	top := s.out[s.start]
	s.worst = dist_key(top.dist)
	s.worst_id = top.id
}

top_offer :: proc(s: ^Sink, id: u32, d: f64) {
	n := len(s.out) - s.start
	if n < s.k {
		if _, err := append(s.out, Hit{id = id, dist = d}); err != nil {
			s.err = .Out_Of_Memory
			return
		}
		heap_up(sink_heap(s), n)
		if n + 1 == s.k {
			sink_refresh(s)
		}
		return
	}
	key := dist_key(d)
	if key > s.worst || (key == s.worst && id > s.worst_id) {
		return
	}
	h := sink_heap(s)
	h[0] = Hit{id = id, dist = d}
	heap_down(h, 0)
	sink_refresh(s)
}

top_take :: proc(s: ^Sink, ids: []u32, dists: []f64, bounded: bool) #no_bounds_check {
	n := len(ids)
	r := s.radius
	i := 0
	for ; i < n && len(s.out) - s.start < s.k; i += 1 {
		if !bounded || dists[i] <= r {
			top_offer(s, ids[i], dists[i])
		}
	}
	worst := s.worst
	wid := s.worst_id
	for ; i < n; i += 1 {
		d := dists[i]
		if bounded && !(d <= r) {
			continue
		}
		key := dist_key(d)
		if key > worst || (key == worst && ids[i] > wid) {
			continue
		}
		h := sink_heap(s)
		h[0] = Hit{id = ids[i], dist = d}
		heap_down(h, 0)
		sink_refresh(s)
		worst = s.worst
		wid = s.worst_id
	}
}

sink_take :: proc(s: ^Sink, ids: []u32, dists: []f64) #no_bounds_check {
	switch s.mode {
	case .Top:
		if s.k <= 0 {
			return
		}
		top_take(s, ids, dists, false)
	case .Range:
		r := s.radius
		for i in 0 ..< len(ids) {
			if dists[i] <= r {
				if _, err := append(s.out, Hit{id = ids[i], dist = dists[i]}); err != nil {
					s.err = .Out_Of_Memory
					return
				}
			}
		}
	case .Range_Top:
		if s.k <= 0 {
			return
		}
		top_take(s, ids, dists, true)
	}
}

sink_finish :: proc "contextless" (s: ^Sink, order: Order) {
	h := sink_heap(s)
	switch s.mode {
	case .Top, .Range_Top:
		heap_sort(h)
		if order == .Id {
			sort_hits(h, .Id)
		}
	case .Range:
		if order == .Distance {
			sort_hits(h, .Distance)
		}
	}
}

score_f64 :: proc "contextless" (a: ^vmath.Arena, q: ^vmath.Query, slots: []u32, out: []f64) #no_bounds_check {
	n := min(len(slots), len(out))
	ahead := vmath.prefetch_ahead(a)
	for i in 0 ..< min(n, ahead) {
		vmath.arena_prefetch(a, slots[i])
	}
	score := a.score
	data := q.data
	aux := q.aux
	dim := a.dim
	stride := a.stride
	for i in 0 ..< n {
		if i + ahead < n {
			vmath.arena_prefetch(a, slots[i + ahead])
		}
		s := slots[i]
		out[i] = score(data, aux, a.vectors[int(s) * stride:], vmath.arena_aux(a, s), dim)
	}
}

chunk_flush :: proc(ix: ^Index, c: ^Chunk, qy: ^Query, s: ^Sink) {
	n := c.n
	if n == 0 {
		return
	}
	a := &ix.blocks[c.block].arena
	if ix.spec.elem == .F64 {
		score_f64(a, &qy.q, c.slots[:n], c.d64[:n])
	} else {
		vmath.arena_query_distances(a, &qy.q, c.slots[:n], c.d32[:n])
		for i in 0 ..< n {
			c.d64[i] = f64(c.d32[i])
		}
	}
	sink_take(s, c.ids[:n], c.d64[:n])
	c.n = 0
}

chunk_push :: #force_inline proc(ix: ^Index, c: ^Chunk, qy: ^Query, s: ^Sink, l: int, id: u32) {
	c.slots[c.n] = u32(l)
	c.ids[c.n] = id
	c.n += 1
	if c.n == CHUNK {
		chunk_flush(ix, c, qy, s)
	}
}

scan_block :: proc(ix: ^Index, c: ^Chunk, qy: ^Query, s: ^Sink, b: int, accept: Accept_Proc, actx: rawptr) {
	blk := &ix.blocks[b]
	c.block = b
	used := blk.used
	if accept == nil && blk.live == used {
		for start := 0; start < used; start += CHUNK {
			n := min(CHUNK, used - start)
			for i in 0 ..< n {
				c.slots[i] = u32(start + i)
				c.ids[i] = blk.ids[start + i]
			}
			c.n = n
			chunk_flush(ix, c, qy, s)
			if s.err != .None {
				return
			}
		}
		return
	}
	for w in 0 ..< dead_words(used) {
		live := ~blk.dead[w]
		if (w + 1) << 6 > used {
			live &= (u64(1) << uint(used - (w << 6))) - 1
		}
		for live != 0 {
			l := w << 6 + int(bits.trailing_zeros(live))
			live &= live - 1
			id := blk.ids[l]
			if accept != nil && !accept(actx, id) {
				continue
			}
			chunk_push(ix, c, qy, s, l, id)
		}
	}
	chunk_flush(ix, c, qy, s)
}

scan_all :: proc(ix: ^Index, qy: ^Query, s: ^Sink, accept: Accept_Proc, actx: rawptr) {
	c: Chunk
	for b in 0 ..< len(ix.blocks) {
		scan_block(ix, &c, qy, s, b, accept, actx)
		if s.err != .None {
			return
		}
	}
}

ids_sorted :: proc "contextless" (ids: []u32) -> bool #no_bounds_check {
	for i in 1 ..< len(ids) {
		if ids[i] < ids[i - 1] {
			return false
		}
	}
	return true
}

scan_ids :: proc(ix: ^Index, qy: ^Query, s: ^Sink, cands: []u32, accept: Accept_Proc, actx: rawptr) -> Error #no_bounds_check {
	if !ids_sorted(cands) {
		return .Unsorted_Ids
	}
	nc := len(cands)
	nb := len(ix.blocks)
	if nc == 0 || nb == 0 {
		return .None
	}
	c: Chunk
	i := 0
	b := find_block(ix, cands[0])
	for b < nb && i < nc {
		blk := &ix.blocks[b]
		ids := blk.ids
		used := blk.used
		c.block = b
		p := 0
		for i < nc {
			id := cands[i]
			p = gallop(ids, p, used, id)
			if p == used {
				break
			}
			if ids[p] != id {
				i = gallop(cands, i, nc, ids[p])
				continue
			}
			if !is_dead(blk, p) && (accept == nil || accept(actx, id)) {
				chunk_push(ix, &c, qy, s, p, id)
				if s.err != .None {
					return s.err
				}
			}
			p += 1
			i = gallop(cands, i, nc, id + 1) if id != max(u32) else nc
		}
		chunk_flush(ix, &c, qy, s)
		if s.err != .None {
			return s.err
		}
		b += 1
		if i < nc && b < nb {
			b = max(b, find_block(ix, cands[i]))
		}
	}
	return .None
}

scan_bitmap :: proc(ix: ^Index, qy: ^Query, s: ^Sink, set: ^roaring.Bitmap, accept: Accept_Proc, actx: rawptr) -> Error #no_bounds_check {
	nb := len(ix.blocks)
	if set == nil || nb == 0 {
		return .None
	}
	it: roaring.Iterator
	roaring.iterator_init(&it, set)
	id, ok := roaring.next(&it)
	if !ok {
		return .None
	}
	c: Chunk
	b := find_block(ix, id)
	for b < nb && ok {
		blk := &ix.blocks[b]
		ids := blk.ids
		used := blk.used
		c.block = b
		p := 0
		for ok {
			p = gallop(ids, p, used, id)
			if p == used {
				break
			}
			if ids[p] != id {
				id, ok = roaring.advance(&it, ids[p])
				continue
			}
			if !is_dead(blk, p) && (accept == nil || accept(actx, id)) {
				chunk_push(ix, &c, qy, s, p, id)
				if s.err != .None {
					return s.err
				}
			}
			p += 1
			id, ok = roaring.next(&it)
		}
		chunk_flush(ix, &c, qy, s)
		if s.err != .None {
			return s.err
		}
		b += 1
		if ok && b < nb {
			b = max(b, find_block(ix, id))
		}
	}
	return .None
}

scan :: proc(ix: ^Index, qy: ^Query, s: ^Sink, filter: Filter) -> Error {
	if !query_matches(ix, qy) {
		return .Query_Mismatch
	}
	switch filter.kind {
	case .None:
		scan_all(ix, qy, s, filter.accept, filter.ctx)
	case .Ids:
		scan_ids(ix, qy, s, filter.ids, filter.accept, filter.ctx) or_return
	case .Bitmap:
		scan_bitmap(ix, qy, s, filter.set, filter.accept, filter.ctx) or_return
	}
	return s.err
}

sink_top :: proc "contextless" (out: ^[dynamic]Hit, k: int) -> Sink {
	return Sink{out = out, start = len(out), k = k, mode = .Top}
}

sink_range :: proc "contextless" (out: ^[dynamic]Hit, radius: f64, limit: int) -> Sink {
	if limit >= 0 {
		return Sink{out = out, start = len(out), k = limit, radius = radius, mode = .Range_Top}
	}
	return Sink{out = out, start = len(out), radius = radius, mode = .Range}
}

sink_abort :: proc(s: ^Sink) {
	resize(s.out, s.start)
}

knn :: proc(ix: ^Index, qy: ^Query, k: int, out: ^[dynamic]Hit, filter := Filter{}) -> Error {
	return knn_many({ix}, qy, k, out, filter)
}

knn_many :: proc(indexes: []^Index, qy: ^Query, k: int, out: ^[dynamic]Hit, filter := Filter{}) -> Error {
	s := sink_top(out, k)
	for ix in indexes {
		if err := scan(ix, qy, &s, filter); err != .None {
			sink_abort(&s)
			return err
		}
	}
	sink_finish(&s, .Distance)
	return .None
}

range_search :: proc(ix: ^Index, qy: ^Query, radius: f64, out: ^[dynamic]Hit, filter := Filter{}, limit := -1, order := Order.Distance) -> Error {
	return range_many({ix}, qy, radius, out, filter, limit, order)
}

range_many :: proc(indexes: []^Index, qy: ^Query, radius: f64, out: ^[dynamic]Hit, filter := Filter{}, limit := -1, order := Order.Distance) -> Error {
	bound := radius_bound(qy.elem, radius) or_return
	s := sink_range(out, bound, limit)
	for ix in indexes {
		if err := scan(ix, qy, &s, filter); err != .None {
			sink_abort(&s)
			return err
		}
	}
	if len(indexes) > 1 && s.mode == .Range && order == .Id {
		sort_hits(sink_heap(&s), .Id)
	}
	sink_finish(&s, order)
	return .None
}

knn_blob :: proc(ix: ^Index, blob: []u8, k: int, out: ^[dynamic]Hit, filter := Filter{}) -> Error {
	qy: Query
	query_for(&qy, ix, blob, context.temp_allocator) or_return
	defer query_destroy(&qy)
	return knn(ix, &qy, k, out, filter)
}

range_blob :: proc(ix: ^Index, blob: []u8, radius: f64, out: ^[dynamic]Hit, filter := Filter{}, limit := -1, order := Order.Distance) -> Error {
	qy: Query
	query_for(&qy, ix, blob, context.temp_allocator) or_return
	defer query_destroy(&qy)
	return range_search(ix, &qy, radius, out, filter, limit, order)
}

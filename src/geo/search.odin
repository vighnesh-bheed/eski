package geo

import zt "../zsettype"

Point :: struct {
	longitude: f64,
	latitude:  f64,
	dist:      f64,
	score:     f64,
	member:    zt.Item,
}

Sort :: enum u8 {
	None,
	Asc,
	Desc,
}

scores_of_box :: proc "contextless" (hash: Hash_Bits) -> (min: u64, max: u64) {
	min = align52(hash)
	max = align52(Hash_Bits{bits = hash.bits + 1, step = hash.step})
	return
}

@(private = "file")
limit_reached :: #force_inline proc "contextless" (out: ^[dynamic]Point, limit: int) -> bool {
	return limit > 0 && len(out) >= limit
}

@(private = "file")
consider :: proc(shape: ^Shape, member: zt.Item, score: f64, out: ^[dynamic]Point) {
	xy, dist, ok := within_shape(shape, score)
	if !ok {
		return
	}
	item := member
	item.score = score
	append(out, Point{longitude = xy[0], latitude = xy[1], dist = dist, score = score, member = item})
}

@(private)
members_of_box :: proc(z: zt.Zset, hash: Hash_Bits, shape: ^Shape, out: ^[dynamic]Point, limit: int) {
	low, high := scores_of_box(hash)
	spec := zt.Range_Spec {
		min   = f64(low),
		max   = f64(high),
		minex = false,
		maxex = true,
	}
	if z.encoding == .Skiplist {
		for n := zt.sl_nth_in_range(z.sl, &spec, 0); n != nil && zt.value_lte_max(n.score, &spec); n = zt.sl_next(n) {
			if limit_reached(out, limit) {
				return
			}
			consider(shape, zt.item_from_node(n), n.score, out)
		}
		return
	}
	it := zt.iter_make(z, false)
	item: zt.Item
	for zt.iter_next(&it, &item) {
		if !zt.value_gte_min(item.score, &spec) {
			continue
		}
		if !zt.value_lte_max(item.score, &spec) {
			return
		}
		if limit_reached(out, limit) {
			return
		}
		consider(shape, item, item.score, out)
	}
}

@(private = "file")
same_cell :: #force_inline proc "contextless" (a, b: Hash_Bits) -> bool {
	return a.bits == b.bits && a.step == b.step
}

members_of_all_neighbors :: proc(z: zt.Zset, r: ^Radius, shape: ^Shape, out: ^[dynamic]Point, limit: int) {
	n := &r.neighbors
	cells := [9]Hash_Bits{r.hash, n.north, n.south, n.east, n.west, n.north_east, n.north_west, n.south_east, n.south_west}
	visited: [9]Hash_Bits
	count := 0
	for cell in cells {
		if hash_is_zero(cell) {
			continue
		}
		repeated := false
		for i in 0 ..< count {
			if same_cell(visited[i], cell) {
				repeated = true
				break
			}
		}
		if repeated {
			continue
		}
		visited[count] = cell
		count += 1
		members_of_box(z, cell, shape, out, limit)
		if limit_reached(out, limit) {
			return
		}
	}
}

search :: proc(z: zt.Zset, shape: ^Shape, out: ^[dynamic]Point, limit: int) {
	r := calculate_areas(shape)
	members_of_all_neighbors(z, &r, shape, out, limit)
}

@(private)
point_before :: #force_inline proc "contextless" (a, b: ^Point, desc: bool) -> bool {
	return a.dist > b.dist if desc else a.dist < b.dist
}

@(private)
merge_runs :: proc(src, dst: []Point, lo, mid, hi: int, desc: bool) {
	i, j, k := lo, mid, lo
	for i < mid && j < hi {
		if point_before(&src[j], &src[i], desc) {
			dst[k] = src[j]
			j += 1
		} else {
			dst[k] = src[i]
			i += 1
		}
		k += 1
	}
	for i < mid {
		dst[k] = src[i]
		i += 1
		k += 1
	}
	for j < hi {
		dst[k] = src[j]
		j += 1
		k += 1
	}
}

@(private)
insertion_runs :: proc(v: []Point, width: int, desc: bool) {
	for lo := 0; lo < len(v); lo += width {
		hi := min(lo + width, len(v))
		for i in lo + 1 ..< hi {
			cur := v[i]
			j := i
			for j > lo && point_before(&cur, &v[j - 1], desc) {
				v[j] = v[j - 1]
				j -= 1
			}
			v[j] = cur
		}
	}
}

sort_points :: proc(v: []Point, sort: Sort, tmp: ^[dynamic]Point) {
	if sort == .None || len(v) < 2 {
		return
	}
	desc := sort == .Desc
	RUN :: 16
	insertion_runs(v, RUN, desc)
	if len(v) <= RUN {
		return
	}
	resize(tmp, len(v))
	src := v
	dst := tmp[:]
	for width := RUN; width < len(v); width *= 2 {
		for lo := 0; lo < len(v); lo += 2 * width {
			mid := min(lo + width, len(v))
			hi := min(lo + 2 * width, len(v))
			merge_runs(src, dst, lo, mid, hi, desc)
		}
		src, dst = dst, src
	}
	if raw_data(src) != raw_data(v) {
		copy(v, src)
	}
}

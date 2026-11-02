package zsettype

import lp "../listpack"

Aggregate :: enum u8 {
	Sum,
	Min,
	Max,
}

Setop :: enum u8 {
	Union,
	Inter,
	Diff,
}

Source :: struct {
	z:      Zset,
	weight: f64,
	id:     rawptr,
	len:    int,
}

aggregate_into :: proc "contextless" (target: ^f64, val: f64, agg: Aggregate) {
	switch agg {
	case .Sum:
		target^ += val
		if is_nan(target^) {
			target^ = 0
		}
	case .Min:
		if val < target^ {
			target^ = val
		}
	case .Max:
		if val > target^ {
			target^ = val
		}
	}
}

set_source_create :: proc "contextless" (expected: int) -> Zset {
	return create_skiplist(expected)
}

set_source_add :: proc(z: Zset, m: []u8) {
	_, _, _ = add(z, 1, m, {.Nx})
}

create_from_members :: proc(members: [][]u8) -> Zset {
	z := set_source_create(len(members))
	for member in members {
		set_source_add(z, member)
	}
	return z
}

source_make :: proc(z: Zset, weight: f64 = 1) -> Source {
	n := z == nil ? 0 : length(z)
	return Source{z, weight, rawptr(z), n}
}

source_score :: proc(src: ^Source, member: []u8) -> (f64, bool) {
	if src.z == nil {
		return 0, false
	}
	v, found := score(src.z, member)
	if !found {
		return 0, false
	}
	return v * src.weight, true
}

setop_compute :: proc(srcs: []Source, op: Setop, agg: Aggregate, count_only: bool, limit: int) -> (dst: Zset, card: int, maxelelen: int, totelelen: int) {
	if op != .Diff {
		for i in 1 ..< len(srcs) {
			j := i
			for j > 0 && srcs[j].len < srcs[j - 1].len {
				srcs[j], srcs[j - 1] = srcs[j - 1], srcs[j]
				j -= 1
			}
		}
	}
	card_mode := op == .Inter && count_only
	if !card_mode {
		dst = create_skiplist(0)
	}
	if len(srcs) == 0 {
		return
	}
	visited := create_skiplist(0)
	defer destroy(visited)
	for src, source_index in srcs {
		if source_index > 0 && op != .Union {
			break
		}
		if src.z == nil {
			continue
		}
		it := iter_make(src.z, false)
		item: Item
		buf: [lp.LP_INTBUF_SIZE]u8
		for iter_next(&it, &item) {
			member := item_bytes(&item, &buf)
			if _, seen := score(visited, member); seen {
				continue
			}
			_, _, _ = add(visited, 0, member, {})
			value := op == .Diff ? item.score : item.score * src.weight
			if is_nan(value) {
				value = 0
			}
			include := true
			for &other, j in srcs {
				if j == source_index {
					continue
				}
				v, found := source_score(&other, member)
				if op == .Union && is_nan(v) {
					v = 0
				}
				if op == .Inter && !found || op == .Diff && found {
					include = false
					break
				}
				if op != .Diff && found {
					aggregate_into(&value, v, agg)
				}
			}
			if !include {
				continue
			}
			if card_mode {
				card += 1
				if limit > 0 && card >= limit {
					return
				}
			} else {
				maxelelen = max(maxelelen, len(member))
				totelelen += len(member)
				_, _, _ = add(dst, value, member, {})
			}
		}
	}
	return
}

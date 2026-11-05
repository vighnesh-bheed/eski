package settype

import lp "../listpack"

Op :: enum u8 {
	Union,
	Diff,
}

card_of :: proc(s: Set) -> int {
	return size(s)
}

sort_by_cardinality :: proc(sets: []Set) {
	for i in 1 ..< len(sets) {
		j := i
		for j > 0 && size(sets[j]) < size(sets[j - 1]) {
			sets[j], sets[j - 1] = sets[j - 1], sets[j]
			j -= 1
		}
	}
}

in_all_others :: proc(sets: []Set, v: Member) -> bool {
	for s in sets {
		if s == nil || !is_member_aux(s, v) {
			return false
		}
	}
	return true
}

inter_collect :: proc(sets: []Set, out: ^[dynamic]Member) -> int {
	if len(sets) == 0 {
		return 0
	}
	sort_by_cardinality(sets)
	it := iterator(sets[0])
	n := 0
	for {
		v, ok := next(&it)
		if !ok {
			break
		}
		if in_all_others(sets[1:], v) {
			append(out, v)
			n += 1
		}
	}
	return n
}

inter_card :: proc(sets: []Set, limit: int) -> int {
	if len(sets) == 0 {
		return 0
	}
	sort_by_cardinality(sets)
	it := iterator(sets[0])
	n := 0
	for {
		v, ok := next(&it)
		if !ok {
			break
		}
		if in_all_others(sets[1:], v) {
			n += 1
			if limit > 0 && n >= limit {
				break
			}
		}
	}
	return n
}

inter_store :: proc(sets: []Set) -> Set {
	smallest: Set
	if len(sets) > 0 {
		sort_by_cardinality(sets)
		smallest = sets[0]
	}
	others := sets[min(1, len(sets)):]
	shared := create_listpack() if smallest != nil && smallest.encoding != .Intset else create_intset()
	numeric := true
	walk := iterator(smallest)
	for candidate in next(&walk) {
		if !in_all_others(others, candidate) {
			continue
		}
		add_aux(shared, candidate)
		numeric = numeric && (candidate.numeric || lp.lp_string_to_int64(candidate.text, nil))
	}
	if numeric && size(shared) > 0 {
		maybe_convert_to_intset(shared)
	}
	return shared
}

union_diff :: proc(sets: []Set, op: Op) -> Set {
	result := create_intset()
	if len(sets) == 0 {
		return result
	}
	inputs := sets
	if op == .Diff {
		inputs = sets[:1]
	}
	for s in inputs {
		it := iterator(s)
		for {
			v, ok := next(&it)
			if !ok {
				break
			}
			include := true
			if op == .Diff {
				for other in sets[1:] {
					if other != nil && is_member_aux(other, v) {
						include = false
						break
					}
				}
			}
			if include {
				add_aux(result, v)
			}
		}
	}
	return result
}

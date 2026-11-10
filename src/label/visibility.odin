package label

import "core:math/bits"

Visibility :: struct {
	words:  [dynamic]u64,
	reader: Label,
	built:  int,
}

visibility_init :: proc(v: ^Visibility, reader: Label, allocator := context.allocator) {
	v^ = Visibility{reader = reader}
	v.words = make([dynamic]u64, 0, 0, allocator)
}

visibility_destroy :: proc(v: ^Visibility) {
	delete(v.words)
	v^ = Visibility{}
}

visibility_refresh :: proc(v: ^Visibility, t: ^Table) -> Error #no_bounds_check {
	n := len(t.labels)
	if n <= v.built {
		return .None
	}
	words := (n + 63) >> 6
	if len(v.words) < words {
		if err := resize(&v.words, words); err != nil {
			return .Out_Of_Memory
		}
	}
	reader := v.reader
	labels := t.labels[:]
	i := v.built
	for i < n {
		w := i >> 6
		stop := min(n, (w + 1) << 6)
		acc := u64(0)
		for j in i ..< stop {
			acc |= dominance_bit(reader, labels[j]) << uint(j & 63)
		}
		v.words[w] |= acc
		i = stop
	}
	v.built = n
	return .None
}

visibility_build :: proc(v: ^Visibility, t: ^Table, reader: Label, allocator := context.allocator) -> Error {
	visibility_init(v, reader, allocator)
	return visibility_refresh(v, t)
}

visible :: #force_inline proc "contextless" (v: ^Visibility, id: Id) -> bool #no_bounds_check {
	i := int(id)
	if i >= v.built {
		return false
	}
	return v.words[i >> 6] >> uint(i & 63) & 1 != 0
}

visible_count :: proc "contextless" (v: ^Visibility) -> (n: int) {
	for w in v.words {
		n += int(bits.count_ones(w))
	}
	return n
}

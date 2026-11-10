package label

import "core:math/bits"

Counters :: struct {
	counts: [dynamic]u64,
	total:  u64,
}

counters_init :: proc(c: ^Counters, allocator := context.allocator) {
	c^ = Counters{}
	c.counts = make([dynamic]u64, 0, 0, allocator)
}

counters_destroy :: proc(c: ^Counters) {
	delete(c.counts)
	c^ = Counters{}
}

counters_add :: proc(c: ^Counters, id: Id, delta: u64) -> Error {
	if id == ID_NONE {
		return .Invalid_Label
	}
	if delta > max(u64) - c.total {
		return .Overflow
	}
	if int(id) >= len(c.counts) {
		if err := resize(&c.counts, int(id) + 1); err != nil {
			return .Out_Of_Memory
		}
	}
	c.counts[id] += delta
	c.total += delta
	return .None
}

counters_sub :: proc "contextless" (c: ^Counters, id: Id, delta: u64) -> Error {
	if id == ID_NONE {
		return .Invalid_Label
	}
	if int(id) >= len(c.counts) {
		if delta == 0 {
			return .None
		}
		return .Underflow
	}
	if c.counts[id] < delta {
		return .Underflow
	}
	c.counts[id] -= delta
	c.total -= delta
	return .None
}

counters_get :: proc "contextless" (c: ^Counters, id: Id) -> u64 {
	if int(id) >= len(c.counts) {
		return 0
	}
	return c.counts[id]
}

counters_total :: proc "contextless" (c: ^Counters) -> u64 {
	return c.total
}

counters_visible :: proc "contextless" (c: ^Counters, v: ^Visibility) -> (sum: u64) #no_bounds_check {
	n := min(len(c.counts), v.built)
	for w in 0 ..< (n + 63) >> 6 {
		word := v.words[w]
		if (w + 1) << 6 > n {
			word &= (u64(1) << uint(n & 63)) - 1
		}
		for word != 0 {
			sum += c.counts[w << 6 + int(bits.trailing_zeros(word))]
			word &= word - 1
		}
	}
	return sum
}

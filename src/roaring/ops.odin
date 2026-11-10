package roaring

import "base:runtime"
import "core:math/bits"

Op :: enum u8 {
	And,
	Or,
	Andnot,
}

array_and :: proc "contextless" (a, b: []u16, out: []u16) -> int #no_bounds_check {
	i, j, k := 0, 0, 0
	for i < len(a) && j < len(b) {
		x, y := a[i], b[j]
		out[k] = x
		k += int(x == y)
		i += int(x <= y)
		j += int(y <= x)
	}
	return k
}

array_or :: proc "contextless" (a, b: []u16, out: []u16) -> int #no_bounds_check {
	i, j, k := 0, 0, 0
	for i < len(a) && j < len(b) {
		x, y := a[i], b[j]
		if x < y {
			out[k] = x
			i += 1
		} else if x > y {
			out[k] = y
			j += 1
		} else {
			out[k] = x
			i += 1
			j += 1
		}
		k += 1
	}
	for ; i < len(a); i += 1 {
		out[k] = a[i]
		k += 1
	}
	for ; j < len(b); j += 1 {
		out[k] = b[j]
		k += 1
	}
	return k
}

array_andnot :: proc "contextless" (a, b: []u16, out: []u16) -> int #no_bounds_check {
	j, k := 0, 0
	for x in a {
		for j < len(b) && b[j] < x {
			j += 1
		}
		if j < len(b) && b[j] == x {
			continue
		}
		out[k] = x
		k += 1
	}
	return k
}

container_filter :: proc(a: ^Container, b: ^Container, keep: bool, allocator: runtime.Allocator) -> (Container, Error) {
	values, err := make([dynamic]u16, 0, len(a.values), allocator)
	if err != nil {
		return {}, .Out_Of_Memory
	}
	for x in a.values {
		if container_contains(b, x) == keep {
			append(&values, x)
		}
	}
	return Container{values = values, cardinality = len(values), kind = .Array}, .None
}

container_arrays :: proc(op: Op, a, b: []u16, allocator: runtime.Allocator) -> (Container, Error) {
	room := len(a) + len(b) if op == .Or else len(a)
	values, err := make([dynamic]u16, room, room, allocator)
	if err != nil {
		return {}, .Out_Of_Memory
	}
	n := 0
	switch op {
	case .And:
		n = array_and(a, b, values[:])
	case .Or:
		n = array_or(a, b, values[:])
	case .Andnot:
		n = array_andnot(a, b, values[:])
	}
	resize(&values, n)
	if n > ARRAY_MAX {
		single := Container{values = values, cardinality = n, kind = .Array}
		words, e := container_words(&single, allocator)
		delete(values)
		if e != .None {
			return {}, e
		}
		return Container{words = words, cardinality = n, kind = .Bitset}, .None
	}
	return Container{values = values, cardinality = n, kind = .Array}, .None
}

container_op :: proc(op: Op, a, b: ^Container, allocator: runtime.Allocator) -> (result: Container, err: Error) {
	if a.kind == .Array && b.kind == .Array {
		return container_arrays(op, a.values[:], b.values[:], allocator)
	}
	switch op {
	case .And:
		if a.kind == .Array {
			return container_filter(a, b, true, allocator)
		}
		if b.kind == .Array {
			return container_filter(b, a, true, allocator)
		}
		words := container_words(a, allocator) or_return
		other := container_words(b, allocator) or_return
		for w in 0 ..< BITSET_WORDS {
			words[w] &= other[w]
		}
		delete(other, allocator)
		return container_from_words(words, allocator)
	case .Or:
		words := container_words(a, allocator) or_return
		container_fill(b, words)
		return container_from_words(words, allocator)
	case .Andnot:
		if a.kind == .Array {
			return container_filter(a, b, false, allocator)
		}
		words := container_words(a, allocator) or_return
		container_unfill(b, words)
		return container_from_words(words, allocator)
	}
	return {}, .None
}

push_container :: proc(out: ^Bitmap, key: u16, c: Container) -> Error {
	c := c
	if c.cardinality == 0 {
		container_destroy(&c, out.allocator)
		return .None
	}
	if _, err := append(&out.keys, key); err != nil {
		container_destroy(&c, out.allocator)
		return .Out_Of_Memory
	}
	if _, err := append(&out.containers, c); err != nil {
		pop(&out.keys)
		container_destroy(&c, out.allocator)
		return .Out_Of_Memory
	}
	return .None
}

push_clone :: proc(out: ^Bitmap, key: u16, c: ^Container) -> Error {
	clone := container_clone(c, out.allocator) or_return
	return push_container(out, key, clone)
}

combine :: proc(op: Op, a, b: ^Bitmap, out: ^Bitmap) -> Error {
	clear(out)
	i, j := 0, 0
	for i < len(a.keys) && j < len(b.keys) {
		ka, kb := a.keys[i], b.keys[j]
		if ka < kb {
			if op != .And {
				push_clone(out, ka, &a.containers[i]) or_return
			}
			i += 1
		} else if ka > kb {
			if op == .Or {
				push_clone(out, kb, &b.containers[j]) or_return
			}
			j += 1
		} else {
			c := container_op(op, &a.containers[i], &b.containers[j], out.allocator) or_return
			push_container(out, ka, c) or_return
			i += 1
			j += 1
		}
	}
	if op != .And {
		for ; i < len(a.keys); i += 1 {
			push_clone(out, a.keys[i], &a.containers[i]) or_return
		}
	}
	if op == .Or {
		for ; j < len(b.keys); j += 1 {
			push_clone(out, b.keys[j], &b.containers[j]) or_return
		}
	}
	return .None
}

and :: proc(a, b: ^Bitmap, out: ^Bitmap) -> Error {
	return combine(.And, a, b, out)
}

or :: proc(a, b: ^Bitmap, out: ^Bitmap) -> Error {
	return combine(.Or, a, b, out)
}

andnot :: proc(a, b: ^Bitmap, out: ^Bitmap) -> Error {
	return combine(.Andnot, a, b, out)
}

combine_into :: proc(op: Op, a, b: ^Bitmap) -> Error {
	tmp: Bitmap
	init(&tmp, a.allocator)
	if e := combine(op, a, b, &tmp); e != .None {
		destroy(&tmp)
		return e
	}
	destroy(a)
	a^ = tmp
	return .None
}

and_cardinality :: proc(a, b: ^Bitmap) -> (count: int, err: Error) {
	n := 0
	i, j := 0, 0
	for i < len(a.keys) && j < len(b.keys) {
		ka, kb := a.keys[i], b.keys[j]
		if ka < kb {
			i += 1
		} else if ka > kb {
			j += 1
		} else {
			ca, cb := &a.containers[i], &b.containers[j]
			if ca.kind == .Array {
				for x in ca.values {
					n += int(container_contains(cb, x))
				}
			} else if cb.kind == .Array {
				for x in cb.values {
					n += int(container_contains(ca, x))
				}
			} else {
				wa := container_words(ca, a.allocator) or_return
				wb, e := container_words(cb, a.allocator)
				if e != .None {
					delete(wa, a.allocator)
					return 0, e
				}
				for w in 0 ..< BITSET_WORDS {
					n += int(bits.count_ones(wa[w] & wb[w]))
				}
				delete(wa, a.allocator)
				delete(wb, a.allocator)
			}
			i += 1
			j += 1
		}
	}
	return n, .None
}

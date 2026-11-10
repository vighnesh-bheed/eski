package roaring

import "base:runtime"
import "core:math/bits"

ARRAY_MAX :: 4096

BITSET_WORDS :: 1024

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Data,
}

Kind :: enum u8 {
	Array,
	Bitset,
	Run,
}

Container :: struct {
	values:      [dynamic]u16,
	words:       []u64,
	cardinality: int,
	kind:        Kind,
}

Bitmap :: struct {
	keys:       [dynamic]u16,
	containers: [dynamic]Container,
	allocator:  runtime.Allocator,
}

init :: proc(b: ^Bitmap, allocator := context.allocator) {
	b^ = Bitmap{allocator = allocator}
	b.keys = make([dynamic]u16, 0, 0, allocator)
	b.containers = make([dynamic]Container, 0, 0, allocator)
}

container_destroy :: proc(c: ^Container, allocator: runtime.Allocator) {
	delete(c.values)
	if c.words != nil {
		delete(c.words, allocator)
	}
	c^ = Container{}
}

clear :: proc(b: ^Bitmap) {
	for &c in b.containers {
		container_destroy(&c, b.allocator)
	}
	runtime.clear(&b.keys)
	runtime.clear(&b.containers)
}

destroy :: proc(b: ^Bitmap) {
	for &c in b.containers {
		container_destroy(&c, b.allocator)
	}
	delete(b.keys)
	delete(b.containers)
	b^ = Bitmap{}
}

high :: #force_inline proc "contextless" (x: u32) -> u16 {
	return u16(x >> 16)
}

low :: #force_inline proc "contextless" (x: u32) -> u16 {
	return u16(x)
}

key_search :: proc "contextless" (keys: []u16, key: u16) -> (int, bool) #no_bounds_check {
	lo, hi := 0, len(keys)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if keys[mid] < key {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(keys) && keys[lo] == key
}

array_search :: proc "contextless" (values: []u16, x: u16) -> (int, bool) #no_bounds_check {
	lo, hi := 0, len(values)
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if values[mid] < x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(values) && values[lo] == x
}

run_search :: proc "contextless" (runs: []u16, x: u16) -> (int, bool) #no_bounds_check {
	lo, hi := 0, len(runs) / 2
	for lo < hi {
		mid := int(uint(lo + hi) >> 1)
		if runs[2 * mid] <= x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return 0, false
	}
	r := lo - 1
	start := u32(runs[2 * r])
	return r, u32(x) <= start + u32(runs[2 * r + 1])
}

bit_get :: #force_inline proc "contextless" (words: []u64, x: u16) -> bool #no_bounds_check {
	return words[x >> 6] >> (x & 63) & 1 != 0
}

container_contains :: proc "contextless" (c: ^Container, x: u16) -> bool {
	switch c.kind {
	case .Array:
		_, found := array_search(c.values[:], x)
		return found
	case .Bitset:
		return bit_get(c.words, x)
	case .Run:
		_, found := run_search(c.values[:], x)
		return found
	}
	return false
}

words_count :: proc "contextless" (words: []u64) -> int #no_bounds_check {
	n := 0
	for w in words {
		n += int(bits.count_ones(w))
	}
	return n
}

words_set_range :: proc "contextless" (words: []u64, start, last: u32) #no_bounds_check {
	first_word := start >> 6
	last_word := last >> 6
	lo_mask := ~u64(0) << (start & 63)
	hi_mask := ~u64(0) >> (63 - (last & 63))
	if first_word == last_word {
		words[first_word] |= lo_mask & hi_mask
		return
	}
	words[first_word] |= lo_mask
	for w in first_word + 1 ..< last_word {
		words[w] = ~u64(0)
	}
	words[last_word] |= hi_mask
}

words_clear_range :: proc "contextless" (words: []u64, start, last: u32) #no_bounds_check {
	first_word := start >> 6
	last_word := last >> 6
	lo_mask := ~u64(0) << (start & 63)
	hi_mask := ~u64(0) >> (63 - (last & 63))
	if first_word == last_word {
		words[first_word] &~= lo_mask & hi_mask
		return
	}
	words[first_word] &~= lo_mask
	for w in first_word + 1 ..< last_word {
		words[w] = 0
	}
	words[last_word] &~= hi_mask
}

container_fill :: proc "contextless" (c: ^Container, words: []u64) #no_bounds_check {
	switch c.kind {
	case .Array:
		for x in c.values {
			words[x >> 6] |= u64(1) << (x & 63)
		}
	case .Bitset:
		for w in 0 ..< BITSET_WORDS {
			words[w] |= c.words[w]
		}
	case .Run:
		for r := 0; r < len(c.values); r += 2 {
			start := u32(c.values[r])
			words_set_range(words, start, start + u32(c.values[r + 1]))
		}
	}
}

container_unfill :: proc "contextless" (c: ^Container, words: []u64) #no_bounds_check {
	switch c.kind {
	case .Array:
		for x in c.values {
			words[x >> 6] &~= u64(1) << (x & 63)
		}
	case .Bitset:
		for w in 0 ..< BITSET_WORDS {
			words[w] &~= c.words[w]
		}
	case .Run:
		for r := 0; r < len(c.values); r += 2 {
			start := u32(c.values[r])
			words_clear_range(words, start, start + u32(c.values[r + 1]))
		}
	}
}

new_words :: proc(allocator: runtime.Allocator) -> ([]u64, Error) {
	w, err := make([]u64, BITSET_WORDS, allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	return w, .None
}

container_from_words :: proc(words: []u64, allocator: runtime.Allocator) -> (Container, Error) {
	n := words_count(words)
	if n > ARRAY_MAX {
		return Container{words = words, cardinality = n, kind = .Bitset}, .None
	}
	values, err := make([dynamic]u16, 0, n, allocator)
	if err != nil {
		delete(words, allocator)
		return {}, .Out_Of_Memory
	}
	for w in 0 ..< BITSET_WORDS {
		word := words[w]
		for word != 0 {
			append(&values, u16(w << 6 + int(bits.trailing_zeros(word))))
			word &= word - 1
		}
	}
	delete(words, allocator)
	return Container{values = values, cardinality = n, kind = .Array}, .None
}

container_words :: proc(c: ^Container, allocator: runtime.Allocator) -> (words: []u64, err: Error) {
	words = new_words(allocator) or_return
	container_fill(c, words)
	return words, .None
}

container_flatten :: proc(c: ^Container, allocator: runtime.Allocator) -> Error {
	if c.kind != .Run {
		return .None
	}
	words := container_words(c, allocator) or_return
	flat := container_from_words(words, allocator) or_return
	container_destroy(c, allocator)
	c^ = flat
	return .None
}

container_add :: proc(c: ^Container, x: u16, allocator: runtime.Allocator) -> (added: bool, err: Error) {
	container_flatten(c, allocator) or_return
	switch c.kind {
	case .Array:
		idx, found := array_search(c.values[:], x)
		if found {
			return false, .None
		}
		if len(c.values) >= ARRAY_MAX {
			words := container_words(c, allocator) or_return
			words[x >> 6] |= u64(1) << (x & 63)
			delete(c.values)
			c^ = Container{words = words, cardinality = ARRAY_MAX + 1, kind = .Bitset}
			return true, .None
		}
		if _, err := inject_at(&c.values, idx, x); err != nil {
			return false, .Out_Of_Memory
		}
		c.cardinality += 1
		return true, .None
	case .Bitset:
		if bit_get(c.words, x) {
			return false, .None
		}
		c.words[x >> 6] |= u64(1) << (x & 63)
		c.cardinality += 1
		return true, .None
	case .Run:
	}
	return false, .None
}

container_remove :: proc(c: ^Container, x: u16, allocator: runtime.Allocator) -> (removed: bool, err: Error) {
	if !container_contains(c, x) {
		return false, .None
	}
	container_flatten(c, allocator) or_return
	switch c.kind {
	case .Array:
		idx, _ := array_search(c.values[:], x)
		ordered_remove(&c.values, idx)
		c.cardinality -= 1
	case .Bitset:
		c.words[x >> 6] &~= u64(1) << (x & 63)
		c.cardinality -= 1
		if c.cardinality <= ARRAY_MAX {
			flat := container_from_words(c.words, allocator) or_return
			c^ = flat
		}
	case .Run:
	}
	return true, .None
}

add :: proc(b: ^Bitmap, x: u32) -> (added: bool, err: Error) {
	key := high(x)
	idx, found := key_search(b.keys[:], key)
	if !found {
		values, err := make([dynamic]u16, 0, 4, b.allocator)
		if err != nil {
			return false, .Out_Of_Memory
		}
		append(&values, low(x))
		if _, e := inject_at(&b.keys, idx, key); e != nil {
			delete(values)
			return false, .Out_Of_Memory
		}
		if _, e := inject_at(&b.containers, idx, Container{values = values, cardinality = 1, kind = .Array}); e != nil {
			ordered_remove(&b.keys, idx)
			delete(values)
			return false, .Out_Of_Memory
		}
		return true, .None
	}
	return container_add(&b.containers[idx], low(x), b.allocator)
}

remove :: proc(b: ^Bitmap, x: u32) -> (removed: bool, err: Error) {
	idx, found := key_search(b.keys[:], high(x))
	if !found {
		return false, .None
	}
	c := &b.containers[idx]
	removed = container_remove(c, low(x), b.allocator) or_return
	if c.cardinality == 0 {
		container_destroy(c, b.allocator)
		ordered_remove(&b.keys, idx)
		ordered_remove(&b.containers, idx)
	}
	return removed, .None
}

contains :: proc "contextless" (b: ^Bitmap, x: u32) -> bool {
	idx, found := key_search(b.keys[:], high(x))
	if !found {
		return false
	}
	return container_contains(&b.containers[idx], low(x))
}

cardinality :: proc "contextless" (b: ^Bitmap) -> int {
	n := 0
	for c in b.containers {
		n += c.cardinality
	}
	return n
}

is_empty :: proc "contextless" (b: ^Bitmap) -> bool {
	return len(b.containers) == 0
}

minimum :: proc "contextless" (b: ^Bitmap) -> (u32, bool) {
	if len(b.containers) == 0 {
		return 0, false
	}
	c := &b.containers[0]
	base := u32(b.keys[0]) << 16
	switch c.kind {
	case .Array, .Run:
		return base | u32(c.values[0]), true
	case .Bitset:
		for w in 0 ..< BITSET_WORDS {
			if c.words[w] != 0 {
				return base | u32(w << 6 + int(bits.trailing_zeros(c.words[w]))), true
			}
		}
	}
	return 0, false
}

maximum :: proc "contextless" (b: ^Bitmap) -> (u32, bool) {
	n := len(b.containers)
	if n == 0 {
		return 0, false
	}
	c := &b.containers[n - 1]
	base := u32(b.keys[n - 1]) << 16
	switch c.kind {
	case .Array:
		return base | u32(c.values[len(c.values) - 1]), true
	case .Run:
		r := len(c.values) - 2
		return base | (u32(c.values[r]) + u32(c.values[r + 1])), true
	case .Bitset:
		for w := BITSET_WORDS - 1; w >= 0; w -= 1 {
			if c.words[w] != 0 {
				return base | u32(w << 6 + 63 - int(bits.leading_zeros(c.words[w]))), true
			}
		}
	}
	return 0, false
}

container_clone :: proc(c: ^Container, allocator: runtime.Allocator) -> (Container, Error) {
	out := Container{cardinality = c.cardinality, kind = c.kind}
	if c.kind == .Bitset {
		w, err := make([]u64, BITSET_WORDS, allocator)
		if err != nil {
			return {}, .Out_Of_Memory
		}
		copy(w, c.words)
		out.words = w
		return out, .None
	}
	v, err := make([dynamic]u16, len(c.values), len(c.values), allocator)
	if err != nil {
		return {}, .Out_Of_Memory
	}
	copy(v[:], c.values[:])
	out.values = v
	return out, .None
}

copy_into :: proc(dst, src: ^Bitmap) -> Error {
	clear(dst)
	reserve(&dst.keys, len(src.keys))
	reserve(&dst.containers, len(src.containers))
	for i in 0 ..< len(src.keys) {
		c := container_clone(&src.containers[i], dst.allocator) or_return
		append(&dst.keys, src.keys[i])
		if _, err := append(&dst.containers, c); err != nil {
			container_destroy(&c, dst.allocator)
			pop(&dst.keys)
			return .Out_Of_Memory
		}
	}
	return .None
}

equal :: proc "contextless" (a, b: ^Bitmap) -> bool {
	if len(a.keys) != len(b.keys) {
		return false
	}
	for i in 0 ..< len(a.keys) {
		if a.keys[i] != b.keys[i] || a.containers[i].cardinality != b.containers[i].cardinality {
			return false
		}
	}
	ia, ib: Iterator
	iterator_init(&ia, a)
	iterator_init(&ib, b)
	for {
		x, okx := next(&ia)
		y, oky := next(&ib)
		if okx != oky {
			return false
		}
		if !okx {
			return true
		}
		if x != y {
			return false
		}
	}
}

add_sorted :: proc(b: ^Bitmap, values: []u32) -> Error {
	for x in values {
		add(b, x) or_return
	}
	return .None
}

to_array :: proc "contextless" (b: ^Bitmap, out: []u32) -> int {
	it: Iterator
	iterator_init(&it, b)
	n := 0
	for n < len(out) {
		x, ok := next(&it)
		if !ok {
			break
		}
		out[n] = x
		n += 1
	}
	return n
}

run_count :: proc "contextless" (c: ^Container) -> int #no_bounds_check {
	switch c.kind {
	case .Run:
		return len(c.values) / 2
	case .Array:
		n := 0
		for i in 0 ..< len(c.values) {
			if i == 0 || c.values[i] != c.values[i - 1] + 1 {
				n += 1
			}
		}
		return n
	case .Bitset:
		n := 0
		for w in 0 ..< BITSET_WORDS {
			word := c.words[w]
			carry := u64(0)
			if w > 0 {
				carry = c.words[w - 1] >> 63
			}
			n += int(bits.count_ones(word &~ (word << 1 | carry)))
		}
		return n
	}
	return 0
}

container_bytes :: proc "contextless" (kind: Kind, cardinality: int, runs: int) -> int {
	switch kind {
	case .Array:
		return 2 * cardinality
	case .Bitset:
		return 8 * BITSET_WORDS
	case .Run:
		return 2 + 4 * runs
	}
	return 0
}

container_to_runs :: proc(c: ^Container, allocator: runtime.Allocator) -> Error #no_bounds_check {
	runs := run_count(c)
	values, err := make([dynamic]u16, 0, 2 * runs, allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	switch c.kind {
	case .Array:
		i := 0
		for i < len(c.values) {
			j := i
			for j + 1 < len(c.values) && c.values[j + 1] == c.values[j] + 1 {
				j += 1
			}
			append(&values, c.values[i], c.values[j] - c.values[i])
			i = j + 1
		}
	case .Bitset:
		w := 0
		word := c.words[0]
		scan: for {
			for word == 0 {
				w += 1
				if w == BITSET_WORDS {
					break scan
				}
				word = c.words[w]
			}
			start := w << 6 + int(bits.trailing_zeros(word))
			word |= word - 1
			for word == ~u64(0) {
				w += 1
				if w == BITSET_WORDS {
					append(&values, u16(start), u16(0xFFFF - start))
					break scan
				}
				word = c.words[w]
			}
			stop := w << 6 + int(bits.trailing_zeros(~word)) - 1
			append(&values, u16(start), u16(stop - start))
			word &= word + 1
		}
	case .Run:
		delete(values)
		return .None
	}
	cardinality := c.cardinality
	container_destroy(c, allocator)
	c^ = Container{values = values, cardinality = cardinality, kind = .Run}
	return .None
}

run_optimize :: proc(b: ^Bitmap) -> (changed: bool, err: Error) {
	for &c in b.containers {
		runs := run_count(&c)
		now := container_bytes(c.kind, c.cardinality, runs)
		as_runs := container_bytes(.Run, c.cardinality, runs)
		flat_kind := Kind.Array if c.cardinality <= ARRAY_MAX else Kind.Bitset
		flat := container_bytes(flat_kind, c.cardinality, runs)
		if c.kind != .Run && as_runs < now {
			container_to_runs(&c, b.allocator) or_return
			changed = true
		} else if c.kind == .Run && flat <= as_runs {
			container_flatten(&c, b.allocator) or_return
			changed = true
		}
	}
	return changed, .None
}

bytes_used :: proc "contextless" (b: ^Bitmap) -> int {
	n := cap(b.keys) * size_of(u16) + cap(b.containers) * size_of(Container)
	for c in b.containers {
		n += cap(c.values) * size_of(u16) + len(c.words) * size_of(u64)
	}
	return n
}

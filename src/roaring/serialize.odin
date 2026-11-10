package roaring

import "core:math/bits"

COOKIE_NO_RUNS :: 12346

COOKIE_RUNS :: 12347

NO_OFFSET_THRESHOLD :: 4

put_u16 :: #force_inline proc "contextless" (out: []u8, at: int, v: u16) {
	out[at] = u8(v)
	out[at + 1] = u8(v >> 8)
}

put_u32 :: #force_inline proc "contextless" (out: []u8, at: int, v: u32) {
	out[at] = u8(v)
	out[at + 1] = u8(v >> 8)
	out[at + 2] = u8(v >> 16)
	out[at + 3] = u8(v >> 24)
}

get_u16 :: #force_inline proc "contextless" (data: []u8, at: int) -> u16 {
	return u16(data[at]) | u16(data[at + 1]) << 8
}

get_u32 :: #force_inline proc "contextless" (data: []u8, at: int) -> u32 {
	return u32(data[at]) | u32(data[at + 1]) << 8 | u32(data[at + 2]) << 16 | u32(data[at + 3]) << 24
}

has_runs :: proc "contextless" (b: ^Bitmap) -> bool {
	for c in b.containers {
		if c.kind == .Run {
			return true
		}
	}
	return false
}

payload_bytes :: proc "contextless" (c: ^Container) -> int {
	switch c.kind {
	case .Run:
		return 2 + 2 * len(c.values)
	case .Array, .Bitset:
		if c.cardinality > ARRAY_MAX {
			return 8 * BITSET_WORDS
		}
		return 2 * c.cardinality
	}
	return 0
}

header_bytes :: proc "contextless" (b: ^Bitmap) -> int {
	n := len(b.containers)
	runs := has_runs(b)
	size := 8
	if runs {
		size = 4 + (n + 7) / 8
	}
	size += 4 * n
	if !runs || n >= NO_OFFSET_THRESHOLD {
		size += 4 * n
	}
	return size
}

serialized_size :: proc "contextless" (b: ^Bitmap) -> int {
	size := header_bytes(b)
	for &c in b.containers {
		size += payload_bytes(&c)
	}
	return size
}

serialize :: proc "contextless" (b: ^Bitmap, out: []u8) -> int #no_bounds_check {
	total := serialized_size(b)
	if len(out) < total {
		return 0
	}
	n := len(b.containers)
	runs := has_runs(b)
	at := 0
	if runs {
		put_u32(out, 0, u32(COOKIE_RUNS) | u32(n - 1) << 16)
		at = 4
		flags := (n + 7) / 8
		for i in 0 ..< flags {
			out[at + i] = 0
		}
		for i in 0 ..< n {
			if b.containers[i].kind == .Run {
				out[at + i / 8] |= u8(1) << uint(i % 8)
			}
		}
		at += flags
	} else {
		put_u32(out, 0, COOKIE_NO_RUNS)
		put_u32(out, 4, u32(n))
		at = 8
	}
	for i in 0 ..< n {
		put_u16(out, at, b.keys[i])
		put_u16(out, at + 2, u16(b.containers[i].cardinality - 1))
		at += 4
	}
	offsets := at
	if !runs || n >= NO_OFFSET_THRESHOLD {
		at += 4 * n
	}
	for i in 0 ..< n {
		c := &b.containers[i]
		if !runs || n >= NO_OFFSET_THRESHOLD {
			put_u32(out, offsets + 4 * i, u32(at))
		}
		switch c.kind {
		case .Run:
			put_u16(out, at, u16(len(c.values) / 2))
			at += 2
			for v in c.values {
				put_u16(out, at, v)
				at += 2
			}
		case .Array, .Bitset:
			if c.cardinality > ARRAY_MAX {
				words: [BITSET_WORDS]u64
				container_fill(c, words[:])
				for w in words {
					put_u32(out, at, u32(w))
					put_u32(out, at + 4, u32(w >> 32))
					at += 8
				}
			} else if c.kind == .Array {
				for v in c.values {
					put_u16(out, at, v)
					at += 2
				}
			} else {
				for w in 0 ..< BITSET_WORDS {
					word := c.words[w]
					for word != 0 {
						put_u16(out, at, u16(w << 6 + int(bits.trailing_zeros(word))))
						at += 2
						word &= word - 1
					}
				}
			}
		}
	}
	return at
}

deserialize :: proc(b: ^Bitmap, data: []u8) -> (int, Error) {
	clear(b)
	if len(data) < 4 {
		return 0, .Invalid_Data
	}
	cookie := get_u32(data, 0)
	n := 0
	runs := false
	at := 0
	flags_at := 0
	if cookie & 0xFFFF == COOKIE_RUNS {
		runs = true
		n = int(cookie >> 16) + 1
		flags_at = 4
		at = 4 + (n + 7) / 8
	} else if cookie == COOKIE_NO_RUNS {
		if len(data) < 8 {
			return 0, .Invalid_Data
		}
		n = int(get_u32(data, 4))
		at = 8
	} else {
		return 0, .Invalid_Data
	}
	if n > 65536 || len(data) < at + 4 * n {
		return 0, .Invalid_Data
	}
	header := at
	at += 4 * n
	if !runs || n >= NO_OFFSET_THRESHOLD {
		if len(data) < at + 4 * n {
			return 0, .Invalid_Data
		}
		at += 4 * n
	}
	prev := -1
	for i in 0 ..< n {
		key := get_u16(data, header + 4 * i)
		card := int(get_u16(data, header + 4 * i + 2)) + 1
		if int(key) <= prev {
			clear(b)
			return 0, .Invalid_Data
		}
		prev = int(key)
		is_run := runs && data[flags_at + i / 8] >> uint(i % 8) & 1 != 0
		c: Container
		used := 0
		e: Error
		if is_run {
			c, used, e = read_runs(data[at:], card, b.allocator)
		} else if card > ARRAY_MAX {
			c, used, e = read_bitset(data[at:], card, b.allocator)
		} else {
			c, used, e = read_array(data[at:], card, b.allocator)
		}
		if e != .None {
			clear(b)
			return 0, e
		}
		at += used
		if pe := push_container(b, key, c); pe != .None {
			clear(b)
			return 0, pe
		}
	}
	return at, .None
}

read_array :: proc(data: []u8, card: int, allocator := context.allocator) -> (Container, int, Error) {
	if len(data) < 2 * card {
		return {}, 0, .Invalid_Data
	}
	values, err := make([dynamic]u16, card, card, allocator)
	if err != nil {
		return {}, 0, .Out_Of_Memory
	}
	for i in 0 ..< card {
		values[i] = get_u16(data, 2 * i)
		if i > 0 && values[i] <= values[i - 1] {
			delete(values)
			return {}, 0, .Invalid_Data
		}
	}
	return Container{values = values, cardinality = card, kind = .Array}, 2 * card, .None
}

read_bitset :: proc(data: []u8, card: int, allocator := context.allocator) -> (Container, int, Error) {
	if len(data) < 8 * BITSET_WORDS {
		return {}, 0, .Invalid_Data
	}
	words, err := make([]u64, BITSET_WORDS, allocator)
	if err != nil {
		return {}, 0, .Out_Of_Memory
	}
	for w in 0 ..< BITSET_WORDS {
		words[w] = u64(get_u32(data, 8 * w)) | u64(get_u32(data, 8 * w + 4)) << 32
	}
	if words_count(words) != card {
		delete(words, allocator)
		return {}, 0, .Invalid_Data
	}
	return Container{words = words, cardinality = card, kind = .Bitset}, 8 * BITSET_WORDS, .None
}

read_runs :: proc(data: []u8, card: int, allocator := context.allocator) -> (Container, int, Error) {
	if len(data) < 2 {
		return {}, 0, .Invalid_Data
	}
	count := int(get_u16(data, 0))
	if count == 0 || len(data) < 2 + 4 * count {
		return {}, 0, .Invalid_Data
	}
	values, err := make([dynamic]u16, 2 * count, 2 * count, allocator)
	if err != nil {
		return {}, 0, .Out_Of_Memory
	}
	total := 0
	next_free := 0
	for r in 0 ..< count {
		start := int(get_u16(data, 2 + 4 * r))
		length := int(get_u16(data, 4 + 4 * r))
		if start < next_free || start + length > 0xFFFF {
			delete(values)
			return {}, 0, .Invalid_Data
		}
		values[2 * r] = u16(start)
		values[2 * r + 1] = u16(length)
		total += length + 1
		next_free = start + length + 1
	}
	if total != card {
		delete(values)
		return {}, 0, .Invalid_Data
	}
	return Container{values = values, cardinality = card, kind = .Run}, 2 + 4 * count, .None
}

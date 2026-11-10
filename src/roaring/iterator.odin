package roaring

import "core:math/bits"

Iterator :: struct {
	bitmap:    ^Bitmap,
	container: int,
	pos:       int,
	offset:    u32,
	word:      u64,
	value:     u32,
	started:   bool,
	done:      bool,
}

iterator_init :: proc "contextless" (it: ^Iterator, b: ^Bitmap) {
	it^ = Iterator{bitmap = b}
}

iterator_load :: proc "contextless" (it: ^Iterator, ci: int, from: u16) -> bool #no_bounds_check {
	b := it.bitmap
	for c := ci; c < len(b.containers); c += 1 {
		con := &b.containers[c]
		base := u32(b.keys[c]) << 16
		lo := from if c == ci else 0
		switch con.kind {
		case .Array:
			idx, _ := array_search(con.values[:], lo)
			if idx < len(con.values) {
				it.container, it.pos = c, idx
				it.value = base | u32(con.values[idx])
				return true
			}
		case .Bitset:
			w := int(lo >> 6)
			word := con.words[w] & (~u64(0) << (lo & 63))
			for {
				if word != 0 {
					it.container, it.pos = c, w
					it.word = word & (word - 1)
					it.value = base | u32(w << 6 + int(bits.trailing_zeros(word)))
					return true
				}
				w += 1
				if w == BITSET_WORDS {
					break
				}
				word = con.words[w]
			}
		case .Run:
			r, inside := run_search(con.values[:], lo)
			if inside {
				it.container, it.pos = c, r
				it.offset = u32(lo) - u32(con.values[2 * r])
				it.value = base | u32(lo)
				return true
			}
			if lo < con.values[0] {
				r = 0
			} else {
				r += 1
			}
			if r < len(con.values) / 2 {
				it.container, it.pos, it.offset = c, r, 0
				it.value = base | u32(con.values[2 * r])
				return true
			}
		}
	}
	it.done = true
	return false
}

next :: proc "contextless" (it: ^Iterator) -> (u32, bool) #no_bounds_check {
	if it.done {
		return 0, false
	}
	if !it.started {
		it.started = true
		if !iterator_load(it, 0, 0) {
			return 0, false
		}
		return it.value, true
	}
	b := it.bitmap
	con := &b.containers[it.container]
	base := u32(b.keys[it.container]) << 16
	switch con.kind {
	case .Array:
		it.pos += 1
		if it.pos < len(con.values) {
			it.value = base | u32(con.values[it.pos])
			return it.value, true
		}
	case .Bitset:
		word := it.word
		w := it.pos
		for {
			if word != 0 {
				it.pos = w
				it.word = word & (word - 1)
				it.value = base | u32(w << 6 + int(bits.trailing_zeros(word)))
				return it.value, true
			}
			w += 1
			if w == BITSET_WORDS {
				break
			}
			word = con.words[w]
		}
	case .Run:
		if it.offset < u32(con.values[2 * it.pos + 1]) {
			it.offset += 1
			it.value += 1
			return it.value, true
		}
		it.pos += 1
		if it.pos < len(con.values) / 2 {
			it.offset = 0
			it.value = base | u32(con.values[2 * it.pos])
			return it.value, true
		}
	}
	if !iterator_load(it, it.container + 1, 0) {
		return 0, false
	}
	return it.value, true
}

advance :: proc "contextless" (it: ^Iterator, target: u32) -> (u32, bool) {
	if it.done {
		return 0, false
	}
	if it.started && it.value >= target {
		return it.value, true
	}
	it.started = true
	b := it.bitmap
	key := high(target)
	ci, _ := key_search(b.keys[:], key)
	if ci < it.container {
		ci = it.container
	}
	if ci >= len(b.keys) {
		it.done = true
		return 0, false
	}
	from := low(target) if b.keys[ci] == key else 0
	if !iterator_load(it, ci, from) {
		return 0, false
	}
	return it.value, true
}

iterator_value :: proc "contextless" (it: ^Iterator) -> (u32, bool) {
	if it.done || !it.started {
		return 0, false
	}
	return it.value, true
}

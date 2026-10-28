package settype

import lp "../listpack"

INTSET_ENC_INT16 :: 2
INTSET_ENC_INT32 :: 4
INTSET_ENC_INT64 :: 8
INTSET_HDR_SIZE :: 8
INTSET_MAX_ENTRIES_CAP :: 1 << 30

intset_value_encoding :: proc "contextless" (v: i64) -> u32 {
	if v >= i64(min(i16)) && v <= i64(max(i16)) {
		return INTSET_ENC_INT16
	}
	if v >= i64(min(i32)) && v <= i64(max(i32)) {
		return INTSET_ENC_INT32
	}
	return INTSET_ENC_INT64
}

intset_read_le :: proc "contextless" (p: [^]u8, width: int) -> u64 {
	v := u64(0)
	for i in 0 ..< width {
		v |= u64(p[i]) << uint(i * 8)
	}
	return v
}

intset_write_le :: proc "contextless" (p: [^]u8, width: int, v: u64) {
	for i in 0 ..< width {
		p[i] = u8(v >> uint(i * 8))
	}
}

intset_encoding :: proc "contextless" (is: [^]u8) -> u32 {
	return u32(intset_read_le(is, 4))
}

intset_len :: proc "contextless" (is: [^]u8) -> int {
	return int(intset_read_le(lp.padd(is, 4), 4))
}

intset_set_encoding :: proc "contextless" (is: [^]u8, enc: u32) {
	intset_write_le(is, 4, u64(enc))
}

intset_set_len :: proc "contextless" (is: [^]u8, n: int) {
	resize_require(n >= 0 && u64(n) <= u64(max(u32)))
	intset_write_le(lp.padd(is, 4), 4, u64(n))
}

intset_get_encoded :: proc "contextless" (is: [^]u8, pos: int, enc: u32) -> i64 {
	bits := intset_read_le(lp.padd(is, INTSET_HDR_SIZE + pos * int(enc)), int(enc))
	switch enc {
	case INTSET_ENC_INT16:
		return i64(i16(u16(bits)))
	case INTSET_ENC_INT32:
		return i64(i32(u32(bits)))
	case INTSET_ENC_INT64:
		return i64(bits)
	}
	resize_require(false)
	return 0
}

intset_get :: proc "contextless" (is: [^]u8, pos: int) -> i64 {
	return intset_get_encoded(is, pos, intset_encoding(is))
}

intset_put :: proc "contextless" (is: [^]u8, pos: int, v: i64) {
	enc := int(intset_encoding(is))
	intset_write_le(lp.padd(is, INTSET_HDR_SIZE + pos * enc), enc, u64(v))
}

intset_new :: proc "contextless" () -> [^]u8 {
	is := lp.lp_malloc(INTSET_HDR_SIZE)
	resize_require(is != nil)
	intset_set_encoding(is, INTSET_ENC_INT16)
	intset_set_len(is, 0)
	return is
}

intset_blob_len :: proc "contextless" (is: [^]u8) -> int {
	return INTSET_HDR_SIZE + intset_len(is) * int(intset_encoding(is))
}

intset_bytes :: proc "contextless" (is: [^]u8) -> []u8 {
	return is[:intset_blob_len(is)]
}

intset_resize :: proc "contextless" (is: [^]u8, n: int) -> [^]u8 {
	enc := int(intset_encoding(is))
	resize_require(n >= 0 && u64(n) <= u64(max(u32)) && n <= (max(int) - INTSET_HDR_SIZE) / enc)
	p := lp.lp_realloc(is, INTSET_HDR_SIZE + n * enc)
	resize_require(p != nil)
	return p
}

intset_search :: proc "contextless" (is: [^]u8, v: i64) -> (pos: int, found: bool) {
	low := 0
	high := intset_len(is)
	for low < high {
		mid := low + (high - low) / 2
		if intset_get(is, mid) < v {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low, low < intset_len(is) && intset_get(is, low) == v
}

intset_move_tail :: proc "contextless" (is: [^]u8, from: int, to: int) {
	count := intset_len(is) - from
	if to > from {
		for i := count; i > 0; i -= 1 {
			intset_put(is, to + i - 1, intset_get(is, from + i - 1))
		}
	} else if to < from {
		for i in 0 ..< count {
			intset_put(is, to + i, intset_get(is, from + i))
		}
	}
}

intset_upgrade_and_add :: proc "contextless" (source: [^]u8, v: i64) -> [^]u8 {
	is := source
	old_enc := intset_encoding(is)
	n := intset_len(is)
	enc := intset_value_encoding(v)
	intset_set_encoding(is, enc)
	is = intset_resize(is, n + 1)
	shift := int(v < 0)
	for i := n; i > 0; i -= 1 {
		value := intset_get_encoded(is, i - 1, old_enc)
		intset_put(is, i - 1 + shift, value)
	}
	intset_put(is, 0 if shift != 0 else n, v)
	intset_set_len(is, n + 1)
	return is
}

intset_add :: proc "contextless" (source: [^]u8, v: i64) -> ([^]u8, bool) {
	is := source
	if intset_value_encoding(v) > intset_encoding(is) {
		return intset_upgrade_and_add(is, v), true
	}
	pos, found := intset_search(is, v)
	if found {
		return is, false
	}
	n := intset_len(is)
	is = intset_resize(is, n + 1)
	intset_move_tail(is, pos, pos + 1)
	intset_put(is, pos, v)
	intset_set_len(is, n + 1)
	return is, true
}

intset_remove :: proc "contextless" (source: [^]u8, v: i64) -> ([^]u8, bool) {
	is := source
	pos, found := intset_search(is, v)
	if !found {
		return is, false
	}
	n := intset_len(is)
	intset_move_tail(is, pos + 1, pos)
	is = intset_resize(is, n - 1)
	intset_set_len(is, n - 1)
	return is, true
}

intset_find :: proc "contextless" (is: [^]u8, v: i64) -> bool {
	_, found := intset_search(is, v)
	return found
}

intset_min :: proc "contextless" (is: [^]u8) -> i64 {
	return intset_get(is, 0)
}

intset_max :: proc "contextless" (is: [^]u8) -> i64 {
	return intset_get(is, intset_len(is) - 1)
}

intset_random :: proc "contextless" (is: [^]u8) -> i64 {
	return intset_get(is, int(rand64() % u64(intset_len(is))))
}

intset_dup :: proc "contextless" (is: [^]u8) -> [^]u8 {
	n := intset_blob_len(is)
	p := lp.lp_malloc(n)
	resize_require(p != nil)
	copy(p[:n], is[:n])
	return p
}

intset_max_entries :: proc "contextless" () -> int {
	return min(max(0, set_max_intset_entries), INTSET_MAX_ENTRIES_CAP)
}

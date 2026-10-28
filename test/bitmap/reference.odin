package bitmap_harness

import "core:slice"
import bm "../../src/bitmap"

naive_bit :: proc(b: []u8, pos: i64) -> bool {
	return b[pos >> 3] & (u8(0x80) >> u8(pos & 7)) != 0
}

naive_popcount :: proc(b: []u8) -> i64 {
	c: i64 = 0
	for x in b {
		for k in 0 ..< 8 {
			if x & (u8(1) << u8(k)) != 0 {
				c += 1
			}
		}
	}
	return c
}

naive_find_bit :: proc(b: []u8, bit: bool) -> i64 {
	for p in 0 ..< i64(len(b)) * 8 {
		if naive_bit(b, p) == bit {
			return p
		}
	}
	return -1 if bit else i64(len(b)) * 8
}

ref_normalise :: proc(start, end, totlen: i64) -> (s, e: i64) {
	s = start
	e = end
	if s < 0 {
		s = totlen + s
	}
	if e < 0 {
		e = totlen + e
	}
	if s < 0 {
		s = 0
	}
	if e < 0 {
		e = 0
	}
	if e >= totlen {
		e = totlen - 1
	}
	return
}

ref_bitcount :: proc(b: []u8, start, end: i64, unit: bm.Unit) -> i64 {
	n := i64(len(b))
	if start < 0 && end < 0 && start > end {
		return 0
	}
	tot := n * 8 if unit == .Bit else n
	s, e := ref_normalise(start, end, tot)
	if s > e {
		return 0
	}
	lo, hi := s, e
	if unit == .Byte {
		lo = s * 8
		hi = e * 8 + 7
	}
	c: i64 = 0
	for p in lo ..= hi {
		if naive_bit(b, p) {
			c += 1
		}
	}
	return c
}

ref_bitpos :: proc(b: []u8, bit: bool, start, end: i64, unit: bm.Unit, end_given: bool) -> i64 {
	n := i64(len(b))
	tot := n * 8 if unit == .Bit else n
	e0 := end
	if !end_given {
		e0 = n * 8 + 7 if unit == .Bit else n - 1
	}
	s, e := ref_normalise(start, e0, tot)
	if s > e {
		return -1
	}
	lo, hi := s, e
	if unit == .Byte {
		lo = s * 8
		hi = e * 8 + 7
	}
	for p in lo ..= hi {
		if naive_bit(b, p) == bit {
			return p
		}
	}
	if bit || end_given {
		return -1
	}
	return hi + 1
}

ref_bitpos_all :: proc(b: []u8, bit: bool) -> i64 {
	if len(b) == 0 {
		return -1
	}
	return naive_find_bit(b, bit)
}

ref_bitop :: proc(op: bm.Bitop, srcs: [][]u8, allocator := context.temp_allocator) -> []u8 {
	maxlen := 0
	for s in srcs {
		maxlen = max(maxlen, len(s))
	}
	out := make([]u8, maxlen, allocator)
	for j in 0 ..< maxlen {
		acc: u8 = srcs[0][j] if j < len(srcs[0]) else 0
		if op == .Not {
			acc = ~acc
		}
		for i in 1 ..< len(srcs) {
			b: u8 = srcs[i][j] if j < len(srcs[i]) else 0
			switch op {
			case .And:
				acc &= b
			case .Or:
				acc |= b
			case .Xor:
				acc ~= b
			case .Not:
			}
		}
		out[j] = acc
	}
	return out
}

naive_set_field :: proc(b: []u8, offset: u64, bits: u64, value: u64) {
	for j in 0 ..< bits {
		pos := offset + j
		mask := u8(0x80) >> u8(pos & 7)
		if (value >> (bits - 1 - j)) & 1 != 0 {
			b[pos >> 3] |= mask
		} else {
			b[pos >> 3] &= ~mask
		}
	}
}

naive_get_field :: proc(b: []u8, offset: u64, bits: u64) -> u64 {
	v: u64 = 0
	for j in 0 ..< bits {
		pos := offset + j
		v = (v << 1) | (1 if b[pos >> 3] & (u8(0x80) >> u8(pos & 7)) != 0 else 0)
	}
	return v
}

floor_mod :: proc(a, m: i128) -> i128 {
	r := a % m
	if r < 0 {
		r += m
	}
	return r
}

ref_field :: proc(signed: bool, bits: u64, sum: i128, mode: bm.Overflow) -> (value: i64, null: bool) {
	minv, maxv: i128
	if signed {
		maxv = (i128(1) << (bits - 1)) - 1
		minv = -maxv - 1
	} else {
		maxv = (i128(1) << bits) - 1
		minv = 0
	}
	if sum >= minv && sum <= maxv {
		return i64(sum), false
	}
	switch mode {
	case .Wrap:
		return i64(floor_mod(sum - minv, i128(1) << bits) + minv), false
	case .Sat:
		return i64(maxv) if sum > maxv else i64(minv), false
	case .Fail:
	}
	return 0, true
}

interesting_offsets :: proc(l: i64, allocator := context.temp_allocator) -> []i64 {
	base := [?]i64 {
		min(i64),
		-8 * l - 9,
		-8 * l - 1,
		-8 * l,
		-8 * l + 1,
		-l - 1,
		-l,
		-l + 1,
		-9,
		-8,
		-2,
		-1,
		0,
		1,
		2,
		7,
		8,
		9,
		l - 1,
		l,
		l + 1,
		8 * l - 1,
		8 * l,
		8 * l + 1,
		max(i64),
	}
	out := make([dynamic]i64, allocator)
	for v in base {
		if !slice.contains(out[:], v) {
			append(&out, v)
		}
	}
	return out[:]
}

package bits_test

import bm "../../src/bitmap"

main :: proc() {
}

ref_bit :: proc(buf: []u8, i: i64) -> bool {
	if i < 0 || i / 8 >= i64(len(buf)) {
		return false
	}
	return (buf[i / 8] >> u8(7 - i % 8)) & 1 == 1
}

ref_put_bit :: proc(buf: []u8, i: i64, on: bool) {
	mask := u8(1) << u8(7 - i % 8)
	if on {
		buf[i / 8] |= mask
	} else {
		buf[i / 8] &= ~mask
	}
}

ref_popcount :: proc(buf: []u8) -> i64 {
	total: i64
	for i in 0 ..< i64(len(buf)) * 8 {
		if ref_bit(buf, i) {
			total += 1
		}
	}
	return total
}

ref_normalize :: proc(total, start_in, end_in: i64) -> (start, end: i64) {
	start, end = start_in, end_in
	if start < 0 {
		start = max(total + start, 0)
	}
	if end < 0 {
		end = max(total + end, 0)
	}
	end = min(end, total - 1)
	return
}

ref_bitcount :: proc(buf: []u8, start_in, end_in: i64, unit: bm.Unit) -> i64 {
	if start_in < 0 && end_in < 0 && start_in > end_in {
		return 0
	}
	scale: i64 = 1 if unit == .Bit else 8
	total := i64(len(buf)) * 8 / scale
	start, end := ref_normalize(total, start_in, end_in)
	count: i64
	for i := start * scale; i <= end * scale + scale - 1 && start <= end; i += 1 {
		if ref_bit(buf, i) {
			count += 1
		}
	}
	return count
}

ref_bitpos :: proc(buf: []u8, bit: bool, start_in, end_in: i64, unit: bm.Unit, end_given: bool) -> i64 {
	scale: i64 = 1 if unit == .Bit else 8
	total := i64(len(buf)) * 8 / scale
	start, end := ref_normalize(total, start_in, end_in)
	if start > end {
		return -1
	}
	first := start * scale
	last := end * scale + scale - 1
	for i := first; i <= last; i += 1 {
		if ref_bit(buf, i) == bit {
			return i
		}
	}
	if !bit && !end_given {
		return last + 1
	}
	return -1
}

ref_bitop :: proc(op: bm.Bitop, srcs: [][]u8, allocator := context.allocator) -> []u8 {
	longest := 0
	for s in srcs {
		longest = max(longest, len(s))
	}
	out := make([]u8, longest, allocator)
	for i in 0 ..< longest {
		acc: u8
		for s, k in srcs {
			b: u8 = s[i] if i < len(s) else 0
			if k == 0 {
				acc = ~b if op == .Not else b
				continue
			}
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
		out[i] = acc
	}
	return out
}

ref_get_field :: proc(buf: []u8, offset: u64, bits: int, signed: bool) -> i64 {
	v: u64
	for k in 0 ..< bits {
		v <<= 1
		if ref_bit(buf, i64(offset) + i64(k)) {
			v |= 1
		}
	}
	if signed && bits < 64 && (v >> u64(bits - 1)) & 1 == 1 {
		v |= ~u64(0) << u64(bits)
	}
	return i64(v)
}

ref_set_field :: proc(buf: []u8, offset: u64, bits: int, value: u64) {
	for k in 0 ..< bits {
		on := (value >> u64(bits - 1 - k)) & 1 == 1
		ref_put_bit(buf, i64(offset) + i64(k), on)
	}
}

Ref_Outcome :: struct {
	stored: i64,
	reply:  i64,
	null:   bool,
}

ref_low_bits :: proc(v: i128, bits: int, signed: bool) -> i64 {
	m := i128(1) << u128(bits)
	r := v %% m
	if signed && r >= m / 2 {
		r -= m
	}
	return i64(r)
}

ref_field_op :: proc(old: i64, opcode: bm.Bitfield_Opcode, arg: i64, bits: int, signed: bool, mode: bm.Overflow) -> Ref_Outcome {
	lo, hi: i128
	if signed {
		hi = (i128(1) << u128(bits - 1)) - 1
		lo = -hi - 1
	} else {
		hi = (i128(1) << u128(bits)) - 1
		lo = 0
	}
	target: i128
	if opcode == .Set {
		target = i128(arg) if signed else i128(u64(arg))
	} else {
		target = i128(old) + i128(arg)
	}
	wrapped := ref_low_bits(target, bits, signed)
	if mode == .Wrap || (target >= lo && target <= hi) {
		result := wrapped if mode == .Wrap else i64(target)
		return {stored = result, reply = old if opcode == .Set else result}
	}
	upward := target > hi
	if signed && opcode == .Set && target < lo && hi - target > i128(max(i64)) {
		upward = true
	}
	if mode == .Fail {
		return {stored = old, null = true}
	}
	clamp := i64(hi) if upward else i64(lo)
	return {stored = clamp, reply = old if opcode == .Set else clamp}
}

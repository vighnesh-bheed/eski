package bitmap

import "base:intrinsics"
import "core:simd"

Lane32 :: #simd[32]u8
Lane16 :: #simd[16]u8
Quad64 :: #simd[4]u64

POPCOUNT_WIDE_MIN :: 256
SCAN_WIDE_MIN :: 64

load_word :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	return intrinsics.unaligned_load((^u64)(p))
}

store_word :: #force_inline proc "contextless" (p: [^]u8, v: u64) {
	intrinsics.unaligned_store((^u64)(p), v)
}

load_be_word :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	when ODIN_ENDIAN == .Little {
		return intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(p)))
	} else {
		return intrinsics.unaligned_load((^u64)(p))
	}
}

store_be_word :: #force_inline proc "contextless" (p: [^]u8, v: u64) {
	when ODIN_ENDIAN == .Little {
		intrinsics.unaligned_store((^u64)(p), intrinsics.byte_swap(v))
	} else {
		intrinsics.unaligned_store((^u64)(p), v)
	}
}

first_set_in_word :: #force_inline proc "contextless" (w: u64) -> i64 {
	when ODIN_ENDIAN == .Little {
		return i64(intrinsics.count_leading_zeros(intrinsics.byte_swap(w)))
	} else {
		return i64(intrinsics.count_leading_zeros(w))
	}
}

popcount_generic :: proc "contextless" (p: [^]u8, n: int) -> i64 #no_bounds_check {
	t0, t1, t2, t3: u64
	i := 0
	for ; i + 32 <= n; i += 32 {
		t0 += intrinsics.count_ones(load_word(p[i:]))
		t1 += intrinsics.count_ones(load_word(p[i + 8:]))
		t2 += intrinsics.count_ones(load_word(p[i + 16:]))
		t3 += intrinsics.count_ones(load_word(p[i + 24:]))
	}
	for ; i + 8 <= n; i += 8 {
		t0 += intrinsics.count_ones(load_word(p[i:]))
	}
	for ; i < n; i += 1 {
		t1 += u64(intrinsics.count_ones(p[i]))
	}
	return i64(t0 + t1 + t2 + t3)
}

when ODIN_ARCH == .amd64 {
	@(enable_target_feature = "popcnt")
	popcount_popcnt :: proc "contextless" (p: [^]u8, n: int) -> i64 #no_bounds_check {
		t0, t1, t2, t3: u64
		i := 0
		for ; i + 32 <= n; i += 32 {
			t0 += intrinsics.count_ones(load_word(p[i:]))
			t1 += intrinsics.count_ones(load_word(p[i + 8:]))
			t2 += intrinsics.count_ones(load_word(p[i + 16:]))
			t3 += intrinsics.count_ones(load_word(p[i + 24:]))
		}
		for ; i + 8 <= n; i += 8 {
			t0 += intrinsics.count_ones(load_word(p[i:]))
		}
		for ; i < n; i += 1 {
			t1 += u64(intrinsics.count_ones(p[i]))
		}
		return i64(t0 + t1 + t2 + t3)
	}

	@(enable_target_feature = "avx2,popcnt")
	popcount_avx2 :: proc "contextless" (p: [^]u8, n: int) -> i64 #no_bounds_check {
		low_bytes := Quad64(0x00ff00ff00ff00ff)
		spread := Quad64(0x0001000100010001)
		sums: Quad64
		i := 0
		for n - i >= 128 {
			rounds := min((n - i) / 128, 7)
			acc: Lane32
			for _ in 0 ..< rounds {
				a := intrinsics.unaligned_load((^Lane32)(p[i:]))
				b := intrinsics.unaligned_load((^Lane32)(p[i + 32:]))
				c := intrinsics.unaligned_load((^Lane32)(p[i + 64:]))
				d := intrinsics.unaligned_load((^Lane32)(p[i + 96:]))
				acc += (intrinsics.count_ones(a) + intrinsics.count_ones(b)) + (intrinsics.count_ones(c) + intrinsics.count_ones(d))
				i += 128
			}
			w := transmute(Quad64)acc
			pairs := (w & low_bytes) + (simd.shr(w, Quad64(8)) & low_bytes)
			sums += simd.shr(pairs * spread, Quad64(48))
		}
		total := simd.reduce_add_ordered(sums)
		for ; i + 8 <= n; i += 8 {
			total += intrinsics.count_ones(load_word(p[i:]))
		}
		for ; i < n; i += 1 {
			total += u64(intrinsics.count_ones(p[i]))
		}
		return i64(total)
	}
}

popcount_raw :: #force_inline proc "contextless" (p: [^]u8, n: int) -> i64 {
	when ODIN_ARCH == .amd64 {
		if n >= POPCOUNT_WIDE_MIN {
			switch cpu_level {
			case .Avx2:
				return popcount_avx2(p, n)
			case .Popcnt:
				return popcount_popcnt(p, n)
			case .Generic:
			}
		}
	}
	return popcount_generic(p, n)
}

popcount :: proc "contextless" (buf: []u8) -> i64 #no_bounds_check {
	return popcount_raw(raw_data(buf), len(buf))
}

when ODIN_ARCH == .amd64 {
	@(enable_target_feature = "avx2")
	skip_uniform_avx2 :: proc "contextless" (p: [^]u8, n: int, fill: u8) -> int #no_bounds_check {
		pattern := Lane32(fill)
		zero := Lane32(0)
		i := 0
		for i + 128 <= n {
			a := intrinsics.unaligned_load((^Lane32)(p[i:])) ~ pattern
			b := intrinsics.unaligned_load((^Lane32)(p[i + 32:])) ~ pattern
			c := intrinsics.unaligned_load((^Lane32)(p[i + 64:])) ~ pattern
			d := intrinsics.unaligned_load((^Lane32)(p[i + 96:])) ~ pattern
			m := intrinsics.simd_extract_msbs(simd.lanes_ne((a | b) | (c | d), zero))
			if transmute(u32)m != 0 {
				break
			}
			i += 128
		}
		for i + 32 <= n {
			v := intrinsics.unaligned_load((^Lane32)(p[i:])) ~ pattern
			m := intrinsics.simd_extract_msbs(simd.lanes_ne(v, zero))
			if transmute(u32)m != 0 {
				return i
			}
			i += 32
		}
		return i
	}
}

skip_uniform_sse :: proc "contextless" (p: [^]u8, n: int, fill: u8) -> int #no_bounds_check {
	pattern := Lane16(fill)
	zero := Lane16(0)
	i := 0
	for i + 64 <= n {
		a := intrinsics.unaligned_load((^Lane16)(p[i:])) ~ pattern
		b := intrinsics.unaligned_load((^Lane16)(p[i + 16:])) ~ pattern
		c := intrinsics.unaligned_load((^Lane16)(p[i + 32:])) ~ pattern
		d := intrinsics.unaligned_load((^Lane16)(p[i + 48:])) ~ pattern
		m := intrinsics.simd_extract_msbs(simd.lanes_ne((a | b) | (c | d), zero))
		if transmute(u16)m != 0 {
			break
		}
		i += 64
	}
	return i
}

find_raw :: proc "contextless" (p: [^]u8, n: int, bit: bool) -> i64 #no_bounds_check {
	fill: u8 = 0 if bit else 0xff
	flip: u64 = 0 if bit else max(u64)
	i := 0
	if n >= SCAN_WIDE_MIN {
		when ODIN_ARCH == .amd64 {
			if cpu_level == .Avx2 {
				i = skip_uniform_avx2(p, n, fill)
			} else {
				i = skip_uniform_sse(p, n, fill)
			}
		} else {
			i = skip_uniform_sse(p, n, fill)
		}
	}
	for ; i + 8 <= n; i += 8 {
		w := load_word(p[i:]) ~ flip
		if w != 0 {
			return i64(i) * 8 + first_set_in_word(w)
		}
	}
	for ; i < n; i += 1 {
		b := p[i] ~ fill
		if b != 0 {
			return i64(i) * 8 + i64(intrinsics.count_leading_zeros(b))
		}
	}
	return -1
}

find_bit :: proc "contextless" (buf: []u8, bit: bool) -> i64 #no_bounds_check {
	return find_raw(raw_data(buf), len(buf), bit)
}

getbit :: proc "contextless" (buf: []u8, offset: i64) -> bool #no_bounds_check {
	if offset < 0 {
		return false
	}
	index := offset >> 3
	if index >= i64(len(buf)) {
		return false
	}
	return (buf[index] >> (7 - u8(offset & 7))) & 1 != 0
}

setbit :: proc(
	buf: ^[]u8,
	offset: i64,
	value: bool,
	allocator := RAW_HEAP_ALLOCATOR,
	capacity: ^int = nil,
	max_bulk_len := PROTO_MAX_BULK_LEN,
) -> (
	old: bool,
	err: Error,
) #no_bounds_check {
	if offset < 0 || (offset >> 3) >= max_bulk_len {
		return false, .Bit_Offset
	}
	index := int(offset >> 3)
	if index >= len(buf^) {
		if grow_zero(buf, index + 1, allocator, capacity) != .None {
			return false, .Out_Of_Memory
		}
	}
	data := buf^
	mask := u8(0x80) >> u8(offset & 7)
	old = data[index] & mask != 0
	if value {
		data[index] |= mask
	} else {
		data[index] &~= mask
	}
	return old, .None
}

count_bit_range :: proc "contextless" (p: [^]u8, lo, hi: i64) -> i64 #no_bounds_check {
	first := lo >> 3
	last := hi >> 3
	head := u8(0xff) >> u8(lo & 7)
	tail := u8(0xff) << u8(7 - (hi & 7))
	if first == last {
		return i64(intrinsics.count_ones(p[first] & head & tail))
	}
	total := i64(intrinsics.count_ones(p[first] & head)) + i64(intrinsics.count_ones(p[last] & tail))
	inner := int(last - first - 1)
	if inner > 0 {
		total += popcount_raw(p[first + 1:], inner)
	}
	return total
}

find_bit_range :: proc "contextless" (p: [^]u8, bit: bool, lo, hi: i64) -> i64 #no_bounds_check {
	fill: u8 = 0 if bit else 0xff
	first := lo >> 3
	last := hi >> 3
	head := u8(0xff) >> u8(lo & 7)
	tail := u8(0xff) << u8(7 - (hi & 7))
	if first == last {
		b := (p[first] ~ fill) & head & tail
		if b != 0 {
			return first * 8 + i64(intrinsics.count_leading_zeros(b))
		}
		return -1
	}
	b := (p[first] ~ fill) & head
	if b != 0 {
		return first * 8 + i64(intrinsics.count_leading_zeros(b))
	}
	inner := int(last - first - 1)
	if inner > 0 {
		r := find_raw(p[first + 1:], inner, bit)
		if r >= 0 {
			return (first + 1) * 8 + r
		}
	}
	b = (p[last] ~ fill) & tail
	if b != 0 {
		return last * 8 + i64(intrinsics.count_leading_zeros(b))
	}
	return -1
}

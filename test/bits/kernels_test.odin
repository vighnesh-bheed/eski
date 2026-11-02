package bits_test

import "core:math/rand"
import "core:testing"
import bm "../../src/bitmap"

ALL_LEVELS := [?]bm.Cpu_Level{.Generic, .Popcnt, .Avx2}

levels_available :: proc() -> []bm.Cpu_Level {
	switch bm.probe_cpu_level() {
	case .Avx2:
		return ALL_LEVELS[:3]
	case .Popcnt:
		return ALL_LEVELS[:2]
	case .Generic:
	}
	return ALL_LEVELS[:1]
}

random_length :: proc(limit: int) -> int {
	switch rand.int_max(4) {
	case 0:
		return rand.int_max(16)
	case 1:
		return rand.int_max(300)
	}
	return rand.int_max(limit + 1)
}

fill_random :: proc(buf: []u8) {
	switch rand.int_max(5) {
	case 0:
		for i in 0 ..< len(buf) {
			buf[i] = 0
		}
	case 1:
		for i in 0 ..< len(buf) {
			buf[i] = 0xff
		}
	case 2:
		for i in 0 ..< len(buf) {
			buf[i] = 0xff if rand.int_max(64) != 0 else u8(rand.uint32())
		}
	case 3:
		for i in 0 ..< len(buf) {
			buf[i] = 0 if rand.int_max(64) != 0 else u8(rand.uint32())
		}
	case:
		for i in 0 ..< len(buf) {
			buf[i] = u8(rand.uint32())
		}
	}
}

random_slice :: proc(limit: int) -> (backing: []u8, view: []u8) {
	n := random_length(limit)
	pad := rand.int_max(33)
	backing = make([]u8, n + pad + 1)
	view = backing[pad:pad + n]
	fill_random(view)
	return
}

random_index :: proc(total: i64) -> i64 {
	switch rand.int_max(8) {
	case 0:
		return min(i64)
	case 1:
		return max(i64)
	case 2:
		return -1
	case 3:
		return 0
	case 4:
		return total
	case 5:
		return -total - 1 - i64(rand.int_max(3))
	}
	span := total + 3
	return i64(rand.int_max(int(2 * span + 1))) - span
}

@(test)
popcount_matches_reference :: proc(t: ^testing.T) {
	saved := bm.cpu_level
	defer bm.cpu_level = saved
	for level in levels_available() {
		bm.cpu_level = level
		for _ in 0 ..< 250 {
			backing, view := random_slice(2500)
			testing.expect_value(t, bm.popcount(view), ref_popcount(view))
			delete(backing)
		}
		big := make([]u8, 200_003)
		fill_random(big)
		testing.expect_value(t, bm.popcount(big), ref_popcount(big))
		testing.expect_value(t, bm.popcount(big[5:]), ref_popcount(big[5:]))
		delete(big)
	}
}

@(test)
find_bit_matches_reference :: proc(t: ^testing.T) {
	saved := bm.cpu_level
	defer bm.cpu_level = saved
	for level in levels_available() {
		bm.cpu_level = level
		for _ in 0 ..< 400 {
			n := random_length(3000)
			pad := rand.int_max(33)
			backing := make([]u8, n + pad + 1)
			view := backing[pad:pad + n]
			base: u8 = 0 if rand.int_max(2) == 0 else 0xff
			for i in 0 ..< n {
				view[i] = base
			}
			flips := rand.int_max(3)
			for _ in 0 ..< flips {
				if n > 0 {
					p := rand.int_max(n * 8)
					view[p / 8] ~= u8(0x80) >> u8(p % 8)
				}
			}
			for bit in ([]bool{false, true}) {
				want: i64 = -1
				for i in 0 ..< i64(n) * 8 {
					if ref_bit(view, i) == bit {
						want = i
						break
					}
				}
				testing.expect_value(t, bm.find_bit(view, bit), want)
			}
			delete(backing)
		}
	}
}

@(test)
bitcount_ranges_match_reference :: proc(t: ^testing.T) {
	saved := bm.cpu_level
	defer bm.cpu_level = saved
	for level in levels_available() {
		bm.cpu_level = level
		for _ in 0 ..< 1500 {
			backing, view := random_slice(700)
			unit := bm.Unit.Bit if rand.int_max(2) == 0 else bm.Unit.Byte
			total := i64(len(view)) * (8 if unit == .Bit else 1)
			start := random_index(total)
			end := random_index(total)
			got := bm.bitcount(view, start, end, unit)
			want := ref_bitcount(view, start, end, unit)
			if got != want {
				testing.expectf(t, false, "bitcount len=%d %d %d %v got %d want %d", len(view), start, end, unit, got, want)
			}
			args := bm.Bitcount_Args{start, end, unit, true}
			testing.expect_value(t, bm.bitcount_args(view, args), want)
			testing.expect_value(t, bm.bitcount_args(view, {}), ref_popcount(view))
			delete(backing)
		}
	}
}

@(test)
bitpos_ranges_match_reference :: proc(t: ^testing.T) {
	saved := bm.cpu_level
	defer bm.cpu_level = saved
	for level in levels_available() {
		bm.cpu_level = level
		for _ in 0 ..< 1500 {
			backing, view := random_slice(700)
			unit := bm.Unit.Bit if rand.int_max(2) == 0 else bm.Unit.Byte
			total := i64(len(view)) * (8 if unit == .Bit else 1)
			start := random_index(total)
			end := random_index(total)
			end_given := rand.int_max(2) == 0
			if !end_given {
				end = -1
			}
			for bit in ([]bool{false, true}) {
				got := bm.bitpos(view, bit, start, end, unit, end_given)
				want := ref_bitpos(view, bit, start, end, unit, end_given)
				if got != want {
					testing.expectf(t, false, "bitpos len=%d bit=%v %d %d %v given=%v got %d want %d", len(view), bit, start, end, unit, end_given, got, want)
				}
				args := bm.Bitpos_Args{start, end, unit, bit, true, end_given}
				testing.expect_value(t, bm.bitpos_args(view, true, args), want)
				whole := bm.Bitpos_Args{bit = bit, end = -1}
				testing.expect_value(t, bm.bitpos_args(view, true, whole), ref_bitpos(view, bit, 0, -1, .Byte, false))
				testing.expect_value(t, bm.bitpos_all(view, bit), ref_bitpos(view, bit, 0, -1, .Byte, false))
				testing.expect_value(t, bm.bitpos_args(nil, false, args), -1 if bit else 0)
			}
			delete(backing)
		}
	}
}

@(test)
setbit_getbit_match_reference :: proc(t: ^testing.T) {
	buf: []u8
	capacity := 0
	model := make([dynamic]u8)
	defer delete(model)
	defer bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	for step in 0 ..< 4000 {
		limit := 64 if step < 2000 else 40_000
		offset := i64(rand.int_max(limit * 8))
		on := rand.int_max(2) == 0
		old, err := bm.setbit(&buf, offset, on, bm.RAW_HEAP_ALLOCATOR, &capacity)
		testing.expect_value(t, err, bm.Error.None)
		for i64(len(model)) <= offset / 8 {
			append(&model, 0)
		}
		testing.expect_value(t, old, ref_bit(model[:], offset))
		ref_put_bit(model[:], offset, on)
		testing.expect_value(t, len(buf), len(model))
		testing.expect(t, capacity >= len(buf))
		probe := i64(rand.int_max(limit * 8 + 64)) - 8
		testing.expect_value(t, bm.getbit(buf, probe), ref_bit(model[:], probe))
	}
	testing.expect(t, string(buf) == string(model[:]))
}

@(test)
grow_zero_clears_spare_capacity :: proc(t: ^testing.T) {
	buf: []u8
	capacity := 0
	testing.expect_value(t, bm.grow_zero(&buf, 10, bm.RAW_HEAP_ALLOCATOR, &capacity), bm.Error.None)
	testing.expect_value(t, len(buf), 10)
	testing.expect_value(t, capacity, 20)
	for i in 0 ..< len(buf) {
		buf[i] = 0xaa
	}
	buf = buf[:3]
	testing.expect_value(t, bm.grow_zero(&buf, 15, bm.RAW_HEAP_ALLOCATOR, &capacity), bm.Error.None)
	testing.expect_value(t, capacity, 20)
	for i in 3 ..< 15 {
		testing.expect_value(t, buf[i], 0)
	}
	testing.expect_value(t, buf[0], 0xaa)
	testing.expect_value(t, bm.grow_zero(&buf, 2 * bm.GREEDY_GROWTH_LIMIT, bm.RAW_HEAP_ALLOCATOR, &capacity), bm.Error.None)
	testing.expect_value(t, capacity, 3 * bm.GREEDY_GROWTH_LIMIT)
	testing.expect_value(t, buf[2], 0xaa)
	testing.expect_value(t, buf[3], 0)
	bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	testing.expect(t, buf == nil)
	testing.expect_value(t, capacity, 0)
	exact: []u8
	testing.expect_value(t, bm.grow_zero(&exact, 7), bm.Error.None)
	testing.expect_value(t, len(exact), 7)
	bm.free_bytes(&exact)
}

@(test)
setbit_limits_without_large_allocations :: proc(t: ^testing.T) {
	buf: []u8
	capacity := 0
	defer bm.free_bytes(&buf, bm.RAW_HEAP_ALLOCATOR, &capacity)
	_, err := bm.setbit(&buf, 16 * 8, true, bm.RAW_HEAP_ALLOCATOR, &capacity, 16)
	testing.expect_value(t, err, bm.Error.Bit_Offset)
	_, err = bm.setbit(&buf, -1, true, bm.RAW_HEAP_ALLOCATOR, &capacity, 16)
	testing.expect_value(t, err, bm.Error.Bit_Offset)
	testing.expect_value(t, len(buf), 0)
	old: bool
	old, err = bm.setbit(&buf, 16 * 8 - 1, true, bm.RAW_HEAP_ALLOCATOR, &capacity, 16)
	testing.expect_value(t, err, bm.Error.None)
	testing.expect_value(t, old, false)
	testing.expect_value(t, len(buf), 16)
	testing.expect_value(t, buf[15], 1)
	testing.expect(t, bm.getbit(buf, 127))
	testing.expect(t, !bm.getbit(buf, 128))
	testing.expect(t, !bm.getbit(buf, max(i64)))
	testing.expect(t, !bm.getbit(buf, -1))
	off, perr := bm.parse_bit_offset(transmute([]u8)string("4294967295"))
	testing.expect_value(t, perr, bm.Error.None)
	testing.expect_value(t, off, 4294967295)
	_, perr = bm.parse_bit_offset(transmute([]u8)string("4294967296"))
	testing.expect_value(t, perr, bm.Error.Bit_Offset)
	_, perr = bm.parse_bit_offset(transmute([]u8)string("127"), false, 0, 16)
	testing.expect_value(t, perr, bm.Error.None)
	_, perr = bm.parse_bit_offset(transmute([]u8)string("128"), false, 0, 16)
	testing.expect_value(t, perr, bm.Error.Bit_Offset)
	off, perr = bm.parse_bit_offset(transmute([]u8)string("#536870911"), true, 8)
	testing.expect_value(t, perr, bm.Error.None)
	testing.expect_value(t, off, 4294967288)
	_, perr = bm.parse_bit_offset(transmute([]u8)string("#536870912"), true, 8)
	testing.expect_value(t, perr, bm.Error.Bit_Offset)
}

@(test)
bitop_matches_reference :: proc(t: ^testing.T) {
	saved := bm.cpu_level
	defer bm.cpu_level = saved
	for level in levels_available() {
		bm.cpu_level = level
		for round in 0 ..< 300 {
			op := bm.Bitop(rand.int_max(4))
			count := 1 if op == .Not else 1 + rand.int_max(5)
			backings := make([][]u8, count)
			srcs := make([][]u8, count)
			limit := 600 if round % 25 != 0 else 3 * bm.BITOP_CHUNK + 77
			for k in 0 ..< count {
				backings[k], srcs[k] = random_slice(limit)
				if rand.int_max(6) == 0 {
					srcs[k] = nil
				}
			}
			out: []u8
			n, err := bm.bitop(op, srcs, &out)
			want := ref_bitop(op, srcs)
			testing.expect_value(t, err, bm.Error.None)
			testing.expect_value(t, n, len(want))
			testing.expect(t, string(out) == string(want))
			if n == 0 {
				testing.expect(t, out == nil)
			}
			bm.free_bytes(&out)
			delete(want)
			for k in 0 ..< count {
				delete(backings[k])
			}
			delete(backings)
			delete(srcs)
		}
	}
	out: []u8
	_, err := bm.bitop(.Not, [][]u8{nil, nil}, &out)
	testing.expect_value(t, err, bm.Error.Bitop_Not_Arity)
	n: int
	n, err = bm.bitop(.And, [][]u8{nil, nil}, &out)
	testing.expect_value(t, err, bm.Error.None)
	testing.expect_value(t, n, 0)
	testing.expect(t, out == nil)
}

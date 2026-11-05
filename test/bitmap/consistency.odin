package bitmap_harness

import "core:math/rand"
import bm "../../src/bitmap"

unit_reference_consistency :: proc() {
	rand.reset(16)
	for round in 0 ..< 400 {
		n := int(rand.int31_max(300))
		buf := make([]u8, n, context.temp_allocator)
		for i in 0 ..< n {
			buf[i] = u8(rand.int31_max(256))
			if round % 7 == 0 {
				buf[i] = 0
			} else if round % 7 == 1 {
				buf[i] = 0xff
			}
		}
		check(bm.popcount(buf) == naive_popcount(buf), "popcount round %d", round)
		check(bm.find_bit(buf, true) == naive_find_bit(buf, true), "find_bit 1 round %d", round)
		if n > 0 {
			for _ in 0 ..< 8 {
				start := i64(rand.int31_max(i32(n)))
				end := start + i64(rand.int31_max(i32(n - int(start))))
				check(bm.bitcount(buf, start, end, .Byte) == ref_bitcount(buf, start, end, .Byte), "bitcount %d %d round %d", start, end, round)
			}
		}
		other := make([]u8, int(rand.int31_max(300)), context.temp_allocator)
		for i in 0 ..< len(other) {
			other[i] = u8(rand.int31_max(256))
		}
		srcs := [][]u8{buf, other}
		for op in ([]bm.Bitop{.And, .Or, .Xor}) {
			dst: []u8
			length, err := bm.bitop(op, srcs, &dst)
			want := ref_bitop(op, srcs)
			check(err == .None && length == len(want) && string(dst) == string(want), "bitop %v round %d", op, round)
			bm.free_bytes(&dst)
		}
		dst: []u8
		length, err := bm.bitop(.Not, srcs[:1], &dst)
		want := ref_bitop(.Not, srcs[:1])
		check(err == .None && length == len(want) && string(dst) == string(want), "bitop not round %d", round)
		bm.free_bytes(&dst)
		free_all(context.temp_allocator)
	}
}

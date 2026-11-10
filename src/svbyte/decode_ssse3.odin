#+build amd64
package svbyte

import "base:intrinsics"
import "core:simd"

U8x16 :: #simd[16]u8

U32x4 :: #simd[4]u32

@(enable_target_feature = "sse2,ssse3")
decode_ssse3 :: proc "contextless" (data: []u8, out: []u32) -> int #no_bounds_check {
	n := len(out)
	groups := n >> 2
	pos := control_bytes(n)
	end := len(data)
	g := 0
	for ; g < groups && pos + 16 <= end; g += 1 {
		c := data[g]
		v := intrinsics.unaligned_load((^U8x16)(&data[pos]))
		mask := intrinsics.unaligned_load((^U8x16)(&SHUFFLE[c][0]))
		intrinsics.unaligned_store((^U8x16)(&out[4 * g]), simd.runtime_swizzle(v, mask))
		pos += int(LENGTH[c])
	}
	return decode_tail(data, out, 4 * g, pos, false, 0)
}

@(enable_target_feature = "sse2,ssse3")
decode_delta_ssse3 :: proc "contextless" (data: []u8, out: []u32, previous: u32) -> int #no_bounds_check {
	n := len(out)
	groups := n >> 2
	pos := control_bytes(n)
	end := len(data)
	prev := U32x4{previous, previous, previous, previous}
	zero := U32x4{}
	g := 0
	for ; g < groups && pos + 16 <= end; g += 1 {
		c := data[g]
		v := intrinsics.unaligned_load((^U8x16)(&data[pos]))
		mask := intrinsics.unaligned_load((^U8x16)(&SHUFFLE[c][0]))
		d := transmute(U32x4)simd.runtime_swizzle(v, mask)
		d += simd.shuffle(d, zero, 4, 0, 1, 2)
		d += simd.shuffle(d, zero, 4, 5, 0, 1)
		d += prev
		intrinsics.unaligned_store((^U32x4)(&out[4 * g]), d)
		prev = simd.shuffle(d, d, 3, 3, 3, 3)
		pos += int(LENGTH[c])
	}
	last := previous
	if g > 0 {
		last = out[4 * g - 1]
	}
	return decode_tail(data, out, 4 * g, pos, true, last)
}

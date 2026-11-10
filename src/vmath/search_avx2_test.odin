#+build amd64
package vmath

import "base:intrinsics"
import "core:simd"

@(enable_target_feature = "avx2,f16c")
f16_hard_widen_all :: proc "contextless" (out: []u32) #no_bounds_check {
	for base := 0; base + 8 <= len(out); base += 8 {
		v: U16x8
		for j in 0 ..< 8 {
			v = simd.replace(v, j, u16(base + j))
		}
		w := cast(F32x8)transmute(#simd[8]f16)v
		intrinsics.unaligned_store((^F32x8)(&out[base]), w)
	}
}

f16_hard_matches_soft :: proc() -> bool {
	hard := make([]u32, 0x10000, context.temp_allocator)
	f16_hard_widen_all(hard)
	for base := 0; base < 0x10000; base += 8 {
		v: U16x8
		for j in 0 ..< 8 {
			v = simd.replace(v, j, u16(base + j))
		}
		soft := transmute(U32x8)f16x8_soft(v)
		for j in 0 ..< 8 {
			x := hard[base + j]
			y := simd.extract(soft, j)
			if x != y && !(x & 0x7F800000 == 0x7F800000 && x & 0x7FFFFF != 0 && x | 0x400000 == y) {
				return false
			}
		}
	}
	return true
}

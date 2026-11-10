#+build amd64
package sorted

import "base:intrinsics"
import "core:simd"
import x86 "core:simd/x86"

U32x8 :: #simd[8]u32
I32x8 :: #simd[8]i32

@(private = "file", default_calling_convention = "none")
foreign _ {
	@(link_name = "llvm.x86.avx2.permd")
	permd :: proc(a: I32x8, b: I32x8) -> I32x8 ---
}

compress_table: [256][8]i32

build_compress_table :: proc "contextless" () {
	for mask in 0 ..< 256 {
		n := 0
		for lane in 0 ..< 8 {
			if mask >> uint(lane) & 1 != 0 {
				compress_table[mask][n] = i32(lane)
				n += 1
			}
		}
		for ; n < 8; n += 1 {
			compress_table[mask][n] = 0
		}
	}
}

@(enable_target_feature = "avx,avx2")
block_match :: proc "contextless" (va, vb: U32x8) -> u32 {
	m := simd.lanes_eq(va, vb)
	m |= simd.lanes_eq(va, simd.shuffle(vb, vb, 1, 2, 3, 4, 5, 6, 7, 0))
	m |= simd.lanes_eq(va, simd.shuffle(vb, vb, 2, 3, 4, 5, 6, 7, 0, 1))
	m |= simd.lanes_eq(va, simd.shuffle(vb, vb, 3, 4, 5, 6, 7, 0, 1, 2))
	m |= simd.lanes_eq(va, simd.shuffle(vb, vb, 4, 5, 6, 7, 0, 1, 2, 3))
	m |= simd.lanes_eq(va, simd.shuffle(vb, vb, 5, 6, 7, 0, 1, 2, 3, 4))
	m |= simd.lanes_eq(va, simd.shuffle(vb, vb, 6, 7, 0, 1, 2, 3, 4, 5))
	m |= simd.lanes_eq(va, simd.shuffle(vb, vb, 7, 0, 1, 2, 3, 4, 5, 6))
	return u32(x86._mm256_movemask_ps(transmute(x86.__m256)m))
}

@(enable_target_feature = "avx,avx2")
intersect_avx2 :: proc "contextless" (a, b: []u32, out: []u32) -> int #no_bounds_check {
	na, nb, room := len(a), len(b), len(out)
	pa, pb, po := raw_data(a), raw_data(b), raw_data(out)
	i, j, k := 0, 0, 0
	for i + 8 <= na && j + 8 <= nb {
		va := intrinsics.unaligned_load((^U32x8)(&pa[i]))
		vb := intrinsics.unaligned_load((^U32x8)(&pb[j]))
		mask := block_match(va, vb)
		if mask != 0 {
			idx := intrinsics.unaligned_load((^I32x8)(&compress_table[mask][0]))
			packed := transmute(U32x8)permd(transmute(I32x8)va, idx)
			found := int(intrinsics.count_ones(mask))
			if k + 8 <= room {
				intrinsics.unaligned_store((^U32x8)(&po[k]), packed)
			} else {
				spill: [8]u32
				intrinsics.unaligned_store((^U32x8)(&spill[0]), packed)
				for t in 0 ..< found {
					po[k + t] = spill[t]
				}
			}
			k += found
		}
		amax := pa[i + 7]
		bmax := pb[j + 7]
		if amax <= bmax {
			i += 8
		}
		if bmax <= amax {
			j += 8
		}
	}
	for i < na && j < nb {
		x, y := pa[i], pb[j]
		if x < y {
			i += 1
		} else if x > y {
			j += 1
		} else {
			po[k] = x
			k += 1
			i += 1
			j += 1
		}
	}
	return k
}

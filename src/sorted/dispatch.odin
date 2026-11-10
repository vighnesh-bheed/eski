package sorted

import "base:intrinsics"

Level :: enum u8 {
	Base,
	Avx2,
}

Intersect_Proc :: #type proc "contextless" (a, b: []u32, out: []u32) -> int

Kernels :: struct {
	intersect: Intersect_Proc,
	level:     Level,
}

kernels: Kernels

cpu_has_avx2 :: proc "contextless" () -> bool {
	when ODIN_ARCH == .amd64 {
		top, _, _, _ := intrinsics.x86_cpuid(0, 0)
		if top < 7 {
			return false
		}
		_, _, ecx1, _ := intrinsics.x86_cpuid(1, 0)
		if ecx1 & (1 << 27) == 0 || ecx1 & (1 << 28) == 0 || ecx1 & (1 << 23) == 0 {
			return false
		}
		xcr0, _ := intrinsics.x86_xgetbv(0)
		if xcr0 & 6 != 6 {
			return false
		}
		_, ebx7, _, _ := intrinsics.x86_cpuid(7, 0)
		return ebx7 & (1 << 5) != 0
	} else {
		return false
	}
}

level_supported :: proc "contextless" (level: Level) -> bool {
	switch level {
	case .Base:
		return true
	case .Avx2:
		return cpu_has_avx2()
	}
	return false
}

best_level :: proc "contextless" () -> Level {
	return .Avx2 if level_supported(.Avx2) else .Base
}

kernels_for :: proc "contextless" (level: Level) -> Kernels {
	k := Kernels{intersect = intersect_merge, level = .Base}
	when ODIN_ARCH == .amd64 {
		if level == .Avx2 {
			k.intersect = intersect_avx2
			k.level = .Avx2
		}
	}
	return k
}

select_level :: proc "contextless" (level: Level) -> bool {
	if !level_supported(level) {
		return false
	}
	kernels = kernels_for(level)
	return true
}

@(init)
init_kernels :: proc "contextless" () {
	when ODIN_ARCH == .amd64 {
		build_compress_table()
	}
	kernels = kernels_for(best_level())
}

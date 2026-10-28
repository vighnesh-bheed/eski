package bitmap

import "base:intrinsics"

Cpu_Level :: enum u8 {
	Generic,
	Popcnt,
	Avx2,
}

cpu_level: Cpu_Level

@(init)
detect_cpu_level :: proc "contextless" () {
	cpu_level = probe_cpu_level()
}

probe_cpu_level :: proc "contextless" () -> Cpu_Level {
	when ODIN_ARCH == .amd64 {
		max_leaf, _, _, _ := intrinsics.x86_cpuid(0, 0)
		if max_leaf < 1 {
			return .Generic
		}
		_, _, ecx1, _ := intrinsics.x86_cpuid(1, 0)
		has_popcnt := ecx1 & (1 << 23) != 0
		if !has_popcnt {
			return .Generic
		}
		has_osxsave := ecx1 & (1 << 27) != 0
		has_avx := ecx1 & (1 << 28) != 0
		if max_leaf < 7 || !has_osxsave || !has_avx {
			return .Popcnt
		}
		xcr0, _ := intrinsics.x86_xgetbv(0)
		if xcr0 & 6 != 6 {
			return .Popcnt
		}
		_, ebx7, _, _ := intrinsics.x86_cpuid(7, 0)
		if ebx7 & (1 << 5) == 0 {
			return .Popcnt
		}
		return .Avx2
	} else {
		return .Generic
	}
}

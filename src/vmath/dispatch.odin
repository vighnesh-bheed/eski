package vmath

import "base:intrinsics"

Level :: enum u8 {
	Base,
	Avx2,
	Avx_Vnni,
	Avx_Vnni_Int8,
}

Cpu :: struct {
	avx:            bool,
	avx2:           bool,
	fma:            bool,
	popcnt:         bool,
	f16c:           bool,
	avx_vnni:       bool,
	avx_vnni_int8:  bool,
	avx_ne_convert: bool,
}

Distance_Proc :: #type proc "contextless" (a: [^]u8, aux_a: f32, b: [^]u8, aux_b: f32, dim: int) -> f32
Score_Proc :: #type proc "contextless" (a: [^]u8, aux_a: f32, b: [^]u8, aux_b: f32, dim: int) -> f64
Batch_Proc :: #type proc "contextless" (a: ^Arena, q: ^Query, slots: []u32, out: []f32)
Dot_F32_Proc :: #type proc "contextless" (a: [^]f32, b: [^]f32, n: int) -> f32
Dot_I8_Proc :: #type proc "contextless" (a: [^]i8, b: [^]i8, n: int) -> i64
Dot_U8_Proc :: #type proc "contextless" (a: [^]u8, b: [^]u8, n: int) -> i64
Hamming_Proc :: #type proc "contextless" (a: [^]u64, b: [^]u64, n: int) -> u64

Kernels :: struct {
	distance:      [Elem][Metric]Distance_Proc,
	score:         [Elem][Metric]Score_Proc,
	batch:         [Elem][Metric]Batch_Proc,
	dot_f32:       Dot_F32_Proc,
	dot_f32_exact: Dot_F32_Proc,
	dot_i8:        Dot_I8_Proc,
	dot_u8:        Dot_U8_Proc,
	hamming:       Hamming_Proc,
	level:         Level,
	family:        Family,
}

Kernel_Set :: [Family]Kernels

kernels: Kernels
search_kernels: Kernels
BASE_KERNELS: Kernels

cpu_detect :: proc "contextless" () -> (cpu: Cpu) {
	when ODIN_ARCH == .amd64 {
		top, _, _, _ := intrinsics.x86_cpuid(0, 0)
		if top < 1 {
			return
		}
		_, _, ecx1, _ := intrinsics.x86_cpuid(1, 0)
		cpu.popcnt = ecx1 & (1 << 23) != 0
		if ecx1 & (1 << 27) == 0 || ecx1 & (1 << 28) == 0 {
			return
		}
		xcr0, _ := intrinsics.x86_xgetbv(0)
		if xcr0 & 6 != 6 {
			return
		}
		cpu.avx = true
		cpu.fma = ecx1 & (1 << 12) != 0
		cpu.f16c = ecx1 & (1 << 29) != 0
		if top >= 7 {
			sub, ebx7, _, _ := intrinsics.x86_cpuid(7, 0)
			cpu.avx2 = ebx7 & (1 << 5) != 0
			if sub >= 1 {
				eax71, _, _, edx71 := intrinsics.x86_cpuid(7, 1)
				cpu.avx_vnni = eax71 & (1 << 4) != 0
				cpu.avx_vnni_int8 = edx71 & (1 << 4) != 0
				cpu.avx_ne_convert = edx71 & (1 << 5) != 0
			}
		}
	}
	return
}

level_supported :: proc "contextless" (level: Level, cpu: Cpu) -> bool {
	when ODIN_ARCH == .amd64 {
		avx2 := cpu.avx2 && cpu.fma && cpu.popcnt && cpu.f16c
		switch level {
		case .Base:
			return true
		case .Avx2:
			return avx2
		case .Avx_Vnni:
			return avx2 && cpu.avx_vnni
		case .Avx_Vnni_Int8:
			return avx2 && cpu.avx_vnni_int8
		}
		return false
	} else {
		return level == .Base
	}
}

best_level :: proc "contextless" (cpu: Cpu) -> Level {
	levels := [?]Level{.Avx_Vnni_Int8, .Avx_Vnni, .Avx2}
	for level in levels {
		if level_supported(level, cpu) {
			return level
		}
	}
	return .Base
}

kernel_set :: proc "contextless" (level: Level) -> (k: Kernel_Set) {
	base_kernels(&k)
	when ODIN_ARCH == .amd64 {
		if level >= .Avx2 {
			avx2_kernels(&k)
		}
		if level == .Avx_Vnni {
			vnni_kernels(&k)
		}
		if level == .Avx_Vnni_Int8 {
			vnni_int8_kernels(&k)
		}
	}
	for family in Family {
		k[family].level = level
		k[family].family = family
	}
	return
}

kernels_for :: proc "contextless" (level: Level, family := Family.Vector_Set) -> Kernels {
	set := kernel_set(level)
	return set[family]
}

family_kernels :: proc "contextless" (family: Family) -> ^Kernels {
	return &search_kernels if family == .Search else &kernels
}

use_level :: proc "contextless" (level: Level) {
	set := kernel_set(level)
	kernels = set[.Vector_Set]
	search_kernels = set[.Search]
}

select_kernels :: proc "contextless" (level: Level) -> bool {
	if !level_supported(level, cpu_detect()) {
		return false
	}
	use_level(level)
	return true
}

@(init)
init_kernels :: proc "contextless" () {
	BASE_KERNELS = kernels_for(.Base)
	use_level(best_level(cpu_detect()))
}

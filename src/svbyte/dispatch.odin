package svbyte

import "base:intrinsics"

Level :: enum u8 {
	Base,
	Ssse3,
}

Decode_Proc :: #type proc "contextless" (data: []u8, out: []u32) -> int

Decode_Delta_Proc :: #type proc "contextless" (data: []u8, out: []u32, previous: u32) -> int

Kernels :: struct {
	decode:       Decode_Proc,
	decode_delta: Decode_Delta_Proc,
	level:        Level,
}

kernels: Kernels

LENGTH: [256]u8

SHUFFLE: [256][16]u8

build_tables :: proc "contextless" () {
	for c in 0 ..< 256 {
		pos := 0
		for lane in 0 ..< 4 {
			length := (c >> uint(2 * lane) & 3) + 1
			for b in 0 ..< 4 {
				if b < length {
					SHUFFLE[c][4 * lane + b] = u8(pos + b)
				} else {
					SHUFFLE[c][4 * lane + b] = 0xFF
				}
			}
			pos += length
		}
		LENGTH[c] = u8(pos)
	}
}

level_supported :: proc "contextless" (level: Level) -> bool {
	switch level {
	case .Base:
		return true
	case .Ssse3:
		when ODIN_ARCH == .amd64 {
			_, _, ecx1, _ := intrinsics.x86_cpuid(1, 0)
			return ecx1 & (1 << 9) != 0
		} else {
			return false
		}
	}
	return false
}

best_level :: proc "contextless" () -> Level {
	return .Ssse3 if level_supported(.Ssse3) else .Base
}

kernels_for :: proc "contextless" (level: Level) -> Kernels {
	k := Kernels{decode = decode_reference, decode_delta = decode_delta_reference, level = .Base}
	when ODIN_ARCH == .amd64 {
		if level == .Ssse3 {
			k = Kernels{decode = decode_ssse3, decode_delta = decode_delta_ssse3, level = .Ssse3}
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
	build_tables()
	kernels = kernels_for(best_level())
}

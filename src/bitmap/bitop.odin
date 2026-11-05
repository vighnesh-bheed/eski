package bitmap

import "base:intrinsics"

Bitop :: enum u8 {
	And,
	Or,
	Xor,
	Not,
}

BITOP_CHUNK :: 16 * 1024

parse_bitop :: proc "contextless" (name: []u8) -> (op: Bitop, err: Error) {
	word := c_string(name)
	switch {
	case equal_fold(word, "and"):
		return .And, .None
	case equal_fold(word, "or"):
		return .Or, .None
	case equal_fold(word, "xor"):
		return .Xor, .None
	case equal_fold(word, "not"):
		return .Not, .None
	}
	return .And, .Syntax
}

check_bitop_arity :: proc "contextless" (op: Bitop, nsrc: int) -> Error {
	if op == .Not && nsrc != 1 {
		return .Bitop_Not_Arity
	}
	if nsrc < 1 {
		return .Syntax
	}
	return .None
}

bitop :: proc(op: Bitop, srcs: [][]u8, dst: ^[]u8, allocator := RAW_HEAP_ALLOCATOR) -> (length: int, err: Error) #no_bounds_check {
	if op == .Not && len(srcs) != 1 {
		return 0, .Bitop_Not_Arity
	}
	longest := 0
	for s in srcs {
		longest = max(longest, len(s))
	}
	if longest == 0 {
		dst^ = nil
		return 0, .None
	}
	mem, alloc_err := allocator.procedure(allocator.data, .Alloc_Non_Zeroed, longest, 16, nil, 0)
	if alloc_err != nil || raw_data(mem) == nil {
		return 0, .Out_Of_Memory
	}
	out := raw_data(mem)
	when ODIN_ARCH == .amd64 {
		if cpu_level == .Avx2 {
			bitop_run_avx2(op, srcs, out, longest)
		} else {
			bitop_run_base(op, srcs, out, longest)
		}
	} else {
		bitop_run_base(op, srcs, out, longest)
	}
	dst^ = out[:longest]
	return longest, .None
}

when ODIN_ARCH == .amd64 {
	@(enable_target_feature = "avx2")
	bitop_run_avx2 :: proc "contextless" (op: Bitop, srcs: [][]u8, out: [^]u8, n: int) {
		bitop_run_body(op, srcs, out, n)
	}
}

bitop_run_base :: proc "contextless" (op: Bitop, srcs: [][]u8, out: [^]u8, n: int) {
	bitop_run_body(op, srcs, out, n)
}

bitop_run_body :: #force_inline proc "contextless" (op: Bitop, srcs: [][]u8, out: [^]u8, n: int) #no_bounds_check {
	for base := 0; base < n; base += BITOP_CHUNK {
		m := min(BITOP_CHUNK, n - base)
		o := out[base:]
		first := srcs[0]
		take := clamp(len(first) - base, 0, m)
		if op == .Not {
			bytes_not(o, raw_data(first)[base:], take)
		} else {
			if take > 0 {
				intrinsics.mem_copy_non_overlapping(o, raw_data(first)[base:], take)
			}
		}
		if take < m {
			intrinsics.mem_zero(o[take:], m - take)
		}
		if op == .Not {
			continue
		}
		for s in srcs[1:] {
			take = clamp(len(s) - base, 0, m)
			src := raw_data(s)[base:]
			switch op {
			case .And:
				bytes_and(o, src, take)
				if take < m {
					intrinsics.mem_zero(o[take:], m - take)
				}
			case .Or:
				bytes_or(o, src, take)
			case .Xor:
				bytes_xor(o, src, take)
			case .Not:
			}
		}
	}
}

bytes_not :: #force_inline proc "contextless" (o, s: [^]u8, k: int) #no_bounds_check {
	for i in 0 ..< k {
		o[i] = ~s[i]
	}
}

bytes_and :: #force_inline proc "contextless" (o, s: [^]u8, k: int) #no_bounds_check {
	for i in 0 ..< k {
		o[i] &= s[i]
	}
}

bytes_or :: #force_inline proc "contextless" (o, s: [^]u8, k: int) #no_bounds_check {
	for i in 0 ..< k {
		o[i] |= s[i]
	}
}

bytes_xor :: #force_inline proc "contextless" (o, s: [^]u8, k: int) #no_bounds_check {
	for i in 0 ..< k {
		o[i] ~= s[i]
	}
}

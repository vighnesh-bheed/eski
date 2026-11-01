package rdb

import "base:intrinsics"
import "base:runtime"

LZF_HLOG :: 16
LZF_HSIZE :: 1 << LZF_HLOG
LZF_MAX_LIT :: 1 << 5
LZF_MAX_OFF :: 1 << 13
LZF_MAX_REF :: (1 << 8) + (1 << 3)
LZF_MAX_INPUT :: 1 << 31

LZF_CONTEXT_BYTES :: LZF_HSIZE * size_of(u32)

Lzf_Context :: struct {
	table: [^]u32,
	base: u32,
}

lzf_context_init :: proc "contextless" (ctx: ^Lzf_Context) {
	if ctx.table == nil {
		ctx.table = ([^]u32)(runtime.heap_alloc(LZF_CONTEXT_BYTES, true))
		if ctx.table == nil { runtime.panic_contextless("rdb: out of memory") }
	} else {
		intrinsics.mem_zero(ctx.table, LZF_CONTEXT_BYTES)
	}
	ctx.base = 0
}

lzf_context_destroy :: proc "contextless" (ctx: ^Lzf_Context) {
	if ctx.table != nil { runtime.heap_free(ctx.table) }
	ctx^ = {}
}

@(private)
lzf_idx :: #force_inline proc "contextless" (h: u32) -> u32 {
	return ((h >> (3 * 8 - LZF_HLOG)) - h * 5) & (LZF_HSIZE - 1)
}

@(private)
lzf_table :: proc "contextless" (ctx: ^Lzf_Context, in_len: int) -> (htab: [^]u32, base: u32) {
	if ctx.table == nil { lzf_context_init(ctx) }
	if u64(ctx.base) + u64(in_len) + 1 >= 1 << 32 {
		intrinsics.mem_zero(ctx.table, LZF_CONTEXT_BYTES)
		ctx.base = 0
	}
	base = ctx.base
	ctx.base += u32(in_len)
	return ctx.table, base
}

lzf_compress :: proc "contextless" (input: []u8, output: []u8) -> int {
	ctx: Lzf_Context
	defer lzf_context_destroy(&ctx)
	return lzf_compress_with_context(&ctx, input, output)
}

lzf_compress_with_context :: proc "contextless" (ctx: ^Lzf_Context, input: []u8, output: []u8) -> int #no_bounds_check {
	in_len := len(input)
	out_len := len(output)
	if in_len == 0 || out_len == 0 || in_len < 3 || in_len >= LZF_MAX_INPUT {
		return 0
	}
	htab, base := lzf_table(ctx, in_len)
	src := raw_data(input)
	dst := raw_data(output)
	ip := 0
	op := 0
	in_end := in_len
	out_end := out_len
	lit := 0
	op += 1
	hval := (u32(src[0]) << 8) | u32(src[1])
	for ip < in_end - 2 {
		hval = (hval << 8) | u32(src[ip + 2])
		slot := &htab[lzf_idx(hval)]
		stored := slot^
		slot^ = base + u32(ip)
		ref := 0
		if stored > base {
			ref = int(stored - base)
		}
		off := ip - ref - 1
		if ref > 0 && off < LZF_MAX_OFF && src[ref + 2] == src[ip + 2] && src[ref] == src[ip] && src[ref + 1] == src[ip + 1] {
			mlen := 2
			maxlen := in_end - ip - mlen
			if maxlen > LZF_MAX_REF {
				maxlen = LZF_MAX_REF
			}
			if op + 3 + 1 >= out_end {
				if op - (1 if lit == 0 else 0) + 3 + 1 >= out_end {
					return 0
				}
			}
			dst[op - lit - 1] = u8(lit - 1)
			if lit == 0 {
				op -= 1
			}
			stopped := false
			if maxlen > 16 {
				for _ in 0 ..< 16 {
					mlen += 1
					if src[ref + mlen] != src[ip + mlen] {
						stopped = true
						break
					}
				}
			}
			if !stopped {
				mlen += 1
				for mlen < maxlen && src[ref + mlen] == src[ip + mlen] {
					mlen += 1
				}
			}
			mlen -= 2
			ip += 1
			if mlen < 7 {
				dst[op] = u8((off >> 8) + (mlen << 5))
				op += 1
			} else {
				dst[op] = u8((off >> 8) + (7 << 5))
				op += 1
				dst[op] = u8(mlen - 7)
				op += 1
			}
			dst[op] = u8(off)
			op += 1
			lit = 0
			op += 1
			ip += mlen + 1
			if ip >= in_end - 2 {
				break
			}
			ip -= 2
			hval = (u32(src[ip]) << 8) | u32(src[ip + 1])
			hval = (hval << 8) | u32(src[ip + 2])
			htab[lzf_idx(hval)] = base + u32(ip)
			ip += 1
			hval = (hval << 8) | u32(src[ip + 2])
			htab[lzf_idx(hval)] = base + u32(ip)
			ip += 1
		} else {
			if op >= out_end {
				return 0
			}
			lit += 1
			dst[op] = src[ip]
			op += 1
			ip += 1
			if lit == LZF_MAX_LIT {
				dst[op - lit - 1] = u8(lit - 1)
				lit = 0
				op += 1
			}
		}
	}
	if op + 3 > out_end {
		return 0
	}
	for ip < in_end {
		lit += 1
		dst[op] = src[ip]
		op += 1
		ip += 1
		if lit == LZF_MAX_LIT {
			dst[op - lit - 1] = u8(lit - 1)
			lit = 0
			op += 1
		}
	}
	dst[op - lit - 1] = u8(lit - 1)
	if lit == 0 {
		op -= 1
	}
	return op
}

lzf_decompress :: proc "contextless" (input: []u8, output: []u8) -> int #no_bounds_check {
	src := raw_data(input)
	dst := raw_data(output)
	ip := 0
	op := 0
	in_end := len(input)
	out_end := len(output)
	for ip < in_end {
		ctrl := int(src[ip])
		ip += 1
		if ctrl < 1 << 5 {
			ctrl += 1
			if op + ctrl > out_end {
				return 0
			}
			if ip + ctrl > in_end {
				return 0
			}
			intrinsics.mem_copy_non_overlapping(&dst[op], &src[ip], ctrl)
			op += ctrl
			ip += ctrl
		} else {
			n := ctrl >> 5
			ref := op - ((ctrl & 0x1f) << 8) - 1
			if ip >= in_end {
				return 0
			}
			if n == 7 {
				n += int(src[ip])
				ip += 1
				if ip >= in_end {
					return 0
				}
			}
			ref -= int(src[ip])
			ip += 1
			if op + n + 2 > out_end {
				return 0
			}
			if ref < 0 {
				return 0
			}
			n += 2
			if op >= ref + n {
				intrinsics.mem_copy_non_overlapping(&dst[op], &dst[ref], n)
				op += n
			} else {
				for _ in 0 ..< n {
					dst[op] = dst[ref]
					op += 1
					ref += 1
				}
			}
		}
	}
	return op
}

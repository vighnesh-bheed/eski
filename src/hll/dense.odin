package hll

HLL_DENSE_REG_BYTES :: HLL_DENSE_SIZE - HLL_HDR_SIZE

dense_get :: #force_inline proc "contextless" (regs: []u8, index: int) -> u8 #no_bounds_check {
	bit := index * HLL_BITS
	at := bit >> 3
	tail := (at + 1) / HLL_DENSE_REG_BYTES
	at -= tail
	shift := uint(bit & 7) + uint(tail) * 8
	word := u16(regs[at]) | u16(regs[at + 1]) << 8
	return u8(word >> shift) & HLL_REGISTER_MAX
}

dense_put :: #force_inline proc "contextless" (regs: []u8, index: int, val: u8) #no_bounds_check {
	bit := index * HLL_BITS
	at := bit >> 3
	tail := (at + 1) / HLL_DENSE_REG_BYTES
	at -= tail
	shift := uint(bit & 7) + uint(tail) * 8
	word := u16(regs[at]) | u16(regs[at + 1]) << 8
	word = (word &~ (u16(HLL_REGISTER_MAX) << shift)) | (u16(val & HLL_REGISTER_MAX) << shift)
	regs[at] = u8(word)
	regs[at + 1] = u8(word >> 8)
}

dense_set :: #force_inline proc "contextless" (regs: []u8, index: int, count: u8) -> bool {
	if dense_get(regs, index) < count {
		dense_put(regs, index, count)
		return true
	}
	return false
}

dense_add :: proc "contextless" (regs: []u8, elem: []u8) -> bool {
	index, count := hll_pat_len(elem)
	return dense_set(regs, index, count)
}

dense_reg_histo :: proc "contextless" (regs: []u8, reghisto: ^[64]int) #no_bounds_check {
	for at := 0; at < HLL_DENSE_REG_BYTES; at += 3 {
		b0, b1, b2 := regs[at], regs[at + 1], regs[at + 2]
		reghisto[b0 & 63] += 1
		reghisto[(b0 >> 6) | ((b1 & 15) << 2)] += 1
		reghisto[(b1 >> 4) | ((b2 & 3) << 4)] += 1
		reghisto[b2 >> 2] += 1
	}
}

raw_reg_histo :: proc "contextless" (regs: ^[HLL_REGISTERS]u8, reghisto: ^[64]int) #no_bounds_check {
	for value in regs {
		reghisto[value & 63] += 1
	}
}

dense_decode_into :: proc "contextless" (regs: []u8, out: []u8, max_mode: bool) #no_bounds_check {
	index := 0
	for at := 0; at < HLL_DENSE_REG_BYTES; at += 3 {
		b0, b1, b2 := regs[at], regs[at + 1], regs[at + 2]
		r0 := b0 & 63
		r1 := (b0 >> 6) | ((b1 & 15) << 2)
		r2 := (b1 >> 4) | ((b2 & 3) << 4)
		r3 := b2 >> 2
		if max_mode {
			out[index] = max(out[index], r0)
			out[index + 1] = max(out[index + 1], r1)
			out[index + 2] = max(out[index + 2], r2)
			out[index + 3] = max(out[index + 3], r3)
		} else {
			out[index] = r0
			out[index + 1] = r1
			out[index + 2] = r2
			out[index + 3] = r3
		}
		index += 4
	}
}

dense_encode_from :: proc "contextless" (regs: []u8, src: []u8) #no_bounds_check {
	index := 0
	for at := 0; at < HLL_DENSE_REG_BYTES; at += 3 {
		r0 := src[index] & 63
		r1 := src[index + 1] & 63
		r2 := src[index + 2] & 63
		r3 := src[index + 3] & 63
		regs[at] = r0 | (r1 << 6)
		regs[at + 1] = (r1 >> 2) | (r2 << 4)
		regs[at + 2] = (r2 >> 4) | (r3 << 2)
		index += 4
	}
}

dense_merge_registers :: proc "contextless" (regs: []u8, max_regs: ^[HLL_REGISTERS]u8) #no_bounds_check {
	index := 0
	for at := 0; at < HLL_DENSE_REG_BYTES; at += 3 {
		b0, b1, b2 := regs[at], regs[at + 1], regs[at + 2]
		r0 := max(b0 & 63, max_regs[index] & 63)
		r1 := max((b0 >> 6) | ((b1 & 15) << 2), max_regs[index + 1] & 63)
		r2 := max((b1 >> 4) | ((b2 & 3) << 4), max_regs[index + 2] & 63)
		r3 := max(b2 >> 2, max_regs[index + 3] & 63)
		regs[at] = r0 | (r1 << 6)
		regs[at + 1] = (r1 >> 2) | (r2 << 4)
		regs[at + 2] = (r2 >> 4) | (r3 << 2)
		index += 4
	}
}

package ldfloat

import "base:intrinsics"

BIG_LIMBS :: 1024

Big :: struct {
	n: int,
	d: [BIG_LIMBS]u32,
}

big_set_u64 :: proc "contextless" (b: ^Big, v: u64) {
	b.d[0] = u32(v)
	b.d[1] = u32(v >> 32)
	b.n = 2 if b.d[1] != 0 else (1 if b.d[0] != 0 else 0)
}

big_is_zero :: #force_inline proc "contextless" (b: ^Big) -> bool {
	return b.n == 0
}

big_trim :: #force_inline proc "contextless" (b: ^Big) {
	for b.n > 0 && b.d[b.n - 1] == 0 {
		b.n -= 1
	}
}

big_mul_small :: proc "contextless" (b: ^Big, m: u32) {
	carry: u64 = 0
	for i in 0 ..< b.n {
		t := u64(b.d[i]) * u64(m) + carry
		b.d[i] = u32(t)
		carry = t >> 32
	}
	if carry != 0 {
		b.d[b.n] = u32(carry)
		b.n += 1
	}
	big_trim(b)
}

big_add_small :: proc "contextless" (b: ^Big, a: u32) {
	carry := u64(a)
	i := 0
	for carry != 0 {
		if i == b.n {
			b.d[i] = 0
			b.n += 1
		}
		t := u64(b.d[i]) + carry
		b.d[i] = u32(t)
		carry = t >> 32
		i += 1
	}
}

big_bitlen :: proc "contextless" (b: ^Big) -> int {
	if b.n == 0 {
		return 0
	}
	return (b.n - 1) * 32 + (32 - int(intrinsics.count_leading_zeros(b.d[b.n - 1])))
}

big_shl :: proc "contextless" (b: ^Big, bits: int) {
	if b.n == 0 || bits == 0 {
		return
	}
	limbs := bits / 32
	r := uint(bits % 32)
	if r == 0 {
		for i := b.n - 1; i >= 0; i -= 1 {
			b.d[i + limbs] = b.d[i]
		}
		b.n += limbs
	} else {
		b.d[b.n + limbs] = 0
		for i := b.n - 1; i >= 0; i -= 1 {
			v := b.d[i]
			b.d[i + limbs + 1] |= v >> (32 - r)
			b.d[i + limbs] = v << r
		}
		b.n += limbs + 1
	}
	for i in 0 ..< limbs {
		b.d[i] = 0
	}
	big_trim(b)
}

big_shr1 :: proc "contextless" (b: ^Big) {
	for i in 0 ..< b.n {
		hi: u32 = b.d[i + 1] if i + 1 < b.n else 0
		b.d[i] = (b.d[i] >> 1) | (hi << 31)
	}
	big_trim(b)
}

big_cmp :: proc "contextless" (a, b: ^Big) -> int {
	if a.n != b.n {
		return 1 if a.n > b.n else -1
	}
	for i := a.n - 1; i >= 0; i -= 1 {
		if a.d[i] != b.d[i] {
			return 1 if a.d[i] > b.d[i] else -1
		}
	}
	return 0
}

big_sub :: proc "contextless" (a, b: ^Big) {
	borrow: i64 = 0
	for i in 0 ..< a.n {
		bv: i64 = i64(b.d[i]) if i < b.n else 0
		t := i64(a.d[i]) - bv - borrow
		if t < 0 {
			t += 1 << 32
			borrow = 1
		} else {
			borrow = 0
		}
		a.d[i] = u32(t)
	}
	big_trim(a)
}

big_copy :: proc "contextless" (dst, src: ^Big) {
	dst.n = src.n
	for i in 0 ..< src.n {
		dst.d[i] = src.d[i]
	}
}

big_mul_pow5 :: proc "contextless" (b: ^Big, n: int) {
	n := n
	for n >= 13 {
		big_mul_small(b, 1220703125)
		n -= 13
	}
	p: u32 = 1
	for _ in 0 ..< n {
		p *= 5
	}
	if p != 1 {
		big_mul_small(b, p)
	}
}

big_divmod_small :: proc "contextless" (b: ^Big, d: u32) -> u32 {
	rem: u64 = 0
	for i := b.n - 1; i >= 0; i -= 1 {
		t := (rem << 32) | u64(b.d[i])
		b.d[i] = u32(t / u64(d))
		rem = t % u64(d)
	}
	big_trim(b)
	return u32(rem)
}

big_top128 :: proc "contextless" (b: ^Big) -> (top: u128, shifted: int, sticky: bool) {
	bl := big_bitlen(b)
	if bl <= 128 {
		for i := b.n - 1; i >= 0; i -= 1 {
			top = (top << 32) | u128(b.d[i])
		}
		return top, 0, false
	}
	shifted = bl - 128
	for k in 0 ..< 128 {
		bit := shifted + 127 - k
		v := (b.d[bit / 32] >> uint(bit % 32)) & 1
		top = (top << 1) | u128(v)
	}
	full := shifted / 32
	for i in 0 ..< full {
		if b.d[i] != 0 {
			sticky = true
			break
		}
	}
	r := uint(shifted % 32)
	if !sticky && r != 0 && (b.d[full] & ((u32(1) << r) - 1)) != 0 {
		sticky = true
	}
	return top, shifted, sticky
}

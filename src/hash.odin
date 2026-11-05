package main

import "base:intrinsics"

WY_P0 :: u64(0x2d358dccaa6c78a5)
WY_P1 :: u64(0x8bb84b93962eacc9)
WY_P2 :: u64(0x4b33a62ed433d4a3)
WY_P3 :: u64(0x4d5a2da51de1aa47)

hash_seed: u64

@(private = "file")
wy_mum :: #force_inline proc "contextless" (a, b: u64) -> (u64, u64) {
	r := u128(a) * u128(b)
	return u64(r), u64(r >> 64)
}

@(private = "file")
wy_mix :: #force_inline proc "contextless" (a, b: u64) -> u64 {
	lo, hi := wy_mum(a, b)
	return lo ~ hi
}

@(private = "file")
wy_r8 :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	return intrinsics.unaligned_load((^u64)(p))
}

@(private = "file")
wy_r4 :: #force_inline proc "contextless" (p: [^]u8) -> u64 {
	return u64(intrinsics.unaligned_load((^u32)(p)))
}

hash_init :: proc "contextless" (seed: u64) {
	hash_seed = seed ~ wy_mix(seed ~ WY_P0, WY_P1)
}

hash_bytes :: proc "contextless" (key: []u8) -> u64 #no_bounds_check {
	p := raw_data(key)
	n := len(key)
	seed := hash_seed
	a, b: u64
	if n <= 16 {
		if n >= 4 {
			q := (n >> 3) << 2
			a = (wy_r4(p) << 32) | wy_r4(p[q:])
			b = (wy_r4(p[n - 4:]) << 32) | wy_r4(p[n - 4 - q:])
		} else if n > 0 {
			a = (u64(p[0]) << 16) | (u64(p[n >> 1]) << 8) | u64(p[n - 1])
		}
	} else {
		i := n
		if i > 48 {
			see1, see2 := seed, seed
			for i > 48 {
				seed = wy_mix(wy_r8(p) ~ WY_P1, wy_r8(p[8:]) ~ seed)
				see1 = wy_mix(wy_r8(p[16:]) ~ WY_P2, wy_r8(p[24:]) ~ see1)
				see2 = wy_mix(wy_r8(p[32:]) ~ WY_P3, wy_r8(p[40:]) ~ see2)
				p = p[48:]
				i -= 48
			}
			seed ~= see1 ~ see2
		}
		for i > 16 {
			seed = wy_mix(wy_r8(p) ~ WY_P1, wy_r8(p[8:]) ~ seed)
			i -= 16
			p = p[16:]
		}
		a = wy_r8(p[i - 16:])
		b = wy_r8(p[i - 8:])
	}
	a ~= WY_P1
	b ~= seed
	a, b = wy_mum(a, b)
	return wy_mix(a ~ WY_P0 ~ u64(n), b ~ WY_P1)
}

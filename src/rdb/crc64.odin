package rdb

import "base:intrinsics"

CRC64_POLY :: u64(0xad93d23594c935a9)

@(private)
crc64_table: [8][256]u64
@(private)
crc64_ready: bool

@(private)
crc64_reflect :: proc "contextless" (data: u64, data_len: int) -> u64 {
	d := data
	ret := d & 0x01
	for _ in 1 ..< data_len {
		d >>= 1
		ret = (ret << 1) | (d & 0x01)
	}
	return ret
}

crc64_bitwise :: proc "contextless" (start: u64, data: []u8) -> u64 {
	crc := start
	for c in data {
		i: u32 = 0x01
		for i & 0xff != 0 {
			bit := crc & 0x8000000000000000 != 0
			if u32(c) & i != 0 {
				bit = !bit
			}
			crc <<= 1
			if bit {
				crc ~= CRC64_POLY
			}
			i <<= 1
		}
	}
	return crc64_reflect(crc, 64)
}

crc64_init :: proc "contextless" () {
	if crc64_ready {
		return
	}
	for n in 0 ..< 256 {
		v := [1]u8{u8(n)}
		crc64_table[0][n] = crc64_bitwise(0, v[:])
	}
	for n in 0 ..< 256 {
		crc := crc64_table[0][n]
		for k in 1 ..< 8 {
			crc = crc64_table[0][crc & 0xff] ~ (crc >> 8)
			crc64_table[k][n] = crc
		}
	}
	crc64_ready = true
}

crc64 :: proc "contextless" (start: u64, data: []u8) -> u64 #no_bounds_check {
	if !crc64_ready {
		crc64_init()
	}
	crc := start
	p := raw_data(data)
	n := len(data)
	i := 0
	for i < n && (uintptr(p) + uintptr(i)) & 7 != 0 {
		crc = crc64_table[0][(crc ~ u64(p[i])) & 0xff] ~ (crc >> 8)
		i += 1
	}
	for n - i >= 8 {
		crc ~= intrinsics.unaligned_load((^u64)(&p[i]))
		crc =
			crc64_table[7][crc & 0xff] ~
			crc64_table[6][(crc >> 8) & 0xff] ~
			crc64_table[5][(crc >> 16) & 0xff] ~
			crc64_table[4][(crc >> 24) & 0xff] ~
			crc64_table[3][(crc >> 32) & 0xff] ~
			crc64_table[2][(crc >> 40) & 0xff] ~
			crc64_table[1][(crc >> 48) & 0xff] ~
			crc64_table[0][crc >> 56]
		i += 8
	}
	for i < n {
		crc = crc64_table[0][(crc ~ u64(p[i])) & 0xff] ~ (crc >> 8)
		i += 1
	}
	return crc
}

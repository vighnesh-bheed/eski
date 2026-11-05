package main

import "./glob"
import "./integer"

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "sysclock"

I64_MAX :: max(i64)
I64_MIN :: min(i64)

lower :: #force_inline proc "contextless" (b: u8) -> u8 {
	return b + 32 if b >= 'A' && b <= 'Z' else b
}

eq_nocase :: proc "contextless" (a: []u8, b: string) -> bool #no_bounds_check {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if lower(a[i]) != b[i] {
			return false
		}
	}
	return true
}

bytes_eq :: proc "contextless" (a: []u8, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	if len(a) == 0 {
		return true
	}
	return runtime.memory_equal(raw_data(a), raw_data(b), len(a))
}

parse_i64 :: #force_inline proc "contextless" (s: []u8) -> (i64, bool) {
	return integer.parse_i64(s)
}

format_i64 :: proc "contextless" (dst: [^]u8, v: i64) -> int #no_bounds_check {
	tmp: [20]u8
	u: u64
	neg := v < 0
	if neg {
		u = 0 - cast(u64)v
	} else {
		u = u64(v)
	}
	i := 20
	for {
		i -= 1
		tmp[i] = u8('0' + u % 10)
		u /= 10
		if u == 0 {
			break
		}
	}
	n := 0
	if neg {
		dst[0] = '-'
		n = 1
	}
	l := 20 - i
	intrinsics.mem_copy_non_overlapping(&dst[n], &tmp[i], l)
	return n + l
}

sb_str :: proc(b: ^[dynamic]u8, s: string) {
	append(b, s)
}

sb_bytes :: proc(b: ^[dynamic]u8, s: []u8) {
	append(b, ..s)
}

sb_byte :: proc(b: ^[dynamic]u8, c: u8) {
	append(b, c)
}

sb_int :: proc(b: ^[dynamic]u8, v: i64) {
	tmp: [24]u8
	n := format_i64(&tmp[0], v)
	append(b, ..tmp[:n])
}

sb_fixed2 :: proc(b: ^[dynamic]u8, hundredths: i64) {
	sb_int(b, hundredths / 100)
	sb_byte(b, '.')
	r := hundredths % 100
	sb_byte(b, u8('0' + r / 10))
	sb_byte(b, u8('0' + r % 10))
}

glob_match :: #force_inline proc "contextless" (pat: []u8, str: []u8, nocase: bool) -> bool {
	return glob.glob_match(pat, str, nocase)
}

parse_ipv4 :: proc(s: string) -> (addr: [4]u8, ok: bool) {
	if s == "localhost" {
		return {127, 0, 0, 1}, true
	}
	if s == "*" {
		return {0, 0, 0, 0}, true
	}
	part := 0
	val := 0
	digits := 0
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch >= '0' && ch <= '9' {
			val = val * 10 + int(ch - '0')
			digits += 1
			if val > 255 || digits > 3 {
				return
			}
		} else if ch == '.' {
			if digits == 0 || part >= 3 {
				return
			}
			addr[part] = u8(val)
			part += 1
			val = 0
			digits = 0
		} else {
			return
		}
	}
	if digits == 0 || part != 3 {
		return
	}
	addr[3] = u8(val)
	ok = true
	return
}

write_fd :: proc(fd: linux.Fd, s: string) {
	b := transmute([]u8)s
	for len(b) > 0 {
		n, err := linux.write(fd, b)
		if err == .EINTR {
			continue
		}
		if err != .NONE || n <= 0 {
			return
		}
		b = b[n:]
	}
}

now_realtime :: proc() -> (sec: i64, usec: i64) {
	ts, _ := sysclock.realtime()
	return i64(ts.time_sec), i64(ts.time_nsec) / 1000
}

rng_state: u64 = 0x9E3779B97F4A7C15

rng_next :: proc "contextless" () -> u64 {
	x := rng_state
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	rng_state = x
	return x
}

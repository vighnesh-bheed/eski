package main

import "base:intrinsics"
import "core:sys/linux"
import "sysclock"

mono_ticks_per_us: u64 = 1000
mono_mul: u64 = ((u64(1) << 32) + 999) / 1000
mono_info: string = "POSIX clock_gettime"

@(private = "file")
mono_info_buf: [40]u8

mono_init :: proc() {
	when ODIN_ARCH == .amd64 {
		ticks := mono_cpuinfo_ticks()
		if ticks == 0 {
			ticks = mono_calibrate()
		}
		mono_ticks_per_us = ticks
		b: [dynamic]u8
		defer delete(b)
		sb_str(&b, "X86 TSC @ ")
		sb_int(&b, i64(ticks))
		sb_str(&b, " ticks/us")
		n := copy(mono_info_buf[:], b[:])
		mono_info = string(mono_info_buf[:n])
	}
	mono_mul = ((u64(1) << 32) + mono_ticks_per_us - 1) / mono_ticks_per_us
}

@(private = "file")
mono_line_after_colon :: proc(line: []u8) -> []u8 {
	for b, i in line {
		if b == ':' {
			return line[i + 1:]
		}
	}
	return nil
}

@(private = "file")
mono_starts :: proc(line: []u8, prefix: string) -> bool {
	return len(line) >= len(prefix) && string(line[:len(prefix)]) == prefix
}

@(private = "file")
mono_ghz :: proc(line: []u8) -> u64 {
	rest := mono_line_after_colon(line)
	at := -1
	for i in 0 ..< len(rest) {
		if rest[i] == '@' && i + 1 < len(rest) && rest[i + 1] == ' ' {
			at = i + 2
		}
	}
	if at < 0 {
		return 0
	}
	whole: u64 = 0
	frac: u64 = 0
	scale: u64 = 1
	i := at
	digits := 0
	for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
		whole = whole * 10 + u64(rest[i] - '0')
		i += 1
		digits += 1
	}
	if i < len(rest) && rest[i] == '.' {
		i += 1
		for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
			if scale < 1_000_000 {
				frac = frac * 10 + u64(rest[i] - '0')
				scale *= 10
			}
			i += 1
			digits += 1
		}
	}
	if digits == 0 || i + 3 > len(rest) || string(rest[i:i + 3]) != "GHz" {
		return 0
	}
	return whole * 1000 + frac * 1000 / scale
}

@(private = "file")
mono_has_constant_tsc :: proc(line: []u8) -> bool {
	rest := mono_line_after_colon(line)
	word := " constant_tsc"
	for i in 0 ..< len(rest) {
		if i + len(word) <= len(rest) && string(rest[i:i + len(word)]) == word {
			return true
		}
	}
	return false
}

@(private = "file")
mono_cpuinfo_ticks :: proc() -> u64 {
	fd, err := linux.open("/proc/cpuinfo", {})
	if err != .NONE {
		return 0
	}
	defer linux.close(fd)
	data := make([dynamic]u8, 0, 16384)
	defer delete(data)
	buf: [8192]u8
	for {
		n, rerr := linux.read(fd, buf[:])
		if rerr == .EINTR {
			continue
		}
		if rerr != .NONE || n <= 0 {
			break
		}
		append(&data, ..buf[:n])
	}
	ticks: u64 = 0
	constant := false
	start := 0
	for start < len(data) {
		end := start
		for end < len(data) && data[end] != '\n' {
			end += 1
		}
		line := data[start:end]
		start = end + 1
		if ticks == 0 {
			if mono_starts(line, "model name") {
				ticks = mono_ghz(line)
			}
			continue
		}
		if mono_starts(line, "flags") && mono_has_constant_tsc(line) {
			constant = true
			break
		}
	}
	return ticks if constant else 0
}

@(private = "file")
mono_calibrate :: proc() -> u64 {
	n0 := mono_posix_ns()
	t0 := u64(intrinsics.read_cycle_counter())
	ts := linux.Time_Spec {
		time_nsec = 10_000_000,
	}
	for linux.nanosleep(&ts, &ts) == .EINTR {
	}
	t1 := u64(intrinsics.read_cycle_counter())
	n1 := mono_posix_ns()
	if n1 <= n0 {
		return 1000
	}
	return max((t1 - t0) * 1000 / (n1 - n0), 1)
}

@(cold)
mono_posix_ns :: #force_no_inline proc "contextless" () -> u64 {
	ts, _ := sysclock.monotonic()
	return u64(ts.time_sec) * 1_000_000_000 + u64(ts.time_nsec)
}

mono_now :: #force_inline proc "contextless" () -> u64 {
	when ODIN_ARCH == .amd64 {
		return u64(intrinsics.read_cycle_counter())
	} else {
		return mono_posix_ns()
	}
}

mono_ticks_us :: #force_inline proc "contextless" (ticks: u64) -> u64 {
	return u64((u128(ticks) * u128(mono_mul)) >> 32)
}

mono_us :: #force_inline proc "contextless" () -> u64 {
	return mono_ticks_us(mono_now())
}

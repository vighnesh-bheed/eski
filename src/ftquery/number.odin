package ftquery

import "core:c"
import "core:c/libc"
import "core:math"
import "core:strings"

NUMBER_TEXT_MAX :: 512

f64_inf :: proc "contextless" () -> f64 {
	return math.inf_f64(1)
}

c_buffer :: proc(text: string, buf: []u8) -> (cstring, bool) {
	if len(text) + 1 > len(buf) {
		return nil, false
	}
	copy(buf, text)
	buf[len(text)] = 0
	return cstring(raw_data(buf)), true
}

parse_number_text :: proc(text: string) -> f64 {
	buf: [NUMBER_TEXT_MAX]u8
	cs, ok := c_buffer(text, buf[:])
	if !ok {
		return 0
	}
	return f64(libc.strtod(cs, nil))
}

parse_full_double :: proc(text: string) -> (value: f64, ok: bool) {
	if len(text) == 0 {
		return 0, false
	}
	buf: [NUMBER_TEXT_MAX]u8
	cs, fits := c_buffer(text, buf[:])
	if !fits {
		return 0, false
	}
	end: [^]c.char
	v := libc.strtod(cs, &end)
	consumed := int(uintptr(rawptr(end)) - uintptr(rawptr(cs)))
	if consumed != len(text) {
		return 0, false
	}
	return f64(v), true
}

parse_full_int :: proc(text: string) -> (value: i64, ok: bool) {
	if len(text) == 0 {
		return 0, false
	}
	buf: [NUMBER_TEXT_MAX]u8
	cs, fits := c_buffer(text, buf[:])
	if !fits {
		return 0, false
	}
	end: [^]c.char
	v := libc.strtoll(cs, &end, 10)
	consumed := int(uintptr(rawptr(end)) - uintptr(rawptr(cs)))
	if consumed != len(text) {
		return 0, false
	}
	return i64(v), true
}

parse_unsigned :: proc(text: string) -> u64 {
	v: u64
	for i in 0 ..< len(text) {
		d := u64(text[i] - '0')
		if v > (max(u64) - d) / 10 {
			return max(u64)
		}
		v = v * 10 + d
	}
	return v
}

write_c_format :: proc(b: ^strings.Builder, format: cstring, value: f64) {
	buf: [512]u8
	n := libc.snprintf(raw_data(buf[:]), len(buf), format, value)
	if n < 0 {
		return
	}
	strings.write_string(b, string(buf[:min(int(n), len(buf) - 1)]))
}

write_c_fixed :: proc(b: ^strings.Builder, value: f64) {
	write_c_format(b, "%f", value)
}

write_c_general :: proc(b: ^strings.Builder, value: f64) {
	write_c_format(b, "%g", value)
}

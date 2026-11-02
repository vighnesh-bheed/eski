package listpack

import "core:mem"
import "base:intrinsics"
import integer "../integer"

entry_from_bytes :: proc "contextless" (s: []u8) -> Element {
	if u64(len(s)) > u64(max(u32)) {
		intrinsics.trap()
	}
	selector := raw_data(s)
	if selector == nil {
		selector = cast([^]u8)&empty_string_byte
	}
	return {text = selector, text_len = u32(len(s))}
}

entry_from_int :: proc "contextless" (v: i64) -> Element {
	return {number = v}
}

entry_bytes :: proc "contextless" (e: Element, buf: ^[DECIMAL_BUFFER_BYTES]u8) -> []u8 {
	if e.text != nil {
		return e.text[:int(e.text_len)]
	}
	length := ll2string(raw_data(buf[:]), e.number)
	return buf[:length]
}

padd :: proc "contextless" (p: [^]u8, n: int) -> [^]u8 {
	return mem.ptr_offset(p, n)
}

pdiff :: proc "contextless" (a, b: [^]u8) -> int {
	return mem.ptr_sub(a, b)
}

lp_string_to_int64 :: proc "contextless" (s: []u8, value: ^i64) -> bool {
	parsed, valid := integer.parse_i64(s)
	if valid && value != nil {
		value^ = parsed
	}
	return valid
}

digits10 :: proc "contextless" (v: u64) -> u32 {
	count := u32(1)
	remaining := v
	for remaining >= 10 {
		remaining /= 10
		count += 1
	}
	return count
}

integer_magnitude :: proc "contextless" (v: i64) -> u64 {
	if v < 0 {
		return u64(-(v + 1)) + 1
	}
	return u64(v)
}

sdigits10 :: proc "contextless" (v: i64) -> u32 {
	return digits10(integer_magnitude(v)) + u32(v < 0)
}

ll2string :: proc "contextless" (dst: [^]u8, svalue: i64) -> int {
	magnitude := integer_magnitude(svalue)
	length := int(digits10(magnitude)) + int(svalue < 0)
	position := length
	for {
		position -= 1
		dst[position] = u8(magnitude % 10) + '0'
		magnitude /= 10
		if magnitude == 0 {
			break
		}
	}
	if svalue < 0 {
		dst[0] = '-'
	}
	return length
}

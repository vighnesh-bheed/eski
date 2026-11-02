package listpack

DECIMAL_BUFFER_BYTES :: 21
PACK_HEADER_BYTES :: 6
COUNT_UNTRACKED :: 65535
PACK_END :: u8(255)
PACK_SIZE_CEILING :: 1 << 30

Placement :: enum u8 {
	Before,
	After,
	Replace,
}

Element :: struct {
	text:     [^]u8,
	text_len: u32,
	number:   i64,
}

Element_Matcher :: #type proc(pack: [^]u8, at: [^]u8, state: rawptr, text: [^]u8, measure: i64) -> int
Element_Visitor :: #type proc(at: [^]u8, declared_count: u32, state: rawptr) -> bool

empty_string_byte: u8

Header :: struct {
	bytes: u32,
	count: u16,
}

Body :: struct {
	bytes:         int,
	value:         i64,
	string_offset: int,
	string_length: int,
	is_string:     bool,
}

read_unsigned :: proc "contextless" (data: []u8, offset, width: int) -> (u64, bool) {
	if offset < 0 || width < 1 || width > 8 || offset > len(data) || width > len(data) - offset {
		return 0, false
	}
	value := u64(0)
	for index in 0..<width {
		value |= u64(data[offset + index]) << uint(index * 8)
	}
	return value, true
}

write_unsigned :: proc "contextless" (data: []u8, offset, width: int, value: u64) -> bool {
	if offset < 0 || width < 1 || width > 8 || offset > len(data) || width > len(data) - offset {
		return false
	}
	for index in 0..<width {
		data[offset + index] = u8(value >> uint(index * 8))
	}
	return true
}

decode_header :: proc "contextless" (data: []u8) -> (Header, bool) {
	if len(data) < PACK_HEADER_BYTES + 1 {
		return {}, false
	}
	total, _ := read_unsigned(data, 0, 4)
	count, _ := read_unsigned(data, 4, 2)
	if total < PACK_HEADER_BYTES + 1 || total > u64(len(data)) {
		return {}, false
	}
	if data[int(total) - 1] != PACK_END {
		return {}, false
	}
	return {bytes = u32(total), count = u16(count)}, true
}

signed_value :: proc "contextless" (value: u64, bits: uint) -> i64 {
	if bits == 64 {
		return i64(value)
	}
	if value & (u64(1) << (bits - 1)) != 0 {
		return i64(value) - i64(u64(1) << bits)
	}
	return i64(value)
}

decode_body :: proc "contextless" (data: []u8, offset: int) -> (Body, bool) {
	if offset < 0 || offset >= len(data) {
		return {}, false
	}
	tag := data[offset]
	if tag < 128 {
		return {bytes = 1, value = i64(tag)}, true
	}
	header_bytes := 1
	string_length := u64(0)
	if tag < 192 {
		string_length = u64(tag & 63)
	} else if tag < 224 {
		if len(data) - offset < 2 {
			return {}, false
		}
		value := u64(tag & 31) << 8 | u64(data[offset + 1])
		return {bytes = 2, value = signed_value(value, 13)}, true
	} else if tag < 240 {
		if len(data) - offset < 2 {
			return {}, false
		}
		header_bytes = 2
		string_length = u64(tag & 15) << 8 | u64(data[offset + 1])
	} else if tag == 240 {
		length, valid := read_unsigned(data, offset + 1, 4)
		if !valid {
			return {}, false
		}
		header_bytes = 5
		string_length = length
	} else if tag <= 244 {
		width := 0
		switch tag {
		case 241:
			width = 2
		case 242:
			width = 3
		case 243:
			width = 4
		case 244:
			width = 8
		}
		value, valid := read_unsigned(data, offset + 1, width)
		if !valid {
			return {}, false
		}
		return {bytes = width + 1, value = signed_value(value, uint(width * 8))}, true
	} else {
		return {}, false
	}
	if string_length > u64(len(data) - offset - header_bytes) {
		return {}, false
	}
	return {
		bytes = header_bytes + int(string_length),
		string_offset = offset + header_bytes,
		string_length = int(string_length),
		is_string = true,
	}, true
}

lp_encoding_is_7bit_uint :: proc "contextless" (b: u8) -> bool {
	return b < 128
}

lp_encoding_is_6bit_str :: proc "contextless" (b: u8) -> bool {
	return b >= 128 && b < 192
}

lp_encoding_is_13bit_int :: proc "contextless" (b: u8) -> bool {
	return b >= 192 && b < 224
}

lp_encoding_is_12bit_str :: proc "contextless" (b: u8) -> bool {
	return b >= 224 && b < 240
}

lp_encoding_is_32bit_str :: proc "contextless" (b: u8) -> bool {
	return b == 240
}

lp_encoding_is_16bit_int :: proc "contextless" (b: u8) -> bool {
	return b == 241
}

lp_encoding_is_24bit_int :: proc "contextless" (b: u8) -> bool {
	return b == 242
}

lp_encoding_is_32bit_int :: proc "contextless" (b: u8) -> bool {
	return b == 243
}

lp_encoding_is_64bit_int :: proc "contextless" (b: u8) -> bool {
	return b == 244
}

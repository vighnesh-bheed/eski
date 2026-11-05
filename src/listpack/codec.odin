package listpack

integer_body_size :: proc "contextless" (value: i64) -> int {
	if value >= 0 && value <= 127 {
		return 1
	}
	if value >= -4096 && value <= 4095 {
		return 2
	}
	if value >= i64(min(i16)) && value <= i64(max(i16)) {
		return 3
	}
	if value >= -8388608 && value <= 8388607 {
		return 4
	}
	if value >= i64(min(i32)) && value <= i64(max(i32)) {
		return 5
	}
	return 9
}

write_integer :: proc "contextless" (data: []u8, value: i64) -> (int, bool) {
	length := integer_body_size(value)
	if len(data) < length {
		return length, false
	}
	if length == 1 {
		data[0] = u8(value)
	} else if length == 2 {
		bits := u64(value) & 8191
		data[0] = 192 | u8(bits >> 8)
		data[1] = u8(bits)
	} else {
		switch length {
		case 3:
			data[0] = 241
		case 4:
			data[0] = 242
		case 5:
			data[0] = 243
		case 9:
			data[0] = 244
		}
		write_unsigned(data, 1, length - 1, u64(value))
	}
	return length, true
}

backlen_width :: proc "contextless" (length: u64) -> int {
	if length <= 127 {
		return 1
	}
	if length < 16383 {
		return 2
	}
	if length < 2097151 {
		return 3
	}
	if length < 268435455 {
		return 4
	}
	return 5
}

lp_encode_backlen :: proc "contextless" (buf: [^]u8, l: u64) -> u64 {
	if l > u64(max(u32)) {
		return 0
	}
	width := backlen_width(l)
	if buf != nil {
		for index in 0..<width {
			byte := u8(l >> uint((width - 1 - index) * 7)) & 127
			if index > 0 {
				byte |= 128
			}
			buf[index] = byte
		}
	}
	return u64(width)
}

read_backlen :: proc "contextless" (data: []u8, last, lower: int) -> (u64, int, bool) {
	if lower < 0 || last < lower || last >= len(data) {
		return 0, 0, false
	}
	value := u64(0)
	for width in 1..=5 {
		if width - 1 > last - lower {
			return 0, 0, false
		}
		byte := data[last - width + 1]
		value |= u64(byte & 127) << uint((width - 1) * 7)
		if byte & 128 == 0 {
			return value, width, value <= u64(max(u32))
		}
	}
	return 0, 0, false
}

lp_decode_backlen :: proc "contextless" (p: [^]u8) -> u64 {
	value := u64(0)
	for index in 0..<5 {
		byte := padd(p, -index)[0]
		value |= u64(byte & 127) << uint(index * 7)
		if byte & 128 == 0 {
			return value
		}
	}
	return max(u64)
}

lp_encode_integer_get_type :: proc "contextless" (v: i64, intenc: [^]u8, enclen: ^u64) {
	length := integer_body_size(v)
	if enclen != nil {
		enclen^ = u64(length)
	}
	if intenc != nil {
		write_integer(intenc[:length], v)
	}
}

lp_integer_entry_size :: proc "contextless" (value: i64) -> int {
	length := integer_body_size(value)
	return length + backlen_width(u64(length))
}

lp_repeated_integer_bytes :: proc "contextless" (value: i64, repeats: u64) -> int {
	entry_size := u64(lp_integer_entry_size(value))
	if repeats > (u64(max(int)) - PACK_HEADER_BYTES - 1) / entry_size {
		return max(int)
	}
	return PACK_HEADER_BYTES + 1 + int(repeats * entry_size)
}

string_header_size :: proc "contextless" (length: u32) -> int {
	if length < 64 {
		return 1
	}
	if length < 4096 {
		return 2
	}
	return 5
}

write_string :: proc "contextless" (data: []u8, value: []u8) -> (int, bool) {
	if u64(len(value)) > u64(max(u32)) {
		return 0, false
	}
	header := string_header_size(u32(len(value)))
	if len(value) > max(int) - header {
		return 0, false
	}
	length := header + len(value)
	if len(data) < length {
		return length, false
	}
	copy(data[header:length], value)
	switch header {
	case 1:
		data[0] = 128 | u8(len(value))
	case 2:
		data[0] = 224 | u8(len(value) >> 8)
		data[1] = u8(len(value))
	case 5:
		data[0] = 240
		write_unsigned(data, 1, 4, u64(len(value)))
	}
	return length, true
}

Entry_Plan :: struct {
	value:        Element,
	body_bytes:   int,
	encoded_bytes: int,
}

plan_entry :: proc "contextless" (entry: Element) -> (Entry_Plan, bool) {
	value := entry
	if value.text != nil && value.text_len <= 20 {
		integer_value := i64(0)
		if lp_string_to_int64(value.text[:int(value.text_len)], &integer_value) {
			value = entry_from_int(integer_value)
		}
	}
	length := 0
	if value.text == nil {
		length = integer_body_size(value.number)
	} else {
		wide_length := u64(string_header_size(value.text_len)) + u64(value.text_len)
		if wide_length > u64(max(int)) || wide_length > u64(max(u32)) {
			return {}, false
		}
		length = int(wide_length)
	}
	back := backlen_width(u64(length))
	if length > max(int) - back || u64(length) + u64(back) + PACK_HEADER_BYTES + 1 > u64(max(u32)) {
		return {}, false
	}
	return {value = value, body_bytes = length, encoded_bytes = length + back}, true
}

write_entry :: proc "contextless" (data: []u8, plan: Entry_Plan) -> bool {
	if plan.body_bytes < 1 || plan.encoded_bytes < plan.body_bytes || len(data) < plan.encoded_bytes {
		return false
	}
	if u64(plan.body_bytes) > u64(max(u32)) || plan.encoded_bytes - plan.body_bytes != backlen_width(u64(plan.body_bytes)) {
		return false
	}
	valid := false
	if plan.value.text == nil {
		_, valid = write_integer(data[:plan.body_bytes], plan.value.number)
	} else {
		_, valid = write_string(data[:plan.body_bytes], plan.value.text[:int(plan.value.text_len)])
	}
	if !valid {
		return false
	}
	return lp_encode_backlen(raw_data(data[plan.body_bytes:]), u64(plan.body_bytes)) == u64(plan.encoded_bytes - plan.body_bytes)
}

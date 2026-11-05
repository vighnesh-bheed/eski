package listpack

repr_text :: proc(output: ^[dynamic]u8, value: string) {
	append(output, ..transmute([]u8)value)
}

repr_unsigned :: proc(output: ^[dynamic]u8, value: u64, width: int) {
	buffer: [20]u8
	cursor := len(buffer)
	remaining := value
	for {
		cursor -= 1
		buffer[cursor] = u8(remaining % 10) + '0'
		remaining /= 10
		if remaining == 0 {
			break
		}
	}
	for _ in 0..<max(0, width - (len(buffer) - cursor)) {
		append(output, ' ')
	}
	append(output, ..buffer[cursor:])
}

repr_hex :: proc(output: ^[dynamic]u8, value: u64, width: int) {
	digits := "0123456789abcdef"
	buffer: [16]u8
	cursor := len(buffer)
	remaining := value
	for {
		cursor -= 1
		buffer[cursor] = digits[int(remaining & 15)]
		remaining >>= 4
		if remaining == 0 && len(buffer) - cursor >= width {
			break
		}
	}
	append(output, ..buffer[cursor:])
}

lp_repr :: proc(lp: [^]u8, allocator := context.allocator) -> string {
	output := make([dynamic]u8, 0, 128, allocator)
	repr_text(&output, "{total bytes ")
	repr_unsigned(&output, u64(lp_bytes(lp)), 0)
	repr_text(&output, "} {num entries ")
	repr_unsigned(&output, lp_length(lp), 0)
	repr_text(&output, "}\n")
	cursor := lp_first(lp)
	index := u64(0)
	for cursor != nil {
		body, valid := owned_body(cursor)
		if !valid {
			break
		}
		header := 1
		if body.is_string {
			header = body.string_offset
		}
		back := backlen_width(u64(body.bytes))
		repr_text(&output, "{\n\taddr: 0x")
		repr_hex(&output, u64(uintptr(cursor)), 0)
		repr_text(&output, ",\n\tindex: ")
		repr_unsigned(&output, index, 2)
		repr_text(&output, ",\n\toffset: ")
		repr_unsigned(&output, u64(pdiff(cursor, lp)), 0)
		repr_text(&output, ",\n\thdr+entrylen+backlen: ")
		repr_unsigned(&output, u64(body.bytes + back), 2)
		repr_text(&output, ",\n\thdrlen: ")
		repr_unsigned(&output, u64(header), 3)
		repr_text(&output, ",\n\tbacklen: ")
		repr_unsigned(&output, u64(back), 2)
		repr_text(&output, ",\n\tpayload: ")
		repr_unsigned(&output, u64(body.bytes - header), 0)
		repr_text(&output, "\n\tbytes: ")
		for byte in cursor[:body.bytes + back] {
			repr_hex(&output, u64(byte), 2)
			append(&output, '|')
		}
		repr_text(&output, "\n\t[str]")
		buffer: [DECIMAL_BUFFER_BYTES]u8
		bytes := lp_get_bytes(cursor, &buffer)
		append(&output, ..bytes[:min(40, len(bytes))])
		if len(bytes) > 40 {
			repr_text(&output, "...")
		}
		repr_text(&output, "\n}\n")
		index += 1
		cursor = lp_next(lp, cursor)
	}
	repr_text(&output, "{end}\n\n")
	return string(output[:])
}

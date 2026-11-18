package jsondoc

import "core:mem"
import "core:strconv"
import "../fpconv"

Format :: struct {
	indent, newline, space: string,
}

Buffer :: struct {
	bytes: [dynamic]u8,
	error: string,
}

buffer_init :: proc(b: ^Buffer, allocator: mem.Allocator) {
	b.bytes.allocator = allocator
}

buffer_add :: proc(b: ^Buffer, text: string) {
	if b.error != "" || len(text) == 0 {
		return
	}
	if len(text) > MAX_TEXT_BYTES - len(b.bytes) {
		b.error = SIZE_LIMIT
		return
	}
	if _, err := append(&b.bytes, ..transmute([]u8)text); err != nil {
		b.error = OUT_OF_MEMORY
	}
}

buffer_byte :: proc(b: ^Buffer, c: u8) {
	one := [1]u8{c}
	buffer_add(b, string(one[:]))
}

buffer_integer :: proc(b: ^Buffer, n: i64) {
	buf: [32]u8
	buffer_add(b, strconv.write_int(buf[:], n, 10))
}

format_parse_error :: proc(err: Parse_Error, prefix: bool, allocator := context.allocator) -> string {
	if err.line == 0 {
		return err.message
	}
	b: Buffer
	buffer_init(&b, allocator)
	defer delete(b.bytes)
	if prefix {
		buffer_add(&b, "ERR ")
	}
	buffer_add(&b, err.message)
	buffer_add(&b, " at line ")
	buffer_integer(&b, i64(err.line))
	buffer_add(&b, " column ")
	buffer_integer(&b, i64(err.column))
	if b.error != "" {
		return b.error
	}
	text, ok := copy_text(string(b.bytes[:]), allocator)
	return text if ok else OUT_OF_MEMORY
}

serialize :: proc(v: ^Value, options := Format{}, allocator := context.allocator) -> (string, string) {
	b: Buffer
	buffer_init(&b, allocator)
	defer delete(b.bytes)
	write_value(&b, v, options, 0)
	if b.error != "" {
		return "", b.error
	}
	text, ok := copy_text(string(b.bytes[:]), allocator)
	return text, "" if ok else OUT_OF_MEMORY
}

write_string :: proc(b: ^Buffer, text: string) {
	buffer_byte(b, '"')
	start := 0
	for c, i in transmute([]u8)text {
		escape: string
		switch c {
		case '"':
			escape = "\\\""
		case '\\':
			escape = "\\\\"
		case 8:
			escape = "\\b"
		case 9:
			escape = "\\t"
		case 10:
			escape = "\\n"
		case 12:
			escape = "\\f"
		case 13:
			escape = "\\r"
		case 0..=7, 11, 14..=31:
			hex := "0123456789abcdef"
			code := [6]u8{'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]}
			buffer_add(b, text[start:i])
			buffer_add(b, string(code[:]))
			start = i + 1
			continue
		case:
			continue
		}
		buffer_add(b, text[start:i])
		buffer_add(b, escape)
		start = i + 1
	}
	buffer_add(b, text[start:])
	buffer_byte(b, '"')
}

write_indent :: proc(b: ^Buffer, options: Format, depth: int) {
	buffer_add(b, options.newline)
	if options.indent != "" {
		for _ in 0 ..< depth {
			buffer_add(b, options.indent)
		}
	}
}

write_value :: proc(b: ^Buffer, v: ^Value, options: Format, nesting: int) {
	if b.error != "" {
		return
	}
	if v == nil {
		buffer_add(b, "null")
		return
	}
	#partial switch data in v.data {
	case Null:
		buffer_add(b, "null")
	case bool:
		buffer_add(b, "true" if data else "false")
	case i64:
		buffer_integer(b, data)
	case u64:
		buf: [32]u8
		buffer_add(b, strconv.write_uint(buf[:], data, 10))
	case f64:
		buf: [64]u8
		narrow := v.narrow if v.parent != nil && v.parent.narrow != .Normal else Float_Format.Normal
		buffer_add(b, narrow_double(buf[:], data, narrow))
	case string:
		write_string(b, data)
	case ^Array:
		buffer_byte(b, '[')
		for item, i in data.items {
			if i != 0 {
				buffer_byte(b, ',')
			}
			write_indent(b, options, nesting + 1)
			write_value(b, item, options, nesting + 1)
		}
		if len(data.items) != 0 {
			write_indent(b, options, nesting)
		}
		buffer_byte(b, ']')
	case ^Object:
		buffer_byte(b, '{')
		for member, i in data.members {
			if i != 0 {
				buffer_byte(b, ',')
			}
			write_indent(b, options, nesting + 1)
			write_string(b, member.name)
			buffer_byte(b, ':')
			buffer_add(b, options.space)
			write_value(b, member.value, options, nesting + 1)
		}
		if len(data.members) != 0 {
			write_indent(b, options, nesting)
		}
		buffer_byte(b, '}')
	}
}

json_double :: proc(dst: []u8, n: f64, bits := 64, precision := -1) -> string {
	spelling: [32]u8
	text := strconv.write_float(spelling[:], n, 'e', precision, bits)
	p := 0
	start := 0
	if text[0] == '-' {
		dst[p] = '-'
		p += 1
		start += 1
	} else if text[0] == '+' {
		start += 1
	}
	digits: [24]u8
	count := 0
	exp_start := start
	for exp_start < len(text) && text[exp_start] != 'e' {
		if text[exp_start] != '.' {
			digits[count] = text[exp_start]
			count += 1
		}
		exp_start += 1
	}
	if exp_start == len(text) || count == 0 {
		return text
	}
	e, _ := strconv.parse_i64(text[exp_start+1:], 10)
	point := int(e) + 1
	if count <= point && point <= 16 {
		p += copy(dst[p:], digits[:count])
		for _ in count ..< point {
			dst[p] = '0'
			p += 1
		}
		p += copy(dst[p:], ".0")
	} else if point > 0 && point <= 16 {
		p += copy(dst[p:], digits[:point])
		dst[p] = '.'
		p += 1
		p += copy(dst[p:], digits[point:count])
	} else if -5 < point && point <= 0 {
		p += copy(dst[p:], "0.")
		for _ in 0 ..< -point {
			dst[p] = '0'
			p += 1
		}
		p += copy(dst[p:], digits[:count])
	} else {
		dst[p] = digits[0]
		p += 1
		if count > 1 {
			dst[p] = '.'
			p += 1
			p += copy(dst[p:], digits[1:count])
		}
		dst[p] = 'e'
		p += 1
		p += len(strconv.write_int(dst[p:], e, 10))
	}
	return string(dst[:p])
}

resp_double :: proc(dst: []u8, n: f64) -> string {
	count := fpconv.format_double(dst, n)
	return string(dst[:count])
}

serialize_path_matches :: proc(matches: []Match, allocator: mem.Allocator) -> (string, bool) {
	b: Buffer
	buffer_init(&b, allocator)
	defer delete(b.bytes)
	buffer_byte(&b, '[')
	for match, i in matches {
		if i != 0 {
			buffer_byte(&b, ',')
		}
		write_value(&b, match.value, {}, 0)
	}
	buffer_byte(&b, ']')
	if b.error != "" {
		return "", false
	}
	return copy_text(string(b.bytes[:]), allocator)
}

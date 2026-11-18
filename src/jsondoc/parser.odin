package jsondoc

import "core:math"
import "core:mem"
import "core:strconv"
import "core:unicode/utf8"

Parse_Error :: struct {
	message: string,
	line, column: int,
}

Parser :: struct {
	text: string,
	pos, nodes: int,
	allocator: mem.Allocator,
	error: Parse_Error,
	narrow: Float_Format,
}

parse :: proc(text: string, allocator := context.allocator) -> (value: ^Value, err: Parse_Error) {
	return parse_with_float_format(text, .Normal, allocator)
}

parse_with_float_format :: proc(text: string, format: Float_Format, allocator: mem.Allocator) -> (^Value, Parse_Error) {
	if len(text) > MAX_TEXT_BYTES {
		return nil, {message = SIZE_LIMIT}
	}
	if !utf8.valid_string(text) {
		return nil, {message = "Couldn't parse as UTF-8 string"}
	}
	p := Parser{text = text, allocator = allocator, narrow = format}
	v := parse_value(&p, 0)
	if v != nil {
		space(&p)
		if p.pos != len(p.text) {
			fail_next(&p, "trailing characters")
			release(v, allocator)
			v = nil
		}
	}
	return v, p.error
}

fail_at :: proc(p: ^Parser, message: string, end: int) {
	line, line_start := 1, 0
	for i in 0 ..< min(end, len(p.text)) {
		if p.text[i] == '\n' {
			line += 1
			line_start = i + 1
		}
	}
	p.error = {message, line, min(end, len(p.text)) - line_start}
}

fail_next :: proc(p: ^Parser, message: string) {
	fail_at(p, message, p.pos + 1)
}

fail_empty :: proc(p: ^Parser, message: string) {
	p.error = {message = message}
}

peek :: proc(p: ^Parser) -> u8 {
	return p.text[p.pos] if p.pos < len(p.text) else 0
}

space :: proc(p: ^Parser) {
	for p.pos < len(p.text) {
		switch p.text[p.pos] {
		case ' ', '\n', '\r', '\t':
			p.pos += 1
		case:
			return
		}
	}
}

digit :: proc(c: u8) -> bool {
	return '0' <= c && c <= '9'
}

parse_value :: proc(p: ^Parser, nesting: int) -> ^Value {
	space(p)
	if p.pos == len(p.text) {
		fail_next(p, "EOF while parsing a value")
		return nil
	}
	if p.nodes >= MAX_ITEMS {
		fail_empty(p, SIZE_LIMIT)
		return nil
	}
	p.nodes += 1
	data: Data
	switch peek(p) {
	case '"':
		s, ok := parse_string(p)
		if !ok {
			return nil
		}
		data = s
	case 'n':
		if !parse_ident(p, "null") {
			return nil
		}
		data = Null{}
	case 't', 'f':
		b := peek(p) == 't'
		if !parse_ident(p, "true" if b else "false") {
			return nil
		}
		data = b
	case '{', '[':
		if nesting >= MAX_DEPTH {
			fail_next(p, "recursion limit exceeded")
			return nil
		}
		return parse_container(p, nesting + 1)
	case '-', '0'..='9':
		var := parse_number(p)
		if var == nil {
			return nil
		}
		data = var
	case:
		fail_next(p, "expected value")
		return nil
	}
	v := new_value(data, p.allocator)
	if v == nil {
		release_data(data, p.allocator)
		fail_empty(p, OUT_OF_MEMORY)
	}
	return v
}

parse_ident :: proc(p: ^Parser, text: string) -> bool {
	for c in transmute([]u8)text {
		if p.pos == len(p.text) {
			fail_next(p, "EOF while parsing a value")
			return false
		}
		p.pos += 1
		if p.text[p.pos - 1] != c {
			fail_at(p, "expected ident", p.pos)
			return false
		}
	}
	return true
}

parse_container :: proc(p: ^Parser, nesting: int) -> ^Value {
	object := peek(p) == '{'
	end: u8 = '}' if object else ']'
	eof := "EOF while parsing an object" if object else "EOF while parsing a list"
	v := make_object(p.allocator) if object else make_array(p.allocator)
	if v == nil {
		fail_empty(p, OUT_OF_MEMORY)
		return nil
	}
	if !object {
		v.narrow = p.narrow
	}
	success := false
	defer if !success {
		release(v, p.allocator)
	}
	p.pos += 1
	space(p)
	if peek(p) != end {
		for {
			if p.pos == len(p.text) {
				fail_next(p, eof)
				return nil
			}
			name: string
			if object {
				if peek(p) != '"' {
					fail_next(p, "key must be a string")
					return nil
				}
				ok: bool
				name, ok = parse_string(p)
				if !ok {
					return nil
				}
				space(p)
				if peek(p) != ':' {
					fail_next(p, "EOF while parsing an object" if p.pos == len(p.text) else "expected `:`")
					free_text(name, p.allocator)
					return nil
				}
				p.pos += 1
			}
			child := parse_value(p, nesting)
			if child == nil {
				free_text(name, p.allocator)
				return nil
			}
			if !object && !narrow_array_number(p, child) {
				release(child, p.allocator)
				return nil
			}
			err := object_add(v, name, child, p.allocator) if object else array_add(v, child)
			if err != "" {
				release(child, p.allocator)
				free_text(name, p.allocator)
				fail_empty(p, err)
				return nil
			}
			space(p)
			if peek(p) == end {
				break
			}
			if p.pos == len(p.text) {
				fail_next(p, eof)
				return nil
			}
			if peek(p) != ',' {
				fail_next(p, "expected `,` or `}`" if object else "expected `,` or `]`")
				return nil
			}
			p.pos += 1
			space(p)
			if peek(p) == end {
				fail_next(p, "trailing comma")
				return nil
			}
		}
	}
	p.pos += 1
	success = true
	return v
}

read_hex :: proc(p: ^Parser) -> (rune, bool) {
	value: rune
	invalid := 0
	for _ in 0 ..< 4 {
		if p.pos == len(p.text) {
			fail_next(p, "EOF while parsing a string")
			return 0, false
		}
		c := p.text[p.pos]
		p.pos += 1
		value *= 16
		switch c {
		case '0'..='9':
			value += rune(c - '0')
		case 'a'..='f':
			value += rune(c - 'a' + 10)
		case 'A'..='F':
			value += rune(c - 'A' + 10)
		case:
			invalid = p.pos
		}
	}
	if invalid != 0 {
		fail_at(p, "invalid escape", p.pos)
		return 0, false
	}
	return value, true
}

parse_escape :: proc(p: ^Parser) -> (rune, bool) {
	if p.pos == len(p.text) {
		fail_next(p, "EOF while parsing a string")
		return 0, false
	}
	c := p.text[p.pos]
	p.pos += 1
	switch c {
	case '"', '/', '\\':
		return rune(c), true
	case 'b':
		return 0x08, true
	case 'f':
		return 0x0c, true
	case 'n':
		return '\n', true
	case 'r':
		return '\r', true
	case 't':
		return '\t', true
	case 'u':
		r, ok := read_hex(p)
		if !ok {
			return 0, false
		}
		if 0xdc00 <= r && r <= 0xdfff {
			fail_at(p, "lone leading surrogate in hex escape", p.pos)
			return 0, false
		}
		if r < 0xd800 || r > 0xdbff {
			return r, true
		}
		if len(p.text) - p.pos < 2 || p.text[p.pos:p.pos+2] != "\\u" {
			fail_next(p, "unexpected end of hex escape")
			return 0, false
		}
		p.pos += 2
		low, low_ok := read_hex(p)
		if !low_ok {
			return 0, false
		}
		if low < 0xdc00 || low > 0xdfff {
			fail_at(p, "lone leading surrogate in hex escape", p.pos)
			return 0, false
		}
		return 0x10000 + (r - 0xd800) * 1024 + low - 0xdc00, true
	case:
		fail_at(p, "invalid escape", p.pos)
		return 0, false
	}
}

parse_string :: proc(p: ^Parser) -> (string, bool) {
	p.pos += 1
	start := p.pos
	buf: [dynamic]u8
	buf.allocator = p.allocator
	defer delete(buf)
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		p.pos += 1
		switch c {
		case '"':
			tail := p.text[start:p.pos-1]
			if len(buf) != 0 {
				_, err := append(&buf, ..transmute([]u8)tail)
				if err != nil {
					fail_empty(p, OUT_OF_MEMORY)
					return "", false
				}
				tail = string(buf[:])
			}
			s, ok := copy_text(tail, p.allocator)
			if !ok {
				fail_empty(p, OUT_OF_MEMORY)
			}
			return s, ok
		case '\\':
			r, ok := parse_escape_after_chunk(p, &buf, start)
			if !ok {
				return "", false
			}
			encoded, width := utf8.encode_rune(r)
			_, err := append(&buf, ..encoded[:width])
			if err != nil {
				fail_empty(p, OUT_OF_MEMORY)
				return "", false
			}
			start = p.pos
		case 0..=0x1f:
			fail_at(p, "control character (\\u0000-\\u001F) found while parsing a string", p.pos)
			return "", false
		}
	}
	fail_next(p, "EOF while parsing a string")
	return "", false
}

parse_escape_after_chunk :: proc(p: ^Parser, buf: ^[dynamic]u8, start: int) -> (rune, bool) {
	_, err := append(buf, ..transmute([]u8)p.text[start:p.pos-1])
	if err != nil {
		fail_empty(p, OUT_OF_MEMORY)
		return 0, false
	}
	return parse_escape(p)
}

scan_digits :: proc(p: ^Parser) {
	for digit(peek(p)) {
		p.pos += 1
	}
}

parse_number :: proc(p: ^Parser) -> Data {
	start := p.pos
	negative := peek(p) == '-'
	if negative {
		p.pos += 1
	}
	if !digit(peek(p)) {
		fail_next(p, "EOF while parsing a value" if p.pos == len(p.text) else "invalid number")
		return nil
	}
	if peek(p) == '0' {
		p.pos += 1
		if digit(peek(p)) {
			fail_next(p, "invalid number")
			return nil
		}
	} else {
		scan_digits(p)
	}
	decimal := peek(p) == '.'
	if decimal {
		p.pos += 1
		if !digit(peek(p)) {
			fail_next(p, "EOF while parsing a value" if p.pos == len(p.text) else "invalid number")
			return nil
		}
		scan_digits(p)
	}
	if peek(p) == 'e' || peek(p) == 'E' {
		decimal = true
		p.pos += 1
		if peek(p) == '+' || peek(p) == '-' {
			p.pos += 1
		}
		if !digit(peek(p)) {
			fail_next(p, "EOF while parsing a value" if p.pos == len(p.text) else "invalid number")
			return nil
		}
		scan_digits(p)
	}
	text := p.text[start:p.pos]
	if !decimal && text != "-0" {
		magnitude, fits := unsigned_decimal(text[int(negative):])
		if fits {
			if !negative {
				if magnitude <= u64(max(i64)) {
					return i64(magnitude)
				}
				return magnitude
			}
			if magnitude <= u64(max(i64)) + 1 {
				return -i64(magnitude-1) - 1
			}
		} else {
			return parse_large_integer(p, text[int(negative):], negative)
		}
	}
	v, ok := strconv.parse_f64(text)
	if !ok || math.is_inf(v) || math.is_nan(v) {
		fail_at(p, "number out of range", p.pos)
		return nil
	}
	return v
}


unsigned_decimal :: proc(text: string) -> (u64, bool) {
	n: u64
	for c in transmute([]u8)text {
		if !digit(c) {
			return 0, false
		}
		d := u64(c-'0')
		if n > (max(u64)-d)/10 {
			return 0, false
		}
		n = n*10+d
	}
	return n, true
}


parse_large_integer :: proc(p: ^Parser, text: string, negative: bool) -> Data {
	magnitude: u64
	end := 0
	for byte in transmute([]u8)text {
		digit := u64(byte - '0')
		if magnitude > (max(u64)-digit)/10 {
			break
		}
		magnitude = magnitude*10 + digit
		end += 1
	}
	exp := len(text)-end
	if exp > 308 {
		fail_at(p, "number out of range", p.pos)
		return nil
	}
	scale: f64 = 1
	if exp > 0 {
		buf: [24]u8
		buf[0], buf[1] = '1', 'e'
		n := len(strconv.write_int(buf[2:], i64(exp), 10))
		scale, _ = strconv.parse_f64(string(buf[:2+n]))
	}
	value := f64(magnitude) * scale
	if math.is_inf(value) {
		fail_at(p, "number out of range", p.pos)
		return nil
	}
	return -value if negative else value
}

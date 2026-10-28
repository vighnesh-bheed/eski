package bitmap_harness

import "core:strconv"
import "core:strings"

cmd_append :: proc(buf: ^[dynamic]u8, args: [][]u8) {
	tmp: [32]u8
	append(buf, "*")
	append(buf, strconv.write_int(tmp[:], i64(len(args)), 10))
	append(buf, "\r\n")
	for a in args {
		append(buf, "$")
		append(buf, strconv.write_int(tmp[:], i64(len(a)), 10))
		append(buf, "\r\n")
		append(buf, ..a)
		append(buf, "\r\n")
	}
}

read_line :: proc(data: []u8, pos: int) -> (line: []u8, next: int, ok: bool) {
	i := pos
	for i + 1 < len(data) {
		if data[i] == '\r' && data[i + 1] == '\n' {
			return data[pos:i], i + 2, true
		}
		i += 1
	}
	return nil, pos, false
}

parse_commands :: proc(data: []u8, allocator := context.allocator) -> (cmds: [dynamic][][]u8, ok: bool) {
	cmds = make([dynamic][][]u8, allocator)
	pos := 0
	for pos < len(data) {
		if data[pos] != '*' {
			return cmds, false
		}
		line, next, lok := read_line(data, pos)
		if !lok {
			return cmds, false
		}
		argc, aok := strconv.parse_int(string(line[1:]))
		if !aok {
			return cmds, false
		}
		pos = next
		argv := make([][]u8, argc, allocator)
		for i in 0 ..< argc {
			hdr, hnext, hok := read_line(data, pos)
			if !hok || len(hdr) < 2 || hdr[0] != '$' {
				return cmds, false
			}
			n, nok := strconv.parse_int(string(hdr[1:]))
			if !nok || hnext + n + 2 > len(data) {
				return cmds, false
			}
			argv[i] = data[hnext:hnext + n]
			pos = hnext + n + 2
		}
		append(&cmds, argv)
	}
	return cmds, true
}

reply_end :: proc(data: []u8, pos: int) -> (end: int, ok: bool) {
	if pos >= len(data) {
		return pos, false
	}
	line, next, lok := read_line(data, pos)
	if !lok || len(line) == 0 {
		return pos, false
	}
	switch line[0] {
	case '+', '-', ':':
		return next, true
	case '$':
		n, nok := strconv.parse_int(string(line[1:]))
		if !nok {
			return pos, false
		}
		if n < 0 {
			return next, true
		}
		if next + n + 2 > len(data) {
			return pos, false
		}
		return next + n + 2, true
	case '*':
		n, nok := strconv.parse_int(string(line[1:]))
		if !nok {
			return pos, false
		}
		p := next
		for _ in 0 ..< max(n, 0) {
			e, eok := reply_end(data, p)
			if !eok {
				return pos, false
			}
			p = e
		}
		return p, true
	}
	return pos, false
}

Reply_Kind :: enum u8 {
	Int,
	Bulk,
	Null,
	Error,
	Status,
	Array,
	Invalid,
}

Reply :: struct {
	kind:  Reply_Kind,
	num:   i64,
	str:   string,
	elems: []Reply,
}

parse_reply :: proc(data: []u8, pos: int, allocator := context.temp_allocator) -> (r: Reply, next: int) {
	line, nx, ok := read_line(data, pos)
	if !ok || len(line) == 0 {
		return Reply{kind = .Invalid}, pos
	}
	body := string(line[1:])
	switch line[0] {
	case ':':
		v, _ := strconv.parse_i64(body)
		return Reply{kind = .Int, num = v}, nx
	case '+':
		return Reply{kind = .Status, str = strings.clone(body, allocator)}, nx
	case '-':
		return Reply{kind = .Error, str = strings.clone(body, allocator)}, nx
	case '$':
		n, _ := strconv.parse_int(body)
		if n < 0 {
			return Reply{kind = .Null}, nx
		}
		return Reply{kind = .Bulk, str = strings.clone(string(data[nx:nx + n]), allocator)}, nx + n + 2
	case '*':
		n, _ := strconv.parse_int(body)
		if n < 0 {
			return Reply{kind = .Null}, nx
		}
		elems := make([]Reply, n, allocator)
		p := nx
		for i in 0 ..< n {
			elems[i], p = parse_reply(data, p, allocator)
		}
		return Reply{kind = .Array, elems = elems}, p
	}
	return Reply{kind = .Invalid}, pos
}

escape_bytes :: proc(b: []u8, limit: int, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	n := min(len(b), limit)
	for i in 0 ..< n {
		c := b[i]
		switch {
		case c == '\r':
			strings.write_string(&sb, "\\r")
		case c == '\n':
			strings.write_string(&sb, "\\n")
		case c == '\\':
			strings.write_string(&sb, "\\\\")
		case c >= 32 && c < 127:
			strings.write_byte(&sb, c)
		case:
			hex := "0123456789abcdef"
			strings.write_string(&sb, "\\x")
			strings.write_byte(&sb, hex[c >> 4])
			strings.write_byte(&sb, hex[c & 15])
		}
	}
	if len(b) > limit {
		strings.write_string(&sb, "...(")
		strings.write_int(&sb, len(b))
		strings.write_string(&sb, " bytes)")
	}
	return strings.to_string(sb)
}

render_command :: proc(argv: [][]u8, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for a, i in argv {
		if i > 0 {
			strings.write_byte(&sb, ' ')
		}
		strings.write_string(&sb, escape_bytes(a, 48, allocator))
	}
	return strings.to_string(sb)
}

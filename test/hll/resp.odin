package hll_harness

import "core:strconv"

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

cmd :: proc(buf: ^[dynamic]u8, args: ..string) {
	parts := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		parts[i] = transmute([]u8)a
	}
	cmd_append(buf, parts)
}

cmd_with :: proc(buf: ^[dynamic]u8, head: []string, elems: [][]u8) {
	parts := make([][]u8, len(head) + len(elems), context.temp_allocator)
	for a, i in head {
		parts[i] = transmute([]u8)a
	}
	copy(parts[len(head):], elems)
	cmd_append(buf, parts)
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

reply_int :: proc(r: []u8) -> (v: i64, ok: bool) {
	if len(r) < 3 || r[0] != ':' {
		return 0, false
	}
	return strconv.parse_i64(string(r[1:len(r) - 2]))
}

reply_text :: proc(r: []u8) -> string {
	if len(r) >= 3 && (r[0] == '+' || r[0] == '-') {
		return string(r[1:len(r) - 2])
	}
	return ""
}

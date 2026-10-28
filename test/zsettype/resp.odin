package zsettype_harness

import "core:strconv"

Kind :: enum u8 {
	Simple,
	Error,
	Integer,
	Bulk,
	Null,
	Array,
	Map,
	Set,
	Double,
	Boolean,
	Big_Number,
	Verbatim,
	Push,
	Null_Array,
	Attribute,
}

Reply :: struct {
	kind:  Kind,
	str:   []u8,
	num:   i64,
	elems: []Reply,
	raw:   []u8,
}

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
		args := make([][]u8, argc, allocator)
		for i in 0 ..< argc {
			l2, n2, ok2 := read_line(data, pos)
			if !ok2 || len(l2) == 0 || l2[0] != '$' {
				return cmds, false
			}
			n, nok := strconv.parse_int(string(l2[1:]))
			if !nok || n2 + n + 2 > len(data) {
				return cmds, false
			}
			args[i] = data[n2:n2 + n]
			pos = n2 + n + 2
		}
		append(&cmds, args)
	}
	return cmds, true
}

parse_reply :: proc(data: []u8, pos: int, allocator := context.allocator) -> (r: Reply, next: int, ok: bool) {
	line, p, lok := read_line(data, pos)
	if !lok || len(line) == 0 {
		return {}, pos, false
	}
	body := line[1:]
	switch line[0] {
	case '+':
		r.kind = .Simple
		r.str = body
	case '-':
		r.kind = .Error
		r.str = body
	case ':':
		r.kind = .Integer
		r.str = body
		r.num, _ = strconv.parse_i64(string(body))
	case '_':
		r.kind = .Null
	case ',':
		r.kind = .Double
		r.str = body
	case '#':
		r.kind = .Boolean
		r.str = body
	case '(':
		r.kind = .Big_Number
		r.str = body
	case '$', '=', '!':
		n, nok := strconv.parse_int(string(body))
		if !nok {
			return {}, pos, false
		}
		if n < 0 {
			r.kind = .Null
		} else {
			if p + n + 2 > len(data) {
				return {}, pos, false
			}
			r.kind = .Bulk if line[0] == '$' else (.Verbatim if line[0] == '=' else .Error)
			r.str = data[p:p + n]
			p += n + 2
		}
	case '*', '~', '>', '%', '|':
		n, nok := strconv.parse_int(string(body))
		if !nok {
			return {}, pos, false
		}
		if n < 0 {
			r.kind = .Null_Array
		} else {
			switch line[0] {
			case '*':
				r.kind = .Array
			case '~':
				r.kind = .Set
			case '>':
				r.kind = .Push
			case '%':
				r.kind = .Map
				n *= 2
			case '|':
				r.kind = .Attribute
				n *= 2
			}
			elems := make([]Reply, n, allocator)
			for i in 0 ..< n {
				e, np, eok := parse_reply(data, p, allocator)
				if !eok {
					return {}, pos, false
				}
				elems[i] = e
				p = np
			}
			r.elems = elems
		}
	case:
		return {}, pos, false
	}
	r.raw = data[pos:p]
	return r, p, true
}

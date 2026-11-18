package jsondoc

import "core:mem"

PATH_MISSING :: "ERR Path does not exist"
PROJECTION_ERROR :: "ERR computed/projection expressions are only supported by JSON.GET/JSON.MGET/JSON.RESP"
EXPECT_DOT :: "<string>, function_name, '*'"
EXPECT_DESCENT :: "<string>, '*'"
EXPECT_BRACKET :: "'<string>[,<string>,...]', '<number>', ['start:end:steps'], '*'"
EXPECT_SLICE :: "['start:end:steps']"
EXPECT_END :: "EOI, add, sub, mul, div, rem, postfix_method, get_keys_op, '..'"
EXPECT_FILTER :: "add, sub, mul, div, rem, postfix_method, get_keys_op, and, or"
EXPECT_COMPARISON :: "ge, gt, le, lt, eq, ne, re, in_op, nin_op, subsetof_op, anyof_op, noneof_op, size_op, empty_op, add, sub, mul, div, rem, postfix_method, get_keys_op, and, or, '..'"
MAX_PATH_BYTES :: 1024 * 1024

Path :: struct {
	expr: ^Expr,
	legacy: bool,
}

Expr_Kind :: enum {
	Selector, Literal, Call,
	Add, Sub, Mul, Div, Rem, Pos, Neg,
	Not, And, Or, Eq, Ne, Lt, Le, Gt, Ge, Regex,
	In, Nin, Size, Empty, Subset, Any, None,
}

Expr :: struct {
	kind: Expr_Kind,
	root, rooted: bool,
	literal: ^Value,
	name: string,
	steps: [dynamic]Step,
	args: [dynamic]^Expr,
	left, right: ^Expr,
}

Step_Kind :: enum {
	Name, Index, Wildcard, Names, Indexes, Slice, Filter,
}

Step :: struct {
	kind: Step_Kind,
	descend: bool,
	name: string,
	index: i64,
	names: [dynamic]string,
	indexes: [dynamic]i64,
	start, end, stride: i64,
	predicate: ^Expr,
}

Path_Error :: struct {
	position: int,
	expected, message: string,
}

Path_Parser :: struct {
	text: string,
	pos, nesting, operations: int,
	allocator: mem.Allocator,
	error: Path_Error,
}

compile_path :: proc(text: string, allocator := context.allocator) -> (Path, Path_Error) {
	if len(text) > MAX_PATH_BYTES {
		return {}, {message = SIZE_LIMIT}
	}
	p := Path_Parser{text = text, allocator = allocator}
	direct := len(text) > 0 && text[0] == '$'
	if text == "." {
		e := expr_new(&p, .Selector)
		if e != nil {
			e.root, e.rooted = true, true
		}
		return {e, true}, p.error
	}
	computed := projection_prefix(text)
	if direct || computed {
		e := parse_expression(&p, false, 1)
		path_space(&p)
		if p.error == {} && p.pos < len(p.text) {
			path_fail(&p, p.pos, EXPECT_END)
		}
		return {e, !direct && !computed}, p.error
	}
	prefix := "$."
	if len(text) > 0 && (text[0] == '.' || text[0] == '[') {
		prefix = "$"
	}
	buf: Buffer
	buffer_init(&buf, allocator)
	buffer_add(&buf, prefix)
	buffer_add(&buf, text)
	if buf.error != "" {
		return {}, {message = buf.error}
	}
	p.text = string(buf.bytes[:])
	e := parse_expression(&p, false, 1)
	path_space(&p)
	if p.error == {} && p.pos < len(p.text) {
		if path_peek(&p) == '/' {
			p.error = {message = PATH_MISSING}
		} else {
			path_fail(&p, p.pos, EXPECT_END)
		}
	}
	return {e, e == nil || e.kind == .Selector}, p.error
}

projection_prefix :: proc(text: string) -> bool {
	p := Path_Parser{text = text}
	path_space(&p)
	c := path_peek(&p)
	if c == '(' {
		return true
	}
	if c == '+' || c == '-' {
		p.pos += 1
		path_space(&p)
		if path_peek(&p) == '$' || path_peek(&p) == '(' {
			return true
		}
	}
	for name_byte(path_peek(&p)) {
		p.pos += 1
	}
	return path_peek(&p) == '(' || (digit(c) && p.pos < len(text) && contains_arithmetic(text))
}

contains_arithmetic :: proc(text: string) -> bool {
	bytes := transmute([]u8)text
	for i in 1 ..< len(bytes)-1 {
		c := bytes[i]
		if (c == '+' || c == '-' || c == '*' || c == '/' || c == '%') && path_whitespace(bytes[i-1]) && path_whitespace(bytes[i+1]) {
			return true
		}
	}
	return false
}

path_error_text :: proc(e: Path_Error, allocator := context.allocator) -> string {
	if e.expected == "" {
		return e.message
	}
	b: Buffer
	buffer_init(&b, allocator)
	defer delete(b.bytes)
	buffer_add(&b, "Error occurred at position ")
	buffer_integer(&b, i64(e.position))
	buffer_add(&b, ", Error at position ")
	buffer_integer(&b, i64(e.position))
	buffer_add(&b, ": expected one of the following: ")
	buffer_add(&b, e.expected)
	if b.error != "" {
		return b.error
	}
	text, ok := copy_text(string(b.bytes[:]), allocator)
	return text if ok else OUT_OF_MEMORY
}

path_fail :: proc(p: ^Path_Parser, pos: int, expected: string) {
	if p.error == {} {
		p.error = {position = pos, expected = expected}
	}
}

path_peek :: proc(p: ^Path_Parser) -> u8 {
	return p.text[p.pos] if p.pos < len(p.text) else 0
}

path_next :: proc(p: ^Path_Parser, look := 1) -> u8 {
	return p.text[p.pos+look] if p.pos + look < len(p.text) else 0
}

path_whitespace :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

path_space :: proc(p: ^Path_Parser) {
	for path_whitespace(path_peek(p)) {
		p.pos += 1
	}
}

path_take :: proc(p: ^Path_Parser, text: string) -> bool {
	if len(text) <= len(p.text) - p.pos && p.text[p.pos:p.pos+len(text)] == text {
		p.pos += len(text)
		return true
	}
	return false
}

path_push :: proc(p: ^Path_Parser, items: ^[dynamic]$T, item: T) -> bool {
	if len(items) >= MAX_PATH_STEPS {
		p.error = {message = SIZE_LIMIT}
		return false
	}
	if _, err := append(items, item); err != nil {
		p.error = {message = OUT_OF_MEMORY}
		return false
	}
	return true
}

expr_new :: proc(p: ^Path_Parser, kind: Expr_Kind) -> ^Expr {
	if p.operations >= MAX_PATH_STEPS {
		p.error = {message = SIZE_LIMIT}
		return nil
	}
	p.operations += 1
	e, err := new(Expr, p.allocator)
	if err != nil {
		p.error = {message = OUT_OF_MEMORY}
		return nil
	}
	e.kind = kind
	e.steps.allocator = p.allocator
	e.args.allocator = p.allocator
	return e
}

name_byte :: proc(c: u8) -> bool {
	return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || digit(c) || c == '_' || c == '$' || c == '-' || c == '+'
}

parse_selector :: proc(p: ^Path_Parser, in_filter: bool) -> ^Expr {
	start := p.pos
	e := expr_new(p, .Selector)
	if e == nil {
		return nil
	}
	e.root = path_peek(p) == '$'
	e.rooted = true
	p.pos += 1
	if e.root && p.pos == 1 {
		first := path_peek(p)
		path_space(p)
		next := path_peek(p)
		if (p.pos > 1 && (next == '.' || next == '[')) || (name_byte(first) && first != '+' && first != '-') {
			p.error = {message = PATH_MISSING}
			return nil
		}
		p.pos = 1
	}
	for p.error == {} {
		before_space := p.pos
		path_space(p)
		switch path_peek(p) {
		case '.', '[':
		case '~':
			p.pos += 1
			call := expr_new(p, .Call)
			if call == nil || !path_push(p, &call.args, e) {
				return nil
			}
			call.name, call.rooted = "keys", true
			return call
		case:
			if in_filter && !e.root && p.pos == start + 1 && (path_peek(p) == '+' || path_peek(p) == '-') {
				begin := p.pos
				for name_byte(path_peek(p)) {
					p.pos += 1
				}
				if !path_push(p, &e.steps, Step{kind = .Name, name = p.text[begin:p.pos]}) {
					return nil
				}
			} else {
				p.pos = before_space
			}
			return e
		}
		step := Step{}
		step_start := p.pos
		if path_take(p, ".") {
			step.descend = path_take(p, ".")
			path_space(p)
			if path_peek(p) != '[' {
				if path_take(p, "*") {
					step.kind = .Wildcard
				} else {
					name_start := p.pos
					for name_byte(path_peek(p)) {
						p.pos += 1
					}
					if p.pos == name_start {
						path_fail(p, p.pos, EXPECT_DESCENT if step.descend else EXPECT_DOT)
						return nil
					}
					step.name = p.text[name_start:p.pos]
					if !step.descend && path_peek(p) == '(' {
						return parse_call(p, step.name, in_filter, e)
					}
				}
				if !path_push(p, &e.steps, step) {
					return nil
				}
				continue
			}
		}
		if !parse_bracket(p, &step, step_start) || !path_push(p, &e.steps, step) {
			return nil
		}
	}
	return nil
}

path_quote :: proc(p: ^Path_Parser, escaped: bool) -> (string, bool) {
	quote := path_peek(p)
	if quote != '\'' && quote != '"' {
		return "", false
	}
	p.pos += 1
	start := p.pos
	b: Buffer
	buffer_init(&b, p.allocator)
	defer delete(b.bytes)
	for p.pos < len(p.text) {
		c := path_peek(p)
		p.pos += 1
		if c == quote {
			if len(b.bytes) == 0 {
				return p.text[start:p.pos-1], true
			}
			buffer_add(&b, p.text[start:p.pos-1])
			if b.error != "" {
				p.error = {message = b.error}
				return "", false
			}
			s, ok := copy_text(string(b.bytes[:]), p.allocator)
			if !ok {
				p.error = {message = OUT_OF_MEMORY}
			}
			return s, ok
		}
		if c == '\\' {
			c = path_peek(p)
			if !escaped || (c != '\\' && c != '\'' && c != '"') {
				return "", false
			}
			buffer_add(&b, p.text[start:p.pos-1])
			buffer_byte(&b, c)
			p.pos += 1
			start = p.pos
		}
	}
	return "", false
}

path_integer :: proc(p: ^Path_Parser) -> (i64, bool) {
	start := p.pos
	negative := path_take(p, "-")
	if !digit(path_peek(p)) {
		p.pos = start
		return 0, false
	}
	if path_take(p, "0") {
		return 0, true
	}
	for digit(path_peek(p)) {
		p.pos += 1
	}
	n, ok := integer_argument(p.text[start:p.pos])
	if !ok {
		return min(i64) if negative else max(i64), true
	}
	return n, true
}

parse_bracket :: proc(p: ^Path_Parser, step: ^Step, step_start: int) -> bool {
	p.pos += 1
	path_space(p)
	start := p.pos
	switch path_peek(p) {
	case '*':
		p.pos += 1
		step.kind = .Wildcard
	case '?':
		p.pos += 1
		step.kind = .Filter
		step.predicate = parse_expression(p, true, 1)
		if step.predicate == nil {
			return false
		}
		path_space(p)
		if path_peek(p) != ']' {
			path_fail(p, p.pos, "and, or")
			return false
		}
	case '\'', '"':
		name, ok := path_quote(p, true)
		if !ok {
			path_fail(p, start, EXPECT_BRACKET)
			return false
		}
		step.kind = .Name
		step.name = name
		path_space(p)
		if path_peek(p) == ',' {
			step.kind = .Names
			step.names.allocator = p.allocator
			if !path_push(p, &step.names, name) {
				return false
			}
			for path_take(p, ",") {
				path_space(p)
				n, found := path_quote(p, true)
				if !found {
					path_fail(p, start, EXPECT_BRACKET)
					return false
				}
				if !path_push(p, &step.names, n) {
					return false
				}
				path_space(p)
			}
		}
		if path_peek(p) != ']' {
			path_fail(p, start, "'<number>', ['start:end:steps']")
			return false
		}
	case '0'..='9', '-', ':':
		index, has_index := path_integer(p)
		path_space(p)
		if path_take(p, ":") {
			step.kind = .Slice
			step.start = index
			step.end, step.stride = max(i64), 1
			path_space(p)
			if end, ok := path_integer(p); ok {
				step.end = end
			}
			path_space(p)
			if path_take(p, ":") {
				path_space(p)
				if path_peek(p) != ']' {
					stride_start := p.pos
					stride, ok := path_integer(p)
					if !ok || stride < 1 {
						path_fail(p, stride_start, "pos_number")
						return false
					}
					step.stride = stride
				}
			}
			path_space(p)
			if path_peek(p) != ']' {
				path_fail(p, step_start if step_start > 1 else start, EXPECT_END if step_start > 1 else EXPECT_SLICE)
				return false
			}
		} else if has_index {
			step.kind, step.index = .Index, index
			if path_peek(p) == ',' {
				step.kind = .Indexes
				step.indexes.allocator = p.allocator
				if !path_push(p, &step.indexes, index) {
					return false
				}
				for path_take(p, ",") {
					path_space(p)
					pos := p.pos
					n, ok := path_integer(p)
					if !ok {
						path_fail(p, pos, "'<number>'")
						return false
					}
					if !path_push(p, &step.indexes, n) {
						return false
					}
					path_space(p)
				}
			}
			if path_peek(p) != ']' {
				path_fail(p, start, EXPECT_SLICE)
				return false
			}
		} else {
			path_fail(p, start, EXPECT_BRACKET)
			return false
		}
	case:
		path_fail(p, start, EXPECT_BRACKET)
		return false
	}
	path_space(p)
	if !path_take(p, "]") {
		path_fail(p, start, EXPECT_BRACKET)
		return false
	}
	return true
}

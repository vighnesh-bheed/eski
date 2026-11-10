package vfilter

import "base:runtime"
import "core:mem"
import "core:strings"

SYNTAX_ERROR_PREFIX :: "ERR syntax error in FILTER expression near: "

Op :: enum u8 {
	Push,
	Load,
	Not,
	Pow,
	Mul,
	Div,
	Mod,
	Add,
	Sub,
	Gt,
	Ge,
	Lt,
	Le,
	Eq,
	Ne,
	In,
	And,
	Or,
}

Instruction :: struct {
	op:  Op,
	arg: u32,
}

Field_Ref :: struct {
	name: string,
	hash: u32,
}

Program :: struct {
	code:      []Instruction,
	constants: []Value,
	fields:    []Field_Ref,
	items:     []Item,
	bytes:     []u8,
	depth:     int,
	constant:  bool,
	result:    bool,
}

Compile_Error :: enum u8 {
	None,
	Syntax,
	Out_Of_Memory,
}

Token_Kind :: enum u8 {
	Constant,
	Field,
	Open,
	Close,
	Operator,
}

Token :: struct {
	kind: Token_Kind,
	op:   Op,
	arg:  u32,
}

Lex_Status :: enum u8 {
	Token,
	End,
	Error,
}

Lexer :: struct {
	text:           string,
	pos:            int,
	error_at:       int,
	run_end:        int,
	prev_operand:   bool,
	filling:        bool,
	constants:      []Value,
	items:          []Item,
	fields:         []Field_Ref,
	base:           [^]u8,
	constant_count: int,
	item_count:     int,
	field_count:    int,
	token_count:    int,
	code_count:     int,
}

Stack_Entry :: struct {
	op:   Op,
	open: bool,
}

Parser :: struct {
	code:      []Instruction,
	code_len:  int,
	stack:     []Stack_Entry,
	stack_len: int,
	depth:     int,
	max_depth: int,
	broken:    bool,
}

Word_Op :: struct {
	text: string,
	kind: Token_Kind,
	op:   Op,
}

WORD_OPS := [?]Word_Op {
	{"and", .Operator, .And},
	{"not", .Operator, .Not},
	{"**", .Operator, .Pow},
	{">=", .Operator, .Ge},
	{"<=", .Operator, .Le},
	{"==", .Operator, .Eq},
	{"!=", .Operator, .Ne},
	{"&&", .Operator, .And},
	{"||", .Operator, .Or},
	{"or", .Operator, .Or},
	{"in", .Operator, .In},
	{"*", .Operator, .Mul},
	{"/", .Operator, .Div},
	{"%", .Operator, .Mod},
	{"+", .Operator, .Add},
	{"-", .Operator, .Sub},
	{">", .Operator, .Gt},
	{"<", .Operator, .Lt},
	{"!", .Operator, .Not},
	{"(", .Open, .Push},
	{")", .Close, .Push},
}

is_letter :: #force_inline proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_run_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	switch c {
	case '+', '-', '*', '/', '%', '<', '>', '=', '!', '&', '|', '(', ')':
		return true
	}
	return is_letter(c)
}

is_name_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_letter(c) || is_digit(c) || c == '_' || c == '-'
}

is_number_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_digit(c) || c == '.' || c == 'e' || c == 'E'
}

op_precedence :: proc "contextless" (op: Op) -> int {
	#partial switch op {
	case .Not:
		return 7
	case .Pow:
		return 6
	case .Mul, .Div, .Mod:
		return 5
	case .Add, .Sub:
		return 4
	case .Gt, .Ge, .Lt, .Le, .Eq, .Ne, .In:
		return 3
	case .And:
		return 2
	case .Or:
		return 1
	}
	return 0
}

op_right_associative :: #force_inline proc "contextless" (op: Op) -> bool {
	return op == .Pow
}

op_arity :: #force_inline proc "contextless" (op: Op) -> int {
	#partial switch op {
	case .Push, .Load:
		return 0
	case .Not:
		return 1
	}
	return 2
}

skip_filter_space :: #force_inline proc "contextless" (l: ^Lexer) {
	for l.pos < len(l.text) && is_c_space(l.text[l.pos]) {
		l.pos += 1
	}
}

lex_fail :: #force_inline proc "contextless" (l: ^Lexer, at: int) -> (Token, Lex_Status) {
	l.error_at = at
	return {}, .Error
}

scan_literal_string :: proc "contextless" (text: string, start: int) -> (end: int, ok: bool) {
	quote := text[start]
	i := start + 1
	for i < len(text) {
		c := text[i]
		if c == quote {
			return i, true
		}
		i += 2 if c == '\\' else 1
	}
	return len(text), false
}

scan_number_run :: proc "contextless" (text: string, start: int) -> int {
	i := start
	if i < len(text) && text[i] == '-' {
		i += 1
	}
	for i < len(text) && is_number_byte(text[i]) {
		i += 1
	}
	return i
}

push_constant :: proc(l: ^Lexer, value: Value) -> Token {
	index := l.constant_count
	if l.filling {
		l.constants[index] = value
	}
	l.constant_count += 1
	return Token{kind = .Constant, arg = u32(index)}
}

string_constant :: proc(l: ^Lexer, start, end: int) -> Value {
	if !l.filling {
		return {}
	}
	text := l.text[start:end]
	return Value{kind = .String, str = text, num = string_number(text)}
}

lex_array :: proc(l: ^Lexer) -> (token: Token, status: Lex_Status) {
	text := l.text
	i := l.pos + 1
	first := l.item_count
	for i < len(text) && is_c_space(text[i]) {
		i += 1
	}
	if i < len(text) && text[i] == ']' {
		l.pos = i + 1
		return push_constant(l, Value{kind = .Array}), .Token
	}
	for {
		for i < len(text) && is_c_space(text[i]) {
			i += 1
		}
		if i >= len(text) {
			return lex_fail(l, len(text))
		}
		item: Item
		c := text[i]
		if c == '"' || c == '\'' {
			end, closed := scan_literal_string(text, i)
			if !closed {
				return lex_fail(l, end)
			}
			item.kind = .String
			item.off = u32(i + 1)
			item.len = u32(end - i - 1)
			if l.filling {
				item.num = string_number(text[i + 1:end])
			}
			i = end + 1
		} else if is_digit(c) || c == '-' {
			end := scan_number_run(text, i)
			value, valid := run_number(text[i:end])
			if !valid {
				return lex_fail(l, end)
			}
			item.num = value
			i = end
		} else {
			return lex_fail(l, i)
		}
		if l.filling {
			l.items[l.item_count] = item
		}
		l.item_count += 1
		for i < len(text) && is_c_space(text[i]) {
			i += 1
		}
		if i >= len(text) {
			return lex_fail(l, len(text))
		}
		if text[i] == ']' {
			i += 1
			break
		}
		if text[i] != ',' {
			return lex_fail(l, i)
		}
		i += 1
		for i < len(text) && is_c_space(text[i]) {
			i += 1
		}
		if i < len(text) && text[i] == ']' {
			i += 1
			break
		}
	}
	l.pos = i
	value := Value{kind = .Array}
	if l.filling {
		value.items = l.items[first:l.item_count]
		value.base = l.base
	}
	return push_constant(l, value), .Token
}

lex_next :: proc(l: ^Lexer) -> (token: Token, status: Lex_Status) {
	skip_filter_space(l)
	text := l.text
	if l.pos >= len(text) {
		return {}, .End
	}
	start := l.pos
	c := text[start]
	next: u8 = text[start + 1] if start + 1 < len(text) else 0
	switch {
	case is_digit(c) || (c == '-' && !l.prev_operand && is_digit(next)):
		end := scan_number_run(text, start)
		value, valid := run_number(text[start:end])
		if !valid {
			return lex_fail(l, end)
		}
		l.pos = end
		return push_constant(l, number_value(value)), .Token
	case c == '"' || c == '\'':
		end, closed := scan_literal_string(text, start)
		if !closed {
			return lex_fail(l, end)
		}
		l.pos = end + 1
		return push_constant(l, string_constant(l, start + 1, end)), .Token
	case c == '[':
		return lex_array(l)
	case c == '.':
		end := start + 1
		for end < len(text) && is_name_byte(text[end]) {
			end += 1
		}
		if end == start + 1 && end < len(text) {
			return lex_fail(l, start)
		}
		l.pos = end
		index := l.field_count
		if l.filling {
			name := text[start + 1:end]
			l.fields[index] = Field_Ref{name = name, hash = name_hash(name)}
		}
		l.field_count += 1
		return Token{kind = .Field, arg = u32(index)}, .Token
	case is_run_byte(c):
		end := l.run_end
		if start >= end {
			end = start
			for end < len(text) && is_run_byte(text[end]) {
				end += 1
			}
			l.run_end = end
		}
		run := text[start:end]
		if run == "null" {
			l.pos = end
			return push_constant(l, Value{kind = .Null}), .Token
		}
		for word in WORD_OPS {
			if strings.has_prefix(run, word.text) {
				l.pos = start + len(word.text)
				return Token{kind = word.kind, op = word.op}, .Token
			}
		}
		return lex_fail(l, end)
	}
	return lex_fail(l, start)
}

lex_step :: proc(l: ^Lexer) -> (token: Token, status: Lex_Status) {
	token, status = lex_next(l)
	if status == .Token {
		l.token_count += 1
		if token.kind == .Constant || token.kind == .Field || token.kind == .Operator {
			l.code_count += 1
		}
		l.prev_operand = token.kind == .Constant || token.kind == .Field || token.kind == .Close
	}
	return
}

parser_emit :: proc(p: ^Parser, instruction: Instruction) {
	arity := op_arity(instruction.op)
	if p.depth < arity {
		p.broken = true
	}
	p.code[p.code_len] = instruction
	p.code_len += 1
	p.depth += 1 - arity
	p.max_depth = max(p.max_depth, p.depth)
}

parser_feed :: proc(p: ^Parser, token: Token) -> bool {
	switch token.kind {
	case .Constant:
		parser_emit(p, Instruction{op = .Push, arg = token.arg})
	case .Field:
		parser_emit(p, Instruction{op = .Load, arg = token.arg})
	case .Open:
		p.stack[p.stack_len] = Stack_Entry{open = true}
		p.stack_len += 1
	case .Close:
		for {
			if p.stack_len == 0 {
				return false
			}
			p.stack_len -= 1
			entry := p.stack[p.stack_len]
			if entry.open {
				break
			}
			parser_emit(p, Instruction{op = entry.op})
		}
	case .Operator:
		precedence := op_precedence(token.op)
		right := op_right_associative(token.op)
		for p.stack_len > 0 {
			top := p.stack[p.stack_len - 1]
			if top.open {
				break
			}
			top_precedence := op_precedence(top.op)
			if top_precedence < precedence || (top_precedence == precedence && right) {
				break
			}
			parser_emit(p, Instruction{op = top.op})
			p.stack_len -= 1
		}
		p.stack[p.stack_len] = Stack_Entry{op = token.op}
		p.stack_len += 1
	}
	return true
}

parser_finish :: proc(p: ^Parser) -> bool {
	for p.stack_len > 0 {
		p.stack_len -= 1
		entry := p.stack[p.stack_len]
		if entry.open {
			return false
		}
		parser_emit(p, Instruction{op = entry.op})
	}
	return !p.broken && p.depth == 1
}

program_destroy :: proc(program: ^Program, allocator := context.allocator) {
	delete(program.code, allocator)
	delete(program.constants, allocator)
	delete(program.fields, allocator)
	delete(program.items, allocator)
	delete(program.bytes, allocator)
	program^ = {}
}

program_allocate :: proc(program: ^Program, l: ^Lexer, allocator: runtime.Allocator) -> mem.Allocator_Error {
	program.code = make([]Instruction, l.code_count, allocator) or_return
	program.constants = make([]Value, l.constant_count, allocator) or_return
	program.fields = make([]Field_Ref, l.field_count, allocator) or_return
	program.items = make([]Item, l.item_count, allocator) or_return
	program.bytes = make([]u8, len(l.text), allocator) or_return
	return nil
}

effective_text :: proc "contextless" (expression: string) -> string {
	for i in 0 ..< len(expression) {
		if expression[i] == 0 {
			return expression[:i]
		}
	}
	return expression
}

near_text :: proc "contextless" (expression, effective: string, at: int) -> string {
	if at >= len(expression) {
		return effective
	}
	return effective[at:]
}

compile :: proc(expression: string, allocator := context.allocator) -> (program: Program, near: string, err: Compile_Error) {
	effective := effective_text(expression)
	counter := Lexer{text = effective}
	for {
		_, status := lex_step(&counter)
		if status == .End {
			break
		}
		if status == .Error {
			return {}, near_text(expression, effective, counter.error_at), .Syntax
		}
	}
	if program_allocate(&program, &counter, allocator) != nil {
		program_destroy(&program, allocator)
		return {}, "", .Out_Of_Memory
	}
	stack, stack_err := make([]Stack_Entry, counter.token_count, allocator)
	if stack_err != nil {
		program_destroy(&program, allocator)
		return {}, "", .Out_Of_Memory
	}
	defer delete(stack, allocator)
	copy(program.bytes, effective)
	filler := Lexer {
		text      = string(program.bytes),
		filling   = true,
		constants = program.constants,
		items     = program.items,
		fields    = program.fields,
		base      = raw_data(program.bytes),
	}
	parser := Parser {
		code  = program.code,
		stack = stack,
	}
	for {
		token, status := lex_step(&filler)
		if status != .Token {
			break
		}
		if !parser_feed(&parser, token) {
			program_destroy(&program, allocator)
			return {}, effective, .Syntax
		}
	}
	if !parser_finish(&parser) {
		program_destroy(&program, allocator)
		return {}, effective, .Syntax
	}
	program.depth = parser.max_depth
	program.constant = len(program.fields) == 0
	if program.constant {
		program.result = program_run_constant(&program)
	}
	return program, "", .None
}

reply_near :: proc "contextless" (near: string) -> string {
	end := len(near)
	for end > 0 && (near[end - 1] == '\r' || near[end - 1] == '\n') {
		end -= 1
	}
	return near[:end]
}

error_text :: proc(near: string, allocator := context.allocator) -> (text: string, err: mem.Allocator_Error) {
	trimmed := reply_near(near)
	buffer := make([]u8, len(SYNTAX_ERROR_PREFIX) + len(trimmed), allocator) or_return
	copy(buffer, SYNTAX_ERROR_PREFIX)
	copy(buffer[len(SYNTAX_ERROR_PREFIX):], trimmed)
	for &c in buffer {
		if c == '\r' || c == '\n' {
			c = ' '
		}
	}
	return string(buffer), nil
}

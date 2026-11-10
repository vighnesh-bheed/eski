package vsetargs

import "base:runtime"

MAX_DIM :: 65536
DEFAULT_COUNT :: 10
DEFAULT_M :: 16
DEFAULT_BUILD_EF :: 200
EF_MAX :: 1_000_000
M_MIN :: 4
M_MAX :: 4096

Command :: enum u8 {
	Vadd,
	Vcard,
	Vdim,
	Vemb,
	Vgetattr,
	Vinfo,
	Vismember,
	Vlinks,
	Vrandmember,
	Vrange,
	Vrem,
	Vsetattr,
	Vsim,
}

Error_Kind :: enum u8 {
	None,
	Arity,
	Vector_Spec,
	Option_After_Element,
	Ef,
	M,
	Count,
	Epsilon,
	Filter_Ef,
	Vsim_Syntax,
	Filter_Syntax,
	Filter_Memory,
	Option,
	Count_Not_Integer,
	Start_Range,
	End_Range,
	Infinity_Order,
	Count_Value,
	Memory,
}

Stage :: enum u8 {
	Before_Key,
	After_Key,
	After_Query,
}

Error :: struct {
	kind:  Error_Kind,
	stage: Stage,
	text:  string,
	near:  string,
}

ERR_VECTOR_SPEC :: "ERR invalid vector specification"
ERR_OPTION_AFTER_ELEMENT :: "ERR invalid option after element"
ERR_EF :: "ERR invalid EF"
ERR_M :: "ERR invalid M"
ERR_COUNT :: "ERR invalid COUNT"
ERR_EPSILON :: "ERR invalid EPSILON"
ERR_FILTER_EF :: "ERR invalid FILTER-EF"
ERR_VSIM_SYNTAX :: "ERR syntax error in VSIM command"
ERR_FILTER_MEMORY :: "OOM not enough memory to compile the FILTER expression"
ERR_OPTION :: "ERR invalid option"
ERR_COUNT_NOT_INTEGER :: "ERR COUNT value is not an integer"
ERR_START_RANGE :: "ERR invalid start range format"
ERR_END_RANGE :: "ERR invalid end range format"
ERR_INFINITY_ORDER :: "ERR '-' can only be used as first argument, '+' only as second"
ERR_COUNT_VALUE :: "ERR invalid COUNT value"
ERR_MEMORY :: "OOM not enough memory to hold the vector"

@(rodata)
ARITY_TEXTS := [Command]string {
	.Vadd        = "ERR wrong number of arguments for 'VADD' command",
	.Vcard       = "ERR wrong number of arguments for 'VCARD' command",
	.Vdim        = "ERR wrong number of arguments for 'VDIM' command",
	.Vemb        = "ERR wrong number of arguments for 'VEMB' command",
	.Vgetattr    = "ERR wrong number of arguments for 'VGETATTR' command",
	.Vinfo       = "ERR wrong number of arguments for 'VINFO' command",
	.Vismember   = "ERR wrong number of arguments for 'VISMEMBER' command",
	.Vlinks      = "ERR wrong number of arguments for 'VLINKS' command",
	.Vrandmember = "ERR wrong number of arguments for 'VRANDMEMBER' command",
	.Vrange      = "ERR wrong number of arguments for 'VRANGE' command",
	.Vrem        = "ERR wrong number of arguments for 'VREM' command",
	.Vsetattr    = "ERR wrong number of arguments for 'VSETATTR' command",
	.Vsim        = "ERR wrong number of arguments for 'VSIM' command",
}

Key_Request :: struct {
	key: []u8,
}

Element_Request :: struct {
	key:     []u8,
	element: []u8,
}

Vsetattr_Request :: struct {
	key:        []u8,
	element:    []u8,
	attributes: []u8,
}

Vemb_Request :: struct {
	key:     []u8,
	element: []u8,
	raw:     bool,
}

Vlinks_Request :: struct {
	key:         []u8,
	element:     []u8,
	with_scores: bool,
}

Vrandmember_Request :: struct {
	key:       []u8,
	count:     i64,
	has_count: bool,
}

Bound_Kind :: enum u8 {
	Min,
	Max,
	Inclusive,
	Exclusive,
}

Lex_Bound :: struct {
	kind:  Bound_Kind,
	value: []u8,
}

Vrange_Request :: struct {
	key:       []u8,
	start:     Lex_Bound,
	end:       Lex_Bound,
	count:     i64,
	has_count: bool,
}

fail :: #force_inline proc "contextless" (kind: Error_Kind, text: string, stage := Stage.Before_Key) -> Error {
	return Error{kind = kind, stage = stage, text = text}
}

arity_error :: #force_inline proc "contextless" (cmd: Command) -> Error {
	return Error{kind = .Arity, stage = .Before_Key, text = ARITY_TEXTS[cmd]}
}

memory_error :: #force_inline proc "contextless" () -> Error {
	return Error{kind = .Memory, stage = .Before_Key, text = ERR_MEMORY}
}

arity_ok :: proc "contextless" (cmd: Command, argc: int) -> bool {
	arity := int(COMMAND_SPECS[cmd].arity)
	return (arity > 0 && argc == arity) || (arity < 0 && argc >= -arity)
}

token_is :: proc "contextless" (arg: []u8, token: string) -> bool {
	if len(arg) < len(token) {
		return false
	}
	for i in 0 ..< len(token) {
		c := arg[i]
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		if c != token[i] {
			return false
		}
	}
	return len(arg) == len(token) || arg[len(token)] == 0
}

error_length :: proc "contextless" (err: Error) -> int {
	n := 0
	for part in ([2]string{err.text, err.near}) {
		for i in 0 ..< len(part) {
			if part[i] == 0 {
				return n
			}
			n += 1
		}
	}
	return n
}

error_write :: proc "contextless" (err: Error, out: []u8) -> int {
	n := 0
	for part in ([2]string{err.text, err.near}) {
		for i in 0 ..< len(part) {
			c := part[i]
			if c == 0 || n >= len(out) {
				return n
			}
			if c == '\r' || c == '\n' {
				c = ' '
			}
			out[n] = c
			n += 1
		}
	}
	return n
}

error_string :: proc(err: Error, allocator := context.allocator) -> (text: string, alloc_err: runtime.Allocator_Error) {
	buffer := make([]u8, error_length(err), allocator) or_return
	error_write(err, buffer)
	return string(buffer), nil
}

parse_vrem :: proc "contextless" (args: [][]u8) -> (req: Element_Request, err: Error) {
	return parse_element_command(.Vrem, args)
}

parse_vgetattr :: proc "contextless" (args: [][]u8) -> (req: Element_Request, err: Error) {
	return parse_element_command(.Vgetattr, args)
}

parse_vismember :: proc "contextless" (args: [][]u8) -> (req: Element_Request, err: Error) {
	return parse_element_command(.Vismember, args)
}

parse_vcard :: proc "contextless" (args: [][]u8) -> (req: Key_Request, err: Error) {
	return parse_key_command(.Vcard, args)
}

parse_vdim :: proc "contextless" (args: [][]u8) -> (req: Key_Request, err: Error) {
	return parse_key_command(.Vdim, args)
}

parse_vinfo :: proc "contextless" (args: [][]u8) -> (req: Key_Request, err: Error) {
	return parse_key_command(.Vinfo, args)
}

parse_key_command :: proc "contextless" (cmd: Command, args: [][]u8) -> (req: Key_Request, err: Error) {
	if !arity_ok(cmd, len(args) + 1) {
		return req, arity_error(cmd)
	}
	req.key = args[0]
	return
}

parse_element_command :: proc "contextless" (cmd: Command, args: [][]u8) -> (req: Element_Request, err: Error) {
	if !arity_ok(cmd, len(args) + 1) {
		return req, arity_error(cmd)
	}
	req.key = args[0]
	req.element = args[1]
	return
}

parse_vsetattr :: proc "contextless" (args: [][]u8) -> (req: Vsetattr_Request, err: Error) {
	if !arity_ok(.Vsetattr, len(args) + 1) {
		return req, arity_error(.Vsetattr)
	}
	req.key = args[0]
	req.element = args[1]
	req.attributes = args[2]
	return
}

parse_vemb :: proc "contextless" (args: [][]u8) -> (req: Vemb_Request, err: Error) {
	if !arity_ok(.Vemb, len(args) + 1) {
		return req, arity_error(.Vemb)
	}
	req.key = args[0]
	req.element = args[1]
	for option in args[2:] {
		if !token_is(option, "RAW") {
			return req, fail(.Option, ERR_OPTION)
		}
		req.raw = true
	}
	return
}

parse_vlinks :: proc "contextless" (args: [][]u8) -> (req: Vlinks_Request, err: Error) {
	if !arity_ok(.Vlinks, len(args) + 1) || len(args) > 3 {
		return req, arity_error(.Vlinks)
	}
	req.key = args[0]
	req.element = args[1]
	if len(args) == 3 {
		if !token_is(args[2], "WITHSCORES") {
			return req, arity_error(.Vlinks)
		}
		req.with_scores = true
	}
	return
}

parse_vrandmember :: proc "contextless" (args: [][]u8) -> (req: Vrandmember_Request, err: Error) {
	if !arity_ok(.Vrandmember, len(args) + 1) || len(args) > 2 {
		return req, arity_error(.Vrandmember)
	}
	req.key = args[0]
	if len(args) == 2 {
		count, ok := parse_i64(args[1])
		if !ok {
			return req, fail(.Count_Not_Integer, ERR_COUNT_NOT_INTEGER)
		}
		req.count = count
		req.has_count = true
	}
	return
}

parse_vrange :: proc "contextless" (args: [][]u8) -> (req: Vrange_Request, err: Error) {
	if !arity_ok(.Vrange, len(args) + 1) || len(args) > 4 {
		return req, arity_error(.Vrange)
	}
	req.key = args[0]
	if len(args) == 4 {
		count, ok := parse_i64(args[3])
		if !ok {
			return req, fail(.Count_Value, ERR_COUNT_VALUE)
		}
		req.count = count
		req.has_count = true
	}
	start, start_ok := parse_bound(args[1])
	if !start_ok {
		return req, fail(.Start_Range, ERR_START_RANGE)
	}
	end, end_ok := parse_bound(args[2])
	if !end_ok {
		return req, fail(.End_Range, ERR_END_RANGE)
	}
	if start.kind == .Max || end.kind == .Min {
		return req, fail(.Infinity_Order, ERR_INFINITY_ORDER)
	}
	req.start = start
	req.end = end
	return
}

parse_bound :: proc "contextless" (arg: []u8) -> (bound: Lex_Bound, ok: bool) {
	if len(arg) == 1 {
		switch arg[0] {
		case '-':
			return Lex_Bound{kind = .Min}, true
		case '+':
			return Lex_Bound{kind = .Max}, true
		}
		return
	}
	if len(arg) < 2 {
		return
	}
	switch arg[0] {
	case '[':
		return Lex_Bound{kind = .Inclusive, value = arg[1:]}, true
	case '(':
		return Lex_Bound{kind = .Exclusive, value = arg[1:]}, true
	}
	return
}

vrange_limit :: proc "contextless" (req: ^Vrange_Request) -> (limit: i64, limited: bool) {
	if !req.has_count || req.count < 0 {
		return 0, false
	}
	return req.count, true
}

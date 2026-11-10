package vsetargs

import "base:runtime"
import "../vfilter"

Query_Kind :: enum u8 {
	Element,
	Vector,
}

Vsim_Request :: struct {
	key:          []u8,
	query:        Query_Kind,
	element:      []u8,
	vector:       []f32,
	count:        i64,
	ef:           i64,
	epsilon:      f64,
	has_filter:   bool,
	filter:       vfilter.Program,
	filter_text:  []u8,
	filter_ef:    i64,
	with_scores:  bool,
	with_attribs: bool,
	truth:        bool,
	nothread:     bool,
	allocator:    runtime.Allocator,
}

parse_vsim :: proc(args: [][]u8, allocator := context.allocator) -> (req: Vsim_Request, err: Error) {
	req.allocator = allocator
	req.count = DEFAULT_COUNT
	if len(args) > 0 {
		req.key = args[0]
	}
	if !arity_ok(.Vsim, len(args) + 1) {
		return req, arity_error(.Vsim)
	}
	at: int
	if token_is(args[1], "ELE") {
		req.query = .Element
		req.element = args[2]
		at = 3
	} else {
		vector, next, vector_err := parse_vector(args, 1, allocator)
		if vector_err.kind != .None {
			if vector_err.kind == .Vector_Spec {
				vector_err.stage = .After_Key
			}
			return req, vector_err
		}
		req.query = .Vector
		req.vector = vector
		at = next
	}
	for j := at; j < len(args); j += 1 {
		option := args[j]
		more := j + 1 < len(args)
		switch {
		case token_is(option, "WITHSCORES"):
			req.with_scores = true
		case token_is(option, "WITHATTRIBS"):
			req.with_attribs = true
		case token_is(option, "TRUTH"):
			req.truth = true
		case token_is(option, "NOTHREAD"):
			req.nothread = true
		case token_is(option, "COUNT") && more:
			j += 1
			value, ok := parse_i64(args[j])
			if !ok || value <= 0 {
				return req, option_error(&req, .Count, ERR_COUNT)
			}
			req.count = value
		case token_is(option, "EPSILON") && more:
			j += 1
			value, ok := parse_double(args[j])
			if !ok || value <= 0 {
				return req, option_error(&req, .Epsilon, ERR_EPSILON)
			}
			req.epsilon = value
		case token_is(option, "EF") && more:
			j += 1
			value, ok := parse_i64(args[j])
			if !ok || value <= 0 || value > EF_MAX {
				return req, option_error(&req, .Ef, ERR_EF)
			}
			req.ef = value
		case token_is(option, "FILTER") && more:
			j += 1
			program, near, compile_err := vfilter.compile(string(args[j]), allocator)
			switch compile_err {
			case .None:
				drop_filter(&req)
				req.filter = program
				req.filter_text = args[j]
				req.has_filter = true
			case .Syntax:
				drop_filter(&req)
				return req, Error{kind = .Filter_Syntax, stage = .After_Query, text = vfilter.SYNTAX_ERROR_PREFIX, near = vfilter.reply_near(near)}
			case .Out_Of_Memory:
				return req, option_error(&req, .Filter_Memory, ERR_FILTER_MEMORY)
			}
		case token_is(option, "FILTER-EF") && more:
			j += 1
			value, ok := parse_i64(args[j])
			if !ok || value <= 0 {
				return req, option_error(&req, .Filter_Ef, ERR_FILTER_EF)
			}
			req.filter_ef = value
		case:
			return req, option_error(&req, .Vsim_Syntax, ERR_VSIM_SYNTAX)
		}
	}
	return req, {}
}

option_error :: proc(req: ^Vsim_Request, kind: Error_Kind, text: string) -> Error {
	drop_filter(req)
	return fail(kind, text, .After_Query)
}

drop_filter :: proc(req: ^Vsim_Request) {
	if req.has_filter {
		vfilter.program_destroy(&req.filter, req.allocator)
		req.has_filter = false
		req.filter_text = nil
	}
}

vsim_request_destroy :: proc(req: ^Vsim_Request) {
	drop_filter(req)
	if req.vector != nil {
		delete(req.vector, req.allocator)
	}
	allocator := req.allocator
	req^ = {}
	req.allocator = allocator
}

vsim_filter_ef :: proc "contextless" (req: ^Vsim_Request) -> i64 {
	if req.filter_ef > 0 {
		return req.filter_ef
	}
	if req.count > max(i64) / 100 {
		return max(i64)
	}
	return req.count * 100
}

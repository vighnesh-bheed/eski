package vsetargs

import "base:runtime"

Quant :: enum u8 {
	Q8,
	Noquant,
	Bin,
}

Vadd_Request :: struct {
	key:            []u8,
	element:        []u8,
	vector:         []f32,
	reduce:         u32,
	quant:          Quant,
	m:              i64,
	ef:             i64,
	cas:            bool,
	set_attributes: bool,
	attributes:     []u8,
	allocator:      runtime.Allocator,
}

parse_vector :: proc(args: [][]u8, at: int, allocator: runtime.Allocator) -> (vector: []f32, next: int, err: Error) {
	if at + 1 >= len(args) {
		return nil, at, fail(.Vector_Spec, ERR_VECTOR_SPEC)
	}
	form := args[at]
	switch {
	case token_is(form, "FP32"):
		blob := args[at + 1]
		if len(blob) == 0 || len(blob) % 4 != 0 || len(blob) / 4 > MAX_DIM {
			return nil, at, fail(.Vector_Spec, ERR_VECTOR_SPEC)
		}
		made, alloc_err := make([]f32, len(blob) / 4, allocator)
		if alloc_err != nil {
			return nil, at, memory_error()
		}
		for &component, i in made {
			bits := u32(blob[4 * i]) | u32(blob[4 * i + 1]) << 8 | u32(blob[4 * i + 2]) << 16 | u32(blob[4 * i + 3]) << 24
			component = transmute(f32)bits
		}
		return made, at + 2, {}
	case token_is(form, "VALUES"):
		count, ok := parse_i64(args[at + 1])
		if !ok || count <= 0 || count > MAX_DIM || count > i64(len(args) - at - 2) {
			return nil, at, fail(.Vector_Spec, ERR_VECTOR_SPEC)
		}
		made, alloc_err := make([]f32, int(count), allocator)
		if alloc_err != nil {
			return nil, at, memory_error()
		}
		for &component, i in made {
			value, good := parse_double(args[at + 2 + i])
			if !good {
				delete(made, allocator)
				return nil, at, fail(.Vector_Spec, ERR_VECTOR_SPEC)
			}
			component = f32(value)
		}
		return made, at + 2 + int(count), {}
	}
	return nil, at, fail(.Vector_Spec, ERR_VECTOR_SPEC)
}

parse_vadd :: proc(args: [][]u8, allocator := context.allocator) -> (req: Vadd_Request, err: Error) {
	req.allocator = allocator
	req.m = DEFAULT_M
	req.ef = DEFAULT_BUILD_EF
	if !arity_ok(.Vadd, len(args) + 1) {
		return req, arity_error(.Vadd)
	}
	req.key = args[0]
	at := 1
	reduce: i64
	if token_is(args[at], "REDUCE") {
		value, ok := parse_i64(args[at + 1])
		if !ok || value <= 0 {
			return req, fail(.Vector_Spec, ERR_VECTOR_SPEC)
		}
		reduce = value
		at += 2
	}
	vector, next, vector_err := parse_vector(args, at, allocator)
	if vector_err.kind != .None {
		return req, vector_err
	}
	req.vector = vector
	if reduce != 0 {
		truncated := u32(reduce)
		if int(truncated) > len(vector) {
			vadd_request_destroy(&req)
			return req, fail(.Vector_Spec, ERR_VECTOR_SPEC)
		}
		req.reduce = truncated
	}
	if next >= len(args) {
		vadd_request_destroy(&req)
		return req, arity_error(.Vadd)
	}
	req.element = args[next]
	for j := next + 1; j < len(args); j += 1 {
		option := args[j]
		more := j + 1 < len(args)
		switch {
		case token_is(option, "CAS"):
			req.cas = true
		case token_is(option, "NOQUANT"):
			req.quant = .Noquant
		case token_is(option, "Q8"):
			req.quant = .Q8
		case token_is(option, "BIN"):
			req.quant = .Bin
		case token_is(option, "EF") && more:
			j += 1
			value, ok := parse_i64(args[j])
			if !ok || value <= 0 || value > EF_MAX {
				vadd_request_destroy(&req)
				return req, fail(.Ef, ERR_EF)
			}
			req.ef = value
		case token_is(option, "SETATTR") && more:
			j += 1
			req.attributes = args[j]
			req.set_attributes = true
		case token_is(option, "M") && more:
			j += 1
			value, ok := parse_i64(args[j])
			if !ok || value < M_MIN || value > M_MAX {
				vadd_request_destroy(&req)
				return req, fail(.M, ERR_M)
			}
			req.m = value
		case:
			vadd_request_destroy(&req)
			return req, fail(.Option_After_Element, ERR_OPTION_AFTER_ELEMENT)
		}
	}
	return req, {}
}

vadd_request_destroy :: proc(req: ^Vadd_Request) {
	if req.vector != nil {
		delete(req.vector, req.allocator)
	}
	allocator := req.allocator
	req^ = {}
	req.allocator = allocator
}

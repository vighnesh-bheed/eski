package vsetargs

import "core:testing"

values_args :: proc(prefix: []string, count: int, component: string, suffix: []string, allocator := context.temp_allocator) -> [][]u8 {
	out := make([dynamic][]u8, 0, len(prefix) + count + len(suffix) + 2, allocator)
	for arg in prefix {
		append(&out, transmute([]u8)arg)
	}
	for _ in 0 ..< count {
		append(&out, transmute([]u8)component)
	}
	for arg in suffix {
		append(&out, transmute([]u8)arg)
	}
	return out[:]
}

@(test)
dimension_limit_is_65536 :: proc(t: ^testing.T) {
	accepted, err := parse_vadd(values_args({"k", "VALUES", "65536"}, MAX_DIM, "1", {"e"}))
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect_value(t, len(accepted.vector), MAX_DIM)
	vadd_request_destroy(&accepted)
	over, over_err := parse_vadd(values_args({"k", "VALUES", "65537"}, MAX_DIM + 1, "1", {"e"}))
	testing.expect_value(t, over_err.kind, Error_Kind.Vector_Spec)
	vadd_request_destroy(&over)
	blob := make([]u8, 4 * MAX_DIM, context.temp_allocator)
	fp32, fp32_err := parse_vadd({transmute([]u8)string("k"), transmute([]u8)string("FP32"), blob, transmute([]u8)string("e")})
	testing.expect_value(t, fp32_err.kind, Error_Kind.None)
	testing.expect_value(t, len(fp32.vector), MAX_DIM)
	vadd_request_destroy(&fp32)
	long_blob := make([]u8, 4 * MAX_DIM + 4, context.temp_allocator)
	long, long_err := parse_vadd({transmute([]u8)string("k"), transmute([]u8)string("FP32"), long_blob, transmute([]u8)string("e")})
	testing.expect_value(t, long_err.kind, Error_Kind.Vector_Spec)
	vadd_request_destroy(&long)
	query, query_err := parse_vsim(values_args({"k", "VALUES", "65537"}, MAX_DIM + 1, "1", {"COUNT", "1"}))
	testing.expect_value(t, query_err.kind, Error_Kind.Vector_Spec)
	testing.expect_value(t, query_err.stage, Stage.After_Key)
	vsim_request_destroy(&query)
	reduce, reduce_err := parse_vadd({transmute([]u8)string("k"), transmute([]u8)string("REDUCE"), transmute([]u8)string("65537"), transmute([]u8)string("FP32"), blob, transmute([]u8)string("e")})
	testing.expect_value(t, reduce_err.kind, Error_Kind.Vector_Spec)
	vadd_request_destroy(&reduce)
	free_all(context.temp_allocator)
}

@(test)
reduce_keeps_the_low_32_bits :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:   string,
		reduce: u32,
		ok:     bool,
	} {
		{"1", 1, true},
		{"2", 2, true},
		{"3", 0, false},
		{"4294967297", 1, true},
		{"4294967298", 2, true},
		{"4294967299", 0, false},
		{"4294967296", 0, true},
		{"8589934593", 1, true},
		{"2147483648", 0, false},
		{"2147483649", 0, false},
		{"9223372036854775807", 0, false},
		{"-4294967295", 0, false},
		{"0", 0, false},
	}
	for c in cases {
		req, err := parse_vadd(as_args({"k", "REDUCE", c.text, "VALUES", "2", "1", "0", "e"}))
		testing.expectf(t, (err.kind == .None) == c.ok, "REDUCE %s: %v", c.text, err.kind)
		if c.ok {
			testing.expectf(t, req.reduce == c.reduce, "REDUCE %s kept %d", c.text, req.reduce)
		} else {
			testing.expect_value(t, err.text, ERR_VECTOR_SPEC)
		}
		vadd_request_destroy(&req)
	}
	free_all(context.temp_allocator)
}

@(test)
vsim_stages_order_the_replies :: proc(t: ^testing.T) {
	cases := [?]struct {
		args:  []string,
		kind:  Error_Kind,
		stage: Stage,
	} {
		{{"k", "BOGUS", "a"}, .Vector_Spec, .After_Key},
		{{"k", "VALUES", "2", "1", "x"}, .Vector_Spec, .After_Key},
		{{"k", "FP32", "abc"}, .Vector_Spec, .After_Key},
		{{"k", "ELE", "a", "COUNT", "0"}, .Count, .After_Query},
		{{"k", "VALUES", "1", "1", "FILTER", ".n >"}, .Filter_Syntax, .After_Query},
		{{"k", "ELE", "a", "BOGUS"}, .Vsim_Syntax, .After_Query},
		{{"k", "ELE"}, .Arity, .Before_Key},
	}
	for c in cases {
		req, err := parse_vsim(as_args(c.args))
		testing.expectf(t, err.kind == c.kind && err.stage == c.stage, "%q: %v at %v", c.args, err.kind, err.stage)
		if err.stage == .After_Query {
			testing.expectf(t, req.element != nil || req.vector != nil, "%q lost its query", c.args)
		}
		vsim_request_destroy(&req)
	}
	filter, filter_err := parse_vsim(as_args({"k", "ELE", "a", "FILTER", "(1\r\n == 1"}))
	text, _ := error_string(filter_err, context.temp_allocator)
	testing.expect_value(t, text, "ERR syntax error in FILTER expression near: (1   == 1")
	vsim_request_destroy(&filter)
	last, last_err := parse_vsim(as_args({"k", "ELE", "a", "FILTER", ".n > 1", "FILTER", ".n > 2", "FILTER-EF", "7"}))
	testing.expect_value(t, last_err.kind, Error_Kind.None)
	testing.expect(t, last.has_filter && string(last.filter_text) == ".n > 2" && last.filter_ef == 7 && vsim_filter_ef(&last) == 7)
	vsim_request_destroy(&last)
	plain, _ := parse_vsim(as_args({"k", "ELE", "a", "COUNT", "3"}))
	testing.expect_value(t, vsim_filter_ef(&plain), 300)
	vsim_request_destroy(&plain)
	free_all(context.temp_allocator)
}

@(test)
vrange_bounds_and_limits :: proc(t: ^testing.T) {
	req, err := parse_vrange(as_args({"k", "[a\x00", "(z", "-5"}))
	testing.expect_value(t, err.kind, Error_Kind.None)
	testing.expect(t, req.start.kind == .Inclusive && string(req.start.value) == "a\x00")
	testing.expect(t, req.end.kind == .Exclusive && string(req.end.value) == "z")
	_, limited := vrange_limit(&req)
	testing.expect(t, !limited)
	zero, _ := parse_vrange(as_args({"k", "-", "+", "0"}))
	limit, zero_limited := vrange_limit(&zero)
	testing.expect(t, zero_limited && limit == 0 && zero.start.kind == .Min && zero.end.kind == .Max)
	open, _ := parse_vrange(as_args({"k", "-", "+"}))
	_, open_limited := vrange_limit(&open)
	testing.expect(t, !open_limited)
	free_all(context.temp_allocator)
}

@(test)
attributes_distinguish_empty_from_absent :: proc(t: ^testing.T) {
	empty, _ := parse_vadd(as_args({"k", "VALUES", "1", "5", "e", "SETATTR", ""}))
	testing.expect(t, empty.set_attributes && len(empty.attributes) == 0)
	vadd_request_destroy(&empty)
	absent, _ := parse_vadd(as_args({"k", "VALUES", "1", "5", "e"}))
	testing.expect(t, !absent.set_attributes)
	vadd_request_destroy(&absent)
	twice, _ := parse_vadd(as_args({"k", "VALUES", "1", "5", "e", "SETATTR", "x", "SETATTR", ""}))
	testing.expect(t, twice.set_attributes && len(twice.attributes) == 0)
	vadd_request_destroy(&twice)
	free_all(context.temp_allocator)
}

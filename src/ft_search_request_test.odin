package main

import "core:mem"
import "core:testing"

search_test_args :: proc(args: ..string) -> [][]u8 {
	slices := make([][]u8, len(args), context.temp_allocator)
	for arg, i in args {
		slices[i] = transmute([]u8)arg
	}
	return slices
}

@(test)
search_request_baseline_options :: proc(t: ^testing.T) {
	defaults, err := search_request_parse(nil)
	testing.expect_value(t, err, "")
	testing.expect_value(t, defaults.query_options.dialect, 1)
	testing.expect_value(t, defaults.offset, 0)
	testing.expect_value(t, defaults.count, 10)
	testing.expect(t, defaults.timeout_ms == nil)
	testing.expect(t, defaults.execute_options.slop == nil)
	testing.expect(t, !defaults.has_in_keys && !defaults.has_return && !defaults.has_sort)

	raw := "\x00\x00\x80?\x00\x00\x80?"
	args := search_test_args(
		"inorder", "SCORER", "BM25STD", "WITHSCORES", "WITHSORTKEYS", "RETURN", "4", "year", "as", "y", "dist",
		"SORTBY", "dist", "dEsC", "WITHCOUNT", "DIALECT", "+02", "LIMIT", "0", "04", "params", "4", "vector", raw, "k", "4",
		"verbatim", "NOSTOPWORDS", "LANGUAGE", "EnGLIsH", "SLOP", "-2", "TIMEOUT", "0", "INKEYS", "2", "a\x00b", "a", "INFIELDS", "1", "Title",
	)
	req, error := search_request_parse(args)
	testing.expect_value(t, error, "")
	testing.expect(t, req.execute_options.in_order && req.with_scores && req.with_sort_keys && req.with_count)
	testing.expect(t, req.query_options.verbatim && req.query_options.no_stop_words)
	testing.expect_value(t, req.query_options.language, "english")
	testing.expect_value(t, req.query_options.dialect, 2)
	testing.expect_value(t, req.execute_options.slop.? or_else -1, -2)
	testing.expect_value(t, req.timeout_ms.? or_else -1, i64(0))
	testing.expect_value(t, req.offset, 0)
	testing.expect_value(t, req.count, 4)
	testing.expect(t, req.has_sort && req.sort_desc)
	testing.expect_value(t, req.sort_by, "dist")
	testing.expect(t, req.has_return && !req.no_content)
	testing.expect_value(t, len(req.return_fields), 2)
	testing.expect_value(t, len(req.query_options.params), 2)
	testing.expect_value(t, len(req.in_fields), 1)
	testing.expect(t, req.has_in_keys)
	testing.expect_value(t, len(req.in_keys), 2)
	if len(req.return_fields) == 2 {
		testing.expect_value(t, req.return_fields[0], Search_Return_Field{"year", "y"})
		testing.expect_value(t, req.return_fields[1], Search_Return_Field{"dist", "dist"})
	}
	if len(req.query_options.params) == 2 {
		testing.expect_value(t, req.query_options.params[0].name, "vector")
		testing.expect_value(t, req.query_options.params[0].value, raw)
		testing.expect_value(t, req.query_options.params[1].name, "k")
		testing.expect_value(t, req.query_options.params[1].value, "4")
		testing.expect(t, raw_data(transmute([]u8)req.query_options.params[0].value) == raw_data(transmute([]u8)raw))
	}
	if len(req.in_fields) == 1 {
		testing.expect_value(t, string(req.in_fields[0]), "Title")
	}
	if len(req.in_keys) == 2 {
		testing.expect_value(t, string(req.in_keys[0]), "a\x00b")
	}
}

@(test)
search_request_option_order_and_empty_blocks :: proc(t: ^testing.T) {
	req, err := search_request_parse(search_test_args(
		"RETURN", "0", "RETURN", "8", "missing", "AS", "t", "t", "m", "AS", "M", "M", "LIMIT", "1", "1", "LIMIT", "0", "0",
		"SCORER", "bad", "SCORER", "BM25STD", "LANGUAGE", "bad", "LANGUAGE", "english", "INFIELDS", "1", "f", "INFIELDS", "0", "INKEYS", "1", "x", "INKEYS", "0",
	))
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(req.return_fields), 2)
	testing.expect(t, req.has_return && !req.no_content && req.has_in_keys)
	testing.expect_value(t, len(req.in_fields), 0)
	testing.expect_value(t, len(req.in_keys), 0)
	testing.expect_value(t, req.count, 0)
	testing.expect_value(t, req.offset, 0)
	if len(req.return_fields) == 2 {
		testing.expect_value(t, req.return_fields[0], Search_Return_Field{"missing", "t"})
		testing.expect_value(t, req.return_fields[1], Search_Return_Field{"m", "M"})
	}
	req, err = search_request_parse(search_test_args("NOCONTENT", "RETURN", "3", "field", "AS", ""))
	testing.expect_value(t, err, "")
	testing.expect(t, req.no_content)
	if len(req.return_fields) == 1 {
		testing.expect_value(t, req.return_fields[0].name, "")
	}
	req, err = search_request_parse(search_test_args("RETURN", "0", "WITHCOUNT", "SORTBY", "n"))
	testing.expect_value(t, err, "")
	testing.expect(t, req.no_content && req.with_count && req.has_sort && !req.sort_desc)
	req, err = search_request_parse(search_test_args("LIMIT", " -0", "01", "TIMEOUT", "9223372036854775806", "DIALECT", "4\x00extra", "PARAMS", "4", "a", "1", "A", "2"))
	testing.expect_value(t, err, "")
	testing.expect_value(t, req.count, 1)
	testing.expect_value(t, req.timeout_ms.? or_else -1, i64(9223372036854775806))
	testing.expect_value(t, req.query_options.dialect, 4)
	testing.expect_value(t, len(req.query_options.params), 2)
}

@(test)
search_request_recorded_argument_errors :: proc(t: ^testing.T) {
	cases := []struct{ args: []string, error: string } {
		{{"BOGUS"}, "SEARCH_ARG_UNRECOGNIZED Unknown argument `BOGUS` at position 1 for <main>"},
		{{"BOG\r\nUS"}, "SEARCH_ARG_UNRECOGNIZED Unknown argument `BOG  US` at position 1 for <main>"},
		{{"BOG\x00US"}, "SEARCH_ARG_UNRECOGNIZED Unknown argument `BOG` at position 1 for <main>"},
		{{"SORTBY", "n", "SIDEWAYS"}, "SEARCH_ARG_UNRECOGNIZED Unknown argument `SIDEWAYS` at position 3 for <main>"},
		{{"SORTBY"}, "SEARCH_PARSE_ARGS Bad SORTBY arguments"},
		{{"SORTBY", "n", "SORTBY"}, "SEARCH_PARSE_ARGS Multiple SORTBY steps are not allowed"},
		{{"SORTBY", "n", "WITHCOUNT", "DESC"}, "SEARCH_ARG_UNRECOGNIZED Unknown argument `DESC` at position 4 for <main>"},
		{{"LIMIT", "a", "b"}, "SEARCH_PARSE_ARGS LIMIT needs two numeric arguments"},
		{{"LIMIT", "0"}, "SEARCH_PARSE_ARGS LIMIT requires two arguments"},
		{{"LIMIT", "-1", "1"}, "SEARCH_PARSE_ARGS LIMIT needs two numeric arguments"},
		{{"LIMIT", "0", "9223372036854775807"}, "SEARCH_PARSE_ARGS LIMIT needs two numeric arguments"},
		{{"LIMIT", "0", "1 "}, "SEARCH_PARSE_ARGS LIMIT needs two numeric arguments"},
		{{"LIMIT", "1", "0"}, "SEARCH_LIMIT_OVER The `offset` of the LIMIT must be 0 when `num` is 0"},
		{{"LIMIT", "1000001", "1"}, "SEARCH_LIMIT_OVER OFFSET exceeds maximum of 1000000"},
		{{"LIMIT", "0", "1000001"}, "SEARCH_LIMIT_OVER LIMIT exceeds maximum of 1000000"},
		{{"RETURN", "3", "t"}, "SEARCH_PARSE_ARGS Bad arguments for RETURN: Expected an argument, but none provided"},
		{{"RETURN", "x"}, "SEARCH_PARSE_ARGS Bad arguments for RETURN: Could not convert argument to expected type"},
		{{"RETURN", "-1"}, "SEARCH_PARSE_ARGS Bad arguments for RETURN: Value is outside acceptable bounds"},
		{{"RETURN", "4294967296"}, "SEARCH_PARSE_ARGS Bad arguments for RETURN: Value is outside acceptable bounds"},
		{{"RETURN", "1", "t", "AS", "tr"}, "SEARCH_ARG_UNRECOGNIZED Unknown argument `AS` at position 4 for <main>"},
		{{"RETURN", "2", "t", "AS"}, "SEARCH_PARSE_ARGS RETURN path AS name - must be accompanied with NAME"},
		{{"PARAMS", "2", "a"}, "SEARCH_PARSE_ARGS Bad arguments for PARAMS: Expected an argument, but none provided"},
		{{"PARAMS", "1", "q", "DIALECT", "2"}, "SEARCH_ADD_ARGS Parameters must be specified in PARAM VALUE pairs"},
		{{"PARAMS", "0"}, "SEARCH_ADD_ARGS Parameters must be specified in PARAM VALUE pairs"},
		{{"PARAMS", "4", "a", "1", "a", "2", "DIALECT", "2"}, "SEARCH_ADD_ARGS Duplicate parameter `a`"},
		{{"PARAMS", "4", "a\x00b", "1", "a", "2"}, "SEARCH_ADD_ARGS Duplicate parameter `a`"},
		{{"PARAMS", "2", "a", "1", "PARAMS", "1", "z"}, "SEARCH_ADD_ARGS Multiple PARAMS are not allowed. Parameters can be defined only once"},
		{{"DIALECT"}, "SEARCH_PARSE_ARGS Need an argument for DIALECT"},
		{{"DIALECT", "0"}, "SEARCH_PARSE_ARGS DIALECT requires a non negative integer >=1 and <= 4"},
		{{"DIALECT", "5"}, "SEARCH_PARSE_ARGS DIALECT requires a non negative integer >=1 and <= 4"},
		{{"TIMEOUT"}, "SEARCH_PARSE_ARGS Need argument for TIMEOUT"},
		{{"TIMEOUT", "abc"}, "SEARCH_PARSE_ARGS TIMEOUT requires a non negative integer"},
		{{"TIMEOUT", "9223372036854775807"}, "SEARCH_PARSE_ARGS TIMEOUT requires a non negative integer"},
		{{"INKEYS", "3", "e:1"}, "SEARCH_PARSE_ARGS Bad arguments for INKEYS: Expected an argument, but none provided"},
		{{"INFIELDS", "-1"}, "SEARCH_PARSE_ARGS Bad arguments for INFIELDS: Value is outside acceptable bounds"},
		{{"SLOP", "2147483648"}, "SEARCH_PARSE_ARGS Bad arguments for SLOP: Value is outside acceptable bounds"},
		{{"SLOP", "x"}, "SEARCH_PARSE_ARGS Bad arguments for SLOP: Could not convert argument to expected type"},
		{{"LANGUAGE"}, "SEARCH_PARSE_ARGS Bad arguments for LANGUAGE: Expected an argument, but none provided"},
		{{"LANGUAGE", "NOPE"}, "SEARCH_QUERY_BAD No such language"},
		{{"SCORER", "NOPE"}, "SEARCH_QUERY_BAD No such scorer NOPE"},
		{{"SCORER", "bm25std"}, "SEARCH_QUERY_BAD No such scorer bm25std"},
		{{"EXPLAINSCORE"}, "SEARCH_PARSE_ARGS EXPLAINSCORE must be accompanied with WITHSCORES"},
		{{"FILTER"}, "SEARCH_PARSE_ARGS FILTER requires 3 arguments"},
		{{"GEOFILTER"}, "SEARCH_PARSE_ARGS GEOFILTER requires 5 arguments"},
	}
	for c in cases {
		q, err := search_request_parse(search_test_args(..c.args))
		testing.expect_value(t, err, c.error)
		testing.expect_value(t, q.count, 0)
	}
}

@(test)
search_request_rejects_unsupported_options_and_handles_allocation_failure :: proc(t: ^testing.T) {
	cases := []struct{ args: []string, error: string } {
		{{"LANGUAGE", "GRR"}, "SEARCH_QUERY_BAD No such language"},
		{{"LANGUAGE", "GERMAN"}, "SEARCH_OPTION_INVALID LANGUAGE german is not supported"},
		{{"EXPANDER", "NOPE"}, "SEARCH_OPTION_INVALID EXPANDER is not supported"},
		{{"FORMAT", "STRING"}, "SEARCH_OPTION_INVALID FORMAT is not supported"},
	}
	for c in cases {
		_, err := search_request_parse(search_test_args(..c.args))
		testing.expect_value(t, err, c.error)
	}
	no_alloc := mem.nil_allocator()
	_, args_error := search_request_parse(search_test_args("BOGUS"), no_alloc)
	_, params_error := search_request_parse(search_test_args("PARAMS", "2", "v", "binary"), no_alloc)
	_, return_error := search_request_parse(search_test_args("RETURN", "1", "field"), no_alloc)
	testing.expect_value(t, args_error, "ERR out of memory")
	testing.expect_value(t, params_error, "ERR out of memory")
	testing.expect_value(t, return_error, "ERR out of memory")
}

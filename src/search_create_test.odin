package main

import "core:testing"

@(test)
search_create_error_replies :: proc(t: ^testing.T) {
	cases := [?]struct{args: []string, expected: string}{
		{{"FT.CREATE"},
		 "ERR wrong number of arguments for 'FT.CREATE' command"},
		{{"FT.CREATE", "e"},
		 "ERR wrong number of arguments for 'FT.CREATE' command"},
		{{"FT.CREATE", "e", "SCHEMA"},
		 "ERR wrong number of arguments for 'FT.CREATE' command"},
		{{"FT.CREATE", "x1", "ON", "HASH"},
		 "ERR wrong number of arguments for 'FT.CREATE' command"},
		{{"FT.CREATE", "x1", "SCHEMA", "t", "BLOB"},
		 "SEARCH_PARSE_ARGS Invalid field type for field `t`"},
		{{"FT.CREATE", "x1", "SCHEMA", "t"},
		 "ERR wrong number of arguments for 'FT.CREATE' command"},
		{{"FT.CREATE", "x1", "ON", "STRING", "SCHEMA", "t", "TEXT"},
		 "SEARCH_ADD_ARGS Invalid rule type: STRING"},
		{{"FT.CREATE", "x1", "PREFIX", "2", "a:", "SCHEMA", "t", "TEXT"},
		 "SEARCH_ARG_UNRECOGNIZED Unknown argument `t`"},
		{{"FT.CREATE", "x1", "PREFIX", "x", "SCHEMA", "t", "TEXT"},
		 "SEARCH_PARSE_ARGS Bad arguments for PREFIX: Could not convert argument to expected type"},
		{{"FT.CREATE", "x1", "FILTER", "@n >", "SCHEMA", "n", "NUMERIC"},
		 "ERR FT.CREATE does not support FILTER"},
		{{"FT.CREATE", "x1", "LANGUAGE", "klingon", "SCHEMA", "t", "TEXT"},
		 "SEARCH_ADD_ARGS Invalid language"},
		{{"FT.CREATE", "x1", "STOPWORDS", "3", "a", "SCHEMA", "t", "TEXT"},
		 "SEARCH_ARG_UNRECOGNIZED Unknown argument `TEXT`"},
		{{"FT.CREATE", "x1", "SCORE", "abc", "SCHEMA", "t", "TEXT"},
		 "SEARCH_ADD_ARGS Invalid score"},
		{{"FT.CREATE", "x1", "SCORE", "2", "SCHEMA", "t", "TEXT"},
		 "SEARCH_ADD_ARGS Invalid score"},
		{{"FT.CREATE", "x1", "SCHEMA", "t", "TEXT", "t", "TEXT"},
		 "SEARCH_QUERY_BAD Duplicate field in schema - t"},
		{{"FT.CREATE", "x1", "SCHEMA", "t", "TEXT", "WEIGHT", "abc"},
		 "SEARCH_PARSE_ARGS Bad arguments for weight: Could not convert argument to expected type"},
		{{"FT.CREATE", "x1", "SCHEMA", "g", "TAG", "SEPARATOR", ";;"},
		 "SEARCH_PARSE_ARGS Tag separator must be a single character. Got `%s`;;"},
		{{"FT.CREATE", "x1", "SCHEMA", "g", "TAG", "SEPARATOR"},
		 "SEARCH_PARSE_ARGS SEPARATOR requires an argument"},
		{{"FT.CREATE", "x1", "SCHEMA", "t", "TEXT", "PHONETIC", "xx:yy"},
		 "SEARCH_QUERY_BAD Matcher Format: <2 chars algorithm>:<2 chars language>. Support algorithms: double metaphone (dm). Supported languages: English (en), French (fr), Portuguese (pt) and Spanish (es)"},
		{{"FT.CREATE", "x1", "SCHEMA", "t", "TEXT", "BOGUS"},
		 "SEARCH_PARSE_ARGS Field `BOGUS` does not have a type"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity algorithm: Expected an argument, but none provided"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "IVF", "6", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity algorithm: Unknown argument"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "5", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2"},
		 "SEARCH_PARSE_ARGS Bad number of arguments for vector similarity index: got 5 but expected even number as algorithm parameters (should be submitted as named arguments)"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "8", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2"},
		 "SEARCH_PARSE_ARGS Expected 8 parameters but got 6"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "4", "TYPE", "FLOAT32", "DIM", "2"},
		 "SEARCH_PARSE_ARGS Missing mandatory parameter: cannot create FLAT index without specifying DISTANCE_METRIC argument"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "4", "DIM", "2", "DISTANCE_METRIC", "L2"},
		 "SEARCH_PARSE_ARGS Missing mandatory parameter: cannot create FLAT index without specifying TYPE argument"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "4", "TYPE", "FLOAT32", "DISTANCE_METRIC", "L2"},
		 "SEARCH_PARSE_ARGS Missing mandatory parameter: cannot create FLAT index without specifying DIM argument"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "6", "TYPE", "FLOAT32", "DIM", "0", "DISTANCE_METRIC", "L2"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity FLAT index `DIM`: Value is outside acceptable bounds"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "6", "TYPE", "FLOAT32", "DIM", "abc", "DISTANCE_METRIC", "L2"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity FLAT index `DIM`: Could not convert argument to expected type"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "6", "TYPE", "FLOAT128", "DIM", "2", "DISTANCE_METRIC", "L2"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity FLAT index `TYPE`: Unknown argument"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "6", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "HAMMING"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity FLAT index `DISTANCE_METRIC`: Unknown argument"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "8", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2", "M", "16"},
		 "SEARCH_PARSE_ARGS Bad arguments for algorithm FLAT: M"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "HNSW", "8", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2", "M", "0"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity HNSW index `M`: Value is outside acceptable bounds"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "HNSW", "8", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2", "EF_CONSTRUCTION", "0"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity HNSW index `EF_CONSTRUCTION`: Value is outside acceptable bounds"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "HNSW", "8", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2", "EPSILON", "abc"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity HNSW index `EPSILON`: Could not convert argument to expected type"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "HNSW", "8", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2", "BLOCK_SIZE", "0"},
		 "SEARCH_PARSE_ARGS Bad arguments for algorithm HNSW: BLOCK_SIZE"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "SVS-VAMANA", "8", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2", "COMPRESSION", "LVQ99"},
		 "SEARCH_PARSE_ARGS Bad arguments for vector similarity SVS-VAMANA index `COMPRESSION`: Unknown argument"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "SVS-VAMANA", "8", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2", "M", "16"},
		 "SEARCH_PARSE_ARGS Bad arguments for algorithm SVS-VAMANA: M"},
		{{"FT.CREATE", "x1", "SCHEMA", "v", "VECTOR", "FLAT", "6", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2", "SORTABLE"},
		 "SEARCH_PARSE_ARGS Field `SORTABLE` does not have a type"},
		{{"FT.CREATE", "x1", "ON", "JSON", "SCHEMA", "$.a", "TEXT", "$.a", "TEXT"},
		 "SEARCH_QUERY_BAD Duplicate field in schema - $.a"},
		{{"FT.CREATE", "x1", "ON", "JSON", "SCHEMA", "a[", "AS", "a", "TEXT"},
		 "SEARCH_PATH_BAD Invalid JSONPath 'a[' in attribute 'a' in index 'x1'"},
		{{"FT.CREATE", "i", "TEMPORARY", "10", "SCHEMA", "x", "TEXT"},
		 "ERR FT.CREATE does not support TEMPORARY"},
		{{"FT.CREATE", "i", "NOHL", "SCHEMA", "x", "TEXT"},
		 "ERR FT.CREATE does not support NOHL"},
		{{"FT.CREATE", "i", "NOOFFSETS", "SCHEMA", "x", "TEXT"},
		 "ERR FT.CREATE does not support NOOFFSETS"},
		{{"FT.CREATE", "i", "NOFIELDS", "SCHEMA", "x", "TEXT"},
		 "ERR FT.CREATE does not support NOFIELDS"},
		{{"FT.CREATE", "i", "NOFREQS", "SCHEMA", "x", "TEXT"},
		 "ERR FT.CREATE does not support NOFREQS"},
		{{"FT.CREATE", "i", "SCHEMA", "x", "GEOSHAPE", "FLAT"},
		 "ERR FT.CREATE does not support GEOSHAPE"},
		{{"FT.CREATE", "i", "SCHEMA", "x", "TEXT", "PHONETIC", "dm:en"},
		 "ERR FT.CREATE does not support PHONETIC"},
		{{"FT.CREATE", "i", "SCHEMA", "x", "VECTOR", "SVS-VAMANA", "6", "TYPE", "FLOAT32", "DIM", "2", "DISTANCE_METRIC", "L2"},
		 "ERR FT.CREATE does not support SVS-VAMANA"},
		{{"FT.CREATE", "i", "MAXTEXTFIELDS", "NOFIELDS", "SCHEMA", "x", "TEXT"},
		 "SEARCH_QUERY_BAD MAXTEXTFIELDS cannot be used with NOFIELDS"},
		{{"FT.CREATE", "i", "INDEXALL", "BOGUS", "SCHEMA", "t", "TEXT"},
		 "SEARCH_ADD_ARGS Invalid argument for `INDEXALL`, use ENABLE/DISABLE"},
	}
	for item in cases {
		argv := make([][]u8, len(item.args), context.temp_allocator)
		for arg, i in item.args {
			argv[i] = transmute([]u8)arg
		}
		_, got := search_create_parse(argv)
		testing.expectf(t, got == item.expected, "%v answered %q, expected %q", item.args, got, item.expected)
	}
}

@(test)
search_create_preserves_schema_and_scan_options :: proc(t: ^testing.T) {
	args := [?]string{
		"FT.CREATE", "schema", "ON", "HaSh", "PREFIX", "2", "alpha:", "beta:", "LANGUAGE", "German",
		"LANGUAGE_FIELD", "doc_lang", "SCORE_FIELD", "rank", "SCORE", "0.5", "STOPWORDS", "2", "One", "two",
		"SKIPINITIALSCAN", "INDEXALL", "ENABLE", "SCHEMA", "source_text", "AS", "body", "TEXT",
		"NOSTEM", "WEIGHT", "2.5", "SORTABLE", "UNF", "INDEXEMPTY", "INDEXMISSING",
		"tag", "TAG", "SEPARATOR", ";", "CASESENSITIVE", "num", "NUMERIC", "SORTABLE", "NOINDEX",
		"vec", "VECTOR", "HNSW", "16", "TYPE", "FLOAT64", "DIM", "4", "DISTANCE_METRIC", "IP",
		"INITIAL_CAP", "100", "M", "8", "EF_CONSTRUCTION", "100", "EF_RUNTIME", "20", "EPSILON", "0.05",
	}
	argv := make([][]u8, len(args), context.temp_allocator)
	for arg, i in args {
		argv[i] = transmute([]u8)arg
	}
	spec, err := search_create_parse(argv)
	testing.expect_value(t, err, "")
	if err != "" { return }
	testing.expect(t, spec.skip_initial_scan && spec.indexes_all && spec.explicit_language)
	testing.expect(t, spec.prefixes[0] == "alpha:" && spec.prefixes[1] == "beta:")
	testing.expect_value(t, spec.definition.language_field, "doc_lang")
	testing.expect_value(t, spec.definition.score_field, "rank")
	testing.expect_value(t, spec.definition.stop_words[0], "One")
	testing.expect_value(t, spec.definition.score, f32(0.5))
	f := spec.definition.fields
	testing.expect(t, f[0].name == "body" && f[0].source == "source_text")
	testing.expect(t, f[0].no_stem && f[0].sortable && f[0].index_empty && f[0].index_missing)
	testing.expect_value(t, f[0].weight, f64(2.5))
	testing.expect(t, f[1].case_sensitive && f[1].separator == ';')
	testing.expect(t, f[2].sortable && f[2].no_index && spec.attributes[2].unf)
	testing.expect_value(t, f[3].vector.m, 8)
	testing.expect_value(t, f[3].vector.ef_runtime, 20)
	testing.expect_value(t, spec.attributes[3].initial_cap, 100)
}

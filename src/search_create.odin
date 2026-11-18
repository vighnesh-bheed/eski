package main

import "core:fmt"
import "core:math"
import fi "ftindex"
import "jsondoc"
import "text"
import "vmath"

SEARCH_ARITY_CREATE :: "ERR wrong number of arguments for 'FT.CREATE' command"
SEARCH_CONVERT :: "Could not convert argument to expected type"
SEARCH_MISSING :: "Expected an argument, but none provided"
SEARCH_BOUNDS :: "Value is outside acceptable bounds"
SEARCH_UNKNOWN :: "Unknown argument"

search_default_prefixes := [?]string{""}

Search_Attribute :: struct {
	unf:         bool,
	initial_cap: int,
	block_size:  int,
}

Search_Create :: struct {
	definition:       fi.Definition,
	on_json:          bool,
	prefixes:         []string,
	attributes:        []Search_Attribute,
	default_score:     f64,
	explicit_language: bool,
	max_text_fields:   bool,
	indexes_all:       bool,
	skip_initial_scan: bool,
}

@(private = "file")
search_upper :: proc(value: []u8) -> string {
	upper := make([]u8, len(value), context.temp_allocator)
	for ch, i in value {
		upper[i] = ch - ('a'-'A') if ch >= 'a' && ch <= 'z' else ch
	}
	return string(upper)
}

search_unsupported :: proc(option: string) -> string {
	return fmt.tprintf("ERR FT.CREATE does not support %s", option)
}

@(private = "file")
search_arg :: proc(name, why: string) -> string {
	return fmt.tprintf("SEARCH_PARSE_ARGS Bad arguments for %s: %s", name, why)
}

@(private = "file")
search_invalid_option :: proc(value: []u8) -> string {
	return fmt.tprintf("SEARCH_ARG_UNRECOGNIZED Unknown argument `%s`", string(value))
}

@(private = "file")
search_list_args :: proc(argv: [][]u8, i: ^int, option: string) -> ([]string, string) {
	if i^ == len(argv) {
		return nil, search_arg(option, SEARCH_MISSING)
	}
	n, ok := parse_i64(argv[i^])
	i^ += 1
	if !ok || n < 0 {
		return nil, search_arg(option, SEARCH_CONVERT)
	}
	if n > i64(len(argv) - i^) {
		return nil, search_arg(option, SEARCH_MISSING)
	}
	out := make([]string, int(n), context.temp_allocator)
	for j in 0 ..< int(n) {
		out[j] = string(argv[i^ + j])
	}
	i^ += int(n)
	return out, ""
}

search_create_parse :: proc(argv: [][]u8) -> (out: Search_Create, err: string) {
	if len(argv) < 5 {
		return {}, SEARCH_ARITY_CREATE
	}
	out.definition = fi.definition_default(nil)
	out.default_score = 1
	out.prefixes = search_default_prefixes[:]
	i := 2
	no_fields := false
	unsupported := ""
	for i < len(argv) && !eq_nocase(argv[i], "schema") {
		option := argv[i]
		i += 1
		switch {
		case eq_nocase(option, "maxtextfields"):
			out.max_text_fields = true
		case eq_nocase(option, "skipinitialscan"):
			out.skip_initial_scan = true
		case eq_nocase(option, "prefix"), eq_nocase(option, "stopwords"):
			prefix := eq_nocase(option, "prefix")
			list, msg := search_list_args(argv, &i, "PREFIX" if prefix else "STOPWORDS")
			if msg != "" {
				return {}, msg
			}
			if prefix {
				out.prefixes = list if len(list) != 0 else search_default_prefixes[:]
			} else {
				out.definition.stop_words = list
				out.definition.stop_mode = .Custom if len(list) > 0 else .None
			}
		case eq_nocase(option, "nooffsets"), eq_nocase(option, "nohl"), eq_nocase(option, "nofields"), eq_nocase(option, "nofreqs"):
			no_fields = no_fields || eq_nocase(option, "nofields")
			if unsupported == "" {
				unsupported = search_upper(option)
			}
		case eq_nocase(option, "on"), eq_nocase(option, "language"), eq_nocase(option, "language_field"),
		     eq_nocase(option, "score"), eq_nocase(option, "score_field"), eq_nocase(option, "indexall"),
		     eq_nocase(option, "filter"), eq_nocase(option, "temporary"), eq_nocase(option, "payload_field"):
			if i == len(argv) {
				return {}, search_arg(search_upper(option), SEARCH_MISSING)
			}
			value := argv[i]
			i += 1
			switch {
			case eq_nocase(option, "on"):
				out.on_json = eq_nocase(value, "json")
				if !out.on_json && !eq_nocase(value, "hash") {
					return {}, fmt.tprintf("SEARCH_ADD_ARGS Invalid rule type: %s", string(value))
				}
			case eq_nocase(option, "language"):
				language, ok := text.language_parse(value)
				if !ok {
					return {}, "SEARCH_ADD_ARGS Invalid language"
				}
				out.definition.language = language
				out.explicit_language = true
			case eq_nocase(option, "language_field"):
				out.definition.language_field = string(value)
			case eq_nocase(option, "score"):
				score, ok := parse_double_strict(value)
				if !ok || !(score >= 0 && score <= 1) {
					return {}, "SEARCH_ADD_ARGS Invalid score"
				}
				out.definition.score = f32(score)
				out.default_score = score
			case eq_nocase(option, "score_field"):
				out.definition.score_field = string(value)
			case eq_nocase(option, "payload_field"):
				out.definition.payload_field = string(value)
			case eq_nocase(option, "indexall"):
				if !eq_nocase(value, "enable") && !eq_nocase(value, "disable") {
					return {}, "SEARCH_ADD_ARGS Invalid argument for `INDEXALL`, use ENABLE/DISABLE"
				}
				out.indexes_all = eq_nocase(value, "enable")
			case:
				return {}, search_unsupported(search_upper(option))
			}
		case:
			return {}, search_invalid_option(option)
		}
	}
	if out.max_text_fields && no_fields {
		return {}, "SEARCH_QUERY_BAD MAXTEXTFIELDS cannot be used with NOFIELDS"
	}
	if unsupported != "" {
		return {}, search_unsupported(unsupported)
	}
	if i + 2 >= len(argv) {
		return {}, SEARCH_ARITY_CREATE
	}
	i += 1
	fields := make([dynamic]fi.Field, context.temp_allocator)
	attributes := make([dynamic]Search_Attribute, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	text_count := 0
	for i < len(argv) {
		f, flags, msg := search_field_parse(argv, &i, out.on_json)
		if msg != "" {
			return {}, msg
		}
		if out.on_json {
			if why := search_validate_json_path(string(argv[1]), f.source, f.name); why != "" {
				return {}, why
			}
		}
		if f.name in seen {
			return {}, fmt.tprintf("SEARCH_QUERY_BAD Duplicate field in schema - %s", f.name)
		}
		seen[f.name] = true
		if f.kind == .Text {
			text_count += 1
			if text_count > fi.TEXT_FIELDS_MAX {
				return {}, "SEARCH_QUERY_BAD Too many TEXT fields"
			}
		}
		append(&fields, f)
		append(&attributes, flags)
	}
	out.definition.fields = fields[:]
	out.attributes = attributes[:]
	return out, ""
}

search_validate_json_path :: proc(index, path, name: string) -> string {
	compiled, err := jsondoc.compile_path(path, context.temp_allocator)
	if err != {} || compiled.expr == nil || compiled.expr.kind != .Selector {
		return fmt.tprintf("SEARCH_PATH_BAD Invalid JSONPath '%s' in attribute '%s' in index '%s'", path, name, index)
	}
	return ""
}

search_field_parse :: proc(argv: [][]u8, i: ^int, on_json := false) -> (f: fi.Field, flags: Search_Attribute, err: string) {
	source := string(argv[i^])
	i^ += 1
	name := source
	if i^ < len(argv) && eq_nocase(argv[i^], "as") {
		if i^ + 1 >= len(argv) {
			return {}, {}, search_arg("AS", SEARCH_MISSING)
		}
		name = string(argv[i^ + 1])
		i^ += 2
	}
	if i^ >= len(argv) {
		return {}, {}, fmt.tprintf("SEARCH_PARSE_ARGS Field `%s` does not have a type", name)
	}
	kind := argv[i^]
	i^ += 1
	fkind: fi.Field_Kind
	switch {
	case eq_nocase(kind, "text"): fkind = .Text
	case eq_nocase(kind, "tag"): fkind = .Tag
	case eq_nocase(kind, "numeric"): fkind = .Numeric
	case eq_nocase(kind, "vector"): fkind = .Vector
	case eq_nocase(kind, "geo"): fkind = .Geo
	case eq_nocase(kind, "geoshape"):
		return {}, {}, search_unsupported(search_upper(kind))
	case:
		return {}, {}, fmt.tprintf("SEARCH_PARSE_ARGS Invalid field type for field `%s`", name)
	}
	if len(name) == 0 || len(source) == 0 {
		return {}, {}, "SEARCH_PARSE_ARGS Field names must not be empty"
	}
	f = fi.field_default(name, fkind)
	f.source = source
	if on_json && fkind == .Tag {
		f.separator = 0
	}
	if fkind == .Vector {
		err = search_vector_parse(argv, i, &f.vector, &flags)
		if err != "" {
			return
		}
		if i^ < len(argv) && eq_nocase(argv[i^], "indexmissing") {
			f.index_missing = true
			i^ += 1
		}
		return
	}
	for i^ < len(argv) {
		option := argv[i^]
		switch {
		case eq_nocase(option, "sortable"):
			f.sortable = true
			flags.unf = on_json || fkind == .Numeric
			if i^ + 1 < len(argv) && eq_nocase(argv[i^ + 1], "unf") {
				flags.unf = true
				i^ += 1
			}
		case eq_nocase(option, "noindex"):
			f.no_index = true
		case eq_nocase(option, "indexmissing"):
			f.index_missing = true
		case eq_nocase(option, "indexempty") && fkind != .Numeric:
			f.index_empty = true
		case eq_nocase(option, "nostem") && fkind == .Text:
			f.no_stem = true
		case eq_nocase(option, "casesensitive") && fkind == .Tag:
			f.case_sensitive = true
		case eq_nocase(option, "withsuffixtrie") && (fkind == .Text || fkind == .Tag):
			f.suffix_trie = true
		case eq_nocase(option, "phonetic") && fkind == .Text:
			if i^ + 1 >= len(argv) {
				return {}, {}, search_arg("PHONETIC", SEARCH_MISSING)
			}
			matcher := argv[i^ + 1]
			if len(matcher) != 5 || !eq_nocase(matcher[:3], "dm:") ||
			   !(eq_nocase(matcher[3:], "en") || eq_nocase(matcher[3:], "fr") ||
			     eq_nocase(matcher[3:], "pt") || eq_nocase(matcher[3:], "es")) {
				return {}, {}, "SEARCH_QUERY_BAD Matcher Format: <2 chars algorithm>:<2 chars language>. Support algorithms: double metaphone (dm). Supported languages: English (en), French (fr), Portuguese (pt) and Spanish (es)"
			}
			return {}, {}, search_unsupported("PHONETIC")
		case eq_nocase(option, "weight") && fkind == .Text:
			if i^ + 1 >= len(argv) {
				return {}, {}, search_arg("weight", SEARCH_MISSING)
			}
			weight, ok := parse_double_strict(argv[i^ + 1])
			if !ok || math.is_inf(weight, 0) {
				return {}, {}, search_arg("weight", SEARCH_CONVERT)
			}
			if weight < 0 {
				return {}, {}, search_unsupported("negative TEXT WEIGHT")
			}
			f.weight = weight
			i^ += 1
		case eq_nocase(option, "separator") && fkind == .Tag:
			if i^ + 1 >= len(argv) {
				return {}, {}, "SEARCH_PARSE_ARGS SEPARATOR requires an argument"
			}
			sep := argv[i^ + 1]
			if len(sep) != 1 {
				return {}, {}, "SEARCH_PARSE_ARGS Tag separator must be a single character. Got `%s`;;"
			}
			f.separator = sep[0]
			i^ += 1
		case:
			return
		}
		i^ += 1
	}
	return
}

SEARCH_VECTOR_ALGORITHMS := [fi.Vector_Method]string{.Flat = "FLAT", .Hnsw = "HNSW", .Svs_Vamana = "SVS-VAMANA"}
SEARCH_VECTOR_TYPES := #partial [vmath.Elem]string{.F32 = "FLOAT32", .F64 = "FLOAT64", .F16 = "FLOAT16", .BF16 = "BFLOAT16", .Int8 = "INT8", .U8 = "UINT8"}
SEARCH_VECTOR_METRICS := [vmath.Metric]string{.Cosine = "COSINE", .L2 = "L2", .IP = "IP"}

@(private = "file")
Search_Vector_Arg :: enum {
	Type, Dim, Distance_Metric, Initial_Cap, Block_Size, M, Ef_Construction, Ef_Runtime, Epsilon,
	Compression, Construction_Window_Size, Graph_Max_Degree, Search_Window_Size, Training_Threshold, Reduce,
}

@(private = "file")
search_vector_args := [Search_Vector_Arg]string{
	.Type = "TYPE", .Dim = "DIM", .Distance_Metric = "DISTANCE_METRIC", .Initial_Cap = "INITIAL_CAP",
	.Block_Size = "BLOCK_SIZE", .M = "M", .Ef_Construction = "EF_CONSTRUCTION",
	.Ef_Runtime = "EF_RUNTIME", .Epsilon = "EPSILON", .Compression = "COMPRESSION",
	.Construction_Window_Size = "CONSTRUCTION_WINDOW_SIZE", .Graph_Max_Degree = "GRAPH_MAX_DEGREE",
	.Search_Window_Size = "SEARCH_WINDOW_SIZE", .Training_Threshold = "TRAINING_THRESHOLD", .Reduce = "REDUCE",
}

@(private = "file")
search_vector_arg_error :: proc(algorithm, key, why: string) -> string {
	return fmt.tprintf("SEARCH_PARSE_ARGS Bad arguments for vector similarity %s index `%s`: %s", algorithm, key, why)
}

@(private = "file")
search_vector_parse :: proc(argv: [][]u8, i: ^int, out: ^fi.Vector_Options, flags: ^Search_Attribute) -> string {
	if i^ >= len(argv) {
		return search_arg("vector similarity algorithm", SEARCH_MISSING)
	}
	variation := string(argv[i^])
	i^ += 1
	algorithm := ""
	for method in fi.Vector_Method {
		if eq_fold(transmute([]u8)variation, transmute([]u8)SEARCH_VECTOR_ALGORITHMS[method]) {
			out.method = method
			algorithm = SEARCH_VECTOR_ALGORITHMS[method]
			break
		}
	}
	if algorithm == "" {
		return search_arg("vector similarity algorithm", SEARCH_UNKNOWN)
	}
	if i^ >= len(argv) {
		return search_arg("vector similarity argument count", SEARCH_MISSING)
	}
	n, ok := parse_i64(argv[i^])
	i^ += 1
	if !ok || n < 0 {
		return search_arg("vector similarity argument count", SEARCH_CONVERT)
	}
	if n & 1 != 0 {
		return fmt.tprintf("SEARCH_PARSE_ARGS Bad number of arguments for vector similarity index: got %d but expected even number as algorithm parameters (should be submitted as named arguments)", n)
	}
	if n > i64(len(argv)-i^) {
		return fmt.tprintf("SEARCH_PARSE_ARGS Expected %d parameters but got %d", n, len(argv)-i^)
	}
	out.m = fi.HNSW_M_DEFAULT
	out.ef_construction = fi.HNSW_EF_CONSTRUCTION_DEFAULT
	out.ef_runtime = fi.HNSW_EF_RUNTIME_DEFAULT
	out.epsilon = fi.HNSW_EPSILON_DEFAULT
	seen: bit_set[Search_Vector_Arg]
	end := i^ + int(n)
	for i^ < end {
		key, value := argv[i^], argv[i^+1]
		i^ += 2
		arg: Search_Vector_Arg
		found := false
		for option in Search_Vector_Arg {
			if eq_fold(key, transmute([]u8)search_vector_args[option]) {
				arg, found = option, true
				break
			}
		}
		allowed := bit_set[Search_Vector_Arg]{.Type, .Dim, .Distance_Metric, .Initial_Cap}
		switch out.method {
		case .Flat: allowed += {.Block_Size}
		case .Hnsw: allowed += {.M, .Ef_Construction, .Ef_Runtime, .Epsilon}
		case .Svs_Vamana: allowed += {.Epsilon, .Compression, .Construction_Window_Size, .Graph_Max_Degree, .Search_Window_Size, .Training_Threshold, .Reduce}
		}
		if !found || arg not_in allowed {
			return fmt.tprintf("SEARCH_PARSE_ARGS Bad arguments for algorithm %s: %s", algorithm, string(key))
		}
		seen += {arg}
		if err := search_vector_value(arg, value, algorithm, out, flags); err != "" {
			return err
		}
	}
	for arg in ([3]Search_Vector_Arg{.Type, .Dim, .Distance_Metric}) {
		if arg not_in seen {
			return fmt.tprintf("SEARCH_PARSE_ARGS Missing mandatory parameter: cannot create %s index without specifying %s argument", algorithm, search_vector_args[arg])
		}
	}
	if out.method == .Svs_Vamana {
		if out.elem != .F32 && out.elem != .F16 {
			return "SEARCH_PARSE_ARGS Not supported data type is given. Expected: FLOAT16, FLOAT32"
		}
		return search_unsupported("SVS-VAMANA")
	}
	return ""
}

@(private = "file")
search_vector_value :: proc(k: Search_Vector_Arg, value: []u8, algorithm: string, v: ^fi.Vector_Options, flags: ^Search_Attribute) -> string {
	key := search_vector_args[k]
	#partial switch k {
	case .Type:
		for elem in vmath.Elem {
			if SEARCH_VECTOR_TYPES[elem] != "" && eq_fold(value, transmute([]u8)SEARCH_VECTOR_TYPES[elem]) {
				v.elem = elem
				return ""
			}
		}
		return search_vector_arg_error(algorithm, key, SEARCH_UNKNOWN)
	case .Distance_Metric:
		for metric in vmath.Metric {
			if eq_fold(value, transmute([]u8)SEARCH_VECTOR_METRICS[metric]) {
				v.metric = metric
				return ""
			}
		}
		return search_vector_arg_error(algorithm, key, SEARCH_UNKNOWN)
	case .Compression:
		for mode in ([11]string{"NONE", "LVQ4", "LVQ8", "LVQ4x4", "LVQ4x8", "LVQ8x8", "LeanVec4x4", "LeanVec4x8", "LeanVec8x8", "GlobalSQ8", "GlobalSQ4"}) {
			if eq_fold(value, transmute([]u8)mode) {
				return ""
			}
		}
		return search_vector_arg_error(algorithm, key, SEARCH_UNKNOWN)
	case .Epsilon:
		n, ok := parse_double_strict(value)
		if !ok || math.is_inf(n, 0) {
			return search_vector_arg_error(algorithm, key, SEARCH_CONVERT)
		}
		if n < 0 {
			return search_vector_arg_error(algorithm, key, SEARCH_BOUNDS)
		}
		v.epsilon = n
		return ""
	}
	n, ok := parse_i64(value)
	if !ok {
		return search_vector_arg_error(algorithm, key, SEARCH_CONVERT)
	}
	if n < (0 if k == .Initial_Cap else 1) || (k == .Dim && n > vmath.DIM_MAX) {
		return search_vector_arg_error(algorithm, key, SEARCH_BOUNDS)
	}
	#partial switch k {
	case .Dim: v.dim = int(n)
	case .Initial_Cap: flags.initial_cap = int(n)
	case .Block_Size: flags.block_size = int(n)
	case .M: v.m = int(n)
	case .Ef_Construction: v.ef_construction = int(n)
	case .Ef_Runtime: v.ef_runtime = int(n)
	}
	return ""
}

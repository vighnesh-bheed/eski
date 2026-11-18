package main

import "core:strings"
import fi "ftindex"
import "rrf"

FT_HYBRID_DIALECT :: 2
FT_HYBRID_DIALECT_ERROR ::"SEARCH_PARSE_ARGS DIALECT is not supported in FT.HYBRID or any of its subqueries. Please check the documentation on search-default-dialect configuration."

FT_Hybrid_Request :: struct {
	query, filter, field, parameter: string,
	text_alias, vector_alias, fused_alias: string,
	has_filter, combine, linear, explain: bool,
	window: int,
	constant, alpha, beta: f64,
	vector: fi.Hybrid_Vector,
	pipeline: FT_Pipeline,
}

ft_hybrid_parse :: proc(args: [][]u8, out: ^FT_Hybrid_Request) -> string {
	out.window, out.constant = rrf.WINDOW, rrf.CONSTANT
	out.alpha, out.beta = 0.3, 0.7
	out.vector.k = fi.HYBRID_K_DEFAULT
	if !eq_nocase(args[0], "search") {
		return "SEARCH_SYNTAX Invalid subqueries count: expected an unsigned integer"
	}
	out.query = string(args[1])
	at := 2
	for at < len(args) && !eq_nocase(args[at], "vsim") {
		token := args[at]
		at += 1
		if eq_nocase(token, "dialect") {
			return FT_HYBRID_DIALECT_ERROR
		}
		if at == len(args) {
			break
		}
		if eq_nocase(token, "scorer") {
			out.pipeline.scorer = ft_token(args[at])
		} else if eq_nocase(token, "yield_score_as") {
			out.text_alias = ft_token(args[at])
		} else if eq_nocase(token, "verbatim") {
			out.pipeline.search.query_options.verbatim = true
			continue
		} else {
			return ft_error("SEARCH_PARSE_ARGS ", ft_token(token), ": Unknown argument")
		}
		at += 1
	}
	if len(args) - at < 3 {
		return "ERR wrong number of arguments for 'FT.HYBRID' command"
	}
	field := ft_token(args[at+1])
	param := ft_token(args[at+2])
	if len(field) == 0 || field[0] != '@' {
		return "SEARCH_SYNTAX Missing @ prefix for vector field name"
	}
	if len(param) < 2 || param[0] != '$' {
		return "SEARCH_SYNTAX Invalid vector argument, expected a parameter name starting with $"
	}
	out.field, out.parameter = field[1:], param[1:]
	at += 3
	if at < len(args) && (eq_nocase(args[at], "knn") || eq_nocase(args[at], "range")) {
		ranged := eq_nocase(args[at], "range")
		at += 1
		if err := ft_hybrid_vector_parse(args, &at, ranged, &out.vector); err != "" {
			return err
		}
	}
	for at < len(args) {
		token := args[at]
		if eq_nocase(token, "filter") && !out.has_filter {
			at += 1
			if at == len(args) {
				return "SEARCH_PARSE_ARGS FILTER: Expected an argument, but none provided"
			}
			out.filter, out.has_filter = string(args[at]), true
		} else if eq_nocase(token, "yield_score_as") && out.vector_alias == "" {
			at += 1
			if at == len(args) {
				return "SEARCH_PARSE_ARGS YIELD_SCORE_AS: Expected an argument, but none provided"
			}
			out.vector_alias = ft_token(args[at])
		} else {
			break
		}
		at += 1
	}
	err := ft_pipeline_parse(args[at:], true, &out.pipeline, out)
	out.pipeline.search.query_options.dialect = FT_HYBRID_DIALECT
	return err
}

ft_hybrid_vector_parse :: proc(args: [][]u8, at: ^int, ranged: bool, out: ^fi.Hybrid_Vector) -> string {
	option := "RANGE" if ranged else "KNN"
	required := "RADIUS" if ranged else "K"
	if at^ == len(args) {
		return "SEARCH_SYNTAX Invalid argument count: expected an unsigned integer"
	}
	n, parsed := search_number(args[at^])
	at^ += 1
	if !parsed || n < 0 {
		return "SEARCH_SYNTAX Invalid argument count: expected an unsigned integer"
	}
	if n == 0 || n % 2 != 0 {
		return ft_error("SEARCH_SYNTAX Invalid argument count: ", ft_int_text(n), " (must be a positive even number for key/value pairs)")
	}
	if n > i64(len(args) - at^) {
		return ft_error("SEARCH_PARSE_ARGS Bad arguments for ", option, ": ", SEARCH_MISSING_ARGUMENT)
	}
	end := at^ + int(n)
	found := false
	out.range = ranged
	for at^ < end {
		token, val := args[at^], args[at^+1]
		at^ += 2
		switch {
		case eq_nocase(token, "radius" if ranged else "k"):
			found = true
			if ranged {
				value, ok := fi.number_parse(ft_token(val))
				if !ok || !(value >= 0) {
					return "SEARCH_SYNTAX Invalid RADIUS value"
				}
				out.radius = value
			} else {
				value, ok := search_number(val)
				if !ok || value <= 0 {
					return "SEARCH_SYNTAX Invalid K value"
				}
				out.k = int(value)
			}
		case ranged && eq_nocase(token, "epsilon"):
			value, ok := fi.number_parse(ft_token(val))
			if !ok || !(value > 0) {
				return "SEARCH_SYNTAX Invalid EPSILON value"
			}
			out.epsilon = value
		case !ranged && eq_nocase(token, "ef_runtime"):
			value, ok := search_number(val)
			if !ok || value <= 0 {
				return "SEARCH_SYNTAX Invalid EF_RUNTIME value"
			}
			out.ef_runtime = int(value)
		case:
			return ft_error("SEARCH_ARG_UNRECOGNIZED Unknown argument `", ft_token(token), "` in ", option)
		}
	}
	if !found {
		return ft_error("SEARCH_PARSE_ARGS Missing required argument ", required)
	}
	return ""
}

ft_hybrid_combine :: proc(args: [][]u8, at: ^int, out: ^FT_Hybrid_Request) -> string {
	if out.combine {
		return "SEARCH_PARSE_ARGS COMBINE: Multiple COMBINE options are not allowed"
	}
	out.combine = true
	if at^ == len(args) {
		return "SEARCH_PARSE_ARGS COMBINE: Expected an argument, but none provided"
	}
	method := args[at^]
	at^ += 1
	out.linear = eq_nocase(method, "linear")
	if !out.linear && !eq_nocase(method, "rrf") {
		return "SEARCH_PARSE_ARGS COMBINE: Invalid value for argument"
	}
	params, err := search_counted_args(args, at, "COMBINE", context.temp_allocator)
	if err != "" {
		return err
	}
	alpha, beta: bool
	for i := 0; i < len(params); i += 2 {
		name := strings.to_upper(ft_token(params[i]), context.temp_allocator)
		supported := name == "WINDOW" || name == "YIELD_SCORE_AS" ||
			(out.linear && (name == "ALPHA" || name == "BETA")) || (!out.linear && name == "CONSTANT")
		if !supported {
			return ft_error("SEARCH_PARSE_ARGS ", name, ": Unknown argument")
		}
		if i + 1 == len(params) {
			return ft_error("SEARCH_PARSE_ARGS ", name, ": ", SEARCH_MISSING_ARGUMENT)
		}
		token := params[i+1]
		switch name {
		case "YIELD_SCORE_AS":
			out.fused_alias = ft_token(token)
		case "WINDOW":
			value, ok := search_number(token)
			if !ok {
				return ft_error("SEARCH_PARSE_ARGS WINDOW: ", SEARCH_INVALID_ARGUMENT)
			}
			if value < 1 {
				return "SEARCH_PARSE_ARGS WINDOW: Value below minimum"
			}
			out.window = int(value)
		case "ALPHA", "BETA", "CONSTANT":
			value, ok := fi.number_parse(ft_token(token))
			if !ok {
				return ft_error("SEARCH_PARSE_ARGS ", name, ": ", SEARCH_INVALID_ARGUMENT)
			}
			switch name {
			case "ALPHA":
				out.alpha, alpha = value, true
			case "BETA":
				out.beta, beta = value, true
			case "CONSTANT":
				out.constant = value
			}
		}
	}
	if alpha != beta {
		return "SEARCH_SYNTAX Missing value for BETA" if alpha else "SEARCH_SYNTAX Missing value for ALPHA"
	}
	return ""
}

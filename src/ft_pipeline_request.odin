package main

import "core:strings"
import fi "ftindex"

FT_AGGREGATE_LIMIT :: 2_147_483_648
FT_CURSOR_COUNT :: 1000
FT_CURSOR_IDLE :: 300_000

FT_Cursor_Options :: struct {
	enabled: bool,
	count:   int,
	idle_ms: i64,
}

FT_Pipeline_Kind :: enum {
	Load,
	Apply,
	Filter,
	Group,
	Sort,
	Limit,
}

FT_Pipeline_Step :: struct {
	kind: FT_Pipeline_Kind,
	fields: []Search_Return_Field,
	all: bool,
	expr: ^FT_Expr,
	name: string,
	reducers: []FT_Reducer,
	order: []FT_Order,
	maximum, offset, count: int,
}

FT_Order :: struct {
	name: string,
	desc: bool,
}

FT_Pipeline :: struct {
	search: Search_Request,
	steps: [dynamic]FT_Pipeline_Step,
	cursor: FT_Cursor_Options,
	scorer: string,
	add_scores: bool,
	expand: bool,
	sorted: bool,
	count_all: Maybe(bool),
	no_sort: bool,
}

ft_property :: proc "contextless" (name: string) -> string {
	return name[1:] if len(name) > 0 && name[0] == '@' else name
}

ft_token :: proc "contextless" (arg: []u8) -> string {
	return string(search_option_text(arg))
}

ft_error :: proc(parts: ..string) -> string {
	return search_error_text(context.temp_allocator, ..parts)
}

ft_int_text :: proc(i: i64) -> string {
	buf: [24]u8
	n := format_i64(raw_data(buf[:]), i)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

ft_argument_error :: proc(name, message: string) -> string {
	return search_argument_error(name, message, context.temp_allocator)
}

ft_unknown_argument :: proc(args: [][]u8, at: int, name := "main") -> string {
	pos: [24]u8
	n := format_i64(raw_data(pos[:]), i64(at + 1))
	return ft_error("SEARCH_ARG_UNRECOGNIZED Unknown argument `", ft_token(args[at]), "` at position ", string(pos[:n]), " for <", name, ">")
}

ft_cursor_options :: proc(args: [][]u8, at: ^int, out: ^FT_Cursor_Options) -> string {
	out^ = {true, FT_CURSOR_COUNT, ft_config_numbers[.Cursor_Idle]}
	for at^ < len(args) {
		token := args[at^]
		is_count := eq_nocase(token, "count")
		if !is_count && !eq_nocase(token, "maxidle") {
			break
		}
		name := "COUNT" if is_count else "MAXIDLE"
		at^ += 1
		if at^ == len(args) {
			return ft_argument_error(name, SEARCH_MISSING_ARGUMENT)
		}
		value, ok := search_number(args[at^])
		if !ok {
			return ft_argument_error(name, SEARCH_INVALID_ARGUMENT)
		}
		if value <= 0 || value > i64(max(u32)) {
			return ft_argument_error(name, SEARCH_ARGUMENT_BOUNDS)
		}
		if is_count {
			out.count = int(value)
		} else {
			out.idle_ms = min(value, ft_config_numbers[.Cursor_Idle])
		}
		at^ += 1
	}
	return ""
}

ft_pipeline_parse :: proc(args: [][]u8, hybrid: bool, out: ^FT_Pipeline, hybrid_request: ^FT_Hybrid_Request = nil, on_json := false) -> string {
	a := context.temp_allocator
	ft_config_search_options(&out.search)
	out.steps = make([dynamic]FT_Pipeline_Step, a)
	projected := false
	has_params := false
	collect_depth := 0
	for at := 0; at < len(args); {
		position := at
		token := strings.to_upper(ft_token(args[at]), a)
		at += 1
		switch token {
		case "LOAD":
			if projected && !hybrid {
				return "SEARCH_QUERY_BAD LOAD cannot be applied after projectors or reducers"
			}
			step := FT_Pipeline_Step{kind = .Load}
			if at < len(args) && ft_token(args[at]) == "*" {
				step.all = true
				at += 1
			} else {
				fields, err := search_counted_args(args, &at, "LOAD", a)
				if err != "" {
					return err
				}
				if hybrid && len(fields) == 0 {
					return "SEARCH_PARSE_ARGS Bad arguments for LOAD: Expected number of fields or `*`"
				}
				step.fields, err = ft_load_fields(fields)
				if err != "" {
					return err
				}
			}
			append(&out.steps, step)
		case "APPLY", "FILTER":
			if at == len(args) {
				return ft_argument_error(token, SEARCH_MISSING_ARGUMENT)
			}
			step := FT_Pipeline_Step{kind = .Apply if token == "APPLY" else .Filter}
			expr := ft_token(args[at])
			at += 1
			if step.kind == .Apply {
				projected = true
				step.name = expr
				if at < len(args) && eq_nocase(args[at], "as") {
					if at + 1 == len(args) {
						return "SEARCH_PARSE_ARGS APPLY requires an AS alias"
					}
					step.name = ft_token(args[at+1])
					at += 2
				}
			}
			err: string
			step.expr, err = ft_expr_parse(expr)
			if err != "" {
				return err
			}
			out.search.execute_options.track_matches = out.search.execute_options.track_matches || ft_expr_tracks_matches(step.expr)
			append(&out.steps, step)
		case "GROUPBY":
			projected = true
			step := FT_Pipeline_Step{kind = .Group}
			fields, err := search_counted_args(args, &at, token, a)
			if err != "" {
				return err
			}
			step.fields = make([]Search_Return_Field, len(fields), a)
			for field, i in fields {
				name := ft_token(field)
				if len(name) == 0 || name[0] != '@' {
					return ft_error("SEARCH_PARSE_ARGS Bad arguments for GROUPBY: Unknown property `", name, "`. Did you mean `@", name, "`?")
				}
				name = ft_property(name)
				step.fields[i] = {name, name}
			}
			reducers := make([dynamic]FT_Reducer, a)
			collect := false
			for at < len(args) && eq_nocase(args[at], "reduce") {
				at += 1
				reducer, reducer_error := ft_reducer_parse(args, &at)
				if reducer_error != "" {
					return reducer_error
				}
				collect = collect || reducer.kind == .Collect
				append(&reducers, reducer)
			}
			collect_depth += int(collect)
			if collect_depth > 32 {
				return "SEARCH_PARSE_ARGS Aggregation nesting limit exceeded"
			}
			step.reducers = reducers[:]
			append(&out.steps, step)
		case "SORTBY":
			if out.sorted {
				return "SEARCH_PARSE_ARGS Multiple SORTBY steps are not allowed. Sort multiple fields in a single step"
			}
			out.sorted = true
			step := FT_Pipeline_Step{kind = .Sort}
			tokens, err := search_counted_args(args, &at, token, a)
			if err != "" {
				return err
			}
			if step.order, err = ft_sort_fields(tokens); err != "" {
				return err
			}
			if at < len(args) && eq_nocase(args[at], "max") {
				at += 1
				if at == len(args) {
					return ft_argument_error("MAX", SEARCH_MISSING_ARGUMENT)
				}
				value, ok := search_number(args[at])
				if !ok {
					return ft_argument_error("MAX", SEARCH_INVALID_ARGUMENT)
				}
				if value < 0 || value > FT_AGGREGATE_LIMIT {
					return ft_argument_error("MAX", SEARCH_ARGUMENT_BOUNDS)
				}
				step.maximum = int(value)
				at += 1
			}
			append(&out.steps, step)
		case "LIMIT":
			off, take, err := ft_aggregate_limit(args[at:], hybrid)
			if err != "" {
				return err
			}
			at += 2
			append(&out.steps, FT_Pipeline_Step{kind = .Limit, offset = off, count = take})
		case "WITHCURSOR":
			if err := ft_cursor_options(args, &at, &out.cursor); err != "" {
				return err
			}
		case "PARAMS":
			pairs, err := search_counted_args(args, &at, token, a)
			if err != "" {
				return err
			}
			if has_params {
				return "SEARCH_ADD_ARGS Multiple PARAMS are not allowed. Parameters can be defined only once"
			}
			has_params = true
			out.search.query_options.params, err = search_params(pairs, a)
			if err != "" {
				return err
			}
		case "INKEYS":
			if hybrid || !on_json {
				return ft_unknown_argument(args, position)
			}
			keys, err := search_counted_args(args, &at, token, a)
			if err != "" {
				return err
			}
			out.search.has_in_keys = true
			out.search.in_keys = keys
		case "DIALECT":
			if hybrid {
				return FT_HYBRID_DIALECT_ERROR
			}
			if at == len(args) {
				return "SEARCH_PARSE_ARGS Need an argument for DIALECT"
			}
			value, ok := search_number(args[at])
			if !ok || value < 1 || value > 4 {
				return "SEARCH_PARSE_ARGS DIALECT requires a non negative integer >=1 and <= 4"
			}
			out.search.query_options.dialect = int(value)
			at += 1
		case "TIMEOUT":
			if at == len(args) {
				return "SEARCH_PARSE_ARGS Need argument for TIMEOUT"
			}
			value, ok := search_number(args[at])
			if !ok || value < 0 {
				return "SEARCH_PARSE_ARGS TIMEOUT requires a non negative integer"
			}
			out.search.timeout_ms = value
			at += 1
		case "WITHCOUNT", "WITHOUTCOUNT":
			if len(out.steps) > 0 {
				if out.steps[len(out.steps)-1].kind != .Sort {
					return ft_unknown_argument(args, position)
				}
			}
			out.count_all = token == "WITHCOUNT"
		case "COMBINE", "EXPLAINSCORE":
			if !hybrid {
				return ft_unknown_argument(args, position)
			}
			if token == "EXPLAINSCORE" {
				hybrid_request.explain = true
			} else if err := ft_hybrid_combine(args, &at, hybrid_request); err != "" {
				return err
			}
		case "NOSORT":
			if !hybrid {
				return ft_unknown_argument(args, position)
			}
			out.no_sort = true
		case "ADDSCORES", "VERBATIM", "NOSTOPWORDS", "SCORER", "LANGUAGE", "FORMAT":
			if hybrid || (len(out.steps) != 0 && !(on_json && token == "FORMAT")) {
				if hybrid {
					return ft_error("SEARCH_PARSE_ARGS ", ft_token(args[position]), ": Unknown argument")
				}
				return ft_unknown_argument(args, position)
			}
			err := ft_pipeline_search_option(out, token, args, &at)
			if err != "" {
				return err
			}
		case:
			if hybrid {
				return ft_error("SEARCH_PARSE_ARGS ", ft_token(args[position]), ": Unknown argument")
			}
			return ft_unknown_argument(args, position)
		}
	}
	if out.no_sort && out.sorted {
		return "SEARCH_PARSE_ARGS NOSORT is not allowed with SORTBY"
	}
	if out.scorer != "" {
		kind, ok := fi.scorer_kind(out.scorer)
		if !ok {
			return ft_error("SEARCH_QUERY_BAD No such scorer ", out.scorer)
		}
		out.search.execute_options.scorer_kind = kind
	}
	return ""
}

ft_pipeline_search_option :: proc(out: ^FT_Pipeline, token: string, args: [][]u8, at: ^int) -> string {
	switch token {
	case "ADDSCORES":
		out.add_scores = true
	case "VERBATIM":
		out.search.query_options.verbatim = true
	case "NOSTOPWORDS":
		out.search.query_options.no_stop_words = true
	case "SCORER", "LANGUAGE", "FORMAT":
		if at^ == len(args) {
			return ft_argument_error(token, SEARCH_MISSING_ARGUMENT)
		}
		value := args[at^]
		at^ += 1
		switch token {
		case "SCORER":
			out.scorer = ft_token(value)
		case "LANGUAGE":
			language_args := [2][]u8{args[at^-2], value}
			request, err := search_request_parse(language_args[:])
			if err != "" {
				return err
			}
			out.search.query_options.language = request.query_options.language
		case "FORMAT":
			if eq_nocase(value, "expand") {
				out.expand = true
			} else if !eq_nocase(value, "string") {
				return "SEARCH_VALUE_BAD Invalid FORMAT value"
			}
		}
	}
	return ""
}

ft_load_fields :: proc(args: [][]u8) -> ([]Search_Return_Field, string) {
	fields := make([dynamic]Search_Return_Field, 0, len(args), context.temp_allocator)
	for at := 0; at < len(args); {
		name := ft_property(ft_token(args[at]))
		identifier := name
		at += 1
		if at < len(args) && eq_nocase(args[at], "as") {
			if at + 1 == len(args) {
				return nil, "SEARCH_PARSE_ARGS LOAD path AS name - must be accompanied with NAME"
			}
			name = ft_token(args[at+1])
			at += 2
		}
		append(&fields, Search_Return_Field{identifier, name})
	}
	return fields[:], ""
}

ft_sort_fields :: proc(args: [][]u8) -> ([]FT_Order, string) {
	order := make([dynamic]FT_Order, context.temp_allocator)
	for at := 0; at < len(args); {
		token := args[at]
		at += 1
		if eq_nocase(token, "asc") || eq_nocase(token, "desc") {
			continue
		}
		name := ft_token(token)
		if len(name) == 0 || name[0] != '@' {
			return nil, ft_error("SEARCH_PARSE_ARGS MISSING ASC or DESC after sort field (", name, ")")
		}
		field := FT_Order{name = ft_property(name)}
		if at < len(args) && (eq_nocase(args[at], "asc") || eq_nocase(args[at], "desc")) {
			field.desc = eq_nocase(args[at], "desc")
			at += 1
		}
		append(&order, field)
	}
	return order[:], ""
}

ft_aggregate_limit :: proc(args: [][]u8, hybrid: bool) -> (int, int, string) {
	if hybrid {
		return search_limit(args)
	}
	if len(args) < 2 {
		return 0, 0, "SEARCH_PARSE_ARGS LIMIT requires two arguments"
	}
	offset, good_offset := search_number(args[0])
	count, good_count := search_number(args[1])
	if !good_offset || !good_count || offset < 0 || count < 0 {
		return 0, 0, "SEARCH_PARSE_ARGS LIMIT needs two numeric arguments"
	}
	if count == 0 && offset != 0 {
		return 0, 0, "SEARCH_LIMIT_OVER The `offset` of the LIMIT must be 0 when `num` is 0"
	}
	limit := ft_config_numbers[.Max_Aggregate]
	return search_limit_bounds(offset, count, limit if limit >= 0 else FT_AGGREGATE_LIMIT)
}

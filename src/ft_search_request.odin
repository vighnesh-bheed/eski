package main

import "core:mem"
import "ftindex"
import "ftquery"
import "text"

Search_Return_Field :: struct {
	identifier: string,
	name:       string,
}

Search_Request :: struct {
	query_options:   ftindex.Query_Options,
	execute_options: ftindex.Execute_Options,
	offset, count:   int,
	sort_by:         string,
	has_sort:        bool,
	sort_desc:       bool,
	with_count:      bool,
	with_scores:     bool,
	with_payloads:   bool,
	with_sort_keys:  bool,
	no_content:      bool,
	has_return:      bool,
	return_fields:   []Search_Return_Field,
	timeout_ms:      Maybe(i64),
	has_in_keys:     bool,
	in_keys:         [][]u8,
	in_fields:       [][]u8,
	filters:          [dynamic]Search_Legacy_Filter,
	snippet:          Search_Snippet,
	json_expand:      bool,
}

@(private = "file")
Search_Option :: enum {
	Unknown,
	No_Content, With_Scores, With_Sort_Keys, With_Count, Scorer, Return, Sort_By,
	Limit, Params, Dialect, Verbatim, No_Stop_Words, Language, In_Order, Slop,
	Timeout, In_Keys, In_Fields, With_Payloads, Filter, Geo_Filter, Summarize,
	Highlight, Expander, Explain_Score, Payload, Format,
}

@(private = "file")
SEARCH_OPTION_NAMES := [Search_Option]string {
	.Unknown        = "",
	.No_Content     = "nocontent",
	.With_Scores    = "withscores",
	.With_Sort_Keys = "withsortkeys",
	.With_Count     = "withcount",
	.Scorer         = "scorer",
	.Return         = "return",
	.Sort_By        = "sortby",
	.Limit          = "limit",
	.Params         = "params",
	.Dialect        = "dialect",
	.Verbatim       = "verbatim",
	.No_Stop_Words  = "nostopwords",
	.Language       = "language",
	.In_Order       = "inorder",
	.Slop           = "slop",
	.Timeout        = "timeout",
	.In_Keys        = "inkeys",
	.In_Fields      = "infields",
	.With_Payloads  = "withpayloads",
	.Filter         = "filter",
	.Geo_Filter     = "geofilter",
	.Summarize      = "summarize",
	.Highlight      = "highlight",
	.Expander       = "expander",
	.Explain_Score  = "explainscore",
	.Payload        = "payload",
	.Format         = "format",
}

SEARCH_DEFAULT_DIALECT :: 1

@(private = "file")
SEARCH_DEFAULT_COUNT :: 10

SEARCH_MAX_PAGE :: 1_000_000

SEARCH_OUT_OF_MEMORY :: "ERR out of memory"

SEARCH_MISSING_ARGUMENT :: "Expected an argument, but none provided"

SEARCH_INVALID_ARGUMENT :: "Could not convert argument to expected type"

SEARCH_ARGUMENT_BOUNDS :: "Value is outside acceptable bounds"

search_request_parse :: proc(args: [][]u8, allocator := context.temp_allocator, on_json := false) -> (Search_Request, string) {
	out := Search_Request{count = SEARCH_DEFAULT_COUNT}
	ft_config_search_options(&out)
	scorer, language: []u8
	has_language, has_scorer, explain_score: bool
	for i := 0; i < len(args); {
		token := search_option_text(args[i])
		position := i + 1
		i += 1
		option := search_option(token)
		switch option {
		case .No_Content:
			out.no_content = true
		case .With_Scores:
			out.with_scores = true
		case .With_Sort_Keys:
			out.with_sort_keys = true
		case .With_Count:
			out.with_count = true
		case .Verbatim:
			out.query_options.verbatim = true
		case .No_Stop_Words:
			out.query_options.no_stop_words = true
		case .In_Order:
			out.execute_options.in_order = true
		case .Explain_Score:
			explain_score = true
		case .Scorer, .Language:
			if i == len(args) {
				return {}, search_argument_error("SCORER" if option == .Scorer else "LANGUAGE", SEARCH_MISSING_ARGUMENT, allocator)
			}
			if option == .Scorer {
				scorer = search_option_text(args[i])
				has_scorer = true
			} else {
				language = search_option_text(args[i])
				has_language = true
			}
			i += 1
		case .Return:
			fields, err := search_counted_args(args, &i, "RETURN", allocator)
			if err != "" {
				return {}, err
			}
			out.return_fields, err = search_return_fields(fields, allocator)
			if err != "" {
				return {}, err
			}
			out.has_return = true
		case .In_Keys, .In_Fields:
			keys := option == .In_Keys
			input, err := search_counted_args(args, &i, "INKEYS" if keys else "INFIELDS", allocator)
			if err != "" {
				return {}, err
			}
			if keys {
				out.has_in_keys = true
				out.in_keys = input
			} else {
				out.in_fields = input
			}
		case .Params:
			pairs, err := search_counted_args(args, &i, "PARAMS", allocator)
			if err != "" {
				return {}, err
			}
			if out.query_options.params != nil {
				return {}, "SEARCH_ADD_ARGS Multiple PARAMS are not allowed. Parameters can be defined only once"
			}
			out.query_options.params, err = search_params(pairs, allocator)
			if err != "" {
				return {}, err
			}
		case .Sort_By:
			if out.has_sort {
				return {}, "SEARCH_PARSE_ARGS Multiple SORTBY steps are not allowed"
			}
			if i == len(args) {
				return {}, "SEARCH_PARSE_ARGS Bad SORTBY arguments"
			}
			out.has_sort, out.sort_by = true, string(search_option_text(args[i]))
			i += 1
			if i < len(args) {
				direction := search_option_text(args[i])
				if eq_nocase(direction, "asc") || eq_nocase(direction, "desc") {
					out.sort_desc = eq_nocase(direction, "desc")
					i += 1
				}
			}
		case .Limit:
			offset, count, err := search_limit(args[i:])
			if err != "" {
				return {}, err
			}
			out.offset, out.count = offset, count
			i += 2
		case .Slop:
			if i == len(args) {
				return {}, search_argument_error("SLOP", SEARCH_MISSING_ARGUMENT, allocator)
			}
			n, ok := search_number(args[i])
			if !ok {
				return {}, search_argument_error("SLOP", SEARCH_INVALID_ARGUMENT, allocator)
			}
			if n < i64(min(i32)) || n > i64(max(i32)) {
				return {}, search_argument_error("SLOP", SEARCH_ARGUMENT_BOUNDS, allocator)
			}
			out.execute_options.slop = int(n)
			i += 1
		case .Timeout:
			if i == len(args) {
				return {}, "SEARCH_PARSE_ARGS Need argument for TIMEOUT"
			}
			n, ok := search_number(args[i])
			if !ok || n < 0 {
				return {}, "SEARCH_PARSE_ARGS TIMEOUT requires a non negative integer"
			}
			out.timeout_ms = n
			i += 1
		case .Dialect:
			if i == len(args) {
				return {}, "SEARCH_PARSE_ARGS Need an argument for DIALECT"
			}
			n, ok := search_number(args[i])
			if !ok || n < 1 || n > 4 {
				return {}, "SEARCH_PARSE_ARGS DIALECT requires a non negative integer >=1 and <= 4"
			}
			out.query_options.dialect = int(n)
			i += 1
		case .With_Payloads:
			out.with_payloads = true
		case .Summarize, .Highlight:
			if err := search_snippet_parse(&out.snippet, option == .Highlight, args, &i, allocator); err != "" {
				return {}, err
			}
			out.execute_options.track_matches = true
		case .Filter, .Geo_Filter:
			filter, err := search_legacy_filter(args[i:], option == .Geo_Filter)
			if err != "" {
				return {}, err
			}
			if out.filters == nil {
				out.filters = make([dynamic]Search_Legacy_Filter, allocator)
			}
			append(&out.filters, filter)
			i += 5 if option == .Geo_Filter else 3
		case .Payload:
			if i == len(args) {
				return {}, search_argument_error("PAYLOAD", SEARCH_MISSING_ARGUMENT, allocator)
			}
			out.execute_options.payload = string(args[i])
			i += 1
		case .Expander:
			name := "EXPANDER"
			if i == len(args) {
				return {}, search_argument_error(name, SEARCH_MISSING_ARGUMENT, allocator)
			}
			return {}, search_error_text(allocator, "SEARCH_OPTION_INVALID ", name, " is not supported")
		case .Format:
			if !on_json {
				return {}, "SEARCH_OPTION_INVALID FORMAT is not supported"
			}
			if i == len(args) {
				return {}, search_argument_error("FORMAT", SEARCH_MISSING_ARGUMENT, allocator)
			}
			if !eq_nocase(args[i], "expand") && !eq_nocase(args[i], "string") {
				return {}, "SEARCH_VALUE_BAD Invalid FORMAT value"
			}
			out.json_expand = eq_nocase(args[i], "expand")
			i += 1
		case .Unknown:
			pos: [24]u8
			n := format_i64(raw_data(pos[:]), i64(position))
			return {}, search_error_text(allocator, "SEARCH_ARG_UNRECOGNIZED Unknown argument `", string(token), "` at position ", string(pos[:n]), " for <main>")
		}
	}
	if has_language {
		lang, known := text.language_parse(language)
		if !known {
			return {}, "SEARCH_QUERY_BAD No such language"
		}
		if lang != .English {
			return {}, search_error_text(allocator, "SEARCH_OPTION_INVALID LANGUAGE ", text.language_name(lang), " is not supported")
		}
		out.query_options.language = text.language_name(lang)
	}
	if has_scorer {
		kind, known := ftindex.scorer_kind(string(scorer))
		if !known {
			return {}, search_error_text(allocator, "SEARCH_QUERY_BAD No such scorer ", string(scorer))
		}
		out.execute_options.scorer_kind = kind
	}
	if explain_score && !out.with_scores {
		return {}, "SEARCH_PARSE_ARGS EXPLAINSCORE must be accompanied with WITHSCORES"
	}
	out.execute_options.explain_scores = explain_score
	out.no_content = out.no_content || (out.has_return && len(out.return_fields) == 0)
	return out, ""
}

@(private = "file")
search_option :: proc "contextless" (token: []u8) -> Search_Option {
	for option in Search_Option {
		if eq_nocase(token, SEARCH_OPTION_NAMES[option]) {
			return option
		}
	}
	return .Unknown
}

search_option_text :: proc "contextless" (token: []u8) -> []u8 {
	for c, i in token {
		if c == 0 {
			return token[:i]
		}
	}
	return token
}

search_error_text :: proc(allocator: mem.Allocator, parts: ..string) -> string {
	n := 0
	for part in parts {
		if len(part) > max(int) - n {
			return SEARCH_OUT_OF_MEMORY
		}
		n += len(part)
	}
	buf, err := make([]u8, n, allocator)
	if err != nil || len(buf) != n {
		return SEARCH_OUT_OF_MEMORY
	}
	start := 0
	for part in parts {
		start += copy(buf[start:], part)
	}
	for &c in buf {
		if c == '\r' || c == '\n' {
			c = ' '
		}
	}
	return string(buf)
}

search_argument_error :: proc(name, message: string, allocator: mem.Allocator) -> string {
	return search_error_text(allocator, "SEARCH_PARSE_ARGS Bad arguments for ", name, ": ", message)
}

search_number :: proc "contextless" (arg: []u8) -> (i64, bool) {
	input := search_option_text(arg)
	if len(input) == 0 {
		return 0, true
	}
	at := 0
	for at < len(input) {
		c := input[at]
		if c != ' ' && (c < '\t' || c > '\r') {
			break
		}
		at += 1
	}
	if at == len(input) {
		return 0, false
	}
	negative := input[at] == '-'
	if negative || input[at] == '+' {
		at += 1
	}
	if at == len(input) {
		return 0, false
	}
	for at < len(input) - 1 && input[at] == '0' {
		at += 1
	}
	if input[at] < '0' || input[at] > '9' {
		return 0, false
	}
	n, ok := parse_i64(input[at:])
	if !ok || n == max(i64) {
		return 0, false
	}
	return -n if negative else n, true
}

search_counted_args :: proc(args: [][]u8, position: ^int, option: string, allocator: mem.Allocator) -> ([][]u8, string) {
	at := position^
	if at == len(args) {
		return nil, search_argument_error(option, SEARCH_MISSING_ARGUMENT, allocator)
	}
	count, ok := search_number(args[at])
	if !ok {
		return nil, search_argument_error(option, SEARCH_INVALID_ARGUMENT, allocator)
	}
	if count < 0 || count > i64(max(u32)) {
		return nil, search_argument_error(option, SEARCH_ARGUMENT_BOUNDS, allocator)
	}
	at += 1
	if count > i64(len(args) - at) {
		return nil, search_argument_error(option, SEARCH_MISSING_ARGUMENT, allocator)
	}
	position^ = at + int(count)
	return args[at:position^], ""
}

search_limit :: proc (args: [][]u8) -> (int, int, string) {
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
	return search_limit_bounds(offset, count, ft_config_numbers[.Max_Search])
}

@(private = "file")
search_return_fields :: proc(tokens: [][]u8, allocator: mem.Allocator) -> ([]Search_Return_Field, string) {
	if len(tokens) == 0 {
		return nil, ""
	}
	fields, err := make([]Search_Return_Field, len(tokens), allocator)
	if err != nil || len(fields) != len(tokens) {
		return nil, SEARCH_OUT_OF_MEMORY
	}
	seen, map_err := make(map[string]bool, 0, allocator)
	if map_err != nil {
		return nil, SEARCH_OUT_OF_MEMORY
	}
	defer delete(seen)
	count := 0
	for i := 0; i < len(tokens); {
		identifier := string(search_option_text(tokens[i]))
		i += 1
		name := identifier
		if i < len(tokens) && eq_nocase(search_option_text(tokens[i]), "as") {
			if len(tokens) - i < 2 {
				return nil, "SEARCH_PARSE_ARGS RETURN path AS name - must be accompanied with NAME"
			}
			name = string(search_option_text(tokens[i+1]))
			i += 2
		}
		if seen[name] {
			continue
		}
		if map_insert(&seen, name, true) == nil {
			return nil, SEARCH_OUT_OF_MEMORY
		}
		fields[count] = {identifier = identifier, name = name}
		count += 1
	}
	return fields[:count], ""
}

search_params :: proc(pairs: [][]u8, allocator: mem.Allocator) -> ([]ftquery.Param, string) {
	if len(pairs) == 0 || len(pairs) % 2 != 0 {
		return nil, "SEARCH_ADD_ARGS Parameters must be specified in PARAM VALUE pairs"
	}
	params, err := make([]ftquery.Param, len(pairs) / 2, allocator)
	if err != nil || len(params) != len(pairs) / 2 {
		return nil, SEARCH_OUT_OF_MEMORY
	}
	seen, map_err := make(map[string]bool, 0, allocator)
	if map_err != nil {
		return nil, SEARCH_OUT_OF_MEMORY
	}
	defer delete(seen)
	for i := 0; i < len(pairs); i += 2 {
		name := string(search_option_text(pairs[i]))
		if seen[name] {
			return nil, search_error_text(allocator, "SEARCH_ADD_ARGS Duplicate parameter `", name, "`")
		}
		if map_insert(&seen, name, true) == nil {
			return nil, SEARCH_OUT_OF_MEMORY
		}
		params[i/2] = {name = name, value = string(pairs[i+1])}
	}
	return params, ""
}

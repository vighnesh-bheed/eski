package main

import fi "ftindex"

FT_Config_Option :: enum {
	Min_Prefix,
	Min_Stem,
	Max_Search,
	Max_Aggregate,
	Max_Expansions,
	Max_Prefix_Expansions,
	Timeout,
	Scorer,
	Cursor_Idle,
	Cursor_Limit,
	Dialect,
	Tanh_Factor,
}

FT_Config_Entry :: struct {
	name, description: string,
}

ft_config_entries := [FT_Config_Option]FT_Config_Entry{
	.Min_Prefix = {"MINPREFIX", "Set the minimum prefix for expansions (`*`)"},
	.Min_Stem = {"MINSTEMLEN", "Set the minimum word length to stem (default 4)"},
	.Max_Search = {"MAXSEARCHRESULTS", "Maximum number of results from ft.search command"},
	.Max_Aggregate = {"MAXAGGREGATERESULTS", "Maximum number of results from ft.aggregate command"},
	.Max_Expansions = {"MAXEXPANSIONS", "Maximum prefix expansions to be used in a query"},
	.Max_Prefix_Expansions = {"MAXPREFIXEXPANSIONS", "Maximum prefix expansions to be used in a query"},
	.Timeout = {"TIMEOUT", "Query (search) timeout"},
	.Scorer = {"DEFAULT_SCORER", "Default scorer to use when no scorer is specified in queries"},
	.Cursor_Idle = {"CURSOR_MAX_IDLE", "max idle time allowed to be set for cursor, setting it height might cause high memory consumption."},
	.Cursor_Limit = {"INDEX_CURSOR_LIMIT", "Max number of cursors for a given index that can be opened inside of a shard. Default is 128"},
	.Dialect = {"DEFAULT_DIALECT", "Set RediSearch default dialect version through the lifetime of the server."},
	.Tanh_Factor = {"BM25STD_TANH_FACTOR", "Set the BM25STD.TANH stretch factor. This is an integer value that divides the argument of the tanh function that is used to normalize the score computed by the BM25STD scorer.The default value is 4."},
}

ft_config_numbers := [FT_Config_Option]i64{
	.Min_Prefix = 2,
	.Min_Stem = 4,
	.Max_Search = SEARCH_MAX_PAGE,
	.Max_Aggregate = -1,
	.Max_Expansions = 200,
	.Max_Prefix_Expansions = 200,
	.Timeout = SEARCH_TIMEOUT_MS,
	.Scorer = 0,
	.Cursor_Idle = FT_CURSOR_IDLE,
	.Cursor_Limit = FT_CURSOR_CAPACITY,
	.Dialect = SEARCH_DEFAULT_DIALECT,
	.Tanh_Factor = 4,
}
ft_config_scorer: fi.Scorer_Kind

ft_config_search_options :: proc(out: ^Search_Request) {
	out.query_options.dialect = int(ft_config_numbers[.Dialect])
	out.execute_options.scorer_kind = ft_config_scorer
	out.execute_options.minimum_pattern = int(ft_config_numbers[.Min_Prefix])
	out.execute_options.expansions = int(ft_config_numbers[.Max_Prefix_Expansions])
	out.execute_options.tanh_factor = f64(ft_config_numbers[.Tanh_Factor])
}

cmd_ft_config :: proc(c: ^Conn, argv: [][]u8) {
	get := eq_nocase(argv[1], "get")
	help := eq_nocase(argv[1], "help")
	set := eq_nocase(argv[1], "set")
	if !get && !help && !set {
		reply_error(c, ft_error("ERR unknown subcommand '", ft_token(argv[1]), "'. Try FT.CONFIG HELP."))
		return
	}
	if len(argv) < 3 || (set && len(argv) < 4) {
		reply_error(c, ft_error("ERR wrong number of arguments for 'FT.CONFIG|", "SET" if set else ("HELP" if help else "GET"), "' command"))
		return
	}
	found: Maybe(FT_Config_Option)
	for option in FT_Config_Option {
		if command_subcommand_matches(argv[2], ft_config_entries[option].name) {
			found = option
			break
		}
	}
	if set {
		if labels_on && !access.top {
			reply_error(c, "NOPERM FT.CONFIG SET requires the top scope")
			return
		}
		if len(argv) > 4 {
			reply_error(c, "EXCESSARGS")
			return
		}
		if option, known := found.?; known {
			if err := ft_config_set(option, argv[3]); err != "" {
				reply_error(c, err)
			} else {
				reply_ok(c)
			}
		} else {
			reply_error(c, "SEARCH_OPTION_INVALID Invalid option")
		}
		return
	}
	all := string(argv[2]) == "*"
	count := len(ft_config_entries) if all else int(found != nil)
	if c.resp >= RESP3 {
		reply_map(c, count)
	} else {
		reply_array(c, count)
	}
	for option in FT_Config_Option {
		if all || found == option {
			ft_config_reply(c, option, help)
		}
	}
}

ft_config_reply :: proc(c: ^Conn, option: FT_Config_Option, help: bool) {
	entry := ft_config_entries[option]
	if c.resp < RESP3 {
		reply_array(c, 5 if help else 2)
	}
	reply_simple(c, entry.name)
	if help {
		if c.resp >= RESP3 {
			reply_map(c, 2)
		}
		reply_simple(c, "Description")
		reply_simple(c, entry.description)
		reply_simple(c, "Value")
	}
	value := ft_config_numbers[option]
	if option == .Scorer {
		reply_bulk_str(c, fi.SCORER_NAMES[ft_config_scorer])
	} else if value < 0 {
		reply_bulk_str(c, "unlimited")
	} else {
		reply_bulk_str(c, ft_int_text(value))
	}
}

ft_config_set :: proc(option: FT_Config_Option, arg: []u8) -> string {
	if option == .Scorer {
		kind, known := fi.scorer_kind(string(arg))
		if !known || len(arg) == 0 {
			return "SEARCH_VALUE_BAD Invalid default scorer value"
		}
		ft_config_scorer = kind
		return ""
	}
	value, valid := search_number(arg)
	if !valid {
		return ft_error("SEARCH_PARSE_ARGS ", SEARCH_INVALID_ARGUMENT)
	}
	minimum: i64 = 1
	#partial switch option {
	case .Timeout, .Cursor_Limit:
		minimum = 0
	case .Max_Search, .Max_Aggregate:
		minimum = min(i64)
	case:
	}
	if value < minimum || value > i64(max(int)) {
		return ft_error("SEARCH_PARSE_ARGS ", SEARCH_ARGUMENT_BOUNDS)
	}
	if option == .Dialect && value > 4 {
		return "SEARCH_VALUE_BAD Default dialect version cannot be higher than 4"
	}
	ft_config_numbers[option] = value
	if option == .Max_Expansions || option == .Max_Prefix_Expansions {
		ft_config_numbers[.Max_Expansions], ft_config_numbers[.Max_Prefix_Expansions] = value, value
	}
	return ""
}

search_limit_bounds :: proc(offset, count, ceiling: i64) -> (int, int, string) {
	if ceiling >= 0 {
		if offset > ceiling {
			return 0, 0, ft_error("SEARCH_LIMIT_OVER OFFSET exceeds maximum of ", ft_int_text(ceiling))
		}
		if count > ceiling {
			return 0, 0, ft_error("SEARCH_LIMIT_OVER LIMIT exceeds maximum of ", ft_int_text(ceiling))
		}
	}
	return int(offset), int(count), ""
}

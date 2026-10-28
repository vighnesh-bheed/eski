package listtype

import "../integer"

WRONGTYPE_ERROR :: "WRONGTYPE Operation against a key holding the wrong kind of value"

ERR_NOT_INTEGER :: "value is not an integer or out of range"

ERR_MUST_BE_POSITIVE :: "value is out of range, must be positive"

ERR_LONG_RANGE :: "value is out of range, value must between -9223372036854775807 and 9223372036854775807"

ERR_SYNTAX :: "syntax error"

ERR_RANK_ZERO :: "RANK can't be zero: use 1 to start from the first match, 2 from the second ... or use negative to start from the end of the list"

ERR_COUNT_NEGATIVE :: "COUNT can't be negative"

ERR_MAXLEN_NEGATIVE :: "MAXLEN can't be negative"

ERR_NUMKEYS :: "numkeys should be greater than 0"

ERR_COUNT_POSITIVE :: "count should be greater than 0"

ERR_INDEX_OUT_OF_RANGE :: "index out of range"

ERR_NO_SUCH_KEY :: "no such key"

ERR_PACKED_THRESHOLD :: "argument must be a memory value bigger than 1 and smaller than 4gb"

Error :: enum u8 {
	None,
	Not_Integer,
	Must_Be_Positive,
	Long_Range,
	Syntax,
	Rank_Zero,
	Count_Negative,
	Maxlen_Negative,
	Numkeys,
	Count_Positive,
	Index_Out_Of_Range,
	No_Such_Key,
	Packed_Threshold,
}

	ERROR_MESSAGES := [Error]string {
	.None               = "",
	.Not_Integer        = ERR_NOT_INTEGER,
	.Must_Be_Positive   = ERR_MUST_BE_POSITIVE,
	.Long_Range         = ERR_LONG_RANGE,
	.Syntax             = ERR_SYNTAX,
	.Rank_Zero          = ERR_RANK_ZERO,
	.Count_Negative     = ERR_COUNT_NEGATIVE,
	.Maxlen_Negative    = ERR_MAXLEN_NEGATIVE,
	.Numkeys            = ERR_NUMKEYS,
	.Count_Positive     = ERR_COUNT_POSITIVE,
	.Index_Out_Of_Range = ERR_INDEX_OUT_OF_RANGE,
	.No_Such_Key        = ERR_NO_SUCH_KEY,
	.Packed_Threshold   = ERR_PACKED_THRESHOLD,
}

Lpos_Args :: struct {
	rank:   int,
	count:  int,
	maxlen: int,
}

Mpop_Args :: struct {
	numkeys: int,
	where_:  Where,
	count:   int,
}

Config_Param :: enum u8 {
	None,
	Max_Listpack_Size,
	Max_Ziplist_Size,
	Compress_Depth,
}

	CONFIG_NAMES := [Config_Param]string {
	.None              = "",
	.Max_Listpack_Size = "list-max-listpack-size",
	.Max_Ziplist_Size  = "list-max-ziplist-size",
	.Compress_Depth    = "list-compress-depth",
}

error_message :: proc "contextless" (e: Error) -> string {
	return ERROR_MESSAGES[e]
}

lower_byte :: proc "contextless" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

eq_nocase :: proc "contextless" (a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for v, i in a {
		if lower_byte(v) != lower_byte(b[i]) {
			return false
		}
	}
	return true
}

parse_long :: proc "contextless" (s: []u8) -> (v: i64, ok: bool) {
	return integer.parse_i64(s)
}

parse_index :: proc "contextless" (s: []u8) -> (int, Error) {
	v, ok := parse_long(s)
	if !ok {
		return 0, .Not_Integer
	}
	return int(v), .None
}

parse_range_long :: proc "contextless" (s: []u8, lo: i64, hi: i64, msg: Error) -> (int, Error) {
	v, ok := parse_long(s)
	if !ok {
		return 0, .Not_Integer
	}
	if v < lo || v > hi {
		return 0, msg
	}
	return int(v), .None
}

parse_pop_count :: proc "contextless" (s: []u8) -> (int, Error) {
	v, ok := parse_long(s)
	if !ok || v < 0 {
		return 0, .Must_Be_Positive
	}
	return int(v), .None
}

parse_lrem_count :: proc "contextless" (s: []u8) -> (int, Error) {
	return parse_range_long(s, -max(i64), max(i64), .Long_Range)
}

parse_direction :: proc "contextless" (s: []u8) -> (Where, Error) {
	if eq_nocase(s, "left") {
		return .Head, .None
	}
	if eq_nocase(s, "right") {
		return .Tail, .None
	}
	return .Head, .Syntax
}

parse_linsert_where :: proc "contextless" (s: []u8) -> (after: bool, err: Error) {
	if eq_nocase(s, "before") {
		return false, .None
	}
	if eq_nocase(s, "after") {
		return true, .None
	}
	return false, .Syntax
}

parse_lpos_args :: proc "contextless" (args: [][]u8) -> (a: Lpos_Args, err: Error) {
	a = {1, -1, 0}
	for i := 0; i < len(args); i += 2 {
		if i + 1 >= len(args) {
			return a, .Syntax
		}
		field: ^int
		msg: Error
		lo: i64 = 0
		if eq_nocase(args[i], "rank") {
			field = &a.rank
			msg = .Long_Range
			lo = -max(i64)
		} else if eq_nocase(args[i], "count") {
			field = &a.count
			msg = .Count_Negative
		} else if eq_nocase(args[i], "maxlen") {
			field = &a.maxlen
			msg = .Maxlen_Negative
		} else {
			return a, .Syntax
		}
		v, e := parse_range_long(args[i+1], lo, max(i64), msg)
		if e != .None {
			if field != &a.rank {
				return a, msg
			}
			return a, e
		}
		if field == &a.rank && v == 0 {
			return a, .Rank_Zero
		}
		field^ = v
	}
	return a, .None
}

parse_mpop_args :: proc "contextless" (argv: [][]u8, numkeys_idx: int) -> (a: Mpop_Args, err: Error) {
	a.count = 1
	if numkeys_idx >= len(argv) {
		return a, .Syntax
	}
	n, e := parse_index(argv[numkeys_idx])
	if e != .None || n <= 0 {
		return a, .Numkeys
	}
	a.numkeys = n
	if n > len(argv)-numkeys_idx-2 {
		return a, .Syntax
	}
	i := numkeys_idx + n + 1
	a.where_, e = parse_direction(argv[i])
	if e != .None {
		return a, e
	}
	i += 1
	if i == len(argv) {
		return a, .None
	}
	if i + 2 != len(argv) || !eq_nocase(argv[i], "count") {
		return a, .Syntax
	}
	n, e = parse_index(argv[i+1])
	if e != .None || n <= 0 {
		return a, .Count_Positive
	}
	a.count = n
	return a, .None
}

parse_memory :: proc "contextless" (s: []u8) -> (u64, bool) {
	if len(s) == 0 {
		return 0, true
	}
	i := 0
	n: u64
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		d := u64(s[i]-'0')
		if n > (max(u64)-d)/10 {
			return 0, false
		}
		n = n*10+d
		i += 1
	}
	multiplier: u64 = 1
	if i < len(s) {
		suffix := s[i:]
		if eq_nocase(suffix, "b") {
			multiplier = 1
		} else if eq_nocase(suffix, "k") {
			multiplier = 1000
		} else if eq_nocase(suffix, "kb") {
			multiplier = 1024
		} else if eq_nocase(suffix, "m") {
			multiplier = 1000*1000
		} else if eq_nocase(suffix, "mb") {
			multiplier = 1024*1024
		} else if eq_nocase(suffix, "g") {
			multiplier = 1000*1000*1000
		} else if eq_nocase(suffix, "gb") {
			multiplier = 1024*1024*1024
		} else {
			return 0, false
		}
	}
	if n > max(u64)/multiplier {
		return 0, false
	}
	return n*multiplier, true
}

parse_packed_threshold :: proc "contextless" (s: []u8) -> Error {
	n, ok := parse_memory(s)
	if !ok || !set_packed_threshold(n) {
		return .Packed_Threshold
	}
	return .None
}

config_param :: proc "contextless" (name: []u8) -> Config_Param {
	for p in Config_Param {
		if p != .None && eq_nocase(name, CONFIG_NAMES[p]) {
			return p
		}
	}
	return .None
}

config_value :: proc "contextless" (p: Config_Param) -> int {
	if p == .Compress_Depth {
		return list_compress_depth
	}
	return list_max_listpack_size
}

config_parse :: proc "contextless" (p: Config_Param, s: []u8) -> (v: int, err: string) {
	n, ok := parse_long(s)
	if !ok {
		return 0, "argument couldn't be parsed into an integer"
	}
	lo: i64 = i64(min(i32))
	if p == .Compress_Depth {
		lo = 0
	}
	if n < lo || n > i64(max(i32)) {
		if p == .Compress_Depth {
			return 0, "argument must be between 0 and 2147483647 inclusive"
		}
		return 0, "argument must be between -2147483648 and 2147483647 inclusive"
	}
	return int(n), ""
}

config_apply :: proc "contextless" (p: Config_Param, v: int) {
	if p == .Compress_Depth {
		list_compress_depth = v
	} else if p != .None {
		list_max_listpack_size = v
	}
}

package zsettype

import lp "../listpack"

Range_Kind :: enum u8 {
	Auto,
	Rank,
	Score,
	Lex,
}

Direction :: enum u8 {
	Auto,
	Forward,
	Reverse,
}

Zadd_Args :: struct {
	flags:    Zadd_Flags,
	ch:       bool,
	scoreidx: int,
	elements: int,
}

Zrange_Args :: struct {
	kind:       Range_Kind,
	reverse:    bool,
	withscores: bool,
	offset:     i64,
	limit:      i64,
	start:      i64,
	end:        i64,
	srange:     Range_Spec,
	lrange:     Lex_Spec,
}

Setop_Options :: struct {
	aggregate:  Aggregate,
	withscores: bool,
	limit:      i64,
}

Zmpop_Args :: struct {
	numkeys: int,
	max_end: bool,
	count:   i64,
}

cstr :: proc "contextless" (a: []u8) -> []u8 {
	for c, i in a {
		if c == 0 {
			return a[:i]
		}
	}
	return a
}

keyword :: proc "contextless" (a: []u8, word: string) -> bool {
	return eq_nocase(cstr(a), word)
}

parse_long :: proc "contextless" (s: []u8) -> (i64, bool) {
	value: i64
	if !lp.lp_string_to_int64(s, &value) {
		return 0, false
	}
	return value, true
}

parse_zadd :: proc "contextless" (argv: [][]u8, incr_cmd: bool) -> (a: Zadd_Args, err: Error) {
	i := 2
	if incr_cmd {
		a.flags = {.Incr}
	}
	for i < len(argv) {
		if keyword(argv[i], "nx") {
			a.flags |= {.Nx}
		} else if keyword(argv[i], "xx") {
			a.flags |= {.Xx}
		} else if keyword(argv[i], "gt") {
			a.flags |= {.Gt}
		} else if keyword(argv[i], "lt") {
			a.flags |= {.Lt}
		} else if keyword(argv[i], "ch") {
			a.ch = true
		} else if keyword(argv[i], "incr") {
			a.flags |= {.Incr}
		} else {
			break
		}
		i += 1
	}
	a.scoreidx = i
	a.elements = (len(argv) - i) / 2
	if len(argv) - i == 0 || (len(argv) - i) % 2 != 0 {
		return a, .Syntax
	}
	if .Nx in a.flags && .Xx in a.flags {
		return a, .Xx_Nx
	}
	if .Gt in a.flags && .Lt in a.flags || .Nx in a.flags && (.Gt in a.flags || .Lt in a.flags) {
		return a, .Gt_Lt_Nx
	}
	if .Incr in a.flags && a.elements != 1 {
		return a, .Incr_Pair
	}
	return
}

parse_zrange :: proc "contextless" (argv: [][]u8, argc_start: int, store: bool, kind_in: Range_Kind, dir_in: Direction) -> (a: Zrange_Args, err: Error) {
	a.kind = kind_in
	a.reverse = dir_in == .Reverse
	a.limit = -1
	has_limit := false
	for i := argc_start + 3; i < len(argv); i += 1 {
		if keyword(argv[i], "withscores") && !store {
			a.withscores = true
		} else if keyword(argv[i], "limit") && i + 2 < len(argv) {
			var_ok: bool
			a.offset, var_ok = parse_long(argv[i + 1])
			if !var_ok {
				return a, .Not_Integer
			}
			a.limit, var_ok = parse_long(argv[i + 2])
			if !var_ok {
				return a, .Not_Integer
			}
			i += 2
			has_limit = true
		} else if keyword(argv[i], "byscore") && kind_in == .Auto && a.kind == .Auto {
			a.kind = .Score
		} else if keyword(argv[i], "bylex") && kind_in == .Auto && a.kind == .Auto {
			a.kind = .Lex
		} else if keyword(argv[i], "rev") && dir_in == .Auto && !a.reverse {
			a.reverse = true
		} else {
			return a, .Syntax
		}
	}
	if a.kind == .Auto {
		a.kind = .Rank
	}
	if has_limit && a.kind == .Rank && (a.offset != 0 || a.limit != -1) {
		return a, .Limit_Rank
	}
	if a.withscores && a.kind == .Lex {
		return a, .Withscores_Lex
	}
	first, last := argv[argc_start + 1], argv[argc_start + 2]
	if a.kind == .Rank {
		good: bool
		a.start, good = parse_long(first)
		if !good {
			return a, .Not_Integer
		}
		a.end, good = parse_long(last)
		if !good {
			return a, .Not_Integer
		}
	} else {
		if a.reverse {
			first, last = last, first
		}
		good: bool
		if a.kind == .Score {
			a.srange, good = parse_range(first, last)
			if !good {
				return a, .Min_Max_Float
			}
		} else {
			a.lrange, good = parse_lex_range(first, last)
			if !good {
				return a, .Min_Max_Lex
			}
		}
	}
	return
}

parse_setop_numkeys :: proc "contextless" (argv: [][]u8, numkeys_index: int) -> (setnum: int, err: Error) {
	n, good := parse_long(argv[numkeys_index])
	if !good {
		return 0, .Not_Integer
	}
	if n < 1 {
		return 0, .At_Least_One_Key
	}
	if n > i64(len(argv) - numkeys_index - 1) {
		return 0, .Syntax
	}
	return int(n), .None
}

parse_setop_options :: proc "contextless" (argv: [][]u8, first: int, setnum: int, op: Setop, store: bool, cardinality_only: bool, weights: []f64) -> (o: Setop_Options, err: Error) {
	for &w in weights {
		w = 1
	}
	for i := first; i < len(argv); i += 1 {
		if cardinality_only && keyword(argv[i], "limit") && i + 1 < len(argv) {
			n, good := parse_long(argv[i + 1])
			if !good {
				return o, .Limit_Negative
			}
			if n < 0 {
				return o, .Limit_Negative
			}
			o.limit = n
			i += 1
		} else if !cardinality_only && op != .Diff && keyword(argv[i], "weights") && len(argv) - i > setnum {
			for j in 0 ..< setnum {
				v, good := parse_score(argv[i + j + 1])
				if !good {
					return o, .Weight_Float
				}
				weights[j] = v
			}
			i += setnum
		} else if !cardinality_only && op != .Diff && keyword(argv[i], "aggregate") && i + 1 < len(argv) {
			i += 1
			if keyword(argv[i], "sum") {
				o.aggregate = .Sum
			} else if keyword(argv[i], "min") {
				o.aggregate = .Min
			} else if keyword(argv[i], "max") {
				o.aggregate = .Max
			} else {
				return o, .Syntax
			}
		} else if !cardinality_only && !store && keyword(argv[i], "withscores") {
			o.withscores = true
		} else {
			return o, .Syntax
		}
	}
	return
}

parse_zrandmember :: proc "contextless" (argv: [][]u8) -> (count: i64, withscores: bool, err: Error) {
	if len(argv) < 3 {
		return 1, false, .None
	}
	n, good := parse_long(argv[2])
	if !good {
		return 0, false, .Not_Integer
	}
	if n == min(i64) {
		return 0, false, .Randmember_Range
	}
	if len(argv) > 4 || len(argv) == 4 && !keyword(argv[3], "withscores") {
		return 0, false, .Syntax
	}
	withscores = len(argv) == 4
	if withscores && (n < -(max(i64) / 2) || n > max(i64) / 2) {
		return 0, false, .Out_Of_Range
	}
	return n, withscores, .None
}

parse_zpop_count :: proc "contextless" (argv: [][]u8) -> (count: i64, err: Error) {
	if len(argv) == 2 {
		return -1, .None
	}
	if len(argv) != 3 {
		return 0, .Syntax
	}
	n, good := parse_long(argv[2])
	if !good {
		return 0, .Must_Be_Positive
	}
	if n < 0 {
		return 0, .Must_Be_Positive
	}
	return n, .None
}

parse_zmpop :: proc "contextless" (argv: [][]u8, numkeys_idx: int) -> (a: Zmpop_Args, err: Error) {
	a.count = 1
	n, good := parse_long(argv[numkeys_idx])
	if !good {
		return a, .Numkeys
	}
	if n < 1 {
		return a, .Numkeys
	}
	if n > i64(len(argv) - numkeys_idx - 2) {
		return a, .Syntax
	}
	a.numkeys = int(n)
	i := numkeys_idx + a.numkeys + 1
	if keyword(argv[i], "min") {
		a.max_end = false
	} else if keyword(argv[i], "max") {
		a.max_end = true
	} else {
		return a, .Syntax
	}
	i += 1
	if i < len(argv) {
		if !keyword(argv[i], "count") || i + 2 != len(argv) {
			return a, .Syntax
		}
		count, ok := parse_long(argv[i + 1])
		if !ok {
			return a, .Count_Positive
		}
		if count < 1 {
			return a, .Count_Positive
		}
		a.count = count
	}
	return
}

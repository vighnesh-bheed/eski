package streamtype

WRONGTYPE_ERROR :: "WRONGTYPE Operation against a key holding the wrong kind of value"

Error :: enum u8 {
	None,
	Invalid_ID,
	Not_Integer,
	Syntax,
	Maxlen_Minid,
	Maxlen_Negative,
	Limit_Negative,
	Limit_No_Strategy,
	Xtrim_No_Strategy,
	Limit_No_Approx,
	Xadd_Arity,
	Id_Zero,
	Id_Exhausted,
	Id_Too_Small,
	Too_Large,
	Invalid_Start,
	Invalid_End,
	Unbalanced_Xread,
	Unbalanced_Xreadgroup,
	Group_Option,
	Noack_Option,
	Gt_Id,
	Timeout_Not_Int,
	Timeout_Negative,
	Timeout_Range,
	Entries_Added_Negative,
	Setid_Max_Deleted,
	Setid_Current_Max_Deleted,
	Setid_Top,
	Setid_Entries_Added,
	No_Such_Key,
	Subcommand_Syntax,
	Missing_Group,
	Dollar_Group,
	Plus_Group,
	Entries_Read_Value,
	Xgroup_No_Key,
	Busygroup,
	Claim_Min_Idle,
	Claim_Idle,
	Claim_Time,
	Claim_Retry,
	Claim_Option,
	Autoclaim_Min_Idle,
	Count_Positive,
}

ERROR_MESSAGES := [Error]string {
	.None                      = "",
	.Invalid_ID                = "Invalid stream ID specified as stream command argument",
	.Not_Integer               = "value is not an integer or out of range",
	.Syntax                    = "syntax error",
	.Maxlen_Minid              = "syntax error, MAXLEN and MINID options at the same time are not compatible",
	.Maxlen_Negative           = "The MAXLEN argument must be >= 0.",
	.Limit_Negative            = "The LIMIT argument must be >= 0.",
	.Limit_No_Strategy         = "syntax error, LIMIT cannot be used without specifying a trimming strategy",
	.Xtrim_No_Strategy         = "syntax error, XTRIM must be called with a trimming strategy",
	.Limit_No_Approx           = "syntax error, LIMIT cannot be used without the special ~ option",
	.Xadd_Arity                = "wrong number of arguments for 'xadd' command",
	.Id_Zero                   = "The ID specified in XADD must be greater than 0-0",
	.Id_Exhausted              = "The stream has exhausted the last possible ID, unable to add more items",
	.Id_Too_Small              = "The ID specified in XADD is equal or smaller than the target stream top item",
	.Too_Large                 = "Elements are too large to be stored",
	.Invalid_Start             = "invalid start ID for the interval",
	.Invalid_End               = "invalid end ID for the interval",
	.Unbalanced_Xread          = "Unbalanced 'xread' list of streams: for each stream key an ID or '$' must be specified.",
	.Unbalanced_Xreadgroup     = "Unbalanced 'xreadgroup' list of streams: for each stream key an ID or '>' must be specified.",
	.Group_Option              = "The GROUP option is only supported by XREADGROUP. You called XREAD instead.",
	.Noack_Option              = "The NOACK option is only supported by XREADGROUP. You called XREAD instead.",
	.Gt_Id                     = "The > ID can be specified only when calling XREADGROUP using the GROUP <group> <consumer> option.",
	.Timeout_Not_Int           = "timeout is not an integer or out of range",
	.Timeout_Negative          = "timeout is negative",
	.Timeout_Range             = "timeout is out of range",
	.Entries_Added_Negative    = "entries_added must be positive",
	.Setid_Max_Deleted         = "The ID specified in XSETID is smaller than the provided max_deleted_entry_id",
	.Setid_Current_Max_Deleted = "The ID specified in XSETID is smaller than current max_deleted_entry_id",
	.Setid_Top                 = "The ID specified in XSETID is smaller than the target stream top item",
	.Setid_Entries_Added       = "The entries_added specified in XSETID is smaller than the target stream length",
	.No_Such_Key               = "no such key",
	.Subcommand_Syntax         = "",
	.Missing_Group             = "Missing GROUP option for XREADGROUP",
	.Dollar_Group              = "The $ ID is meaningless in the context of XREADGROUP: you want to read the history of this consumer by specifying a proper ID, or use the > ID to get new messages. The $ ID would just return an empty result set.",
	.Plus_Group                = "The + ID is meaningless in the context of XREADGROUP: you want to read the history of this consumer by specifying a proper ID, or use the > ID to get new messages. The + ID would just return an empty result set.",
	.Entries_Read_Value        = "value for ENTRIESREAD must be positive or -1",
	.Xgroup_No_Key             = "The XGROUP subcommand requires the key to exist. Note that for CREATE you may want to use the MKSTREAM option to create an empty stream automatically.",
	.Busygroup                 = "BUSYGROUP Consumer Group name already exists",
	.Claim_Min_Idle            = "Invalid min-idle-time argument for XCLAIM",
	.Claim_Idle                = "Invalid IDLE option argument for XCLAIM",
	.Claim_Time                = "Invalid TIME option argument for XCLAIM",
	.Claim_Retry               = "Invalid RETRYCOUNT option argument for XCLAIM",
	.Claim_Option              = "",
	.Autoclaim_Min_Idle        = "Invalid min-idle-time argument for XAUTOCLAIM",
	.Count_Positive            = "COUNT must be > 0",
}

@(private)
ID_ARG_MAX :: 127

error_has_prefix :: proc "contextless" (e: Error) -> bool {
	return e == .Busygroup
}

error_message :: proc "contextless" (e: Error) -> string {
	return ERROR_MESSAGES[e]
}

@(private)
lower_byte :: #force_inline proc "contextless" (b: u8) -> u8 {
	if b >= 'A' && b <= 'Z' {
		return b + 32
	}
	return b
}

eq_nocase :: proc "contextless" (a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if lower_byte(a[i]) != lower_byte(b[i]) {
			return false
		}
	}
	return true
}

cstr :: #force_inline proc "contextless" (a: []u8) -> []u8 {
	for c, i in a {
		if c == 0 {
			return a[:i]
		}
	}
	return a
}

opt_is :: #force_inline proc "contextless" (a: []u8, name: string) -> bool {
	return eq_nocase(cstr(a), name)
}

is_byte :: #force_inline proc "contextless" (a: []u8, b: u8) -> bool {
	if len(a) == 0 || a[0] != b {
		return false
	}
	return len(a) == 1 || a[1] == 0
}

parse_ll :: #force_inline proc "contextless" (s: []u8) -> (v: i64, ok: bool) {
	return parse_int_text(s)
}

@(private)
is_space :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\v' || b == '\f' || b == '\r'
}

string2ull :: proc "contextless" (s: []u8) -> (v: u64, ok: bool) {
	if strict, good := parse_int_text(s); good {
		if strict < 0 {
			return 0, false
		}
		return u64(strict), true
	}
	i := 0
	for i < len(s) && is_space(s[i]) {
		i += 1
	}
	neg := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		neg = s[i] == '-'
		i += 1
	}
	digits := i
	acc: u64
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		d := u64(s[i] - '0')
		if acc > (max(u64) - d) / 10 {
			return 0, false
		}
		acc = acc * 10 + d
		i += 1
	}
	if i == digits || i != len(s) {
		return 0, false
	}
	if neg {
		acc = 0 - acc
	}
	return acc, true
}

parse_id :: proc "contextless" (arg: []u8, missing_seq: u64, strict: bool, allow_partial: bool) -> (id: ID, seq_given: bool, ok: bool) {
	if len(arg) > ID_ARG_MAX {
		return
	}
	s := cstr(arg)
	if !strict && len(s) == 1 {
		if s[0] == '-' {
			return ID_MIN, true, true
		}
		if s[0] == '+' {
			return ID_MAX, true, true
		}
	}
	dash := -1
	for c, i in s {
		if c == '-' {
			dash = i
			break
		}
	}
	if dash < 0 {
		ms, good := string2ull(s)
		if !good {
			return
		}
		return ID{ms, missing_seq}, true, true
	}
	ms, good := string2ull(s[:dash])
	if !good {
		return
	}
	rest := s[dash + 1:]
	if allow_partial && len(rest) == 1 && rest[0] == '*' {
		return ID{ms, 0}, false, true
	}
	seq, sgood := string2ull(rest)
	if !sgood {
		return
	}
	return ID{ms, seq}, true, true
}

parse_strict_id :: #force_inline proc "contextless" (arg: []u8) -> (id: ID, ok: bool) {
	id, _, ok = parse_id(arg, 0, true, false)
	return
}

parse_interval_id :: proc "contextless" (arg: []u8, missing_seq: u64) -> (id: ID, exclude: bool, ok: bool) {
	if len(arg) > 0 && arg[0] == '(' {
		if len(arg) > ID_ARG_MAX {
			return
		}
		id, _, ok = parse_id(arg[1:], missing_seq, true, false)
		exclude = true
		return
	}
	id, _, ok = parse_id(arg, missing_seq, false, false)
	return
}

trim_limit_relaxed: bool

@(private)
default_trim_limit :: proc "contextless" () -> i64 {
	n := stream_node_max_entries
	if n <= 0 {
		return 0
	}
	if n > max(i64) / 100 {
		return max(i64)
	}
	return n * 100
}

parse_add_trim_args :: proc "contextless" (argv: [][]u8, xadd: bool) -> (args: Add_Trim_Args, idpos: int, err: Error) {
	n := len(argv)
	i := 2
	limit_given := false
	for i < n {
		opt := argv[i]
		more := n - 1 - i
		if xadd && is_byte(opt, '*') {
			break
		}
		if (opt_is(opt, "maxlen") || opt_is(opt, "minid")) && more >= 1 {
			is_maxlen := opt_is(opt, "maxlen")
			approx := false
			nx := argv[i + 1]
			if more >= 2 && is_byte(nx, '~') {
				approx = true
				i += 1
			} else if more >= 2 && is_byte(nx, '=') {
				i += 1
			}
			if is_maxlen {
				v, ok := parse_ll(argv[i + 1])
				if !ok {
					err = .Not_Integer
					return
				}
				if v < 0 {
					err = .Maxlen_Negative
					return
				}
				if args.trim_strategy == .Minid {
					err = .Maxlen_Minid
					return
				}
				args.trim_strategy = .Maxlen
				args.maxlen = v
			} else {
				m, ok := parse_strict_id(argv[i + 1])
				if !ok {
					err = .Invalid_ID
					return
				}
				if args.trim_strategy == .Maxlen {
					err = .Maxlen_Minid
					return
				}
				args.trim_strategy = .Minid
				args.minid = m
			}
			args.approx_trim = approx
			args.trim_strategy_arg_idx = i + 1
			i += 2
			continue
		}
		if opt_is(opt, "limit") && more >= 1 {
			v, ok := parse_ll(argv[i + 1])
			if !ok {
				err = .Not_Integer
				return
			}
			if v < 0 {
				err = .Limit_Negative
				return
			}
			args.limit = v
			limit_given = true
			i += 2
			continue
		}
		if xadd && opt_is(opt, "nomkstream") {
			args.no_mkstream = true
			i += 1
			continue
		}
		if xadd {
			break
		}
		err = .Syntax
		return
	}
	if args.limit > 0 && args.trim_strategy == .None {
		err = .Limit_No_Strategy
		return
	}
	if !xadd && args.trim_strategy == .None {
		err = .Xtrim_No_Strategy
		return
	}
	if args.limit > 0 && !args.approx_trim && !trim_limit_relaxed {
		err = .Limit_No_Approx
		return
	}
	if args.approx_trim {
		if !limit_given {
			args.limit = default_trim_limit()
		}
	} else {
		args.limit = 0
	}
	if !xadd {
		return
	}
	idpos = i
	if i >= n {
		err = .Xadd_Arity
		return
	}
	if is_byte(argv[i], '*') {
		args.id_given = false
		args.seq_given = true
	} else {
		id, seq_given, ok := parse_id(argv[i], 0, true, true)
		if !ok {
			err = .Invalid_ID
			return
		}
		args.id = id
		args.id_given = true
		args.seq_given = seq_given
	}
	rest := n - i - 1
	if rest <= 0 || rest % 2 != 0 {
		err = .Xadd_Arity
		return
	}
	if args.id_given && args.seq_given && id_is_zero(args.id) {
		err = .Id_Zero
		return
	}
	return
}

parse_range_args :: proc "contextless" (argv: [][]u8, rev: bool) -> (start: ID, end: ID, count: i64, err: Error) {
	count = -1
	if len(argv) < 4 {
		err = .Syntax
		return
	}
	sarg := rev ? argv[3] : argv[2]
	earg := rev ? argv[2] : argv[3]
	sx, ex, ok: bool
	start, sx, ok = parse_interval_id(sarg, 0)
	if !ok {
		err = .Invalid_ID
		return
	}
	if sx && !incr_id(&start) {
		err = .Invalid_Start
		return
	}
	end, ex, ok = parse_interval_id(earg, max(u64))
	if !ok {
		err = .Invalid_ID
		return
	}
	if ex && !decr_id(&end) {
		err = .Invalid_End
		return
	}
	for i := 4; i < len(argv); i += 2 {
		if opt_is(argv[i], "count") && i + 1 < len(argv) {
			v, good := parse_ll(argv[i + 1])
			if !good {
				err = .Not_Integer
				return
			}
			count = v < 0 ? 0 : v
		} else {
			err = .Syntax
			return
		}
	}
	return
}

parse_timeout_ms :: proc "contextless" (arg: []u8, now_ms: i64) -> (timeout: i64, err: Error) {
	v, ok := parse_ll(arg)
	if !ok {
		err = .Timeout_Not_Int
		return
	}
	if v < 0 {
		err = .Timeout_Negative
		return
	}
	if v == 0 {
		return 0, .None
	}
	if v > max(i64) - now_ms {
		err = .Timeout_Range
		return
	}
	return now_ms + v, .None
}

Xread_Args :: struct {
	timeout:       i64,
	count:         i64,
	streams_arg:   int,
	streams_count: int,
	group_arg:     int,
	noack:         bool,
}

parse_xread_args :: proc "contextless" (argv: [][]u8, now_ms: i64, xreadgroup: bool) -> (a: Xread_Args, err: Error) {
	a.timeout = -1
	n := len(argv)
	i := 1
	for i < n {
		opt := argv[i]
		more := n - 1 - i
		if opt_is(opt, "block") && more >= 1 {
			t, e := parse_timeout_ms(argv[i + 1], now_ms)
			if e != .None {
				err = e
				return
			}
			a.timeout = t
			i += 2
		} else if opt_is(opt, "count") && more >= 1 {
			v, ok := parse_ll(argv[i + 1])
			if !ok {
				err = .Not_Integer
				return
			}
			a.count = v < 0 ? 0 : v
			i += 2
		} else if opt_is(opt, "streams") && more >= 1 {
			a.streams_arg = i + 1
			rem := n - a.streams_arg
			if rem % 2 != 0 {
				err = xreadgroup ? .Unbalanced_Xreadgroup : .Unbalanced_Xread
				return
			}
			a.streams_count = rem / 2
			break
		} else if opt_is(opt, "group") && more >= 2 {
			if !xreadgroup {
				err = .Group_Option
				return
			}
			a.group_arg = i + 1
			i += 3
		} else if opt_is(opt, "noack") {
			if !xreadgroup {
				err = .Noack_Option
				return
			}
			a.noack = true
			i += 1
		} else {
			err = .Syntax
			return
		}
	}
	if a.streams_arg == 0 {
		err = .Syntax
		return
	}
	if xreadgroup && a.group_arg == 0 {
		err = .Missing_Group
		return
	}
	return
}

Setid_Args :: struct {
	id:            ID,
	entries_added: i64,
	max_xdel_id:   ID,
}

parse_xsetid_args :: proc "contextless" (argv: [][]u8) -> (a: Setid_Args, err: Error) {
	a.entries_added = -1
	if len(argv) < 3 {
		err = .Syntax
		return
	}
	id, ok := parse_strict_id(argv[2])
	if !ok {
		err = .Invalid_ID
		return
	}
	a.id = id
	n := len(argv)
	for i := 3; i < n; i += 2 {
		if opt_is(argv[i], "entriesadded") && i + 1 < n {
			v, good := parse_ll(argv[i + 1])
			if !good {
				err = .Not_Integer
				return
			}
			if v < 0 {
				err = .Entries_Added_Negative
				return
			}
			a.entries_added = v
		} else if opt_is(argv[i], "maxdeletedid") && i + 1 < n {
			m, good := parse_strict_id(argv[i + 1])
			if !good {
				err = .Invalid_ID
				return
			}
			if compare_id(a.id, m) < 0 {
				err = .Setid_Max_Deleted
				return
			}
			a.max_xdel_id = m
		} else {
			err = .Syntax
			return
		}
	}
	return
}

xsetid_apply :: proc(s: Stream, a: ^Setid_Args) -> Error {
	if compare_id(a.id, s.max_deleted_entry_id) < 0 {
		return .Setid_Current_Max_Deleted
	}
	if s.length > 0 && compare_id(a.id, last_valid_id(s)) < 0 {
		return .Setid_Top
	}
	if a.entries_added != -1 && u64(a.entries_added) < s.length {
		return .Setid_Entries_Added
	}
	s.last_id = a.id
	if a.entries_added != -1 {
		s.entries_added = u64(a.entries_added)
	}
	if !id_is_zero(a.max_xdel_id) {
		s.max_deleted_entry_id = a.max_xdel_id
	}
	return .None
}

parse_xinfo_stream_opts :: proc "contextless" (opts: [][]u8) -> (full: bool, count: i64, err: Error) {
	if len(opts) == 0 {
		return
	}
	if !opt_is(opts[0], "full") {
		err = .Subcommand_Syntax
		return
	}
	full = true
	count = 10
	if len(opts) == 1 {
		return
	}
	if len(opts) == 3 && opt_is(opts[1], "count") {
		v, ok := parse_ll(opts[2])
		if !ok {
			err = .Not_Integer
			return
		}
		count = v < 0 ? 0 : v
		return
	}
	err = .Subcommand_Syntax
	return
}

xdel_apply :: proc(s: Stream, ids: []ID) -> int {
	deleted := 0
	for id in ids {
		if delete_item(s, id) {
			deleted += 1
			if compare_id(id, s.max_deleted_entry_id) > 0 {
				s.max_deleted_entry_id = id
			}
		}
	}
	return deleted
}

xadd_apply :: proc(s: Stream, args: ^Add_Trim_Args, fv: [][]u8, now_ms: u64) -> (id: ID, err: Error) {
	if compare_id(s.last_id, ID_MAX) == 0 {
		err = .Id_Exhausted
		return
	}
	use_id: ^ID
	if args.id_given {
		use_id = &args.id
	}
	added, res := append_item(s, fv, use_id, args.seq_given, now_ms)
	switch res {
	case .Ok:
		return added, .None
	case .Edom:
		err = .Id_Too_Small
	case .Erange:
		err = .Too_Large
	}
	return
}

parse_xgroup_opts :: proc "contextless" (argv: [][]u8) -> (mkstream: bool, entries_read: i64, err: Error) {
	entries_read = SCG_INVALID_ENTRIES_READ
	if len(argv) < 2 {
		return
	}
	create := eq_nocase(argv[1], "create")
	setid := eq_nocase(argv[1], "setid")
	if !create && !setid {
		return
	}
	n := len(argv)
	i := 5
	for i < n {
		if create && opt_is(argv[i], "mkstream") {
			mkstream = true
			i += 1
		} else if opt_is(argv[i], "entriesread") && i + 1 < n {
			v, ok := parse_ll(argv[i + 1])
			if !ok {
				err = .Not_Integer
				return
			}
			if v < 0 && v != SCG_INVALID_ENTRIES_READ {
				err = .Entries_Read_Value
				return
			}
			entries_read = v
			i += 2
		} else {
			err = .Subcommand_Syntax
			return
		}
	}
	return
}

Xpending_Args :: struct {
	justinfo:     bool,
	minidle:      i64,
	start:        ID,
	end:          ID,
	count:        i64,
	consumer_idx: int,
}

parse_xpending_args :: proc "contextless" (argv: [][]u8) -> (a: Xpending_Args, err: Error) {
	n := len(argv)
	if n == 3 {
		a.justinfo = true
		return
	}
	if n < 6 || n > 9 {
		err = .Syntax
		return
	}
	at := 3
	if opt_is(argv[3], "idle") {
		if n < 8 {
			err = .Syntax
			return
		}
		v, ok := parse_ll(argv[4])
		if !ok {
			err = .Not_Integer
			return
		}
		a.minidle = v < 0 ? 0 : v
		at = 5
	}
	sx, ex, ok: bool
	a.start, sx, ok = parse_interval_id(argv[at], 0)
	if !ok {
		err = .Invalid_ID
		return
	}
	if sx && !incr_id(&a.start) {
		err = .Invalid_Start
		return
	}
	a.end, ex, ok = parse_interval_id(argv[at + 1], max(u64))
	if !ok {
		err = .Invalid_ID
		return
	}
	if ex && !decr_id(&a.end) {
		err = .Invalid_End
		return
	}
	v, good := parse_ll(argv[at + 2])
	if !good {
		err = .Not_Integer
		return
	}
	a.count = v < 0 ? 0 : v
	if n > at + 3 {
		a.consumer_idx = at + 3
	}
	return
}

parse_xclaim_args :: proc(argv: [][]u8, now: i64, ids: ^[dynamic]ID) -> (a: Claim_Args, bad: int, err: Error) {
	a.retrycount = -1
	a.deliverytime = -1
	n := len(argv)
	if n < 6 {
		err = .Syntax
		return
	}
	minidle, ok := parse_ll(argv[4])
	if !ok {
		err = .Claim_Min_Idle
		return
	}
	a.minidle = minidle < 0 ? 0 : minidle
	j := 5
	for j < n {
		id, good := parse_strict_id(argv[j])
		if !good {
			break
		}
		append(ids, id)
		j += 1
	}
	for ; j < n; j += 1 {
		more := n - 1 - j
		opt := argv[j]
		if opt_is(opt, "force") {
			a.force = true
		} else if opt_is(opt, "justid") {
			a.justid = true
		} else if opt_is(opt, "idle") && more >= 1 {
			v, good := parse_ll(argv[j + 1])
			if !good {
				err = .Claim_Idle
				return
			}
			a.deliverytime = now - v
			j += 1
		} else if opt_is(opt, "time") && more >= 1 {
			v, good := parse_ll(argv[j + 1])
			if !good {
				err = .Claim_Time
				return
			}
			a.deliverytime = v
			j += 1
		} else if opt_is(opt, "retrycount") && more >= 1 {
			v, good := parse_ll(argv[j + 1])
			if !good {
				err = .Claim_Retry
				return
			}
			a.retrycount = v
			j += 1
		} else if opt_is(opt, "lastid") && more >= 1 {
			id, good := parse_strict_id(argv[j + 1])
			if !good {
				err = .Invalid_ID
				return
			}
			a.last_id = id
			j += 1
		} else {
			bad = j
			err = .Claim_Option
			return
		}
	}
	return
}

Autoclaim_Args :: struct {
	minidle: i64,
	start:   ID,
	count:   i64,
	justid:  bool,
}

parse_xautoclaim_args :: proc "contextless" (argv: [][]u8) -> (a: Autoclaim_Args, err: Error) {
	a.count = 100
	n := len(argv)
	if n < 6 {
		err = .Syntax
		return
	}
	minidle, ok := parse_ll(argv[4])
	if !ok {
		err = .Autoclaim_Min_Idle
		return
	}
	a.minidle = minidle < 0 ? 0 : minidle
	sx: bool
	a.start, sx, ok = parse_interval_id(argv[5], 0)
	if !ok {
		err = .Invalid_ID
		return
	}
	if sx && !incr_id(&a.start) {
		err = .Invalid_Start
		return
	}
	for j := 6; j < n; j += 1 {
		more := n - 1 - j
		if opt_is(argv[j], "count") && more >= 1 {
			v, good := parse_ll(argv[j + 1])
			if !good || v < 1 || v > AUTOCLAIM_MAX_COUNT {
				err = .Count_Positive
				return
			}
			a.count = v
			j += 1
		} else if opt_is(argv[j], "justid") {
			a.justid = true
		} else {
			err = .Syntax
			return
		}
	}
	return
}

package streamtype

import decimal "../decimal"
import integer "../integer"

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
ID_ARG_BYTES_MAX :: 127

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
	return integer.parse_i64(s)
}

Id_Shape :: enum u8 {
	Bad,
	Lowest,
	Highest,
	Ms,
	Ms_Seq,
	Ms_Star,
}

Id_Text :: struct {
	shape: Id_Shape,
	ms:    u64,
	seq:   u64,
}

Xadd_Id_Mode :: enum u8 {
	Generated,
	Explicit,
	Generated_Seq,
}

read_id_text :: proc "contextless" (arg: []u8) -> (t: Id_Text) {
	if len(arg) > ID_ARG_BYTES_MAX {
		return
	}
	text := cstr(arg)
	if len(text) == 1 && (text[0] == '-' || text[0] == '+') {
		t.shape = .Lowest if text[0] == '-' else .Highest
		return
	}
	head, tail := text, []u8{}
	split := false
	for c, at in text {
		if c == '-' {
			head, tail = text[:at], text[at + 1:]
			split = true
			break
		}
	}
	ms, good := decimal.parse_u64_loose(head)
	if !good {
		return
	}
	t.ms = ms
	if !split {
		t.shape = .Ms
		return
	}
	if len(tail) == 1 && tail[0] == '*' {
		t.shape = .Ms_Star
		return
	}
	seq, fine := decimal.parse_u64_loose(tail)
	if fine {
		t.seq = seq
		t.shape = .Ms_Seq
	}
	return
}

parse_exact_id :: proc "contextless" (arg: []u8) -> (ID, bool) {
	t := read_id_text(arg)
	#partial switch t.shape {
	case .Ms, .Ms_Seq:
		return ID{t.ms, t.seq}, true
	}
	return {}, false
}

parse_id_or_sentinel :: proc "contextless" (arg: []u8, missing_seq: u64) -> (ID, bool) {
	t := read_id_text(arg)
	#partial switch t.shape {
	case .Lowest:
		return ID_MIN, true
	case .Highest:
		return ID_MAX, true
	case .Ms:
		return ID{t.ms, missing_seq}, true
	case .Ms_Seq:
		return ID{t.ms, t.seq}, true
	}
	return {}, false
}

parse_range_bound :: proc "contextless" (arg: []u8, missing_seq: u64) -> (id: ID, exclusive: bool, ok: bool) {
	if len(arg) == 0 || arg[0] != '(' {
		id, ok = parse_id_or_sentinel(arg, missing_seq)
		return
	}
	exclusive = true
	if len(arg) > ID_ARG_BYTES_MAX {
		return
	}
	t := read_id_text(arg[1:])
	#partial switch t.shape {
	case .Ms:
		id, ok = ID{t.ms, missing_seq}, true
	case .Ms_Seq:
		id, ok = ID{t.ms, t.seq}, true
	}
	return
}

parse_xadd_id :: proc "contextless" (arg: []u8) -> (id: ID, mode: Xadd_Id_Mode, ok: bool) {
	if is_byte(arg, '*') {
		return {}, .Generated, true
	}
	t := read_id_text(arg)
	#partial switch t.shape {
	case .Ms, .Ms_Seq:
		return ID{t.ms, t.seq}, .Explicit, true
	case .Ms_Star:
		return ID{t.ms, 0}, .Generated_Seq, true
	}
	return {}, .Explicit, false
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

@(private)
Trim_Word :: enum u8 {
	Unknown,
	Max_Len,
	Min_Id,
	Limit,
	Nomkstream,
	Auto_Id,
}

@(private)
trim_word :: proc "contextless" (arg: []u8, xadd: bool, has_value: bool) -> Trim_Word {
	switch {
	case xadd && is_byte(arg, '*'):
		return .Auto_Id
	case has_value && opt_is(arg, "maxlen"):
		return .Max_Len
	case has_value && opt_is(arg, "minid"):
		return .Min_Id
	case has_value && opt_is(arg, "limit"):
		return .Limit
	case xadd && opt_is(arg, "nomkstream"):
		return .Nomkstream
	}
	return .Unknown
}

@(private)
Trim_Reader :: struct {
	spec:       Trim_Spec,
	limit_seen: bool,
	nomkstream: bool,
	stop:       int,
}

@(private)
read_threshold :: proc "contextless" (r: ^Trim_Reader, argv: [][]u8, at: int, word: Trim_Word) -> (next: int, err: Error) {
	value := at + 1
	r.spec.nearly = false
	if value + 1 < len(argv) {
		if is_byte(argv[value], '~') {
			r.spec.nearly = true
			value += 1
		} else if is_byte(argv[value], '=') {
			value += 1
		}
	}
	other := Trim_Rule.Min_Id if word == .Max_Len else Trim_Rule.Max_Len
	if word == .Max_Len {
		keep, good := parse_ll(argv[value])
		switch {
		case !good:
			return value, .Not_Integer
		case keep < 0:
			return value, .Maxlen_Negative
		case r.spec.rule == other:
			return value, .Maxlen_Minid
		}
		r.spec.rule = .Max_Len
		r.spec.max_len = keep
	} else {
		floor, good := parse_exact_id(argv[value])
		switch {
		case !good:
			return value, .Invalid_ID
		case r.spec.rule == other:
			return value, .Maxlen_Minid
		}
		r.spec.rule = .Min_Id
		r.spec.min_id = floor
	}
	return value + 1, .None
}

@(private)
read_trim_words :: proc "contextless" (argv: [][]u8, xadd: bool) -> (r: Trim_Reader, err: Error) {
	at := 2
	scan: for at < len(argv) {
		word := trim_word(argv[at], xadd, at + 1 < len(argv))
		switch word {
		case .Max_Len, .Min_Id:
			at = read_threshold(&r, argv, at, word) or_return
		case .Limit:
			bound, good := parse_ll(argv[at + 1])
			if !good {
				return r, .Not_Integer
			}
			if bound < 0 {
				return r, .Limit_Negative
			}
			r.spec.limit = bound
			r.limit_seen = true
			at += 2
		case .Nomkstream:
			r.nomkstream = true
			at += 1
		case .Auto_Id:
			break scan
		case .Unknown:
			if !xadd {
				return r, .Syntax
			}
			break scan
		}
	}
	r.stop = at
	if r.spec.rule == .Off {
		if r.spec.limit > 0 {
			return r, .Limit_No_Strategy
		}
		if !xadd {
			return r, .Xtrim_No_Strategy
		}
	}
	if r.spec.limit > 0 && !r.spec.nearly && !trim_limit_relaxed {
		return r, .Limit_No_Approx
	}
	switch {
	case !r.spec.nearly:
		r.spec.limit = 0
	case !r.limit_seen:
		r.spec.limit = default_trim_limit()
	}
	return r, .None
}

parse_xtrim :: proc "contextless" (argv: [][]u8) -> (spec: Trim_Spec, err: Error) {
	r := read_trim_words(argv, false) or_return
	return r.spec, .None
}

parse_xadd :: proc "contextless" (argv: [][]u8) -> (spec: Xadd_Spec, err: Error) {
	r := read_trim_words(argv, true) or_return
	spec.trim = r.spec
	spec.nomkstream = r.nomkstream
	if r.stop >= len(argv) {
		return spec, .Xadd_Arity
	}
	good: bool
	spec.id, spec.id_mode, good = parse_xadd_id(argv[r.stop])
	if !good {
		return spec, .Invalid_ID
	}
	spec.fields_at = r.stop + 1
	pairs := len(argv) - spec.fields_at
	if pairs == 0 || pairs % 2 == 1 {
		return spec, .Xadd_Arity
	}
	if spec.id_mode == .Explicit && id_is_zero(spec.id) {
		return spec, .Id_Zero
	}
	return spec, .None
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
	start, sx, ok = parse_range_bound(sarg, 0)
	if !ok {
		err = .Invalid_ID
		return
	}
	if sx && !incr_id(&start) {
		err = .Invalid_Start
		return
	}
	end, ex, ok = parse_range_bound(earg, max(u64))
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
	keys_at:       int,
	key_count:     int,
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
			a.keys_at = i + 1
			rem := n - a.keys_at
			if rem % 2 != 0 {
				err = xreadgroup ? .Unbalanced_Xreadgroup : .Unbalanced_Xread
				return
			}
			a.key_count = rem / 2
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
	if a.keys_at == 0 {
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
	id:             ID,
	entries_added:  i64,
	max_deleted_id: ID,
}

parse_xsetid_args :: proc "contextless" (argv: [][]u8) -> (a: Setid_Args, err: Error) {
	a.entries_added = -1
	if len(argv) < 3 {
		err = .Syntax
		return
	}
	id, ok := parse_exact_id(argv[2])
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
			m, good := parse_exact_id(argv[i + 1])
			if !good {
				err = .Invalid_ID
				return
			}
			if compare_id(a.id, m) < 0 {
				err = .Setid_Max_Deleted
				return
			}
			a.max_deleted_id = m
		} else {
			err = .Syntax
			return
		}
	}
	return
}

xsetid_apply :: proc(s: Stream, a: ^Setid_Args) -> Error {
	if compare_id(a.id, s.tomb) < 0 {
		return .Setid_Current_Max_Deleted
	}
	if s.live > 0 && compare_id(a.id, last_valid_id(s)) < 0 {
		return .Setid_Top
	}
	if a.entries_added != -1 && u64(a.entries_added) < s.live {
		return .Setid_Entries_Added
	}
	s.top = a.id
	if a.entries_added != -1 {
		s.added = u64(a.entries_added)
	}
	if !id_is_zero(a.max_deleted_id) {
		s.tomb = a.max_deleted_id
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
			if compare_id(id, s.tomb) > 0 {
				s.tomb = id
			}
		}
	}
	return deleted
}

xadd_apply :: proc(s: Stream, spec: ^Xadd_Spec, fv: [][]u8, now_ms: u64) -> (id: ID, err: Error) {
	if compare_id(s.top, ID_MAX) == 0 {
		err = .Id_Exhausted
		return
	}
	added, outcome := append_entry(s, fv, spec.id_mode, spec.id, now_ms)
	switch outcome {
	case .Ok:
		return added, .None
	case .Id_Not_Greater:
		err = .Id_Too_Small
	case .Entry_Too_Large:
		err = .Too_Large
	}
	return
}

parse_xgroup_opts :: proc "contextless" (argv: [][]u8) -> (mkstream: bool, entries_read: i64, err: Error) {
	entries_read = ENTRIES_READ_UNKNOWN
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
			if v < 0 && v != ENTRIES_READ_UNKNOWN {
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
	a.start, sx, ok = parse_range_bound(argv[at], 0)
	if !ok {
		err = .Invalid_ID
		return
	}
	if sx && !incr_id(&a.start) {
		err = .Invalid_Start
		return
	}
	a.end, ex, ok = parse_range_bound(argv[at + 1], max(u64))
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

parse_xclaim_args :: proc(argv: [][]u8, now: i64, ids: ^[dynamic]ID) -> (a: Claim_Options, bad: int, err: Error) {
	a.tries = CLAIM_UNSET
	a.stamp = CLAIM_UNSET
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
	a.idle_floor = minidle < 0 ? 0 : minidle
	j := 5
	for j < n {
		id, good := parse_exact_id(argv[j])
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
			a.flags += {.Force}
		} else if opt_is(opt, "justid") {
			a.flags += {.Ids_Only}
		} else if opt_is(opt, "idle") && more >= 1 {
			v, good := parse_ll(argv[j + 1])
			if !good {
				err = .Claim_Idle
				return
			}
			a.stamp = now - v
			j += 1
		} else if opt_is(opt, "time") && more >= 1 {
			v, good := parse_ll(argv[j + 1])
			if !good {
				err = .Claim_Time
				return
			}
			a.stamp = v
			j += 1
		} else if opt_is(opt, "retrycount") && more >= 1 {
			v, good := parse_ll(argv[j + 1])
			if !good {
				err = .Claim_Retry
				return
			}
			a.tries = v
			j += 1
		} else if opt_is(opt, "lastid") && more >= 1 {
			id, good := parse_exact_id(argv[j + 1])
			if !good {
				err = .Invalid_ID
				return
			}
			a.raise_to = id
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
	a.start, sx, ok = parse_range_bound(argv[5], 0)
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

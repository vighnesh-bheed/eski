package main

import ld "ldfloat"

@(private = "file")
ERR_NOT_FLOAT :: "ERR value is not a valid float"

@(private = "file")
ERR_STRING_TOO_BIG :: "ERR string exceeds maximum allowed size (proto-max-bulk-len)"

@(private = "file")
ERR_OFFSET_RANGE :: "ERR offset is out of range"

@(private = "file")
ERR_FLOAT_RESULT :: "ERR increment would produce NaN or Infinity"

@(private = "file")
ERR_DECREMENT_OVERFLOW :: "ERR decrement would overflow"

@(private = "file")
ERR_LCS_LEN_AND_IDX :: "ERR If you want both the length and indexes, please just use IDX."

@(private = "file")
ERR_LCS_NOT_STRING :: "ERR The specified keys must contain string values"

@(private = "file")
ERR_LCS_MEMORY :: "ERR Insufficient memory, transient memory for LCS exceeds proto-max-bulk-len"

@(private = "file")
STABLE_VALUE_MIN :: 17

@(private = "file")
Write_Rule :: enum u8 {
	Nx,
	Xx,
	Get,
	Keepttl,
	Persist,
	Ifeq,
}

@(private = "file")
Write_Rules :: bit_set[Write_Rule;u8]

@(private = "file")
Deadline_Form :: enum u8 {
	None,
	Ex,
	Px,
	Exat,
	Pxat,
}

@(private = "file")
Write_Plan :: struct {
	rules:    Write_Rules,
	form:     Deadline_Form,
	deadline: []u8,
	expected: []u8,
}

@(private = "file")
deadline_form_of :: proc "contextless" (tok: []u8) -> Deadline_Form {
	switch len(tok) {
	case 2:
		if eq_nocase(tok, "ex") {
			return .Ex
		}
		if eq_nocase(tok, "px") {
			return .Px
		}
	case 4:
		if eq_nocase(tok, "exat") {
			return .Exat
		}
		if eq_nocase(tok, "pxat") {
			return .Pxat
		}
	}
	return .None
}

@(private = "file")
read_write_plan :: proc "contextless" (argv: [][]u8, from: int, setting: bool) -> (plan: Write_Plan, ok: bool) {
	i := from
	for i < len(argv) {
		tok := argv[i]
		has_next := i + 1 < len(argv)
		switch {
		case setting && eq_nocase(tok, "nx"):
			if plan.rules & {.Xx, .Ifeq} != {} {
				return plan, false
			}
			plan.rules += {.Nx}
		case setting && eq_nocase(tok, "xx"):
			if plan.rules & {.Nx, .Ifeq} != {} {
				return plan, false
			}
			plan.rules += {.Xx}
		case setting && eq_nocase(tok, "get"):
			plan.rules += {.Get}
		case setting && eq_nocase(tok, "keepttl"):
			if plan.form != .None {
				return plan, false
			}
			plan.rules += {.Keepttl}
		case !setting && eq_nocase(tok, "persist"):
			if plan.form != .None {
				return plan, false
			}
			plan.rules += {.Persist}
		case setting && eq_nocase(tok, "ifeq"):
			if plan.rules & {.Nx, .Xx, .Ifeq} != {} || !has_next {
				return plan, false
			}
			plan.rules += {.Ifeq}
			plan.expected = argv[i + 1]
			i += 1
		case:
			form := deadline_form_of(tok)
			if form == .None || !has_next || plan.rules & {.Keepttl, .Persist} != {} {
				return plan, false
			}
			if plan.form != .None && plan.form != form {
				return plan, false
			}
			plan.form = form
			plan.deadline = argv[i + 1]
			i += 1
		}
		i += 1
	}
	return plan, true
}

@(private = "file")
reply_bad_deadline :: proc(c: ^Conn, name: string) {
	reply_error_parts(c, "ERR invalid expire time in '", name, "' command")
}

@(private = "file")
deadline_ms :: proc(c: ^Conn, form: Deadline_Form, text: []u8, name: string) -> (at: i64, ok: bool) {
	amount, parsed := parse_i64(text)
	if !parsed {
		reply_error(c, ERR_NOT_INT)
		return 0, false
	}
	if amount <= 0 {
		reply_bad_deadline(c, name)
		return 0, false
	}
	ms := amount
	if form == .Ex || form == .Exat {
		if amount > max(i64) / 1000 {
			reply_bad_deadline(c, name)
			return 0, false
		}
		ms = amount * 1000
	}
	if form == .Ex || form == .Px {
		now := expire_now()
		if ms > max(i64) - now {
			reply_bad_deadline(c, name)
			return 0, false
		}
		ms += now
	}
	return ms, true
}

@(private = "file")
stored_deadline :: #force_inline proc "contextless" (at: i64) -> i64 {
	return min(at, MAX_EXPIRE_MS)
}

@(private = "file")
string_entry_of :: #force_inline proc(c: ^Conn, e: ^Entry) -> bool {
	if e != nil && entry_type(e) != .String {
		reply_wrongtype(c)
		return false
	}
	return true
}

@(private = "file")
put_plain :: #force_inline proc(key: []u8, val: []u8) {
	e, _ := db_upsert(key)
	entry_assign(e, val)
	entry_set_expire(e, 0)
}

@(private = "file")
announce_set :: #force_inline proc(key: []u8) {
	signal_key(key)
	notify(.String, "set", key)
}

@(private = "file")
nothing_written :: #force_inline proc() {
	pst.dirty_explicit = true
}

cmd_set :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) == 3 {
		put_plain(argv[1], argv[2])
		announce_set(argv[1])
		reply_ok(c)
		return
	}
	set_with_plan(c, argv)
}

set_creates_only :: proc "contextless" (argv: [][]u8) -> bool {
	plan, parsed := read_write_plan(argv, 3, true)
	return parsed && .Nx in plan.rules
}

@(private = "file")
set_with_plan :: proc(c: ^Conn, argv: [][]u8) {
	plan, parsed := read_write_plan(argv, 3, true)
	if !parsed {
		reply_error(c, ERR_SYNTAX)
		return
	}
	at: i64
	if plan.form != .None {
		ok: bool
		at, ok = deadline_ms(c, plan.form, plan.deadline, "set")
		if !ok {
			return
		}
	}
	key := argv[1]
	reading := plan.rules & {.Get, .Ifeq} != {}
	e := db_find_read(key) if .Get in plan.rules else db_find(key)
	if reading && !string_entry_of(c, e) {
		return
	}
	write := true
	if .Nx in plan.rules && e != nil {
		write = false
	}
	if .Xx in plan.rules && e == nil {
		write = false
	}
	if .Ifeq in plan.rules && (e == nil || !bytes_eq(e.val, plan.expected)) {
		write = false
	}
	if .Get in plan.rules {
		if e == nil {
			reply_null(c)
		} else {
			reply_bulk(c, e.val)
		}
	}
	if !write {
		if .Get not_in plan.rules {
			reply_null(c)
		}
		nothing_written()
		return
	}
	if e == nil {
		e, _ = db_upsert_timed(key, 0 if .Keepttl in plan.rules else stored_deadline(at))
	}
	entry_assign(e, argv[2])
	if .Keepttl not_in plan.rules {
		entry_set_expire(e, stored_deadline(at))
	}
	announce_set(key)
	if plan.form != .None {
		notify(.Generic, "expire", key)
	}
	if .Get not_in plan.rules {
		reply_ok(c)
	}
}

cmd_get :: proc(c: ^Conn, argv: [][]u8) {
	e := db_find_read(argv[1])
	if e == nil {
		reply_null(c)
		return
	}
	if entry_type(e) != .String {
		reply_wrongtype(c)
		return
	}
	reply_bulk(c, e.val)
}

cmd_getex :: proc(c: ^Conn, argv: [][]u8) {
	plan, parsed := read_write_plan(argv, 2, false)
	if !parsed {
		reply_error(c, ERR_SYNTAX)
		return
	}
	key := argv[1]
	e := db_find_read(key)
	if e == nil {
		reply_null(c)
		nothing_written()
		return
	}
	if entry_type(e) != .String {
		reply_wrongtype(c)
		return
	}
	at: i64
	if plan.form != .None {
		ok: bool
		at, ok = deadline_ms(c, plan.form, plan.deadline, "getex")
		if !ok {
			return
		}
	}
	reply_bulk(c, e.val)
	switch {
	case plan.form != .None && at <= expire_now():
		db_remove(key)
		signal_key(key)
		notify(.Generic, "del", key)
	case plan.form != .None:
		entry_set_expire(e, stored_deadline(at))
		signal_key(key)
		notify(.Generic, "expire", key)
	case .Persist in plan.rules && e.expire_at != 0:
		entry_set_expire(e, 0)
		signal_key(key)
		notify(.Generic, "persist", key)
	case:
		nothing_written()
	}
}

cmd_getdel :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	e := db_find_read(key)
	if e == nil {
		reply_null(c)
		nothing_written()
		return
	}
	if entry_type(e) != .String {
		reply_wrongtype(c)
		return
	}
	reply_bulk(c, e.val)
	db_remove(key)
	signal_key(key)
	notify(.Generic, "del", key)
}

cmd_getset :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	e := db_find_read(key)
	if !string_entry_of(c, e) {
		return
	}
	if e == nil {
		reply_null(c)
		e, _ = db_upsert(key)
	} else {
		reply_bulk(c, e.val)
	}
	entry_assign(e, argv[2])
	entry_set_expire(e, 0)
	announce_set(key)
}

cmd_setnx :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	if db_find(key) != nil {
		reply_int(c, 0)
		nothing_written()
		return
	}
	put_plain(key, argv[2])
	announce_set(key)
	reply_int(c, 1)
}

setex_generic :: proc(c: ^Conn, argv: [][]u8, unit: Expire_Unit, name: string) {
	form := Deadline_Form.Px if unit == .Ms else Deadline_Form.Ex
	at, ok := deadline_ms(c, form, argv[2], name)
	if !ok {
		return
	}
	key := argv[1]
	e, _ := db_upsert_timed(key, stored_deadline(at))
	entry_assign(e, argv[3])
	entry_set_expire(e, stored_deadline(at))
	announce_set(key)
	notify(.Generic, "expire", key)
	reply_ok(c)
}

cmd_setex :: proc(c: ^Conn, argv: [][]u8) {
	setex_generic(c, argv, .Sec, "setex")
}

cmd_psetex :: proc(c: ^Conn, argv: [][]u8) {
	setex_generic(c, argv, .Ms, "psetex")
}

cmd_mget :: proc(c: ^Conn, argv: [][]u8) {
	reply_array(c, len(argv) - 1)
	for key in argv[1:] {
		e := db_find_read(key)
		if e == nil || entry_type(e) != .String {
			reply_null(c)
		} else {
			reply_bulk(c, e.val)
		}
	}
}

@(private = "file")
put_pairs :: proc(argv: [][]u8) {
	for i := 1; i < len(argv); i += 2 {
		put_plain(argv[i], argv[i + 1])
		announce_set(argv[i])
	}
	pst.dirty += i64(len(argv) / 2)
}

cmd_mset :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) % 2 == 0 {
		reply_wrong_args(c, "mset")
		return
	}
	put_pairs(argv)
	reply_ok(c)
}

cmd_msetnx :: proc(c: ^Conn, argv: [][]u8) {
	if len(argv) % 2 == 0 {
		reply_wrong_args(c, "msetnx")
		return
	}
	for i := 1; i < len(argv); i += 2 {
		if db_find(argv[i]) != nil {
			reply_int(c, 0)
			nothing_written()
			return
		}
	}
	put_pairs(argv)
	reply_int(c, 1)
}

string_max_len :: #force_inline proc() -> i64 {
	limit := cfg.proto_max_bulk_len
	return limit if limit > 0 else MAX_STRING_LEN
}

@(private = "file")
STRING_STORE_LIMIT :: i64(max(u32)) - 2 * STRING_DOUBLING_LIMIT

@(private = "file")
string_length_ok :: #force_inline proc(size: i64, extra: int) -> bool {
	return size <= min(string_max_len(), STRING_STORE_LIMIT) - i64(extra)
}

cmd_append :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	tail := argv[2]
	e := db_find(key)
	if e == nil {
		e, _ = db_upsert(key)
		entry_assign(e, tail)
	} else {
		if entry_type(e) != .String {
			reply_wrongtype(c)
			return
		}
		if !string_length_ok(i64(len(e.val)), len(tail)) {
			reply_error(c, ERR_STRING_TOO_BIG)
			return
		}
		entry_append(e, tail)
	}
	signal_key(key)
	notify(.String, "append", key)
	reply_int(c, i64(len(e.val)))
}

cmd_strlen :: proc(c: ^Conn, argv: [][]u8) {
	e := db_find_read(argv[1])
	if e == nil {
		reply_int(c, 0)
		return
	}
	if entry_type(e) != .String {
		reply_wrongtype(c)
		return
	}
	reply_int(c, i64(len(e.val)))
}

cmd_setrange :: proc(c: ^Conn, argv: [][]u8) {
	offset, parsed := parse_i64(argv[2])
	if !parsed {
		reply_error(c, ERR_NOT_INT)
		return
	}
	if offset < 0 {
		reply_error(c, ERR_OFFSET_RANGE)
		return
	}
	key := argv[1]
	patch := argv[3]
	e := db_find(key)
	if !string_entry_of(c, e) {
		return
	}
	if len(patch) == 0 {
		reply_int(c, 0 if e == nil else i64(len(e.val)))
		nothing_written()
		return
	}
	if !string_length_ok(offset, len(patch)) {
		reply_error(c, ERR_STRING_TOO_BIG)
		return
	}
	if e == nil {
		e, _ = db_upsert(key)
	}
	entry_setrange(e, int(offset), patch)
	signal_key(key)
	notify(.String, "setrange", key)
	reply_int(c, i64(len(e.val)))
}

cmd_getrange :: proc(c: ^Conn, argv: [][]u8) {
	from, from_ok := parse_i64(argv[2])
	to, to_ok := parse_i64(argv[3])
	if !from_ok || !to_ok {
		reply_error(c, ERR_NOT_INT)
		return
	}
	e := db_find_read(argv[1])
	if e == nil {
		reply_bulk(c, nil)
		return
	}
	if entry_type(e) != .String {
		reply_wrongtype(c)
		return
	}
	s := e.val
	size := i64(len(s))
	if size == 0 {
		reply_bulk(c, nil)
		return
	}
	if from < 0 {
		from += size
	}
	if to < 0 {
		to += size
	}
	from = max(from, 0)
	to = min(max(to, 0), size - 1)
	if from > to {
		reply_bulk(c, nil)
		return
	}
	reply_bulk(c, s[from:to + 1])
}

incr_generic :: proc(c: ^Conn, key: []u8, delta: i64) {
	e := db_find(key)
	if !string_entry_of(c, e) {
		return
	}
	current: i64
	if e != nil {
		v, ok := parse_i64(e.val)
		if !ok {
			reply_error(c, ERR_NOT_INT)
			return
		}
		current = v
	}
	if (delta > 0 && current > max(i64) - delta) || (delta < 0 && current < min(i64) - delta) {
		reply_error(c, ERR_OVERFLOW)
		return
	}
	result := current + delta
	digits: [24]u8
	n := format_i64(raw_data(digits[:]), result)
	if e == nil {
		e, _ = db_upsert(key)
	}
	entry_assign(e, digits[:n])
	signal_key(key)
	notify(.String, "incrby", key)
	reply_int(c, result)
}

cmd_incr :: proc(c: ^Conn, argv: [][]u8) {
	incr_generic(c, argv[1], 1)
}

cmd_decr :: proc(c: ^Conn, argv: [][]u8) {
	incr_generic(c, argv[1], -1)
}

cmd_incrby :: proc(c: ^Conn, argv: [][]u8) {
	delta, ok := parse_i64(argv[2])
	if !ok {
		reply_error(c, ERR_NOT_INT)
		return
	}
	incr_generic(c, argv[1], delta)
}

cmd_decrby :: proc(c: ^Conn, argv: [][]u8) {
	delta, ok := parse_i64(argv[2])
	if !ok {
		reply_error(c, ERR_NOT_INT)
		return
	}
	if delta == min(i64) {
		reply_error(c, ERR_DECREMENT_OVERFLOW)
		return
	}
	incr_generic(c, argv[1], -delta)
}

@(private = "file")
float_text: [ld.MAX_LONG_DOUBLE_CHARS]u8

cmd_incrbyfloat :: proc(c: ^Conn, argv: [][]u8) {
	key := argv[1]
	e := db_find(key)
	if !string_entry_of(c, e) {
		return
	}
	step, step_ok := ld.parse(argv[2])
	if !step_ok {
		reply_error(c, ERR_NOT_FLOAT)
		return
	}
	current := ld.zero(false)
	if e != nil {
		v, ok := ld.parse(e.val)
		if !ok {
			reply_error(c, ERR_NOT_FLOAT)
			return
		}
		current = v
	}
	total := ld.add(current, step)
	if !ld.is_finite(total) {
		reply_error(c, ERR_FLOAT_RESULT)
		return
	}
	n := ld.format_human(total, float_text[:])
	text := float_text[:n]
	if e == nil {
		e, _ = db_upsert(key)
	}
	entry_assign(e, text)
	entry_set_encoding(e, .Embstr if n <= EMBEDDED_STRING_MAX else .Raw)
	signal_key(key)
	notify(.String, "incrbyfloat", key)
	reply_bulk(c, text)
}

Lcs_Want :: struct {
	length:   bool,
	ranges:   bool,
	min_run:  i64,
	with_len: bool,
}

@(private = "file")
read_lcs_want :: proc(c: ^Conn, argv: [][]u8) -> (want: Lcs_Want, ok: bool) {
	i := 3
	for i < len(argv) {
		tok := argv[i]
		switch {
		case eq_nocase(tok, "len"):
			want.length = true
		case eq_nocase(tok, "idx"):
			want.ranges = true
		case eq_nocase(tok, "withmatchlen"):
			want.with_len = true
		case eq_nocase(tok, "minmatchlen") && i + 1 < len(argv):
			v, parsed := parse_i64(argv[i + 1])
			if !parsed {
				reply_error(c, ERR_NOT_INT)
				return want, false
			}
			want.min_run = max(v, 0)
			i += 1
		case:
			reply_error(c, ERR_SYNTAX)
			return want, false
		}
		i += 1
	}
	if want.length && want.ranges {
		reply_error(c, ERR_LCS_LEN_AND_IDX)
		return want, false
	}
	return want, true
}

@(private = "file")
Lcs_Run :: struct {
	a_from: int,
	a_to:   int,
	b_from: int,
	b_to:   int,
}

@(private = "file")
lcs_flush :: proc(c: ^Conn, run: Lcs_Run, min_run: i64, with_len: bool, emit: bool) -> int {
	size := run.a_to - run.a_from + 1
	if i64(size) < min_run {
		return 0
	}
	if emit {
		reply_array(c, 3 if with_len else 2)
		reply_array(c, 2)
		reply_int(c, i64(run.a_from))
		reply_int(c, i64(run.a_to))
		reply_array(c, 2)
		reply_int(c, i64(run.b_from))
		reply_int(c, i64(run.b_to))
		if with_len {
			reply_int(c, i64(size))
		}
	}
	return 1
}

@(private = "file")
lcs_walk :: proc(c: ^Conn, a, b: []u8, table: [^]u32, min_run: i64, with_len: bool, emit: bool, out: [^]u8) -> int #no_bounds_check {
	width := len(b) + 1
	i := len(a)
	j := len(b)
	kept := 0
	fill := int(table[i * width + j])
	run: Lcs_Run
	open := false
	for i > 0 && j > 0 {
		if a[i - 1] == b[j - 1] {
			if out != nil {
				fill -= 1
				out[fill] = a[i - 1]
			}
			if open && run.a_from == i && run.b_from == j {
				run.a_from = i - 1
				run.b_from = j - 1
			} else {
				if open {
					kept += lcs_flush(c, run, min_run, with_len, emit)
				}
				run = Lcs_Run{i - 1, i - 1, j - 1, j - 1}
				open = true
			}
			i -= 1
			j -= 1
		} else if table[(i - 1) * width + j] > table[i * width + j - 1] {
			i -= 1
		} else {
			j -= 1
		}
	}
	if open {
		kept += lcs_flush(c, run, min_run, with_len, emit)
	}
	return kept
}

@(private = "file")
lcs_value :: proc(c: ^Conn, key: []u8, keep: ^[STABLE_VALUE_MIN]u8) -> (value: []u8, ok: bool) {
	e := db_find_read(key)
	if e == nil {
		return nil, true
	}
	if entry_type(e) != .String {
		reply_error(c, ERR_LCS_NOT_STRING)
		return nil, false
	}
	if len(e.val) < STABLE_VALUE_MIN {
		n := copy(keep[:], e.val)
		return keep[:n], true
	}
	return e.val, true
}

cmd_lcs :: proc(c: ^Conn, argv: [][]u8) {
	keep_a, keep_b: [STABLE_VALUE_MIN]u8
	a, a_ok := lcs_value(c, argv[1], &keep_a)
	if !a_ok {
		return
	}
	b, b_ok := lcs_value(c, argv[2], &keep_b)
	if !b_ok {
		return
	}
	want, parsed := read_lcs_want(c, argv)
	if !parsed {
		return
	}
	width := len(b) + 1
	limit := string_max_len()
	if i64(len(a) + 1) > limit / 4 / i64(width) {
		reply_error(c, ERR_LCS_MEMORY)
		return
	}
	cells := (len(a) + 1) * width
	if lcs_try_compute(c, argv, a, b, cells, want) {
		return
	}
	extra := min(len(a), len(b))
	block := mem_alloc(cells * size_of(u32) + extra)
	if block == nil {
		reply_error(c, ERR_LCS_MEMORY)
		return
	}
	defer mem_free(block)
	table := cast([^]u32)block
	lcs_fill(a, b, table, nil)
	lcs_reply(c, a, b, table, cast([^]u8)(&table[cells]), cells, want)
}

lcs_reply :: proc(c: ^Conn, a, b: []u8, table: [^]u32, text: [^]u8, cells: int, want: Lcs_Want) {
	total := table[cells - 1]
	if want.length {
		reply_int(c, i64(total))
		return
	}
	if !want.ranges {
		lcs_walk(c, a, b, table, 0, false, false, text)
		reply_bulk(c, text[:total])
		return
	}
	kept := lcs_walk(c, a, b, table, want.min_run, want.with_len, false, nil)
	if c.resp == RESP3 {
		reply_map(c, 2)
	} else {
		reply_array(c, 4)
	}
	reply_bulk_str(c, "matches")
	reply_array(c, kept)
	lcs_walk(c, a, b, table, want.min_run, want.with_len, true, nil)
	reply_bulk_str(c, "len")
	reply_int(c, i64(total))
}

@(private = "file")
string_commands := [?]Command {
	{"set", cmd_set, -3},
	{"get", cmd_get, 2},
	{"getex", cmd_getex, -2},
	{"getdel", cmd_getdel, 2},
	{"getset", cmd_getset, 3},
	{"setnx", cmd_setnx, 3},
	{"setex", cmd_setex, 4},
	{"psetex", cmd_psetex, 4},
	{"mget", cmd_mget, -2},
	{"mset", cmd_mset, -3},
	{"msetnx", cmd_msetnx, -3},
	{"append", cmd_append, 3},
	{"strlen", cmd_strlen, 2},
	{"setrange", cmd_setrange, 4},
	{"getrange", cmd_getrange, 4},
	{"substr", cmd_getrange, 4},
	{"incr", cmd_incr, 2},
	{"decr", cmd_decr, 2},
	{"incrby", cmd_incrby, 3},
	{"decrby", cmd_decrby, 3},
	{"incrbyfloat", cmd_incrbyfloat, 3},
	{"lcs", cmd_lcs, -3},
}

@(init)
register_string_commands :: proc "contextless" () {
	register_commands(string_commands[:])
}

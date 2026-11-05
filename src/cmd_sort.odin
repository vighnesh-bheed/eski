package main

import "base:intrinsics"
import "core:bytes"
import "core:math"
import "core:strconv"
import "base:runtime"

@(private = "file")
SORT_ERR_SCORE :: "ERR One or more scores can't be converted into double"

@(private = "file")
SORT_ERR_BY_DENIED :: "ERR BY option of SORT denied due to insufficient ACL permissions."

@(private = "file")
SORT_ERR_GET_DENIED :: "ERR GET option of SORT denied due to insufficient ACL permissions."

@(private = "file")
SORT_ABSENT :: -1

@(private = "file")
SORT_SHORT_RUN :: 12

@(private = "file")
SORT_KEEP_BYTES :: 1 << 20

@(private = "file")
SORT_KEEP_ROWS :: 1 << 15

@(private = "file")
SORT_SMALLEST_NORMAL :: 0h0010_0000_0000_0000

@(private = "file")
Sort_Row :: struct {
	elem_off: int,
	elem_len: int,
	key_off:  int,
	key_len:  int,
	prefix:   u64,
	score:    f64,
	seq:      int,
}

@(private = "file")
Sort_Order :: struct {
	data:    []u8,
	numeric: bool,
	desc:    bool,
}

@(private = "file")
Sort_Request :: struct {
	desc:      bool,
	alpha:     bool,
	natural:   bool,
	has_by:    bool,
	by:        []u8,
	has_store: bool,
	store:     []u8,
	offset:    i64,
	count:     i64,
}

@(private = "file")
Sort_Word :: enum u8 {
	Unknown,
	Asc,
	Desc,
	Alpha,
	Limit,
	Store,
	By,
	Get,
}

@(private = "file")
sort_word_operands := [Sort_Word]int {
	.Unknown = 0,
	.Asc     = 0,
	.Desc    = 0,
	.Alpha   = 0,
	.Limit   = 2,
	.Store   = 1,
	.By      = 1,
	.Get     = 1,
}

@(private = "file")
sort_word_names := [Sort_Word]string {
	.Unknown = "",
	.Asc     = "asc",
	.Desc    = "desc",
	.Alpha   = "alpha",
	.Limit   = "limit",
	.Store   = "store",
	.By      = "by",
	.Get     = "get",
}

@(private = "file")
Sort_Window :: struct {
	first: i64,
	span:  i64,
}

@(private = "file")
Sort_Value :: struct {
	off:     int,
	len:     int,
	element: bool,
}

@(private = "file")
sort_rows: [dynamic]Sort_Row

@(private = "file")
sort_spare: [dynamic]Sort_Row

@(private = "file")
sort_data: [dynamic]u8

@(private = "file")
sort_key: [dynamic]u8

@(private = "file")
sort_emit: [dynamic]u8

@(private = "file")
sort_values: [dynamic]Sort_Value

@(private = "file")
sort_get_args: [dynamic]int

@(private = "file")
sort_slices: [dynamic][]u8

sort_add_element :: proc(elem: []u8) {
	append(&sort_rows, Sort_Row{elem_off = len(sort_data), elem_len = len(elem), key_len = SORT_ABSENT, seq = len(sort_rows)})
	append(&sort_data, ..elem)
}

cmd_sort :: proc(c: ^Conn, argv: [][]u8) {
	sort_command(c, argv, true)
}

cmd_sort_ro :: proc(c: ^Conn, argv: [][]u8) {
	sort_command(c, argv, false)
}

@(private = "file")
sort_word_of :: proc(arg: []u8, writable: bool) -> Sort_Word {
	for name, word in sort_word_names {
		if word != .Unknown && eq_nocase(arg, name) {
			if word == .Store && !writable {
				return .Unknown
			}
			return word
		}
	}
	return .Unknown
}

@(private = "file")
sort_read_options :: proc(c: ^Conn, argv: [][]u8, writable: bool) -> (req: Sort_Request, ok: bool) {
	req.count = -1
	clear(&sort_get_args)
	checked, permitted := false, false
	at := 2
	for at < len(argv) {
		word := sort_word_of(argv[at], writable)
		operands := sort_word_operands[word]
		if word == .Unknown || at + operands >= len(argv) {
			reply_error(c, ERR_SYNTAX)
			return
		}
		next := at + 1
		#partial switch word {
		case .Asc:
			req.desc = false
		case .Desc:
			req.desc = true
		case .Alpha:
			req.alpha = true
		case .Limit:
			offset, offset_ok := parse_i64(argv[next])
			if !offset_ok {
				reply_error(c, ERR_NOT_INT)
				return
			}
			count, count_ok := parse_i64(argv[next + 1])
			if !count_ok {
				reply_error(c, ERR_NOT_INT)
				return
			}
			req.offset, req.count = offset, count
		case .Store:
			req.has_store = true
			req.store = argv[next]
		case .By:
			req.has_by = true
			req.by = argv[next]
			if bytes.index_byte(req.by, '*') < 0 {
				req.natural = true
			} else if !sort_full_access(c, argv, &checked, &permitted) {
				reply_error(c, SORT_ERR_BY_DENIED)
				return
			}
		case .Get:
			if !sort_full_access(c, argv, &checked, &permitted) {
				reply_error(c, SORT_ERR_GET_DENIED)
				return
			}
			append(&sort_get_args, next)
		}
		at = next + operands
	}
	ok = true
	return
}

@(private = "file")
sort_open_source :: proc(key: []u8) -> (src: ^Entry, kind: Obj_Type, sortable: bool) {
	src = db_find_read(key)
	if src == nil {
		return nil, .List, true
	}
	kind = entry_type(src)
	sortable = kind == .List || kind == .Set || kind == .Zset
	return
}

@(private = "file")
sort_load :: proc(src: ^Entry, kind: Obj_Type, req: ^Sort_Request, want: Sort_Window) -> (trimmed: bool) {
	if src == nil {
		return false
	}
	#partial switch kind {
	case .Set:
		set_sort_load(src)
	case .Zset:
		trimmed = zset_sort_load(src, req.natural, req.desc, want.first, want.span)
	case .List:
		trimmed = list_sort_load(src, req.natural, req.desc, want.first, want.first + want.span - 1, want.span)
	}
	return
}

@(private = "file")
sort_gather :: proc(src: ^Entry, kind: Obj_Type, req: ^Sort_Request) -> Sort_Window {
	total := sort_source_length(src, kind) if src != nil else 0
	want: Sort_Window
	want.first, want.span = sort_window(req.offset, req.count, total)
	sort_reset()
	if req.natural && kind != .Set {
		reserve(&sort_rows, int(want.span))
	} else {
		reserve(&sort_rows, int(total))
	}
	trimmed := sort_load(src, kind, req, want)
	held := i64(len(sort_rows))
	switch {
	case trimmed:
		return Sort_Window{0, held}
	case want.first >= held:
		return Sort_Window{}
	}
	return Sort_Window{want.first, min(want.span, held - want.first)}
}

@(private = "file")
sort_command :: proc(c: ^Conn, argv: [][]u8, writable: bool) {
	pst.dirty_explicit = true
	req, parsed := sort_read_options(c, argv, writable)
	if !parsed {
		return
	}
	src, kind, sortable := sort_open_source(argv[1])
	if !sortable {
		reply_wrongtype(c)
		return
	}
	if req.natural && kind == .Set && (req.has_store || lua_active != nil) {
		req.natural, req.alpha, req.has_by = false, true, false
	}
	view := sort_gather(src, kind, &req)
	defer sort_release()
	if !req.natural {
		if !sort_weigh(&req) {
			reply_error(c, SORT_ERR_SCORE)
			return
		}
		sort_arrange(&req, int(view.first), int(view.span))
	}
	sort_project(argv, int(view.first), int(view.span))
	if !req.has_store {
		sort_reply(c)
		return
	}
	sort_store(c, req.store)
}

@(private = "file")
sort_full_access :: proc(c: ^Conn, argv: [][]u8, known: ^bool, full: ^bool) -> bool {
	if !known^ {
		full^ = acl_unrestricted_access(c, argv, {.Access})
		known^ = true
	}
	return full^
}

@(private = "file")
sort_source_length :: proc(e: ^Entry, kind: Obj_Type) -> i64 {
	#partial switch kind {
	case .List:
		return list_sort_len(e)
	case .Set:
		return set_sort_len(e)
	case .Zset:
		return zset_sort_input_len(e)
	}
	return 0
}

@(private = "file")
sort_window :: proc(offset: i64, count: i64, total: i64) -> (first: i64, span: i64) {
	first = max(offset, 0)
	if count == 0 || first >= total {
		return 0, 0
	}
	last := total - 1
	if count > 0 && count - 1 < last - first {
		last = first + count - 1
	}
	return first, last - first + 1
}

@(private = "file")
sort_reset :: proc() {
	clear(&sort_rows)
	clear(&sort_data)
	clear(&sort_emit)
	clear(&sort_values)
	clear(&sort_slices)
}

@(private = "file")
sort_release :: proc() {
	if cap(sort_data) > SORT_KEEP_BYTES {
		delete(sort_data)
		sort_data = nil
	}
	if cap(sort_emit) > SORT_KEEP_BYTES {
		delete(sort_emit)
		sort_emit = nil
	}
	if cap(sort_key) > SORT_KEEP_BYTES {
		delete(sort_key)
		sort_key = nil
	}
	if cap(sort_rows) > SORT_KEEP_ROWS {
		delete(sort_rows)
		sort_rows = nil
	}
	if cap(sort_spare) > SORT_KEEP_ROWS {
		delete(sort_spare)
		sort_spare = nil
	}
	if cap(sort_values) > SORT_KEEP_ROWS {
		delete(sort_values)
		sort_values = nil
	}
	if cap(sort_slices) > SORT_KEEP_ROWS {
		delete(sort_slices)
		sort_slices = nil
	}
}

@(private = "file")
sort_element :: #force_inline proc(row: ^Sort_Row) -> []u8 {
	return sort_data[row.elem_off:][:row.elem_len]
}

@(private = "file")
sort_text_length :: #force_inline proc(s: []u8, whole: bool) -> int {
	if whole {
		return len(s)
	}
	if cut := bytes.index_byte(s, 0); cut >= 0 {
		return cut
	}
	return len(s)
}

@(private = "file")
sort_weigh :: proc(req: ^Sort_Request) -> bool {
	numeric := !req.alpha
	whole := req.has_store
	usable := true
	for i in 0 ..< len(sort_rows) {
		row := &sort_rows[i]
		if req.has_by {
			value, found := sort_fetch(req.by, sort_element(row))
			if numeric {
				if found {
					score, ok := sort_score(value)
					row.score = score
					usable = usable && ok
				} else {
					row.score = 0
				}
			} else if found {
				row.key_off = len(sort_data)
				row.key_len = sort_text_length(value, whole)
				row.prefix = sort_prefix(value[:row.key_len])
				append(&sort_data, ..value)
			}
		} else if numeric {
			score, ok := sort_score(sort_element(row))
			row.score = score
			usable = usable && ok
		} else {
			elem := sort_element(row)
			row.key_off = row.elem_off
			row.key_len = sort_text_length(elem, whole)
			row.prefix = sort_prefix(elem[:row.key_len])
		}
	}
	return usable
}

@(private = "file")
sort_prefix :: #force_inline proc "contextless" (s: []u8) -> u64 {
	p: u64 = 0
	n := min(len(s), 8)
	for i in 0 ..< n {
		p |= u64(s[i]) << uint(56 - 8 * i)
	}
	return p
}

@(private = "file")
sort_fetch :: proc(pattern: []u8, elem: []u8) -> (value: []u8, found: bool) {
	star := bytes.index_byte(pattern, '*')
	if star < 0 {
		return nil, false
	}
	tail := pattern[star + 1:]
	arrow := sort_arrow(tail)
	clear(&sort_key)
	append(&sort_key, ..pattern[:star])
	append(&sort_key, ..elem)
	if arrow < 0 {
		append(&sort_key, ..tail)
		e := db_find_read(sort_key[:])
		if e == nil || entry_type(e) != .String {
			return nil, false
		}
		return e.val, true
	}
	append(&sort_key, ..tail[:arrow])
	e := db_find_read(sort_key[:])
	if e == nil || entry_type(e) != .Hash {
		return nil, false
	}
	return hash_sort_field(sort_key[:], e, tail[arrow + 2:])
}

@(private = "file")
sort_arrow :: proc(s: []u8) -> int {
	for i := 0; i + 2 < len(s); i += 1 {
		if s[i] == '-' && s[i + 1] == '>' {
			return i
		}
	}
	return -1
}

@(private = "file")
sort_is_space :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == ' ' || (b >= '\t' && b <= '\r')
}

@(private = "file")
sort_is_digit :: #force_inline proc "contextless" (b: u8) -> bool {
	return b >= '0' && b <= '9'
}

@(private = "file")
sort_score :: proc(text: []u8) -> (value: f64, ok: bool) {
	s := text
	if cut := bytes.index_byte(s, 0); cut >= 0 {
		s = s[:cut]
	}
	if len(s) == 0 {
		return 0, true
	}
	i := 0
	for i < len(s) && sort_is_space(s[i]) {
		i += 1
	}
	head := i
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		i += 1
	}
	if i < len(s) && s[i] | 0x20 == 'i' {
		return sort_infinity(s[head:], i - head)
	}
	if i + 1 < len(s) && s[i] == '0' && s[i + 1] | 0x20 == 'x' {
		return sort_hex_score(s[i + 2:], head < i && s[head] == '-')
	}
	nonzero := false
	digits := 0
	for i < len(s) && sort_is_digit(s[i]) {
		nonzero = nonzero || s[i] != '0'
		digits += 1
		i += 1
	}
	if i < len(s) && s[i] == '.' {
		i += 1
		for i < len(s) && sort_is_digit(s[i]) {
			nonzero = nonzero || s[i] != '0'
			digits += 1
			i += 1
		}
	}
	if digits == 0 {
		return 0, false
	}
	if i < len(s) && s[i] | 0x20 == 'e' {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			j += 1
		}
		if j < len(s) && sort_is_digit(s[j]) {
			for j < len(s) && sort_is_digit(s[j]) {
				j += 1
			}
			i = j
		}
	}
	if i != len(s) {
		return 0, false
	}
	parsed, good := strconv.parse_f64(string(s[head:i]))
	if !good {
		return 0, false
	}
	if parsed == 0 {
		return parsed, !nonzero
	}
	if abs(parsed) < SORT_SMALLEST_NORMAL {
		return 0, false
	}
	return parsed, true
}

@(private = "file")
sort_hex_digit :: #force_inline proc "contextless" (b: u8) -> (value: u64, ok: bool) {
	switch b {
	case '0' ..= '9':
		return u64(b - '0'), true
	case 'a' ..= 'f':
		return u64(b - 'a' + 10), true
	case 'A' ..= 'F':
		return u64(b - 'A' + 10), true
	}
	return 0, false
}

@(private = "file")
sort_hex_score :: proc(s: []u8, negative: bool) -> (value: f64, ok: bool) {
	mantissa: u64 = 0
	exponent := 0
	sticky := false
	digits := 0
	fraction := false
	i := 0
	for i < len(s) {
		if s[i] == '.' && !fraction {
			fraction = true
			i += 1
			continue
		}
		d, is_hex := sort_hex_digit(s[i])
		if !is_hex {
			break
		}
		digits += 1
		if mantissa >> 60 == 0 {
			mantissa = mantissa << 4 | d
			if fraction {
				exponent -= 4
			}
		} else {
			sticky = sticky || d != 0
			if !fraction {
				exponent += 4
			}
		}
		i += 1
	}
	if digits == 0 {
		return 0, false
	}
	if i < len(s) && s[i] | 0x20 == 'p' {
		j := i + 1
		minus := false
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			minus = s[j] == '-'
			j += 1
		}
		if j < len(s) && sort_is_digit(s[j]) {
			shift := 0
			for j < len(s) && sort_is_digit(s[j]) {
				if shift < 1_000_000 {
					shift = shift * 10 + int(s[j] - '0')
				}
				j += 1
			}
			exponent += -shift if minus else shift
			i = j
		}
	}
	if i != len(s) {
		return 0, false
	}
	if mantissa == 0 {
		return 0, true
	}
	lead := int(intrinsics.count_leading_zeros(mantissa))
	top := mantissa << uint(lead)
	power := exponent - lead + 63
	kept := top >> 11
	rest := top & 0x7ff
	if rest > 0x400 || (rest == 0x400 && (sticky || kept & 1 == 1)) {
		kept += 1
		if kept == 1 << 53 {
			kept >>= 1
			power += 1
		}
	}
	if power > 1023 || power < -1022 {
		return 0, false
	}
	value = math.ldexp(f64(kept), power - 52)
	return -value if negative else value, true
}

@(private = "file")
sort_infinity :: proc(s: []u8, sign: int) -> (value: f64, ok: bool) {
	word := "infinity"
	body := s[sign:]
	matched := 0
	for matched < len(body) && matched < len(word) && body[matched] | 0x20 == word[matched] {
		matched += 1
	}
	if matched < 3 {
		return 0, false
	}
	used := 8 if matched == 8 else 3
	if used != len(body) {
		return 0, false
	}
	if sign > 0 && s[0] == '-' {
		return math.inf_f64(-1), true
	}
	return math.inf_f64(1), true
}

@(private = "file")
sort_bytes_compare :: #force_inline proc "contextless" (a: []u8, b: []u8) -> int {
	n := min(len(a), len(b))
	if n > 0 {
		if r := runtime.memory_compare(raw_data(a), raw_data(b), n); r != 0 {
			return r
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

@(private = "file")
sort_rank :: #force_inline proc "contextless" (o: ^Sort_Order, a: ^Sort_Row, b: ^Sort_Row) -> int {
	if o.numeric {
		if a.score < b.score {
			return -1
		}
		if a.score > b.score {
			return 1
		}
		return sort_bytes_compare(o.data[a.elem_off:][:a.elem_len], o.data[b.elem_off:][:b.elem_len])
	}
	if a.key_len == SORT_ABSENT {
		return 0 if b.key_len == SORT_ABSENT else -1
	}
	if b.key_len == SORT_ABSENT {
		return 1
	}
	if a.prefix != b.prefix {
		return -1 if a.prefix < b.prefix else 1
	}
	return sort_bytes_compare(o.data[a.key_off:][:a.key_len], o.data[b.key_off:][:b.key_len])
}

@(private = "file")
sort_before :: #force_inline proc "contextless" (o: ^Sort_Order, a: ^Sort_Row, b: ^Sort_Row) -> bool {
	r := sort_rank(o, a, b)
	if r != 0 {
		return (r < 0) != o.desc
	}
	return a.seq < b.seq
}

@(private = "file")
sort_arrange :: proc(req: ^Sort_Request, first: int, span: int) {
	if span == 0 {
		return
	}
	order := Sort_Order {
		data    = sort_data[:],
		numeric = !req.alpha,
		desc    = req.desc,
	}
	rows := sort_rows[:]
	need := first + span
	resize(&sort_spare, need)
	if need < len(rows) && need * 4 <= len(rows) {
		sort_select(&order, rows, need)
		sort_merge(&order, rows[:need], sort_spare[:need])
	} else {
		resize(&sort_spare, len(rows))
		sort_merge(&order, rows, sort_spare[:])
	}
}

@(private = "file")
sort_insertion :: proc(o: ^Sort_Order, v: []Sort_Row) {
	for i in 1 ..< len(v) {
		x := v[i]
		j := i
		for j > 0 && sort_before(o, &x, &v[j - 1]) {
			v[j] = v[j - 1]
			j -= 1
		}
		v[j] = x
	}
}

@(private = "file")
sort_merge :: proc(o: ^Sort_Order, v: []Sort_Row, spare: []Sort_Row) {
	n := len(v)
	if n <= SORT_SHORT_RUN {
		sort_insertion(o, v)
		return
	}
	half := n / 2
	sort_merge(o, v[:half], spare[:half])
	sort_merge(o, v[half:], spare[half:])
	if !sort_before(o, &v[half], &v[half - 1]) {
		return
	}
	copy(spare[:half], v[:half])
	i, j, k := 0, half, 0
	for i < half && j < n {
		if sort_before(o, &v[j], &spare[i]) {
			v[k] = v[j]
			j += 1
		} else {
			v[k] = spare[i]
			i += 1
		}
		k += 1
	}
	for i < half {
		v[k] = spare[i]
		i += 1
		k += 1
	}
}

@(private = "file")
sort_sift :: proc(o: ^Sort_Order, heap: []Sort_Row, at: int) {
	i := at
	for {
		child := 2 * i + 1
		if child >= len(heap) {
			return
		}
		if child + 1 < len(heap) && sort_before(o, &heap[child], &heap[child + 1]) {
			child += 1
		}
		if !sort_before(o, &heap[i], &heap[child]) {
			return
		}
		heap[i], heap[child] = heap[child], heap[i]
		i = child
	}
}

@(private = "file")
sort_select :: proc(o: ^Sort_Order, v: []Sort_Row, keep: int) {
	heap := v[:keep]
	for i := keep / 2 - 1; i >= 0; i -= 1 {
		sort_sift(o, heap, i)
	}
	for i in keep ..< len(v) {
		if sort_before(o, &v[i], &heap[0]) {
			heap[0], v[i] = v[i], heap[0]
			sort_sift(o, heap, 0)
		}
	}
}

@(private = "file")
sort_project :: proc(argv: [][]u8, first: int, span: int) {
	gets := sort_get_args[:]
	for i in first ..< first + span {
		row := &sort_rows[i]
		if len(gets) == 0 {
			append(&sort_values, Sort_Value{off = row.elem_off, len = row.elem_len, element = true})
			continue
		}
		for at in gets {
			pattern := argv[at]
			if len(pattern) == 1 && pattern[0] == '#' {
				append(&sort_values, Sort_Value{off = row.elem_off, len = row.elem_len, element = true})
				continue
			}
			value, found := sort_fetch(pattern, sort_element(row))
			if !found {
				append(&sort_values, Sort_Value{len = SORT_ABSENT})
				continue
			}
			append(&sort_values, Sort_Value{off = len(sort_emit), len = len(value)})
			append(&sort_emit, ..value)
		}
	}
}

@(private = "file")
sort_value_bytes :: #force_inline proc(v: Sort_Value) -> []u8 {
	if v.element {
		return sort_data[v.off:][:v.len]
	}
	return sort_emit[v.off:][:v.len]
}

@(private = "file")
sort_reply :: proc(c: ^Conn) {
	reply_array(c, len(sort_values))
	for v in sort_values {
		if v.len == SORT_ABSENT {
			reply_null(c)
		} else {
			reply_bulk(c, sort_value_bytes(v))
		}
	}
}

@(private = "file")
sort_store :: proc(c: ^Conn, key: []u8) {
	if len(sort_values) == 0 {
		if found, _ := db_remove(key); found {
			signal_key(key)
			notify(.Generic, "del", key)
			pst.dirty += 1
		}
		reply_int(c, 0)
		return
	}
	for v in sort_values {
		if v.len == SORT_ABSENT {
			append(&sort_slices, nil)
		} else {
			append(&sort_slices, sort_value_bytes(v))
		}
	}
	list_sort_store(key, sort_slices[:])
	signal_key(key)
	notify(.List, "sortstore", key)
	pst.dirty += i64(len(sort_values))
	reply_int(c, i64(len(sort_values)))
}

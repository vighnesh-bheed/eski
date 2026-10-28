package hashtype

import glob "../glob"
import integer "../integer"
import lp "../listpack"

DEFAULT_SCAN_COUNT :: 10

Scan_Options :: struct {
	count: int,
	pattern: []u8,
	use_pattern: bool,
	no_values: bool,
}

Hrandfield_Args :: struct {
	count: i64,
	has_count: bool,
	with_values: bool,
}

lower :: proc "contextless" (c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

is_c_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || (c >= 9 && c <= 13)
}

eq_nocase :: proc "contextless" (a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for c, i in a {
		if lower(c) != lower(b[i]) {
			return false
		}
	}
	return true
}

string_match_len :: proc "contextless" (pattern, str: []u8, nocase: bool) -> bool {
	return glob.glob_match(pattern, str, nocase)
}

parse_scan_cursor :: proc "contextless" (arg: []u8) -> (cursor: u64, ok: bool) {
	if len(arg) == 0 {
		return 0, false
	}
	end := len(arg)
	for c, j in arg {
		if c == 0 {
			end = j
			break
		}
	}
	if strict, valid := integer.parse_i64(arg[:end]); valid {
		return u64(strict), strict >= 0
	}
	i := 0
	for i < end && is_c_space(arg[i]) {
		i += 1
	}
	negative := false
	if i < end && (arg[i] == '+' || arg[i] == '-') {
		negative = arg[i] == '-'
		i += 1
	}
	if i == end {
		return 0, false
	}
	for i < end {
		c := arg[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		digit := u64(c - '0')
		if cursor > (max(u64) - digit) / 10 {
			return 0, false
		}
		cursor = cursor * 10 + digit
		i += 1
	}
	if negative {
		cursor = 0 - cursor
	}
	return cursor, true
}

parse_scan_options :: proc "contextless" (args: [][]u8, is_hash: bool) -> (opts: Scan_Options, err: Error) {
	opts.count = DEFAULT_SCAN_COUNT
	i := 0
	for i < len(args) {
		arg := args[i]
		if eq_nocase(arg, "novalues") {
			if !is_hash {
				return opts, .Novalues_Only_Hscan
			}
			opts.no_values = true
			i += 1
		} else if eq_nocase(arg, "count") {
			if i + 1 >= len(args) {
				return opts, .Syntax
			}
			n, valid := integer.parse_i64(args[i + 1])
			if !valid {
				return opts, .Value_Not_Integer
			}
			if n <= 0 {
				return opts, .Syntax
			}
			opts.count = int(n)
			i += 2
		} else if eq_nocase(arg, "match") {
			if i + 1 >= len(args) {
				return opts, .Syntax
			}
			opts.pattern = args[i + 1]
			opts.use_pattern = !(len(opts.pattern) == 1 && opts.pattern[0] == '*')
			i += 2
		} else {
			return opts, .Syntax
		}
	}
	return opts, .None
}

parse_hrandfield_args :: proc "contextless" (args: [][]u8) -> (r: Hrandfield_Args, err: Error) {
	if len(args) == 0 {
		return r, .None
	}
	v, ok := integer.parse_i64(args[0])
	if !ok {
		return r, .Value_Not_Integer
	}
	if v == min(i64) {
		return r, .Hrandfield_Count_Range
	}
	r.count = v
	r.has_count = true
	if len(args) > 1 {
		if len(args) != 2 || !eq_nocase(args[1], "withvalues") {
			return r, .Syntax
		}
		r.with_values = true
		if v > max(i64) / 2 || v < -max(i64) / 2 {
			return r, .Value_Out_Of_Range
		}
	}
	return r, .None
}

table_rev :: proc "contextless" (v: u64) -> u64 {
	x := v
	x = ((x >> 1) & 0x5555555555555555) | ((x & 0x5555555555555555) << 1)
	x = ((x >> 2) & 0x3333333333333333) | ((x & 0x3333333333333333) << 2)
	x = ((x >> 4) & 0x0f0f0f0f0f0f0f0f) | ((x & 0x0f0f0f0f0f0f0f0f) << 4)
	x = ((x >> 8) & 0x00ff00ff00ff00ff) | ((x & 0x00ff00ff00ff00ff) << 8)
	x = ((x >> 16) & 0x0000ffff0000ffff) | ((x & 0x0000ffff0000ffff) << 16)
	return (x >> 32) | (x << 32)
}

slots_scan_bucket :: proc(slots: [^]Slot, cap: int, bucket: u64, fn: proc(user: rawptr, b: ^Blob), user: rawptr) {
	if cap == 0 {
		return
	}
	mask := u64(cap - 1)
	i := int(bucket & mask)
	for _ in 0 ..< cap {
		s := slots[i]
		if s.blob == nil {
			return
		}
		if blob_live(s.blob) && s.hash & mask == bucket & mask {
			fn(user, s.blob)
		}
		i = (i + 1) & int(mask)
	}
}

table_scan_bucket :: proc(t: ^Table, v: u64, fn: proc(user: rawptr, b: ^Blob), user: rawptr) -> u64 {
	if t.count == 0 {
		return 0
	}
	capacity := t.cap
	if t.resize != nil {
		capacity = min(capacity, t.resize.old_cap)
	}
	mask := u64(capacity - 1)
	bucket := v & mask
	for bank in 0 ..< 2 {
		slots, cap := table_bank(t, bank)
		for b := bucket; b < u64(cap); b += u64(capacity) {
			slots_scan_bucket(slots, cap, b, fn, user)
		}
	}
	return table_rev(table_rev(v | ~mask) + 1)
}

Scan_Ctx :: struct {
	opts: ^Scan_Options,
	out: ^[dynamic]Value,
	sampled: int,
	now: u64,
	t: ^Table,
}

scan_callback :: proc(user: rawptr, b: ^Blob) {
	c := cast(^Scan_Ctx)user
	c.sampled += 1
	expiry := table_field_expire(c.t, b)
	if expiry != EB_EXPIRE_TIME_INVALID && expiry < c.now {
		return
	}
	f := blob_field(b)
	if c.opts.use_pattern && !glob.glob_match(c.opts.pattern, f, false) {
		return
	}
	append(c.out, Value{str = f})
	if !c.opts.no_values {
		append(c.out, Value{str = blob_value(b)})
	}
}

scan :: proc(h: Hash, cursor: u64, opts: Scan_Options, out: ^[dynamic]Value, now: u64) -> u64 {
	if h.encoding != .Hashtable {
		it := iterator_live(h, now)
		for next(&it) {
			f := current_field(&it)
			buf: [lp.LP_INTBUF_SIZE]u8
			if opts.use_pattern && !glob.glob_match(opts.pattern, value_bytes(f, &buf), false) {
				continue
			}
			append(out, f)
			if !opts.no_values {
				append(out, current_value(&it))
			}
		}
		return 0
	}
	options := opts
	c := Scan_Ctx{opts = &options, out = out, now = now, t = h.table}
	v := cursor
	budget := max(opts.count, 1)
	max_steps := max(int)
	if budget <= max(int) / 10 {
		max_steps = budget * 10
	}
	for steps := 0; steps < max_steps; steps += 1 {
		v = table_scan_bucket(h.table, v, scan_callback, &c)
		if v == 0 || c.sampled >= budget {
			break
		}
	}
	return v
}

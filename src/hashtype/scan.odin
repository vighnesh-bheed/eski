package hashtype

import "base:intrinsics"
import decimal "../decimal"
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

matches_pattern :: proc "contextless" (pattern, text: []u8, nocase: bool) -> bool {
	return glob.glob_match(pattern, text, nocase)
}

parse_scan_cursor :: proc "contextless" (arg: []u8) -> (cursor: u64, ok: bool) {
	text := arg
	for c, at in arg {
		if c == 0 {
			text = arg[:at]
			break
		}
	}
	return decimal.parse_u64_loose(text)
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

SCAN_STEPS_PER_COUNT :: 10

Scan_Page :: struct {
	opts:    Scan_Options,
	out:     ^[dynamic]Value,
	table:   ^Table,
	now:     u64,
	visited: int,
}

scan_wanted :: #force_inline proc "contextless" (opts: ^Scan_Options, text: []u8) -> bool {
	return !opts.use_pattern || glob.glob_match(opts.pattern, text, false)
}

cursor_after :: proc "contextless" (cursor: u64, buckets: int) -> u64 {
	width := intrinsics.count_trailing_zeros(u64(buckets))
	low := intrinsics.reverse_bits(cursor & u64(buckets - 1))
	return intrinsics.reverse_bits(low + (u64(1) << (64 - width)))
}

scan_chain :: proc(page: ^Scan_Page, slots: [^]Slot, capacity: int, home: int) {
	mask := capacity - 1
	at := home
	for _ in 0 ..< capacity {
		blob := slots[at].blob
		if blob == nil {
			break
		}
		if blob_live(blob) && int(slots[at].hash & u64(mask)) == home {
			page.visited += 1
			expire := table_field_expire(page.table, blob)
			stale := expire != DEADLINE_UNSET && expire < page.now
			field := blob_field(blob)
			if !stale && scan_wanted(&page.opts, field) {
				append(page.out, Value{str = field})
				if !page.opts.no_values {
					append(page.out, Value{str = blob_value(blob)})
				}
			}
		}
		at = (at + 1) & mask
	}
}

scan_bank :: proc(page: ^Scan_Page, slots: [^]Slot, capacity: int, home: int, stride: int) {
	for image := home; image < capacity; image += stride {
		scan_chain(page, slots, capacity, image)
	}
}

scan_step :: proc(page: ^Scan_Page, cursor: u64) -> u64 {
	t := page.table
	if t.count == 0 {
		return 0
	}
	moving := t.resize
	stride := t.cap
	if moving != nil {
		stride = min(stride, moving.old_cap)
	}
	home := int(cursor & u64(stride - 1))
	scan_bank(page, t.slots, t.cap, home, stride)
	if moving != nil {
		scan_bank(page, moving.old_slots, moving.old_cap, home, stride)
	}
	return cursor_after(cursor, stride)
}

scan_packed :: proc(h: Hash, opts: ^Scan_Options, out: ^[dynamic]Value, now: u64) {
	rows := iterator_live(h, now)
	for next(&rows) {
		field := current_field(&rows)
		spelled: [lp.LP_INTBUF_SIZE]u8
		if !scan_wanted(opts, value_bytes(field, &spelled)) {
			continue
		}
		append(out, field)
		if !opts.no_values {
			append(out, current_value(&rows))
		}
	}
}

scan :: proc(h: Hash, cursor: u64, opts: Scan_Options, out: ^[dynamic]Value, now: u64) -> u64 {
	if h.encoding != .Hashtable {
		packed := opts
		scan_packed(h, &packed, out, now)
		return 0
	}
	page := Scan_Page{opts = opts, out = out, table = h.table, now = now}
	goal := max(opts.count, 1)
	steps_left, overflow := intrinsics.overflow_mul(goal, SCAN_STEPS_PER_COUNT)
	if overflow {
		steps_left = max(int)
	}
	position := cursor
	for {
		position = scan_step(&page, position)
		steps_left -= 1
		if position == 0 || page.visited >= goal || steps_left == 0 {
			return position
		}
	}
}

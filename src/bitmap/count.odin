package bitmap

Bitcount_Args :: struct {
	start:  i64,
	end:    i64,
	unit:   Unit,
	ranged: bool,
}

Bitpos_Args :: struct {
	start:     i64,
	end:       i64,
	unit:      Unit,
	bit:       bool,
	ranged:    bool,
	end_given: bool,
}

parse_bitcount_args :: proc "contextless" (args: [][]u8) -> (a: Bitcount_Args, err: Error) {
	switch len(args) {
	case 0:
		return a, .None
	case 2, 3:
		a.start = parse_integer(args[0]) or_return
		a.end = parse_integer(args[1]) or_return
		if len(args) == 3 {
			a.unit = parse_unit(args[2]) or_return
		}
		a.ranged = true
		return a, .None
	case:
		return a, .Syntax
	}
}

parse_bitpos_args :: proc "contextless" (args: [][]u8) -> (a: Bitpos_Args, err: Error) {
	if len(args) == 0 {
		return a, .Syntax
	}
	b := parse_integer(args[0]) or_return
	if b != 0 && b != 1 {
		return a, .Bit_Argument
	}
	a.bit = b == 1
	a.end = -1
	if len(args) > 4 {
		return a, .Syntax
	}
	if len(args) >= 2 {
		a.start = parse_integer(args[1]) or_return
		a.ranged = true
	}
	if len(args) == 4 {
		a.unit = parse_unit(args[3]) or_return
	}
	if len(args) >= 3 {
		a.end = parse_integer(args[2]) or_return
		a.end_given = true
	}
	return a, .None
}

clamp_range :: #force_inline proc "contextless" (total, start_in, end_in: i64) -> (start, end: i64) {
	start = start_in
	end = end_in
	if start < 0 {
		start += total
	}
	if end < 0 {
		end += total
	}
	if start < 0 {
		start = 0
	}
	if end < 0 {
		end = 0
	}
	if end >= total {
		end = total - 1
	}
	return
}

bitcount :: proc "contextless" (buf: []u8, start_in, end_in: i64, unit: Unit) -> i64 #no_bounds_check {
	if start_in < 0 && end_in < 0 && start_in > end_in {
		return 0
	}
	n := i64(len(buf))
	total := n * 8 if unit == .Bit else n
	start, end := clamp_range(total, start_in, end_in)
	if start > end {
		return 0
	}
	p := raw_data(buf)
	if unit == .Bit {
		return count_bit_range(p, start, end)
	}
	return popcount_raw(p[start:], int(end - start + 1))
}

bitcount_args :: proc "contextless" (buf: []u8, a: Bitcount_Args) -> i64 {
	if !a.ranged {
		return popcount(buf)
	}
	return bitcount(buf, a.start, a.end, a.unit)
}

bitpos_all :: proc "contextless" (buf: []u8, bit: bool) -> i64 {
	if len(buf) == 0 {
		return -1
	}
	r := find_bit(buf, bit)
	if r < 0 && !bit {
		return i64(len(buf)) * 8
	}
	return r
}

bitpos :: proc "contextless" (
	buf: []u8,
	bit: bool,
	start_in, end_in: i64,
	unit: Unit,
	end_given: bool,
) -> i64 #no_bounds_check {
	n := i64(len(buf))
	total := n * 8 if unit == .Bit else n
	start, end := clamp_range(total, start_in, end_in)
	if start > end {
		return -1
	}
	lo, hi := start, end
	if unit == .Byte {
		lo = start * 8
		hi = end * 8 + 7
	}
	r := find_bit_range(raw_data(buf), bit, lo, hi)
	if r < 0 && !bit && !end_given {
		return hi + 1
	}
	return r
}

bitpos_args :: proc "contextless" (buf: []u8, exists: bool, a: Bitpos_Args) -> i64 {
	if !exists {
		return -1 if a.bit else 0
	}
	if !a.ranged {
		return bitpos_all(buf, a.bit)
	}
	end := a.end if a.end_given else -1
	return bitpos(buf, a.bit, a.start, end, a.unit, a.end_given)
}

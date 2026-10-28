package hashtype

import integer "../integer"
import ld "../ldfloat"
import lp "../listpack"

parse_incrby_increment :: proc "contextless" (arg: []u8) -> (i64, Error) {
	v, ok := integer.parse_i64(arg)
	if !ok {
		return 0, .Value_Not_Integer
	}
	return v, .None
}

parse_incrbyfloat_increment :: proc "contextless" (arg: []u8) -> (ld.F80, Error) {
	v, ok := ld.parse(arg)
	if !ok {
		return {}, .Value_Not_Float
	}
	if !ld.is_finite(v) {
		return {}, .Value_Nan_Or_Infinity
	}
	return v, .None
}

incrby :: proc(h: Hash, field: []u8, incr: i64, now: u64) -> (result: i64, err: Error) {
	v, res := get(h, field, now)
	if res == .Expired_Hash {
		reset(h)
	}
	old: i64
	if res == .Ok {
		if v.is_int {
			old = v.ival
		} else {
			ok: bool
			old, ok = integer.parse_i64(v.str)
			if !ok {
				return 0, .Hash_Value_Not_Integer
			}
		}
	}
	if (incr > 0 && old > max(i64) - incr) || (incr < 0 && old < min(i64) - incr) {
		return 0, .Increment_Overflow
	}
	result = old + incr
	buf: [lp.LP_INTBUF_SIZE]u8
	value := value_bytes(Value{ival = result, is_int = true}, &buf)
	set(h, field, value, true)
	return result, .None
}

incrbyfloat :: proc(h: Hash, field: []u8, incr: ld.F80, buf: []u8, now: u64) -> (result: []u8, err: Error) {
	v, res := get(h, field, now)
	if res == .Expired_Hash {
		reset(h)
	}
	old := ld.zero(false)
	if res == .Ok {
		if v.is_int {
			old = ld.from_i64(v.ival)
		} else {
			ok: bool
			old, ok = ld.parse(v.str)
			if !ok {
				return nil, .Hash_Value_Not_Float
			}
		}
	}
	sum := ld.add(old, incr)
	if !ld.is_finite(sum) {
		return nil, .Increment_Nan_Or_Infinity
	}
	n := ld.format_human(sum, buf)
	result = buf[:n]
	set(h, field, result, true)
	return result, .None
}

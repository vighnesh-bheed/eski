package hashtype

import integer "../integer"

parse_numfields :: proc "contextless" (argv: [][]u8, at: int, err_value: Error) -> (fields: [][]u8, err: Error) {
	if at < 0 || at >= len(argv) {
		return nil, err_value
	}
	count, valid := integer.parse_i64(argv[at])
	if !valid || count <= 0 {
		return nil, err_value
	}
	if count != i64(len(argv) - at - 1) {
		return nil, .Numfields_Mismatch
	}
	return argv[at + 1:], .None
}

parse_fields_args :: proc "contextless" (argv: [][]u8) -> (fields: [][]u8, err: Error) {
	if len(argv) <= 2 || !eq_nocase(argv[2], "fields") {
		return nil, .Fields_Missing
	}
	return parse_numfields(argv, 3, .Numfields_Positive)
}

parse_expire_args :: proc "contextless" (argv: [][]u8, unit_seconds: bool, basetime: u64) -> (r: Expire_Args, err: Error) {
	if len(argv) <= 2 {
		return r, .Value_Not_Integer
	}
	value, valid := integer.parse_i64(argv[2])
	if !valid {
		return r, .Value_Not_Integer
	}
	if value < 0 {
		return r, .Invalid_Expire_Negative
	}
	duration := u64(value)
	if unit_seconds {
		if duration > FIELD_DEADLINE_COMMAND_MAX / 1000 {
			return r, .Invalid_Expire_Time
		}
		duration *= 1000
	}
	if duration > FIELD_DEADLINE_COMMAND_MAX || basetime > FIELD_DEADLINE_COMMAND_MAX - duration {
		return r, .Invalid_Expire_Time
	}
	r.expire_at = basetime + duration
	at := 3
	if at < len(argv) {
		if eq_nocase(argv[at], "nx") {
			r.cond = .NX
			at += 1
		} else if eq_nocase(argv[at], "xx") {
			r.cond = .XX
			at += 1
		} else if eq_nocase(argv[at], "gt") {
			r.cond = .GT
			at += 1
		} else if eq_nocase(argv[at], "lt") {
			r.cond = .LT
			at += 1
		}
	}
	if at >= len(argv) || !eq_nocase(argv[at], "fields") {
		return r, .Fields_Missing
	}
	r.fields, err = parse_numfields(argv, at + 1, .Numfields_Expire)
	return
}

package integer

DIGITS_MAX :: 19
POSITIVE_CEILING :: u64(9_223_372_036_854_775_807)

parse_i64 :: proc "contextless" (s: []u8) -> (i64, bool) #no_bounds_check {
	if len(s) == 1 && s[0] == '0' {
		return 0, true
	}
	body := s
	ceiling := POSITIVE_CEILING
	if len(body) > 0 && body[0] == '-' {
		body = body[1:]
		ceiling += 1
	}
	if len(body) == 0 || len(body) > DIGITS_MAX || body[0] == '0' {
		return 0, false
	}
	total: u64
	for b in body {
		digit := b - '0'
		if digit > 9 {
			return 0, false
		}
		total = total * 10 + u64(digit)
	}
	if total > ceiling {
		return 0, false
	}
	if ceiling == POSITIVE_CEILING {
		return i64(total), true
	}
	return cast(i64)(~total + 1), true
}

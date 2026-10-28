package integer

parse_i64 :: proc "contextless" (s: []u8) -> (i64, bool) {
	n := len(s)
	if n == 0 {
		return 0, false
	}

	#no_bounds_check {
		if n == 1 {
			c := s[0]
			if c >= '0' && c <= '9' {
				return i64(c - '0'), true
			}
			return 0, false
		}

		negative := s[0] == '-'
		start := 0
		if negative {
			start = 1
		}

		if n - start > 19 {
			return 0, false
		}

		first := s[start]
		if first < '1' || first > '9' {
			return 0, false
		}

		magnitude := u64(first - '0')
		for i := start + 1; i < n; i += 1 {
			c := s[i]
			if c < '0' || c > '9' {
				return 0, false
			}
			magnitude = magnitude * 10 + u64(c - '0')
		}

		if negative {
			if magnitude > 9223372036854775808 {
				return 0, false
			}
			return -i64(magnitude - 1) - 1, true
		}
		if magnitude > 9223372036854775807 {
			return 0, false
		}
		return i64(magnitude), true
	}
}

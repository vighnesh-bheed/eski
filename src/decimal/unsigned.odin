package decimal

import "base:intrinsics"

parse_u64_loose :: proc "contextless" (s: []u8) -> (u64, bool) {
	at := 0
	for at < len(s) && (s[at] == ' ' || (s[at] >= '\t' && s[at] <= '\r')) {
		at += 1
	}
	minus := false
	signed := at < len(s) && (s[at] == '+' || s[at] == '-')
	if signed {
		minus = s[at] == '-'
		at += 1
	}
	digits := s[at:]
	if len(digits) == 0 {
		return 0, false
	}
	total: u64
	for c in digits {
		if c < '0' || c > '9' {
			return 0, false
		}
		scaled, wide := intrinsics.overflow_mul(total, 10)
		sum, carry := intrinsics.overflow_add(scaled, u64(c - '0'))
		if wide || carry {
			return 0, false
		}
		total = sum
	}
	if !minus {
		return total, true
	}
	if at == 1 && digits[0] != '0' && total <= u64(1) << 63 {
		return 0, false
	}
	return 0 - total, true
}

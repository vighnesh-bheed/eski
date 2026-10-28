package bitmap

PROTO_MAX_BULK_LEN :: i64(512 * 1024 * 1024)

LONG_STR_SIZE :: 21

Unit :: enum u8 {
	Byte,
	Bit,
}

parse_ll :: proc "contextless" (s: []u8) -> (value: i64, ok: bool) #no_bounds_check {
	n := len(s)
	if n == 0 || n > 20 {
		return 0, false
	}
	if n == 1 && s[0] == '0' {
		return 0, true
	}
	i := 0
	negative := s[0] == '-'
	if negative {
		i = 1
		if n == 1 {
			return 0, false
		}
	}
	if s[i] < '1' || s[i] > '9' {
		return 0, false
	}
	magnitude: u64 = 0
	for ; i < n; i += 1 {
		d := u64(s[i]) - '0'
		if d > 9 {
			return 0, false
		}
		if magnitude > (max(u64) - d) / 10 {
			return 0, false
		}
		magnitude = magnitude * 10 + d
	}
	if negative {
		if magnitude > u64(max(i64)) + 1 {
			return 0, false
		}
		return i64(0 - magnitude), true
	}
	if magnitude > u64(max(i64)) {
		return 0, false
	}
	return i64(magnitude), true
}

c_string :: proc "contextless" (s: []u8) -> []u8 #no_bounds_check {
	for i in 0 ..< len(s) {
		if s[i] == 0 {
			return s[:i]
		}
	}
	return s
}

equal_fold :: proc "contextless" (s: []u8, lit: string) -> bool #no_bounds_check {
	if len(s) != len(lit) {
		return false
	}
	for i in 0 ..< len(s) {
		a := s[i]
		b := lit[i]
		if a - 'A' < 26 {
			a += 'a' - 'A'
		}
		if b - 'A' < 26 {
			b += 'a' - 'A'
		}
		if a != b {
			return false
		}
	}
	return true
}

parse_integer :: proc "contextless" (s: []u8) -> (value: i64, err: Error) {
	v, ok := parse_ll(s)
	if !ok {
		return 0, .Not_Integer
	}
	return v, .None
}

parse_bit_offset :: proc "contextless" (
	s: []u8,
	hash := false,
	bits := 0,
	max_bulk_len := PROTO_MAX_BULK_LEN,
) -> (
	offset: u64,
	err: Error,
) {
	digits := s
	scaled := false
	if hash && len(s) > 0 && s[0] == '#' {
		digits = s[1:]
		scaled = true
	}
	v, ok := parse_ll(digits)
	if !ok {
		return 0, .Bit_Offset
	}
	if scaled {
		v = i64(u64(v) * u64(bits))
	}
	if v < 0 || (v >> 3) >= max_bulk_len {
		return 0, .Bit_Offset
	}
	return u64(v), .None
}

parse_bit_value :: proc "contextless" (s: []u8) -> (on: bool, err: Error) {
	if len(s) == 1 {
		if s[0] == '0' {
			return false, .None
		}
		if s[0] == '1' {
			return true, .None
		}
	}
	return false, .Bit_Value
}

parse_unit :: proc "contextless" (s: []u8) -> (unit: Unit, err: Error) {
	word := c_string(s)
	if equal_fold(word, "byte") {
		return .Byte, .None
	}
	if equal_fold(word, "bit") {
		return .Bit, .None
	}
	return .Byte, .Syntax
}

parse_bitfield_type :: proc "contextless" (s: []u8) -> (signed: bool, bits: int, err: Error) {
	word := c_string(s)
	if len(word) < 2 {
		return false, 0, .Bitfield_Type
	}
	switch word[0] {
	case 'i':
		signed = true
	case 'u':
		signed = false
	case:
		return false, 0, .Bitfield_Type
	}
	width, ok := parse_ll(word[1:])
	limit := i64(64) if signed else i64(63)
	if !ok || width < 1 || width > limit {
		return false, 0, .Bitfield_Type
	}
	return signed, int(width), .None
}

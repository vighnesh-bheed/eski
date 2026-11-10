package vsetargs

import "core:log"
import "core:strings"
import "core:testing"

@(test)
number_vectors_round_exactly :: proc(t: ^testing.T) {
	matched := 0
	for c in NUMBER_CASES {
		value, ok := parse_double(transmute([]u8)c.text)
		good := ok == c.accepted && (!ok || transmute(u64)value == c.bits)
		if good {
			matched += 1
		} else {
			testing.expectf(t, false, "%q: got %v %016x, want %v %016x", c.text, ok, transmute(u64)value, c.accepted, c.bits)
		}
	}
	log.infof("number vectors: %d of %d", matched, len(NUMBER_CASES))
}

@(test)
integers_follow_the_strict_grammar :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		value: i64,
		ok:    bool,
	} {
		{"0", 0, true},
		{"1", 1, true},
		{"-1", -1, true},
		{"9223372036854775807", max(i64), true},
		{"-9223372036854775808", min(i64), true},
		{"9223372036854775808", 0, false},
		{"-9223372036854775809", 0, false},
		{"-0", 0, false},
		{"00", 0, false},
		{"01", 0, false},
		{"+1", 0, false},
		{" 1", 0, false},
		{"1 ", 0, false},
		{"", 0, false},
		{"-", 0, false},
		{"1.0", 0, false},
		{"1e2", 0, false},
		{"0x1", 0, false},
		{"1\x00", 0, false},
		{"99999999999999999999", 0, false},
	}
	for c in cases {
		value, ok := parse_i64(transmute([]u8)c.text)
		testing.expectf(t, ok == c.ok && (!ok || value == c.value), "%q: got %v %d", c.text, ok, value)
	}
}

oracle_double :: proc(s: []u8) -> (value: f64, ok: bool) {
	if len(s) == 0 || s[0] == ' ' || (s[0] >= '\t' && s[0] <= '\r') {
		return 0, false
	}
	buffer := make([]u8, len(s) + 1, context.temp_allocator)
	copy(buffer, s)
	locale := libc_newlocale(LC_NUMERIC_MASK, "C", nil)
	end: cstring
	value = libc_strtod_l(cstring(raw_data(buffer)), &end, locale)
	libc_freelocale(locale)
	consumed := int(uintptr(rawptr(end)) - uintptr(raw_data(buffer)))
	if consumed != len(s) || value != value {
		return 0, false
	}
	body := s
	if body[0] == '+' || body[0] == '-' {
		body = body[1:]
	}
	if len(body) > 0 && (body[0] == 'i' || body[0] == 'I') {
		return value, true
	}
	if len(body) > 1 && body[0] == '0' && (body[1] == 'x' || body[1] == 'X') {
		nonzero := false
		for c in body[2:] {
			if c == 'p' || c == 'P' {
				break
			}
			if c != '0' && c != '.' {
				nonzero = true
			}
		}
		infinite := transmute(u64)value & 0x7FFF_FFFF_FFFF_FFFF == 0x7FF0_0000_0000_0000
		return value, !infinite && (value != 0 || !nonzero)
	}
	mark := strings.index_any(string(body), "eE")
	mantissa := body if mark < 0 else body[:mark]
	exponent: i64
	if mark >= 0 {
		digits := body[mark + 1:]
		minus := len(digits) > 0 && digits[0] == '-'
		if len(digits) > 0 && (digits[0] == '-' || digits[0] == '+') {
			digits = digits[1:]
		}
		for c in digits {
			if exponent < 100_000_000 {
				exponent = exponent * 10 + i64(c - '0')
			}
		}
		if minus {
			exponent = -exponent
		}
	}
	significant := 0
	fraction := 0
	after_point := false
	leading := true
	for c in mantissa {
		if c == '.' {
			after_point = true
			continue
		}
		if after_point {
			fraction += 1
		}
		if leading && c == '0' {
			continue
		}
		leading = false
		significant += 1
	}
	if significant == 0 {
		return value, true
	}
	scale := exponent - i64(fraction)
	if significant <= 19 {
		return value, scale >= -342 && scale <= 308
	}
	infinite := transmute(u64)value & 0x7FFF_FFFF_FFFF_FFFF == 0x7FF0_0000_0000_0000
	return value, value != 0 && !infinite
}

Number_Fuzz :: struct {
	state: u64,
}

number_fuzz_next :: proc(r: ^Number_Fuzz) -> u64 {
	x := r.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	r.state = x
	return x * 0x2545F4914F6CDD1D
}

number_fuzz_below :: proc(r: ^Number_Fuzz, n: int) -> int {
	return int(number_fuzz_next(r) % u64(n))
}

@(rodata)
FUZZ_SIGNS := [?]string{"", "+", "-"}

@(rodata)
FUZZ_POWERS := [?]string{"0", "1", "52", "1022", "1023", "1024", "1074", "1075", "1076", "1100", "99999999999"}

@(rodata)
FUZZ_SPECIALS := [?]string{"inf", "INF", "infinity", "Infinity", "nan", "-inf", "+INFINITY", "infinit", "nan(1)", "-nan"}

number_fuzz_pick :: proc(r: ^Number_Fuzz, list: []string) -> string {
	return list[number_fuzz_below(r, len(list))]
}

number_fuzz_digits :: proc(r: ^Number_Fuzz, b: ^strings.Builder, n: int, alphabet: string) {
	for _ in 0 ..< n {
		strings.write_byte(b, alphabet[number_fuzz_below(r, len(alphabet))])
	}
}

number_fuzz_text :: proc(r: ^Number_Fuzz, b: ^strings.Builder) {
	strings.builder_reset(b)
	switch number_fuzz_below(r, 8) {
	case 0:
		number_fuzz_digits(r, b, 1 + number_fuzz_below(r, 12), "0123456789.eE+-xXpPabcdefinINFtyNA \t")
	case 1:
		strings.write_string(b, number_fuzz_pick(r, FUZZ_SIGNS[:]))
		strings.write_string(b, "0x")
		number_fuzz_digits(r, b, number_fuzz_below(r, 20), "0123456789abcdefABCDEF")
		if number_fuzz_below(r, 2) == 0 {
			strings.write_byte(b, '.')
			number_fuzz_digits(r, b, number_fuzz_below(r, 6), "0123456789abcdef")
		}
		if number_fuzz_below(r, 4) != 0 {
			strings.write_byte(b, 'p')
			strings.write_string(b, number_fuzz_pick(r, FUZZ_SIGNS[:]))
			strings.write_string(b, number_fuzz_pick(r, FUZZ_POWERS[:]))
		}
	case 2:
		strings.write_string(b, number_fuzz_pick(r, FUZZ_SPECIALS[:]))
	case:
		strings.write_string(b, number_fuzz_pick(r, FUZZ_SIGNS[:]))
		n := 1 + number_fuzz_below(r, 24)
		if number_fuzz_below(r, 40) == 0 {
			n = 300 + number_fuzz_below(r, 700)
		}
		lead := number_fuzz_below(r, 4) == 0
		if lead {
			strings.write_string(b, "0.")
			number_fuzz_digits(r, b, number_fuzz_below(r, 30), "0")
		}
		point := number_fuzz_below(r, n + 1)
		for i in 0 ..< n {
			if !lead && i == point && number_fuzz_below(r, 2) == 0 {
				strings.write_byte(b, '.')
			}
			number_fuzz_digits(r, b, 1, "0123456789")
		}
		if number_fuzz_below(r, 5) != 0 {
			number_fuzz_digits(r, b, 1, "eE")
			strings.write_string(b, number_fuzz_pick(r, FUZZ_SIGNS[:]))
			if number_fuzz_below(r, 30) == 0 {
				strings.write_string(b, "99999999999999999999")
			} else {
				strings.write_int(b, number_fuzz_below(r, 420))
			}
		}
	}
}

@(test)
doubles_match_strtod_under_the_reference_range_rule :: proc(t: ^testing.T) {
	r := Number_Fuzz{state = 0x51A7E5EED0FF1CE5}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	accepted, rejected := 0, 0
	for _ in 0 ..< 150_000 {
		number_fuzz_text(&r, &b)
		text := transmute([]u8)strings.to_string(b)
		value, ok := parse_double(text)
		want, want_ok := oracle_double(text)
		if ok != want_ok || (ok && transmute(u64)value != transmute(u64)want) {
			testing.expectf(t, false, "%q: got %v %016x, strtod oracle %v %016x", string(text), ok, transmute(u64)value, want_ok, transmute(u64)want)
		}
		if ok {
			accepted += 1
		} else {
			rejected += 1
		}
		free_all(context.temp_allocator)
	}
	log.infof("double fuzz: %d accepted, %d rejected, all equal to strtod", accepted, rejected)
	testing.expect(t, accepted > 50_000 && rejected > 20_000)
}

@(test)
values_cast_through_double :: proc(t: ^testing.T) {
	cases := [?]struct {
		text: string,
		bits: u32,
	} {
		{"1.00000005960464477539", 0x3F80_0000},
		{"1.00000005960464478", 0x3F80_0000},
		{"1.0000000596046448", 0x3F80_0000},
		{"0.1", 0x3DCC_CCCD},
		{"3.4028235e38", 0x7F7F_FFFF},
		{"3.4028236e38", 0x7F80_0000},
		{"1e39", 0x7F80_0000},
		{"-1e39", 0xFF80_0000},
		{"1e-46", 0},
		{"-0", 0x8000_0000},
		{"7e-46", 0},
		{"7.1e-46", 1},
	}
	for c in cases {
		value, ok := parse_double(transmute([]u8)c.text)
		testing.expectf(t, ok, "%q rejected", c.text)
		testing.expectf(t, transmute(u32)f32(value) == c.bits, "%q: got %08x want %08x", c.text, transmute(u32)f32(value), c.bits)
	}
}

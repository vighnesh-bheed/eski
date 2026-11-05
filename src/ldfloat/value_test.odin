package ldfloat

import "core:strconv"
import "core:testing"

Parsed :: struct {
	spelling: string,
	ok:       bool,
	value:    F80,
}

Sum :: struct {
	a, b:  string,
	value: F80,
}

Integer :: struct {
	value:    i64,
	expected: F80,
}

@(test)
parsed_values_are_exact :: proc(t: ^testing.T) {
	cases := [?]Parsed{
		{"0", true, F80{class = .Zero}},
		{"-0", true, F80{neg = true, class = .Zero}},
		{"+0", true, F80{class = .Zero}},
		{"0.0", true, F80{class = .Zero}},
		{"-0.0", true, F80{neg = true, class = .Zero}},
		{"0x0", true, F80{class = .Zero}},
		{"-0x0", true, F80{neg = true, class = .Zero}},
		{"1", true, F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
		{"-1", true, F80{mant = 0x8000000000000000, exp = -63, neg = true, class = .Finite}},
		{"0.5", true, F80{mant = 0x8000000000000000, exp = -64, class = .Finite}},
		{"0x1p-3", true, F80{mant = 0x8000000000000000, exp = -66, class = .Finite}},
		{"1e3", true, F80{mant = 0xfa00000000000000, exp = -54, class = .Finite}},
		{"3", true, F80{mant = 0xc000000000000000, exp = -62, class = .Finite}},
		{"10", true, F80{mant = 0xa000000000000000, exp = -60, class = .Finite}},
		{"9223372036854775807", true, F80{mant = 0xfffffffffffffffe, exp = -1, class = .Finite}},
		{"-9223372036854775808", true, F80{mant = 0x8000000000000000, exp = 0, neg = true, class = .Finite}},
		{"18446744073709551615", true, F80{mant = 0xffffffffffffffff, exp = 0, class = .Finite}},
		{"18446744073709551616", true, F80{mant = 0x8000000000000000, exp = 1, class = .Finite}},
		{"18446744073709551617", true, F80{mant = 0x8000000000000000, exp = 1, class = .Finite}},
		{"18446744073709551618", true, F80{mant = 0x8000000000000001, exp = 1, class = .Finite}},
		{"18446744073709551619", true, F80{mant = 0x8000000000000002, exp = 1, class = .Finite}},
		{"36893488147419103231", true, F80{mant = 0x8000000000000000, exp = 2, class = .Finite}},
		{"36893488147419103233", true, F80{mant = 0x8000000000000000, exp = 2, class = .Finite}},
		{"0.1", true, F80{mant = 0xcccccccccccccccd, exp = -67, class = .Finite}},
		{"-0.1", true, F80{mant = 0xcccccccccccccccd, exp = -67, neg = true, class = .Finite}},
		{"3.14159265358979323846", true, F80{mant = 0xc90fdaa22168c235, exp = -62, class = .Finite}},
		{"3.3621031431120935063e-4932", true, F80{mant = 0x8000000000000000, exp = -16445, class = .Finite}},
		{"3.3621031431120935062e-4932", true, F80{mant = 0x8000000000000000, exp = -16445, class = .Finite}},
		{"1e-4932", true, F80{mant = 0x261247c8f29357f0, exp = -16445, class = .Finite}},
		{"1e-4940", true, F80{mant = 0x663278e62, exp = -16445, class = .Finite}},
		{"-1e-4945", true, F80{mant = 0x42f9d, exp = -16445, neg = true, class = .Finite}},
		{"1e-4945", true, F80{mant = 0x42f9d, exp = -16445, class = .Finite}},
		{"3.6451995318824746025e-4951", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"3.6451995318824746026e-4951", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"3.6e-4951", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"3.7e-4951", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"2e-4951", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"1.9e-4951", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"1.8225997659412373013e-4951", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"1.822599765941237302e-4951", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"1.8e-4951", false, {}},
		{"1e-4951", false, {}},
		{"1.822599765941237301e-4951", false, {}},
		{"0x1p-16382", true, F80{mant = 0x8000000000000000, exp = -16445, class = .Finite}},
		{"0x1p-16383", true, F80{mant = 0x4000000000000000, exp = -16445, class = .Finite}},
		{"0x1p-16444", true, F80{mant = 0x2, exp = -16445, class = .Finite}},
		{"0x1p-16445", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"-0x1p-16445", true, F80{mant = 0x1, exp = -16445, neg = true, class = .Finite}},
		{"0x1.8p-16445", true, F80{mant = 0x2, exp = -16445, class = .Finite}},
		{"0x1.8p-16446", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"0x1p-16446", false, {}},
		{"0x3p-16446", true, F80{mant = 0x2, exp = -16445, class = .Finite}},
		{"0x1.fffffffffffffffp-16446", true, F80{mant = 0x1, exp = -16445, class = .Finite}},
		{"0x0.fffffffffffffffp-16382", true, F80{mant = 0x7ffffffffffffff8, exp = -16445, class = .Finite}},
		{"0x0.ffffffffffffffffp-16382", true, F80{mant = 0x8000000000000000, exp = -16445, class = .Finite}},
		{"0x0.fffffffffffffffe8p-16382", true, F80{mant = 0x7fffffffffffffff, exp = -16445, class = .Finite}},
		{"0x0.fffffffffffffffe7p-16382", true, F80{mant = 0x7fffffffffffffff, exp = -16445, class = .Finite}},
		{"0x1p-16447", false, {}},
		{"1.18973149535723176502e4932", true, F80{mant = 0xffffffffffffffff, exp = 16320, class = .Finite}},
		{"1.18973149535723176503e4932", true, F80{mant = 0xffffffffffffffff, exp = 16320, class = .Finite}},
		{"1.19e4932", false, {}},
		{"1e4932", true, F80{mant = 0xd72cb2a95c7ef6cd, exp = 16320, class = .Finite}},
		{"1e4933", false, {}},
		{"0x1.fffffffffffffffep16383", true, F80{mant = 0xffffffffffffffff, exp = 16320, class = .Finite}},
		{"0x1.fffffffffffffffe8p16383", true, F80{mant = 0xffffffffffffffff, exp = 16320, class = .Finite}},
		{"0x1.fffffffffffffffe9p16383", true, F80{mant = 0xffffffffffffffff, exp = 16320, class = .Finite}},
		{"0xfffffffffffffffe.8p16320", true, F80{mant = 0xfffffffffffffffe, exp = 16320, class = .Finite}},
		{"0xffffffffffffffff.8p16320", false, {}},
		{"0xffffffffffffffff.7p16320", true, F80{mant = 0xffffffffffffffff, exp = 16320, class = .Finite}},
		{"0xffffffffffffffffp16320", true, F80{mant = 0xffffffffffffffff, exp = 16320, class = .Finite}},
		{"0x1p16383", true, F80{mant = 0x8000000000000000, exp = 16320, class = .Finite}},
		{"-0x1p16383", true, F80{mant = 0x8000000000000000, exp = 16320, neg = true, class = .Finite}},
		{"0x1p16384", false, {}},
		{"0x1p63", true, F80{mant = 0x8000000000000000, exp = 0, class = .Finite}},
		{"0x1p64", true, F80{mant = 0x8000000000000000, exp = 1, class = .Finite}},
		{"0x10000000000000001", true, F80{mant = 0x8000000000000000, exp = 1, class = .Finite}},
		{"0x10000000000000003", true, F80{mant = 0x8000000000000002, exp = 1, class = .Finite}},
		{"0x1.8p1", true, F80{mant = 0xc000000000000000, exp = -62, class = .Finite}},
		{"0xdeadbeefcafebabep-30", true, F80{mant = 0xdeadbeefcafebabe, exp = -30, class = .Finite}},
		{"inf", true, F80{class = .Inf}},
		{"-inf", true, F80{neg = true, class = .Inf}},
		{"INF", true, F80{class = .Inf}},
		{"Infinity", true, F80{class = .Inf}},
		{"-Infinity", true, F80{neg = true, class = .Inf}},
		{"nan", false, {}},
		{"-nan", false, {}},
		{"", false, {}},
		{"abc", false, {}},
		{"0x1p", false, {}},
	}
	for c in cases {
		got, ok := parse(transmute([]u8)c.spelling)
		testing.expectf(t, ok == c.ok, "parse of %q: accepted is %v, expected %v", c.spelling, ok, c.ok)
		if ok && c.ok {
			testing.expectf(t, got == c.value, "parse of %q gave %v, expected %v", c.spelling, got, c.value)
		}
	}
}

@(test)
sums_are_exact_and_commute :: proc(t: ^testing.T) {
	cases := [?]Sum{
		{"0x1p-16445", "0x1p-16445", F80{mant = 0x2, exp = -16445, class = .Finite}},
		{"0x1p-16445", "-0x1p-16445", F80{class = .Zero}},
		{"0x1p-16445", "0x1p-16444", F80{mant = 0x3, exp = -16445, class = .Finite}},
		{"0x1p-16383", "0x1p-16383", F80{mant = 0x8000000000000000, exp = -16445, class = .Finite}},
		{"0x1p-16382", "-0x1p-16445", F80{mant = 0x7fffffffffffffff, exp = -16445, class = .Finite}},
		{"0x1p-16382", "0x1p-16445", F80{mant = 0x8000000000000001, exp = -16445, class = .Finite}},
		{"0x1p-16382", "-0x1p-16382", F80{class = .Zero}},
		{"0x1p-16383", "-0x1p-16382", F80{mant = 0x4000000000000000, exp = -16445, neg = true, class = .Finite}},
		{"0x3p-16445", "-0x1p-16445", F80{mant = 0x2, exp = -16445, class = .Finite}},
		{"0x1p-16445", "1", F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
		{"1", "-0x1p-16445", F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
		{"-0x1p-16445", "-0x1p-16445", F80{mant = 0x2, exp = -16445, neg = true, class = .Finite}},
		{"0x0.fffffffffffffffep-16382", "0x1p-16445", F80{mant = 0x8000000000000000, exp = -16445, class = .Finite}},
		{"0x0.fffffffffffffffep-16382", "0x1p-16444", F80{mant = 0x8000000000000001, exp = -16445, class = .Finite}},
		{"0x1.fffffffffffffffep16383", "0x1p16319", F80{class = .Inf}},
		{"0x1.fffffffffffffffep16383", "0x1p16320", F80{class = .Inf}},
		{"0x1.fffffffffffffffep16383", "0x1p16318", F80{mant = 0xffffffffffffffff, exp = 16320, class = .Finite}},
		{"0x1.fffffffffffffffep16383", "0x1.8p16318", F80{mant = 0xffffffffffffffff, exp = 16320, class = .Finite}},
		{"0x1p16383", "0x1p16383", F80{class = .Inf}},
		{"0x1.fffffffffffffffep16383", "-0x1p16383", F80{mant = 0xfffffffffffffffe, exp = 16319, class = .Finite}},
		{"-0x1.fffffffffffffffep16383", "-0x1p16320", F80{neg = true, class = .Inf}},
		{"-0x1.fffffffffffffffep16383", "-0x1p16319", F80{neg = true, class = .Inf}},
		{"0x1.fffffffffffffffep16383", "-0x1.fffffffffffffffep16383", F80{class = .Zero}},
		{"0x1p16383", "-0x1.fffffffffffffffep16382", F80{mant = 0x8000000000000000, exp = 16256, class = .Finite}},
		{"inf", "1", F80{class = .Inf}},
		{"1", "-inf", F80{neg = true, class = .Inf}},
		{"inf", "-inf", F80{class = .NaN}},
		{"-inf", "-inf", F80{neg = true, class = .Inf}},
		{"inf", "inf", F80{class = .Inf}},
		{"-inf", "inf", F80{class = .NaN}},
		{"inf", "0", F80{class = .Inf}},
		{"0", "0", F80{class = .Zero}},
		{"-0", "-0", F80{neg = true, class = .Zero}},
		{"-0", "0", F80{class = .Zero}},
		{"0", "-0", F80{class = .Zero}},
		{"1", "-1", F80{class = .Zero}},
		{"-1", "1", F80{class = .Zero}},
		{"0x1p63", "0x1p-1", F80{mant = 0x8000000000000000, exp = 0, class = .Finite}},
		{"0x1p63", "0x1p-2", F80{mant = 0x8000000000000000, exp = 0, class = .Finite}},
		{"0x1p63", "0x1.8p-1", F80{mant = 0x8000000000000001, exp = 0, class = .Finite}},
		{"0x1p64", "0x1p0", F80{mant = 0x8000000000000000, exp = 1, class = .Finite}},
		{"0x1p64", "0x1.8p0", F80{mant = 0x8000000000000001, exp = 1, class = .Finite}},
		{"0x1p64", "0x1p1", F80{mant = 0x8000000000000001, exp = 1, class = .Finite}},
		{"0x1p64", "0x1.8p1", F80{mant = 0x8000000000000002, exp = 1, class = .Finite}},
		{"0x1p64", "-0x1p0", F80{mant = 0xffffffffffffffff, exp = 0, class = .Finite}},
		{"0x1p64", "-0x1p1", F80{mant = 0xfffffffffffffffe, exp = 0, class = .Finite}},
		{"0x1p64", "-0x1.8p0", F80{mant = 0xfffffffffffffffe, exp = 0, class = .Finite}},
		{"-0x1p64", "0x1p0", F80{mant = 0xffffffffffffffff, exp = 0, neg = true, class = .Finite}},
		{"0x1p-64", "1", F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
		{"0x1p-64", "-1", F80{mant = 0xffffffffffffffff, exp = -64, neg = true, class = .Finite}},
		{"1", "0x1p-64", F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
		{"1", "0x1p-65", F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
		{"1", "0x1.8p-65", F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
		{"1", "-0x1p-65", F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
		{"1", "-0x1.8p-65", F80{mant = 0xffffffffffffffff, exp = -64, class = .Finite}},
		{"0x1.00000000000000008p0", "0x1p-100", F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
	}
	for c in cases {
		x, x_ok := parse(transmute([]u8)c.a)
		y, y_ok := parse(transmute([]u8)c.b)
		testing.expectf(t, x_ok && y_ok, "operands %q and %q must parse", c.a, c.b)
		got := add(x, y)
		testing.expectf(t, got == c.value, "%q plus %q gave %v, expected %v", c.a, c.b, got, c.value)
		back := add(y, x)
		testing.expectf(t, back == c.value, "%q plus %q gave %v, expected %v", c.b, c.a, back, c.value)
	}
}

@(test)
integers_convert_exactly :: proc(t: ^testing.T) {
	cases := [?]Integer{
		{0, F80{class = .Zero}},
		{1, F80{mant = 0x8000000000000000, exp = -63, class = .Finite}},
		{-1, F80{mant = 0x8000000000000000, exp = -63, neg = true, class = .Finite}},
		{2, F80{mant = 0x8000000000000000, exp = -62, class = .Finite}},
		{-2, F80{mant = 0x8000000000000000, exp = -62, neg = true, class = .Finite}},
		{3, F80{mant = 0xc000000000000000, exp = -62, class = .Finite}},
		{7, F80{mant = 0xe000000000000000, exp = -61, class = .Finite}},
		{255, F80{mant = 0xff00000000000000, exp = -56, class = .Finite}},
		{256, F80{mant = 0x8000000000000000, exp = -55, class = .Finite}},
		{-256, F80{mant = 0x8000000000000000, exp = -55, neg = true, class = .Finite}},
		{65535, F80{mant = 0xffff000000000000, exp = -48, class = .Finite}},
		{65536, F80{mant = 0x8000000000000000, exp = -47, class = .Finite}},
		{2147483647, F80{mant = 0xfffffffe00000000, exp = -33, class = .Finite}},
		{-2147483648, F80{mant = 0x8000000000000000, exp = -32, neg = true, class = .Finite}},
		{4294967295, F80{mant = 0xffffffff00000000, exp = -32, class = .Finite}},
		{4294967296, F80{mant = 0x8000000000000000, exp = -31, class = .Finite}},
		{9007199254740992, F80{mant = 0x8000000000000000, exp = -10, class = .Finite}},
		{9007199254740993, F80{mant = 0x8000000000000400, exp = -10, class = .Finite}},
		{-9007199254740993, F80{mant = 0x8000000000000400, exp = -10, neg = true, class = .Finite}},
		{4611686018427387904, F80{mant = 0x8000000000000000, exp = -1, class = .Finite}},
		{4611686018427387903, F80{mant = 0xfffffffffffffffc, exp = -2, class = .Finite}},
		{9223372036854775807, F80{mant = 0xfffffffffffffffe, exp = -1, class = .Finite}},
		{-9223372036854775807, F80{mant = 0xfffffffffffffffe, exp = -1, neg = true, class = .Finite}},
		{-9223372036854775808, F80{mant = 0x8000000000000000, exp = 0, neg = true, class = .Finite}},
		{1234567890123456789, F80{mant = 0x891087a3ef4c08a8, exp = -3, class = .Finite}},
		{-1234567890123456789, F80{mant = 0x891087a3ef4c08a8, exp = -3, neg = true, class = .Finite}},
		{1000000000000000000, F80{mant = 0xde0b6b3a76400000, exp = -4, class = .Finite}},
		{999999999999999999, F80{mant = 0xde0b6b3a763ffff0, exp = -4, class = .Finite}},
	}
	for c in cases {
		got := from_i64(c.value)
		testing.expectf(t, got == c.expected, "from_i64(%d) gave %v, expected %v", c.value, got, c.expected)
	}
}

@(test)
integers_format_as_their_decimal_digits :: proc(t: ^testing.T) {
	values := [?]i64{0, 1, -1, 9, 10, -10, 4294967296, 9007199254740993, -9007199254740993, 1234567890123456789, 9223372036854775807, -9223372036854775807, -9223372036854775808}
	buf: [MAX_LONG_DOUBLE_CHARS]u8
	digits: [32]u8
	for v in values {
		n := format_human(from_i64(v), buf[:])
		want := strconv.write_int(digits[:], v, 10)
		testing.expectf(t, string(buf[:n]) == want, "from_i64(%d) formatted as %q", v, string(buf[:n]))
	}
}

@(test)
special_values_are_classified :: proc(t: ^testing.T) {
	testing.expect(t, is_finite(zero(false)) && !is_inf(zero(false)) && !is_nan(zero(false)))
	testing.expect(t, is_finite(zero(true)) && zero(true).neg)
	testing.expect(t, is_inf(infinity(false)) && !is_finite(infinity(false)) && !is_nan(infinity(false)))
	testing.expect(t, is_inf(infinity(true)) && infinity(true).neg)
	testing.expect(t, is_nan(nan()) && !is_finite(nan()) && !is_inf(nan()))
	testing.expect(t, is_finite(from_i64(5)) && !is_inf(from_i64(5)) && !is_nan(from_i64(5)))
	testing.expect(t, is_nan(add(infinity(false), infinity(true))))
	testing.expect(t, is_nan(add(nan(), from_i64(1))))
	testing.expect(t, is_nan(add(from_i64(1), nan())))
	testing.expect(t, is_inf(add(infinity(true), from_i64(1))))
}

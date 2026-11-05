package zsettype

F64_INF :: f64(0h7FF0_0000_0000_0000)

F64_NEG_INF :: f64(0hFFF0_0000_0000_0000)

F64_NAN :: f64(0h7FF8_0000_0000_0000)

foreign import numeric_libc "system:c"

foreign numeric_libc {
	@(link_name = "strtod_l")
	c_strtod_l :: proc "c" (s: cstring, end: ^[^]u8, locale: rawptr) -> f64 ---
	@(link_name = "newlocale")
	c_newlocale :: proc "c" (mask: i32, name: cstring, base: rawptr) -> rawptr ---
	@(link_name = "freelocale")
	c_freelocale :: proc "c" (locale: rawptr) ---
	@(link_name = "uselocale")
	c_uselocale :: proc "c" (locale: rawptr) -> rawptr ---
	@(link_name = "__errno_location")
	c_errno :: proc "c" () -> ^i32 ---
	@(link_name = "snprintf")
	c_snprintf :: proc "c" (dst: [^]u8, n: uintptr, format: cstring, #c_vararg args: ..any) -> i32 ---
}

eq_nocase :: proc "contextless" (a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for c, i in a {
		value := c
		if value >= 'A' && value <= 'Z' {
			value += 'a' - 'A'
		}
		expected := b[i]
		if expected >= 'A' && expected <= 'Z' {
			expected += 'a' - 'A'
		}
		if value != expected {
			return false
		}
	}
	return true
}

is_nan :: proc "contextless" (v: f64) -> bool {
	return v != v
}

is_inf :: proc "contextless" (v: f64) -> bool {
	return (transmute(u64)v & 0x7fff_ffff_ffff_ffff) == 0x7ff0_0000_0000_0000
}

strtod :: proc "contextless" (s: []u8) -> (v: f64, consumed: int, erange: bool) {
	if len(s) == 0 || len(s) == max(int) {
		return
	}
	p := mem_alloc(len(s) + 1)
	copy(p[:len(s)], s)
	p[len(s)] = 0
	locale := c_newlocale(2, "C", nil)
	resize_require(locale != nil)
	end: [^]u8
	c_errno()^ = 0
	v = c_strtod_l(cast(cstring)p, &end, locale)
	err := c_errno()^
	consumed = int(uintptr(end) - uintptr(p))
	c_freelocale(locale)
	mem_free(p)
	if is_nan(v) {
		v = F64_NAN
	}
	erange = err == 34 && (v == 0 || is_inf(v))
	return
}

parse_score :: proc "contextless" (s: []u8) -> (f64, bool) {
	if len(s) == 0 || s[0] == ' ' || s[0] >= 9 && s[0] <= 13 {
		return 0, false
	}
	v, consumed, erange := strtod(s)
	if consumed != len(s) || erange || is_nan(v) {
		return 0, false
	}
	return v, true
}

score_from_lp_string :: proc "contextless" (s: []u8) -> f64 {
	v, _, _ := strtod(s[:min(len(s), 127)])
	return v
}

double2ll :: proc "contextless" (d: f64) -> (i64, bool) {
	if is_nan(d) || d < -4611686018427387904 || d > 4611686018427387904 {
		return 0, false
	}
	n := i64(d)
	if f64(n) != d {
		return 0, false
	}
	return n, true
}

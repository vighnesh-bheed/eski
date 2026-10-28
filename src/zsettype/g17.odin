package zsettype

G17_MAX :: 32

format_g17 :: proc "contextless" (dst: []u8, v: f64) -> int {
	if is_nan(v) {
		copy(dst, []u8{'n', 'a', 'n'})
		dst[3] = 0
		return 3
	}
	locale := c_newlocale(2, "C", nil)
	resize_require(locale != nil)
	previous := c_uselocale(locale)
	n := c_snprintf(raw_data(dst), uintptr(len(dst)), "%.17g", v)
	_ = c_uselocale(previous)
	c_freelocale(locale)
	return int(n)
}

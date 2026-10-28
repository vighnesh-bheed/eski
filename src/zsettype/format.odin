package zsettype

import fc "../fpconv"

D2STRING_MAX :: fc.DOUBLE_STR_MAX

d2string :: proc "contextless" (dst: []u8, v: f64) -> int {
	return fc.format_double(dst, v)
}

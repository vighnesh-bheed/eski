package lua_runtime

import "core:c"
import fpconv "../fpconv"

number_text :: proc "c" (value: f64, argument: i32, out: [^]u8, capacity: c.size_t) -> c.size_t {
	if out == nil || capacity < c.size_t(fpconv.DOUBLE_STR_MAX) {
		return 0
	}
	buffer := out[:int(capacity)]
	bits := transmute(u64)value
	if argument != 0 {
		if bits & 0x7FFF_FFFF_FFFF_FFFF > 0x7FF0_0000_0000_0000 {
			text := "-nan" if bits >> 63 != 0 else "nan"
			copy(buffer, text)
			return c.size_t(len(text))
		}
		if value == 0 {
			buffer[0] = '0'
			return 1
		}
	}
	return c.size_t(fpconv.format_double(buffer, value))
}

@(init)
install_number_text :: proc "contextless" () {
	set_number_format(number_text)
}

package jsondoc

import "core:math"
import "core:strconv"

Float_Format :: enum u8 {
	Normal, FP16, BF16, FP32, FP64,
}

round_narrow :: proc(value: f64, format: Float_Format) -> f64 {
	switch format {
	case .FP16:
		return f64(f16(value))
	case .FP32:
		return f64(f32(value))
	case .BF16:
		raw := transmute(u32)f32(value)
		rounded := (raw + 0x7fff + ((raw >> 16) & 1)) & 0xffff0000
		return f64(transmute(f32)rounded)
	case .Normal, .FP64:
		return value
	}
	return value
}

narrow_array_number :: proc(p: ^Parser, value: ^Value) -> bool {
	if p.narrow == .Normal {
		return true
	}
	n, ok := number(value)
	if !ok {
		return true
	}
	if p.narrow == .FP16 && abs(n) > 65504.0 || p.narrow == .FP32 && abs(n) > f64(max(f32)) || p.narrow == .BF16 && abs(n) > f64(transmute(f32)u32(0x7f7f0000)) {
		label := "F16" if p.narrow == .FP16 else ("F32" if p.narrow == .FP32 else "BF16")
		switch label {
		case "F16": fail_next(p, "value out of range for F16")
		case "F32": fail_next(p, "value out of range for F32")
		case: fail_next(p, "value out of range for BF16")
		}
		return false
	}
	set_scalar(value, round_narrow(n, p.narrow))
	value.narrow = p.narrow
	return true
}

narrow_double :: proc(dst: []u8, value: f64, format: Float_Format) -> string {
	if format == .Normal || format == .FP64 || value == math.trunc(value) {
		return json_double(dst, value)
	}
	if format == .FP32 {
		return json_double(dst, value, 32)
	}
	buf: [32]u8
	for p in 0 ..= 6 {
		text := strconv.write_float(buf[:], value, 'e', p, 64)
		n, ok := strconv.parse_f64(text)
		if ok && round_narrow(n, format) == value {
			return json_double(dst, value, 64, p)
		}
	}
	return json_double(dst, value)
}

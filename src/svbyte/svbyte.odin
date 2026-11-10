package svbyte

control_bytes :: #force_inline proc "contextless" (n: int) -> int {
	return (n + 3) >> 2
}

max_encoded :: #force_inline proc "contextless" (n: int) -> int {
	return control_bytes(n) + 4 * n
}

value_length :: #force_inline proc "contextless" (v: u32) -> int {
	return 1 + int(v > 0xFF) + int(v > 0xFFFF) + int(v > 0xFF_FFFF)
}

code_length :: #force_inline proc "contextless" (control: []u8, i: int) -> int #no_bounds_check {
	return int(control[i >> 2] >> (uint(i & 3) * 2) & 3) + 1
}

put_value :: #force_inline proc "contextless" (out: []u8, pos: int, v: u32, length: int) #no_bounds_check {
	out[pos] = u8(v)
	if length > 1 {
		out[pos + 1] = u8(v >> 8)
	}
	if length > 2 {
		out[pos + 2] = u8(v >> 16)
	}
	if length > 3 {
		out[pos + 3] = u8(v >> 24)
	}
}

get_value :: #force_inline proc "contextless" (data: []u8, pos: int, length: int) -> u32 #no_bounds_check {
	v := u32(data[pos])
	if length > 1 {
		v |= u32(data[pos + 1]) << 8
	}
	if length > 2 {
		v |= u32(data[pos + 2]) << 16
	}
	if length > 3 {
		v |= u32(data[pos + 3]) << 24
	}
	return v
}

encoded_length :: proc "contextless" (data: []u8, n: int) -> int #no_bounds_check {
	cb := control_bytes(n)
	if len(data) < cb {
		return -1
	}
	total := cb
	full := n >> 2
	for g in 0 ..< full {
		total += int(LENGTH[data[g]])
	}
	for i in full << 2 ..< n {
		total += code_length(data, i)
	}
	return total
}

encode :: proc "contextless" (values: []u32, out: []u8) -> int #no_bounds_check {
	n := len(values)
	cb := control_bytes(n)
	for i in 0 ..< cb {
		out[i] = 0
	}
	pos := cb
	for i in 0 ..< n {
		v := values[i]
		length := value_length(v)
		out[i >> 2] |= u8(length - 1) << (uint(i & 3) * 2)
		put_value(out, pos, v, length)
		pos += length
	}
	return pos
}

encode_delta :: proc "contextless" (values: []u32, previous: u32, out: []u8) -> int #no_bounds_check {
	n := len(values)
	cb := control_bytes(n)
	for i in 0 ..< cb {
		out[i] = 0
	}
	pos := cb
	prev := previous
	for i in 0 ..< n {
		v := values[i] - prev
		prev = values[i]
		length := value_length(v)
		out[i >> 2] |= u8(length - 1) << (uint(i & 3) * 2)
		put_value(out, pos, v, length)
		pos += length
	}
	return pos
}

decode_reference :: proc "contextless" (data: []u8, out: []u32) -> int #no_bounds_check {
	n := len(out)
	pos := control_bytes(n)
	for i in 0 ..< n {
		length := code_length(data, i)
		out[i] = get_value(data, pos, length)
		pos += length
	}
	return pos
}

decode_delta_reference :: proc "contextless" (data: []u8, out: []u32, previous: u32) -> int #no_bounds_check {
	n := len(out)
	pos := control_bytes(n)
	prev := previous
	for i in 0 ..< n {
		length := code_length(data, i)
		prev += get_value(data, pos, length)
		out[i] = prev
		pos += length
	}
	return pos
}

decode_tail :: proc "contextless" (data: []u8, out: []u32, from: int, pos: int, delta: bool, previous: u32) -> int #no_bounds_check {
	p := pos
	prev := previous
	for i in from ..< len(out) {
		length := code_length(data, i)
		v := get_value(data, p, length)
		if delta {
			prev += v
			v = prev
		}
		out[i] = v
		p += length
	}
	return p
}

decode :: proc "contextless" (data: []u8, out: []u32) -> int {
	return kernels.decode(data, out)
}

decode_delta :: proc "contextless" (data: []u8, out: []u32, previous: u32) -> int {
	return kernels.decode_delta(data, out, previous)
}

skip :: proc "contextless" (data: []u8, n: int) -> int {
	return encoded_length(data, n)
}

Writer :: struct {
	out:   []u8,
	pos:   int,
	count: int,
}

writer_init :: proc "contextless" (w: ^Writer, out: []u8, n: int) #no_bounds_check {
	cb := control_bytes(n)
	for i in 0 ..< cb {
		out[i] = 0
	}
	w^ = Writer{out = out, pos = cb}
}

writer_put :: #force_inline proc "contextless" (w: ^Writer, v: u32) #no_bounds_check {
	length := value_length(v)
	w.out[w.count >> 2] |= u8(length - 1) << (uint(w.count & 3) * 2)
	put_value(w.out, w.pos, v, length)
	w.pos += length
	w.count += 1
}

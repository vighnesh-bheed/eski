package hyperloglog_test

import "core:fmt"
import hll "../../src/hll"

hex_decode :: proc(s: string, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(s) / 2, allocator)
	nibble :: proc(c: u8) -> u8 {
		switch c {
		case '0' ..= '9':
			return c - '0'
		case 'a' ..= 'f':
			return c - 'a' + 10
		case 'A' ..= 'F':
			return c - 'A' + 10
		}
		return 0
	}
	for i in 0 ..< len(out) {
		out[i] = nibble(s[2 * i]) << 4 | nibble(s[2 * i + 1])
	}
	return out
}

hex_encode :: proc(b: []u8, allocator := context.allocator) -> string {
	digits := "0123456789abcdef"
	out := make([]u8, 2 * len(b), allocator)
	for v, i in b {
		out[2 * i] = digits[v >> 4]
		out[2 * i + 1] = digits[v & 15]
	}
	return string(out)
}

decode_string :: proc(buf: []u8, allocator := context.allocator) -> string {
	out := make([dynamic]u8, 0, 64, allocator)
	hll.sparse_debug_append(buf, &out)
	return string(out[:])
}

dyn_from :: proc(src: []u8) -> [dynamic]u8 {
	d := make([dynamic]u8, len(src))
	copy(d[:], src)
	return d
}

dyn_from_hex :: proc(s: string) -> [dynamic]u8 {
	raw := hex_decode(s)
	defer delete(raw)
	return dyn_from(raw)
}

elem_name :: proc(buf: []u8, prefix: string, n: int) -> []u8 {
	s := fmt.bprintf(buf, "%s%d", prefix, n)
	return transmute([]u8)s
}

model_run :: proc(m: ^Model, args: ..string) -> string {
	argv := make([][]u8, len(args))
	defer delete(argv)
	for a, i in args {
		argv[i] = transmute([]u8)a
	}
	model_exec(m, argv)
	return string(m.out[:])
}

main :: proc() {
}

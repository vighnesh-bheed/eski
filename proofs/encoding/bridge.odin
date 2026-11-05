package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import lp "../../src/listpack"
import rp "../../src/request_parser"

number :: proc(s: string) -> i64 {
	value, ok := strconv.parse_i64(s, 10)
	assert(ok)
	return value
}

unsigned :: proc(s: string) -> u64 {
	value, ok := strconv.parse_u64(s, 10)
	assert(ok)
	return value
}

bytes_field :: proc(s: string) -> []u8 {
	if s == "-" || s == "~" { return nil }
	parts := strings.split(s, ",")
	defer delete(parts)
	data := make([]u8, len(parts))
	for part, i in parts {
		value := number(part)
		assert(value >= 0 && value <= 255)
		data[i] = u8(value)
	}
	return data
}

show_bytes :: proc(data: []u8, empty := "-") {
	if len(data) == 0 { fmt.print(empty); return }
	for byte, i in data {
		if i > 0 { fmt.print(",") }
		fmt.printf("%d", byte)
	}
}

show_body :: proc(data: []u8, offset: int) {
	body, ok := lp.decode_body(data, offset)
	if !ok { fmt.print("0|0|0|-"); return }
	fmt.printf("1|%d|%d|", body.bytes, body.value)
	if body.is_string {
		show_bytes(data[body.string_offset:body.string_offset + body.string_length], "~")
	} else { fmt.print("n") }
}

show_extent :: proc(body: []u8) {
	data := make([]u8, len(body) + lp.backlen_width(u64(len(body))))
	defer delete(data)
	copy(data, body)
	assert(lp.lp_encode_backlen(raw_data(data[len(body):]), u64(len(body))) == u64(len(data) - len(body)))
	extent, ok := lp.decode_entry_extent(data, 0, len(data))
	if ok { fmt.printf("%d", extent.end) } else { fmt.print("0") }
}

show_result :: proc(result: rp.Result, scratch: ^rp.Scratch) {
	fmt.printf("%d,%d,%d,%d,%d,%d:", u8(result.kind), u8(result.fault), result.consumed, result.need, result.payload, result.error_byte)
	if result.kind != .Command || result.argc == 0 { fmt.print("-"); return }
	for i in 0..<result.argc {
		if i > 0 { fmt.print("/") }
		show_bytes(scratch.args[i], "~")
	}
}

equal_results :: proc(a, b: rp.Result, sa, sb: ^rp.Scratch) {
	assert(a.kind == b.kind && a.fault == b.fault && a.consumed == b.consumed && a.need == b.need && a.payload == b.payload && a.argc == b.argc && a.error_byte == b.error_byte)
	if a.kind == .Command {
		for i in 0..<a.argc { assert(string(sa.args[i]) == string(sb.args[i])) }
	}
}

show_pack :: proc(data: []u8) {
	pointer := raw_data(data)
	shallow := lp.lp_validate_integrity(pointer, u64(len(data)), false, nil, nil)
	deep := lp.lp_validate_integrity(pointer, u64(len(data)), true, nil, nil)
	fmt.printf("L|%d|%d|", int(shallow), int(deep))
	if !deep { fmt.print("0|-|-"); return }
	count := lp.lp_length(pointer)
	fmt.printf("%d|", count)
	cursor := lp.lp_first(pointer)
	visited := 0
	for cursor != nil {
		assert(visited <= len(data))
		if visited > 0 { fmt.print(",") }
		fmt.printf("%d", lp.pdiff(cursor, pointer))
		cursor = lp.lp_next(pointer, cursor)
		visited += 1
	}
	assert(u64(visited) == count)
	if visited == 0 { fmt.print("-") }
	fmt.print("|")
	cursor = lp.lp_last(pointer)
	visited = 0
	for cursor != nil {
		assert(visited <= len(data))
		if visited > 0 { fmt.print(",") }
		fmt.printf("%d", lp.pdiff(cursor, pointer))
		cursor = lp.lp_prev(pointer, cursor)
		visited += 1
	}
	assert(u64(visited) == count)
	if visited == 0 { fmt.print("-") }
}

main :: proc() {
	assert(size_of(int) == 8 && len(os.args) == 2)
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(input)
	lines := strings.split(string(input), "\n")
	defer delete(lines)
	for line in lines {
		if len(line) == 0 { continue }
		fields := strings.split(line, " ")
		defer delete(fields)
		switch fields[0] {
		case "G":
			finish, ok := rp.bulk_required_end(int(number(fields[1])), int(number(fields[2])), number(fields[3]))
			fmt.printf("G|%d|%d", int(ok), finish)
		case "I":
			data: [9]u8
			length, ok := lp.write_integer(data[:], number(fields[1]))
			assert(ok)
			fmt.printf("I|%d|", length)
			show_bytes(data[:length])
			fmt.print("|")
			show_body(data[:length], 0)
			fmt.print("|")
			show_extent(data[:length])
		case "S":
			value := bytes_field(fields[1])
			defer delete(value)
			data := make([]u8, len(value) + 5)
			defer delete(data)
			length, ok := lp.write_string(data, value)
			assert(ok)
			fmt.printf("S|%d|", length)
			show_bytes(data[:length])
			fmt.print("|")
			show_body(data[:length], 0)
			fmt.print("|")
			show_extent(data[:length])
		case "B":
			data: [5]u8
			width := int(lp.lp_encode_backlen(raw_data(data[:]), unsigned(fields[1])))
			fmt.printf("B|%d|", width)
			show_bytes(data[:width])
			value, decoded, ok := u64(0), 0, false
			if width > 0 { value, decoded, ok = lp.read_backlen(data[:width], width - 1, 0) }
			fmt.printf("|%d|%d|%d", value, decoded, int(ok))
		case "R":
			data := bytes_field(fields[1])
			defer delete(data)
			value, width, ok := lp.read_backlen(data, int(number(fields[2])), int(number(fields[3])))
			if ok { fmt.printf("R|1|%d|%d", value, width) } else { fmt.print("R|0|0|0") }
		case "D":
			data := bytes_field(fields[1])
			defer delete(data)
			fmt.print("D|")
			show_body(data, int(number(fields[2])))
		case "L":
			data := bytes_field(fields[1])
			defer delete(data)
			show_pack(data)
		case "P":
			assert(len(fields) == 8)
			limits := rp.Limits{base_offset = int(number(fields[1])), bulk_max = number(fields[2]), unauthenticated = fields[3] == "1", unauth_array_max = number(fields[4]), unauth_bulk_max = number(fields[5])}
			data := bytes_field(fields[6])
			defer delete(data)
			sizes := strings.split(fields[7], ",")
			defer delete(sizes)
			fast, slow: rp.Scratch
			defer rp.destroy(&fast)
			defer rp.destroy(&slow)
			assert(rp.ensure_args(&fast, 64))
			cursor := 0
			fmt.print("P|")
			for size, i in sizes {
				if i > 0 { fmt.print(";") }
				cursor += int(number(size))
				assert(cursor <= len(data))
				a := rp.parse_array(data[:cursor], &fast, limits)
				b := rp.parse_array_slow(data[:cursor], &slow, limits)
				equal_results(a, b, &fast, &slow)
				show_result(a, &fast)
			}
			assert(cursor == len(data))
		case:
			panic("invalid trace")
		}
		fmt.println()
	}
}

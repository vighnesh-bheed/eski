package request_parser

import "core:testing"

append_number :: proc(output: ^[dynamic]u8, value: int) {
	storage: [20]u8
	position := len(storage)
	remaining := value
	for {
		position -= 1
		storage[position] = u8(remaining % 10) + '0'
		remaining /= 10
		if remaining == 0 {
			break
		}
	}
	for byte in storage[position:] {
		append(output, byte)
	}
}

encode_array :: proc(args: [][]u8) -> [dynamic]u8 {
	output: [dynamic]u8
	append(&output, '*')
	append_number(&output, len(args))
	append(&output, '\r', '\n')
	for argument in args {
		append(&output, '$')
		append_number(&output, len(argument))
		append(&output, '\r', '\n')
		for byte in argument {
			append(&output, byte)
		}
		append(&output, '\r', '\n')
	}
	return output
}

expect_equal :: proc(t: ^testing.T, first, second: []u8) {
	testing.expect(t, len(first) == len(second))
	if len(first) == len(second) {
		for byte, index in first {
			testing.expect(t, byte == second[index])
		}
	}
}

@(test)
canonical_frames_all_fragment_boundaries :: proc(t: ^testing.T) {
	binary: [256]u8
	for index in 0..<len(binary) {
		binary[index] = u8(index)
	}
	fixtures := [][][]u8{
		{},
		{transmute([]u8)string("PING")},
		{transmute([]u8)string("SET"), transmute([]u8)string("key"), {}},
		{transmute([]u8)string("SET"), binary[:], transmute([]u8)string("a\x00b\r\nc\xff")},
	}
	scratch: Scratch
	defer destroy(&scratch)
	for arguments in fixtures {
		wire := encode_array(arguments)
		defer delete(wire)
		snapshot := make([]u8, len(wire))
		defer delete(snapshot)
		copy(snapshot, wire[:])
		for split in 0..<len(wire) {
			partial := parse_array(wire[:split], &scratch, Limits{bulk_max = 1048576, unauth_array_max = 10, unauth_bulk_max = 16384})
			testing.expect(t, partial.kind == .Incomplete)
			testing.expect(t, partial.consumed == 0 && partial.argc == 0)
			testing.expect(t, partial.need > split)
			expect_equal(t, wire[:], snapshot)
		}
		for _ in 0..<2 {
			complete := parse_array(wire[:], &scratch, Limits{bulk_max = 1048576, unauth_array_max = 10, unauth_bulk_max = 16384})
			testing.expect(t, complete.kind == .Command)
			testing.expect(t, complete.consumed == len(wire) && complete.argc == len(arguments))
			for argument, index in arguments {
				expect_equal(t, scratch.args[index], argument)
			}
			expect_equal(t, wire[:], snapshot)
		}
	}
}

@(test)
pipeline_offset_scratch_growth_and_reuse :: proc(t: ^testing.T) {
	arguments := make([][]u8, 130)
	defer delete(arguments)
	for index in 0..<len(arguments) {
		arguments[index] = transmute([]u8)string("payload")
	}
	first := encode_array(arguments)
	defer delete(first)
	second_args := [][]u8{transmute([]u8)string("PING")}
	second := encode_array(second_args)
	defer delete(second)
	wire: [dynamic]u8
	defer delete(wire)
	append(&wire, 0, 255, 0)
	for byte in first {
		append(&wire, byte)
	}
	for byte in second {
		append(&wire, byte)
	}
	scratch: Scratch
	defer destroy(&scratch)
	parsed := parse_array(wire[3:], &scratch, Limits{bulk_max = 1048576, unauth_array_max = 10, unauth_bulk_max = 16384})
	testing.expect(t, parsed.kind == .Command && parsed.argc == 130 && parsed.consumed == len(first))
	testing.expect(t, len(scratch.args) >= 130)
	for argument, index in arguments {
		expect_equal(t, scratch.args[index], argument)
	}
	storage := raw_data(scratch.args)
	capacity := len(scratch.args)
	parsed = parse_array(wire[3 + len(first):], &scratch, Limits{bulk_max = 1048576, unauth_array_max = 10, unauth_bulk_max = 16384})
	testing.expect(t, parsed.kind == .Command && parsed.argc == 1 && parsed.consumed == len(second))
	testing.expect(t, raw_data(scratch.args) == storage && len(scratch.args) == capacity)
	expect_equal(t, scratch.args[0], second_args[0])
	scratch.args[0] = arguments[0]
	parsed = parse_array(wire[3:], &scratch, Limits{bulk_max = 1048576, unauth_array_max = 10, unauth_bulk_max = 16384})
	testing.expect(t, parsed.kind == .Command && raw_data(scratch.args) == storage)
	fresh: Scratch
	defer destroy(&fresh)
	partial := parse_array(transmute([]u8)string("*1000000000\r\n"), &fresh, Limits{bulk_max = 1048576, unauth_array_max = 10, unauth_bulk_max = 16384})
	testing.expect(t, partial.kind != .Command && len(fresh.args) == 0)
}

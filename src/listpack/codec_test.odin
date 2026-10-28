package listpack

import "core:testing"

@(test)
integer_body_literals_and_every_truncation :: proc(t: ^testing.T) {
	Fixture :: struct {
		wire: []u8,
		value: i64,
	}
	fixtures := []Fixture{
		{{0}, 0},
		{{127}, 127},
		{{192, 128}, 128},
		{{207, 255}, 4095},
		{{208, 0}, -4096},
		{{223, 255}, -1},
		{{241, 0, 128}, -32768},
		{{241, 255, 127}, 32767},
		{{242, 0, 0, 128}, -8388608},
		{{242, 255, 255, 127}, 8388607},
		{{243, 0, 0, 0, 128}, -2147483648},
		{{243, 255, 255, 255, 127}, 2147483647},
		{{244, 0, 0, 0, 0, 0, 0, 0, 128}, min(i64)},
		{{244, 255, 255, 255, 255, 255, 255, 255, 127}, max(i64)},
	}
	storage: [32]u8
	offsets := []int{0, 1, 3, 7}
	for fixture in fixtures {
		for offset in offsets {
			for index in 0..<len(storage) {
				storage[index] = 165
			}
			copy(storage[offset:], fixture.wire)
			for length in 0..<len(fixture.wire) {
				_, valid := decode_body(storage[:offset + length], offset)
				testing.expect(t, !valid)
			}
			body, valid := decode_body(storage[:offset + len(fixture.wire)], offset)
			testing.expect(t, valid && !body.is_string && body.bytes == len(fixture.wire) && body.value == fixture.value)
			testing.expect(t, storage[offset + len(fixture.wire)] == 165)
			if offset > 0 {
				testing.expect(t, storage[offset - 1] == 165)
			}
		}
	}
}

@(test)
string_body_layout_lengths_binary_and_truncation :: proc(t: ^testing.T) {
	Fixture :: struct {
		header: []u8,
		length: int,
	}
	fixtures := []Fixture{
		{{128}, 0},
		{{131}, 3},
		{{191}, 63},
		{{224, 64}, 64},
		{{239, 255}, 4095},
		{{240, 0, 16, 0, 0}, 4096},
	}
	for fixture in fixtures {
		wire := make([]u8, 3 + len(fixture.header) + fixture.length)
		defer delete(wire)
		copy(wire[3:], fixture.header)
		for index in 0..<fixture.length {
			wire[3 + len(fixture.header) + index] = u8(index % 256)
		}
		for length in 0..<len(wire) - 3 {
			_, valid := decode_body(wire[:3 + length], 3)
			testing.expect(t, !valid)
		}
		body, valid := decode_body(wire, 3)
		testing.expect(t, valid && body.is_string && body.bytes == len(wire) - 3)
		testing.expect(t, body.string_offset == 3 + len(fixture.header) && body.string_length == fixture.length)
		for index in 0..<body.string_length {
			testing.expect(t, wire[body.string_offset + index] == u8(index % 256))
		}
	}
	announced := [5]u8{240, 255, 255, 255, 255}
	_, valid := decode_body(announced[:], 0)
	testing.expect(t, !valid)
	for tag in 245..<256 {
		wire := [1]u8{u8(tag)}
		_, valid = decode_body(wire[:], 0)
		testing.expect(t, !valid)
	}
}

@(test)
header_wire_is_six_bytes_and_size_is_bounded :: proc(t: ^testing.T) {
	wire := [8]u8{7, 0, 0, 0, 255, 255, 255, 165}
	for length in 0..<7 {
		_, valid := decode_header(wire[:length])
		testing.expect(t, !valid)
	}
	header, valid := decode_header(wire[:])
	testing.expect(t, valid && header.bytes == 7 && header.count == 65535)
	for invalid in 0..<7 {
		wire[0] = u8(invalid)
		_, valid = decode_header(wire[:])
		testing.expect(t, !valid)
	}
	wire[0] = 7
	wire[6] = 0
	_, valid = decode_header(wire[:])
	testing.expect(t, !valid)
	for index in 0..<4 {
		wire[index] = 255
	}
	wire[6] = 255
	_, valid = decode_header(wire[:])
	testing.expect(t, !valid)
	_, valid = read_unsigned(wire[:], -1, 1)
	testing.expect(t, !valid)
	_, valid = read_unsigned(wire[:], max(int), 4)
	testing.expect(t, !valid)
}

@(test)
entry_selectors_and_signed_decimal_boundaries :: proc(t: ^testing.T) {
	Fixture :: struct {
		value: i64,
		decimal: string,
	}
	fixtures := []Fixture{
		{0, "0"},
		{127, "127"},
		{-1, "-1"},
		{4096, "4096"},
		{-32768, "-32768"},
		{max(i64), "9223372036854775807"},
		{min(i64), "-9223372036854775808"},
	}
	for fixture in fixtures {
		storage: [LP_INTBUF_SIZE + 2]u8
		for index in 0..<len(storage) {
			storage[index] = 238
		}
		storage[0], storage[len(storage) - 1] = 165, 165
		length := ll2string(raw_data(storage[1:]), fixture.value)
		testing.expect(t, length == len(fixture.decimal) && storage[length + 1] == 238)
		testing.expect(t, storage[0] == 165 && storage[len(storage) - 1] == 165)
		testing.expect(t, string(storage[1:length + 1]) == fixture.decimal && sdigits10(fixture.value) == u32(length))
		value := i64(123)
		testing.expect(t, lp_string_to_int64(storage[1:length + 1], &value) && value == fixture.value)
		buffer: [LP_INTBUF_SIZE]u8
		entry := entry_from_int(fixture.value)
		testing.expect(t, entry.sval == nil && string(entry_bytes(entry, &buffer)) == fixture.decimal)
	}
	invalid := []string{"", "+1", "01", "-0", "-01", " 1", "1 ", "9223372036854775808", "-9223372036854775809"}
	for text in invalid {
		value := i64(123)
		testing.expect(t, !lp_string_to_int64(transmute([]u8)text, &value) && value == 123)
	}
	buffer: [LP_INTBUF_SIZE]u8
	empty := entry_from_bytes(nil)
	testing.expect(t, empty.sval != nil && empty.slen == 0 && len(entry_bytes(empty, &buffer)) == 0)
	binary := [3]u8{0, 128, 255}
	entry := entry_from_bytes(binary[:])
	testing.expect(t, entry.sval == raw_data(binary[:]) && entry.slen == 3)
}

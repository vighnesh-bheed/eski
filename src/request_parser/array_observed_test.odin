package request_parser

import "core:testing"

normal_limits :: proc() -> Limits {
	return {bulk_max = 536870912, unauth_array_max = 10, unauth_bulk_max = 16384}
}

header_frame :: proc(prefix, field: string) -> [dynamic]u8 {
	output: [dynamic]u8
	for byte in transmute([]u8)prefix {
		append(&output, byte)
	}
	for byte in transmute([]u8)field {
		append(&output, byte)
	}
	append(&output, '\r', '\n')
	return output
}

@(test)
observed_count_grammar_limits_and_auth_priority :: proc(t: ^testing.T) {
	cases := []struct {
		field: string,
		normal, auth: Kind,
		fault, auth_fault: Fault,
	}{
		{"0", .Command, .Command, .None, .None},
		{"-1", .Command, .Command, .None, .None},
		{"-2", .Command, .Command, .None, .None},
		{"-9223372036854775808", .Command, .Command, .None, .None},
		{"1", .Incomplete, .Incomplete, .None, .None},
		{"10", .Incomplete, .Incomplete, .None, .None},
		{"11", .Incomplete, .Error, .None, .Unauthenticated_Array_Length},
		{"2147483647", .Incomplete, .Error, .None, .Unauthenticated_Array_Length},
		{"2147483648", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{"9223372036854775807", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{"9223372036854775808", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{"-9223372036854775809", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{"+1", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{"00", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{"01", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{"-0", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{"", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{" 1", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
		{"1 ", .Error, .Error, .Invalid_Array_Length, .Invalid_Array_Length},
	}
	for fixture in cases {
		wire := header_frame("*", fixture.field)
		defer delete(wire)
		for auth in 0..<2 {
			scratch: Scratch
			defer destroy(&scratch)
			limits := normal_limits()
			limits.unauthenticated = auth == 1
			actual := parse_array(wire[:], &scratch, limits)
			expected := fixture.normal if auth == 0 else fixture.auth
			fault := fixture.fault if auth == 0 else fixture.auth_fault
			testing.expect(t, actual.kind == expected && actual.fault == fault)
			testing.expect(t, len(scratch.args) == 0)
			if expected == .Command {
				testing.expect(t, actual.argc == 0 && actual.consumed == len(wire))
			} else {
				testing.expect(t, actual.consumed == 0 && actual.argc == 0)
			}
		}
	}
}

@(test)
observed_bulk_grammar_limits_and_auth_priority :: proc(t: ^testing.T) {
	cases := []struct {
		field: string,
		normal, auth: Kind,
		fault, auth_fault: Fault,
		length: int,
	}{
		{"0", .Incomplete, .Incomplete, .None, .None, 0},
		{"4", .Incomplete, .Incomplete, .None, .None, 4},
		{"16384", .Incomplete, .Incomplete, .None, .None, 16384},
		{"16385", .Incomplete, .Error, .None, .Unauthenticated_Bulk_Length, 16385},
		{"536870912", .Incomplete, .Error, .None, .Unauthenticated_Bulk_Length, 536870912},
		{"536870913", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"-1", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"-2", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"+4", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"04", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"00", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"-0", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"9223372036854775807", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"9223372036854775808", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{" 4", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
		{"4 ", .Error, .Error, .Invalid_Bulk_Length, .Invalid_Bulk_Length, 0},
	}
	for fixture in cases {
		wire := header_frame("*1\r\n$", fixture.field)
		defer delete(wire)
		for auth in 0..<2 {
			scratch: Scratch
			defer destroy(&scratch)
			limits := normal_limits()
			limits.unauthenticated = auth == 1
			actual := parse_array(wire[:], &scratch, limits)
			expected := fixture.normal if auth == 0 else fixture.auth
			fault := fixture.fault if auth == 0 else fixture.auth_fault
			testing.expect(t, actual.kind == expected && actual.fault == fault)
			testing.expect(t, actual.consumed == 0 && actual.argc == 0 && len(scratch.args) == 0)
			if expected == .Incomplete {
				testing.expect(t, actual.need == len(wire) + fixture.length + 2)
			}
		}
	}
	limits := normal_limits()
	limits.bulk_max = 1048576
	scratch: Scratch
	defer destroy(&scratch)
	configured := parse_array(transmute([]u8)string("*1\r\n$1048577\r\n"), &scratch, limits)
	testing.expect(t, configured.kind == .Error && configured.fault == .Invalid_Bulk_Length)
}

@(test)
observed_permissive_header_and_payload_trailers :: proc(t: ^testing.T) {
	scratch: Scratch
	defer destroy(&scratch)
	for first in 0..<256 {
		for second in 0..<256 {
			wire := [14]u8{'*', '1', '\r', u8(first), '$', '4', '\r', u8(second), 'P', 'I', 'N', 'G', u8(second), u8(first)}
			result := parse_array(wire[:], &scratch, normal_limits())
			testing.expect(t, result.kind == .Command && result.argc == 1 && result.consumed == len(wire))
			expect_equal(t, scratch.args[0], transmute([]u8)string("PING"))
		}
	}
}

@(test)
observed_nul_lf_partial_and_unexpected_prefix :: proc(t: ^testing.T) {
	incomplete := []string{
		"*1\r",
		"*+1\r",
		"*1\n$4\nPING\n",
		"*1\x00\r\n",
		"*1\r\n\x00PING\r\n",
		"*1\r\n$4\x00\r\nPING\r\n",
		"*1\r\n$4\r",
	}
	scratch: Scratch
	defer destroy(&scratch)
	for wire in incomplete {
		result := parse_array(transmute([]u8)wire, &scratch, normal_limits())
		testing.expect(t, result.kind == .Incomplete && result.consumed == 0 && result.argc == 0)
	}
	prefixes := []u8{'+', '*', '\r', '\n'}
	for byte in prefixes {
		wire := [11]u8{'*', '1', '\r', '\n', byte, 'P', 'I', 'N', 'G', '\r', '\n'}
		result := parse_array(wire[:], &scratch, normal_limits())
		testing.expect(t, result.kind == .Error && result.fault == .Expected_Bulk && result.error_byte == byte)
	}
}

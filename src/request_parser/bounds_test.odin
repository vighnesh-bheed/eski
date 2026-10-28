package request_parser

import "core:testing"

@(test)
unbounded_header_limits_and_nul_blocking :: proc(t: ^testing.T) {
	for length in 65535..=65537 {
		wire := make([]u8, length + 4)
		defer delete(wire)
		for index in 0..<len(wire) {
			wire[index] = '1'
		}
		scratch: Scratch
		defer destroy(&scratch)
		owner: ^Inline_Owner
		defer inline_release(&owner)
		for nul in 0..<2 {
			wire[0] = '*'
			wire[2] = 0 if nul == 1 else u8('1')
			array := parse_array(wire[:length], &scratch, normal_limits())
			testing.expect(t, array.kind == (.Error if length > 65536 else .Incomplete))
			if length > 65536 {
				testing.expect(t, array.fault == .Array_Header_Too_Large)
			}
			wire[0] = '*'
			wire[1] = '1'
			wire[2] = '\r'
			wire[3] = '\n'
			wire[4] = '$'
			wire[6] = 0 if nul == 1 else u8('1')
			bulk := parse_array(wire[:length + 4], &scratch, normal_limits())
			testing.expect(t, bulk.kind == (.Error if length > 65536 else .Incomplete))
			if length > 65536 {
				testing.expect(t, bulk.fault == .Bulk_Header_Too_Large)
			}
			wire[0] = 'A'
			wire[1] = 'A'
			wire[2] = 0 if nul == 1 else u8('A')
			wire[3] = 'A'
			wire[4] = 'A'
			wire[6] = 'A'
			inline := parse_inline(wire[:length], &scratch, &owner, normal_limits())
			testing.expect(t, inline.kind == (.Error if length > 65536 else .Incomplete))
			if length > 65536 {
				testing.expect(t, inline.fault == .Inline_Too_Large)
			}
			testing.expect(t, owner == nil && len(scratch.args) == 0)
		}
	}
}

@(test)
complete_overlong_headers_and_inline_lines :: proc(t: ^testing.T) {
	scratch: Scratch
	defer destroy(&scratch)
	owner: ^Inline_Owner
	defer inline_release(&owner)
	lengths := []int{65536, 65537, 70000}
	for length in lengths {
		wire := make([]u8, length + 2)
		defer delete(wire)
		copy(wire, transmute([]u8)string("ECHO "))
		for index in 5..<length {
			wire[index] = 'A'
		}
		wire[length] = '\r'
		wire[length + 1] = '\n'
		result := parse_inline(wire, &scratch, &owner, normal_limits())
		testing.expect(t, result.kind == .Command && result.argc == 2 && result.consumed == len(wire))
		testing.expect(t, len(scratch.args[1]) == length - 5 && owner == nil)
		for byte in scratch.args[1] {
			testing.expect(t, byte == 'A')
		}
	}
	wire := make([]u8, 70007)
	defer delete(wire)
	for index in 0..<len(wire) {
		wire[index] = '1'
	}
	wire[0] = '*'
	wire[70001] = '\r'
	wire[70002] = '\n'
	array := parse_array(wire[:70003], &scratch, normal_limits())
	testing.expect(t, array.kind == .Error && array.fault == .Invalid_Array_Length)
	wire[0] = '*'
	wire[1] = '1'
	wire[2] = '\r'
	wire[3] = '\n'
	wire[4] = '$'
	wire[70001] = '1'
	wire[70002] = '1'
	wire[70005] = '\r'
	wire[70006] = '\n'
	bulk := parse_array(wire, &scratch, normal_limits())
	testing.expect(t, bulk.kind == .Error && bulk.fault == .Invalid_Bulk_Length)
	wire[4] = '!'
	wrong := parse_array(wire, &scratch, normal_limits())
	testing.expect(t, wrong.kind == .Error && wrong.fault == .Expected_Bulk && wrong.error_byte == '!')
}

@(test)
native_bulk_end_and_descriptor_size_arithmetic :: proc(t: ^testing.T) {
	last := i64(max(int))
	required, valid := bulk_required_end(0, 0, last - 2)
	testing.expect(t, valid && required == max(int))
	_, valid = bulk_required_end(0, 1, last - 2)
	testing.expect(t, !valid)
	_, valid = bulk_required_end(1, 0, last - 2)
	testing.expect(t, !valid)
	required, valid = bulk_required_end(max(int) - 2, 0, 0)
	testing.expect(t, valid && required == 2)
	_, valid = bulk_required_end(max(int) - 1, 0, 0)
	testing.expect(t, !valid)
	_, valid = bulk_required_end(-1, 0, 0)
	testing.expect(t, !valid)
	_, valid = bulk_required_end(0, -1, 0)
	testing.expect(t, !valid)
	_, valid = bulk_required_end(0, 0, -1)
	testing.expect(t, !valid)
	scratch: Scratch
	defer destroy(&scratch)
	testing.expect(t, !ensure_args(&scratch, max(int) / size_of([]u8) + 1) && len(scratch.args) == 0)
	limits := normal_limits()
	limits.bulk_max = max(i64)
	too_large := parse_array(transmute([]u8)string("*1\r\n$9223372036854775807\r\n"), &scratch, limits)
	testing.expect(t, too_large.kind == .Error && too_large.fault == .Invalid_Bulk_Length && too_large.need == 0)
	limits.base_offset = max(int) - 10
	too_large = parse_array(transmute([]u8)string("*1\r\n$0\r\n"), &scratch, limits)
	testing.expect(t, too_large.kind == .Incomplete && too_large.need == 10)
	limits.base_offset += 1
	too_large = parse_array(transmute([]u8)string("*1\r\n$0\r\n"), &scratch, limits)
	testing.expect(t, too_large.kind == .Error && too_large.fault == .Invalid_Bulk_Length)
}

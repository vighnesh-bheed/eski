package request_parser

import "core:testing"

@(test)
incomplete_bulk_reports_only_validated_payload_prefix :: proc(t: ^testing.T) {
	first := transmute([]u8)string("binary\x00\xff\r\nargument")
	last := transmute([]u8)string("last-value")
	args := [][]u8{transmute([]u8)string("MSET"), transmute([]u8)string("first"), first, transmute([]u8)string("last"), last}
	wire := encode_array(args)
	defer delete(wire)
	payload := len(wire) - len(last) - 2
	for preallocate in ([2]bool{false, true}) {
		scratch: Scratch
		if preallocate { testing.expect(t, ensure_args(&scratch, 64)) }
		result := parse_array(wire[:payload + 3], &scratch, normal_limits())
		testing.expect_value(t, result.kind, Kind.Incomplete)
		testing.expect_value(t, result.payload, payload)
		testing.expect_value(t, result.need, len(wire))
		expect_equal(t, scratch.args[2], first)
		result = parse_array(wire[:payload - 1], &scratch, normal_limits())
		testing.expect_value(t, result.kind, Kind.Incomplete)
		testing.expect_value(t, result.payload, 0)
		destroy(&scratch)
	}
}

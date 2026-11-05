package request_parser

import integer "../integer"

Kind :: enum u8 {
	Incomplete,
	Command,
	Error,
}

Fault :: enum u8 {
	None,
	Invalid_Array_Length,
	Invalid_Bulk_Length,
	Unauthenticated_Array_Length,
	Unauthenticated_Bulk_Length,
	Expected_Bulk,
	Unbalanced_Quotes,
	Array_Header_Too_Large,
	Bulk_Header_Too_Large,
	Inline_Too_Large,
}

Limits :: struct {
	bulk_max:          i64,
	base_offset:       int,
	unauthenticated:   bool,
	unauth_array_max:  i64,
	unauth_bulk_max:   i64,
}

Result :: struct {
	consumed:   int,
	need:       int,
	payload:    int,
	argc:       int,
	kind:       Kind,
	fault:      Fault,
	error_byte: u8,
}

Scratch :: struct {
	args: [][]u8,
}

Header_Result :: struct {
	end:       int,
	next:      int,
	need:      int,
	kind:      Kind,
	unbounded: bool,
}

UNBOUNDED_MAX :: 65536

ensure_args :: #force_inline proc(scratch: ^Scratch, wanted: int) -> bool {
	if wanted >= 0 && wanted <= len(scratch.args) {
		return true
	}
	return grow_args(scratch, wanted)
}

grow_args :: #force_no_inline proc(scratch: ^Scratch, wanted: int) -> bool {
	maximum := max(int) / size_of([]u8)
	if wanted < 0 || wanted > maximum {
		return false
	}
	capacity := max(64, wanted)
	if len(scratch.args) <= max(int) / 2 {
		capacity = max(capacity, len(scratch.args) * 2)
	}
	capacity = min(capacity, maximum)
	replacement := make([][]u8, capacity)
	copy(replacement, scratch.args)
	delete(scratch.args)
	scratch.args = replacement
	return true
}

destroy :: proc(scratch: ^Scratch) {
	delete(scratch.args)
	scratch^ = {}
}

header_end :: #force_inline proc "contextless" (input: []u8, offset: int) -> Header_Result {
	cursor := offset
	for cursor < len(input) {
		byte := input[cursor]
		if byte == 0 {
			break
		}
		if byte == '\r' {
			if cursor > max(int) - 2 {
				return {kind = .Error}
			}
			if cursor + 1 == len(input) {
				return {kind = .Incomplete, need = cursor + 2}
			}
			return {kind = .Command, end = cursor, next = cursor + 2}
		}
		cursor += 1
	}
	if len(input) == max(int) {
		return {kind = .Incomplete, unbounded = true}
	}
	return {kind = .Incomplete, need = len(input) + 1, unbounded = true}
}

bulk_required_end :: #force_inline proc "contextless" (base_offset, payload_offset: int, length: i64) -> (int, bool) {
	if base_offset < 0 || payload_offset < 0 || length < 0 || payload_offset > max(int) - base_offset {
		return 0, false
	}
	remaining := max(int) - base_offset - payload_offset
	if remaining < 2 || u64(length) > u64(remaining - 2) {
		return 0, false
	}
	return payload_offset + int(length) + 2, true
}

read_nonnegative_header :: #force_inline proc "contextless" (input: []u8, offset: int, marker: u8) -> (i64, int, bool) {
	if len(input) - offset < 4 {
		return 0, 0, false
	}
	actual, first, third: u8
	#no_bounds_check {
		actual = input[offset]
		first = input[offset + 1]
		third = input[offset + 2]
	}
	if actual != marker || first < '0' || first > '9' {
		return 0, 0, false
	}
	if third == '\r' {
		return i64(first - '0'), offset + 4, true
	}
	if first == '0' {
		return 0, 0, false
	}
	value := u64(first - '0')
	cursor := offset + 2
	digits := 1
	for cursor < len(input) {
		byte: u8
		#no_bounds_check {
			byte = input[cursor]
		}
		if byte == '\r' {
			if len(input) - cursor < 2 || value > u64(max(i64)) {
				return 0, 0, false
			}
			return i64(value), cursor + 2, true
		}
		if byte < '0' || byte > '9' || digits == 19 {
			return 0, 0, false
		}
		value = value * 10 + u64(byte - '0')
		digits += 1
		cursor += 1
	}
	return 0, 0, false
}

parse_array :: #force_inline proc(input: []u8, scratch: ^Scratch, limits: Limits) -> Result {
	count, cursor, count_valid := read_nonnegative_header(input, 0, '*')
	if !count_valid || count > 2147483647 || count > i64(len(scratch.args)) || limits.base_offset < 0 {
		return parse_array_slow(input, scratch, limits)
	}
	if count == 0 {
		return {kind = .Command, consumed = cursor}
	}
	if limits.unauthenticated && count > limits.unauth_array_max {
		return {kind = .Error, fault = .Unauthenticated_Array_Length}
	}
	frame_limit := max(int) - limits.base_offset
	for argument in 0..<int(count) {
		length, payload, length_valid := read_nonnegative_header(input, cursor, '$')
		if !length_valid {
			return parse_array_slow(input, scratch, limits)
		}
		if length > limits.bulk_max {
			return {kind = .Error, fault = .Invalid_Bulk_Length}
		}
		if limits.unauthenticated && length > limits.unauth_bulk_max {
			return {kind = .Error, fault = .Unauthenticated_Bulk_Length}
		}
		if frame_limit < 2 || payload > frame_limit - 2 || u64(length) > u64(frame_limit - 2 - payload) {
			return {kind = .Error, fault = .Invalid_Bulk_Length}
		}
		next := payload + int(length) + 2
		if next > len(input) {
			return {kind = .Incomplete, need = next, payload = payload}
		}
		#no_bounds_check {
			scratch.args[argument] = input[payload:next - 2]
		}
		cursor = next
	}
	return {kind = .Command, consumed = cursor, argc = int(count)}
}

parse_array_slow :: #force_inline proc(input: []u8, scratch: ^Scratch, limits: Limits) -> Result {
	return parse_array_slow_fields(input, scratch, limits.bulk_max, limits.base_offset, limits.unauthenticated, limits.unauth_array_max, limits.unauth_bulk_max)
}

parse_array_slow_fields :: #force_no_inline proc(input: []u8, scratch: ^Scratch, bulk_max: i64, base_offset: int, unauthenticated: bool, unauth_array_max, unauth_bulk_max: i64) -> Result {
	limits := Limits{bulk_max = bulk_max, base_offset = base_offset, unauthenticated = unauthenticated, unauth_array_max = unauth_array_max, unauth_bulk_max = unauth_bulk_max}
	if len(input) == 0 {
		return {kind = .Incomplete, need = 1}
	}
	header := header_end(input, 0)
	if header.kind != .Command {
		if header.unbounded && len(input) > UNBOUNDED_MAX {
			return {kind = .Error, fault = .Array_Header_Too_Large}
		}
		if header.kind == .Error {
			return {kind = .Error, fault = .Invalid_Array_Length}
		}
		return {kind = header.kind, need = header.need}
	}
	if input[0] != '*' || header.end == 0 {
		return {kind = .Error, fault = .Invalid_Array_Length}
	}
	count, valid := integer.parse_i64(input[1:header.end])
	if !valid || count > 2147483647 {
		return {kind = .Error, fault = .Invalid_Array_Length}
	}
	if count <= 0 {
		return {kind = .Command, consumed = header.next}
	}
	if limits.unauthenticated && count > limits.unauth_array_max {
		return {kind = .Error, fault = .Unauthenticated_Array_Length}
	}
	cursor := header.next
	for argument in 0..<int(count) {
		bulk := header_end(input, cursor)
		if bulk.kind != .Command {
			if bulk.unbounded && len(input) - cursor > UNBOUNDED_MAX {
				return {kind = .Error, fault = .Bulk_Header_Too_Large}
			}
			if bulk.kind == .Error {
				return {kind = .Error, fault = .Invalid_Bulk_Length}
			}
			return {kind = bulk.kind, need = bulk.need}
		}
		if input[cursor] != '$' {
			return {kind = .Error, fault = .Expected_Bulk, error_byte = input[cursor]}
		}
		length, length_valid := integer.parse_i64(input[cursor + 1:bulk.end])
		if !length_valid || length < 0 || length > limits.bulk_max {
			return {kind = .Error, fault = .Invalid_Bulk_Length}
		}
		if limits.unauthenticated && length > limits.unauth_bulk_max {
			return {kind = .Error, fault = .Unauthenticated_Bulk_Length}
		}
		cursor = bulk.next
		next, representable := bulk_required_end(limits.base_offset, cursor, length)
		if !representable {
			return {kind = .Error, fault = .Invalid_Bulk_Length}
		}
		payload_end := next - 2
		if next > len(input) {
			return {kind = .Incomplete, need = next, payload = cursor}
		}
		if !ensure_args(scratch, argument + 1) {
			return {kind = .Error, fault = .Invalid_Array_Length}
		}
		scratch.args[argument] = input[cursor:payload_end]
		cursor = next
	}
	return {kind = .Command, consumed = cursor, argc = int(count)}
}

fault_detail :: #force_inline proc "contextless" (fault: Fault) -> string {
	switch fault {
	case .Invalid_Array_Length:
		return "invalid multibulk length"
	case .Invalid_Bulk_Length:
		return "invalid bulk length"
	case .Unauthenticated_Array_Length:
		return "unauthenticated multibulk length"
	case .Unauthenticated_Bulk_Length:
		return "unauthenticated bulk length"
	case .Unbalanced_Quotes:
		return "unbalanced quotes in request"
	case .Array_Header_Too_Large:
		return "too big mbulk count string"
	case .Bulk_Header_Too_Large:
		return "too big bulk count string"
	case .Inline_Too_Large:
		return "too big inline request"
	case .None, .Expected_Bulk:
		return ""
	}
	return ""
}

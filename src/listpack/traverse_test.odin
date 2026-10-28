package listpack

import "core:testing"

test_pack :: proc(entries: []Entry) -> [^]u8 {
	total := LP_HDR_SIZE + 1
	for entry in entries {
		plan, valid := plan_entry(entry)
		if !valid || plan.encoded_bytes > max(int) - total {
			return nil
		}
		total += plan.encoded_bytes
	}
	lp := lp_new(total)
	if lp == nil {
		return nil
	}
	lp_set_total_bytes(lp, u64(total))
	lp_set_num_elements(lp, u64(len(entries)))
	cursor := LP_HDR_SIZE
	for entry in entries {
		plan, valid := plan_entry(entry)
		if !valid || !write_entry(lp[cursor:cursor + plan.encoded_bytes], plan) {
			lp_free(lp)
			return nil
		}
		cursor += plan.encoded_bytes
	}
	lp[total - 1] = LP_EOF
	return lp
}

@(test)
logical_traversal_seek_endpoints_and_extreme_indices :: proc(t: ^testing.T) {
	entries := []Entry{
		entry_from_bytes(nil),
		entry_from_int(0),
		entry_from_int(-1),
		entry_from_bytes(transmute([]u8)string("binary\x00\xff")),
		entry_from_int(min(i64)),
		entry_from_bytes(transmute([]u8)string("01")),
		entry_from_int(max(i64)),
	}
	lp := test_pack(entries)
	defer lp_free(lp)
	testing.expect(t, lp != nil)
	if lp == nil {
		return
	}
	positions: [7][^]u8
	for unknown in 0..<2 {
		lp_set_num_elements(lp, u64(len(entries)) if unknown == 0 else LP_HDR_NUMELE_UNKNOWN)
		cursor := lp_first(lp)
		for index in 0..<len(entries) {
			testing.expect(t, cursor != nil)
			if cursor == nil {
				break
			}
			positions[index] = cursor
			actual := lp_get_entry(cursor)
			testing.expect(t, (actual.sval == nil) == (entries[index].sval == nil))
			buffer: [LP_INTBUF_SIZE]u8
			expected_buffer: [LP_INTBUF_SIZE]u8
			testing.expect(t, string(lp_get_bytes(cursor, &buffer)) == string(entry_bytes(entries[index], &expected_buffer)))
			cursor = lp_next(lp, cursor)
		}
		testing.expect(t, cursor == nil)
		cursor = lp_last(lp)
		for index := len(entries) - 1; index >= 0; index -= 1 {
			testing.expect(t, cursor == positions[index])
			cursor = lp_prev(lp, cursor)
		}
		testing.expect(t, cursor == nil)
		for index in 0..<len(entries) {
			testing.expect(t, lp_seek(lp, i64(index)) == positions[index])
			testing.expect(t, lp_seek(lp, i64(index - len(entries))) == positions[index])
		}
		testing.expect(t, lp_seek(lp, i64(len(entries))) == nil && lp_seek(lp, -i64(len(entries)) - 1) == nil)
		testing.expect(t, lp_seek(lp, min(i64)) == nil && lp_seek(lp, max(i64)) == nil)
		testing.expect(t, lp_get_num_elements(lp) == u32(len(entries)) if unknown == 0 else lp_get_num_elements(lp) == LP_HDR_NUMELE_UNKNOWN)
	}
	empty := lp_new(0)
	defer lp_free(empty)
	testing.expect(t, lp_first(empty) == nil && lp_last(empty) == nil)
	testing.expect(t, lp_seek(empty, 0) == nil && lp_seek(empty, -1) == nil)
}

@(test)
borrowed_getters_respect_nonminimal_stored_strings_and_integer_buffers :: proc(t: ^testing.T) {
	wire := [14]u8{14, 0, 0, 0, 2, 0, 130, 'u', ':', 3, 129, '1', 2, 255}
	testing.expect(t, lp_validate_integrity(raw_data(wire[:]), u64(len(wire)), true, nil, nil))
	p := lp_last(raw_data(wire[:]))
	entry := lp_get_entry(p)
	testing.expect(t, entry.sval == raw_data(wire[11:]) && entry.slen == 1)
	buffer: [LP_INTBUF_SIZE]u8
	for index in 0..<len(buffer) {
		buffer[index] = 238
	}
	bytes := lp_get_bytes(p, &buffer)
	testing.expect(t, raw_data(bytes) == raw_data(wire[11:]) && string(bytes) == "1" && buffer[0] == 238)
	integer_wire := [9]u8{9, 0, 0, 0, 1, 0, 127, 1, 255}
	bytes = lp_get_bytes(lp_first(raw_data(integer_wire[:])), &buffer)
	testing.expect(t, string(bytes) == "127" && raw_data(bytes) == raw_data(buffer[:]) && buffer[3] == 238)
}

@(test)
validated_cursor_rejects_outside_pack_without_touching_margins :: proc(t: ^testing.T) {
	storage: [32]u8
	for index in 0..<len(storage) {
		storage[index] = 238
	}
	wire := [13]u8{13, 0, 0, 0, 2, 0, 130, 'u', ':', 3, 0, 1, 255}
	copy(storage[8:], wire[:])
	lp := raw_data(storage[8:])
	offsets := []int{-1, 0, 5, 13, 14}
	for offset in offsets {
		cursor := padd(lp, offset)
		testing.expect(t, !lp_validate_next(lp, &cursor, 13))
	}
	cursor := padd(lp, 6)
	testing.expect(t, !lp_validate_next(lp, &cursor, 6))
	testing.expect(t, !lp_validate_next(lp, &cursor, max(u64)))
	cursor = padd(lp, 12)
	testing.expect(t, lp_validate_next(lp, &cursor, 13) && cursor == nil)
	for byte, index in wire {
		testing.expect(t, storage[8 + index] == byte)
	}
	testing.expect(t, storage[7] == 238 && storage[21] == 238)
}

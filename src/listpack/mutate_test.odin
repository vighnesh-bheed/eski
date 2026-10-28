package listpack

import "core:testing"

expect_values :: proc(t: ^testing.T, lp: [^]u8, expected: []string) {
	testing.expect(t, lp != nil)
	if lp == nil {
		return
	}
	testing.expect(t, lp_validate_integrity(lp, u64(lp_bytes(lp)), true, nil, nil))
	testing.expect(t, lp_length(lp) == u64(len(expected)))
	cursor := lp_first(lp)
	for value in expected {
		testing.expect(t, cursor != nil)
		if cursor == nil {
			return
		}
		buffer: [LP_INTBUF_SIZE]u8
		testing.expect(t, string(lp_get_bytes(cursor, &buffer)) == value)
		cursor = lp_next(lp, cursor)
	}
	testing.expect(t, cursor == nil)
	cursor = lp_last(lp)
	for index := len(expected) - 1; index >= 0; index -= 1 {
		testing.expect(t, cursor != nil)
		if cursor == nil {
			return
		}
		buffer: [LP_INTBUF_SIZE]u8
		testing.expect(t, string(lp_get_bytes(cursor, &buffer)) == expected[index])
		cursor = lp_prev(lp, cursor)
	}
	testing.expect(t, cursor == nil)
}

@(test)
mutation_transitions_preserve_order_selectors_and_returned_cursors :: proc(t: ^testing.T) {
	lp := lp_new(0)
	defer lp_free(lp)
	lp = lp_append_integer(lp, -4097)
	lp = lp_prepend(lp, transmute([]u8)string("01"))
	lp = lp_append(lp, nil)
	p: [^]u8
	lp = lp_insert_integer(lp, max(i64), lp_seek(lp, 1), LP_AFTER, &p)
	testing.expect(t, p == lp_seek(lp, 2) && lp_get_entry(p).lval == max(i64))
	expect_values(t, lp, []string{"01", "-4097", "9223372036854775807", ""})
	lp = lp_replace(lp, &p, transmute([]u8)string("x\x00\xff"))
	testing.expect(t, p == lp_seek(lp, 2) && lp_get_entry(p).sval != nil)
	expect_values(t, lp, []string{"01", "-4097", "x\x00\xff", ""})
	lp = lp_delete(lp, lp_seek(lp, 1), &p)
	testing.expect(t, p == lp_seek(lp, 1))
	lp = lp_delete_range_with_entry(lp, &p, max(u64))
	testing.expect(t, p == nil)
	expect_values(t, lp, []string{"01"})
	lp = lp_delete_range(lp, min(i64), max(u64))
	expect_values(t, lp, []string{"01"})
	lp = lp_delete_range(lp, -1, 1)
	expect_values(t, lp, nil)
}

@(test)
bulk_mutation_preserves_borrowed_payloads_across_tail_moves_and_growth :: proc(t: ^testing.T) {
	lp := lp_new(0)
	defer lp_free(lp)
	payload := make([]u8, 4097)
	defer delete(payload)
	for _, index in payload {
		payload[index] = u8(index % 251)
	}
	lp = lp_append(lp, payload)
	borrowed := lp_get_entry(lp_first(lp))
	entries := [4]Entry{borrowed, entry_from_int(min(i64)), borrowed, entry_from_bytes(nil)}
	lp = lp_batch_insert(lp, lp_first(lp), LP_BEFORE, entries[:], nil)
	expect_values(t, lp, []string{string(payload), "-9223372036854775808", string(payload), "", string(payload)})
	p := lp_first(lp)
	borrowed = lp_get_entry(lp_last(lp))
	lp = lp_replace(lp, &p, borrowed.sval[:int(borrowed.slen)])
	expect_values(t, lp, []string{string(payload), "-9223372036854775808", string(payload), "", string(payload)})
	deletions := [3][^]u8{lp_seek(lp, 0), lp_seek(lp, 2), lp_seek(lp, 4)}
	lp = lp_batch_delete(lp, deletions[:])
	expect_values(t, lp, []string{"-9223372036854775808", ""})
}

@(test)
mutation_count_saturates_and_unknown_count_remains_unknown :: proc(t: ^testing.T) {
	entries := make([]Entry, 65534)
	defer delete(entries)
	for _, index in entries {
		entries[index] = entry_from_int(i64(index % 128))
	}
	lp := lp_new(0)
	defer lp_free(lp)
	lp = lp_batch_append(lp, entries)
	testing.expect(t, lp_get_num_elements(lp) == 65534)
	lp = lp_append_integer(lp, 1)
	testing.expect(t, lp_get_num_elements(lp) == LP_HDR_NUMELE_UNKNOWN && lp_length(lp) == 65535)
	lp = lp_append_integer(lp, 2)
	testing.expect(t, lp_get_num_elements(lp) == LP_HDR_NUMELE_UNKNOWN && lp_length(lp) == 65536)
	p := lp_first(lp)
	lp = lp_delete_range_with_entry(lp, &p, 3)
	testing.expect(t, lp_get_num_elements(lp) == LP_HDR_NUMELE_UNKNOWN)
	testing.expect(t, lp_length(lp) == 65533 && lp_get_num_elements(lp) == 65533)
	testing.expect(t, lp_validate_integrity(lp, u64(lp_bytes(lp)), true, nil, nil))
}

@(test)
mutation_sequence_matches_independent_dense_value_model :: proc(t: ^testing.T) {
	lp := lp_new(0)
	defer lp_free(lp)
	model: [128]string
	count := 0
	state := u32(1729)
	values := [4]string{"", "x", "001", "a\x00b\xff"}
	for _ in 0..<2000 {
		state = state * 1664525 + 1013904223
		op := int(state % 5)
		if count == 0 || count > 100 {
			op = 0 if count == 0 else 2
		}
		value := values[int(state >> 16) % len(values)]
		index := int(state >> 8) % (count + 1)
		switch op {
		case 0:
			cursor := padd(lp, lp_bytes(lp) - 1)
			if index < count {
				cursor = lp_seek(lp, i64(index))
			}
			lp = lp_insert_string(lp, transmute([]u8)value, cursor, LP_BEFORE, &cursor)
			copy(model[index + 1:count + 1], model[index:count])
			model[index] = value
			count += 1
			testing.expect(t, cursor == lp_seek(lp, i64(index)))
		case 1:
			index %= count
			cursor := lp_seek(lp, i64(index))
			lp = lp_replace(lp, &cursor, transmute([]u8)value)
			model[index] = value
			testing.expect(t, cursor == lp_seek(lp, i64(index)))
		case 2:
			index %= count
			removed := min(int(state >> 24) % 9 + 1, count - index)
			cursor := lp_seek(lp, i64(index))
			lp = lp_delete_range_with_entry(lp, &cursor, u64(removed))
			copy(model[index:count - removed], model[index + removed:count])
			count -= removed
			testing.expect(t, cursor == lp_seek(lp, i64(index)))
		case 3:
			batch := [3]Entry{entry_from_bytes(transmute([]u8)value), entry_from_int(-1), entry_from_bytes(nil)}
			cursor := padd(lp, lp_bytes(lp) - 1)
			if index < count {
				cursor = lp_seek(lp, i64(index))
			}
			lp = lp_batch_insert(lp, cursor, LP_BEFORE, batch[:], &cursor)
			copy(model[index + 3:count + 3], model[index:count])
			model[index], model[index + 1], model[index + 2] = value, "-1", ""
			count += 3
			testing.expect(t, cursor == lp_seek(lp, i64(index + 2)))
		case 4:
			if count > 2 {
				deletions := [2][^]u8{lp_first(lp), lp_last(lp)}
				lp = lp_batch_delete(lp, deletions[:])
				copy(model[:count - 2], model[1:count - 1])
				count -= 2
			}
		}
		expect_values(t, lp, model[:count])
		if testing.failed(t) {
			return
		}
	}
}

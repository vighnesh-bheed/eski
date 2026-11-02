package listpack

import "core:testing"
import "core:mem"

Callback_Record :: struct {
	visits: int,
	stop_after: int,
	heads: [4]u32,
	tags: [4]u8,
}

record_entry :: proc(p: [^]u8, head_count: u32, userdata: rawptr) -> bool {
	record := cast(^Callback_Record)userdata
	if record.visits < len(record.heads) {
		record.heads[record.visits] = head_count
		record.tags[record.visits] = p[0]
	}
	record.visits += 1
	return record.stop_after == 0 || record.visits < record.stop_after
}

@(test)
bounded_walk_callbacks_and_count_recache :: proc(t: ^testing.T) {
	wire := [17]u8{17, 0, 0, 0, 3, 0, 129, 'm', 2, 223, 249, 2, 130, 'q', '9', 3, 255}
	header, header_valid := decode_header(wire[:])
	testing.expect(t, header_valid)
	record: Callback_Record
	count, valid := walk_entries(wire[:], header, record_entry, &record)
	testing.expect(t, valid && count == 3 && record.visits == 3)
	testing.expect(t, record.heads[0] == 3 && record.heads[1] == 3 && record.heads[2] == 3)
	testing.expect(t, record.tags[0] == 129 && record.tags[1] == 223 && record.tags[2] == 130)
	record = {stop_after = 1}
	_, valid = walk_entries(wire[:], header, record_entry, &record)
	testing.expect(t, !valid && record.visits == 1)
	wire[4] = 4
	header, header_valid = decode_header(wire[:])
	testing.expect(t, header_valid)
	record = {}
	count, valid = walk_entries(wire[:], header, record_entry, &record)
	testing.expect(t, !valid && count == 3 && record.visits == 3 && record.heads[0] == 4 && record.heads[2] == 4)
	wire[4], wire[5] = 255, 255
	header, header_valid = decode_header(wire[:])
	testing.expect(t, header_valid)
	record = {}
	count, valid = walk_entries(wire[:], header, record_entry, &record)
	testing.expect(t, valid && count == 3 && record.visits == 3 && record.heads[0] == 65535 && record.heads[2] == 65535)
	lp := lp_malloc(len(wire))
	defer lp_free(lp)
	copy(lp[:len(wire)], wire[:])
	testing.expect(t, lp_length(lp) == 3 && lp_get_num_elements(lp) == 3)
}

@(test)
bounded_entry_extent_requires_complete_reverse_length :: proc(t: ^testing.T) {
	fixture := [5]u8{131, 'a', 0, 255, 4}
	for limit in 0..<len(fixture) {
		_, valid := decode_entry_extent(fixture[:limit], 0, limit)
		testing.expect(t, !valid)
	}
	extent, valid := decode_entry_extent(fixture[:], 0, len(fixture))
	testing.expect(t, valid && extent.end == 5 && extent.body.bytes == 4 && extent.back_bytes == 1)
	fixture[4] = 3
	_, valid = decode_entry_extent(fixture[:], 0, len(fixture))
	testing.expect(t, !valid)
	fixture[4] = 132
	_, valid = decode_entry_extent(fixture[:], 0, len(fixture))
	testing.expect(t, !valid)
}

@(test)
public_integrity_callback_heads_shallow_and_early_stop :: proc(t: ^testing.T) {
	wire := [17]u8{17, 0, 0, 0, 3, 0, 129, 'm', 2, 223, 249, 2, 130, 'q', '9', 3, 255}
	record: Callback_Record
	testing.expect(t, lp_validate_integrity(raw_data(wire[:]), u64(len(wire)), false, record_entry, &record) && record.visits == 0)
	testing.expect(t, lp_validate_integrity(raw_data(wire[:]), u64(len(wire)), true, record_entry, &record) && record.visits == 3)
	testing.expect(t, record.heads[0] == 3 && record.heads[2] == 3)
	record = {stop_after = 1}
	testing.expect(t, !lp_validate_integrity(raw_data(wire[:]), u64(len(wire)), true, record_entry, &record) && record.visits == 1)
	wire[4] = 4
	record = {}
	testing.expect(t, lp_validate_integrity(raw_data(wire[:]), u64(len(wire)), false, record_entry, &record) && record.visits == 0)
	testing.expect(t, !lp_validate_integrity(raw_data(wire[:]), u64(len(wire)), true, record_entry, &record) && record.visits == 3)
	testing.expect(t, record.heads[0] == 4 && record.heads[2] == 4)
}

@(test)
bounded_integrity_rejects_sizes_and_announcements_without_allocating :: proc(t: ^testing.T) {
	malformed := [17]u8{17, 0, 0, 0, 2, 0, 130, 'u', ':', 3, 240, 255, 255, 255, 255, 5, 255}
	valid := [14]u8{13, 0, 0, 0, 2, 0, 130, 'u', ':', 3, 0, 129, 255, 255}
	saved := context.allocator
	context.allocator = mem.panic_allocator()
	accepts_quirk := lp_validate_integrity(raw_data(valid[:]), 13, true, nil, nil)
	rejects_announced := !lp_validate_integrity(raw_data(malformed[:]), u64(len(malformed)), true, nil, nil)
	rejects_extra := !lp_validate_integrity(raw_data(valid[:]), 14, true, nil, nil)
	rejects_short := !lp_validate_integrity(raw_data(valid[:]), 6, true, nil, nil)
	rejects_nil := !lp_validate_integrity(nil, 7, true, nil, nil)
	rejects_huge := !lp_validate_integrity(raw_data(valid[:]), max(u64), true, nil, nil)
	context.allocator = saved
	testing.expect(t, accepts_quirk && rejects_announced && rejects_extra && rejects_short && rejects_nil && rejects_huge)
	testing.expect(t, valid[10] == 0 && valid[11] == 129 && malformed[11] == 255)
}

@(test)
unknown_count_recache_at_u16_boundary :: proc(t: ^testing.T) {
	counts := []int{65534, 65535, 65536}
	for count in counts {
		total := PACK_HEADER_BYTES + count * 2 + 1
		lp := lp_new(total)
		defer lp_free(lp)
		testing.expect(t, lp != nil)
		if lp == nil {
			continue
		}
		lp_set_total_bytes(lp, u64(total))
		lp_set_num_elements(lp, COUNT_UNTRACKED)
		for index in 0..<count {
			lp[PACK_HEADER_BYTES + index * 2] = 0
			lp[PACK_HEADER_BYTES + index * 2 + 1] = 1
		}
		lp[total - 1] = PACK_END
		testing.expect(t, lp_length(lp) == u64(count))
		testing.expect(t, lp_get_num_elements(lp) == u32(min(count, COUNT_UNTRACKED)))
		testing.expect(t, lp_validate_integrity(lp, u64(total), true, nil, nil))
	}
}

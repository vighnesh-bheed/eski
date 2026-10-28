package request_parser

import "core:testing"

@(test)
quoted_inline_fragments_rewind_and_raw_preservation :: proc(t: ^testing.T) {
	template := transmute([]u8)string("ECHO \"\\x41\\x00\\xff\\n\"\r\n")
	wire := make([]u8, len(template))
	defer delete(wire)
	copy(wire, template)
	scratch: Scratch
	defer destroy(&scratch)
	owner: ^Inline_Owner
	defer inline_release(&owner)
	for split in 0..<len(wire) {
		result := parse_inline(wire[:split], &scratch, &owner, normal_limits())
		testing.expect(t, result.kind == .Incomplete && result.consumed == 0 && result.argc == 0)
		testing.expect(t, owner == nil && len(scratch.args) == 0)
		expect_equal(t, wire, template)
	}
	result := parse_inline(wire, &scratch, &owner, normal_limits())
	testing.expect(t, result.kind == .Command && result.argc == 2 && result.consumed == len(wire))
	expected := [4]u8{65, 0, 255, 10}
	expect_equal(t, scratch.args[1], expected[:])
	expect_equal(t, wire, template)
	first_owner := owner
	storage := raw_data(owner.storage)
	arguments := raw_data(scratch.args)
	capacity := len(scratch.args)
	for _ in 0..<5 {
		result = parse_inline(wire, &scratch, &owner, normal_limits())
		testing.expect(t, result.kind == .Command && result.argc == 2)
		testing.expect(t, owner == first_owner && raw_data(owner.storage) == storage)
		testing.expect(t, raw_data(scratch.args) == arguments && len(scratch.args) == capacity)
		expect_equal(t, scratch.args[1], expected[:])
		expect_equal(t, wire, template)
	}
}

@(test)
quoted_nested_connections_restore_outer_payload :: proc(t: ^testing.T) {
	outer_wire := transmute([]u8)string("ECHO \"outer\\x00\\xff\"\r\n")
	inner_wire: [dynamic]u8
	defer delete(inner_wire)
	for byte in transmute([]u8)string("COMMAND") {
		append(&inner_wire, byte)
	}
	for _ in 0..<130 {
		append(&inner_wire, ' ', '"', 'x', '"')
	}
	append(&inner_wire, '\r', '\n')
	scratch: Scratch
	defer destroy(&scratch)
	outer, inner: ^Inline_Owner
	defer inline_release(&outer)
	defer inline_release(&inner)
	first := parse_inline(outer_wire, &scratch, &outer, normal_limits())
	testing.expect(t, first.kind == .Command && first.argc == 2)
	saved: [2][]u8
	copy(saved[:], scratch.args[:2])
	outer_storage := raw_data(outer.storage)
	old_capacity := len(scratch.args)
	second := parse_inline(inner_wire[:], &scratch, &inner, normal_limits())
	testing.expect(t, second.kind == .Command && second.argc == 131)
	testing.expect(t, len(scratch.args) > old_capacity)
	copy(scratch.args[:2], saved[:])
	expect_equal(t, scratch.args[0], transmute([]u8)string("ECHO"))
	expect_equal(t, scratch.args[1], transmute([]u8)string("outer\x00\xff"))
	testing.expect(t, raw_data(outer.storage) == outer_storage && outer != inner)
	capacity := len(scratch.args)
	first = parse_inline(outer_wire, &scratch, &outer, normal_limits())
	testing.expect(t, first.kind == .Command && first.argc == 2 && len(scratch.args) == capacity)
	expect_equal(t, scratch.args[1], transmute([]u8)string("outer\x00\xff"))
	testing.expect(t, raw_data(outer.storage) == outer_storage)
}

@(test)
plain_inline_borrows_without_owner_and_empty_quotes_are_arguments :: proc(t: ^testing.T) {
	scratch: Scratch
	defer destroy(&scratch)
	owner: ^Inline_Owner
	defer inline_release(&owner)
	wire := transmute([]u8)string("PING\r\nNEXT\r\n")
	result := parse_inline(wire, &scratch, &owner, normal_limits())
	testing.expect(t, result.kind == .Command && result.argc == 1 && result.consumed == 6)
	testing.expect(t, owner == nil && raw_data(scratch.args[0]) == raw_data(wire))
	quoted := transmute([]u8)string("ECHO \"\" ''\r\n")
	result = parse_inline(quoted, &scratch, &owner, normal_limits())
	testing.expect(t, result.kind == .Command && result.argc == 3 && owner != nil)
	testing.expect(t, len(scratch.args[1]) == 0 && len(scratch.args[2]) == 0)
	blank := transmute([]u8)string(" \t\x0b\x0c\r\n")
	result = parse_inline(blank, &scratch, &owner, normal_limits())
	testing.expect(t, result.kind == .Command && result.argc == 0 && result.consumed == len(blank))
}

@(test)
complete_overlong_quoted_payload_owns_actual_bytes :: proc(t: ^testing.T) {
	payload_length := 70000
	wire := make([]u8, payload_length + 9)
	defer delete(wire)
	copy(wire, transmute([]u8)string("ECHO \""))
	for index in 6..<payload_length + 6 {
		wire[index] = 'A'
	}
	wire[payload_length + 6] = '"'
	wire[payload_length + 7] = '\r'
	wire[payload_length + 8] = '\n'
	scratch: Scratch
	defer destroy(&scratch)
	owner: ^Inline_Owner
	defer inline_release(&owner)
	result := parse_inline(wire, &scratch, &owner, normal_limits())
	testing.expect(t, result.kind == .Command && result.argc == 2 && result.consumed == len(wire))
	testing.expect(t, len(scratch.args[1]) == payload_length && owner != nil)
	testing.expect(t, len(owner.storage) >= payload_length + 7)
	testing.expect(t, inline_charge(owner) == size_of(Inline_Owner) + len(owner.storage))
	for byte in scratch.args[1] {
		testing.expect(t, byte == 'A')
	}
	testing.expect(t, wire[5] == '"' && wire[payload_length + 6] == '"')
	storage := raw_data(owner.storage)
	charge := inline_charge(owner)
	result = parse_inline(wire, &scratch, &owner, normal_limits())
	testing.expect(t, result.kind == .Command && raw_data(owner.storage) == storage && inline_charge(owner) == charge)
	testing.expect(t, inline_release(&owner) == charge && owner == nil)
}

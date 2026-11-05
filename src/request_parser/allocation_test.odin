package request_parser

import "core:mem"
import "core:testing"

@(test)
warmed_requests_do_not_allocate :: proc(t: ^testing.T) {
	scratch: Scratch
	defer destroy(&scratch)
	owner: ^Inline_Owner
	defer inline_release(&owner)
	array_wire := transmute([]u8)string("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n")
	quoted_wire := transmute([]u8)string("ECHO \"value\\x00\"\r\n")
	plain_wire := transmute([]u8)string("PING\r\n")
	limits := normal_limits()
	array := parse_array(array_wire, &scratch, limits)
	quoted := parse_inline(quoted_wire, &scratch, &owner, limits)
	testing.expect(t, array.kind == .Command && quoted.kind == .Command)
	arguments := raw_data(scratch.args)
	storage := raw_data(owner.storage)
	backing := context.allocator
	defer context.allocator = backing
	context.allocator = mem.panic_allocator()
	valid := true
	for _ in 0..<16 {
		array = parse_array(array_wire, &scratch, limits)
		valid = valid && array.kind == .Command && array.argc == 3
		quoted = parse_inline(quoted_wire, &scratch, &owner, limits)
		valid = valid && quoted.kind == .Command && quoted.argc == 2
		plain := parse_inline(plain_wire, &scratch, &owner, limits)
		valid = valid && plain.kind == .Command && plain.argc == 1
	}
	context.allocator = backing
	testing.expect(t, valid)
	testing.expect(t, raw_data(scratch.args) == arguments && raw_data(owner.storage) == storage)
}

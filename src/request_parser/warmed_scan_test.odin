package request_parser

import "core:mem"
import "core:testing"

@(test)
warm_frame_scans_match_validated_fragment_results :: proc(t: ^testing.T) {
	fast, slow: Scratch
	defer destroy(&fast)
	defer destroy(&slow)
	fast_owner, slow_owner: ^Inline_Owner
	defer inline_release(&fast_owner)
	defer inline_release(&slow_owner)
	testing.expect(t, ensure_args(&fast, 128) && inline_reserve(&fast_owner, 4096, 8192))
	wires := []string{
		"PING\r\nNEXT\r\n",
		" \t\x0b\x0c\r\n",
		"ECHO a\x0bb\x0cc\r\n",
		"ECHO a\"b\"\r\nNEXT\r\n",
		"ECHO \"a\\x00\\xff\\n\"\r\n",
		"ECHO 'a\\'b' '' \"\"\r\n",
		"ECHO \"a\"x\x00\r\n",
		"ECHO \"a\"x\n\x00",
		"ECHO \"a\\x4\n\"\r\n",
		"ECHO \"a\\x\x00f\"\r\n",
		"ECHO \"a\\\n\"\r\n",
		"ECHO \"a\"\x0bB\r\n",
	}
	for wire in wires {
		for cut in 0..=len(wire) {
			input := transmute([]u8)wire[:cut]
			first := parse_inline(input, &fast, &fast_owner, normal_limits())
			second := parse_inline_slow(input, &slow, &slow_owner, normal_limits())
			expect_same_result(t, first, second)
			if first.kind == .Command {
				for index in 0..<first.argc {
					expect_equal(t, fast.args[index], slow.args[index])
				}
			}
		}
	}
	blocked := parse_inline(transmute([]u8)string("ECHO \"a\"x\x00\r\n"), &fast, &fast_owner, normal_limits())
	testing.expect(t, blocked.kind == .Incomplete && blocked.consumed == 0 && blocked.argc == 0)
	terminated := parse_inline(transmute([]u8)string("ECHO \"a\"x\n\x00"), &fast, &fast_owner, normal_limits())
	testing.expect(t, terminated.kind == .Error && terminated.fault == .Unbalanced_Quotes)
}

@(test)
warmed_inline_escape_bytes_preserve_framing :: proc(t: ^testing.T) {
	fast, slow: Scratch
	defer destroy(&fast)
	defer destroy(&slow)
	fast_owner, slow_owner: ^Inline_Owner
	defer inline_release(&fast_owner)
	defer inline_release(&slow_owner)
	testing.expect(t, ensure_args(&fast, 64) && inline_reserve(&fast_owner, 256, 1024))
	templates := []string{
		"ECHO \"A\\x01\"\r\nNEXT\r\n",
		"ECHO \"A\\q\"\r\nNEXT\r\n",
		"ECHO 'A\\q'\r\nNEXT\r\n",
	}
	for template in templates {
		wire := make([]u8, len(template))
		defer delete(wire)
		for position in 7..<len(template) - 6 {
			for byte in 0..<256 {
				copy(wire, transmute([]u8)template)
				wire[position] = u8(byte)
				first := parse_inline(wire, &fast, &fast_owner, normal_limits())
				second := parse_inline_slow(wire, &slow, &slow_owner, normal_limits())
				expect_same_result(t, first, second)
				if first.kind == .Command {
					for index in 0..<first.argc {
						expect_equal(t, fast.args[index], slow.args[index])
					}
				}
				testing.expect(t, wire[position] == u8(byte))
			}
		}
	}
}

@(test)
warmed_array_exact_capacity_and_native_end :: proc(t: ^testing.T) {
	arguments := make([][]u8, 65)
	defer delete(arguments)
	for index in 0..<len(arguments) {
		arguments[index] = transmute([]u8)string("value")
	}
	wire := encode_array(arguments)
	defer delete(wire)
	scratch := Scratch{args = make([][]u8, len(arguments))}
	defer destroy(&scratch)
	backing := raw_data(scratch.args)
	saved := context.allocator
	context.allocator = mem.panic_allocator()
	result := parse_array(wire[:], &scratch, normal_limits())
	context.allocator = saved
	testing.expect(t, result.kind == .Command && result.argc == len(arguments) && result.consumed == len(wire))
	testing.expect(t, raw_data(scratch.args) == backing && len(scratch.args) == len(arguments))
	for argument, index in arguments {
		expect_equal(t, scratch.args[index], argument)
	}
	limits := normal_limits()
	limits.base_offset = max(int) - len(wire)
	result = parse_array(wire[:], &scratch, limits)
	testing.expect(t, result.kind == .Command && result.consumed == len(wire))
	limits.base_offset += 1
	result = parse_array(wire[:], &scratch, limits)
	testing.expect(t, result.kind == .Error && result.fault == .Invalid_Bulk_Length && result.consumed == 0)
}

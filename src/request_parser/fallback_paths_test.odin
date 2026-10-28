package request_parser

import "core:testing"

expect_same_result :: proc(t: ^testing.T, first, second: Result) {
	testing.expect(t, first.kind == second.kind && first.consumed == second.consumed && first.need == second.need && first.argc == second.argc && first.fault == second.fault && first.error_byte == second.error_byte)
}

@(test)
canonical_and_fallback_array_results_match :: proc(t: ^testing.T) {
	fast, slow: Scratch
	defer destroy(&fast)
	defer destroy(&slow)
	binary: [20]u8
	for index in 0..<len(binary) {
		binary[index] = u8(index)
	}
	counts := []int{0, 1, 2, 3, 33, 65}
	for count in counts {
		arguments := make([][]u8, count)
		defer delete(arguments)
		for index in 0..<count {
			arguments[index] = binary[:index % len(binary)]
		}
		wire := encode_array(arguments)
		defer delete(wire)
		for cut in 0..=len(wire) {
			first := parse_array(wire[:cut], &fast, normal_limits())
			second := parse_array_slow(wire[:cut], &slow, normal_limits())
			expect_same_result(t, first, second)
			if first.kind == .Command {
				for index in 0..<first.argc {
					expect_equal(t, fast.args[index], slow.args[index])
				}
			}
		}
	}
	unusual := []string{
		"*-1\r\n*1\r\n$4\r\nPING\r\n",
		"*01\r\n",
		"*+1\r",
		"*1\x00\r\n",
		"*2\r\n$1\r\nA\r\n$-1\r\n",
		"*2\r\n$1\r\nA\r\n!xx\r\n",
		"*2\r\n$1\r\nA\r\n$1\x00\r\nB\r\n",
		"*1\r\n$9223372036854775808\r\n",
	}
	for wire in unusual {
		first := parse_array(transmute([]u8)wire, &fast, normal_limits())
		second := parse_array_slow(transmute([]u8)wire, &slow, normal_limits())
		expect_same_result(t, first, second)
	}
}

@(test)
warmed_inline_capacity_miss_and_malformed_reuse :: proc(t: ^testing.T) {
	owner: ^Inline_Owner
	defer inline_release(&owner)
	testing.expect(t, inline_reserve(&owner, 4096, 65536))
	scratch: Scratch
	defer destroy(&scratch)
	malformed := transmute([]u8)string("ECHO \"a\" \"unterminated\r\n")
	bad := parse_inline(malformed, &scratch, &owner, normal_limits())
	testing.expect(t, bad.kind == .Error && bad.fault == .Unbalanced_Quotes && bad.argc == 0 && bad.consumed == 0)
	testing.expect(t, len(scratch.args) == 0)
	wire: [dynamic]u8
	defer delete(wire)
	for byte in transmute([]u8)string("COMMAND") {
		append(&wire, byte)
	}
	for _ in 0..<130 {
		append(&wire, ' ', '"', 'v', '"')
	}
	append(&wire, '\r', '\n')
	first_owner := owner
	storage := raw_data(owner.storage)
	result := parse_inline(wire[:], &scratch, &owner, normal_limits())
	testing.expect(t, result.kind == .Command && result.argc == 131)
	testing.expect(t, owner == first_owner && raw_data(owner.storage) == storage)
	for index in 1..<result.argc {
		expect_equal(t, scratch.args[index], transmute([]u8)string("v"))
	}
	arguments := raw_data(scratch.args)
	result = parse_inline(wire[:], &scratch, &owner, normal_limits())
	testing.expect(t, result.kind == .Command && result.argc == 131 && raw_data(scratch.args) == arguments)
	bad = parse_inline(transmute([]u8)string("ECHO \"a\"x\r\n"), &scratch, &owner, normal_limits())
	testing.expect(t, bad.kind == .Error && bad.fault == .Unbalanced_Quotes && bad.argc == 0 && bad.consumed == 0)
	testing.expect(t, raw_data(scratch.args) == arguments && raw_data(owner.storage) == storage)
}

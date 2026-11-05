package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import rp "../../src/request_parser"

Guarded :: struct {
	base: rawptr,
	whole: []u8,
	page, capacity: int,
}

fail :: proc(message: string) -> ! {
	fmt.eprintln(message)
	os.exit(1)
}

u32_at :: proc(data: []u8, at: ^int) -> u32 {
	if at^ > len(data) - 4 {
		fail("truncated fixture integer")
	}
	v, ok := endian.get_u32(data[at^:at^ + 4], .Little)
	if !ok {
		fail("invalid fixture integer")
	}
	at^ += 4
	return v
}

i64_at :: proc(data: []u8, at: ^int) -> i64 {
	if at^ > len(data) - 8 {
		fail("truncated fixture integer")
	}
	v, ok := endian.get_u64(data[at^:at^ + 8], .Little)
	if !ok {
		fail("invalid fixture integer")
	}
	at^ += 8
	return i64(v)
}

guarded :: proc(maximum, page: int) -> Guarded {
	capacity := max(page, ((maximum + page - 1) / page) * page)
	base, err := linux.mmap(0, uint(capacity + 2 * page), {}, {.PRIVATE, .ANONYMOUS})
	if err != nil {
		fail("guard allocation failed")
	}
	return {base, (cast([^]u8)base)[:capacity + 2 * page], page, capacity}
}

place :: proc(g: ^Guarded, data: []u8, right: bool) -> []u8 {
	area := rawptr(uintptr(g.base) + uintptr(g.page))
	if linux.mprotect(area, uint(g.capacity), {.READ, .WRITE}) != nil {
		fail("cannot prepare guarded input")
	}
	start := g.page
	if right {
		start += g.capacity - len(data)
	} else if len(data) == 0 {
		start -= 1
	}
	input := g.whole[start:start + len(data)]
	if len(data) != 0 {
		copy(input, data)
	}
	if linux.mprotect(area, uint(g.capacity), {.READ}) != nil {
		fail("cannot protect input against mutation")
	}
	return input
}

equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for byte, i in a {
		if byte != b[i] {
			return false
		}
	}
	return true
}

main :: proc() {
	if len(os.args) != 2 {
		fail("usage: request-parser-check FIXTURE")
	}
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		fail("cannot read fixture")
	}
	defer delete(data)
	if len(data) < 20 || string(data[:8]) != "ERSP001\x00" {
		fail("invalid fixture header")
	}
	at := 8
	page := int(u32_at(data, &at))
	count := int(u32_at(data, &at))
	maximum := int(u32_at(data, &at))
	if page <= 0 || page > 1048576 || maximum > 2097152 || count > 1000000 {
		fail("invalid fixture dimensions")
	}
	g := guarded(maximum, page)
	defer linux.munmap(g.base, uint(len(g.whole)))
	scratch: rp.Scratch
	defer rp.destroy(&scratch)
	owner: ^rp.Inline_Owner
	defer rp.inline_release(&owner)
	calls := 0
	for index in 0..<count {
		size := int(u32_at(data, &at))
		if at > len(data) - 4 {
			fail("truncated fixture flags")
		}
		flags, kind, fault, error_byte := data[at], data[at + 1], data[at + 2], data[at + 3]
		at += 4
		bulk_max := i64_at(data, &at)
		base := i64_at(data, &at)
		consumed := int(u32_at(data, &at))
		need := i64_at(data, &at)
		argc := int(u32_at(data, &at))
		if flags & 0x7e != 0 || kind > 2 || fault > 9 || size > maximum || argc > 2048 || at > len(data) - size {
			fail("invalid fixture record")
		}
		request := data[at:at + size]
		at += size
		expected: [2048][]u8
		for i in 0..<argc {
			n := int(u32_at(data, &at))
			if n > maximum || at > len(data) - n {
				fail("truncated expected argument")
			}
			expected[i] = data[at:at + n]
			at += n
		}
		limits := rp.Limits{bulk_max = bulk_max, base_offset = int(base), unauthenticated = flags & 0x80 != 0, unauth_array_max = 10, unauth_bulk_max = 16384}
		for arrangement in 0..<4 {
			side := arrangement & 1
			cold_scratch: rp.Scratch
			cold_owner: ^rp.Inline_Owner
			defer rp.destroy(&cold_scratch)
			defer rp.inline_release(&cold_owner)
			active_scratch := &scratch
			active_owner := &owner
			if arrangement < 2 {
				active_scratch = &cold_scratch
				active_owner = &cold_owner
			}
			input := place(&g, request, side == 1)
			result: rp.Result
			if flags & 1 != 0 {
				result = rp.parse_inline(input, active_scratch, active_owner, limits)
			} else {
				result = rp.parse_array(input, active_scratch, limits)
			}
			calls += 1
			if u8(result.kind) != kind || u8(result.fault) != fault || result.error_byte != error_byte || (kind == 1 && (result.consumed != consumed || result.argc != argc)) || (kind == 0 && result.consumed != 0) || (need >= 0 && result.need != int(need)) {
				fmt.eprintf("case=%d side=%d kind=%v fault=%v byte=%d consumed=%d argc=%d need=%d expected_kind=%d expected_fault=%d expected_byte=%d expected_consumed=%d expected_argc=%d expected_need=%d\n", index, side, result.kind, result.fault, result.error_byte, result.consumed, result.argc, result.need, kind, fault, error_byte, consumed, argc, need)
				os.exit(1)
			}
			if !equal(input, request) {
				fail("parser modified raw input")
			}
			if kind == 1 {
				if len(active_scratch.args) < argc {
					fail("argument storage is shorter than result")
				}
				for i in 0..<argc {
					if !equal(active_scratch.args[i], expected[i]) {
						fmt.eprintf("case=%d arrangement=%d argument=%d actual_length=%d expected_length=%d\n", index, arrangement, i, len(active_scratch.args[i]), len(expected[i]))
						os.exit(1)
					}
				}
			}
		}
	}
	if at != len(data) {
		fail("fixture trailing bytes")
	}
	fmt.printf("cases=%d readonly_guard_calls=%d failures=0\n", count, calls)
}

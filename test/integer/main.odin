package main

import integer "../../src/integer"

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:sys/linux"

check :: proc(input: []u8, expected: i64, accepted: bool, index: int, placement: string) {
	actual, ok := integer.parse_i64(input)
	if actual != expected || ok != accepted {
		fmt.eprintf("case=%d placement=%s length=%d expected=%d/%v actual=%d/%v\n", index, placement, len(input), expected, accepted, actual, ok)
		os.exit(1)
	}
}

main :: proc() {
	assert(len(os.args) == 2)
	data, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(data)
	assert(len(data) >= 16)
	assert(string(data[:8]) == "EINTv1\x00\x00")
	page_u32, page_ok := endian.get_u32(data[8:12], .Little)
	count, count_ok := endian.get_u32(data[12:16], .Little)
	assert(page_ok && count_ok && page_u32 >= 1024)
	page := int(page_u32)
	region, map_err := linux.mmap(0, uint(page * 3), {}, {.PRIVATE, .ANONYMOUS})
	assert(map_err == nil)
	defer linux.munmap(region, uint(page * 3))
	middle := rawptr(uintptr(region) + uintptr(page))
	assert(linux.mprotect(middle, uint(page), {.READ, .WRITE}) == nil)
	buffer := ([^]u8)(middle)[:page]
	checks := 0
	guarded := 0
	at := 16
	for index in 0 ..< int(count) {
		assert(at + 13 <= len(data))
		size, size_ok := endian.get_u32(data[at:at + 4], .Little)
		expected, expected_ok := endian.get_i64(data[at + 5:at + 13], .Little)
		assert(size_ok && expected_ok && data[at + 4] <= 1)
		accepted := data[at + 4] == 1
		at += 13
		assert(int(size) <= len(data) - at)
		input := data[at:at + int(size)]
		check(input, expected, accepted, index, "corpus")
		checks += 1
		if len(input) <= page {
			left := buffer[:len(input)]
			copy(left, input)
			check(left, expected, accepted, index, "left-guard")
			right := buffer[page - len(input):]
			copy(right, input)
			check(right, expected, accepted, index, "right-guard")
			checks += 2
			guarded += 2
		}
		at += int(size)
	}
	assert(at == len(data))
	fmt.printf("cases=%d checks=%d guarded=%d\n", count, checks, guarded)
}

package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:sys/linux"
import glob "../../src/glob"

Guarded_Buffer :: struct {
	mapping:  rawptr,
	whole:    []u8,
	page:     int,
	capacity: int,
}

fail :: proc(message: string) -> ! {
	fmt.eprintln(message)
	os.exit(1)
}

read_u32 :: proc(data: []u8, offset: ^int) -> u32 {
	if offset^ > len(data) - 4 {
		fail("truncated fixture integer")
	}
	value, ok := endian.get_u32(data[offset^:offset^ + 4], .Little)
	if !ok {
		fail("invalid fixture integer")
	}
	offset^ += 4
	return value
}

make_guarded :: proc(maximum_size, page: int) -> Guarded_Buffer {
	capacity := max(page, ((maximum_size + page - 1) / page) * page)
	total := capacity + 2 * page
	mapping, error := linux.mmap(0, uint(total), {}, {.PRIVATE, .ANONYMOUS})
	if error != nil {
		fail("guard mmap failed")
	}
	whole := (cast([^]u8)mapping)[:total]
	area := rawptr(uintptr(mapping) + uintptr(page))
	if linux.mprotect(area, uint(capacity), {.READ, .WRITE}) != nil {
		fail("guard mprotect failed")
	}
	return Guarded_Buffer{mapping, whole, page, capacity}
}

place :: proc(buffer: ^Guarded_Buffer, source: []u8, right: bool) -> []u8 {
	start := buffer.page
	if right {
		start += buffer.capacity - len(source)
	} else if len(source) == 0 {
		start -= 1
	}
	result := buffer.whole[start:start + len(source)]
	if len(source) != 0 {
		copy(result, source)
	}
	return result
}

main :: proc() {
	if len(os.args) != 2 {
		fail("usage: glob-check FIXTURE")
	}
	data, error := os.read_entire_file(os.args[1], context.allocator)
	if error != nil {
		fail("cannot read fixture")
	}
	defer delete(data)
	magic := "EGLOB001"
	if len(data) < 20 {
		fail("truncated fixture header")
	}
	for c, i in magic {
		if data[i] != u8(c) {
			fail("invalid fixture magic")
		}
	}
	offset := 8
	page := int(read_u32(data, &offset))
	count := int(read_u32(data, &offset))
	maximum_size := int(read_u32(data, &offset))
	if page <= 0 || page > 1048576 || maximum_size > 100000 || count > 1000000 {
		fail("invalid fixture dimensions")
	}
	pattern_buffer := make_guarded(maximum_size, page)
	defer linux.munmap(pattern_buffer.mapping, uint(len(pattern_buffer.whole)))
	text_buffer := make_guarded(maximum_size, page)
	defer linux.munmap(text_buffer.mapping, uint(len(text_buffer.whole)))

	calls := u64(0)
	for case_index in 0..<count {
		pattern_length := int(read_u32(data, &offset))
		text_length := int(read_u32(data, &offset))
		if pattern_length > maximum_size || text_length > maximum_size || offset >= len(data) {
			fail("invalid fixture record lengths")
		}
		flags := data[offset]
		offset += 1
		if flags > 3 || pattern_length + text_length > len(data) - offset {
			fail("truncated fixture record")
		}
		pattern_source := data[offset:offset + pattern_length]
		offset += pattern_length
		text_source := data[offset:offset + text_length]
		offset += text_length
		for pattern_side in 0..<2 {
			for text_side in 0..<2 {
				pattern := place(&pattern_buffer, pattern_source, pattern_side == 1)
				text := place(&text_buffer, text_source, text_side == 1)
				for mode in 0..<2 {
					nocase := mode == 1
					expected := (flags & (u8(1) << u8(mode))) != 0
					actual := glob.glob_match(pattern, text, nocase)
					calls += 1
					if actual != expected {
						fmt.eprintf("case=%d pattern_side=%d text_side=%d nocase=%v expected=%v actual=%v\n", case_index, pattern_side, text_side, nocase, expected, actual)
						os.exit(1)
					}
				}
			}
		}
	}
	if offset != len(data) {
		fail("unexpected trailing fixture bytes")
	}
	fmt.printf("cases=%d guard_placements=%d calls=%d failures=0\n", count, u64(count) * 4, calls)
}

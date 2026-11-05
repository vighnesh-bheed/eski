package bitmap

import "core:testing"

expect_bitfield_changes :: proc(t: ^testing.T, buffer: ^[]u8, capacity: ^int, words: []string, count, length: int) {
	arguments := make([][]u8, len(words))
	defer delete(arguments)
	for word, i in words { arguments[i] = transmute([]u8)word }
	program: Bitfield_Program
	defer bitfield_program_destroy(&program)
	testing.expect_value(t, bitfield_parse(&program, arguments, false, 1 << 20), Error.None)
	changes, err := bitfield_execute(buffer, &program, RAW_HEAP_ALLOCATOR, capacity)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, changes, count)
	testing.expect_value(t, len(buffer^), length)
}

@(test)
bitfield_counts_growth_and_actual_bit_changes_instead_of_successful_noops :: proc(t: ^testing.T) {
	buffer: []u8
	capacity: int
	defer free_bytes(&buffer, RAW_HEAP_ALLOCATOR, &capacity)
	expect_bitfield_changes(t, &buffer, &capacity, []string{"SET", "u8", "0", "1"}, 1, 1)
	expect_bitfield_changes(t, &buffer, &capacity, []string{"INCRBY", "u8", "0", "0"}, 0, 1)
	expect_bitfield_changes(t, &buffer, &capacity, []string{"INCRBY", "u8", "0", "256"}, 0, 1)
	expect_bitfield_changes(t, &buffer, &capacity, []string{"OVERFLOW", "SAT", "INCRBY", "u8", "0", "1000"}, 1, 1)
	expect_bitfield_changes(t, &buffer, &capacity, []string{"OVERFLOW", "SAT", "INCRBY", "u8", "0", "1000"}, 0, 1)
	expect_bitfield_changes(t, &buffer, &capacity, []string{"INCRBY", "i8", "0", "0"}, 0, 1)
	expect_bitfield_changes(t, &buffer, &capacity, []string{"SET", "u8", "0", "255", "SET", "u8", "8", "0"}, 2, 2)
	free_bytes(&buffer, RAW_HEAP_ALLOCATOR, &capacity)
	expect_bitfield_changes(t, &buffer, &capacity, []string{"OVERFLOW", "FAIL", "INCRBY", "u8", "80", "1000"}, 0, 11)
}

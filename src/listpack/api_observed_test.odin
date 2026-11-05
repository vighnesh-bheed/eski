package listpack

import "core:testing"

api_observed_pack :: proc() -> [^]u8 {
	return test_pack([]Element{entry_from_bytes(transmute([]u8)string("a")), entry_from_bytes(nil), entry_from_int(0), entry_from_int(-7), entry_from_bytes(transmute([]u8)string("01")), entry_from_bytes(transmute([]u8)string("a\x00b"))})
}

@(test)
observed_getters_preserve_unselected_outputs_and_trailing_buffer_bytes :: proc(t: ^testing.T) {
	lp := api_observed_pack()
	defer lp_free(lp)
	values := [6]string{"a", "", "0", "-7", "01", "a\x00b"}
	integers := [6]i64{0, 0, 0, -7, 0, 0}
	for value, index in values {
		p := lp_seek(lp, i64(index))
		is_integer := index == 2 || index == 3
		count := i64(7777)
		s := lp_get(p, &count, nil)
		testing.expect(t, (s == nil) == is_integer)
		testing.expect(t, count == integers[index] if is_integer else count == i64(len(value)))
		if s != nil {
			testing.expect(t, string(s[:int(count)]) == value)
		}
		buffer: [DECIMAL_BUFFER_BYTES]u8
		for _, position in buffer {
			buffer[position] = 238
		}
		s = lp_get(p, &count, raw_data(buffer[:]))
		testing.expect(t, s != nil && count == i64(len(value)) && string(s[:int(count)]) == value)
		testing.expect(t, buffer[len(value)] == 238)
		testing.expect(t, buffer[0] == 238 if !is_integer else buffer[0] == value[0])
		slen := u32(8888)
		lval := i64(9999)
		s = lp_get_value(p, &slen, &lval)
		testing.expect(t, (s == nil) == is_integer)
		testing.expect(t, slen == 8888 && lval == integers[index] if is_integer else slen == u32(len(value)) && lval == 9999)
		integer, is_number := lp_integer_at(p)
		testing.expect(t, is_number == is_integer)
		testing.expect(t, integer == integers[index] if is_integer else integer == 0)
	}
	wire := [10]u8{10, 0, 0, 0, 1, 0, 129, '1', 2, 255}
	value, is_number := lp_integer_at(lp_first(raw_data(wire[:])))
	testing.expect(t, !is_number && value == 0)
	testing.expect(t, lp_compare(lp_first(raw_data(wire[:])), transmute([]u8)string("1")))
}

@(test)
observed_find_matrix_uses_literal_offsets :: proc(t: ^testing.T) {
	lp := api_observed_pack()
	defer lp_free(lp)
	Fixture :: struct { skip: u32, input: string, offset: int }
	fixtures := []Fixture{
		{0, "a", 6},
		{0, "", 9},
		{0, "0", 11},
		{0, "00", -1},
		{0, "-7", 13},
		{0, "01", 16},
		{0, "a\x00b", 20},
		{0, "missing", -1},
		{1, "a", 6},
		{1, "", -1},
		{1, "0", 11},
		{1, "00", -1},
		{1, "-7", -1},
		{1, "01", 16},
		{1, "a\x00b", -1},
		{1, "missing", -1},
		{2, "a", 6},
		{2, "", -1},
		{2, "0", -1},
		{2, "00", -1},
		{2, "-7", 13},
		{2, "01", -1},
		{2, "a\x00b", -1},
		{2, "missing", -1},
		{4294967295, "a", 6},
		{4294967295, "", -1},
		{4294967295, "0", -1},
		{4294967295, "00", -1},
		{4294967295, "-7", -1},
		{4294967295, "01", -1},
		{4294967295, "a\x00b", -1},
		{4294967295, "missing", -1},
	}
	for fixture in fixtures {
		found := lp_find(lp, lp_first(lp), transmute([]u8)fixture.input, fixture.skip)
		if fixture.offset < 0 {
			testing.expect(t, found == nil)
		} else {
			testing.expect(t, found == padd(lp, fixture.offset))
		}
	}
}

normalize_repr_addresses :: proc(value: string) -> string {
	output := make([dynamic]u8)
	position := 0
	for position < len(value) {
		prefix :: "\taddr: "
		if len(value) - position >= len(prefix) && value[position:position + len(prefix)] == prefix {
			append(&output, ..transmute([]u8)string("\taddr: <pointer>"))
			for position < len(value) && value[position] != ',' {
				position += 1
			}
		} else {
			append(&output, value[position])
			position += 1
		}
	}
	return string(output[:])
}

@(test)
observed_binary_representation_matches_normalized_literal :: proc(t: ^testing.T) {
	lp := api_observed_pack()
	defer lp_free(lp)
	value := lp_repr(lp)
	defer delete(value)
	normalized := normalize_repr_addresses(value)
	defer delete(normalized)
	expected :: "{total bytes 26} {num entries 6}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  0,\x0a\x09offset: 6,\x0a\x09hdr+entrylen+backlen:  3,\x0a\x09hdrlen:   1,\x0a\x09backlen:  1,\x0a\x09payload: 1\x0a\x09bytes: 81|61|02|\x0a\x09[str]a\x0a}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  1,\x0a\x09offset: 9,\x0a\x09hdr+entrylen+backlen:  2,\x0a\x09hdrlen:   1,\x0a\x09backlen:  1,\x0a\x09payload: 0\x0a\x09bytes: 80|01|\x0a\x09[str]\x0a}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  2,\x0a\x09offset: 11,\x0a\x09hdr+entrylen+backlen:  2,\x0a\x09hdrlen:   1,\x0a\x09backlen:  1,\x0a\x09payload: 0\x0a\x09bytes: 00|01|\x0a\x09[str]0\x0a}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  3,\x0a\x09offset: 13,\x0a\x09hdr+entrylen+backlen:  3,\x0a\x09hdrlen:   1,\x0a\x09backlen:  1,\x0a\x09payload: 1\x0a\x09bytes: df|f9|02|\x0a\x09[str]-7\x0a}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  4,\x0a\x09offset: 16,\x0a\x09hdr+entrylen+backlen:  4,\x0a\x09hdrlen:   1,\x0a\x09backlen:  1,\x0a\x09payload: 2\x0a\x09bytes: 82|30|31|03|\x0a\x09[str]01\x0a}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  5,\x0a\x09offset: 20,\x0a\x09hdr+entrylen+backlen:  5,\x0a\x09hdrlen:   1,\x0a\x09backlen:  1,\x0a\x09payload: 3\x0a\x09bytes: 83|61|00|62|04|\x0a\x09[str]a\x00b\x0a}\x0a{end}\x0a\x0a"
	testing.expect(t, normalized == expected)
}

@(test)
empty_batch_extension_preserves_pack_capacity_and_output_cursor :: proc(t: ^testing.T) {
	lp := api_observed_pack()
	defer lp_free(lp)
	before := lp_dup(lp)
	defer lp_free(before)
	capacity := lp_malloc_size(lp)
	cursor := lp_seek(lp, 2)
	old_cursor := cursor
	result := lp_splice_entries(lp, nil, lp_first(lp), Placement.Before, &cursor)
	testing.expect(t, result == lp && cursor == old_cursor && lp_malloc_size(lp) == capacity)
	testing.expect(t, string(lp_view(lp)) == string(lp_view(before)))
	result = lp_append_entries(lp, nil)
	testing.expect(t, result == lp && lp_malloc_size(lp) == capacity && string(lp_view(lp)) == string(lp_view(before)))
	result = lp_batch_delete(lp, nil)
	testing.expect(t, result == lp && lp_malloc_size(lp) == capacity && string(lp_view(lp)) == string(lp_view(before)))
}

@(test)
empty_repr_and_zero_range_preserve_exact_observed_behavior :: proc(t: ^testing.T) {
	lp := lp_new(4096)
	representation := lp_repr(lp)
	testing.expect(t, representation == "{total bytes 7} {num entries 0}\n{end}\n\n")
	delete(representation)
	capacity := lp_malloc_size(lp)
	result := lp_delete_range(lp, 0, 0)
	testing.expect(t, result == lp && lp_malloc_size(lp) == capacity)
	lp_free(lp)
}

@(test)
find_nil_start_uses_first_entry :: proc(t: ^testing.T) {
	lp := api_observed_pack()
	defer lp_free(lp)
	testing.expect(t, lp_find(lp, nil, transmute([]u8)string(""), 0) == padd(lp, 9))
	testing.expect(t, lp_find(lp, nil, transmute([]u8)string("01"), 0) == lp_seek(lp, 4))
}

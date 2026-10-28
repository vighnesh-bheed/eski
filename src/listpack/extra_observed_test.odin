package listpack

import "core:testing"

@(test)
observed_large_repr_previews_raw_bytes_and_recounts_unknown_header :: proc(t: ^testing.T) {
	Fixture :: struct { size: int, expected: string }
	fixtures := []Fixture{
		{0, "{total bytes 9} {num entries 1}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  0,\x0a\x09offset: 6,\x0a\x09hdr+entrylen+backlen:  2,\x0a\x09hdrlen:   1,\x0a\x09backlen:  1,\x0a\x09payload: 0\x0a\x09bytes: 80|01|\x0a\x09[str]\x0a}\x0a{end}\x0a\x0a"},
		{1, "{total bytes 10} {num entries 1}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  0,\x0a\x09offset: 6,\x0a\x09hdr+entrylen+backlen:  3,\x0a\x09hdrlen:   1,\x0a\x09backlen:  1,\x0a\x09payload: 1\x0a\x09bytes: 81|00|02|\x0a\x09[str]\x00\x0a}\x0a{end}\x0a\x0a"},
		{63, "{total bytes 72} {num entries 1}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  0,\x0a\x09offset: 6,\x0a\x09hdr+entrylen+backlen: 65,\x0a\x09hdrlen:   1,\x0a\x09backlen:  1,\x0a\x09payload: 63\x0a\x09bytes: bf|00|01|02|03|04|05|06|07|08|09|0a|0b|0c|0d|0e|0f|10|11|12|13|14|15|16|17|18|19|1a|1b|1c|1d|1e|1f|20|21|22|23|24|25|26|27|28|29|2a|2b|2c|2d|2e|2f|30|31|32|33|34|35|36|37|38|39|3a|3b|3c|3d|3e|40|\x0a\x09[str]\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'...\x0a}\x0a{end}\x0a\x0a"},
		{64, "{total bytes 74} {num entries 1}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  0,\x0a\x09offset: 6,\x0a\x09hdr+entrylen+backlen: 67,\x0a\x09hdrlen:   2,\x0a\x09backlen:  1,\x0a\x09payload: 64\x0a\x09bytes: e0|40|00|01|02|03|04|05|06|07|08|09|0a|0b|0c|0d|0e|0f|10|11|12|13|14|15|16|17|18|19|1a|1b|1c|1d|1e|1f|20|21|22|23|24|25|26|27|28|29|2a|2b|2c|2d|2e|2f|30|31|32|33|34|35|36|37|38|39|3a|3b|3c|3d|3e|3f|42|\x0a\x09[str]\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'...\x0a}\x0a{end}\x0a\x0a"},
		{100, "{total bytes 110} {num entries 1}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  0,\x0a\x09offset: 6,\x0a\x09hdr+entrylen+backlen: 103,\x0a\x09hdrlen:   2,\x0a\x09backlen:  1,\x0a\x09payload: 100\x0a\x09bytes: e0|64|00|01|02|03|04|05|06|07|08|09|0a|0b|0c|0d|0e|0f|10|11|12|13|14|15|16|17|18|19|1a|1b|1c|1d|1e|1f|20|21|22|23|24|25|26|27|28|29|2a|2b|2c|2d|2e|2f|30|31|32|33|34|35|36|37|38|39|3a|3b|3c|3d|3e|3f|40|41|42|43|44|45|46|47|48|49|4a|4b|4c|4d|4e|4f|50|51|52|53|54|55|56|57|58|59|5a|5b|5c|5d|5e|5f|60|61|62|63|66|\x0a\x09[str]\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'...\x0a}\x0a{end}\x0a\x0a"},
		{256, "{total bytes 267} {num entries 1}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  0,\x0a\x09offset: 6,\x0a\x09hdr+entrylen+backlen: 260,\x0a\x09hdrlen:   2,\x0a\x09backlen:  2,\x0a\x09payload: 256\x0a\x09bytes: e1|00|00|01|02|03|04|05|06|07|08|09|0a|0b|0c|0d|0e|0f|10|11|12|13|14|15|16|17|18|19|1a|1b|1c|1d|1e|1f|20|21|22|23|24|25|26|27|28|29|2a|2b|2c|2d|2e|2f|30|31|32|33|34|35|36|37|38|39|3a|3b|3c|3d|3e|3f|40|41|42|43|44|45|46|47|48|49|4a|4b|4c|4d|4e|4f|50|51|52|53|54|55|56|57|58|59|5a|5b|5c|5d|5e|5f|60|61|62|63|64|65|66|67|68|69|6a|6b|6c|6d|6e|6f|70|71|72|73|74|75|76|77|78|79|7a|7b|7c|7d|7e|7f|80|81|82|83|84|85|86|87|88|89|8a|8b|8c|8d|8e|8f|90|91|92|93|94|95|96|97|98|99|9a|9b|9c|9d|9e|9f|a0|a1|a2|a3|a4|a5|a6|a7|a8|a9|aa|ab|ac|ad|ae|af|b0|b1|b2|b3|b4|b5|b6|b7|b8|b9|ba|bb|bc|bd|be|bf|c0|c1|c2|c3|c4|c5|c6|c7|c8|c9|ca|cb|cc|cd|ce|cf|d0|d1|d2|d3|d4|d5|d6|d7|d8|d9|da|db|dc|dd|de|df|e0|e1|e2|e3|e4|e5|e6|e7|e8|e9|ea|eb|ec|ed|ee|ef|f0|f1|f2|f3|f4|f5|f6|f7|f8|f9|fa|fb|fc|fd|fe|ff|02|82|\x0a\x09[str]\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'...\x0a}\x0a{end}\x0a\x0a"},
		{300, "{total bytes 311} {num entries 1}\x0a{\x0a\x09addr: <pointer>,\x0a\x09index:  0,\x0a\x09offset: 6,\x0a\x09hdr+entrylen+backlen: 304,\x0a\x09hdrlen:   2,\x0a\x09backlen:  2,\x0a\x09payload: 300\x0a\x09bytes: e1|2c|00|01|02|03|04|05|06|07|08|09|0a|0b|0c|0d|0e|0f|10|11|12|13|14|15|16|17|18|19|1a|1b|1c|1d|1e|1f|20|21|22|23|24|25|26|27|28|29|2a|2b|2c|2d|2e|2f|30|31|32|33|34|35|36|37|38|39|3a|3b|3c|3d|3e|3f|40|41|42|43|44|45|46|47|48|49|4a|4b|4c|4d|4e|4f|50|51|52|53|54|55|56|57|58|59|5a|5b|5c|5d|5e|5f|60|61|62|63|64|65|66|67|68|69|6a|6b|6c|6d|6e|6f|70|71|72|73|74|75|76|77|78|79|7a|7b|7c|7d|7e|7f|80|81|82|83|84|85|86|87|88|89|8a|8b|8c|8d|8e|8f|90|91|92|93|94|95|96|97|98|99|9a|9b|9c|9d|9e|9f|a0|a1|a2|a3|a4|a5|a6|a7|a8|a9|aa|ab|ac|ad|ae|af|b0|b1|b2|b3|b4|b5|b6|b7|b8|b9|ba|bb|bc|bd|be|bf|c0|c1|c2|c3|c4|c5|c6|c7|c8|c9|ca|cb|cc|cd|ce|cf|d0|d1|d2|d3|d4|d5|d6|d7|d8|d9|da|db|dc|dd|de|df|e0|e1|e2|e3|e4|e5|e6|e7|e8|e9|ea|eb|ec|ed|ee|ef|f0|f1|f2|f3|f4|f5|f6|f7|f8|f9|fa|fb|fc|fd|fe|ff|00|01|02|03|04|05|06|07|08|09|0a|0b|0c|0d|0e|0f|10|11|12|13|14|15|16|17|18|19|1a|1b|1c|1d|1e|1f|20|21|22|23|24|25|26|27|28|29|2a|2b|02|ae|\x0a\x09[str]\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f !\"#$%&'...\x0a}\x0a{end}\x0a\x0a"},
	}
	for fixture in fixtures {
		payload := make([]u8, fixture.size)
		for _, index in payload {
			payload[index] = u8(index)
		}
		lp := test_pack([]Entry{entry_from_bytes(payload)})
		lp_set_num_elements(lp, LP_HDR_NUMELE_UNKNOWN)
		representation := lp_repr(lp)
		normalized := normalize_repr_addresses(representation)
		testing.expect(t, normalized == fixture.expected && lp_get_num_elements(lp) == 1)
		delete(normalized)
		delete(representation)
		lp_free(lp)
		delete(payload)
	}
}

@(test)
observed_actual_shrinks_release_spare_capacity_while_same_size_keeps_it :: proc(t: ^testing.T) {
	for operation in 0..<6 {
		lp := lp_new(4096)
		lp = lp_append(lp, transmute([]u8)string("a"))
		lp = lp_append(lp, transmute([]u8)string("b"))
		lp = lp_append(lp, transmute([]u8)string("c"))
		before := lp_malloc_size(lp)
		switch operation {
		case 0:
			lp = lp_delete(lp, lp_first(lp), nil)
		case 1:
			lp = lp_delete_range(lp, 0, 2)
		case 2:
			positions := [2][^]u8{lp_first(lp), lp_seek(lp, 1)}
			lp = lp_batch_delete(lp, positions[:])
		case 3:
			cursor := lp_first(lp)
			lp = lp_replace(lp, &cursor, nil)
		case 4:
			lp = lp_shrink_to_fit(lp)
		case 5:
			cursor := lp_first(lp)
			lp = lp_replace(lp, &cursor, transmute([]u8)string("d"))
		}
		if operation < 5 {
			reference := lp_dup(lp)
			testing.expect(t, lp_malloc_size(lp) < before && lp_malloc_size(lp) == lp_malloc_size(reference))
			lp_free(reference)
		} else {
			testing.expect(t, lp_malloc_size(lp) == before)
		}
		testing.expect(t, lp_validate_integrity(lp, u64(lp_bytes(lp)), true, nil, nil))
		lp_free(lp)
	}
}

@(test)
size_estimates_saturate_only_when_mathematical_result_is_unrepresentable :: proc(t: ^testing.T) {
	for value in ([]i64{0, -1, 127, 128, 4096, min(i64), max(i64)}) {
		width := u64(lp_entry_size_integer(value))
		maximum_representable := (u64(max(int)) - 7) / width
		testing.expect(t, lp_estimate_bytes_repeated_integer(value, maximum_representable) == 7 + int(maximum_representable * width))
		testing.expect(t, lp_estimate_bytes_repeated_integer(value, maximum_representable + 1) == max(int))
		testing.expect(t, lp_estimate_bytes_repeated_integer(value, max(u64)) == max(int))
	}
}

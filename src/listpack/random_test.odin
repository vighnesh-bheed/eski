package listpack

import "core:testing"

random_tuple_pack :: proc(tuple_len: int) -> [^]u8 {
	lp := lp_new(0)
	values := [4]string{"v0", "v1", "v2", "v3"}
	for value, index in values {
		lp = lp_append_integer(lp, i64((index + 1) * 10))
		lp = lp_append(lp, transmute([]u8)value)
		if tuple_len == 3 {
			lp = lp_append_integer(lp, 999)
		}
	}
	return lp
}

expect_sample_pair :: proc(t: ^testing.T, key, val: Element) {
	values := [4]string{"v0", "v1", "v2", "v3"}
	testing.expect(t, key.text == nil && key.number >= 10 && key.number <= 40 && key.number % 10 == 0)
	if key.text != nil || key.number < 10 || key.number > 40 || key.number % 10 != 0 {
		return
	}
	testing.expect(t, val.text != nil && string(val.text[:int(val.text_len)]) == values[int(key.number / 10) - 1])
}

@(test)
seeded_sampling_preserves_draw_order_unique_pack_order_and_tuple_alignment :: proc(t: ^testing.T) {
	for seed in ([]u64{0, 1, 1234, max(u64)}) {
		lp_srand(seed)
		sequence: [16]u32
		for _, index in sequence {
			sequence[index] = lp_rand()
			testing.expect(t, sequence[index] <= 2147483647)
		}
		lp_srand(seed)
		for value in sequence {
			testing.expect(t, lp_rand() == value)
		}
	}
	for tuple_len in 2..=3 {
		lp := random_tuple_pack(tuple_len)
		keys, vals: [32]Element
		lp_srand(1234)
		lp_random_pairs(lp, len(keys), keys[:], vals[:], tuple_len)
		for key, index in keys {
			expect_sample_pair(t, key, vals[index])
		}
		lp_srand(1234)
		repeated_keys, repeated_vals: [32]Element
		lp_random_pairs(lp, len(keys), repeated_keys[:], repeated_vals[:], tuple_len)
		for key, index in keys {
			testing.expect(t, repeated_keys[index].number == key.number && repeated_vals[index].text == vals[index].text)
		}
		for requested in ([]int{0, 1, 3, 4, 6}) {
			for _, index in keys {
				keys[index] = entry_from_int(555)
				vals[index] = entry_from_int(555)
			}
			written := lp_random_pairs_unique(lp, requested, keys[:], vals[:], tuple_len)
			testing.expect(t, written == min(requested, 4))
			previous := i64(0)
			for index in 0..<written {
				expect_sample_pair(t, keys[index], vals[index])
				testing.expect(t, keys[index].number > previous)
				previous = keys[index].number
			}
			testing.expect(t, keys[written].number == 555 && vals[written].number == 555)
		}
		for _ in 0..<32 {
			key, val: Element
			lp_random_pair(lp, 4, &key, &val, tuple_len)
			expect_sample_pair(t, key, val)
		}
		for remaining in ([]u32{1, 2, 4}) {
			index := u32(0)
			cursor := lp_next_random(lp, lp_first(lp), &index, remaining, tuple_len)
			testing.expect(t, index % u32(tuple_len) == 0 && index / u32(tuple_len) <= 4 - remaining)
			testing.expect(t, cursor == lp_seek(lp, i64(index)))
			if remaining == 4 {
				testing.expect(t, index == 0 && cursor == lp_first(lp))
			}
		}
		index := u32(0)
		cursor := lp_first(lp)
		for remaining := u32(4); remaining > 0; remaining -= 1 {
			cursor = lp_next_random(lp, cursor, &index, remaining, tuple_len)
			testing.expect(t, cursor == lp_seek(lp, i64((4 - remaining) * u32(tuple_len))))
			for _ in 0..<tuple_len {
				cursor = lp_next(lp, cursor)
			}
			index += u32(tuple_len)
		}
		lp_free(lp)
	}
	lp := test_pack([]Element{entry_from_bytes(transmute([]u8)string("a")), entry_from_bytes(transmute([]u8)string("b")), entry_from_bytes(transmute([]u8)string("c"))})
	samples: [64]Element
	lp_random_entries(lp, samples[:])
	for sample in samples {
		testing.expect(t, sample.text != nil && sample.text_len == 1 && sample.text[0] >= 'a' && sample.text[0] <= 'c')
	}
	lp_free(lp)
	empty := lp_new(0)
	keys := [1]Element{entry_from_int(555)}
	vals := [1]Element{entry_from_int(555)}
	lp_random_entries(empty, keys[:])
	lp_random_pairs(empty, 1, keys[:], vals[:], 2)
	testing.expect(t, lp_random_pairs_unique(empty, 1, keys[:], vals[:], 2) == 0 && keys[0].number == 555 && vals[0].number == 555)
	lp_free(empty)
	random_cursor_aligns_nonzero_start_and_keeps_incomplete_tail_candidate(t)
	sampling_without_values_preserves_draws_and_unique_pack_order(t)
}

random_cursor_aligns_nonzero_start_and_keeps_incomplete_tail_candidate :: proc(t: ^testing.T) {
	lp := test_pack([]Element{entry_from_bytes(transmute([]u8)string("a")), entry_from_bytes(transmute([]u8)string("b")), entry_from_bytes(transmute([]u8)string("c"))})
	defer lp_free(lp)
	for start in 0..<3 {
		index := u32(start)
		cursor := lp_next_random(lp, lp_seek(lp, i64(start)), &index, 10, 2)
		expected := 0 if start == 0 else 2
		testing.expect(t, cursor == lp_seek(lp, i64(expected)) && index == u32(expected))
	}
	index := u32(2)
	cursor := lp_seek(lp, 2)
	index = 2
	cursor = lp_next_random(lp, lp_seek(lp, 2), &index, 1, 2)
	testing.expect(t, cursor == lp_seek(lp, 2) && index == 2)
}

sampling_without_values_preserves_draws_and_unique_pack_order :: proc(t: ^testing.T) {
	lp := random_tuple_pack(2)
	defer lp_free(lp)
	key: Element
	lp_srand(321)
	lp_random_pair(lp, 4, &key, nil, 2)
	testing.expect(t, key.text == nil && key.number >= 10 && key.number <= 40 && key.number % 10 == 0)
	with_keys, with_vals, without_vals: [8]Element
	lp_srand(321)
	lp_random_pairs(lp, 8, with_keys[:], with_vals[:], 2)
	lp_srand(321)
	lp_random_pairs(lp, 8, without_vals[:], nil, 2)
	for sampled, index in with_keys {
		testing.expect(t, without_vals[index].number == sampled.number)
	}
	written := lp_random_pairs_unique(lp, 6, without_vals[:], nil, 2)
	testing.expect(t, written == 4)
	for index in 0..<written {
		testing.expect(t, without_vals[index].number == i64((index + 1) * 10))
	}
}

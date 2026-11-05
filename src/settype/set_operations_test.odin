package settype

import "core:testing"
import lp "../listpack"
import rdb "../rdb"

text_bytes :: proc(s: string) -> []u8 {
	return raw_data(s)[:len(s)]
}

integer_value :: proc(n: i64) -> Member {
	return {number = n, numeric = true}
}

release_pending_maintenance :: proc() {
	for maintenance_pending() {
		if maintenance_release() == 0 {
			break
		}
	}
}

integer_set_with_encoding :: proc(enc: Encoding, n: int) -> Set {
	s := create_intset()
	for i in 0 ..< n {
		add_aux(s, integer_value(i64(i)))
	}
	if enc != s.encoding {
		convert(s, enc)
	}
	return s
}

@(test)
algebra_models :: proc(t: ^testing.T) {
	for enc in Encoding {
		a := integer_set_with_encoding(enc, 20)
		b := create_listpack()
		for i in 10 ..< 30 {
			add_aux(b, integer_value(i64(i)))
		}
		inputs := []Set{a, b, a}
		intersection := inter_store(inputs)
		testing.expect_value(t, size(intersection), 10)
		for i in 0 ..< 30 {
			testing.expect_value(t, is_member_aux(intersection, integer_value(i64(i))), i >= 10 && i < 20)
		}
		testing.expect_value(t, inter_card(inputs, 0), 10)
		testing.expect_value(t, inter_card(inputs, 4), 4)
		values := make([dynamic]Member)
		append(&values, integer_value(-1))
		testing.expect_value(t, inter_collect(inputs, &values), 10)
		testing.expect_value(t, len(values), 11)
		testing.expect(t, values[0].numeric && values[0].number == -1)
		delete(values)
		both := []Set{a, b}
		united := union_diff(both, .Union)
		difference := union_diff(both, .Diff)
		testing.expect_value(t, size(united), 30)
		testing.expect_value(t, size(difference), 10)
		for i in 0 ..< 30 {
			testing.expect(t, is_member_aux(united, integer_value(i64(i))))
			testing.expect_value(t, is_member_aux(difference, integer_value(i64(i))), i < 10)
		}
		with_missing := []Set{a, nil, b}
		testing.expect_value(t, inter_card(with_missing, 0), 0)
		aliased := []Set{a, a}
		empty := union_diff(aliased, .Diff)
		testing.expect_value(t, size(empty), 0)
		destroy(empty)
		destroy(intersection)
		destroy(united)
		destroy(difference)
		destroy(a)
		destroy(b)
	}
	release_pending_maintenance()
}

@(test)
algebra_binary_lifetimes :: proc(t: ^testing.T) {
	a := create_listpack()
	b := create_table(4)
	for member in ([][]u8{nil, text_bytes("01"), {0, 255, 0}, text_bytes("-0")}) {
		add(a, member)
		add(b, member)
	}
	inputs := []Set{a, b}
	result := inter_store(inputs)
	united := union_diff(inputs, .Union)
	destroy(a)
	destroy(b)
	testing.expect_value(t, size(result), 4)
	for member in ([][]u8{nil, text_bytes("01"), {0, 255, 0}, text_bytes("-0")}) {
		testing.expect(t, is_member(result, member) && is_member(united, member))
	}
	destroy(result)
	destroy(united)
	release_pending_maintenance()
}

@(test)
random_and_pop_complements :: proc(t: ^testing.T) {
	for enc in Encoding {
		for count in ([]int{1, 35, 65}) {
			s := integer_set_with_encoding(enc, 70)
			values: [dynamic]Member
			random_unique(s, 100, &values)
			testing.expect_value(t, len(values), 70)
			seen: [70]bool
			for value in values {
				buf: [21]u8
				n: i64
				testing.expect(t, lp.lp_string_to_int64(value_bytes(value, &buf), &n))
				testing.expect(t, !seen[n])
				seen[n] = true
			}
			clear(&values)
			random_with_repeats(s, 101, &values)
			testing.expect_value(t, len(values), 101)
			for value in values {
				testing.expect(t, is_member_aux(s, value))
			}
			delete(values)
			popped: Popped
			replacement := spop_count(s, count, &popped)
			remaining := s if replacement == nil else replacement
			testing.expect_value(t, size(remaining), 70 - count)
			testing.expect_value(t, popped_len(&popped), count)
			seen = {}
			for i in 0 ..< popped_len(&popped) {
				value := popped_get(&popped, i)
				testing.expect(t, !is_member_aux(remaining, value))
				buf: [21]u8
				n: i64
				lp.lp_string_to_int64(value_bytes(value, &buf), &n)
				testing.expect(t, !seen[n])
				seen[n] = true
			}
			for i in 0 ..< 70 {
				testing.expect_value(t, is_member_aux(remaining, integer_value(i64(i))), !seen[i])
			}
			destroy(s)
			if replacement != nil {
				destroy(replacement)
			}
			for i in 0 ..< popped_len(&popped) {
				buf: [21]u8
				testing.expect(t, len(value_bytes(popped_get(&popped, i), &buf)) > 0)
			}
			popped_reset(&popped)
			testing.expect_value(t, popped_len(&popped), 0)
			popped_destroy(&popped)
		}
	}
	release_pending_maintenance()
}

@(test)
popped_bytes_and_empty_helpers :: proc(t: ^testing.T) {
	s := create_listpack()
	for member in ([][]u8{nil, text_bytes("01"), {255, 0, 255}}) {
		add(s, member)
	}
	popped: Popped
	for size(s) > 0 {
		pop_random(s, &popped)
	}
	destroy(s)
	check := create_table(3)
	for i in 0 ..< popped_len(&popped) {
		buf: [21]u8
		add(check, value_bytes(popped_get(&popped, i), &buf))
	}
	testing.expect(t, is_member(check, nil) && is_member(check, text_bytes("01")) && is_member(check, []u8{255, 0, 255}))
	destroy(check)
	popped_destroy(&popped)
	empty := create_intset()
	values: [dynamic]Member
	random_unique(empty, 8, &values)
	random_with_repeats(empty, 8, &values)
	testing.expect_value(t, len(values), 0)
	testing.expect_value(t, scan(empty, max(u64), 1, &values), u64(0))
	delete(values)
	destroy(empty)
	release_pending_maintenance()
}

@(test)
scan_static_and_migrating :: proc(t: ^testing.T) {
	for enc in Encoding {
		s := integer_set_with_encoding(enc, 200)
		if enc == .Hashtable {
			table_resize(s.table, s.table.cap * 2)
		}
		seen: [200]bool
		cursor := u64(0)
		calls := 0
		for {
			values: [dynamic]Member
			cursor = scan(s, cursor, 3, &values)
			for value in values {
				buf: [21]u8
				n: i64
				testing.expect(t, lp.lp_string_to_int64(value_bytes(value, &buf), &n))
				seen[n] = true
			}
			delete(values)
			calls += 1
			if enc == .Hashtable && s.table.resize != nil {
				table_step(s.table, 7, 2)
			}
			if cursor == 0 {
				break
			}
			if calls > 10000 {
				testing.expect(t, false)
				break
			}
		}
		for found in seen {
			testing.expect(t, found)
		}
		destroy(s)
	}
	for mask in ([]u64{3, 7, 15, 255}) {
		cursor := u64(0)
		count := 0
		for {
			cursor = reverse_increment(cursor, mask)
			count += 1
			if cursor == 0 {
				break
			}
		}
		testing.expect_value(t, count, int(mask + 1))
	}
	release_pending_maintenance()
}

@(test)
codec_roundtrip_and_truncation :: proc(t: ^testing.T) {
	for enc in Encoding {
		s := integer_set_with_encoding(enc, 8)
		if enc == .Intset {
			add_aux(s, integer_value(min(i64)))
			remove_aux(s, integer_value(min(i64)))
		} else {
			add(s, nil)
			add(s, []u8{0, 255, 0})
			add(s, text_bytes("-0"))
		}
		if enc == .Hashtable {
			table_resize(s.table, s.table.cap * 2)
		}
		writer: rdb.Writer
		rdb.writer_init_mem(&writer, false, false)
		rdb_save(&writer, s)
		encoded := rdb.writer_bytes(&writer)
		reader: rdb.Reader
		rdb.reader_init_mem(&reader, encoded, false)
		loaded := rdb_load(&reader, int(rdb_type(s)), true)
		testing.expect(t, loaded != nil && reader.status == .Ok)
		testing.expect_value(t, size(loaded), size(s))
		it := iterator(s)
		for {
			value, ok := next(&it)
			if !ok {
				break
			}
			testing.expect(t, is_member_aux(loaded, value))
		}
		if enc == .Intset {
			testing.expect(t, set_bytes_equal(raw_bytes(loaded), raw_bytes(s)))
		}
		destroy(loaded)
		rdb.reader_destroy(&reader)
		for length in 0 ..< len(encoded) {
			rdb.reader_init_mem(&reader, encoded[:length], false)
			partial := rdb_load(&reader, int(rdb_type(s)), true)
			testing.expect(t, partial == nil)
			testing.expect(t, reader.status != .Ok)
			destroy(partial)
			rdb.reader_destroy(&reader)
		}
		rdb.writer_destroy(&writer)
		destroy(s)
	}
	release_pending_maintenance()
}

@(test)
intset_deep_validation :: proc(t: ^testing.T) {
	is := intset_new()
	for value in ([]i64{-1, 0, 1}) {
		is, _ = intset_add(is, value)
	}
	testing.expect(t, intset_validate(intset_bytes(is), true))
	intset_put(is, 1, -1)
	testing.expect(t, intset_validate(intset_bytes(is), false))
	testing.expect(t, !intset_validate(intset_bytes(is), true))
	intset_put(is, 1, -2)
	testing.expect(t, !intset_validate(intset_bytes(is), true))
	for n in 0 ..< intset_blob_len(is) {
		testing.expect(t, !intset_validate(is[:n], true))
	}
	intset_set_encoding(is, 3)
	testing.expect(t, !intset_validate(is[:14], false))
	lp.lp_mem_free(is)
}

@(test)
scan_shrink_and_bucket_contract :: proc(t: ^testing.T) {
	s := create_table(3000)
	for i in 0 ..< 200 {
		add_aux(s, integer_value(i64(i)))
	}
	table_resize(s.table, s.table.cap / 2)
	seen: [200]bool
	cursor := u64(0)
	for step in 0 ..< 10000 {
		values: [dynamic]Member
		cursor = scan(s, cursor, 2, &values)
		for value in values {
			buf: [21]u8
			n: i64
			testing.expect(t, lp.lp_string_to_int64(value_bytes(value, &buf), &n))
			seen[n] = true
		}
		delete(values)
		if s.table.resize != nil {
			table_step(s.table, 2, 1)
		}
		if cursor == 0 {
			break
		}
		testing.expect(t, step < 9999)
	}
	for found in seen {
		testing.expect(t, found)
	}
	for s.table.resize != nil {
		table_step(s.table, 64, 4)
	}
	for bucket in 0 ..< s.table.cap {
		values: [dynamic]Member
		sampled := slots_scan_bucket(s.table.slots, s.table.cap, u64(bucket), &values)
		testing.expect_value(t, sampled, len(values))
		for value in values {
			testing.expect_value(t, hash_member(value.text) & u64(s.table.cap - 1), u64(bucket))
		}
		delete(values)
	}
	destroy(s)
	release_pending_maintenance()
}

@(test)
codec_empty_and_corrupt_frames :: proc(t: ^testing.T) {
	for enc in Encoding {
		s := integer_set_with_encoding(enc, 0)
		writer: rdb.Writer
		rdb.writer_init_mem(&writer, false, false)
		rdb_save(&writer, s)
		reader: rdb.Reader
		rdb.reader_init_mem(&reader, rdb.writer_bytes(&writer), false)
		loaded := rdb_load(&reader, int(rdb_type(s)), true)
		testing.expect(t, loaded == nil)
		testing.expect_value(t, reader.status, rdb.Status.Corrupt if enc == .Intset else rdb.Status.Empty_Key)
		rdb.reader_destroy(&reader)
		rdb.writer_destroy(&writer)
		destroy(s)
	}
	for format in ([]int{rdb.TYPE_SET_INTSET, rdb.TYPE_SET_LISTPACK}) {
		for deep in ([]bool{false, true}) {
			bad := []u8{3, 0, 0, 0, 1, 0, 0, 0, 255}
			writer: rdb.Writer
			rdb.writer_init_mem(&writer, false, false)
			rdb.put_string(&writer, bad)
			reader: rdb.Reader
			rdb.reader_init_mem(&reader, rdb.writer_bytes(&writer), false)
			loaded := rdb_load(&reader, format, deep)
			testing.expect(t, loaded == nil)
			testing.expect_value(t, reader.status, .Corrupt)
			rdb.reader_destroy(&reader)
			rdb.writer_destroy(&writer)
		}
	}
}

@(test)
collectors_append_and_zero_scan :: proc(t: ^testing.T) {
	for encoding in Encoding {
		s := integer_set_with_encoding(encoding, 4)
		values: [dynamic]Member
		append(&values, integer_value(999))
		random_unique(s, 2, &values)
		testing.expect_value(t, len(values), 3)
		testing.expect(t, values[0].numeric && values[0].number == 999)
		random_with_repeats(s, 3, &values)
		testing.expect_value(t, len(values), 6)
		testing.expect(t, values[0].numeric && values[0].number == 999)
		clear(&values)
		append(&values, integer_value(999))
		next_cursor := scan(s, 0, 0, &values)
		testing.expect(t, values[0].numeric && values[0].number == 999)
		if encoding == .Hashtable {
			expected: [dynamic]Member
			sampled := slots_scan_bucket(s.table.slots, s.table.cap, 0, &expected)
			testing.expect_value(t, len(values), sampled + 1)
			testing.expect_value(t, next_cursor, reverse_increment(0, u64(s.table.cap - 1)))
			delete(expected)
		} else {
			testing.expect_value(t, len(values), 5)
			testing.expect_value(t, next_cursor, u64(0))
		}
		delete(values)
		destroy(s)
	}
	release_pending_maintenance()
}

@(test)
random_listpack_physical_order :: proc(t: ^testing.T) {
	s := create_listpack()
	for value in ([]i64{90, -3, 41, 0, 8, -99, 72, 6}) {
		add_aux(s, integer_value(value))
	}
	for count in 1 ..= size(s) {
		for _ in 0 ..< 20 {
			values: [dynamic]Member
			random_unique(s, count, &values)
			testing.expect_value(t, len(values), count)
			it := iterator(s)
			selected := 0
			for {
				value, ok := next(&it)
				if !ok {
					break
				}
				if selected < len(values) && values[selected].numeric && values[selected].number == value.number {
					selected += 1
				}
			}
			testing.expect_value(t, selected, count)
			delete(values)
		}
	}
	destroy(s)
}

@(test)
listpack_pop_order_and_encoding :: proc(t: ^testing.T) {
	old_limit := set_max_intset_entries
	defer {
		set_max_intset_entries = old_limit
	}
	for count in ([]int{3, 18}) {
		for _ in 0 ..< 10 {
			s := create_listpack()
			for index in 0 ..< 20 {
				add_aux(s, integer_value(i64(100 - index)))
			}
			set_max_intset_entries = 1000
			popped: Popped
			replacement := spop_count(s, count, &popped)
			remaining := s if replacement == nil else replacement
			testing.expect_value(t, remaining.encoding, .Listpack)
			testing.expect_value(t, popped_len(&popped), count)
			previous := i64(101)
			for index in 0 ..< popped_len(&popped) {
				value := popped_get(&popped, index)
				testing.expect(t, value.numeric && value.number < previous)
				previous = value.number
				testing.expect(t, !is_member_aux(remaining, value))
			}
			previous = 101
			it := iterator(remaining)
			for {
				value, ok := next(&it)
				if !ok {
					break
				}
				testing.expect(t, value.numeric && value.number < previous)
				previous = value.number
			}
			destroy(s)
			if replacement != nil {
				destroy(replacement)
			}
			popped_destroy(&popped)
		}
	}
	for _ in 0 ..< 10 {
		s := create_listpack()
		for text in ([]string{"first", "second", "third", "fourth", "fifth", "sixth"}) {
			add(s, text_bytes(text))
		}
		popped: Popped
		spop_count(s, 3, &popped)
		destroy(s)
		previous := -1
		for index in 0 ..< popped_len(&popped) {
			value := popped_get(&popped, index)
			found := -1
			for text, position in ([]string{"first", "second", "third", "fourth", "fifth", "sixth"}) {
				if set_bytes_equal(value.text, text_bytes(text)) {
					found = position
				}
			}
			testing.expect(t, found > previous)
			previous = found
		}
		popped_destroy(&popped)
	}
}

@(test)
intersection_initial_listpack_policy :: proc(t: ^testing.T) {
	old_int, old_pack := set_max_intset_entries, set_max_listpack_entries
	defer {
		set_max_intset_entries, set_max_listpack_entries = old_int, old_pack
	}
	for encoding in ([]Encoding{.Listpack, .Hashtable}) {
		left := create_listpack()
		for value in ([]i64{23, 2}) {
			add_aux(left, integer_value(value))
		}
		if encoding == .Hashtable {
			convert(left, .Hashtable)
		}
		right := create_listpack()
		for value in ([]i64{2, 23, 99}) {
			add_aux(right, integer_value(value))
		}
		set_max_intset_entries = 0
		set_max_listpack_entries = 128
		inputs := []Set{left, right}
		result := inter_store(inputs)
		testing.expect_value(t, result.encoding, .Listpack)
		testing.expect_value(t, size(result), 2)
		if encoding == .Listpack {
			it := iterator(result)
			first, _ := next(&it)
			second, _ := next(&it)
			testing.expect(t, first.numeric && first.number == 23 && second.numeric && second.number == 2)
		}
		destroy(result)
		set_max_intset_entries = 512
		result = inter_store(inputs)
		testing.expect_value(t, result.encoding, .Intset)
		destroy(result)
		destroy(left)
		destroy(right)
	}
	release_pending_maintenance()
}

@(test)
hashtable_pop_replacement_listpack :: proc(t: ^testing.T) {
	old_int, old_pack := set_max_intset_entries, set_max_listpack_entries
	defer {
		set_max_intset_entries, set_max_listpack_entries = old_int, old_pack
	}
	for limit in ([]int{0, 512}) {
		s := integer_set_with_encoding(.Hashtable, 70)
		set_max_intset_entries = limit
		set_max_listpack_entries = 128
		popped: Popped
		replacement := spop_count(s, 65, &popped)
		testing.expect(t, replacement != nil)
		if replacement != nil {
			testing.expect_value(t, replacement.encoding, .Listpack)
			testing.expect_value(t, size(replacement), 5)
			testing.expect_value(t, size(s), 65)
			for index in 0 ..< popped_len(&popped) {
				testing.expect(t, !is_member_aux(replacement, popped_get(&popped, index)))
			}
		}
		destroy(s)
		destroy(replacement)
		popped_destroy(&popped)
	}
	release_pending_maintenance()
}

@(test)
pop_strategy_integer_boundaries :: proc(t: ^testing.T) {
	for encoding in Encoding {
		for total in ([]int{6, 10}) {
			s := integer_set_with_encoding(encoding, total)
			popped: Popped
			replacement := spop_count(s, total - 1, &popped)
			testing.expect(t, replacement != nil)
			if replacement != nil {
				testing.expect_value(t, size(replacement), 1)
				testing.expect_value(t, size(s), total - 1)
				testing.expect_value(t, replacement.encoding, Encoding.Intset if encoding == .Intset else Encoding.Listpack)
				previous := min(i64)
				for index in 0 ..< popped_len(&popped) {
					value := popped_get(&popped, index)
					testing.expect(t, !is_member_aux(replacement, value))
					if encoding == .Intset {
						testing.expect(t, value.numeric && value.number > previous)
						previous = value.number
					}
				}
			}
			destroy(s)
			destroy(replacement)
			popped_destroy(&popped)
		}
	}
	release_pending_maintenance()
}

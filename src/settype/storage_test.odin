package settype

import "core:testing"
import lp "../listpack"

string_bytes :: proc(s: string) -> []u8 {
	return raw_data(s)[:len(s)]
}

reset_set_limits :: proc() {
	set_max_intset_entries = SET_MAX_INTSET_ENTRIES_DEFAULT
	set_max_listpack_entries = SET_MAX_LISTPACK_ENTRIES_DEFAULT
	set_max_listpack_value = SET_MAX_LISTPACK_VALUE_DEFAULT
}

drain_maintenance :: proc() {
	for maintenance_pending() {
		released := maintenance_release()
		if released == 0 {
			break
		}
	}
}

integer_member_bytes :: proc(n: i64, buffer: ^[lp.DECIMAL_BUFFER_BYTES]u8) -> []u8 {
	return value_bytes({number = n, numeric = true}, buffer)
}

@(test)
intset_boundary_and_wire :: proc(t: ^testing.T) {
	is := intset_new()
	values := []i64{0, -1, 32767, -32768, 32768, -32769, 2147483647, -2147483648, 2147483648, -2147483649, min(i64), max(i64)}
	for value, index in values {
		added: bool
		is, added = intset_add(is, value)
		testing.expect(t, added)
		testing.expect_value(t, intset_len(is), index + 1)
		testing.expect_value(t, intset_encoding(is), intset_value_encoding(value) if index > 3 else u32(2))
		previous := min(i64)
		for j in 0 ..< intset_len(is) {
			current := intset_get(is, j)
			testing.expect(t, current >= previous)
			previous = current
		}
	}
	testing.expect_value(t, intset_min(is), min(i64))
	testing.expect_value(t, intset_max(is), max(i64))
	testing.expect(t, set_bytes_equal(intset_bytes(is)[:8], []u8{8, 0, 0, 0, 12, 0, 0, 0}))
	duplicate := intset_dup(is)
	defer lp.lp_mem_free(duplicate)
	for value in values {
		before := is
		added: bool
		is, added = intset_add(is, value)
		testing.expect(t, !added && before == is)
		pos, found := intset_search(is, value)
		testing.expect(t, found && intset_get(is, pos) == value)
		removed: bool
		is, removed = intset_remove(is, value)
		testing.expect(t, removed)
		testing.expect_value(t, intset_encoding(is), u32(8))
		testing.expect(t, intset_find(duplicate, value))
	}
	testing.expect_value(t, intset_blob_len(is), 8)
	position, found := intset_search(is, 5)
	testing.expect(t, position == 0 && !found)
	lp.lp_mem_free(is)
}

@(test)
encodings_and_configuration :: proc(t: ^testing.T) {
	defer reset_set_limits()
	set_max_intset_entries = 2
	set_max_listpack_entries = 3
	set_max_listpack_value = 5
	s := create(string_bytes("1"), 2)
	defer destroy(s)
	testing.expect_value(t, s.encoding, .Intset)
	testing.expect(t, add(s, string_bytes("1")))
	testing.expect(t, add(s, string_bytes("-2")))
	set_max_intset_entries = 0
	testing.expect(t, !add(s, string_bytes("1")))
	testing.expect_value(t, s.encoding, .Intset)
	testing.expect(t, add(s, string_bytes("x")))
	testing.expect_value(t, s.encoding, .Listpack)
	it := iterator(s)
	first, _ := next(&it)
	second, _ := next(&it)
	third, _ := next(&it)
	testing.expect(t, first.numeric && first.number == -2 && second.numeric && second.number == 1)
	testing.expect(t, set_bytes_equal(third.text, string_bytes("x")))
	set_max_listpack_entries = 0
	set_max_listpack_value = 0
	testing.expect(t, !add(s, string_bytes("x")))
	testing.expect_value(t, s.encoding, .Listpack)
	testing.expect(t, add_aux(s, {number = 3, numeric = true}))
	testing.expect_value(t, s.encoding, .Hashtable)
	testing.expect(t, remove_aux(s, {number = -2, numeric = true}))
	testing.expect_value(t, s.encoding, .Hashtable)
	set_max_intset_entries = 2
	ints := create_intset()
	defer destroy(ints)
	for value in ([]i64{1, 2, 3}) {
		testing.expect(t, add_aux(ints, {number = value, numeric = true}))
	}
	testing.expect_value(t, ints.encoding, .Hashtable)
	testing.expect_value(t, size(ints), 3)
	set_max_intset_entries = max(int)
	testing.expect_value(t, intset_max_entries(), INTSET_ENTRY_CEILING)
	set_max_intset_entries = -1
	testing.expect_value(t, intset_max_entries(), 0)
}

@(test)
binary_conversion_and_copy :: proc(t: ^testing.T) {
	defer reset_set_limits()
	members := [][]u8{nil, string_bytes("0"), string_bytes("01"), string_bytes("+1"), string_bytes("-0"), string_bytes(" 1"), string_bytes("9223372036854775808"), {0, 255, 1, 0}}
	s := create_intset()
	for member in members {
		testing.expect(t, add(s, member))
	}
	testing.expect_value(t, size(s), len(members))
	testing.expect_value(t, s.encoding, .Listpack)
	pack_copy := dup(s)
	testing.expect(t, set_bytes_equal(raw_bytes(s), raw_bytes(pack_copy)))
	testing.expect(t, s.data != pack_copy.data)
	convert(s, .Hashtable)
	copy := dup(s)
	destroy(s)
	for member in members {
		testing.expect(t, is_member(copy, member))
		testing.expect(t, is_member(pack_copy, member))
	}
	for member in members {
		testing.expect(t, remove(copy, member))
	}
	testing.expect_value(t, size(copy), 0)
	testing.expect(t, add(copy, string_bytes("again")))
	destroy(copy)
	destroy(pack_copy)
	drain_maintenance()
	ints := create_listpack()
	for value in ([]i64{5, -9, 1, min(i64), max(i64)}) {
		add_aux(ints, {number = value, numeric = true})
	}
	maybe_convert_to_intset(ints)
	testing.expect_value(t, ints.encoding, .Intset)
	testing.expect_value(t, intset_min(ints.data), min(i64))
	testing.expect_value(t, intset_max(ints.data), max(i64))
	destroy(ints)
}

@(test)
model_and_iterator :: proc(t: ^testing.T) {
	defer reset_set_limits()
	set_hash_seed(0x72504)
	set_max_intset_entries = 12
	set_max_listpack_entries = 14
	s := create_intset()
	defer destroy(s)
	model: [257]bool
	state := u64(19)
	for operation in 0 ..< 10000 {
		state = state * 6364136223846793005 + 1442695040888963407
		index := int((state >> 24) % len(model))
		buffer: [lp.DECIMAL_BUFFER_BYTES]u8
		member := integer_member_bytes(i64(index - 128), &buffer)
		if operation % 3 == 0 {
			removed := remove(s, member)
			testing.expect_value(t, removed, model[index])
			model[index] = false
		} else {
			inserted := add(s, member)
			testing.expect_value(t, inserted, !model[index])
			model[index] = true
		}
		if operation % 71 == 0 {
			count := 0
			for expected, j in model {
				count += int(expected)
				probe_buffer: [lp.DECIMAL_BUFFER_BYTES]u8
				testing.expect_value(t, is_member(s, integer_member_bytes(i64(j - 128), &probe_buffer)), expected)
			}
			testing.expect_value(t, size(s), count)
		}
	}
	seen: [257]bool
	it := iterator(s)
	count := 0
	for {
		v, ok := next(&it)
		if !ok {
			break
		}
		integer := v.number
		testing.expect(t, v.numeric || lp.lp_string_to_int64(v.text, &integer))
		index := int(integer) + 128
		testing.expect(t, index >= 0 && index < len(model))
		testing.expect(t, model[index] && !seen[index])
		seen[index] = true
		count += 1
	}
	testing.expect_value(t, count, size(s))
	for _ in 0 ..< 5 {
		_, ok := next(&it)
		testing.expect(t, !ok)
	}
}

@(test)
resize_accounting_lifetimes :: proc(t: ^testing.T) {
	set_hash_seed(88)
	s := create_table(300)
	for number in 0 ..< 160 {
		buffer: [lp.DECIMAL_BUFFER_BYTES]u8
		add(s, integer_member_bytes(i64(number), &buffer))
	}
	tab := s.table
	borrowed := blob_bytes(table_find(tab, string_bytes("73"), hash_member(string_bytes("73"))).blob)
	pointer := raw_data(borrowed)
	table_resize(tab, tab.cap * 2)
	registry := Context{resize_epoch = 4}
	registry.owner = &registry
	maintenance_bind(s, &registry)
	testing.expect_value(t, registry.resize_count, 1)
	testing.expect(t, tab.resize.owner == s && tab.resize.reg == &registry)
	testing.expect_value(t, tab.resize.epoch, u64(4))
	blob_total := 0
	for bank in 0 ..< 2 {
		slots, capacity := table_bank(tab, bank)
		for index in 0 ..< capacity {
			if blob_live(slots[index].blob) {
				blob_total += lp.lp_malloc_size(slots[index].blob)
			}
		}
	}
	testing.expect_value(t, tab.blob_bytes, blob_total)
	expected_memory := lp.lp_malloc_size(s) + lp.lp_malloc_size(tab) + blob_total + slots_memory(tab.slots, tab.cap) + lp.lp_malloc_size(tab.resize) + slots_memory(tab.resize.old_slots, tab.resize.old_cap)
	testing.expect_value(t, memory_usage(s), expected_memory)
	old_slot := table_find(tab, string_bytes("17"), hash_member(string_bytes("17")))
	table_delete_at(tab, old_slot)
	testing.expect(t, old_slot.blob == TOMBSTONE)
	testing.expect(t, !is_member(s, string_bytes("17")))
	copy := dup(s)
	for tab.resize != nil {
		work := table_step(tab, 1, 1)
		testing.expect(t, work.scanned <= 1 && work.moved <= 1)
	}
	testing.expect_value(t, registry.resize_count, 0)
	testing.expect(t, set_bytes_equal(borrowed, string_bytes("73")))
	testing.expect(t, raw_data(blob_bytes(table_find(tab, string_bytes("73"), hash_member(string_bytes("73"))).blob)) == pointer)
	destroy(s)
	testing.expect_value(t, size(copy), 159)
	testing.expect(t, is_member(copy, string_bytes("73")))
	destroy(copy)
	drain_maintenance()
}

@(test)
retirement_and_aliasing :: proc(t: ^testing.T) {
	defer reset_set_limits()
	s := create_table(40)
	add(s, string_bytes("one"))
	add(s, string_bytes("two"))
	table_resize(s.table, s.table.cap * 2)
	registry := Context{resize_epoch = 10}
	registry.owner = &registry
	maintenance_bind(s, &registry)
	remove(s, string_bytes("one"))
	remove(s, string_bytes("two"))
	testing.expect_value(t, size(s), 0)
	testing.expect_value(t, registry.resize_count, 0)
	registry.resize_epoch += 1
	add(s, string_bytes("three"))
	table_resize(s.table, max(s.table.cap * 2, 8))
	maintenance_bind(s, &registry)
	testing.expect_value(t, s.table.resize.epoch, registry.resize_epoch)
	destroy(s)
	testing.expect_value(t, registry.resize_count, 0)
	drain_maintenance()
	pack := create_listpack()
	add(pack, string_bytes("abcdef"))
	it := iterator(pack)
	value, _ := next(&it)
	set_max_listpack_entries = 1
	testing.expect(t, add(pack, value.text[:3]))
	testing.expect_value(t, pack.encoding, .Hashtable)
	testing.expect(t, is_member(pack, string_bytes("abc")) && is_member(pack, string_bytes("abcdef")))
	destroy(pack)
	drain_maintenance()
}

@(test)
conversion_boundaries :: proc(t: ^testing.T) {
	defer reset_set_limits()
	set_max_intset_entries = 2
	set_max_listpack_entries = 3
	set_max_listpack_value = 3
	initial := create(string_bytes("too long for pack"), 3)
	testing.expect_value(t, initial.encoding, .Listpack)
	add(initial, string_bytes("too long for pack"))
	testing.expect_value(t, initial.encoding, .Hashtable)
	destroy(initial)
	for wide in ([]string{"32768", "-999"}) {
		s := create_intset()
		add(s, string_bytes(wide))
		add(s, string_bytes("x"))
		testing.expect_value(t, s.encoding, .Hashtable)
		destroy(s)
	}
	ints := create_intset()
	add(ints, string_bytes("1"))
	maybe_convert(ints, 2)
	testing.expect_value(t, ints.encoding, .Intset)
	maybe_convert(ints, 3)
	testing.expect_value(t, ints.encoding, .Hashtable)
	maybe_convert(ints, 0)
	testing.expect_value(t, ints.encoding, .Hashtable)
	destroy(ints)
	pack := create_listpack()
	add(pack, string_bytes("a"))
	maybe_convert(pack, 3)
	testing.expect_value(t, pack.encoding, .Listpack)
	maybe_convert(pack, 4)
	testing.expect_value(t, pack.encoding, .Hashtable)
	destroy(pack)
	set_max_intset_entries = 1
	set_max_listpack_value = 64
	integers := create_intset()
	add(integers, string_bytes("1"))
	add(integers, string_bytes("2"))
	testing.expect_value(t, integers.encoding, .Hashtable)
	set_max_intset_entries = 1
	maybe_convert_to_intset(integers)
	testing.expect_value(t, integers.encoding, .Hashtable)
	set_max_intset_entries = 2
	maybe_convert_to_intset(integers)
	testing.expect_value(t, integers.encoding, .Intset)
	destroy(integers)
	drain_maintenance()
}

@(test)
probe_holes_and_shrink :: proc(t: ^testing.T) {
	set_hash_seed(0x8877)
	s := create_table(40)
	members: [6][lp.DECIMAL_BUFFER_BYTES]u8
	lengths: [6]int
	found := 0
	for candidate in 0 ..< 10000 {
		buffer: [lp.DECIMAL_BUFFER_BYTES]u8
		member := integer_member_bytes(i64(candidate), &buffer)
		if hash_member(member) & u64(s.table.cap - 1) != u64(s.table.cap - 1) {
			continue
		}
		copy(members[found][:], member)
		lengths[found] = len(member)
		add(s, member)
		found += 1
		if found == len(members) {
			break
		}
	}
	testing.expect_value(t, found, len(members))
	for index in ([]int{2, 0, 5, 1, 4, 3}) {
		testing.expect(t, remove(s, members[index][:lengths[index]]))
		for j in 0 ..< len(members) {
			if lengths[j] != 0 && j != index {
				testing.expect(t, is_member(s, members[j][:lengths[j]]))
			}
		}
		lengths[index] = 0
	}
	destroy(s)
	drain_maintenance()
	shrink := create_table(40)
	for index in 0 ..< 10 {
		buffer: [lp.DECIMAL_BUFFER_BYTES]u8
		add(shrink, integer_member_bytes(i64(index), &buffer))
	}
	testing.expect_value(t, shrink.table.cap, 64)
	remove(shrink, string_bytes("0"))
	testing.expect_value(t, shrink.table.cap, 64)
	remove(shrink, string_bytes("1"))
	testing.expect_value(t, shrink.table.cap, 32)
	testing.expect(t, shrink.table.resize != nil)
	destroy(shrink)
	drain_maintenance()
}

@(test)
mapped_banks :: proc(t: ^testing.T) {
	drain_maintenance()
	before_mapped, before_retired, before_metadata := maintenance_memory()
	s := create_table(6000)
	add(s, string_bytes("mapped"))
	add(s, string_bytes("member"))
	testing.expect(t, s.table.cap > SLOTS_HEAP_LIMIT)
	table_resize(s.table, s.table.cap * 2)
	registry := Context{resize_epoch = 40}
	registry.owner = &registry
	maintenance_bind(s, &registry)
	testing.expect_value(t, memory_usage(s), lp.lp_malloc_size(s) + lp.lp_malloc_size(s.table) + s.table.blob_bytes + slots_memory(s.table.slots, s.table.cap) + lp.lp_malloc_size(s.table.resize) + slots_memory(s.table.resize.old_slots, s.table.resize.old_cap))
	remove(s, string_bytes("mapped"))
	remove(s, string_bytes("member"))
	testing.expect_value(t, registry.resize_count, 0)
	testing.expect_value(t, size(s), 0)
	destroy(s)
	drain_maintenance()
	after_mapped, after_retired, after_metadata := maintenance_memory()
	testing.expect_value(t, after_mapped, before_mapped)
	testing.expect_value(t, after_retired, before_retired)
	testing.expect_value(t, after_metadata, before_metadata)
}

@(test)
iterator_and_integer_values :: proc(t: ^testing.T) {
	for encoding in Encoding {
		s := create_intset()
		if encoding != .Intset {
			convert(s, encoding)
		}
		empty := iterator(s)
		_, exists := next(&empty)
		testing.expect(t, !exists)
		add_aux(s, {number = min(i64), numeric = true})
		_, exists = next(&empty)
		testing.expect(t, !exists)
		it := iterator(s)
		value, ok := next(&it)
		testing.expect(t, ok)
		buffer: [lp.DECIMAL_BUFFER_BYTES]u8
		testing.expect(t, set_bytes_equal(value_bytes(value, &buffer), string_bytes("-9223372036854775808")))
		for _ in 0 ..< 4 {
			_, exists = next(&it)
			testing.expect(t, !exists)
		}
		s.acct = 157
		duplicate := dup(s)
		testing.expect_value(t, duplicate.acct, 0)
		testing.expect_value(t, s.acct, 157)
		destroy(s)
		testing.expect(t, is_member_aux(duplicate, {number = min(i64), numeric = true}))
		destroy(duplicate)
	}
	drain_maintenance()
}

@(test)
configured_hints_and_sizing_guard :: proc(t: ^testing.T) {
	defer reset_set_limits()
	large_hint :: INTSET_ENTRY_CEILING + 1
	set_max_intset_entries = large_hint
	s := create(string_bytes("1"), large_hint)
	testing.expect_value(t, s.encoding, .Intset)
	testing.expect_value(t, size(s), 0)
	testing.expect(t, memory_usage(s) < 1024)
	maybe_convert(s, large_hint)
	testing.expect_value(t, s.encoding, .Intset)
	destroy(s)
	set_max_listpack_entries = large_hint
	pack := create(string_bytes("a"), large_hint)
	testing.expect_value(t, pack.encoding, .Listpack)
	testing.expect_value(t, size(pack), 0)
	maybe_convert(pack, large_hint)
	testing.expect_value(t, pack.encoding, .Listpack)
	testing.expect(t, memory_usage(pack) < 1024)
	destroy(pack)
	set_max_listpack_entries = max(int)
	set_max_listpack_value = max(int)
	is := intset_new()
	for value in ([]i64{min(i64), 0, max(i64)}) {
		is, _ = intset_add(is, value)
	}
	storage: [1]u8
	maximum_member_length :: lp.PACK_SIZE_CEILING - 37
	boundary := raw_data(storage[:])[:maximum_member_length]
	testing.expect(t, intset_can_append_listpack(is, boundary))
	testing.expect(t, !intset_can_append_listpack(is, raw_data(storage[:])[:maximum_member_length + 1]))
	testing.expect(t, !intset_can_append_listpack(is, raw_data(storage[:])[:max(int)]))
	lp.lp_mem_free(is)
	empty := intset_new()
	empty_boundary :: lp.PACK_SIZE_CEILING - 7
	testing.expect(t, intset_can_append_listpack(empty, raw_data(storage[:])[:empty_boundary]))
	testing.expect(t, !intset_can_append_listpack(empty, raw_data(storage[:])[:empty_boundary + 1]))
	lp.lp_mem_free(empty)
}

package settype

import lp "../listpack"
import "base:runtime"

SET_MAX_INTSET_ENTRIES_DEFAULT :: 512
SET_MAX_LISTPACK_ENTRIES_DEFAULT :: 128
SET_MAX_LISTPACK_VALUE_DEFAULT :: 64

set_max_intset_entries: int = SET_MAX_INTSET_ENTRIES_DEFAULT
set_max_listpack_entries: int = SET_MAX_LISTPACK_ENTRIES_DEFAULT
set_max_listpack_value: int = SET_MAX_LISTPACK_VALUE_DEFAULT

WRONGTYPE_ERROR :: "WRONGTYPE Operation against a key holding the wrong kind of value"

Encoding :: enum u8 {
	Intset,
	Listpack,
	Hashtable,
}

Set_Object :: struct {
	data:     [^]u8,
	table:    ^Table,
	acct:     int,
	encoding: Encoding,
}

Set :: ^Set_Object

Member :: struct {
	text:    []u8,
	number:  i64,
	numeric: bool,
}

Iterator :: struct {
	s:   Set,
	p:   [^]u8,
	idx: int,
	bank: int,
}

value_from_entry :: proc "contextless" (e: lp.Element) -> Member {
	if e.text == nil {
		return {number = e.number, numeric = true}
	}
	return {text = e.text[:int(e.text_len)]}
}

value_bytes :: proc "contextless" (v: Member, buf: ^[lp.DECIMAL_BUFFER_BYTES]u8) -> []u8 {
	if !v.numeric {
		return v.text
	}
	n := lp.ll2string(raw_data(buf[:]), v.number)
	return buf[:n]
}

encoding_name :: proc "contextless" (s: Set) -> string {
	switch s.encoding {
	case .Intset:
		return "intset"
	case .Listpack:
		return "listpack"
	case .Hashtable:
		return "hashtable"
	}
	return "unknown"
}

object_new :: proc "contextless" (enc: Encoding) -> Set {
	s := cast(Set)runtime.heap_alloc(size_of(Set_Object))
	resize_require(s != nil)
	s^ = {encoding = enc}
	return s
}

create_intset :: proc "contextless" () -> Set {
	s := object_new(.Intset)
	s.data = intset_new()
	return s
}

create_listpack :: proc "contextless" (capacity: int = 0) -> Set {
	s := object_new(.Listpack)
	s.data = lp.lp_new(capacity)
	resize_require(s.data != nil)
	return s
}

create_table :: proc "contextless" (expected: int) -> Set {
	s := object_new(.Hashtable)
	s.table = table_make(expected)
	return s
}

initial_encoding :: proc "contextless" (first: []u8, size_hint: int) -> Encoding {
	if size_hint <= set_max_intset_entries && lp.lp_string_to_int64(first, nil) {
		return .Intset
	}
	return .Listpack if size_hint <= set_max_listpack_entries else .Hashtable
}

create :: proc "contextless" (first: []u8, size_hint: int) -> Set {
	switch initial_encoding(first, size_hint) {
	case .Intset:
		return create_intset()
	case .Listpack:
		return create_listpack()
	case .Hashtable:
	}
	return create_table(size_hint)
}

release_storage :: proc "contextless" (s: Set) {
	switch s.encoding {
	case .Intset, .Listpack:
		lp.lp_mem_free(s.data)
	case .Hashtable:
		table_free(s.table)
	}
	s.data = nil
	s.table = nil
}

destroy :: proc "contextless" (s: Set) {
	if s != nil {
		release_storage(s)
		lp.lp_mem_free(s)
	}
}

size :: proc(s: Set) -> int {
	if s == nil {
		return 0
	}
	switch s.encoding {
	case .Intset:
		return intset_len(s.data)
	case .Listpack:
		return int(lp.lp_length(s.data))
	case .Hashtable:
		return s.table.count
	}
	return 0
}

memory_usage :: proc "contextless" (s: Set) -> int {
	if s == nil {
		return 0
	}
	storage := 0
	switch s.encoding {
	case .Intset, .Listpack:
		storage = lp.lp_malloc_size(s.data)
	case .Hashtable:
		storage = table_memory(s.table)
	}
	return lp.lp_malloc_size(s) + storage
}

raw_bytes :: proc "contextless" (s: Set) -> []u8 {
	switch s.encoding {
	case .Intset:
		return intset_bytes(s.data)
	case .Listpack:
		return lp.lp_view(s.data)
	case .Hashtable:
		return nil
	}
	return nil
}

iterator :: proc "contextless" (s: Set) -> Iterator {
	return {s = s}
}

next :: proc(it: ^Iterator) -> (v: Member, ok: bool) {
	if it.s == nil || it.idx < 0 {
		return {}, false
	}
	switch it.s.encoding {
	case .Intset:
		if it.idx < intset_len(it.s.data) {
			v = {number = intset_get(it.s.data, it.idx), numeric = true}
			it.idx += 1
			return v, true
		}
	case .Listpack:
		p := lp.lp_first(it.s.data) if it.idx == 0 else lp.lp_next(it.s.data, it.p)
		if p != nil {
			it.p = p
			it.idx += 1
			return value_from_entry(lp.lp_get_entry(p)), true
		}
	case .Hashtable:
		for it.bank < 2 {
			slots, capacity := table_bank(it.s.table, it.bank)
			for it.idx < capacity {
				b := slots[it.idx].blob
				it.idx += 1
				if blob_live(b) {
					return {text = blob_bytes(b)}, true
				}
			}
			it.bank += 1
			it.idx = 0
		}
	}
	it.idx = -1
	return {}, false
}

convert_and_expand :: proc(s: Set, enc: Encoding, cap: int) {
	if s.encoding == enc {
		return
	}
	replacement := object_new(enc)
	switch enc {
	case .Intset:
		replacement.data = intset_new()
	case .Listpack:
		replacement.data = lp.lp_new(cap)
		resize_require(replacement.data != nil)
	case .Hashtable:
		replacement.table = table_make(max(cap, size(s)))
	}
	it := iterator(s)
	for {
		v, ok := next(&it)
		if !ok {
			break
		}
		switch enc {
		case .Intset:
			integer := v.number
			resize_require(v.numeric || lp.lp_string_to_int64(v.text, &integer))
			replacement.data, _ = intset_add(replacement.data, integer)
		case .Listpack:
			if v.numeric {
				replacement.data = lp.lp_append_integer(replacement.data, v.number)
			} else {
				replacement.data = lp.lp_append(replacement.data, v.text)
			}
			resize_require(replacement.data != nil)
		case .Hashtable:
			buf: [lp.DECIMAL_BUFFER_BYTES]u8
			table_add_new(replacement.table, value_bytes(v, &buf))
		}
	}
	release_storage(s)
	s.data = replacement.data
	s.table = replacement.table
	s.encoding = enc
	lp.lp_mem_free(replacement)
}

convert :: proc(s: Set, enc: Encoding) {
	convert_and_expand(s, enc, size(s))
}

maybe_convert :: proc(s: Set, size_hint: int) {
	ceiling := set_max_intset_entries if s.encoding == .Intset else set_max_listpack_entries
	if s.encoding != .Hashtable && size_hint > ceiling {
		convert_and_expand(s, .Hashtable, size_hint)
	}
}

maybe_convert_intset :: proc(s: Set) {
	if s.encoding == .Intset && size(s) > intset_max_entries() {
		convert(s, .Hashtable)
	}
}

maybe_convert_to_intset :: proc(s: Set) {
	if s.encoding == .Intset || size(s) > intset_max_entries() {
		return
	}
	convert(s, .Intset)
}

intset_listpack_estimate :: proc "contextless" (is: [^]u8) -> (bytes: int, fits: bool) {
	members := intset_len(is)
	if members == 0 {
		return lp.PACK_HEADER_BYTES + 1, true
	}
	low, high := intset_min(is), intset_max(is)
	if int(max(lp.sdigits10(low), lp.sdigits10(high))) > set_max_listpack_value {
		return 0, false
	}
	per_low := lp.lp_estimate_bytes_repeated_integer(low, u64(members))
	per_high := lp.lp_estimate_bytes_repeated_integer(high, u64(members))
	return max(per_low, per_high), true
}

intset_can_append_listpack :: proc "contextless" (is: [^]u8, member: []u8) -> bool {
	if len(member) > set_max_listpack_value || intset_len(is) >= set_max_listpack_entries {
		return false
	}
	estimate := intset_listpack_estimate(is) or_return
	return len(member) <= max(int) - estimate && lp.lp_safe_to_add(nil, estimate + len(member))
}

set_convert_and_add :: proc(s: Set, enc: Encoding, member: []u8) -> bool {
	owned := lp.lp_malloc(max(1, len(member)))
	resize_require(owned != nil)
	copy(owned[:len(member)], member)
	defer lp.lp_mem_free(owned)
	convert(s, enc)
	return add_aux(s, {text = owned[:len(member)]})
}

add :: proc(s: Set, m: []u8) -> bool {
	return add_aux(s, {text = m})
}

add_to_intset :: proc(s: Set, v: Member, member: []u8) -> bool {
	number := v.number
	if !v.numeric && !lp.lp_string_to_int64(member, &number) {
		target := Encoding.Listpack if intset_can_append_listpack(s.data, member) else Encoding.Hashtable
		return set_convert_and_add(s, target, member)
	}
	inserted: bool
	s.data, inserted = intset_add(s.data, number)
	if !inserted {
		return false
	}
	maybe_convert_intset(s)
	return true
}

listpack_has_room :: proc(s: Set, member: []u8) -> bool {
	return size(s) < set_max_listpack_entries && len(member) <= set_max_listpack_value && lp.lp_safe_to_add(s.data, len(member))
}

add_to_listpack :: proc(s: Set, v: Member, member: []u8) -> bool {
	if lp.lp_find(s.data, lp.lp_first(s.data), member, 0) != nil {
		return false
	}
	if !listpack_has_room(s, member) {
		return set_convert_and_add(s, .Hashtable, member)
	}
	s.data = lp.lp_append_integer(s.data, v.number) if v.numeric else lp.lp_append(s.data, member)
	resize_require(s.data != nil)
	return true
}

add_aux :: proc(s: Set, v: Member) -> bool {
	scratch: [lp.DECIMAL_BUFFER_BYTES]u8
	member := value_bytes(v, &scratch)
	if s.encoding == .Hashtable {
		return table_add(s.table, member)
	}
	if s.encoding == .Intset {
		return add_to_intset(s, v, member)
	}
	return add_to_listpack(s, v, member)
}

remove :: proc(s: Set, m: []u8) -> bool {
	return remove_aux(s, {text = m})
}

remove_aux :: proc(s: Set, v: Member) -> bool {
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	member := value_bytes(v, &buf)
	switch s.encoding {
	case .Intset:
		integer := v.number
		if !v.numeric && !lp.lp_string_to_int64(member, &integer) {
			return false
		}
		removed: bool
		s.data, removed = intset_remove(s.data, integer)
		return removed
	case .Listpack:
		p := lp.lp_find(s.data, lp.lp_first(s.data), member, 0)
		if p == nil {
			return false
		}
		s.data = lp.lp_delete(s.data, p, nil)
		return true
	case .Hashtable:
		return table_delete(s.table, member)
	}
	return false
}

is_member :: proc(s: Set, m: []u8) -> bool {
	return is_member_aux(s, {text = m})
}

is_member_aux :: proc(s: Set, v: Member) -> bool {
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	member := value_bytes(v, &buf)
	switch s.encoding {
	case .Intset:
		integer := v.number
		if !v.numeric && !lp.lp_string_to_int64(member, &integer) {
			return false
		}
		return intset_find(s.data, integer)
	case .Listpack:
		return lp.lp_find(s.data, lp.lp_first(s.data), member, 0) != nil
	case .Hashtable:
		return table_contains(s.table, member)
	}
	return false
}

dup :: proc(s: Set) -> Set {
	copy := object_new(s.encoding)
	switch s.encoding {
	case .Intset:
		copy.data = intset_dup(s.data)
	case .Listpack:
		copy.data = lp.lp_dup(s.data)
		resize_require(copy.data != nil)
	case .Hashtable:
		copy.table = table_make(s.table.count)
		it := iterator(s)
		for {
			v, ok := next(&it)
			if !ok {
				break
			}
			table_add_new(copy.table, v.text)
		}
	}
	return copy
}

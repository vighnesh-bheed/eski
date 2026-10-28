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

Value :: struct {
	str:    []u8,
	ival:   i64,
	is_int: bool,
}

Iterator :: struct {
	s:   Set,
	p:   [^]u8,
	idx: int,
	bank: int,
}

value_from_entry :: proc "contextless" (e: lp.Entry) -> Value {
	if e.sval == nil {
		return {ival = e.lval, is_int = true}
	}
	return {str = e.sval[:int(e.slen)]}
}

value_bytes :: proc "contextless" (v: Value, buf: ^[lp.LP_INTBUF_SIZE]u8) -> []u8 {
	if !v.is_int {
		return v.str
	}
	n := lp.ll2string(raw_data(buf[:]), v.ival)
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

create :: proc "contextless" (first: []u8, size_hint: int) -> Set {
	if size_hint <= set_max_intset_entries && lp.lp_string_to_int64(first, nil) {
		return create_intset()
	}
	if size_hint <= set_max_listpack_entries {
		return create_listpack()
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

next :: proc(it: ^Iterator) -> (v: Value, ok: bool) {
	if it.s == nil || it.idx < 0 {
		return {}, false
	}
	switch it.s.encoding {
	case .Intset:
		if it.idx < intset_len(it.s.data) {
			v = {ival = intset_get(it.s.data, it.idx), is_int = true}
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
					return {str = blob_bytes(b)}, true
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
			integer := v.ival
			resize_require(v.is_int || lp.lp_string_to_int64(v.str, &integer))
			replacement.data, _ = intset_add(replacement.data, integer)
		case .Listpack:
			if v.is_int {
				replacement.data = lp.lp_append_integer(replacement.data, v.ival)
			} else {
				replacement.data = lp.lp_append(replacement.data, v.str)
			}
			resize_require(replacement.data != nil)
		case .Hashtable:
			buf: [lp.LP_INTBUF_SIZE]u8
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
	switch s.encoding {
	case .Intset:
		if size_hint > set_max_intset_entries {
			convert_and_expand(s, .Hashtable, size_hint)
		}
	case .Listpack:
		if size_hint > set_max_listpack_entries {
			convert_and_expand(s, .Hashtable, size_hint)
		}
	case .Hashtable:
	}
}

maybe_convert_intset :: proc(s: Set) {
	if s.encoding == .Intset && size(s) > intset_max_entries() {
		convert(s, .Hashtable)
	}
}

maybe_convert_to_intset :: proc(s: Set) {
	if s.encoding != .Intset && size(s) <= intset_max_entries() {
		convert(s, .Intset)
	}
}

intset_can_append_listpack :: proc "contextless" (is: [^]u8, member: []u8) -> bool {
	count := intset_len(is)
	if count >= set_max_listpack_entries || len(member) > set_max_listpack_value {
		return false
	}
	total := lp.LP_HDR_SIZE + 1
	if count > 0 {
		minimum := intset_min(is)
		maximum := intset_max(is)
		if int(lp.sdigits10(minimum)) > set_max_listpack_value || int(lp.sdigits10(maximum)) > set_max_listpack_value {
			return false
		}
		total = max(lp.lp_estimate_bytes_repeated_integer(minimum, u64(count)), lp.lp_estimate_bytes_repeated_integer(maximum, u64(count)))
	}
	if len(member) > max(int) - total {
		return false
	}
	return lp.lp_safe_to_add(nil, total + len(member))
}

set_convert_and_add :: proc(s: Set, enc: Encoding, member: []u8) -> bool {
	owned := lp.lp_malloc(max(1, len(member)))
	resize_require(owned != nil)
	copy(owned[:len(member)], member)
	defer lp.lp_mem_free(owned)
	convert(s, enc)
	return add_aux(s, {str = owned[:len(member)]})
}

add :: proc(s: Set, m: []u8) -> bool {
	return add_aux(s, {str = m})
}

add_aux :: proc(s: Set, v: Value) -> bool {
	buf: [lp.LP_INTBUF_SIZE]u8
	member := value_bytes(v, &buf)
	switch s.encoding {
	case .Intset:
		integer := v.ival
		if v.is_int || lp.lp_string_to_int64(member, &integer) {
			inserted: bool
			s.data, inserted = intset_add(s.data, integer)
			if inserted {
				maybe_convert_intset(s)
			}
			return inserted
		}
		enc := Encoding.Hashtable
		if intset_can_append_listpack(s.data, member) {
			enc = .Listpack
		}
		return set_convert_and_add(s, enc, member)
	case .Listpack:
		if lp.lp_find(s.data, lp.lp_first(s.data), member, 0) != nil {
			return false
		}
		if size(s) >= set_max_listpack_entries || len(member) > set_max_listpack_value || !lp.lp_safe_to_add(s.data, len(member)) {
			return set_convert_and_add(s, .Hashtable, member)
		}
		if v.is_int {
			s.data = lp.lp_append_integer(s.data, v.ival)
		} else {
			s.data = lp.lp_append(s.data, member)
		}
		resize_require(s.data != nil)
		return true
	case .Hashtable:
		return table_add(s.table, member)
	}
	return false
}

remove :: proc(s: Set, m: []u8) -> bool {
	return remove_aux(s, {str = m})
}

remove_aux :: proc(s: Set, v: Value) -> bool {
	buf: [lp.LP_INTBUF_SIZE]u8
	member := value_bytes(v, &buf)
	switch s.encoding {
	case .Intset:
		integer := v.ival
		if !v.is_int && !lp.lp_string_to_int64(member, &integer) {
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
	return is_member_aux(s, {str = m})
}

is_member_aux :: proc(s: Set, v: Value) -> bool {
	buf: [lp.LP_INTBUF_SIZE]u8
	member := value_bytes(v, &buf)
	switch s.encoding {
	case .Intset:
		integer := v.ival
		if !v.is_int && !lp.lp_string_to_int64(member, &integer) {
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
			table_add_new(copy.table, v.str)
		}
	}
	return copy
}

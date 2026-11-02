package hashtype

import lp "../listpack"

HASH_MAX_LISTPACK_ENTRIES_DEFAULT :: 512
HASH_MAX_LISTPACK_VALUE_DEFAULT :: 64
hash_max_listpack_entries: int = HASH_MAX_LISTPACK_ENTRIES_DEFAULT
hash_max_listpack_value: int = HASH_MAX_LISTPACK_VALUE_DEFAULT

Encoding :: enum u8 {
	Listpack,
	Listpack_Ex,
	Hashtable,
}

Hash_Object :: struct {
	lp: [^]u8,
	table: ^Table,
	hfe: ^Hfe_Meta,
	acct: int,
	encoding: Encoding,
}

Hash :: ^Hash_Object

Value :: struct {
	str: []u8,
	ival: i64,
	is_int: bool,
}

Field_Mark :: enum u8 {
	Live,
	Reaped,
	Emptied,
}

Field_Read :: bit_set[Field_Mark;u8]

value_from_entry :: #force_inline proc "contextless" (e: lp.Element) -> Value {
	if e.text == nil {
		return Value{ival = e.number, is_int = true}
	}
	return Value{str = e.text[:e.text_len]}
}

value_from_lp :: #force_inline proc "contextless" (p: [^]u8) -> Value {
	return value_from_entry(lp.lp_get_entry(p))
}

value_bytes :: proc "contextless" (v: Value, buf: ^[lp.DECIMAL_BUFFER_BYTES]u8) -> []u8 {
	if !v.is_int {
		return v.str
	}
	n := lp.ll2string(raw_data(buf[:]), v.ival)
	return buf[:n]
}

value_len :: #force_inline proc "contextless" (v: Value) -> int {
	if v.is_int {
		return int(lp.sdigits10(v.ival))
	}
	return len(v.str)
}

value_eq :: proc "contextless" (v: Value, s: []u8) -> bool {
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	return bytes_equal(value_bytes(v, &buf), s)
}

value_to_entry :: #force_inline proc "contextless" (v: Value) -> lp.Element {
	if v.is_int {
		return lp.entry_from_int(v.ival)
	}
	return lp.entry_from_bytes(v.str)
}

create :: proc "contextless" () -> Hash {
	h := cast(Hash)mem_alloc(size_of(Hash_Object))
	h.lp = lp.lp_new(0)
	return h
}

release_storage :: proc "contextless" (h: Hash) {
	maintenance_cancel(h)
	registry_remove(h)
	if h.encoding == .Hashtable {
		table_free(h.table)
	} else {
		lp.lp_free(h.lp)
	}
	h.lp = nil
	h.table = nil
}

destroy :: proc "contextless" (h: Hash) {
	if h == nil {
		return
	}
	release_storage(h)
	mem_free(h.hfe)
	mem_free(h)
}

reset :: proc "contextless" (h: Hash) {
	release_storage(h)
	mem_free(h.hfe)
	h.hfe = nil
	h.encoding = .Listpack
	h.lp = lp.lp_new(0)
}

encoding_name :: proc "contextless" (h: Hash) -> string {
	switch h.encoding {
	case .Hashtable:
		return "hashtable"
	case .Listpack_Ex:
		return "listpackex"
	case .Listpack:
		return "listpack"
	}
	unreachable()
}

memory_usage :: proc "contextless" (h: Hash) -> int {
	if h == nil {
		return 0
	}
	n := mem_usable_size(h) + mem_usable_size(h.hfe)
	if h.encoding == .Hashtable {
		n += table_memory(h.table)
	} else {
		n += lp.lp_malloc_size(h.lp)
	}
	return n
}

listpack_bytes :: proc "contextless" (h: Hash) -> []u8 {
	if h.encoding == .Hashtable {
		return nil
	}
	return lp.lp_view(h.lp)
}

pack_stride :: #force_inline proc "contextless" (h: Hash) -> int {
	if h.encoding == .Listpack_Ex {
		return 3
	}
	return 2
}

length :: #force_inline proc(h: Hash) -> int {
	if h == nil {
		return 0
	}
	if h.encoding == .Hashtable {
		return h.table.count
	}
	cached := lp.lp_get_num_elements(h.lp)
	if cached != lp.COUNT_UNTRACKED {
		return int(cached) / pack_stride(h)
	}
	return int(lp.lp_length(h.lp)) / pack_stride(h)
}

length_live :: proc(h: Hash, now: u64) -> int {
	if !is_registered(h) {
		return length(h)
	}
	n := 0
	it := iterator_live(h, now)
	for next(&it) {
		n += 1
	}
	return n
}

convert :: proc(h: Hash, presize: int = 0) {
	if h.encoding == .Hashtable {
		table_reserve(h.table, max(presize, length(h)))
		return
	}
	t := table_make(max(length(h), presize))
	it := iterator(h)
	for next(&it) {
		fb, vb: [lp.DECIMAL_BUFFER_BYTES]u8
		b := table_add_new(t, value_bytes(current_field(&it), &fb), value_bytes(current_value(&it), &vb))
		expiry := current_expire(&it)
		if expiry != DEADLINE_UNSET {
			vol_set(t, b, expiry)
		}
	}
	lp.lp_free(h.lp)
	h.lp = nil
	h.table = t
	h.encoding = .Hashtable
}

PACK_ENTRY_HEADROOM :: 16

pack_admits :: proc(h: Hash, args: [][]u8) -> bool {
	widest, growth := 0, 0
	for arg in args {
		widest = max(widest, len(arg))
		growth += len(arg) + PACK_ENTRY_HEADROOM
	}
	pairs := len(args) / 2
	return pairs <= hash_max_listpack_entries && widest <= hash_max_listpack_value && lp.lp_safe_to_add(h.lp, growth)
}

try_conversion :: proc(h: Hash, args: [][]u8) {
	if h.encoding != .Hashtable && !pack_admits(h, args) {
		convert(h, length(h) + len(args) / 2)
	}
}

lp_find_field :: #force_inline proc(zl: [^]u8, field: []u8, skip: u32) -> [^]u8 {
	return lp.lp_find(zl, pack_first(zl), field, skip)
}

get_raw :: proc(h: Hash, field: []u8) -> (v: Value, expire: u64, found: bool) {
	if h.encoding == .Hashtable {
		if s := table_find(h.table, field, hash_field(field)); s != nil {
			return Value{str = blob_value(s.blob)}, table_field_expire(h.table, s.blob), true
		}
	} else if h.encoding == .Listpack_Ex {
		_, vp, ttl, ok := lpex_locate(h, field)
		if ok {
			exp := DEADLINE_UNSET
			if ttl != 0 {
				exp = u64(ttl)
			}
			return value_from_lp(vp), exp, true
		}
	} else {
		if p := lp_find_field(h.lp, field, 1); p != nil {
			return value_from_lp(pack_next(p)), DEADLINE_UNSET, true
		}
	}
	return {}, DEADLINE_UNSET, false
}

reap_field :: proc(h: Hash, field: []u8) -> Field_Read {
	notify_field_expired(h, field)
	delete_field(h, field)
	if length(h) > 0 {
		return {.Reaped}
	}
	registry_remove(h)
	return {.Reaped, .Emptied}
}

get :: proc(h: Hash, field: []u8, now: u64, delete_expired := true) -> (v: Value, read: Field_Read) {
	stored, deadline, present := get_raw(h, field)
	switch {
	case !present:
		return
	case deadline >= now:
		return stored, {.Live}
	case delete_expired:
		read = reap_field(h, field)
	}
	return
}

exists :: proc(h: Hash, field: []u8, now: u64, delete_expired := true) -> (bool, Field_Read) {
	_, read := get(h, field, now, delete_expired)
	return .Live in read, read
}

field_strlen :: proc(h: Hash, field: []u8, now: u64, delete_expired := true) -> (n: int, read: Field_Read) {
	v: Value
	v, read = get(h, field, now, delete_expired)
	if .Live in read {
		n = value_len(v)
	}
	return
}

set :: proc(h: Hash, field, value: []u8, keep_ttl := false) -> (updated: bool) {
	if h.encoding != .Hashtable {
		args := [2][]u8{field, value}
		try_conversion(h, args[:])
	}
	if h.encoding == .Hashtable {
		updated = table_set(h.table, field, value, keep_ttl)
	} else if h.encoding == .Listpack_Ex {
		fp, vp, ttl, ok := lpex_locate(h, field)
		if ok {
			if ttl != 0 && !keep_ttl {
				lpex_replace_value(h, fp, field, value, 0)
			} else {
				h.lp = lp.lp_replace(h.lp, &vp, value)
			}
			updated = true
		} else {
			lpex_add_new(h, field, value, 0)
		}
	} else {
		p := lp_find_field(h.lp, field, 1)
		if p != nil {
			vp := pack_next(p)
			h.lp = lp.lp_replace(h.lp, &vp, value)
			updated = true
		} else {
			ent := [2]lp.Element{lp.entry_from_bytes(field), lp.entry_from_bytes(value)}
			h.lp = lp.lp_batch_append(h.lp, ent[:])
		}
	}
	if h.encoding != .Hashtable && length(h) > hash_max_listpack_entries {
		convert(h)
	}
	return
}

hset :: proc(h: Hash, args: [][]u8) -> (created: int) {
	try_conversion(h, args)
	for i := 0; i + 1 < len(args); i += 2 {
		if !set(h, args[i], args[i + 1]) {
			created += 1
		}
	}
	return
}

hsetnx :: proc(h: Hash, field, value: []u8, now: u64) -> bool {
	_, read := get(h, field, now)
	if .Live in read {
		return false
	}
	if .Emptied in read {
		reset(h)
	}
	set(h, field, value)
	return true
}

delete_field :: proc(h: Hash, field: []u8) -> bool {
	removed := false
	if h.encoding == .Hashtable {
		removed = table_delete(h.table, field)
	} else {
		p := lp_find_field(h.lp, field, u32(pack_stride(h) - 1))
		if p != nil {
			h.lp = lp.lp_delete_range_with_entry(h.lp, &p, u64(pack_stride(h)))
			removed = true
		}
	}
	return removed
}

hdel :: proc(h: Hash, fields: [][]u8) -> (deleted: int, emptied: bool) {
	volatile := false
	for field in fields {
		if !volatile && is_registered(h) {
			_, expiry, found := get_raw(h, field)
			volatile = found && expiry != DEADLINE_UNSET
		}
		if delete_field(h, field) {
			deleted += 1
		}
	}
	emptied = length(h) == 0
	if emptied || (volatile && !fields_with_expire(h)) {
		registry_remove(h)
	}
	return
}

clone_table :: proc(h: Hash) -> ^Table {
	copied := table_make(length(h))
	rows := iterator(h)
	for next(&rows) {
		blob := table_add_new(copied, blob_field(rows.blob), blob_value(rows.blob))
		vol_set(copied, blob, current_expire(&rows))
	}
	return copied
}

duplicate :: proc(h: Hash) -> (d: Hash, min_expire: u64) {
	d = cast(Hash)mem_alloc(size_of(Hash_Object))
	d.encoding = h.encoding
	switch h.encoding {
	case .Hashtable:
		d.table = clone_table(h)
	case .Listpack, .Listpack_Ex:
		d.lp = lp.lp_dup(h.lp)
	}
	if h.encoding == .Listpack_Ex || (h.encoding == .Hashtable && h.hfe != nil) {
		ensure_meta(d)
	}
	return d, registered_expire(h)
}

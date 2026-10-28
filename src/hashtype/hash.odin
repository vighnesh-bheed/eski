package hashtype

import lp "../listpack"

OBJ_HASH_KEY :: 1
OBJ_HASH_VALUE :: 2
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

Get_Result :: enum u8 {
	Ok,
	Not_Found,
	Expired,
	Expired_Hash,
}

value_from_entry :: #force_inline proc "contextless" (e: lp.Entry) -> Value {
	if e.sval == nil {
		return Value{ival = e.lval, is_int = true}
	}
	return Value{str = e.sval[:e.slen]}
}

value_from_lp :: #force_inline proc "contextless" (p: [^]u8) -> Value {
	return value_from_entry(lp.lp_get_entry(p))
}

value_bytes :: proc "contextless" (v: Value, buf: ^[lp.LP_INTBUF_SIZE]u8) -> []u8 {
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
	buf: [lp.LP_INTBUF_SIZE]u8
	return bytes_equal(value_bytes(v, &buf), s)
}

value_to_entry :: #force_inline proc "contextless" (v: Value) -> lp.Entry {
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

tuple_len :: #force_inline proc "contextless" (h: Hash) -> int {
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
	if cached != lp.LP_HDR_NUMELE_UNKNOWN {
		return int(cached) / tuple_len(h)
	}
	return int(lp.lp_length(h.lp)) / tuple_len(h)
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
		fb, vb: [lp.LP_INTBUF_SIZE]u8
		b := table_add_new(t, value_bytes(current_field(&it), &fb), value_bytes(current_value(&it), &vb))
		expiry := current_expire(&it)
		if expiry != EB_EXPIRE_TIME_INVALID {
			vol_set(t, b, expiry)
		}
	}
	lp.lp_free(h.lp)
	h.lp = nil
	h.table = t
	h.encoding = .Hashtable
}

try_conversion :: proc(h: Hash, args: [][]u8) {
	if h.encoding == .Hashtable {
		return
	}
	if len(args) / 2 > hash_max_listpack_entries {
		convert(h, length(h) + len(args) / 2)
		return
	}
	bytes := 0
	for arg in args {
		if len(arg) > hash_max_listpack_value {
			convert(h, length(h) + len(args) / 2)
			return
		}
		bytes += len(arg) + 16
	}
	if !lp.lp_safe_to_add(h.lp, bytes) {
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
			exp := EB_EXPIRE_TIME_INVALID
			if ttl != 0 {
				exp = u64(ttl)
			}
			return value_from_lp(vp), exp, true
		}
	} else {
		if p := lp_find_field(h.lp, field, 1); p != nil {
			return value_from_lp(pack_next(p)), EB_EXPIRE_TIME_INVALID, true
		}
	}
	return {}, EB_EXPIRE_TIME_INVALID, false
}

get :: proc(h: Hash, field: []u8, now: u64) -> (v: Value, res: Get_Result) {
	val, expiry, found := get_raw(h, field)
	if !found {
		return {}, .Not_Found
	}
	if expiry != EB_EXPIRE_TIME_INVALID && expiry < now {
		if field_expired_hook != nil {
			field_expired_hook(h, field)
		}
		delete_field(h, field)
		if length(h) == 0 {
			registry_remove(h)
			return {}, .Expired_Hash
		}
		return {}, .Expired
	}
	return val, .Ok
}

exists :: proc(h: Hash, field: []u8, now: u64) -> (bool, Get_Result) {
	_, res := get(h, field, now)
	return res == .Ok, res
}

field_strlen :: proc(h: Hash, field: []u8, now: u64) -> (int, Get_Result) {
	v, res := get(h, field, now)
	if res != .Ok {
		return 0, res
	}
	return value_len(v), res
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
			expiry := u64(0)
			if keep_ttl {
				expiry = u64(ttl)
			}
			lpex_replace_value(h, fp, field, value, expiry)
			updated = true
			_ = vp
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
			ent := [2]lp.Entry{lp.entry_from_bytes(field), lp.entry_from_bytes(value)}
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
	_, res := get(h, field, now)
	if res == .Ok {
		return false
	}
	if res == .Expired_Hash {
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
		p := lp_find_field(h.lp, field, u32(tuple_len(h) - 1))
		if p != nil {
			h.lp = lp.lp_delete_range_with_entry(h.lp, &p, u64(tuple_len(h)))
			removed = true
		}
	}
	return removed
}

hdel :: proc(h: Hash, fields: [][]u8) -> (deleted: int, emptied: bool) {
	for field in fields {
		if delete_field(h, field) {
			deleted += 1
		}
	}
	emptied = length(h) == 0
	if emptied || (deleted > 0 && !fields_with_expire(h)) {
		registry_remove(h)
	}
	return
}

duplicate :: proc(h: Hash) -> (d: Hash, min_expire: u64) {
	d = create()
	min_expire = registered_expire(h)
	if h.encoding != .Hashtable {
		lp.lp_free(d.lp)
		d.lp = lp.lp_dup(h.lp)
		d.encoding = h.encoding
		if h.encoding == .Listpack_Ex {
			ensure_meta(d)
		}
		return
	}
	convert(d, length(h))
	if h.hfe != nil {
		ensure_meta(d)
	}
	it := iterator(h)
	for next(&it) {
		b := table_add_new(d.table, current_field(&it).str, current_value(&it).str)
		expiry := current_expire(&it)
		if expiry != EB_EXPIRE_TIME_INVALID {
			vol_set(d.table, b, expiry)
		}
	}
	return
}

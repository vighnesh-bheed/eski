package main

import "base:intrinsics"
import ht "hashtype"
import ld "ldfloat"
import lp "listpack"


ERR_WRONGTYPE :: ht.WRONGTYPE_ERROR

FIELD_SWEEP_BATCH :: 1000

hash_db_next: int

hash_tick_due: i64

stat_expired_subkeys: i64

@(private)
hash_ints: [dynamic]i64

@(private)
hash_fields: [dynamic]ht.Value

@(private)
hash_values: [dynamic]ht.Value

@(private)
hash_expired: [dynamic]ht.Expired_Hash

@(private)
hash_ldbuf: [ld.MAX_LONG_DOUBLE_CHARS]u8

@(cold)
reply_wrongtype :: #force_no_inline proc(c: ^Conn) {
	reply_error(c, ERR_WRONGTYPE)
}

entry_is_string :: #force_inline proc "contextless" (e: ^Entry) -> bool {
	return e.kp.small.tag.val_form != FORM_OBJECT
}

hash_store_init :: proc() {
	ht.set_hash_seed(rng_next())
	lp.lp_srand(rng_next())
	ht.field_expired_hook = aof_hash_field_expired
}

@(private)
hash_now :: #force_inline proc "contextless" () -> u64 {
	return u64(expire_now())
}

@(private)
hash_obj_encoding :: #force_inline proc "contextless" (h: ht.Hash) -> Obj_Encoding {
	switch h.encoding {
	case .Listpack:
		return .Listpack
	case .Listpack_Ex:
		return .Listpack_Ex
	case .Hashtable:
		return .Hashtable
	}
	return .Listpack
}

@(private)
hash_key_ref_free :: proc "contextless" (h: ht.Hash) {
	k := ht.key_ref(h)
	if k != nil {
		intrinsics.atomic_sub_explicit(&storage_metadata_owned, (^int)(k)^ + 16, .Relaxed)
		mem_free(k)
		ht.set_key_ref(h, nil)
	}
}

@(private)
hash_key_ref_new :: proc "contextless" (key: []u8, registry: ^ht.Registry) -> rawptr {
	n := len(key)
	p := mem_alloc(n + 16)
	if p == nil { store_fatal("out of memory") }
	intrinsics.atomic_add_explicit(&storage_metadata_owned, n + 16, .Relaxed)
	(^int)(p)^ = n
	(^^ht.Registry)(rawptr(uintptr(p) + 8))^ = registry
	if n > 0 { intrinsics.mem_copy_non_overlapping(&p[16], raw_data(key), n) }
	return p
}

@(private)
hash_key_ref_bytes :: #force_inline proc "contextless" (ref: rawptr) -> []u8 {
	p := ([^]u8)(ref)
	return p[16:16 + (^int)(p)^]
}

hash_key_ref_registry :: proc "contextless" (ref: rawptr) -> ^ht.Registry {
	return (^^ht.Registry)(rawptr(uintptr(ref) + 8))^
}

hash_key_ref_move :: proc "contextless" (ref: rawptr, registry: ^ht.Registry) {
	if ref != nil { (^^ht.Registry)(rawptr(uintptr(ref) + 8))^ = registry }
}

object_release :: proc "contextless" (type: Obj_Type, obj: rawptr) -> int {
	if type == .Vectorset {
		return vset_object_release(obj)
	}
	if type != .Hash || obj == nil {
		return 0
	}
	h := ht.Hash(obj)
	n := h.acct
	hash_key_ref_free(h)
	ht.destroy(h)
	return n
}

object_move :: proc "contextless" (type: Obj_Type, obj: rawptr, from: ^Db, to: ^Db) -> int {
	if type == .Vectorset {
		return vset_object_acct(obj)
	}
	if type != .Hash || obj == nil {
		return 0
	}
	h := ht.Hash(obj)
	hash_move_registry(h, from, to)
	return h.acct
}

@(private)
hash_sort_buf: [lp.DECIMAL_BUFFER_BYTES]u8

hash_sort_field :: proc(key: []u8, e: ^Entry, field: []u8) -> (val: []u8, ok: bool) {
	h := ht.Hash(entry_object(e, .Hash))
	if h == nil {
		return nil, false
	}
	v, read := ht.get(h, field, hash_now(), !label_entry_foreign(e))
	if .Live not_in read {
		hash_lazy(key, e, h, read)
		return nil, false
	}
	return ht.value_bytes(v, &hash_sort_buf), true
}

hash_copy_dup :: proc(src: ^Entry) -> (obj: rawptr, min_expire: u64, ok: bool) {
	h := ht.Hash(entry_object(src, .Hash))
	if h == nil {
		return nil, ht.DEADLINE_UNSET, false
	}
	d, at := ht.duplicate(h)
	d.acct = ht.memory_usage(d)
	return d, at, true
}

hash_copy_attach :: proc(dst: ^Entry, key: []u8, obj: rawptr, min_expire: u64) {
	h := ht.Hash(obj)
	entry_object_attach(dst, h, .Hash, hash_obj_encoding(h), h.acct)
	ht.maintenance_bind(h, dst.db.hreg)
	if min_expire != ht.DEADLINE_UNSET {
		ht.set_key_ref(h, hash_key_ref_new(key, dst.db.hreg))
		ht.registry_add(dst.db.hreg, h, min_expire)
	}
}

c_atoi :: proc "contextless" (s: []u8) -> i64 {
	i := 0
	for i < len(s) && (s[i] == ' ' || (s[i] >= '\t' && s[i] <= '\r')) {
		i += 1
	}
	neg := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		neg = s[i] == '-'
		i += 1
	}
	v: i64 = 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + i64(s[i] - '0')
		i += 1
	}
	return -v if neg else v
}

hash_memory :: proc "contextless" (obj: rawptr) -> int {
	return ht.memory_usage(ht.Hash(obj))
}

hash_subexpiry :: proc "contextless" (db: ^Db) -> int {
	return ht.registry_len(db.hreg)
}

@(private)
hash_sync :: #force_inline proc "contextless" (db: ^Db, h: ht.Hash) {
	m := ht.memory_usage(h)
	d := m - h.acct
	if d != 0 {
		h.acct = m
		object_account(db, d)
	}
	ht.maintenance_bind(h, db.hreg)
}

@(private)
hash_done :: #force_inline proc "contextless" (e: ^Entry, h: ht.Hash) {
	entry_set_encoding(e, hash_obj_encoding(h))
	hash_sync(e.db, h)
}

@(private)
hash_reset :: proc(e: ^Entry, h: ht.Hash) {
	hash_key_ref_free(h)
	ht.reset(h)
	entry_set_expire(e, 0)
	hash_done(e, h)
}

@(private)
hash_lookup :: #force_inline proc(key: []u8, read: bool) -> (e: ^Entry, h: ht.Hash, wrong: bool) {
	e = db_find_read(key) if read else db_find(key)
	if e == nil {
		return
	}
	h = ht.Hash(entry_object(e, .Hash))
	wrong = h == nil
	return
}

@(private)
hash_lookup_create :: proc(key: []u8) -> (e: ^Entry, h: ht.Hash, wrong: bool) {
	e = db_find(key)
	if e != nil {
		h = ht.Hash(entry_object(e, .Hash))
		wrong = h == nil
		return
	}
	h = ht.create()
	h.acct = ht.memory_usage(h)
	e, _ = db_upsert(key)
	entry_object_attach(e, h, .Hash, .Listpack, h.acct)
	return
}

@(private)
reply_hash_value :: #force_inline proc(c: ^Conn, v: ht.Value) {
	if v.is_int {
		reply_bulk_int(c, v.ival)
	} else {
		reply_bulk(c, v.str)
	}
}

@(private)
reply_hash_error :: proc(c: ^Conn, err: ht.Error) {
	reply_error_parts(c, "ERR ", ht.error_message(err))
}

@(private)
format_u64 :: proc "contextless" (dst: [^]u8, v: u64) -> int {
	tmp: [24]u8
	n := 0
	x := v
	for {
		tmp[n] = u8('0' + x % 10)
		n += 1
		x /= 10
		if x == 0 {
			break
		}
	}
	for i in 0 ..< n {
		dst[i] = tmp[n - 1 - i]
	}
	return n
}

@(private)
hash_commands := [?]Command {
	{"hset", cmd_hset, -4},
	{"hmset", cmd_hmset, -4},
	{"hsetnx", cmd_hsetnx, 4},
	{"hget", cmd_hget, 3},
	{"hmget", cmd_hmget, -3},
	{"hgetall", cmd_hgetall, 2},
	{"hkeys", cmd_hkeys, 2},
	{"hvals", cmd_hvals, 2},
	{"hlen", cmd_hlen, 2},
	{"hexists", cmd_hexists, 3},
	{"hstrlen", cmd_hstrlen, 3},
	{"hdel", cmd_hdel, -3},
	{"hincrby", cmd_hincrby, 4},
	{"hincrbyfloat", cmd_hincrbyfloat, 4},
	{"hrandfield", cmd_hrandfield, -2},
	{"hscan", cmd_hscan, -3},
	{"hexpire", cmd_hexpire, -6},
	{"hpexpire", cmd_hpexpire, -6},
	{"hexpireat", cmd_hexpireat, -6},
	{"hpexpireat", cmd_hpexpireat, -6},
	{"httl", cmd_httl, -5},
	{"hpttl", cmd_hpttl, -5},
	{"hexpiretime", cmd_hexpiretime, -5},
	{"hpexpiretime", cmd_hpexpiretime, -5},
	{"hpersist", cmd_hpersist, -5},
}

@(init)
register_hash_commands :: proc "contextless" () {
	register_commands(hash_commands[:])
}

hash_resize_db_next: int

hash_resize_tick :: proc "contextless" () {
	if !ht.maintenance_pending() {
		return
	}
	deadline := now_ns() + 150_000
	scans, moves, grants := 4096, 256, 64
	empty, visits := 0, 0
	finished := false
	for grants > 0 && empty < len(db_parts) && visits < 128 && !finished {
		visits += 1
		d := db_parts[hash_resize_db_next]
		hash_resize_db_next = (hash_resize_db_next + 1) % len(db_parts)
		if d.hreg.resize_head == nil {
			empty += 1
			continue
		}
		empty = 0
		for _ in 0 ..< 16 {
			h, work := ht.maintenance_step(d.hreg, min(scans, ht.RESIZE_WRITE_SCANS), min(moves, ht.RESIZE_WRITE_MOVES))
			if h == nil {
				break
			}
			grants -= 1
			scans -= work.scanned
			moves -= work.moved
			hash_sync((^Db)(d.hreg.owner), h)
			if grants == 0 || scans == 0 || moves == 0 || now_ns() >= deadline {
				finished = true
				break
			}
		}
	}
	ht.maintenance_release(deadline_ns = now_ns() + 50_000)
}

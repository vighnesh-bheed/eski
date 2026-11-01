package main

import ks "keyspace"
import ht "hashtype"
import lt "listtype"
import st "settype"
import zt "zsettype"
import sm "streamtype"

keyspace_hash_destroy :: proc "contextless" (object: rawptr) { ht.destroy(cast(ht.Hash)object) }
keyspace_set_destroy :: proc "contextless" (object: rawptr) { st.destroy(cast(st.Set)object) }
keyspace_zset_destroy :: proc "contextless" (object: rawptr) { zt.destroy(cast(zt.Zset)object) }
keyspace_stream_destroy :: proc "contextless" (object: rawptr) { sm.destroy(cast(sm.Stream)object) }

keyspace_object_memory :: proc "contextless" (kind: Obj_Type, object: rawptr) -> int {
	if object == nil { return 0 }
	switch kind {
	case .String: return 0
	case .List: return lt.memory_usage(cast(lt.List)object)
	case .Hash: return ht.memory_usage(cast(ht.Hash)object)
	case .Set: return st.memory_usage(cast(st.Set)object)
	case .Zset: return zt.memory_usage(cast(zt.Zset)object)
	case .Stream: return sm.memory_usage(cast(sm.Stream)object)
	}
	return 0
}

keyspace_object_length :: proc(kind: Obj_Type, object: rawptr) -> int {
	if object == nil { return 0 }
	switch kind {
	case .String: return 0
	case .List: return lt.length(cast(lt.List)object)
	case .Hash: return ht.length(cast(ht.Hash)object)
	case .Set: return st.size(cast(st.Set)object)
	case .Zset: return zt.length(cast(zt.Zset)object)
	case .Stream: return int(sm.length(cast(sm.Stream)object))
	}
	return 0
}

keyspace_hash_registered_minimum :: proc "contextless" (h: ht.Hash) -> u64 {
	minimum := ht.registered_expire(h)
	return 0 if minimum == ht.EB_EXPIRE_TIME_INVALID else minimum
}

keyspace_hash_binding_minimum :: proc(h: ht.Hash, minimum: u64) -> u64 {
	if minimum != 0 { return minimum }
	return ht.EB_EXPIRE_TIME_INVALID if h == nil else ht.min_expire(h, true)
}

keyspace_object_duplicate :: proc(kind: Obj_Type, object: rawptr) -> rawptr {
	switch kind {
	case .String: return nil
	case .List: return lt.dup(cast(lt.List)object)
	case .Hash: clone, _ := ht.duplicate(cast(ht.Hash)object); return clone
	case .Set: return st.dup(cast(st.Set)object)
	case .Zset: return zt.dup(cast(zt.Zset)object)
	case .Stream: return sm.dup(cast(sm.Stream)object)
	}
	return nil
}

keyspace_object_destructor :: proc "contextless" (kind: Obj_Type) -> proc "contextless" (rawptr) {
	switch kind {
	case .String: return nil
	case .List: return keyspace_list_destroy
	case .Hash: return keyspace_hash_destroy
	case .Set: return keyspace_set_destroy
	case .Zset: return keyspace_zset_destroy
	case .Stream: return keyspace_stream_destroy
	}
	return nil
}

keyspace_object_encoding :: proc "contextless" (kind: Obj_Type, object: rawptr) -> u8 {
	switch kind {
	case .String: return 0
	case .List: return u8(list_obj_encoding(cast(lt.List)object))
	case .Hash:
		h := cast(ht.Hash)object
		return u8(Obj_Encoding.Listpack if h.encoding == .Listpack else Obj_Encoding.Listpack_Ex if h.encoding == .Listpack_Ex else Obj_Encoding.Hashtable)
	case .Set: return u8(set_obj_encoding(cast(st.Set)object))
	case .Zset: return u8(zset_obj_encoding(cast(zt.Zset)object))
	case .Stream: return u8(Obj_Encoding.Stream)
	}
	return 0
}

keyspace_object_seed :: proc(c: ^Conn, key: []u8, owner: int) -> ^ks.Record {
	pointer, kind, clock, expires, eligible := keyspace_store_seed_object(c.db, key)
	if !eligible { return nil }
	if kind == .Hash { keyspace_timed = true }
	charge := keyspace_object_memory(kind, pointer)
	if !ks.reserve_external(&keyspace_pool, charge) { return nil }
	object := keyspace_object_duplicate(kind, pointer)
	actual := keyspace_object_memory(kind, object)
	destroy := keyspace_object_destructor(kind)
	if actual > charge && !ks.reserve_external(&keyspace_pool, actual - charge) {
		destroy(object); ks.release_external(&keyspace_pool, charge); return nil
	}
	if actual < charge { ks.release_external(&keyspace_pool, charge - actual) }
	r := ks.record_new(&keyspace_pool, c.db.id, key, owner, false, nil, clock)
	if r == nil { destroy(object); ks.release_external(&keyspace_pool, actual); return nil }
	r.exists = true
	r.kind = u8(kind)
	r.encoding = keyspace_object_encoding(kind, object)
	r.expire_at = expires
	r.object = object
	if kind == .Hash { r.hash_minimum = keyspace_hash_registered_minimum(cast(ht.Hash)pointer) }
	r.object_charge = actual
	r.object_destroy = destroy
	return r
}

keyspace_object_import :: proc(db: ^Db, r: ^ks.Record) {
	key := transmute([]u8)r.key
	e := keyspace_store_object_destination(db, key)
	switch Obj_Type(r.kind) {
	case .String:
	case .List: list_copy_attach(e, r.object)
	case .Hash:
		h := cast(ht.Hash)r.object
		h.acct = ht.memory_usage(h)
		hash_copy_attach(e, key, r.object, keyspace_hash_binding_minimum(h, r.hash_minimum))
	case .Set: set_copy_attach(e, r.object)
	case .Zset: zset_copy_attach(e, key, r.object, 0)
	case .Stream: stream_copy_attach(e, r.object)
	}
	entry_set_expire(e, r.expire_at)
	entry_set_lru(e, r.clock)
	r.object = nil
	ks.release_external(&keyspace_pool, r.object_charge)
	r.object_charge = 0
}

Keyspace_Object_Work :: struct {
	kind: Obj_Type,
	object: rawptr,
	charge: int,
	hash_minimum: u64,
}

keyspace_object_work :: proc(task: ^Keyspace_Task, r: ^ks.Record, kind: Obj_Type) -> (work: Keyspace_Object_Work, ok: bool) {
	original := r.object
	size := u128(keyspace_object_memory(kind, original)) * 4 + u128(keyspace_object_length(kind, original)) * 512 + u128(len(task.argv)) * 512 + 8192
	for arg in task.argv { size += u128(len(arg)) * 4 }
	if size > u128(max(int)) || !ks.reserve_external(&keyspace_pool, int(size)) { task.failed = true; return }
	work.kind = kind
	if kind == .Hash { work.hash_minimum = r.hash_minimum }
	work.charge = int(size)
	if original != nil { work.object = keyspace_object_duplicate(kind, original) } else {
		switch kind {
		case .String:
		case .List: work.object = lt.create()
		case .Hash: work.object = ht.create()
		case .Set: work.object = st.create(nil, len(task.argv))
		case .Zset: work.object = zt.type_create(len(task.argv), 0)
		case .Stream: work.object = sm.create()
		}
	}
	ok = work.object != nil
	if !ok { task.failed = true; keyspace_object_discard(&work) }
	return
}

keyspace_object_discard :: proc "contextless" (work: ^Keyspace_Object_Work) {
	if work.object != nil { keyspace_object_destructor(work.kind)(work.object); work.object = nil }
	ks.release_external(&keyspace_pool, work.charge)
	work.charge = 0
}

keyspace_object_prepare :: proc(task: ^Keyspace_Task, work: ^Keyspace_Object_Work) -> bool {
	actual := keyspace_object_memory(work.kind, work.object)
	if actual > work.charge && !ks.reserve_external(&keyspace_pool, actual - work.charge) { task.failed = true; return false }
	if actual < work.charge { ks.release_external(&keyspace_pool, work.charge - actual) }
	work.charge = actual
	return true
}

keyspace_object_commit :: proc(task: ^Keyspace_Task, r: ^ks.Record, work: ^Keyspace_Object_Work, keep_empty: bool = false) -> bool {
	if !keyspace_object_prepare(task, work) { return false }
	if !keep_empty && keyspace_object_length(work.kind, work.object) == 0 {
		keyspace_object_discard(work); keyspace_remove(r); return true
	}
	created := !r.exists
	ks.record_object_clear(r)
	ks.value_release(r.value)
	r.value = nil
	r.exists = true
	r.kind = u8(work.kind)
	r.object = work.object
	r.hash_minimum = work.hash_minimum if work.kind == .Hash else 0
	r.object_charge = work.charge
	r.object_destroy = keyspace_object_destructor(work.kind)
	r.encoding = keyspace_object_encoding(work.kind, work.object)
	r.changed = true
	r.value_changed = true
	keyspace_touch(task, r, created = created)
	if created { keyspace_notify(task, r, .New, "new") }
	work.object = nil; work.charge = 0
	return true
}

keyspace_object_builder :: proc(task: ^Keyspace_Task, kind: Obj_Type, object: rawptr, extra: int = 0) -> Keyspace_Builder {
	size := u128(keyspace_object_memory(kind, object)) * 2 + u128(keyspace_object_length(kind, object)) * 96 + u128(extra) + 1024
	for arg in task.argv { size += u128(len(arg)) }
	if size > u128(max(int)) { task.failed = true; return {failed = true} }
	bytes := ks.allocate(&keyspace_pool, int(size))
	if len(bytes) == 0 { task.failed = true; return {failed = true} }
	return {bytes = bytes}
}

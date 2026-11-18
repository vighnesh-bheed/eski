package main

import "base:intrinsics"
import "core:fmt"
import ht "hashtype"
import "jsondoc"
import "base:runtime"
import lb "label"
import ow "owner"
import lt "listtype"
import st "settype"
import sm "streamtype"
import zt "zsettype"

ERR_LABEL_QUOTA_OOM :: "OOM command not allowed when used memory > 'label-quota'."

label_quotas: map[lb.Id]int

label_quota_active :: #force_inline proc "contextless" () -> bool {
	return len(label_quotas) > 0
}

label_partition_bytes :: proc "contextless" (p: ^Db) -> int {
	return key_table_charge(p) + p.slab.live + p.heap_bytes
}

key_table_charge :: proc "contextless" (p: ^Db) -> int {
	live := db_size_of(p)
	if live == 0 {
		return 0
	}
	heap := p.role & DB_ROLE_HEAP != 0
	if heap && owner_compact && live <= TABLE_SHORT_FULL / 2 {
		lanes := TABLE_SHORT_FIRST
		for lanes < live {
			lanes *= 2
		}
		return GROUP_SLOTS + lanes * SLOT_BYTES
	}
	cap := TABLE_MIN_CAP
	for live > cap - cap / 8 {
		cap *= 2
	}
	if heap && cap <= TABLE_HEAP_MAX_CAP {
		return table_heap_size(cap)
	}
	return table_alloc_size(cap)
}

object_charged :: #force_inline proc "contextless" (db: ^Db, real, charge: int) {
	db.heap_bytes += charge
	db_used_memory += real
}

object_chg_of :: proc "contextless" (type: Obj_Type, obj: rawptr) -> int {
	if obj == nil {
		return 0
	}
	#partial switch type {
	case .Hash:
		return ht.Hash(obj).chg
	case .Set:
		return st.Set(obj).chg
	case .List:
		return lt.List(obj).chg
	case .Zset:
		return zt.Zset(obj).chg
	case .Stream:
		return stream_chg(sm.Stream(obj))
	case .Json:
		return json_object_content_memory(cast(^Json_Object)obj)
	}
	return object_acct_of(type, obj)
}

object_held_of :: #force_inline proc "contextless" (type: Obj_Type, obj: rawptr) -> int {
	if labels_on {
		return object_chg_of(type, obj)
	}
	return object_acct_of(type, obj)
}

object_charge_attach :: proc "contextless" (db: ^Db, type: Obj_Type, obj: rawptr, bytes: int) {
	c: int
	#partial switch type {
	case .Hash:
		h := ht.Hash(obj)
		c = ht.charge(h)
		h.chg = c
	case .Set:
		s := st.Set(obj)
		c = st.charge(s)
		s.chg = c
	case .List:
		l := lt.List(obj)
		c = lt.charge(l)
		l.chg = c
	case .Zset:
		z := zt.Zset(obj)
		c = zt.charge(z)
		z.chg = c
	case .Stream:
		c = stream_chg_store(sm.Stream(obj), bytes)
	case .Json:
		c = json_object_content_memory(cast(^Json_Object)obj)
	case:
		return
	}
	db.heap_bytes += c - bytes
}

stream_chg :: proc "contextless" (s: sm.Stream) -> int {
	if p := sm.charge_slot(s); p != nil {
		return p^
	}
	return s.acct
}

stream_chg_store :: proc "contextless" (s: sm.Stream, real: int) -> int {
	p := sm.charge_slot(s)
	if p == nil {
		return real
	}
	p^ = sm.charge(s)
	return p^
}

label_flush_charged :: proc "contextless" (db: ^Db, vp: ^Val_Handle) {
	type := vp.slab.info.type
	obj := rawptr(vp.ref.addr)
	db.heap_bytes += object_acct_of(type, obj) - object_chg_of(type, obj)
}

label_used :: proc(id: lb.Id) -> int {
	total := search_scope_charged(ow.Scope{label = id, owner = ow.SHARED})
	for i in 0 ..< len(label_dbs) {
		if p := label_part(i, id); p != nil {
			total += label_partition_bytes(p)
		}
	}
	return total
}

label_quota_check :: proc(cmd: ^Command, spec: ^Cmd_Spec, argv: [][]u8) -> string {
	if spec == nil || .Denyoom not_in spec.flags {
		return ""
	}
	quota, ok := label_quotas[access.id]
	if !ok {
		return ""
	}
	if label_used(access.id) <= quota {
		return ""
	}
	keys := db_size_of(db_cur)
	label_quota_expire(access.id)
	if db_size_of(db_cur) != keys {
		if msg := label_write_check(cmd, spec, argv); msg != "" {
			return msg
		}
	}
	if label_used(access.id) <= quota {
		return ""
	}
	evict_in_label(access.id, quota)
	if label_used(access.id) > quota {
		return ERR_LABEL_QUOTA_OOM
	}
	return ""
}

label_quota_expire :: proc(id: lb.Id) {
	if aof.loading || pst.loading || expiry_deletion_paused() {
		return
	}
	now := expire_now()
	for i in 0 ..< len(label_dbs) {
		if p := label_part(i, id); p != nil {
			db_quota_expire(p, now)
		}
	}
}

object_content_of :: proc "contextless" (type: Obj_Type, obj: rawptr) -> int {
	#partial switch type {
	case .Hash:
		return ht.content_memory(ht.Hash(obj))
	case .Set:
		return st.content_memory(st.Set(obj))
	case .List:
		return lt.content_memory(lt.List(obj))
	case .Zset:
		return zt.content_memory(zt.Zset(obj))
	case .Stream:
		return sm.content_memory(sm.Stream(obj))
	case .Json:
		context = runtime.default_context()
		return jsondoc.content_memory((cast(^Json_Object)obj).doc.root)
	}
	return 0
}

debug_charge_check :: proc(c: ^Conn) {
	vsets := 0
	for i in 0 ..< len(label_dbs) {
		for p in label_dbs[i].by_id {
			if p != nil {
				vsets += charge_check_vsets(p)
			}
		}
	}
	parts := make([dynamic]^Owner_Part, context.temp_allocator)
	for e in owner_table.entries {
		if e == nil {
			continue
		}
		owner_parts_of(e, &parts)
		for q in parts {
			vsets += charge_check_vsets(owner_db(q))
		}
	}
	checked := 0
	for i in 0 ..< len(label_dbs) {
		for p in label_dbs[i].by_id {
			if p != nil && !charge_check_db(c, p, vsets == 0, &checked) {
				return
			}
		}
	}
	for e in owner_table.entries {
		if e == nil {
			continue
		}
		owner_parts_of(e, &parts)
		for q in parts {
			if !charge_check_db(c, owner_db(q), vsets == 0, &checked) {
				return
			}
		}
	}
	reply_int(c, i64(checked))
}

@(private = "file")
charge_check_vsets :: proc(d: ^Db) -> int {
	n := 0
	for k in 0 ..< 2 {
		if k == 1 && d.rehash_idx < 0 {
			break
		}
		t := &d.t[k]
		for g in 0 ..< t.groups {
			full := group_full(group_load(t.ctrl, g))
			for full != 0 {
				i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
				full &= full - 1
				if t.slots[i].key.small.tag.val_form == FORM_OBJECT && t.slots[i].val.slab.info.type == .Vectorset {
					n += 1
				}
			}
		}
	}
	return n
}

@(private = "file")
charge_check_db :: proc(c: ^Conn, d: ^Db, whole: bool, checked: ^int) -> bool {
	heap := 0
	for k in 0 ..< 2 {
		if k == 1 && d.rehash_idx < 0 {
			break
		}
		t := &d.t[k]
		for g in 0 ..< t.groups {
			full := group_full(group_load(t.ctrl, g))
			for full != 0 {
				i := int(g << GROUP_SHIFT) + int(intrinsics.count_trailing_zeros(full))
				full &= full - 1
				kp := &t.slots[i].key
				vp := &t.slots[i].val
				if kp.small.tag.key_form == FORM_HEAP {
					extra := DEADLINE_BYTES if kp.heap.timed != 0 else 0
					heap += (^int)(uintptr(kp.heap.addr))^ + 8 + extra
				}
				switch kp.small.tag.val_form {
				case FORM_HEAP:
					heap += int((^Big_Str)(vp.ref.addr).cap) + BIG_STR_BYTES
				case FORM_OBJECT:
					type := vp.slab.info.type
					if type == .Vectorset {
						continue
					}
					obj := rawptr(vp.ref.addr)
					stored := object_chg_of(type, obj)
					fresh := object_content_of(type, obj)
					if stored != fresh {
						reply_error(c, fmt.tprintf("ERR charge of %s is %d but its content is %d", string(key_bytes(kp, &d.slab)), stored, fresh))
						return false
					}
					heap += stored
					checked^ += 1
				}
			}
		}
	}
	if whole && heap != d.heap_bytes {
		reply_error(c, fmt.tprintf("ERR a partition holds %d heap bytes but its content is %d", d.heap_bytes, heap))
		return false
	}
	return true
}

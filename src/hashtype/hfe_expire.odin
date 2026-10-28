package hashtype

import lp "../listpack"

expire_due_fields :: proc(h: Hash, now: u64, quota: int) -> int {
	expired := 0
	for expired < quota {
		deadline := min_expire(h, true)
		if deadline == EB_EXPIRE_TIME_INVALID || deadline > now {
			break
		}
		field: []u8
		buf: [lp.LP_INTBUF_SIZE]u8
		if h.encoding == .Hashtable {
			field = blob_field(h.table.vol[0].blob)
		} else {
			field = value_bytes(value_from_lp(pack_first(h.lp)), &buf)
		}
		if field_expired_hook != nil {
			field_expired_hook(h, field)
		}
		if !delete_field(h, field) {
			break
		}
		expired += 1
	}
	return expired
}

hash_type_expire :: proc(h: Hash, now: u64, quota: ^int, update_registry: bool) -> (next: u64, expired: int) {
	reg: ^Registry
	if h.hfe != nil {
		reg = h.hfe.reg
	}
	expired = expire_due_fields(h, now, max(quota^, 0))
	quota^ -= expired
	if length(h) == 0 {
		next = 0
	} else {
		next = min_expire(h, true)
	}
	if update_registry && expired > 0 {
		registry_remove(h)
		if reg != nil && next != 0 && next != EB_EXPIRE_TIME_INVALID {
			registry_add(reg, h, next)
		}
	}
	return
}

expire_if_needed :: proc(h: Hash, now: u64) -> (emptied: bool) {
	minimum := min_expire(h, true)
	if minimum == EB_EXPIRE_TIME_INVALID || minimum >= now {
		return false
	}
	quota := max(int)
	next, _ := hash_type_expire(h, now, &quota, true)
	return next == 0
}

active_expire :: proc(reg: ^Registry, now: u64, max_fields: int, out: ^[dynamic]Expired_Hash) -> (fields_expired: int) {
	pending := make([dynamic]Reg_Item)
	defer delete(pending)
	quota := max(max_fields, 0)
	for quota > 0 && registry_len(reg) > 0 && registry_next_expire(reg) <= now {
		h := reg.items[0].h
		key := key_ref(h)
		registry_remove(h)
		next, removed := hash_type_expire(h, now, &quota, false)
		if removed > 0 {
			append(out, Expired_Hash{h = h, key = key, fields = removed, emptied = next == 0})
			fields_expired += removed
		}
		if next != 0 && next != EB_EXPIRE_TIME_INVALID {
			append(&pending, Reg_Item{expire = next, h = h})
		}
	}
	for item in pending {
		registry_add(reg, item.h, item.expire)
	}
	return
}

package hashtype

set_ex_field :: proc(h: Hash, field: []u8, expire_at: u64, cond: Expire_Condition, now: u64, min_fields: ^u64, deleted, updated: ^int) -> i64 {
	_, old, found := get_raw(h, field)
	if !found {
		return EXPIRE_NO_FIELD
	}
	volatile := old != NO_FIELD_DEADLINE
	allowed := true
	switch cond {
	case .None:
	case .NX:
		allowed = !volatile
	case .XX:
		allowed = volatile
	case .GT:
		allowed = volatile && expire_at > old
	case .LT:
		allowed = !volatile || expire_at < old
	}
	if !allowed {
		return EXPIRE_CONDITION_UNMET
	}
	min_fields^ = min(min_fields^, old)
	if expire_at <= now {
		if delete_field(h, field) {
			deleted^ += 1
		}
		return EXPIRE_DELETED
	}
	min_fields^ = min(min_fields^, expire_at)
	if h.encoding == .Hashtable {
		s := table_find(h.table, field, hash_field(field))
		vol_set(h.table, s.blob, expire_at)
		if h.table.resize != nil {
			table_step(h.table, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
		}
	} else {
		fp, vp, _, ok := lpex_locate(h, field)
		resize_require(ok && h.encoding == .Listpack_Ex)
		lpex_update_expiry(h, field, fp, vp, expire_at)
	}
	updated^ += 1
	return EXPIRE_SET
}

expire_fields :: proc(reg: ^Registry, key: rawptr, h: Hash, fields: [][]u8, expire_at: u64, cond: Expire_Condition, now: u64, out: ^[dynamic]i64) -> (emptied: bool) {
	convert_to_ex(h)
	if key_ref(h) == nil {
		set_key_ref(h, key)
	}
	old := registered_expire(h)
	touched := NO_FIELD_DEADLINE
	deleted, updated: int
	for field in fields {
		append(out, set_ex_field(h, field, expire_at, cond, now, &touched, &deleted, &updated))
	}
	if deleted > 0 && length(h) == 0 {
		registry_remove(h)
		return true
	}
	if deleted == 0 && updated == 0 {
		return false
	}
	if old < touched {
		return false
	}
	actual := min_expire(h, true)
	if actual == old {
		return false
	}
	reschedule := actual == NO_FIELD_DEADLINE || old == NO_FIELD_DEADLINE
	if !reschedule {
		shift := actual - old if actual > old else old - actual
		reschedule = shift >= SCHEDULE_SLACK_MS
	}
	if reschedule {
		registry_remove(h)
		if actual != NO_FIELD_DEADLINE {
			registry_add(reg, h, actual)
		}
	}
	return false
}

ttl_fields :: proc(h: Hash, fields: [][]u8, kind: Ttl_Kind, now: u64, out: ^[dynamic]i64) {
	for field in fields {
		_, deadline, found := get_raw(h, field)
		result := i64(TTL_NO_FIELD)
		if found {
			if deadline == NO_FIELD_DEADLINE {
				result = TTL_NO_DEADLINE
			} else {
				elapsed := deadline < now || (h.encoding == .Listpack_Ex && deadline == now)
				if !elapsed {
					base := u64(0)
					if kind == .Ttl || kind == .Pttl {
						base = now
					}
					if kind == .Ttl || kind == .Expire_Time {
						result = i64((deadline + 999 - base) / 1000)
					} else {
						result = i64(deadline - base)
					}
				}
			}
		}
		append(out, result)
	}
}

persist_fields :: proc(h: Hash, fields: [][]u8, now: u64, out: ^[dynamic]i64) -> (changed: bool) {
	for field in fields {
		_, deadline, found := get_raw(h, field)
		result := i64(PERSIST_NO_FIELD)
		if found {
			if deadline == NO_FIELD_DEADLINE {
				result = PERSIST_NO_DEADLINE
			} else if deadline >= now {
				if h.encoding == .Hashtable {
					s := table_find(h.table, field, hash_field(field))
					vol_remove(h.table, s.blob)
					if h.table.resize != nil {
						table_step(h.table, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
					}
				} else {
					fp, vp, _, _ := lpex_locate(h, field)
					lpex_update_expiry(h, field, fp, vp, 0)
				}
				changed = true
				result = PERSIST_REMOVED
			}
		}
		append(out, result)
	}
	return
}

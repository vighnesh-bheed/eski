package hashtype

Expire_Tally :: struct {
	floor:   u64,
	deleted: int,
	updated: int,
}

expire_tally :: #force_inline proc "contextless" () -> Expire_Tally {
	return {floor = DEADLINE_UNSET}
}

condition_allows :: proc "contextless" (cond: Expire_Condition, current, target: u64) -> bool {
	switch cond {
	case .NX:
		return current == DEADLINE_UNSET
	case .XX:
		return current != DEADLINE_UNSET
	case .GT:
		return target > current
	case .LT:
		return target < current
	case .None:
	}
	return true
}

store_deadline :: proc(h: Hash, field: []u8, deadline: u64) {
	if h.encoding != .Hashtable {
		field_at, _, _, found := lpex_locate(h, field)
		resize_require(found && h.encoding == .Listpack_Ex)
		pack_retime(h, field_at, deadline)
		return
	}
	slot := table_find(h.table, field, hash_field(field))
	vol_set(h.table, slot.blob, deadline)
	if h.table.resize != nil {
		table_step(h.table, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
	}
}

retime_field :: proc(h: Hash, field: []u8, target: u64, cond: Expire_Condition, now: u64, tally: ^Expire_Tally) -> i64 {
	_, current, present := get_raw(h, field)
	if !present {
		return EXPIRE_NO_FIELD
	}
	if !condition_allows(cond, current, target) {
		return EXPIRE_CONDITION_UNMET
	}
	if target <= now {
		tally.floor = min(tally.floor, current)
		if delete_field(h, field) {
			tally.deleted += 1
		}
		return EXPIRE_DELETED
	}
	tally.floor = min(tally.floor, current, target)
	store_deadline(h, field, target)
	tally.updated += 1
	return EXPIRE_SET
}

booking_stale :: proc "contextless" (booked, actual: u64) -> bool {
	switch {
	case booked == actual:
		return false
	case booked == DEADLINE_UNSET, actual == DEADLINE_UNSET:
		return true
	}
	drift := booked - actual if booked > actual else actual - booked
	return drift >= SCHEDULE_SLACK_MS
}

rebook :: proc(reg: ^Registry, h: Hash, booked: u64) {
	actual := earliest_deadline(h)
	if !booking_stale(booked, actual) {
		return
	}
	registry_remove(h)
	if actual != DEADLINE_UNSET {
		registry_add(reg, h, actual)
	}
}

expire_fields :: proc(reg: ^Registry, key: rawptr, h: Hash, fields: [][]u8, expire_at: u64, cond: Expire_Condition, now: u64, out: ^[dynamic]i64) -> (emptied: bool) {
	convert_to_ex(h)
	if h.hfe.key == nil {
		h.hfe.key = key
	}
	booked := registered_expire(h)
	tally := expire_tally()
	for field in fields {
		append(out, retime_field(h, field, expire_at, cond, now, &tally))
	}
	emptied = tally.deleted > 0 && length(h) == 0
	if emptied {
		registry_remove(h)
	} else if tally.deleted + tally.updated > 0 && booked >= tally.floor {
		rebook(reg, h, booked)
	}
	return
}

field_ttl :: proc(h: Hash, field: []u8, kind: Ttl_Kind, now: u64) -> i64 {
	_, deadline, present := get_raw(h, field)
	switch {
	case !present:
		return TTL_NO_FIELD
	case deadline == DEADLINE_UNSET:
		return TTL_NO_DEADLINE
	case deadline < now:
		return TTL_NO_FIELD
	}
	span := deadline
	if kind == .Ttl || kind == .Pttl {
		span -= now
	}
	if kind == .Pttl || kind == .Pexpire_Time {
		return i64(span)
	}
	return i64((span + 999) / 1000)
}

ttl_fields :: proc(h: Hash, fields: [][]u8, kind: Ttl_Kind, now: u64, out: ^[dynamic]i64) {
	for field in fields {
		append(out, field_ttl(h, field, kind, now))
	}
}

persist_fields :: proc(h: Hash, fields: [][]u8, now: u64, out: ^[dynamic]i64) -> (changed: bool) {
	for field in fields {
		_, deadline, found := get_raw(h, field)
		result := i64(PERSIST_NO_FIELD)
		if found {
			if deadline == DEADLINE_UNSET {
				result = PERSIST_NO_DEADLINE
			} else if deadline >= now {
				store_deadline(h, field, DEADLINE_UNSET)
				changed = true
				result = PERSIST_REMOVED
			}
		}
		append(out, result)
	}
	return
}

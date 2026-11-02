package hashtype

import lp "../listpack"

expire_due_fields :: proc(h: Hash, now: u64, quota: int) -> int {
	expired := 0
	for expired < quota {
		deadline := earliest_deadline(h)
		if deadline == DEADLINE_UNSET || deadline > now {
			break
		}
		field: []u8
		buf: [lp.DECIMAL_BUFFER_BYTES]u8
		if h.encoding == .Hashtable {
			field = blob_field(h.table.vol[0].blob)
		} else {
			field = value_bytes(value_from_lp(pack_first(h.lp)), &buf)
		}
		notify_field_expired(h, field)
		if !delete_field(h, field) {
			break
		}
		expired += 1
	}
	return expired
}

Sweep :: struct {
	removed: int,
	next:    u64,
	emptied: bool,
}

sweep :: proc(h: Hash, now: u64, budget: ^int) -> (s: Sweep) {
	s.removed = expire_due_fields(h, now, max(budget^, 0))
	budget^ -= s.removed
	s.emptied = length(h) == 0
	s.next = DEADLINE_UNSET if s.emptied else earliest_deadline(h)
	return
}

home_registry :: #force_inline proc "contextless" (h: Hash) -> ^Registry {
	if h.hfe == nil {
		return nil
	}
	return h.hfe.reg
}

sweep_and_rebook :: proc(h: Hash, now: u64, budget: ^int) -> Sweep {
	home := home_registry(h)
	s := sweep(h, now, budget)
	if s.removed > 0 {
		registry_remove(h)
		if home != nil && s.next != DEADLINE_UNSET {
			registry_add(home, h, s.next)
		}
	}
	return s
}

expire_if_needed :: proc(h: Hash, now: u64) -> (emptied: bool) {
	if earliest_deadline(h) >= now {
		return false
	}
	budget := max(int)
	return sweep_and_rebook(h, now, &budget).emptied
}

registry_due :: proc "contextless" (reg: ^Registry, now: u64) -> Hash {
	if registry_len(reg) == 0 || reg.items[0].expire > now {
		return nil
	}
	return reg.items[0].h
}

active_expire :: proc(reg: ^Registry, now: u64, max_fields: int, out: ^[dynamic]Expired_Hash) -> (fields_expired: int) {
	budget := max(max_fields, 0)
	parked: [dynamic]Reg_Item
	defer delete(parked)
	for budget > 0 {
		h := registry_due(reg, now)
		if h == nil {
			break
		}
		key := key_ref(h)
		registry_remove(h)
		s := sweep(h, now, &budget)
		fields_expired += s.removed
		if s.removed > 0 {
			append(out, Expired_Hash{h = h, key = key, fields = s.removed, emptied = s.emptied})
		}
		if s.next != DEADLINE_UNSET {
			append(&parked, Reg_Item{expire = s.next, h = h})
		}
	}
	for entry in parked {
		registry_add(reg, entry.h, entry.expire)
	}
	return fields_expired
}

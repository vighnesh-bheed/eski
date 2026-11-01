package hashtype

Field_Expired_Hook :: #type proc(h: Hash, field: []u8)

ensure_meta :: proc "contextless" (h: Hash) -> ^Hfe_Meta {
	if h.hfe == nil {
		h.hfe = cast(^Hfe_Meta)mem_alloc(size_of(Hfe_Meta))
		h.hfe.reg_index = -1
		h.hfe.reg_expire = NO_FIELD_DEADLINE
	}
	return h.hfe
}

is_registered :: proc "contextless" (h: Hash) -> bool {
	return h != nil && h.hfe != nil && h.hfe.reg != nil && h.hfe.reg_index >= 0
}

registered_expire :: proc "contextless" (h: Hash) -> u64 {
	if !is_registered(h) {
		return NO_FIELD_DEADLINE
	}
	return h.hfe.reg_expire
}

set_key_ref :: proc "contextless" (h: Hash, key: rawptr) {
	if h.hfe != nil {
		h.hfe.key = key
	}
}

key_ref :: proc "contextless" (h: Hash) -> rawptr {
	if h == nil || h.hfe == nil {
		return nil
	}
	return h.hfe.key
}

registry_len :: proc "contextless" (reg: ^Registry) -> int {
	if reg == nil {
		return 0
	}
	return reg.len
}

registry_next_expire :: proc "contextless" (reg: ^Registry) -> u64 {
	if registry_len(reg) == 0 {
		return NO_FIELD_DEADLINE
	}
	return reg.items[0].expire
}

reg_swap :: proc "contextless" (reg: ^Registry, i, j: int) {
	reg.items[i], reg.items[j] = reg.items[j], reg.items[i]
	reg.items[i].h.hfe.reg_index = i
	reg.items[j].h.hfe.reg_index = j
}

reg_up :: proc "contextless" (reg: ^Registry, i: int) {
	at := i
	for at > 0 {
		parent := (at - 1) / 2
		if reg.items[parent].expire <= reg.items[at].expire {
			break
		}
		reg_swap(reg, at, parent)
		at = parent
	}
}

reg_down :: proc "contextless" (reg: ^Registry, i: int) {
	at := i
	for at < reg.len / 2 {
		child := at * 2 + 1
		if child + 1 < reg.len && reg.items[child + 1].expire < reg.items[child].expire {
			child += 1
		}
		if reg.items[at].expire <= reg.items[child].expire {
			break
		}
		reg_swap(reg, at, child)
		at = child
	}
	if at * 2 + 1 < reg.len {
		child := at * 2 + 1
		if reg.items[child].expire < reg.items[at].expire {
			reg_swap(reg, at, child)
		}
	}
}

registry_remove :: proc "contextless" (h: Hash) {
	if !is_registered(h) {
		return
	}
	m := h.hfe
	reg := m.reg
	at := m.reg_index
	reg.len -= 1
	if at < reg.len {
		reg.items[at] = reg.items[reg.len]
		reg.items[at].h.hfe.reg_index = at
		if at > 0 && reg.items[at].expire < reg.items[(at - 1) / 2].expire {
			reg_up(reg, at)
		} else {
			reg_down(reg, at)
		}
	}
	reg.items[reg.len] = {}
	m.reg_index = -1
	m.reg_expire = NO_FIELD_DEADLINE
}

registry_add :: proc "contextless" (reg: ^Registry, h: Hash, expire: u64) {
	if expire > FIELD_DEADLINE_MAX {
		return
	}
	resize_require(reg != nil)
	m := ensure_meta(h)
	registry_remove(h)
	if reg.len == reg.cap {
		capacity := max(16, reg.cap * 2)
		resize_require(capacity > reg.cap && capacity <= max(int) / size_of(Reg_Item))
		items := mem_realloc(cast([^]u8)reg.items, capacity * size_of(Reg_Item))
		resize_require(items != nil)
		reg.items = cast([^]Reg_Item)items
		reg.cap = capacity
	}
	m.reg = reg
	m.reg_index = reg.len
	m.reg_expire = expire
	reg.items[reg.len] = Reg_Item{expire = expire, h = h}
	reg.len += 1
	reg_up(reg, m.reg_index)
}

registry_destroy :: proc "contextless" (reg: ^Registry) {
	if reg == nil {
		return
	}
	maintenance_clear(reg)
	for i in 0 ..< reg.len {
		m := reg.items[i].h.hfe
		m.reg_index = -1
		m.reg_expire = NO_FIELD_DEADLINE
		m.reg = nil
	}
	mem_free(reg.items)
	reg.items = nil
	reg.len = 0
	reg.cap = 0
}

vol_swap :: proc "contextless" (t: ^Table, i, j: int) {
	t.vol[i], t.vol[j] = t.vol[j], t.vol[i]
	t.vol[i].blob.hidx = u32(i + 1)
	t.vol[j].blob.hidx = u32(j + 1)
}

vol_up :: proc "contextless" (t: ^Table, i: int) {
	at := i
	for at > 0 {
		parent := (at - 1) / 2
		if t.vol[parent].expire <= t.vol[at].expire {
			break
		}
		vol_swap(t, at, parent)
		at = parent
	}
}

vol_down :: proc "contextless" (t: ^Table, i: int) {
	at := i
	for at < t.vol_len / 2 {
		child := at * 2 + 1
		if child + 1 < t.vol_len && t.vol[child + 1].expire < t.vol[child].expire {
			child += 1
		}
		if t.vol[at].expire <= t.vol[child].expire {
			break
		}
		vol_swap(t, at, child)
		at = child
	}
	if at * 2 + 1 < t.vol_len {
		child := at * 2 + 1
		if t.vol[child].expire < t.vol[at].expire {
			vol_swap(t, at, child)
		}
	}
}

vol_remove :: proc "contextless" (t: ^Table, b: ^Blob) {
	if b.hidx == 0 {
		return
	}
	at := int(b.hidx) - 1
	t.vol_len -= 1
	if at < t.vol_len {
		t.vol[at] = t.vol[t.vol_len]
		t.vol[at].blob.hidx = u32(at + 1)
		if at > 0 && t.vol[at].expire < t.vol[(at - 1) / 2].expire {
			vol_up(t, at)
		} else {
			vol_down(t, at)
		}
	}
	t.vol[t.vol_len] = {}
	b.hidx = 0
}

vol_set :: proc "contextless" (t: ^Table, b: ^Blob, expire: u64) {
	if expire == 0 || expire == NO_FIELD_DEADLINE {
		vol_remove(t, b)
		return
	}
	if b.hidx != 0 {
		at := int(b.hidx) - 1
		old := t.vol[at].expire
		t.vol[at].expire = expire
		if expire < old {
			vol_up(t, at)
		} else {
			vol_down(t, at)
		}
		return
	}
	if t.vol_len == t.vol_cap {
		capacity := max(16, t.vol_cap * 2)
		resize_require(capacity > t.vol_cap && capacity <= max(int) / size_of(Vol_Item) && capacity <= int(max(u32)))
		items := mem_realloc(cast([^]u8)t.vol, capacity * size_of(Vol_Item))
		resize_require(items != nil)
		t.vol = cast([^]Vol_Item)items
		t.vol_cap = capacity
	}
	at := t.vol_len
	t.vol[at] = Vol_Item{expire = expire, blob = b}
	b.hidx = u32(at + 1)
	t.vol_len += 1
	vol_up(t, at)
}

vol_min :: proc "contextless" (t: ^Table) -> u64 {
	if t.vol_len == 0 {
		return NO_FIELD_DEADLINE
	}
	return t.vol[0].expire
}

vol_count_before :: proc "contextless" (t: ^Table, now: u64) -> int {
	n := 0
	for i in 0 ..< t.vol_len {
		if t.vol[i].expire < now {
			n += 1
		}
	}
	return n
}

table_field_expire :: proc "contextless" (t: ^Table, b: ^Blob) -> u64 {
	if b.hidx == 0 {
		return NO_FIELD_DEADLINE
	}
	return t.vol[b.hidx - 1].expire
}

package label

import "base:runtime"

INDEX_EMPTY :: u16(0xFFFF)

INDEX_MIN :: 16

Table :: struct {
	labels:    [dynamic]Label,
	index:     []u16,
	allocator: runtime.Allocator,
}

label_hash :: #force_inline proc "contextless" (l: Label) -> u64 {
	h := (u64(l.level) | u64(l.trust) << 8) * 0x9E37_79B9_7F4A_7C15 + 0xD6E8_FEB8_6659_FD93
	for w in l.compartments {
		h = (h ~ w) * 0xBF58_476D_1CE4_E5B9
		h ~= h >> 31
	}
	return h ~ h >> 29
}

index_insert :: proc "contextless" (index: []u16, labels: []Label, id: u16) {
	mask := len(index) - 1
	i := int(label_hash(labels[id])) & mask
	for index[i] != INDEX_EMPTY {
		i = (i + 1) & mask
	}
	index[i] = id
}

index_rebuild :: proc(t: ^Table, capacity: int) -> Error {
	fresh, err := make([]u16, capacity, t.allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	for &e in fresh {
		e = INDEX_EMPTY
	}
	for i in 0 ..< len(t.labels) {
		index_insert(fresh, t.labels[:], u16(i))
	}
	delete(t.index, t.allocator)
	t.index = fresh
	return .None
}

table_init :: proc(t: ^Table, allocator := context.allocator) -> Error {
	t^ = Table{allocator = allocator}
	t.labels = make([dynamic]Label, 0, 0, allocator)
	if _, err := append(&t.labels, BOTTOM); err != nil {
		table_destroy(t)
		return .Out_Of_Memory
	}
	if e := index_rebuild(t, INDEX_MIN); e != .None {
		table_destroy(t)
		return e
	}
	return .None
}

table_destroy :: proc(t: ^Table) {
	delete(t.labels)
	delete(t.index, t.allocator)
	t^ = Table{}
}

table_count :: #force_inline proc "contextless" (t: ^Table) -> int {
	return len(t.labels)
}

table_label :: proc "contextless" (t: ^Table, id: Id) -> (Label, bool) {
	if int(id) >= len(t.labels) {
		return {}, false
	}
	return t.labels[id], true
}

table_find :: proc "contextless" (t: ^Table, l: Label) -> (Id, bool) {
	if len(t.index) == 0 {
		return ID_NONE, false
	}
	mask := len(t.index) - 1
	for i := int(label_hash(l)) & mask; t.index[i] != INDEX_EMPTY; i = (i + 1) & mask {
		id := t.index[i]
		if t.labels[id] == l {
			return Id(id), true
		}
	}
	return ID_NONE, false
}

table_intern :: proc(t: ^Table, l: Label) -> (Id, Error) {
	if len(t.index) == 0 {
		return ID_NONE, .Invalid_Label
	}
	if id, found := table_find(t, l); found {
		return id, .None
	}
	if len(t.labels) >= LABEL_LIMIT {
		return ID_NONE, .Table_Full
	}
	if 2 * (len(t.labels) + 1) > len(t.index) {
		if e := index_rebuild(t, 2 * len(t.index)); e != .None {
			return ID_NONE, e
		}
	}
	id := u16(len(t.labels))
	if _, err := append(&t.labels, l); err != nil {
		return ID_NONE, .Out_Of_Memory
	}
	index_insert(t.index, t.labels[:], id)
	return Id(id), .None
}

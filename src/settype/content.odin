package settype

import lp "../listpack"

content_memory :: proc "contextless" (s: Set) -> int {
	if s == nil {
		return 0
	}
	n := lp.content_block(size_of(Set_Object))
	switch s.encoding {
	case .Intset:
		n += lp.content_block(intset_blob_len(s.data))
	case .Listpack:
		n += lp.content_block(lp.lp_bytes(s.data))
	case .Hashtable:
		n += table_content(s.table)
	}
	return n
}

@(private = "file")
table_content :: proc "contextless" (t: ^Table) -> int {
	if t == nil {
		return 0
	}
	n := lp.content_block(size_of(Table)) + slots_content(cap_for(t.count))
	n += blobs_content(t.slots, t.cap)
	if t.resize != nil {
		n += blobs_content(t.resize.old_slots, t.resize.old_cap)
	}
	return n
}

@(private = "file")
blobs_content :: proc "contextless" (slots: [^]Slot, cap: int) -> int {
	n := 0
	for i in 0 ..< cap {
		b := slots[i].blob
		if blob_live(b) {
			n += lp.content_block(size_of(Blob) + int(b.len))
		}
	}
	return n
}

@(private = "file")
slots_content :: proc "contextless" (cap: int) -> int {
	n := cap * size_of(Slot)
	if n > SLOTS_HEAP_LIMIT {
		return n
	}
	return lp.content_block(n)
}

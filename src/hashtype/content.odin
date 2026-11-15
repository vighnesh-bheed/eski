package hashtype

import lp "../listpack"

content_memory :: proc "contextless" (h: Hash) -> int {
	if h == nil {
		return 0
	}
	n := lp.content_block(size_of(Hash_Object))
	if h.hfe != nil {
		n += lp.content_block(size_of(Hfe_Meta))
	}
	if h.encoding == .Hashtable {
		return n + table_content(h.table)
	}
	return n + lp.content_block(lp.lp_bytes(h.lp))
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
	if t.vol_len > 0 {
		room := 16
		for room < t.vol_len {
			room *= 2
		}
		n += lp.content_block(room * size_of(Vol_Item))
	}
	return n
}

@(private = "file")
blobs_content :: proc "contextless" (slots: [^]Slot, cap: int) -> int {
	n := 0
	for i in 0 ..< cap {
		b := slots[i].blob
		if blob_live(b) {
			n += lp.content_block(size_of(Blob) + int(b.flen) + int(b.vlen))
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

package zsettype

import lp "../listpack"

content_memory :: proc "contextless" (z: Zset) -> int {
	if z == nil {
		return 0
	}
	n := lp.content_block(size_of(Zset_Object))
	if z.encoding == .Listpack {
		return n + lp.content_block(lp.lp_bytes(z.lp))
	}
	return n + skiplist_content(z.sl)
}

@(private = "file")
skiplist_content :: proc "contextless" (sl: ^Skiplist) -> int {
	if sl == nil {
		return 0
	}
	n := lp.content_block(size_of(Skiplist)) + lp.content_block(size_of(Node) + MAX_LEVEL * size_of(Level))
	count := 0
	for x := sl_first(sl); x != nil; x = sl_next(x) {
		n += lp.content_block(size_of(Node) + size_of(Level) + int(x.mlen))
		count += 1
	}
	n += count * size_of(Level) / 3
	room := dict_cap_for(count) * size_of(^Node)
	if room > SLOTS_HEAP_LIMIT {
		return n + room
	}
	return n + lp.content_block(room)
}

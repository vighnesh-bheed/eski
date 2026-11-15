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

charge :: proc "contextless" (z: Zset) -> int {
	if z == nil {
		return 0
	}
	n := lp.content_block(size_of(Zset_Object))
	if z.encoding == .Listpack {
		return n + lp.content_block(lp.lp_bytes(z.lp))
	}
	sl := z.sl
	if sl == nil {
		return n
	}
	return n + skiplist_fixed_content(sl.length) + sl.content
}

node_charge :: #force_inline proc "contextless" (x: ^Node) -> int {
	return lp.content_block(size_of(Node) + size_of(Level) + int(x.mlen))
}

@(private = "file")
skiplist_content :: proc "contextless" (sl: ^Skiplist) -> int {
	if sl == nil {
		return 0
	}
	n := 0
	count := 0
	for x := sl_first(sl); x != nil; x = sl_next(x) {
		n += node_charge(x)
		count += 1
	}
	return n + skiplist_fixed_content(count)
}

@(private = "file")
skiplist_fixed_content :: proc "contextless" (count: int) -> int {
	n := lp.content_block(size_of(Skiplist)) + lp.content_block(size_of(Node) + MAX_LEVEL * size_of(Level))
	n += count * size_of(Level) / 3
	room := dict_cap_for(count) * size_of(^Node)
	if room > SLOTS_HEAP_LIMIT {
		return n + room
	}
	return n + lp.content_block(room)
}

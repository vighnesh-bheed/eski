package hnsw

import "base:runtime"

UPPER_GROWTH_FLOOR :: 256
UPPER_SLACK_DEN :: 4
UPPER_SHARE_DEN :: 3

upper_room :: #force_inline proc "contextless" (ix: ^Index, live: int) -> int {
	return max(live + live / UPPER_SLACK_DEN, ix.cap * (ix.m + 1) / UPPER_SHARE_DEN)
}

upper_bound :: #force_inline proc "contextless" (ix: ^Index, live: int) -> int {
	room := upper_room(ix, live)
	return max(UPPER_GROWTH_FLOOR, room + room / 2)
}

upper_compact :: proc(ix: ^Index) -> bool {
	live := upper_lists(ix) * (ix.m + 1)
	pool: [^]u8
	if live > 0 && !array_resize(&pool, 0, pool_bytes(live, ix.width), ix.allocator) {
		return false
	}
	at := 0
	for i in 0 ..< ix.slots {
		lv := ix.levels[i]
		if lv == 0 || lv > LEVEL_CAP {
			continue
		}
		words := upper_words(ix, int(lv))
		runtime.mem_copy_non_overlapping(&pool[at * ix.width], &ix.upper[int(ix.upper_at[i]) * ix.width], words * ix.width)
		ix.upper_at[i] = u32(at)
		at += words
	}
	array_free(ix.upper, pool_bytes(ix.upper_cap, ix.width), ix.allocator)
	ix.upper = pool
	ix.upper_len = live
	ix.upper_cap = live
	for level in 0 ..= LEVEL_CAP {
		ix.upper_free[level] = NONE
	}
	return true
}

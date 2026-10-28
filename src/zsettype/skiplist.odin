package zsettype

import "base:intrinsics"
import "base:runtime"
import "core:hash/xxhash"

MAX_LEVEL :: 32

MAX_SEARCH :: 10

DICT_MIN_CAP :: 4

Level :: struct {
	forward: ^Node,
	span:    u64,
}

Node :: struct {
	score:    f64,
	backward: ^Node,
	hash:     u64,
	mlen:     u32,
	nlevel:   u32,
}

Skiplist :: struct {
	header: ^Node,
	tail:   ^Node,
	length: int,
	level:  int,
	slots:  [^]^Node,
	cap:    int,
	count:  int,
	bytes:  int,
	resize: ^Resize_State,
}

sl_rng: u64 = 0x9E3779B97F4A7C15

hash_seed: u64 = 0x2545F4914F6CDD1D

EMPTY_MEMBER := [1]u8{0}

set_seed :: proc "contextless" (seed: u64) {
	hash_seed = seed
	sl_rng = seed ~ 0x9E3779B97F4A7C15
	if sl_rng == 0 {
		sl_rng = 1
	}
}

hash_member :: proc(member: []u8) -> u64 {
	if len(member) == 0 {
		return xxhash.XXH3_64_with_seed(EMPTY_MEMBER[:0], hash_seed)
	}
	return xxhash.XXH3_64_with_seed(member, hash_seed)
}

rng_next :: proc "contextless" () -> u64 {
	x := sl_rng
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	sl_rng = x
	return x
}

random_level :: proc "contextless" () -> int {
	level := 1
	for level < MAX_LEVEL && rng_next() & 3 == 0 {
		level += 1
	}
	return level
}

node_levels :: proc "contextless" (n: ^Node) -> [^]Level {
	return cast([^]Level)(uintptr(n) + size_of(Node))
}

node_member :: proc "contextless" (n: ^Node) -> []u8 {
	p := cast([^]u8)(uintptr(n) + size_of(Node) + uintptr(n.nlevel) * size_of(Level))
	return p[:int(n.mlen)]
}

fwd :: proc "contextless" (n: ^Node, i: int) -> ^Node {
	return node_levels(n)[i].forward
}

member_cmp :: proc "contextless" (a, b: []u8) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}

member_eq :: proc "contextless" (a, b: []u8) -> bool {
	return member_cmp(a, b) == 0
}

node_new :: proc "contextless" (sl: ^Skiplist, level: int, score: f64, member: []u8, h: u64) -> ^Node {
	assert_contextless(level >= 1 && level <= MAX_LEVEL)
	assert_contextless(len(member) <= int(max(u32)))
	n := cast(^Node)mem_alloc_zero(size_of(Node) + size_of(Level) * level + len(member))
	n.score = score
	n.hash = h
	n.mlen = u32(len(member))
	n.nlevel = u32(level)
	copy(node_member(n), member)
	sl.bytes += mem_usable_size(n)
	return n
}

node_free :: proc "contextless" (sl: ^Skiplist, n: ^Node) {
	if n != nil {
		sl.bytes -= mem_usable_size(n)
		mem_free(n)
	}
}

sl_create :: proc "contextless" (expected: int) -> ^Skiplist {
	sl := cast(^Skiplist)mem_alloc_zero(size_of(Skiplist))
	sl.level = 1
	sl.header = node_new(sl, MAX_LEVEL, 0, nil, 0)
	sl.bytes = 0
	sl.cap = dict_cap_for(expected)
	sl.slots = slots_alloc(sl.cap)
	return sl
}

sl_free :: proc "contextless" (sl: ^Skiplist) {
	if sl == nil {
		return
	}
	if sl.resize != nil {
		r := sl.resize
		resize_unlink(r)
		slots_free(r.old_slots, r.old_cap)
		sl.resize = nil
		mem_free(r)
	}
	n := sl_first(sl)
	for n != nil {
		next := sl_next(n)
		node_free(sl, n)
		n = next
	}
	mem_free(sl.header)
	slots_free(sl.slots, sl.cap)
	mem_free(sl)
}

sl_memory :: proc "contextless" (sl: ^Skiplist) -> int {
	if sl == nil {
		return 0
	}
	n := mem_usable_size(sl) + mem_usable_size(sl.header) + sl.bytes + slots_memory(sl.slots, sl.cap)
	if sl.resize != nil {
		n += mem_usable_size(sl.resize) + slots_memory(sl.resize.old_slots, sl.resize.old_cap)
	}
	return n
}

sl_first :: proc "contextless" (sl: ^Skiplist) -> ^Node {
	return fwd(sl.header, 0)
}

sl_next :: proc "contextless" (n: ^Node) -> ^Node {
	return fwd(n, 0)
}

sl_seek :: proc "contextless" (sl: ^Skiplist, score: f64, member: []u8, update: ^[MAX_LEVEL]^Node) -> ^Node {
	n := sl.header
	for level := sl.level - 1; level >= 0; level -= 1 {
		for next := fwd(n, level); next != nil; next = fwd(n, level) {
			if next.score > score || next.score == score && member_cmp(node_member(next), member) >= 0 {
				break
			}
			n = next
		}
		if update != nil {
			update[level] = n
		}
	}
	return sl_next(n)
}

sl_insert_node :: proc "contextless" (sl: ^Skiplist, x: ^Node) {
	update: [MAX_LEVEL]^Node
	ranks: [MAX_LEVEL]u64
	n := sl.header
	member := node_member(x)
	for level := sl.level - 1; level >= 0; level -= 1 {
		if level + 1 < sl.level {
			ranks[level] = ranks[level + 1]
		}
		for next := fwd(n, level); next != nil; next = fwd(n, level) {
			if next.score > x.score || next.score == x.score && member_cmp(node_member(next), member) >= 0 {
				break
			}
			ranks[level] += node_levels(n)[level].span
			n = next
		}
		update[level] = n
	}
	height := int(x.nlevel)
	for level in sl.level ..< height {
		update[level] = sl.header
		node_levels(sl.header)[level].span = u64(sl.length)
	}
	sl.level = max(sl.level, height)
	for level in 0 ..< sl.level {
		before := &node_levels(update[level])[level]
		if level < height {
			gap := ranks[0] - ranks[level]
			node_levels(x)[level] = Level{before.forward, before.span - gap}
			before.forward = x
			before.span = gap + 1
		} else {
			before.span += 1
		}
	}
	x.backward = update[0]
	if x.backward == sl.header {
		x.backward = nil
	}
	if next := sl_next(x); next != nil {
		next.backward = x
	} else {
		sl.tail = x
	}
	sl.length += 1
}

sl_delete_node :: proc "contextless" (sl: ^Skiplist, x: ^Node, update: ^[MAX_LEVEL]^Node) {
	for level in 0 ..< sl.level {
		before := &node_levels(update[level])[level]
		if before.forward == x {
			before.span = before.span + node_levels(x)[level].span - 1
			before.forward = fwd(x, level)
		} else {
			before.span -= 1
		}
	}
	if next := sl_next(x); next != nil {
		next.backward = x.backward
	} else {
		sl.tail = x.backward
	}
	sl.length -= 1
	for sl.level > 1 && fwd(sl.header, sl.level - 1) == nil {
		sl.level -= 1
	}
}

sl_insert :: proc "contextless" (sl: ^Skiplist, score: f64, member: []u8, h: u64) -> ^Node {
	n := node_new(sl, random_level(), score, member, h)
	sl_insert_node(sl, n)
	dict_add(sl, n)
	return n
}

sl_remove :: proc "contextless" (sl: ^Skiplist, x: ^Node) {
	update: [MAX_LEVEL]^Node
	found := sl_seek(sl, x.score, node_member(x), &update)
	assert_contextless(found == x)
	dict_remove(sl, x)
	sl_delete_node(sl, x, &update)
	node_free(sl, x)
	dict_after_remove(sl)
}

sl_update_score :: proc "contextless" (sl: ^Skiplist, x: ^Node, newscore: f64) {
	if x.score == newscore {
		return
	}
	update: [MAX_LEVEL]^Node
	found := sl_seek(sl, x.score, node_member(x), &update)
	assert_contextless(found == x)
	sl_delete_node(sl, x, &update)
	x.score = newscore
	sl_insert_node(sl, x)
	_ = dict_step(sl, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
}

sl_get_rank :: proc "contextless" (sl: ^Skiplist, score: f64, member: []u8) -> u64 {
	n := sl.header
	rank: u64
	for level := sl.level - 1; level >= 0; level -= 1 {
		for next := fwd(n, level); next != nil; next = fwd(n, level) {
			if next.score > score || next.score == score && member_cmp(node_member(next), member) > 0 {
				break
			}
			rank += node_levels(n)[level].span
			n = next
		}
		if n != sl.header && n.score == score && member_eq(node_member(n), member) {
			return rank
		}
	}
	return 0
}

sl_get_by_rank_from :: proc "contextless" (start: ^Node, start_level: int, rank: u64) -> ^Node {
	n := start
	left := rank
	for level := min(start_level, int(start.nlevel) - 1); level >= 0; level -= 1 {
		for fwd(n, level) != nil && node_levels(n)[level].span <= left {
			left -= node_levels(n)[level].span
			n = fwd(n, level)
		}
		if left == 0 {
			return n
		}
	}
	return nil
}

sl_get_by_rank :: proc "contextless" (sl: ^Skiplist, rank: u64) -> ^Node {
	if rank > u64(sl.length) {
		return nil
	}
	return sl_get_by_rank_from(sl.header, sl.level - 1, rank)
}

assert_contextless :: proc "contextless" (cond: bool) {
	if !cond {
		runtime.debug_trap()
	}
}

dict_count :: proc "contextless" (sl: ^Skiplist) -> int {
	return sl.count
}

slots_find :: proc "contextless" (slots: [^]^Node, cap: int, member: []u8, h: u64) -> ^^Node {
	if slots == nil || cap == 0 {
		return nil
	}
	mask := u64(cap - 1)
	pos := h & mask
	for _ in 0 ..< cap {
		n := slots[pos]
		if n == nil {
			return nil
		}
		if node_live(n) && n.hash == h && member_eq(node_member(n), member) {
			return &slots[pos]
		}
		pos = (pos + 1) & mask
	}
	return nil
}

dict_find :: proc "contextless" (sl: ^Skiplist, member: []u8, h: u64) -> ^Node {
	if slot := slots_find(sl.slots, sl.cap, member, h); slot != nil {
		return slot^
	}
	if sl.resize != nil {
		if slot := slots_find(sl.resize.old_slots, sl.resize.old_cap, member, h); slot != nil {
			return slot^
		}
	}
	return nil
}

dict_place :: proc "contextless" (slots: [^]^Node, mask: u64, n: ^Node) -> (probes: int) {
	pos := n.hash & mask
	for {
		probes += 1
		if !node_live(slots[pos]) {
			slots[pos] = n
			return
		}
		pos = (pos + 1) & mask
		assert_contextless(probes <= int(mask + 1))
	}
}

rand_below :: proc "contextless" (n: u64) -> u64 {
	if n <= 1 {
		return 0
	}
	threshold := (0 - n) % n
	for {
		v := rng_next()
		if v >= threshold {
			return v % n
		}
	}
}

dict_random_node :: proc "contextless" (sl: ^Skiplist, probe_budget: int = 4096) -> ^Node {
	n := dict_count(sl)
	if n == 0 {
		return nil
	}
	return sl_get_by_rank(sl, rand_below(u64(n)) + 1)
}

slots_scan_bucket :: proc(slots: [^]^Node, cap: int, bucket: u64, fn: proc(user: rawptr, n: ^Node), user: rawptr) {
	if cap == 0 {
		return
	}
	mask := u64(cap - 1)
	pos := bucket & mask
	for _ in 0 ..< cap {
		n := slots[pos]
		if n == nil {
			return
		}
		if node_live(n) && n.hash & mask == bucket & mask {
			fn(user, n)
		}
		pos = (pos + 1) & mask
	}
}

dict_scan_bucket :: proc(sl: ^Skiplist, v: u64, fn: proc(user: rawptr, n: ^Node), user: rawptr) -> u64 {
	if dict_count(sl) == 0 {
		return 0
	}
	small_slots, small_cap := sl.slots, sl.cap
	large_slots: [^]^Node
	large_cap := 0
	if sl.resize != nil {
		large_slots, large_cap = sl.resize.old_slots, sl.resize.old_cap
		if small_cap > large_cap {
			small_slots, large_slots = large_slots, small_slots
			small_cap, large_cap = large_cap, small_cap
		}
	}
	mask := u64(small_cap - 1)
	bucket := v & mask
	slots_scan_bucket(small_slots, small_cap, bucket, fn, user)
	if large_cap != 0 {
		for b := bucket; b < u64(large_cap); b += u64(small_cap) {
			slots_scan_bucket(large_slots, large_cap, b, fn, user)
		}
	}
	next := v | ~mask
	next = intrinsics.reverse_bits(next)
	next += 1
	return intrinsics.reverse_bits(next)
}

dict_cap_for :: proc "contextless" (n: int) -> int {
	resize_require(n >= 0 && n <= max(int) / size_of(^Node) / 4)
	cap := DICT_MIN_CAP
	for n >= cap - cap / 4 {
		resize_require(cap <= max(int) / (2 * size_of(^Node)))
		cap *= 2
	}
	return cap
}

dict_resize :: proc "contextless" (sl: ^Skiplist, new_cap: int) {
	if sl.resize != nil || new_cap == sl.cap {
		return
	}
	resize_require(new_cap >= DICT_MIN_CAP && new_cap & (new_cap - 1) == 0)
	resize_require(new_cap <= max(int) / size_of(^Node))
	resize_require(sl.count < new_cap)
	slots := slots_alloc(new_cap)
	r := cast(^Resize_State)mem_alloc_zero(size_of(Resize_State))
	resize_require(r != nil)
	r.target = sl
	r.old_slots = sl.slots
	r.old_cap = sl.cap
	r.old_count = sl.count
	sl.slots = slots
	sl.cap = new_cap
	sl.resize = r
}

dict_add :: proc "contextless" (sl: ^Skiplist, x: ^Node) {
	if sl.cap == 0 {
		sl.cap = DICT_MIN_CAP
		sl.slots = slots_alloc(sl.cap)
	}
	if sl.resize == nil && sl.count + 1 > sl.cap - sl.cap / 4 {
		resize_require(sl.cap <= max(int) / (2 * size_of(^Node)))
		dict_resize(sl, sl.cap * 2)
	}
	_ = dict_place(sl.slots, u64(sl.cap - 1), x)
	sl.count += 1
	_ = dict_step(sl, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
}

dict_remove :: proc "contextless" (sl: ^Skiplist, x: ^Node) {
	member := node_member(x)
	if slot := slots_find(sl.slots, sl.cap, member, x.hash); slot != nil {
		mask := u64(sl.cap - 1)
		hole := u64((uintptr(slot) - uintptr(sl.slots)) / size_of(^Node))
		pos := (hole + 1) & mask
		for sl.slots[pos] != nil {
			n := sl.slots[pos]
			home := n.hash & mask
			if (pos - home) & mask >= (hole - home) & mask {
				sl.slots[hole] = n
				hole = pos
			}
			pos = (pos + 1) & mask
		}
		sl.slots[hole] = nil
	} else {
		assert_contextless(sl.resize != nil)
		old_slot := slots_find(sl.resize.old_slots, sl.resize.old_cap, member, x.hash)
		assert_contextless(old_slot != nil)
		old_slot^ = TOMBSTONE
		sl.resize.old_count -= 1
	}
	sl.count -= 1
}

dict_shrink_if_needed :: proc "contextless" (sl: ^Skiplist) {
	if sl.resize == nil && sl.cap > DICT_MIN_CAP && sl.count <= sl.cap / 8 {
		dict_resize(sl, sl.cap / 2)
	}
}

dict_after_remove :: proc "contextless" (sl: ^Skiplist) {
	if sl.count == 0 {
		dict_empty(sl)
		return
	}
	dict_shrink_if_needed(sl)
	_ = dict_step(sl, RESIZE_WRITE_SCANS, RESIZE_WRITE_MOVES)
}

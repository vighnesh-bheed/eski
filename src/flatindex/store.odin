package flatindex

import "base:runtime"
import "../vmath"

dead_words :: #force_inline proc "contextless" (n: int) -> int {
	return (n + 63) >> 6
}

is_dead :: #force_inline proc "contextless" (blk: ^Block, l: int) -> bool #no_bounds_check {
	return (blk.dead[l >> 6] >> uint(l & 63)) & 1 != 0
}

mark_dead :: #force_inline proc "contextless" (blk: ^Block, l: int) #no_bounds_check {
	blk.dead[l >> 6] |= u64(1) << uint(l & 63)
}

unmark_dead :: #force_inline proc "contextless" (blk: ^Block, l: int) #no_bounds_check {
	blk.dead[l >> 6] &~= u64(1) << uint(l & 63)
}

block_cap :: #force_inline proc "contextless" (blk: ^Block) -> int {
	return len(blk.ids)
}

lower_bound :: proc "contextless" (ids: []u32, lo: int, hi: int, id: u32) -> int #no_bounds_check {
	a, b := lo, hi
	for a < b {
		mid := int(uint(a + b) >> 1)
		if ids[mid] < id {
			a = mid + 1
		} else {
			b = mid
		}
	}
	return a
}

gallop :: proc "contextless" (ids: []u32, from: int, hi: int, id: u32) -> int #no_bounds_check {
	if from >= hi || ids[from] >= id {
		return from
	}
	lo := from
	step := 1
	for {
		probe := lo + step
		if probe >= hi {
			return lower_bound(ids, lo + 1, hi, id)
		}
		if ids[probe] >= id {
			return lower_bound(ids, lo + 1, probe, id)
		}
		lo = probe
		step <<= 1
	}
}

find_block :: proc "contextless" (ix: ^Index, id: u32) -> int #no_bounds_check {
	n := len(ix.firsts)
	if n == 0 {
		return -1
	}
	a, b := 0, n
	for a < b {
		mid := int(uint(a + b) >> 1)
		if ix.firsts[mid] <= id {
			a = mid + 1
		} else {
			b = mid
		}
	}
	return max(a - 1, 0)
}

locate :: proc "contextless" (ix: ^Index, id: u32) -> (b: int, l: int, ok: bool) {
	b = find_block(ix, id)
	if b < 0 {
		return
	}
	blk := &ix.blocks[b]
	l = lower_bound(blk.ids, 0, blk.used, id)
	ok = l < blk.used && blk.ids[l] == id && !is_dead(blk, l)
	return
}

contains :: proc "contextless" (ix: ^Index, id: u32) -> bool {
	_, _, ok := locate(ix, id)
	return ok
}

stored :: proc "contextless" (ix: ^Index, id: u32) -> (data: []u8, aux: f32, ok: bool) {
	b, l, found := locate(ix, id)
	if !found {
		return
	}
	a := &ix.blocks[b].arena
	return vmath.arena_bytes(a, u32(l)), vmath.arena_aux(a, u32(l)), true
}

block_make :: proc(ix: ^Index, capacity: int) -> (blk: Block, err: Error) {
	if vmath.arena_init(&blk.arena, ix.spec.elem, ix.spec.metric, ix.spec.dim, ix.allocator, capacity, .Search) != nil {
		return {}, .Out_Of_Memory
	}
	ids, ierr := make([]u32, capacity, ix.allocator)
	if ierr != nil {
		vmath.arena_destroy(&blk.arena)
		return {}, .Out_Of_Memory
	}
	dead, derr := make([]u64, dead_words(capacity), ix.allocator)
	if derr != nil {
		delete(ids, ix.allocator)
		vmath.arena_destroy(&blk.arena)
		return {}, .Out_Of_Memory
	}
	blk.ids = ids
	blk.dead = dead
	return blk, .None
}

block_free :: proc(ix: ^Index, blk: ^Block) {
	vmath.arena_destroy(&blk.arena)
	delete(blk.ids, ix.allocator)
	delete(blk.dead, ix.allocator)
	blk^ = {}
}

block_grow :: proc(ix: ^Index, blk: ^Block, want: int) -> Error {
	old := block_cap(blk)
	n := min(ix.block, max(want, old + max(old >> 1, 1)))
	if n <= old {
		return .Out_Of_Memory
	}
	blk.arena.high = u32(blk.used)
	if vmath.arena_reserve(&blk.arena, n) != nil {
		return .Out_Of_Memory
	}
	ids, ierr := make([]u32, n, ix.allocator)
	if ierr != nil {
		return .Out_Of_Memory
	}
	dead, derr := make([]u64, dead_words(n), ix.allocator)
	if derr != nil {
		delete(ids, ix.allocator)
		return .Out_Of_Memory
	}
	copy(ids, blk.ids[:blk.used])
	copy(dead, blk.dead)
	delete(blk.ids, ix.allocator)
	delete(blk.dead, ix.allocator)
	blk.ids = ids
	blk.dead = dead
	return .None
}

block_insert :: proc(ix: ^Index, at: int, blk: Block) -> Error {
	if cap(ix.blocks) == 0 {
		if reserve(&ix.blocks, 1) != nil || reserve(&ix.firsts, 1) != nil {
			return .Out_Of_Memory
		}
	}
	if _, err := inject_at(&ix.blocks, at, blk); err != nil {
		return .Out_Of_Memory
	}
	first := blk.ids[0] if blk.used > 0 else 0
	if _, err := inject_at(&ix.firsts, at, first); err != nil {
		ordered_remove(&ix.blocks, at)
		return .Out_Of_Memory
	}
	return .None
}

block_drop :: proc(ix: ^Index, b: int) {
	block_free(ix, &ix.blocks[b])
	ordered_remove(&ix.blocks, b)
	ordered_remove(&ix.firsts, b)
}

sync_first :: #force_inline proc "contextless" (ix: ^Index, b: int) {
	blk := &ix.blocks[b]
	if blk.used > 0 {
		ix.firsts[b] = blk.ids[0]
	}
}

slots_move :: proc "contextless" (ix: ^Index, dst: ^Block, d: int, src: ^Block, s: int, n: int) {
	if n <= 0 || (dst == src && d == s) {
		return
	}
	stride := ix.stride
	runtime.mem_copy(&dst.arena.vectors[d * stride], &src.arena.vectors[s * stride], n * stride)
	runtime.mem_copy(&dst.arena.norms[d], &src.arena.norms[s], n * size_of(f32))
	runtime.mem_copy(&dst.ids[d], &src.ids[s], n * size_of(u32))
}

slot_write :: #force_inline proc "contextless" (blk: ^Block, l: int, id: u32, blob: []u8) {
	vmath.arena_set_blob(&blk.arena, u32(l), blob)
	blk.ids[l] = id
}

block_compact :: proc "contextless" (ix: ^Index, b: int) {
	blk := &ix.blocks[b]
	if blk.live == blk.used {
		return
	}
	w := 0
	r := 0
	for r < blk.used {
		if is_dead(blk, r) {
			r += 1
			continue
		}
		run := r
		for r < blk.used && !is_dead(blk, r) {
			r += 1
		}
		slots_move(ix, blk, w, blk, run, r - run)
		w += r - run
	}
	for &word in blk.dead {
		word = 0
	}
	ix.dead -= blk.used - w
	blk.used = w
	blk.arena.high = u32(w)
	sync_first(ix, b)
}

trim_tail :: proc "contextless" (ix: ^Index, blk: ^Block) {
	for blk.used > 0 && is_dead(blk, blk.used - 1) {
		unmark_dead(blk, blk.used - 1)
		blk.used -= 1
		ix.dead -= 1
	}
	blk.arena.high = u32(blk.used)
}

block_merge :: proc(ix: ^Index, b: int) -> Error {
	block_compact(ix, b)
	block_compact(ix, b + 1)
	dst := &ix.blocks[b]
	need := dst.used + ix.blocks[b + 1].used
	if need > block_cap(dst) {
		block_grow(ix, dst, need) or_return
	}
	src := &ix.blocks[b + 1]
	slots_move(ix, dst, dst.used, src, 0, src.used)
	dst.used += src.used
	dst.live += src.live
	dst.arena.high = u32(dst.used)
	block_drop(ix, b + 1)
	return .None
}

settle :: proc(ix: ^Index, b: int) {
	blk := &ix.blocks[b]
	if (blk.used - blk.live) * 2 < blk.used {
		return
	}
	block_compact(ix, b)
	at := b
	if at + 1 < len(ix.blocks) && ix.blocks[at].live + ix.blocks[at + 1].live <= ix.block {
		if block_merge(ix, at) != .None {
			return
		}
	}
	if at > 0 && ix.blocks[at - 1].live + ix.blocks[at].live <= ix.block {
		block_merge(ix, at - 1)
	}
}

new_block_cap :: proc "contextless" (ix: ^Index, after_full: bool) -> int {
	if after_full {
		return min(ix.block, NEW_BLOCK_MAX)
	}
	return min(ix.block, GROWTH_MIN)
}

block_push :: proc(ix: ^Index, at: int, capacity: int, id: u32, blob: []u8) -> Error {
	blk := block_make(ix, capacity) or_return
	slot_write(&blk, 0, id, blob)
	blk.used = 1
	blk.live = 1
	blk.arena.high = 1
	if err := block_insert(ix, at, blk); err != .None {
		block_free(ix, &blk)
		return err
	}
	ix.count += 1
	return .None
}

block_split :: proc(ix: ^Index, b: int) -> Error {
	block_compact(ix, b)
	nb := block_make(ix, block_cap(&ix.blocks[b])) or_return
	blk := &ix.blocks[b]
	mid := blk.used / 2
	moved := blk.used - mid
	slots_move(ix, &nb, 0, blk, mid, moved)
	nb.used = moved
	nb.live = moved
	nb.arena.high = u32(moved)
	blk.used = mid
	blk.live = mid
	blk.arena.high = u32(mid)
	if err := block_insert(ix, b + 1, nb); err != .None {
		blk = &ix.blocks[b]
		slots_move(ix, blk, mid, &nb, 0, moved)
		blk.used += moved
		blk.live += moved
		blk.arena.high = u32(blk.used)
		block_free(ix, &nb)
		return err
	}
	return .None
}

shift_insert :: proc "contextless" (ix: ^Index, b: int, p: int, id: u32, blob: []u8) {
	blk := &ix.blocks[b]
	slots_move(ix, blk, p + 1, blk, p, blk.used - p)
	slot_write(blk, p, id, blob)
	blk.used += 1
	blk.live += 1
	blk.arena.high = u32(blk.used)
	ix.count += 1
	if p == 0 {
		ix.firsts[b] = id
	}
}

insert_at :: proc(ix: ^Index, b: int, p: int, id: u32, blob: []u8) -> Error {
	bi := b
	pos := p
	blk := &ix.blocks[bi]
	if blk.used == block_cap(blk) {
		switch {
		case block_cap(blk) < ix.block:
			block_grow(ix, blk, blk.used + 1) or_return
		case blk.live < blk.used:
			block_compact(ix, bi)
			pos = lower_bound(blk.ids, 0, blk.used, id)
		case pos == blk.used:
			last := bi + 1 == len(ix.blocks)
			return block_push(ix, bi + 1, new_block_cap(ix, last), id, blob)
		case blk.used < 2:
			return block_push(ix, bi + pos, new_block_cap(ix, false), id, blob)
		case:
			block_split(ix, bi) or_return
			mid := ix.blocks[bi].used
			if pos > mid {
				bi += 1
				pos -= mid
			}
		}
		blk = &ix.blocks[bi]
	}
	if pos < blk.used && blk.live < blk.used {
		block_compact(ix, bi)
		pos = lower_bound(blk.ids, 0, blk.used, id)
	}
	shift_insert(ix, bi, pos, id, blob)
	return .None
}

revive :: proc "contextless" (ix: ^Index, b: int, l: int, id: u32, blob: []u8) {
	blk := &ix.blocks[b]
	slot_write(blk, l, id, blob)
	unmark_dead(blk, l)
	blk.live += 1
	ix.count += 1
	ix.dead -= 1
	if l == 0 {
		ix.firsts[b] = id
	}
}

add :: proc(ix: ^Index, id: u32, blob: []u8) -> (replaced: bool, err: Error) {
	if id == ID_NONE {
		return false, .Invalid_Id
	}
	if len(blob) != ix.stride {
		return false, .Blob_Size
	}
	if len(ix.blocks) == 0 {
		return false, block_push(ix, 0, ix.first_cap, id, blob)
	}
	b := find_block(ix, id)
	blk := &ix.blocks[b]
	p := lower_bound(blk.ids, 0, blk.used, id)
	if p < blk.used && blk.ids[p] == id {
		if is_dead(blk, p) {
			revive(ix, b, p, id, blob)
			return false, .None
		}
		slot_write(blk, p, id, blob)
		return true, .None
	}
	if p > 0 && is_dead(blk, p - 1) {
		revive(ix, b, p - 1, id, blob)
		return false, .None
	}
	if p < blk.used && is_dead(blk, p) {
		revive(ix, b, p, id, blob)
		return false, .None
	}
	return false, insert_at(ix, b, p, id, blob)
}

remove :: proc(ix: ^Index, id: u32) -> Error {
	b, l, ok := locate(ix, id)
	if !ok {
		return .Not_Found
	}
	blk := &ix.blocks[b]
	mark_dead(blk, l)
	blk.live -= 1
	ix.count -= 1
	ix.dead += 1
	if blk.live == 0 {
		ix.dead -= blk.used
		block_drop(ix, b)
		return .None
	}
	trim_tail(ix, blk)
	settle(ix, b)
	return .None
}

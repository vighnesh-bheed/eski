package hnsw

import "base:runtime"

Restore_Fault :: enum u8 {
	None,
	Out_Of_Memory,
	Level,
	Degree,
	Link_Range,
	Link_Self,
	Link_Repeat,
	Link_Target,
	Asymmetric,
	Entry,
	Twin_Prev,
	Twin_Fork,
	Twin_Cycle,
	Twin_Table,
	Counts,
}

restore_reserve :: proc(ix: ^Index, cap: int, slots: int, free: []u32, twin_table: bool) -> Error {
	if ix.cap != 0 || ix.slots != 0 || cap < slots || slots < 0 || cap > SLOT_LIMIT {
		return .Invalid_Parameter
	}
	if cap > 0 {
		if err := reserve_capacity(ix, cap); err != .None {
			return err
		}
	}
	for i in 0 ..< slots {
		slot, err := reserve(ix)
		if err != .None || int(slot) != i {
			return .Out_Of_Memory if err == .None else err
		}
	}
	for i := len(free) - 1; i >= 0; i -= 1 {
		if release(ix, free[i]) != .None {
			return .Invalid_Parameter
		}
	}
	if twin_table && ix.cap > 0 {
		if !array_resize(&ix.twin_link, 0, ix.cap, ix.allocator) {
			return .Out_Of_Memory
		}
		ix.twin_cap = ix.cap
		for i in 0 ..< ix.cap {
			ix.twin_link[i] = NONE
		}
	}
	return .None
}

restore_node :: proc(ix: ^Index, slot: u32, level: int) -> Error {
	if int(slot) >= ix.slots || ix.levels[slot] != LEVEL_RESERVED || level < 0 || level > LEVEL_CAP {
		return .Invalid_Parameter
	}
	ix.upper_at[slot] = NONE
	if level > 0 {
		offset, err := upper_alloc(ix, level)
		if err != .None {
			return err
		}
		ix.upper_at[slot] = offset
	}
	ix.levels[slot] = u8(level)
	ix.degree0[slot] = 0
	return .None
}

restore_twin :: proc "contextless" (ix: ^Index, slot: u32, prev: u32) -> Error {
	if int(slot) >= ix.slots || ix.levels[slot] != LEVEL_RESERVED || ix.twin_link == nil {
		return .Invalid_Parameter
	}
	ix.levels[slot] = LEVEL_TWIN
	ix.degree0[slot] = 0
	ix.upper_at[slot] = NONE
	twin_prev_set(ix, slot, prev)
	return .None
}

restore_list :: proc "contextless" (ix: ^Index, slot: u32, layer: int, ids: []u32) -> Error {
	if int(slot) >= ix.slots || ix.levels[slot] > LEVEL_CAP || layer < 0 || layer > int(ix.levels[slot]) || len(ids) > layer_cap(ix, layer) {
		return .Invalid_Parameter
	}
	l := list_get(ix, slot, layer)
	for id, i in ids {
		list_put(ix, l, i, id)
	}
	list_set_count(ix, slot, layer, len(ids))
	return .None
}

restore_finish :: proc(ix: ^Index, entry: u32, max_level: int, rng: u64, node_uid: u64, twins: int) -> Restore_Fault {
	live := 0
	for i in 0 ..< ix.slots {
		lv := ix.levels[i]
		if lv == LEVEL_RESERVED {
			return .Level
		}
		if lv != LEVEL_FREE {
			live += 1
		}
	}
	ix.entry = entry
	ix.max_level = max_level
	ix.rng = rng
	ix.node_uid = node_uid
	ix.live = live
	ix.twins = twins
	return restore_check(ix)
}

Restore_Work :: struct {
	stamp:  []u32,
	next:   []u32,
	start:  []int,
	fill:   []int,
	edges:  [dynamic]u32,
	buf:    []u32,
}

restore_work_make :: proc(n: int, m0: int, allocator: runtime.Allocator) -> (w: Restore_Work, ok: bool) {
	err: runtime.Allocator_Error
	if w.stamp, err = make([]u32, n, allocator); err != nil {
		return w, false
	}
	if w.next, err = make([]u32, n, allocator); err != nil {
		restore_work_free(&w, allocator)
		return w, false
	}
	if w.start, err = make([]int, n + 1, allocator); err != nil {
		restore_work_free(&w, allocator)
		return w, false
	}
	if w.fill, err = make([]int, n, allocator); err != nil {
		restore_work_free(&w, allocator)
		return w, false
	}
	if w.buf, err = make([]u32, max(m0, 1), allocator); err != nil {
		restore_work_free(&w, allocator)
		return w, false
	}
	w.edges = make([dynamic]u32, 0, 0, allocator)
	return w, true
}

restore_work_free :: proc(w: ^Restore_Work, allocator: runtime.Allocator) {
	delete(w.stamp, allocator)
	delete(w.next, allocator)
	delete(w.start, allocator)
	delete(w.fill, allocator)
	delete(w.buf, allocator)
	delete(w.edges)
	w^ = {}
}

restore_check :: proc(ix: ^Index) -> Restore_Fault {
	n := ix.slots
	if n == 0 {
		return .Counts if ix.live != 0 || ix.entry != NONE || ix.twins != 0 else .None
	}
	w, made := restore_work_make(n, ix.m0, context.allocator)
	if !made {
		return .Out_Of_Memory
	}
	defer restore_work_free(&w, context.allocator)
	top := -1
	twins := 0
	live := 0
	for i in 0 ..< n {
		lv := ix.levels[i]
		switch {
		case lv <= LEVEL_CAP:
			top = max(top, int(lv))
			live += 1
		case lv == LEVEL_TWIN:
			twins += 1
			live += 1
		case lv == LEVEL_FREE:
		case:
			return .Level
		}
	}
	if live != ix.live || twins != ix.twins || top < 0 {
		return .Counts
	}
	if ix.max_level != top || int(ix.entry) >= n || ix.levels[ix.entry] > LEVEL_CAP || int(ix.levels[ix.entry]) != top {
		return .Entry
	}
	for layer in 0 ..= top {
		if f := restore_layer(ix, &w, layer); f != .None {
			return f
		}
	}
	return restore_twins(ix, &w, twins)
}

restore_layer :: proc(ix: ^Index, w: ^Restore_Work, layer: int) -> Restore_Fault {
	n := ix.slots
	cap := layer_cap(ix, layer)
	for &x in w.stamp {
		x = 0
	}
	for &x in w.start {
		x = 0
	}
	total := 0
	for i in 0 ..< n {
		slot := u32(i)
		lv := ix.levels[slot]
		if lv == LEVEL_TWIN || lv == LEVEL_FREE {
			if layer == 0 && ix.degree0[slot] != 0 {
				return .Degree
			}
			continue
		}
		if int(lv) < layer {
			continue
		}
		l := list_get(ix, slot, layer)
		if l.count > cap {
			return .Degree
		}
		tag := slot + 1
		for k in 0 ..< l.count {
			v := list_id(ix, l, k)
			if int(v) >= n {
				return .Link_Range
			}
			if v == slot {
				return .Link_Self
			}
			tl := ix.levels[v]
			if tl > LEVEL_CAP || int(tl) < layer {
				return .Link_Target
			}
			if w.stamp[v] == tag {
				return .Link_Repeat
			}
			w.stamp[v] = tag
			w.start[v + 1] += 1
		}
		total += l.count
	}
	for i in 0 ..< n {
		w.start[i + 1] += w.start[i]
	}
	if resize(&w.edges, total) != nil {
		return .Out_Of_Memory
	}
	for i in 0 ..< n {
		w.fill[i] = w.start[i]
	}
	for i in 0 ..< n {
		slot := u32(i)
		lv := ix.levels[slot]
		if lv > LEVEL_CAP || int(lv) < layer {
			continue
		}
		l := list_get(ix, slot, layer)
		for k in 0 ..< l.count {
			v := list_id(ix, l, k)
			w.edges[w.fill[v]] = slot
			w.fill[v] += 1
		}
	}
	for &x in w.stamp {
		x = 0
	}
	for i in 0 ..< n {
		slot := u32(i)
		lv := ix.levels[slot]
		inbound := w.start[i + 1] - w.start[i]
		if lv > LEVEL_CAP || int(lv) < layer {
			if inbound != 0 {
				return .Asymmetric
			}
			continue
		}
		l := list_get(ix, slot, layer)
		if inbound != l.count {
			return .Asymmetric
		}
		tag := slot + 1
		for k in 0 ..< l.count {
			w.stamp[list_id(ix, l, k)] = tag
		}
		for e in w.edges[w.start[i]:w.start[i + 1]] {
			if w.stamp[e] != tag {
				return .Asymmetric
			}
		}
	}
	return .None
}

restore_twins :: proc(ix: ^Index, w: ^Restore_Work, twins: int) -> Restore_Fault {
	n := ix.slots
	if twins > 0 && ix.twin_link == nil {
		return .Twin_Table
	}
	for &x in w.next {
		x = NONE
	}
	for i in 0 ..< n {
		slot := u32(i)
		if ix.levels[slot] != LEVEL_TWIN {
			continue
		}
		if ix.degree0[slot] != 0 || ix.upper_at[slot] != NONE {
			return .Degree
		}
		prev := twin_prev(ix, slot)
		if int(prev) >= n || prev == slot {
			return .Twin_Prev
		}
		pl := ix.levels[prev]
		if pl != LEVEL_TWIN && pl > LEVEL_CAP {
			return .Twin_Prev
		}
		if w.next[prev] != NONE {
			return .Twin_Fork
		}
		w.next[prev] = slot
	}
	reached := 0
	for i in 0 ..< n {
		if ix.levels[i] > LEVEL_CAP {
			continue
		}
		for t := w.next[i]; t != NONE; t = w.next[t] {
			reached += 1
			if reached > twins {
				return .Twin_Cycle
			}
		}
	}
	if reached != twins {
		return .Twin_Cycle
	}
	if ix.twin_link != nil {
		for i in 0 ..< ix.twin_cap {
			ix.twin_link[i] = NONE
		}
		for i in 0 ..< n {
			ix.twin_link[i] = w.next[i]
		}
	}
	return .None
}

free_chain :: proc(ix: ^Index, out: ^[dynamic]u32) -> bool {
	clear(out)
	none := width_none(ix.width)
	for at := ix.free_head; at != NONE; {
		if len(out) >= ix.slots {
			return false
		}
		append(out, at)
		next := word_get(ix.links0[int(at) * ix.row:], 0, ix.width)
		at = NONE if next == none else next
	}
	return true
}

upper_lists :: proc "contextless" (ix: ^Index) -> int {
	n := 0
	for i in 0 ..< ix.slots {
		if lv := ix.levels[i]; lv <= LEVEL_CAP {
			n += int(lv)
		}
	}
	return n
}

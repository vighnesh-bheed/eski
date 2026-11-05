package settype

import lp "../listpack"

SRANDMEMBER_REPLY_BATCH :: 1000

Popped_Item :: struct {
	off:     int,
	n:       int,
	number:  i64,
	numeric: bool,
}

Popped :: struct {
	arena: [dynamic]u8,
	items: [dynamic]Popped_Item,
}

Index_Set :: struct {
	slots: []u64,
	mask:  u64,
}

popped_reset :: proc(p: ^Popped) {
	clear(&p.arena)
	clear(&p.items)
}

popped_destroy :: proc(p: ^Popped) {
	delete(p.arena)
	delete(p.items)
	p^ = {}
}

popped_push :: proc(p: ^Popped, v: Member) {
	resize_require(len(p.items) < max(int) / size_of(Popped_Item))
	item := Popped_Item{number = v.number, numeric = v.numeric}
	if !v.numeric {
		resize_require(len(v.text) <= max(int) - len(p.arena))
		item.off = len(p.arena)
		item.n = len(v.text)
		append(&p.arena, ..v.text)
	}
	append(&p.items, item)
}

popped_len :: proc(p: ^Popped) -> int {
	return len(p.items)
}

popped_get :: proc(p: ^Popped, i: int) -> Member {
	item := p.items[i]
	if item.numeric {
		return {number = item.number, numeric = true}
	}
	return {text = p.arena[item.off:item.off + item.n]}
}

rand_below :: proc "contextless" (n: u64) -> u64 {
	resize_require(n > 0)
	minimum := (u64(0) - n) % n
	for {
		value := rand64()
		if value >= minimum {
			return value % n
		}
	}
}

table_random_blob :: proc "contextless" (t: ^Table) -> ^Blob {
	index := int(rand_below(u64(t.count)))
	for bank in 0 ..< 2 {
		slots, capacity := table_bank(t, bank)
		for i in 0 ..< capacity {
			if blob_live(slots[i].blob) {
				if index == 0 {
					return slots[i].blob
				}
				index -= 1
			}
		}
	}
	resize_require(false)
	return nil
}

random_element :: proc(s: Set) -> Member {
	resize_require(size(s) > 0)
	if s.encoding == .Hashtable {
		return {text = blob_bytes(table_random_blob(s.table))}
	}
	index := int(rand_below(u64(size(s))))
	if s.encoding == .Intset {
		return {number = intset_get(s.data, index), numeric = true}
	}
	it := iterator(s)
	for i in 0 ..= index {
		value, ok := next(&it)
		resize_require(ok)
		if i == index {
			return value
		}
	}
	return {}
}

pop_random :: proc(s: Set, out: ^Popped) {
	value := random_element(s)
	popped_push(out, value)
	remove_aux(s, value)
}

random_with_repeats :: proc(s: Set, count: int, out: ^[dynamic]Member) {
	if size(s) == 0 || count <= 0 {
		return
	}
	resize_require(count <= (max(int) / size_of(Member)) - len(out^))
	for _ in 0 ..< count {
		append(out, random_element(s))
	}
}

index_set_insert :: proc "contextless" (s: ^Index_Set, idx: int) -> bool {
	resize_require(idx >= 0)
	value := u64(idx) + 1
	index := u64(idx) & s.mask
	for _ in 0 ..< len(s.slots) {
		if s.slots[index] == value {
			return false
		}
		if s.slots[index] == 0 {
			s.slots[index] = value
			return true
		}
		index = (index + 1) & s.mask
	}
	resize_require(false)
	return false
}

random_unique :: proc(s: Set, count: int, out: ^[dynamic]Member) {
	n := size(s)
	take := min(max(0, count), n)
	if take == 0 {
		return
	}
	resize_require(n <= max(int) / size_of(Member) && take <= max(int) / size_of(Member) - len(out^))
	if take == n {
		it := iterator(s)
		for {
			value, ok := next(&it)
			if !ok {
				break
			}
			append(out, value)
		}
		return
	}
	if s.encoding == .Listpack {
		remaining := n
		needed := take
		it := iterator(s)
		for needed > 0 {
			value, ok := next(&it)
			resize_require(ok)
			if rand_below(u64(remaining)) < u64(needed) {
				append(out, value)
				needed -= 1
			}
			remaining -= 1
		}
		return
	}
	values := make([]Member, n)
	defer delete(values)
	it := iterator(s)
	for i in 0 ..< n {
		values[i], _ = next(&it)
	}
	for i in 0 ..< take {
		choice := i + int(rand_below(u64(n - i)))
		values[i], values[choice] = values[choice], values[i]
		append(out, values[i])
	}
}

spop_keep_survivors :: proc(s: Set, kept: int, out: ^Popped) -> Set {
	survivors: [dynamic]Member
	defer delete(survivors)
	random_unique(s, kept, &survivors)
	keeper := create_intset() if s.encoding == .Intset else create_listpack()
	for survivor in survivors {
		add_aux(keeper, survivor)
	}
	retained := iterator(keeper)
	for survivor in next(&retained) {
		remove_aux(s, survivor)
	}
	leftovers := iterator(s)
	for member in next(&leftovers) {
		popped_push(out, member)
	}
	return keeper
}

spop_listpack_in_place :: proc(s: Set, count: int, out: ^Popped) {
	unseen := u64(size(s))
	wanted := u64(count)
	at := lp.lp_first(s.data)
	for at != nil && wanted > 0 {
		if rand_below(unseen) < wanted {
			popped_push(out, value_from_entry(lp.lp_get_entry(at)))
			s.data = lp.lp_delete(s.data, at, &at)
			resize_require(s.data != nil)
			wanted -= 1
		} else {
			at = lp.lp_next(s.data, at)
		}
		unseen -= 1
	}
}

spop_count :: proc(s: Set, count: int, out: ^Popped) -> (newset: Set) {
	resize_require(count > 0 && count < size(s))
	kept := size(s) - count
	switch {
	case kept * 5 <= count:
		newset = spop_keep_survivors(s, kept, out)
	case s.encoding == .Listpack:
		spop_listpack_in_place(s, count, out)
	case:
		for _ in 0 ..< count {
			pop_random(s, out)
		}
	}
	return
}

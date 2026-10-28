package settype

SPOP_MOVE_STRATEGY_MUL :: 5
SRANDMEMBER_SUB_STRATEGY_MUL :: 3
SRANDMEMBER_RANDOM_SAMPLE_LIMIT :: 1000

Popped_Item :: struct {
	off:    int,
	n:      int,
	ival:   i64,
	is_int: bool,
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

popped_push :: proc(p: ^Popped, v: Value) {
	resize_require(len(p.items) < max(int) / size_of(Popped_Item))
	item := Popped_Item{ival = v.ival, is_int = v.is_int}
	if !v.is_int {
		resize_require(len(v.str) <= max(int) - len(p.arena))
		item.off = len(p.arena)
		item.n = len(v.str)
		append(&p.arena, ..v.str)
	}
	append(&p.items, item)
}

popped_len :: proc(p: ^Popped) -> int {
	return len(p.items)
}

popped_get :: proc(p: ^Popped, i: int) -> Value {
	item := p.items[i]
	if item.is_int {
		return {ival = item.ival, is_int = true}
	}
	return {str = p.arena[item.off:item.off + item.n]}
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

random_element :: proc(s: Set) -> Value {
	resize_require(size(s) > 0)
	if s.encoding == .Hashtable {
		return {str = blob_bytes(table_random_blob(s.table))}
	}
	index := int(rand_below(u64(size(s))))
	if s.encoding == .Intset {
		return {ival = intset_get(s.data, index), is_int = true}
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

random_with_repeats :: proc(s: Set, count: int, out: ^[dynamic]Value) {
	if size(s) == 0 || count <= 0 {
		return
	}
	resize_require(count <= (max(int) / size_of(Value)) - len(out^))
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

random_unique :: proc(s: Set, count: int, out: ^[dynamic]Value) {
	n := size(s)
	take := min(max(0, count), n)
	if take == 0 {
		return
	}
	resize_require(n <= max(int) / size_of(Value) && take <= max(int) / size_of(Value) - len(out^))
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
	values := make([]Value, n)
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

spop_count :: proc(s: Set, count: int, out: ^Popped) -> (newset: Set) {
	resize_require(count > 0 && count < size(s))
	remaining := size(s) - count
	if remaining <= count / SPOP_MOVE_STRATEGY_MUL {
		chosen: [dynamic]Value
		defer delete(chosen)
		random_unique(s, remaining, &chosen)
		newset = create_intset() if s.encoding == .Intset else create_listpack()
		for value in chosen {
			add_aux(newset, value)
		}
		it := iterator(newset)
		for {
			value, ok := next(&it)
			if !ok {
				break
			}
			remove_aux(s, value)
		}
		it = iterator(s)
		for {
			value, ok := next(&it)
			if !ok {
				break
			}
			popped_push(out, value)
		}
		return
	}
	if s.encoding == .Listpack {
		chosen: [dynamic]Value
		defer delete(chosen)
		random_unique(s, count, &chosen)
		first := popped_len(out)
		for value in chosen {
			popped_push(out, value)
		}
		for index in first ..< popped_len(out) {
			remove_aux(s, popped_get(out, index))
		}
		return nil
	}
	for _ in 0 ..< count {
		pop_random(s, out)
	}
	return nil
}

package listtype

import lp "../listpack"
import "base:intrinsics"

NODE_BYTES_CAP :: 8192

INSERT_SLACK_BYTES :: 8

FILL_CEILING :: (1 << 15) - 1

FILL_FLOOR :: -5

COMPRESS_DEPTH_CEILING :: (1 << 16) - 1

PLAIN_THRESHOLD_CEILING :: u64(1 << 32) - u64(1 << 20)

NO_LIMIT :: max(int)

OPTIMIZATION_LEVEL := [5]int{4096, 8192, 16384, 32768, 65536}

plain_node_threshold: int

Direction :: enum u8 {
	Start_Head,
	Start_Tail,
}

Node :: struct {
	prev:  ^Node,
	next:  ^Node,
	entry: [^]u8,
	sz:    int,
	count: int,
	plain: bool,
}

Quicklist :: struct {
	head:     ^Node,
	tail:     ^Node,
	count:    int,
	len:      int,
	fill:     int,
	compress: int,
	mem:      int,
}

Iter :: struct {
	list:     ^Quicklist,
	node:     ^Node,
	element:  [^]u8,
	position: int,
	heading:  Direction,
}

Entry :: struct {
	list:     ^Quicklist,
	node:     ^Node,
	element:  [^]u8,
	text:     [^]u8,
	number:   i64,
	text_len: int,
	position: int,
}

out_of_memory :: proc "contextless" () -> ! {
	intrinsics.trap()
}

usable :: proc "contextless" (p: rawptr) -> int {
	if p == nil {
		return 0
	}
	return lp.lp_malloc_size(p)
}

bytes_dup :: proc "contextless" (src: [^]u8, n: int) -> [^]u8 {
	p := lp.lp_malloc(max(n, 1))
	if p == nil {
		out_of_memory()
	}
	if n > 0 {
		copy(p[:n], src[:n])
	}
	return p
}

set_plain_node_threshold :: proc "contextless" (sz: u64) -> bool {
	if sz > PLAIN_THRESHOLD_CEILING {
		return false
	}
	plain_node_threshold = int(sz)
	return true
}

clamp_fill :: proc "contextless" (fill: int) -> int {
	return clamp(fill, FILL_FLOOR, FILL_CEILING)
}

ql_new :: proc "contextless" (fill: int, compress: int) -> ^Quicklist {
	q := cast(^Quicklist)lp.lp_malloc(size_of(Quicklist))
	if q == nil {
		out_of_memory()
	}
	q^ = Quicklist{fill = clamp_fill(fill), compress = clamp(compress, 0, COMPRESS_DEPTH_CEILING)}
	q.mem = usable(q)
	return q
}

ql_release :: proc "contextless" (ql: ^Quicklist) {
	if ql == nil {
		return
	}
	n := ql.head
	for n != nil {
		next_node := n.next
		lp.lp_free(n.entry)
		lp.lp_mem_free(n)
		n = next_node
	}
	lp.lp_mem_free(ql)
}

node_new :: proc "contextless" (ql: ^Quicklist) -> ^Node {
	n := cast(^Node)lp.lp_malloc(size_of(Node))
	if n == nil {
		out_of_memory()
	}
	n^ = {}
	ql.mem += usable(n)
	return n
}

node_update_sz :: proc "contextless" (n: ^Node) {
	if !n.plain {
		n.sz = lp.lp_bytes(n.entry)
	}
}

node_set_entry :: proc "contextless" (ql: ^Quicklist, n: ^Node, old_usable: int, p: [^]u8) {
	n.entry = p
	node_update_sz(n)
	ql.mem += usable(p)-old_usable
}

node_lp_prepend :: proc(ql: ^Quicklist, n: ^Node, value: []u8) {
	old := usable(n.entry)
	p := lp.lp_prepend(n.entry, value)
	node_set_entry(ql, n, old, p)
	n.count += 1
	ql.count += 1
}

node_lp_append :: proc(ql: ^Quicklist, n: ^Node, value: []u8) {
	old := usable(n.entry)
	p := lp.lp_append(n.entry, value)
	node_set_entry(ql, n, old, p)
	n.count += 1
	ql.count += 1
}

node_lp_fresh :: proc(ql: ^Quicklist, n: ^Node, value: []u8) {
	n.entry = lp.lp_new(0)
	ql.mem += usable(n.entry)
	node_lp_append(ql, n, value)
}

node_lp_delete_range :: proc(ql: ^Quicklist, n: ^Node, start_arg: int, num: u64) {
	start := start_arg
	if start < 0 {
		start = n.count + start
	}
	if start < 0 || start >= n.count {
		return
	}
	removed := min(num, u64(n.count-start))
	old := usable(n.entry)
	p := lp.lp_delete_range(n.entry, i64(start), removed)
	node_set_entry(ql, n, old, p)
	n.count -= int(removed)
	ql.count -= int(removed)
}

node_neg_fill_limit :: proc "contextless" (fill: int) -> int {
	return OPTIMIZATION_LEVEL[-clamp(fill, -5, -1)-1]
}

node_limit :: proc "contextless" (fill: int) -> (size: int, count: int) {
	if fill < 0 {
		return node_neg_fill_limit(fill), NO_LIMIT
	}
	return NO_LIMIT, max(fill, 1)
}

node_exceeds_limit :: proc "contextless" (fill: int, new_sz: int, new_count: int) -> bool {
	sz, n := node_limit(fill)
	return new_sz > sz || new_count > n || (fill >= 0 && new_sz > NODE_BYTES_CAP)
}

is_large_element :: proc "contextless" (sz: int, fill: int) -> bool {
	if plain_node_threshold != 0 {
		return sz >= plain_node_threshold
	}
	limit, _ := node_limit(fill)
	if fill >= 0 {
		limit = NODE_BYTES_CAP
	}
	return sz > limit
}

node_allow_insert :: proc "contextless" (n: ^Node, fill: int, sz: int) -> bool {
	return n != nil && !n.plain && !is_large_element(sz, fill) && sz <= max(int)-n.sz-INSERT_SLACK_BYTES && !node_exceeds_limit(fill, n.sz+sz+INSERT_SLACK_BYTES, n.count+1)
}

node_allow_merge :: proc "contextless" (a: ^Node, b: ^Node, fill: int) -> bool {
	return a != nil && b != nil && !a.plain && !b.plain && !node_exceeds_limit(fill, a.sz+b.sz-7, a.count+b.count)
}

node_create_container :: proc(ql: ^Quicklist, plain: bool, value: []u8) -> ^Node {
	n := node_new(ql)
	n.plain = plain
	if plain {
		n.entry = bytes_dup(raw_data(value), len(value))
		n.sz = len(value)
		n.count = 1
		ql.count += 1
		ql.mem += usable(n.entry)
	} else {
		node_lp_fresh(ql, n, value)
	}
	return n
}

insert_node :: proc "contextless" (ql: ^Quicklist, old_node: ^Node, new_node: ^Node, after: bool) {
	if old_node == nil {
		new_node.prev = nil
		new_node.next = nil
		ql.head = new_node
		ql.tail = new_node
	} else if after {
		new_node.prev = old_node
		new_node.next = old_node.next
		if old_node.next != nil {
			old_node.next.prev = new_node
		} else {
			ql.tail = new_node
		}
		old_node.next = new_node
	} else {
		new_node.next = old_node
		new_node.prev = old_node.prev
		if old_node.prev != nil {
			old_node.prev.next = new_node
		} else {
			ql.head = new_node
		}
		old_node.prev = new_node
	}
	ql.len += 1
}

insert_plain_node :: proc(ql: ^Quicklist, old_node: ^Node, value: []u8, after: bool) {
	n := node_create_container(ql, true, value)
	insert_node(ql, old_node, n, after)
}

push_head :: proc(ql: ^Quicklist, value: []u8) -> bool {
	if node_allow_insert(ql.head, ql.fill, len(value)) {
		node_lp_prepend(ql, ql.head, value)
		return false
	}
	n := node_create_container(ql, is_large_element(len(value), ql.fill), value)
	insert_node(ql, ql.head, n, false)
	return true
}

push_tail :: proc(ql: ^Quicklist, value: []u8) -> bool {
	if node_allow_insert(ql.tail, ql.fill, len(value)) {
		node_lp_append(ql, ql.tail, value)
		return false
	}
	n := node_create_container(ql, is_large_element(len(value), ql.fill), value)
	insert_node(ql, ql.tail, n, true)
	return true
}

append_listpack :: proc(ql: ^Quicklist, zl: [^]u8) {
	count := int(lp.lp_length(zl))
	if count == 0 {
		lp.lp_free(zl)
		return
	}
	n := node_new(ql)
	n.entry = zl
	n.sz = lp.lp_bytes(zl)
	n.count = count
	ql.mem += usable(zl)
	ql.count += count
	insert_node(ql, ql.tail, n, true)
}

del_node :: proc "contextless" (ql: ^Quicklist, n: ^Node) {
	if n.prev != nil {
		n.prev.next = n.next
	} else {
		ql.head = n.next
	}
	if n.next != nil {
		n.next.prev = n.prev
	} else {
		ql.tail = n.prev
	}
	ql.len -= 1
	ql.count -= n.count
	ql.mem -= usable(n.entry)+usable(n)
	lp.lp_free(n.entry)
	lp.lp_mem_free(n)
}

del_index :: proc(ql: ^Quicklist, n: ^Node, p: ^[^]u8) -> bool {
	if n.plain {
		del_node(ql, n)
		p^ = nil
		return true
	}
	old := usable(n.entry)
	nextp: [^]u8
	pack := lp.lp_delete(n.entry, p^, &nextp)
	node_set_entry(ql, n, old, pack)
	n.count -= 1
	ql.count -= 1
	p^ = nextp
	if n.count == 0 {
		del_node(ql, n)
		p^ = nil
		return true
	}
	return false
}

node_start_index :: proc "contextless" (ql: ^Quicklist, node: ^Node) -> int {
	i := 0
	for n := ql.head; n != nil; n = n.next {
		if n == node {
			return i
		}
		i += n.count
	}
	return i
}

iter_global_index :: proc "contextless" (it: ^Iter) -> int {
	if it.node == nil {
		if it.heading == .Start_Tail {
			return -1
		}
		return it.list.count
	}
	return node_start_index(it.list, it.node)+it.position
}

iter_seek_absolute :: proc "contextless" (it: ^Iter, idx_arg: int) {
	idx := idx_arg
	it.node = nil
	it.element = nil
	it.position = 0
	if idx < 0 || idx >= it.list.count {
		return
	}
	n := it.list.head
	for idx >= n.count {
		idx -= n.count
		n = n.next
	}
	it.node = n
	it.position = idx
}

del_entry :: proc(it: ^Iter, entry: ^Entry) {
	nextidx := iter_global_index(it)
	idx := node_start_index(it.list, entry.node)+entry.position
	p := entry.element
	del_index(it.list, entry.node, &p)
	if idx < nextidx {
		nextidx -= 1
	}
	iter_seek_absolute(it, nextidx)
	entry^ = {}
}

reset_iterator :: proc "contextless" (it: ^Iter) {
	it.element = nil
}

listpack_merge :: proc(ql: ^Quicklist, a: ^Node, b: ^Node) -> ^Node {
	if a == nil || b == nil || a.next != b {
		return a
	}
	before := usable(a.entry)+usable(b.entry)
	a.entry = lp.lp_merge(&a.entry, &b.entry)
	ql.mem += usable(a.entry)-before
	b.entry = nil
	a.count += b.count
	b.count = 0
	node_update_sz(a)
	del_node(ql, b)
	return a
}

merge_nodes :: proc(ql: ^Quicklist, center: ^Node) -> ^Node {
	if center == nil {
		return nil
	}
	n := center
	if node_allow_merge(n.prev, n, ql.fill) {
		n = listpack_merge(ql, n.prev, n)
	}
	if node_allow_merge(n, n.next, ql.fill) {
		n = listpack_merge(ql, n, n.next)
	}
	return n
}

split_node :: proc(ql: ^Quicklist, node: ^Node, offset: int, after: bool) -> ^Node {
	cut := offset
	if after {
		cut += 1
	}
	cut = clamp(cut, 0, node.count)
	n := node_new(ql)
	n.entry = lp.lp_dup(node.entry)
	ql.mem += usable(n.entry)
	n.count = node.count
	old := usable(n.entry)
	n.entry = lp.lp_delete_range(n.entry, 0, u64(cut))
	node_set_entry(ql, n, old, n.entry)
	n.count -= cut
	old = usable(node.entry)
	node.entry = lp.lp_delete_range(node.entry, i64(cut), u64(node.count-cut))
	node_set_entry(ql, node, old, node.entry)
	node.count = cut
	return n
}

insert :: proc(it: ^Iter, entry: ^Entry, value: []u8, after: bool) {
	ql := it.list
	n := entry.node
	nextidx := iter_global_index(it)
	insertidx := node_start_index(ql, n)+entry.position
	if after {
		insertidx += 1
	}
	if !n.plain && node_allow_insert(n, ql.fill, len(value)) {
		old := usable(n.entry)
		how := lp.Placement.Before
		if after {
			how = lp.Placement.After
		}
		p := lp.lp_insert_string(n.entry, value, lp.lp_seek(n.entry, i64(entry.position)), how, nil)
		node_set_entry(ql, n, old, p)
		n.count += 1
		ql.count += 1
	} else {
		cut := entry.position
		if after {
			cut += 1
		}
		if cut == 0 && node_allow_insert(n.prev, ql.fill, len(value)) {
			node_lp_append(ql, n.prev, value)
		} else if cut == n.count && node_allow_insert(n.next, ql.fill, len(value)) {
			node_lp_prepend(ql, n.next, value)
		} else if cut == 0 || cut == n.count {
			fresh := node_create_container(ql, is_large_element(len(value), ql.fill), value)
			insert_node(ql, n, fresh, cut != 0)
		} else {
			right := split_node(ql, n, cut, false)
			insert_node(ql, n, right, true)
			if is_large_element(len(value), ql.fill) {
				fresh := node_create_container(ql, true, value)
				insert_node(ql, n, fresh, true)
			} else if after {
				node_lp_prepend(ql, right, value)
			} else {
				node_lp_append(ql, n, value)
			}
			if !is_large_element(len(value), ql.fill) {
				if node_allow_merge(right, right.next, ql.fill) {
					listpack_merge(ql, right, right.next)
				}
				merge_nodes(ql, n)
			}
		}
	}
	if insertidx <= nextidx {
		nextidx += 1
	}
	iter_seek_absolute(it, nextidx)
	entry^ = {}
}

replace_entry :: proc(it: ^Iter, entry: ^Entry, data: []u8) {
	ql := it.list
	n := entry.node
	nextidx := iter_global_index(it)
	idx := node_start_index(ql, n)+entry.position
	if !n.plain && !is_large_element(len(data), ql.fill) {
		old := usable(n.entry)
		p := lp.lp_seek(n.entry, i64(entry.position))
		pack := lp.lp_replace(n.entry, &p, data)
		node_set_entry(ql, n, old, pack)
	} else if n.plain && is_large_element(len(data), ql.fill) {
		fresh := bytes_dup(raw_data(data), len(data))
		ql.mem += usable(fresh)-usable(n.entry)
		lp.lp_free(n.entry)
		n.entry = fresh
		n.sz = len(data)
	} else {
		merge_remaining := !n.plain
		cursor, ok := get_iterator_at_idx(ql, .Start_Head, idx)
		assert(ok)
		e: Entry
		assert(next(&cursor, &e))
		insert(&cursor, &e, data, true)
		cursor, ok = get_iterator_at_idx(ql, .Start_Head, idx)
		assert(ok)
		assert(next(&cursor, &e))
		del_entry(&cursor, &e)
		if merge_remaining {
			_, replacement, found := get_iterator_entry_at_idx(ql, idx)
			assert(found)
			center := replacement.node
			if center.prev != nil {
				merge_nodes(ql, center.prev)
			}
			if center.next != nil {
				merge_nodes(ql, center.next)
			}
		}
	}
	iter_seek_absolute(it, nextidx)
	entry^ = {}
}

replace_at_index :: proc(ql: ^Quicklist, index: int, data: []u8) -> bool {
	it, e, ok := get_iterator_entry_at_idx(ql, index)
	if !ok {
		return false
	}
	replace_entry(&it, &e, data)
	return true
}

del_range :: proc(ql: ^Quicklist, start_arg: int, count: int) -> bool {
	start := start_arg
	if count <= 0 {
		return false
	}
	if start < 0 {
		start += ql.count
	}
	if start < 0 || start >= ql.count {
		return false
	}
	remaining := min(count, ql.count-start)
	n := ql.head
	offset := start
	for offset >= n.count {
		offset -= n.count
		n = n.next
	}
	for remaining > 0 {
		next_node := n.next
		take := min(remaining, n.count-offset)
		if offset == 0 && take == n.count {
			del_node(ql, n)
		} else {
			node_lp_delete_range(ql, n, offset, u64(take))
		}
		remaining -= take
		n = next_node
		offset = 0
	}
	return true
}

compare :: proc(entry: ^Entry, s: []u8) -> bool {
	if entry.node.plain {
		return string(entry.text[:entry.text_len]) == string(s)
	}
	return lp.lp_compare(entry.element, s)
}

get_iterator :: proc "contextless" (ql: ^Quicklist, direction: Direction) -> Iter {
	it := Iter{list = ql, heading = direction}
	idx := 0
	if direction == .Start_Tail {
		idx = ql.count-1
	}
	iter_seek_absolute(&it, idx)
	return it
}

get_iterator_at_idx :: proc "contextless" (ql: ^Quicklist, direction: Direction, idx_arg: int) -> (Iter, bool) {
	idx := idx_arg
	if idx < 0 {
		idx += ql.count
	}
	it := Iter{list = ql, heading = direction}
	iter_seek_absolute(&it, idx)
	return it, it.node != nil
}

get_iterator_entry_at_idx :: proc(ql: ^Quicklist, idx: int) -> (it: Iter, entry: Entry, ok: bool) {
	it, ok = get_iterator_at_idx(ql, .Start_Head, idx)
	if ok {
		ok = next(&it, &entry)
	}
	return
}

next :: proc(it: ^Iter, entry: ^Entry) -> bool {
	n := it.node
	for n != nil && (it.position < 0 || it.position >= n.count) {
		if it.heading == .Start_Head {
			n = n.next
			it.position = 0
		} else {
			n = n.prev
			if n != nil {
				it.position = n.count-1
			}
		}
	}
	it.node = n
	if n == nil {
		return false
	}
	entry^ = Entry{list = it.list, node = n, position = it.position}
	if n.plain {
		entry.text = n.entry
		entry.text_len = n.sz
		entry.element = n.entry
	} else {
		entry.element = lp.lp_seek(n.entry, i64(it.position))
		slen: u32
		entry.text = lp.lp_get_value(entry.element, &slen, &entry.number)
		entry.text_len = int(slen)
	}
	it.element = entry.element
	if it.heading == .Start_Head {
		it.position += 1
	} else {
		it.position -= 1
	}
	return true
}

ql_dup :: proc "contextless" (orig: ^Quicklist) -> ^Quicklist {
	ql := ql_new(orig.fill, orig.compress)
	for n := orig.head; n != nil; n = n.next {
		fresh := node_new(ql)
		fresh.entry = bytes_dup(n.entry, n.sz)
		fresh.sz = n.sz
		fresh.count = n.count
		fresh.plain = n.plain
		ql.mem += usable(fresh.entry)
		ql.count += fresh.count
		insert_node(ql, ql.tail, fresh, true)
	}
	return ql
}

ql_end_value :: proc(ql: ^Quicklist, head: bool) -> (v: Value, ok: bool) {
	n := ql.tail
	if head {
		n = ql.head
	}
	if n == nil {
		return {}, false
	}
	if n.plain {
		return Value{str = n.entry[:n.sz]}, true
	}
	p := lp.lp_last(n.entry)
	if head {
		p = lp.lp_first(n.entry)
	}
	return value_from_lp(p), true
}

ql_pop_discard :: proc(ql: ^Quicklist, head: bool) {
	idx := -1
	if head {
		idx = 0
	}
	del_range(ql, idx, 1)
}

ql_memory_recount :: proc "contextless" (ql: ^Quicklist) -> int {
	total := usable(ql)
	for n := ql.head; n != nil; n = n.next {
		total += usable(n)+usable(n.entry)
	}
	return total
}

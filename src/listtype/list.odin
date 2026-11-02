package listtype

import lp "../listpack"
import "core:fmt"

LIST_MAX_LISTPACK_SIZE_DEFAULT :: -2

LIST_COMPRESS_DEPTH_DEFAULT :: 0

list_max_listpack_size: int = LIST_MAX_LISTPACK_SIZE_DEFAULT

list_compress_depth: int = LIST_COMPRESS_DEPTH_DEFAULT

Encoding :: enum u8 {
	Listpack,
	Quicklist,
}

Where :: enum u8 {
	Head,
	Tail,
}

List_Object :: struct {
	lp:       [^]u8,
	ql:       ^Quicklist,
	acct:     int,
	encoding: Encoding,
}

List :: ^List_Object

Value :: struct {
	str:    []u8,
	ival:   i64,
	is_int: bool,
}

Iterator :: struct {
	l:            List,
	encoding:     Encoding,
	direction:    Where,
	pack_cursor:  [^]u8,
	chain_cursor: Iter,
}

List_Entry :: struct {
	pack_at:  [^]u8,
	chain_at: Entry,
}

Quicklist_Info :: struct {
	nodes:             int,
	count:             int,
	fill:              int,
	compressed:        bool,
	uncompressed_size: int,
}

value_from_lp :: proc "contextless" (p: [^]u8) -> Value {
	if p == nil {
		return {}
	}
	v: Value
	n: u32
	s := lp.lp_get_value(p, &n, &v.ival)
	v.is_int = s == nil
	if s != nil {
		v.str = s[:int(n)]
	}
	return v
}

value_bytes :: proc "contextless" (v: Value, buf: ^[lp.DECIMAL_BUFFER_BYTES]u8) -> []u8 {
	if !v.is_int {
		return v.str
	}
	n := lp.ll2string(raw_data(buf[:]), v.ival)
	return buf[:n]
}

create :: proc "contextless" () -> List {
	l := cast(List)lp.lp_malloc(size_of(List_Object))
	if l == nil {
		out_of_memory()
	}
	l^ = {}
	l.lp = lp.lp_new(0)
	return l
}

create_quicklist :: proc "contextless" () -> List {
	l := cast(List)lp.lp_malloc(size_of(List_Object))
	if l == nil {
		out_of_memory()
	}
	l^ = {}
	l.encoding = .Quicklist
	l.ql = ql_new(list_max_listpack_size, list_compress_depth)
	return l
}

destroy :: proc "contextless" (l: List) {
	if l == nil {
		return
	}
	if l.encoding == .Listpack {
		lp.lp_free(l.lp)
	} else {
		ql_release(l.ql)
	}
	lp.lp_mem_free(l)
}

length :: proc(l: List) -> int {
	if l == nil {
		return 0
	}
	if l.encoding == .Listpack {
		return int(lp.lp_length(l.lp))
	}
	return l.ql.count
}

encoding_name :: proc "contextless" (l: List) -> string {
	if l.encoding == .Listpack {
		return "listpack"
	}
	return "quicklist"
}

memory_usage :: proc "contextless" (l: List) -> int {
	if l == nil {
		return 0
	}
	if l.encoding == .Listpack {
		return usable(l)+usable(l.lp)
	}
	return usable(l)+l.ql.mem
}

memory_recount :: proc "contextless" (l: List) -> int {
	if l == nil {
		return 0
	}
	if l.encoding == .Listpack {
		return usable(l)+usable(l.lp)
	}
	return usable(l)+ql_memory_recount(l.ql)
}

quicklist_info :: proc "contextless" (l: List) -> (info: Quicklist_Info, ok: bool) {
	if l == nil || l.encoding != .Quicklist {
		return {}, false
	}
	q := l.ql
	info = {nodes = q.len, count = q.count, fill = q.fill, compressed = q.compress != 0}
	for n := q.head; n != nil; n = n.next {
		info.uncompressed_size += n.sz
	}
	return info, true
}

format_avg_node :: proc(info: Quicklist_Info, buf: []u8) -> string {
	avg: f64
	if info.nodes != 0 {
		avg = f64(info.count)/f64(info.nodes)
	}
	return fmt.bprintf(buf, "%.2f", avg)
}

listpack_bytes :: proc "contextless" (l: List) -> []u8 {
	if l == nil || l.encoding != .Listpack {
		return nil
	}
	return lp.lp_view(l.lp)
}

node_listpacks :: proc(l: List, out: ^[dynamic][]u8, plain: ^[dynamic]bool) {
	if l.encoding == .Listpack {
		append(out, lp.lp_view(l.lp))
		append(plain, false)
		return
	}
	for n := l.ql.head; n != nil; n = n.next {
		append(out, n.entry[:n.sz])
		append(plain, n.plain)
	}
}

halve_limit :: proc "contextless" (limit: int) -> int {
	return limit if limit == NO_LIMIT else limit / 2
}

widen_if_needed :: proc(l: List, add_bytes: int, add_length: int) {
	if l.encoding != .Listpack {
		return
	}
	bytes, items := lp.lp_bytes(l.lp), length(l)
	overflow := add_bytes > max(int) - bytes || add_length > max(int) - items
	if !overflow && !node_exceeds_limit(list_max_listpack_size, bytes + add_bytes, items + add_length) {
		return
	}
	chain := ql_new(list_max_listpack_size, list_compress_depth)
	append_listpack(chain, l.lp)
	l.encoding = .Quicklist
	l.ql = chain
	l.lp = nil
}

demote_if_small :: proc(l: List, halve: bool) {
	if l.encoding != .Quicklist {
		return
	}
	chain := l.ql
	only := chain.head
	if chain.len != 1 || only.plain {
		return
	}
	byte_cap, count_cap := node_limit(list_max_listpack_size)
	if halve {
		byte_cap, count_cap = halve_limit(byte_cap), halve_limit(count_cap)
	}
	if only.sz > byte_cap || only.count > count_cap {
		return
	}
	l.encoding = .Listpack
	l.lp, only.entry = only.entry, nil
	l.ql = nil
	ql_release(chain)
}

narrow_if_possible :: proc(l: List) {
	demote_if_small(l, true)
}

settle_encoding :: proc(l: List) {
	if l.encoding == .Listpack {
		widen_if_needed(l, 0, 0)
	} else {
		demote_if_small(l, false)
	}
}

widen_for_values :: proc(l: List, values: [][]u8) {
	incoming := 0
	for v in values {
		incoming = max(int) if len(v) > max(int) - incoming else incoming + len(v)
	}
	widen_if_needed(l, incoming, len(values))
}

push :: proc(l: List, value: []u8, where_: Where) {
	if l.encoding == .Listpack {
		if where_ == .Head {
			l.lp = lp.lp_prepend(l.lp, value)
		} else {
			l.lp = lp.lp_append(l.lp, value)
		}
	} else {
		if where_ == .Head {
			push_head(l.ql, value)
		} else {
			push_tail(l.ql, value)
		}
	}
}

peek :: proc(l: List, where_: Where) -> (v: Value, ok: bool) {
	if length(l) == 0 {
		return {}, false
	}
	if l.encoding == .Quicklist {
		return ql_end_value(l.ql, where_ == .Head)
	}
	p := lp.lp_first(l.lp)
	if where_ == .Tail {
		p = lp.lp_last(l.lp)
	}
	return value_from_lp(p), true
}

pop_discard :: proc(l: List, where_: Where) {
	if l.encoding == .Quicklist {
		ql_pop_discard(l.ql, where_ == .Head)
	} else {
		idx := i64(0)
		if where_ == .Tail {
			idx = -1
		}
		l.lp = lp.lp_delete_range(l.lp, idx, 1)
	}
}

iterator :: proc(l: List, index: int, direction: Where) -> Iterator {
	it := Iterator{l = l, encoding = l.encoding, direction = direction}
	if l.encoding == .Listpack {
		it.pack_cursor = lp.lp_seek(l.lp, i64(index))
	} else {
		dir := Direction.Start_Head
		if direction == .Head {
			dir = .Start_Tail
		}
		it.chain_cursor, _ = get_iterator_at_idx(l.ql, dir, index)
	}
	return it
}

iter_next :: proc(it: ^Iterator, e: ^List_Entry) -> bool {
	if it.encoding == .Quicklist {
		return next(&it.chain_cursor, &e.chain_at)
	}
	if it.pack_cursor == nil {
		return false
	}
	e.pack_at = it.pack_cursor
	if it.direction == .Tail {
		it.pack_cursor = lp.lp_next(it.l.lp, it.pack_cursor)
	} else {
		it.pack_cursor = lp.lp_prev(it.l.lp, it.pack_cursor)
	}
	return true
}

entry_value :: proc "contextless" (it: ^Iterator, e: ^List_Entry) -> Value {
	if it.encoding == .Listpack {
		return value_from_lp(e.pack_at)
	}
	q := &e.chain_at
	if q.node.plain || q.text != nil {
		return Value{str = q.text[:q.text_len]}
	}
	return Value{ival = q.number, is_int = true}
}

entry_equal :: proc(it: ^Iterator, e: ^List_Entry, s: []u8) -> bool {
	if it.encoding == .Listpack {
		return lp.lp_compare(e.pack_at, s)
	}
	return compare(&e.chain_at, s)
}

lp_pointer_index :: proc(l: List, p: [^]u8) -> int {
	if p == nil {
		return -1
	}
	idx := 0
	for q := lp.lp_first(l.lp); q != nil; q = lp.lp_next(l.lp, q) {
		if q == p {
			return idx
		}
		idx += 1
	}
	return -1
}

entry_insert :: proc(it: ^Iterator, e: ^List_Entry, value: []u8, where_: Where) {
	if it.encoding == .Quicklist {
		insert(&it.chain_cursor, &e.chain_at, value, where_ == .Tail)
		return
	}
	nextidx := lp_pointer_index(it.l, it.pack_cursor)
	at := lp_pointer_index(it.l, e.pack_at)
	how := lp.Placement.Before
	if where_ == .Tail {
		how = lp.Placement.After
		at += 1
	}
	it.l.lp = lp.lp_insert_string(it.l.lp, value, e.pack_at, how, nil)
	if nextidx >= 0 {
		if at <= nextidx {
			nextidx += 1
		}
		it.pack_cursor = lp.lp_seek(it.l.lp, i64(nextidx))
	} else {
		it.pack_cursor = nil
	}
	e^ = {}
}

entry_delete :: proc(it: ^Iterator, e: ^List_Entry) {
	if it.encoding == .Quicklist {
		del_entry(&it.chain_cursor, &e.chain_at)
		return
	}
	nextidx := lp_pointer_index(it.l, it.pack_cursor)
	at := lp_pointer_index(it.l, e.pack_at)
	it.l.lp = lp.lp_delete(it.l.lp, e.pack_at, nil)
	if nextidx >= 0 {
		if at < nextidx {
			nextidx -= 1
		}
		it.pack_cursor = lp.lp_seek(it.l.lp, i64(nextidx))
	} else {
		it.pack_cursor = nil
	}
	e^ = {}
}

replace_index :: proc(l: List, index: int, value: []u8) -> bool {
	if l.encoding == .Quicklist {
		return replace_at_index(l.ql, index, value)
	}
	p := lp.lp_seek(l.lp, i64(index))
	if p == nil {
		return false
	}
	l.lp = lp.lp_replace(l.lp, &p, value)
	return true
}

delete_range :: proc(l: List, start: int, count: int) {
	if count <= 0 {
		return
	}
	if l.encoding == .Quicklist {
		del_range(l.ql, start, count)
	} else {
		l.lp = lp.lp_delete_range(l.lp, i64(start), u64(count))
	}
}

dup :: proc "contextless" (l: List) -> List {
	d := cast(List)lp.lp_malloc(size_of(List_Object))
	if d == nil {
		out_of_memory()
	}
	d^ = {}
	d.encoding = l.encoding
	if l.encoding == .Listpack {
		d.lp = lp.lp_dup(l.lp)
	} else {
		d.ql = ql_dup(l.ql)
	}
	d.acct = memory_usage(d)
	return d
}

index :: proc(l: List, idx: int) -> (v: Value, ok: bool) {
	it := iterator(l, idx, .Tail)
	e: List_Entry
	if !iter_next(&it, &e) {
		return {}, false
	}
	return entry_value(&it, &e), true
}

range_normalize :: proc "contextless" (llen: int, start: int, end: int) -> (s: int, e: int, ok: bool) {
	if llen <= 0 {
		return 0, 0, false
	}
	s = start
	e = end
	if s < 0 {
		s += llen
	}
	if e < 0 {
		e += llen
	}
	s = max(s, 0)
	e = min(e, llen-1)
	return s, e, s <= e && s < llen && e >= 0
}

pop_range_bounds :: proc(l: List, where_: Where, count: int) -> (start: int, rangelen: int) {
	n := min(max(count, 0), length(l))
	if where_ == .Head {
		return 0, n
	}
	return length(l)-n, n
}

linsert :: proc(l: List, after: bool, pivot: []u8, value: []u8) -> bool {
	widen_if_needed(l, len(value), 1)
	it := iterator(l, 0, .Tail)
	e: List_Entry
	for iter_next(&it, &e) {
		if entry_equal(&it, &e, pivot) {
			where_ := Where.Head
			if after {
				where_ = .Tail
			}
			entry_insert(&it, &e, value, where_)
			return true
		}
	}
	return false
}

lset :: proc(l: List, idx: int, value: []u8) -> bool {
	widen_if_needed(l, len(value), 1)
	if !replace_index(l, int(i32(idx)), value) {
		return false
	}
	narrow_if_possible(l)
	return true
}

lpos :: proc(l: List, ele: []u8, rank: int, count: int, maxlen: int, out: ^[dynamic]int) -> int {
	n := length(l)
	idx := 0
	dir := Where.Tail
	step := 1
	remaining := rank
	if rank < 0 {
		remaining = -rank
		idx = n-1
		dir = .Head
		step = -1
	}
	it := iterator(l, idx, dir)
	e: List_Entry
	examined := 0
	found := 0
	for (maxlen == 0 || examined < maxlen) && iter_next(&it, &e) {
		if entry_equal(&it, &e, ele) {
			remaining -= 1
			if remaining <= 0 {
				if count == -1 {
					return idx
				}
				append(out, idx)
				found += 1
				if count > 0 && found == count {
					break
				}
			}
		}
		examined += 1
		idx += step
	}
	return -1
}

lrem :: proc(l: List, toremove: int, ele: []u8) -> int {
	dir := Where.Tail
	idx := 0
	limit: u64 = max(u64)
	if toremove < 0 {
		dir = .Head
		idx = -1
		limit = u64(-(toremove+1))+1
	} else if toremove > 0 {
		limit = u64(toremove)
	}
	it := iterator(l, idx, dir)
	e: List_Entry
	removed := 0
	for u64(removed) < limit && iter_next(&it, &e) {
		if entry_equal(&it, &e, ele) {
			entry_delete(&it, &e)
			removed += 1
		}
	}
	if removed != 0 {
		narrow_if_possible(l)
	}
	return removed
}

ltrim :: proc(l: List, start: int, end: int) -> (ltrim: int, rtrim: int) {
	n := length(l)
	s, e, ok := range_normalize(n, start, end)
	if !ok {
		delete_range(l, 0, n)
		return n, 0
	}
	ltrim = s
	rtrim = n-e-1
	delete_range(l, e+1, rtrim)
	delete_range(l, 0, ltrim)
	narrow_if_possible(l)
	return
}

moved_add_bytes :: proc "contextless" (src_encoding: Encoding, v: Value, n: int) -> int {
	if src_encoding == .Listpack && v.is_int {
		return lp.lp_entry_size_integer(v.ival)
	}
	return n
}

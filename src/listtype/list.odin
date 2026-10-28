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

Conversion :: enum u8 {
	Auto,
	Growing,
	Shrinking,
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
	l:         List,
	encoding:  Encoding,
	direction: Where,
	lpi:       [^]u8,
	qi:        Iter,
}

List_Entry :: struct {
	lpe: [^]u8,
	qe:  Entry,
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

value_bytes :: proc "contextless" (v: Value, buf: ^[lp.LP_INTBUF_SIZE]u8) -> []u8 {
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

try_convert_listpack :: proc(l: List, add_bytes: int, add_length: int) {
	if l.encoding != .Listpack {
		return
	}
	n := length(l)
	bytes := lp.lp_bytes(l.lp)
	if add_bytes <= max(int)-bytes && add_length <= max(int)-n && !node_exceeds_limit(list_max_listpack_size, bytes+add_bytes, n+add_length) {
		return
	}
	q := ql_new(list_max_listpack_size, list_compress_depth)
	append_listpack(q, l.lp)
	l.lp = nil
	l.ql = q
	l.encoding = .Quicklist
}

try_convert_quicklist :: proc(l: List, shrinking: bool) {
	if l.encoding != .Quicklist || l.ql.len != 1 || l.ql.head.plain {
		return
	}
	n := l.ql.head
	szlimit, countlimit := node_limit(list_max_listpack_size)
	if shrinking {
		if szlimit != NO_LIMIT {
			szlimit /= 2
		}
		if countlimit != NO_LIMIT {
			countlimit /= 2
		}
	}
	if n.sz > szlimit || n.count > countlimit {
		return
	}
	l.lp = n.entry
	n.entry = nil
	ql_release(l.ql)
	l.ql = nil
	l.encoding = .Listpack
}

try_conversion :: proc(l: List, lct: Conversion) {
	if l.encoding == .Listpack {
		if lct != .Shrinking {
			try_convert_listpack(l, 0, 0)
		}
	} else if lct != .Growing {
		try_convert_quicklist(l, lct == .Shrinking)
	}
}

try_conversion_append :: proc(l: List, add_bytes: int, add_length: int) {
	try_convert_listpack(l, add_bytes, add_length)
}

try_conversion_append_values :: proc(l: List, values: [][]u8) {
	total := 0
	for v in values {
		if len(v) > max(int)-total {
			total = max(int)
			break
		}
		total += len(v)
	}
	try_convert_listpack(l, total, len(values))
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
		it.lpi = lp.lp_seek(l.lp, i64(index))
	} else {
		dir := Direction.Start_Head
		if direction == .Head {
			dir = .Start_Tail
		}
		it.qi, _ = get_iterator_at_idx(l.ql, dir, index)
	}
	return it
}

iter_next :: proc(it: ^Iterator, e: ^List_Entry) -> bool {
	if it.encoding == .Quicklist {
		return next(&it.qi, &e.qe)
	}
	if it.lpi == nil {
		return false
	}
	e.lpe = it.lpi
	if it.direction == .Tail {
		it.lpi = lp.lp_next(it.l.lp, it.lpi)
	} else {
		it.lpi = lp.lp_prev(it.l.lp, it.lpi)
	}
	return true
}

entry_value :: proc "contextless" (it: ^Iterator, e: ^List_Entry) -> Value {
	if it.encoding == .Listpack {
		return value_from_lp(e.lpe)
	}
	q := &e.qe
	if q.node.plain || q.value != nil {
		return Value{str = q.value[:q.sz]}
	}
	return Value{ival = q.longval, is_int = true}
}

entry_equal :: proc(it: ^Iterator, e: ^List_Entry, s: []u8) -> bool {
	if it.encoding == .Listpack {
		return lp.lp_compare(e.lpe, s)
	}
	return compare(&e.qe, s)
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
		insert(&it.qi, &e.qe, value, where_ == .Tail)
		return
	}
	nextidx := lp_pointer_index(it.l, it.lpi)
	at := lp_pointer_index(it.l, e.lpe)
	how := lp.LP_BEFORE
	if where_ == .Tail {
		how = lp.LP_AFTER
		at += 1
	}
	it.l.lp = lp.lp_insert_string(it.l.lp, value, e.lpe, how, nil)
	if nextidx >= 0 {
		if at <= nextidx {
			nextidx += 1
		}
		it.lpi = lp.lp_seek(it.l.lp, i64(nextidx))
	} else {
		it.lpi = nil
	}
	e^ = {}
}

entry_delete :: proc(it: ^Iterator, e: ^List_Entry) {
	if it.encoding == .Quicklist {
		del_entry(&it.qi, &e.qe)
		return
	}
	nextidx := lp_pointer_index(it.l, it.lpi)
	at := lp_pointer_index(it.l, e.lpe)
	it.l.lp = lp.lp_delete(it.l.lp, e.lpe, nil)
	if nextidx >= 0 {
		if at < nextidx {
			nextidx -= 1
		}
		it.lpi = lp.lp_seek(it.l.lp, i64(nextidx))
	} else {
		it.lpi = nil
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
	try_conversion_append(l, len(value), 1)
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
	try_conversion_append(l, len(value), 1)
	if !replace_index(l, int(i32(idx)), value) {
		return false
	}
	try_conversion(l, .Shrinking)
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
		try_conversion(l, .Shrinking)
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
	try_conversion(l, .Shrinking)
	return
}

moved_add_bytes :: proc "contextless" (src_encoding: Encoding, v: Value, n: int) -> int {
	if src_encoding == .Listpack && v.is_int {
		return lp.lp_entry_size_integer(v.ival)
	}
	return n
}

#+private
package rax

import "base:intrinsics"

STACK_ENTRIES :: 512
STACK_ARENA :: 8192
ARENA_SLACK :: 8
SEPARATOR_INLINE :: 64
SEPARATOR_KEEP :: 16
INNER_SPLIT_MIN :: 8
OVERSIZE_CEILING :: 1 << 26

Entry :: struct {
	a:    [^]u8,
	b:    [^]u8,
	alen: u32,
	blen: u32,
	ptr:  rawptr,
}

Entry_List :: struct {
	items:       [^]Entry,
	count:       int,
	heap:        bool,
	arena:       [^]u8,
	arena_used:  int,
	arena_heap:  bool,
	stack:       [STACK_ENTRIES]Entry,
	arena_stack: [STACK_ARENA]u8,
}

Shape :: struct {
	plen:  int,
	width: int,
	need:  int,
	fixed: bool,
	vmask: u64,
}

Separator :: struct {
	heap:   [^]u8,
	length: int,
	inline: [SEPARATOR_INLINE]u8,
}

separator_reset :: #force_inline proc "contextless" (sb: ^Separator) {
	sb.heap = nil
	sb.length = 0
}

separator_data :: #force_inline proc "contextless" (sb: ^Separator) -> [^]u8 {
	if sb.heap != nil {
		return sb.heap
	}
	return &sb.inline[0]
}

separator_release :: #force_inline proc "contextless" (sb: ^Separator) {
	if sb.heap != nil {
		scratch_free(sb.heap)
		sb.heap = nil
	}
	sb.length = 0
}

separator_set :: proc "contextless" (sb: ^Separator, e: ^Entry, length: int) {
	if length > SEPARATOR_INLINE {
		sb.heap = scratch_alloc(length)
	} else {
		sb.heap = nil
	}
	entry_copy(e, 0, length, separator_data(sb))
	sb.length = length
}

arena_need :: #force_inline proc "contextless" (n: ^Node) -> int {
	if n.varlen {
		return 0
	}
	return int(n.count) * int(n.plen)
}

entries_init :: proc "contextless" (l: ^Entry_List, need: int, arena: int) {
	l.count = 0
	if need <= STACK_ENTRIES {
		l.items = &l.stack[0]
		l.heap = false
	} else {
		l.items = cast([^]Entry)scratch_alloc(need * size_of(Entry))
		l.heap = true
	}
	l.arena_used = 0
	if arena + ARENA_SLACK <= STACK_ARENA {
		l.arena = &l.arena_stack[0]
		l.arena_heap = false
	} else {
		l.arena = scratch_alloc(arena + ARENA_SLACK)
		l.arena_heap = true
	}
}

entries_release :: proc "contextless" (l: ^Entry_List) {
	if l.heap {
		scratch_free(l.items)
		l.heap = false
	}
	if l.arena_heap {
		scratch_free(l.arena)
		l.arena_heap = false
	}
	l.items = nil
	l.arena = nil
	l.count = 0
}

entries_push :: #force_inline proc "contextless" (l: ^Entry_List, a: [^]u8, alen: int, b: [^]u8, blen: int, p: rawptr) {
	l.items[l.count] = Entry{a, b, u32(alen), u32(blen), p}
	l.count += 1
}

entries_gather :: proc "contextless" (l: ^Entry_List, n: ^Node, lo: int, hi: int) #no_bounds_check {
	plen := int(n.plen)
	if !n.varlen {
		vals := cast([^]rawptr)&node_bytes(n)[n.voff]
		for i in lo ..< hi {
			dst := l.arena[l.arena_used:]
			pattern_key_copy(n, i, dst)
			l.arena_used += plen
			entries_push(l, nil, 0, dst, plen, vals[i])
		}
		return
	}
	pre := node_prefix(n)
	v := var_view(n)
	for i in lo ..< hi {
		start := vv_start(v, i)
		entries_push(l, pre, plen, v.b[start:], vv_end(v, i) - start, vv_ptr(v, i))
	}
}

entries_push_separator :: proc "contextless" (l: ^Entry_List, n: ^Node, i: int, p: rawptr) {
	if !n.varlen {
		dst := l.arena[l.arena_used:]
		pattern_key_copy(n, i, dst)
		l.arena_used += int(n.plen)
		entries_push(l, nil, 0, dst, int(n.plen), p)
		return
	}
	k, kl := entry_key(n, i)
	entries_push(l, node_prefix(n), int(n.plen), k, kl, p)
}

entry_len :: #force_inline proc "contextless" (e: ^Entry) -> int {
	return int(e.alen) + int(e.blen)
}

entry_piece :: #force_inline proc "contextless" (e: ^Entry, at: int) -> ([^]u8, int) {
	if at < int(e.alen) {
		return e.a[at:], int(e.alen) - at
	}
	return e.b[at - int(e.alen):], int(e.blen) - (at - int(e.alen))
}

mismatch :: proc "contextless" (x: [^]u8, y: [^]u8, n: int) -> int #no_bounds_check {
	i := 0
	for i + 8 <= n {
		a := load_be(x[i:])
		b := load_be(y[i:])
		if a != b {
			return i + int(intrinsics.count_leading_zeros(a ~ b) >> 3)
		}
		i += 8
	}
	for i < n && x[i] == y[i] {
		i += 1
	}
	return i
}

entry_cpl :: proc "contextless" (x: ^Entry, y: ^Entry) -> int {
	m := min(entry_len(x), entry_len(y))
	i := 0
	for i < m {
		px, nx := entry_piece(x, i)
		py, ny := entry_piece(y, i)
		run := min(nx, ny, m - i)
		d := mismatch(px, py, run)
		i += d
		if d < run {
			break
		}
	}
	return i
}

entry_byte :: #force_inline proc "contextless" (e: ^Entry, at: int) -> u8 {
	if at < int(e.alen) {
		return e.a[at]
	}
	return e.b[at - int(e.alen)]
}

entry_word :: #force_inline proc "contextless" (e: ^Entry, at: int, avail: int) -> u64 #no_bounds_check {
	if e.alen == 0 {
		return probe_word(e.b[at:], avail)
	}
	v: u64 = 0
	for j in 0 ..< min(avail, 8) {
		v |= u64(entry_byte(e, at + j)) << u64(56 - 8 * j)
	}
	return v
}

entry_copy :: proc "contextless" (e: ^Entry, from: int, length: int, dst: [^]u8) {
	if length <= 0 {
		return
	}
	at := from
	done := 0
	for done < length {
		p, avail := entry_piece(e, at)
		run := min(avail, length - done)
		intrinsics.mem_copy_non_overlapping(&dst[done], p, run)
		done += run
		at += run
	}
}

measure :: proc "contextless" (l: ^Entry_List, lo: int, hi: int, level: u8) -> Shape #no_bounds_check {
	n := hi - lo
	body := level_body(level)
	if n == 0 {
		return Shape{0, 0, pattern_used(body, 0, 0, 0), true, 0}
	}
	first := &l.items[lo]
	length0 := entry_len(first)
	same := true
	for i in lo + 1 ..< hi {
		if entry_len(&l.items[i]) != length0 {
			same = false
			break
		}
	}
	if same && length0 <= PATTERN_MAX {
		words: [PATTERN_MAX / 8]u64
		nwords := (length0 + 7) / 8
		for w in 0 ..< nwords {
			base := entry_word(first, 8 * w, length0 - 8 * w)
			acc: u64 = 0
			for i in lo + 1 ..< hi {
				acc |= entry_word(&l.items[i], 8 * w, length0 - 8 * w) ~ base
			}
			words[w] = acc
		}
		vmask: u64 = 0
		for j in 0 ..< length0 {
			if (words[j >> 3] >> u64(56 - 8 * (j & 7))) & 0xff != 0 {
				vmask |= u64(1) << u64(j)
			}
		}
		k := int(intrinsics.count_ones(vmask))
		return Shape{length0, k, pattern_used(body, length0, k, n), true, vmask}
	}
	plen := length0 if n == 1 else entry_cpl(first, &l.items[hi - 1])
	total := 0
	for i in lo ..< hi {
		total += entry_len(&l.items[i]) - plen
	}
	return Shape{plen, 0, body + plen + n * HEAD_BYTES + total + TAIL_PAD, false, 0}
}

build :: proc "contextless" (
	dst: [^]u8,
	size: int,
	l: ^Entry_List,
	lo: int,
	hi: int,
	level: u8,
	first: ^Node,
	sh: Shape,
) #no_bounds_check {
	nd := cast(^Node)dst
	n := hi - lo
	body := level_body(level)
	plen := sh.plen
	nd.count = u16(n)
	nd.level = level
	nd.varlen = !sh.fixed
	nd.spare = 0
	nd.plen = u32(plen)
	nd.size = u32(size)
	if level > 0 {
		node_set_first(nd, first)
	}
	if sh.fixed {
		length := plen
		k := sh.width
		if n > 0 && length > 0 {
			entry_copy(&l.items[lo], 0, length, dst[body:])
		}
		pos := dst[body + 2 * length:]
		t := 0
		for j in 0 ..< length {
			varying := (sh.vmask >> u64(j)) & 1 != 0
			dst[body + length + j] = 0 if varying else 0xff
			if varying {
				pos[t] = u8(j)
				t += 1
			}
		}
		kb := body + 2 * length + k
		capacity := (size - kb) / (k + size_of(rawptr))
		for capacity > n && align8(kb + capacity * k) + capacity * size_of(rawptr) > size {
			capacity -= 1
		}
		capacity = min(capacity, MAX_ENTRY_COUNT)
		voff := align8(kb + capacity * k)
		nd.width = u32(k)
		nd.cap = u16(capacity)
		nd.voff = u32(voff)
		vals := cast([^]rawptr)&dst[voff]
		for i in 0 ..< n {
			e := &l.items[lo + i]
			slot := dst[kb + i * k:]
			if e.alen == 0 {
				for q in 0 ..< k {
					slot[q] = e.b[pos[q]]
				}
			} else {
				for q in 0 ..< k {
					slot[q] = entry_byte(e, int(pos[q]))
				}
			}
			vals[i] = e.ptr
		}
		return
	}
	if n > 0 && plen > 0 {
		entry_copy(&l.items[lo], 0, plen, dst[body:])
	}
	kb := body + plen
	top := size - TAIL_PAD
	total := sh.need - (kb + n * HEAD_BYTES + TAIL_PAD)
	spare := size - sh.need
	capacity := n + spare / (HEAD_BYTES + total / max(n, 1))
	capacity = min(capacity, MAX_ENTRY_COUNT)
	nd.width = 0
	nd.cap = u16(capacity)
	nd.voff = u32(top)
	v := var_view(nd)
	pos := top
	for i in 0 ..< n {
		e := &l.items[lo + i]
		k := entry_len(e) - plen
		pos -= k
		entry_copy(e, plen, k, dst[pos:])
		vv_set(v, i, suffix_hint(dst[pos:], k), pos, e.ptr)
	}
}

build_in_place :: #force_no_inline proc "contextless" (
	n: ^Node,
	l: ^Entry_List,
	lo: int,
	hi: int,
	level: u8,
	first: ^Node,
	sh: Shape,
) {
	size := int(n.size)
	buf: [SCRATCH_BYTES]u8 = ---
	tmp: [^]u8 = &buf[0]
	if size > SCRATCH_BYTES {
		tmp = scratch_alloc(size)
	}
	build(tmp, size, l, lo, hi, level, first, sh)
	intrinsics.mem_copy_non_overlapping(n, tmp, size)
	if size > SCRATCH_BYTES {
		scratch_free(tmp)
	}
}

build_new :: proc "contextless" (
	r: ^Rax,
	size: int,
	l: ^Entry_List,
	lo: int,
	hi: int,
	level: u8,
	first: ^Node,
	sh: Shape,
) -> ^Node {
	nd, usable := node_alloc(r, max(size, sh.need))
	build(cast([^]u8)nd, usable, l, lo, hi, level, first, sh)
	return nd
}

place :: proc "contextless" (
	r: ^Rax,
	old: ^Node,
	l: ^Entry_List,
	lo: int,
	hi: int,
	level: u8,
	first: ^Node,
	sh: Shape,
	grow_to: int,
) -> ^Node {
	if sh.need <= int(old.size) {
		build_in_place(old, l, lo, hi, level, first, sh)
		return old
	}
	nd := build_new(r, grow_to, l, lo, hi, level, first, sh)
	node_release(r, old)
	return nd
}

balance_point :: proc "contextless" (l: ^Entry_List, cnt: int, lo: int, hi: int) -> int #no_bounds_check {
	total := 0
	for i in 0 ..< cnt {
		total += entry_len(&l.items[i]) + size_of(rawptr)
	}
	acc := 0
	m := hi
	for i in 0 ..< cnt {
		acc += entry_len(&l.items[i]) + size_of(rawptr)
		if acc * 2 >= total {
			m = i + 1
			break
		}
	}
	return clamp(m, lo, hi)
}

Insert_Result :: struct {
	node:    ^Node,
	right:   ^Node,
	existed: bool,
	sep:     Separator,
}

split_left :: proc "contextless" (
	r: ^Rax,
	n: ^Node,
	l: ^Entry_List,
	m: int,
	idx: int,
	first: ^Node,
	limit: int,
) -> ^Node {
	keep := m - 1 if idx < m else m
	n.count = u16(keep)
	if idx >= m {
		return n
	}
	e := &l.items[idx]
	if node_insert_fast(n, idx, e.b, int(e.blen), int(e.blen), e.ptr) {
		return n
	}
	lsh := measure(l, 0, m, n.level)
	return place(r, n, l, 0, m, n.level, first, lsh, limit)
}

split_node :: proc "contextless" (
	r: ^Rax,
	n: ^Node,
	l: ^Entry_List,
	cnt: int,
	idx: int,
	rightmost: bool,
	leftmost: bool,
	first: ^Node,
	out: ^Insert_Result,
) #no_bounds_check {
	level := n.level
	limit := level_limit(level)
	if level == 0 {
		m: int
		if rightmost && idx == cnt - 1 {
			m = cnt - 1
		} else if leftmost && idx == 0 {
			m = 1
		} else {
			m = balance_point(l, cnt, 1, cnt - 1)
		}
		right_min := &l.items[m]
		c := entry_cpl(&l.items[m - 1], right_min)
		sep_len := min(entry_len(right_min), max(c + 1, SEPARATOR_KEEP))
		separator_set(&out.sep, right_min, sep_len)
		rsh := measure(l, m, cnt, 0)
		out.right = build_new(r, limit, l, m, cnt, 0, nil, rsh)
		out.node = split_left(r, n, l, m, idx, nil, limit)
		return
	}
	if cnt < 2 {
		sh := measure(l, 0, cnt, level)
		out.node = place(r, n, l, 0, cnt, level, first, sh, sh.need)
		return
	}
	m: int
	if rightmost && idx == cnt - 1 {
		m = cnt - 1
	} else if leftmost && idx == 0 {
		m = 0
	} else if cnt == 2 {
		m = 1
	} else {
		m = balance_point(l, cnt, 1, cnt - 2)
	}
	up := &l.items[m]
	separator_set(&out.sep, up, entry_len(up))
	rsh := measure(l, m + 1, cnt, level)
	out.right = build_new(r, limit, l, m + 1, cnt, level, cast(^Node)up.ptr, rsh)
	out.node = split_left(r, n, l, m, idx, first, limit)
}

insert_slow :: #force_no_inline proc "contextless" (
	r: ^Rax,
	n: ^Node,
	idx: int,
	s: [^]u8,
	sl: int,
	p: rawptr,
	rightmost: bool,
	leftmost: bool,
	out: ^Insert_Result,
) {
	l: Entry_List = ---
	count := int(n.count)
	cnt := count + 1
	entries_init(&l, cnt, arena_need(n))
	entries_gather(&l, n, 0, idx)
	entries_push(&l, nil, 0, s, sl, p)
	entries_gather(&l, n, idx, count)
	level := n.level
	first := node_first(n) if level > 0 else nil
	sh := measure(&l, 0, cnt, level)
	limit := level_limit(level)
	size := int(n.size)
	if sh.need <= size || sh.need <= limit {
		out.node = place(r, n, &l, 0, cnt, level, first, sh, min(limit, size + size / 2))
	} else if level > 0 && cnt < INNER_SPLIT_MIN && sh.need <= OVERSIZE_CEILING {
		out.node = place(r, n, &l, 0, cnt, level, first, sh, sh.need + sh.need / 4)
	} else {
		split_node(r, n, &l, cnt, idx, rightmost, leftmost, first, out)
	}
	entries_release(&l)
}

node_insert :: proc "contextless" (
	r: ^Rax,
	n: ^Node,
	idx: int,
	s: [^]u8,
	sl: int,
	sroom: int,
	p: rawptr,
	rightmost: bool,
	leftmost: bool,
	out: ^Insert_Result,
) {
	out.node = n
	if node_insert_fast(n, idx, s, sl, sroom, p) {
		return
	}
	insert_slow(r, n, idx, s, sl, p, rightmost, leftmost, out)
}

node_insert_fast :: proc "contextless" (n: ^Node, idx: int, s: [^]u8, sl: int, sroom: int, p: rawptr) -> bool {
	plen := int(n.plen)
	if !n.varlen {
		if sl != plen || int(n.count) >= int(n.cap) || !pattern_matches(n, s, sroom) {
			return false
		}
		pattern_insert(n, idx, s, p)
		return true
	}
	if !prefix_equal(n, s, sl, sroom) {
		return false
	}
	tl := sl - plen
	if n.count > 0 && var_make_room(n, tl) {
		var_insert(n, idx, s[plen:], tl, p)
		return true
	}
	return false
}

single_node :: proc "contextless" (r: ^Rax, s: [^]u8, sl: int, p: rawptr) -> ^Node {
	l: Entry_List = ---
	entries_init(&l, 1, 0)
	entries_push(&l, nil, 0, s, sl, p)
	sh := measure(&l, 0, 1, 0)
	nd := build_new(r, sh.need, &l, 0, 1, 0, nil, sh)
	entries_release(&l)
	return nd
}

grow_root :: proc "contextless" (r: ^Rax, left: ^Node, sep: ^Separator, right: ^Node) -> ^Node {
	l: Entry_List = ---
	entries_init(&l, 1, 0)
	entries_push(&l, nil, 0, separator_data(sep), sep.length, right)
	level := left.level + 1
	sh := measure(&l, 0, 1, level)
	nd := build_new(r, sh.need, &l, 0, 1, level, left, sh)
	entries_release(&l)
	return nd
}

shrink_node :: #force_no_inline proc "contextless" (r: ^Rax, n: ^Node) -> ^Node {
	l: Entry_List = ---
	count := int(n.count)
	entries_init(&l, count, arena_need(n))
	entries_gather(&l, n, 0, count)
	level := n.level
	first := node_first(n) if level > 0 else nil
	sh := measure(&l, 0, count, level)
	nd := build_new(r, sh.need + sh.need / 2, &l, 0, count, level, first, sh)
	entries_release(&l)
	node_release(r, n)
	return nd
}

merge_children :: #force_no_inline proc "contextless" (r: ^Rax, p: ^Node, i: int) -> bool {
	a := child_at(p, i)
	b := child_at(p, i + 1)
	level := a.level
	limit := level_limit(level)
	merge_limit := limit - limit / 4
	if node_used(a) + node_used(b) - level_body(level) > merge_limit {
		return false
	}
	l: Entry_List = ---
	na := int(a.count)
	nb := int(b.count)
	cnt := na + nb + (1 if level > 0 else 0)
	sep_arena := 0
	if level > 0 && !p.varlen {
		sep_arena = int(p.plen)
	}
	entries_init(&l, cnt, arena_need(a) + arena_need(b) + sep_arena)
	entries_gather(&l, a, 0, na)
	if level > 0 {
		entries_push_separator(&l, p, i, node_first(b))
	}
	entries_gather(&l, b, 0, nb)
	sh := measure(&l, 0, cnt, level)
	if sh.need > merge_limit {
		entries_release(&l)
		return false
	}
	first := node_first(a) if level > 0 else nil
	merged: ^Node
	if sh.need <= int(a.size) {
		build_in_place(a, &l, 0, cnt, level, first, sh)
		merged = a
		node_release(r, b)
	} else if sh.need <= int(b.size) {
		build_in_place(b, &l, 0, cnt, level, first, sh)
		merged = b
		node_release(r, a)
	} else {
		merged = build_new(r, limit, &l, 0, cnt, level, first, sh)
		node_release(r, a)
		node_release(r, b)
	}
	entries_release(&l)
	set_child(p, i, merged)
	entry_remove(p, i)
	return true
}

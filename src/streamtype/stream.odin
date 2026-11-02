package streamtype

import integer "../integer"
import lp "../listpack"
import rx "../rax"
import "base:intrinsics"
import "base:runtime"

foreign import libc "system:c"

foreign libc {
	@(link_name = "malloc_usable_size")
	libc_usable_size :: proc "c" (ptr: rawptr) -> uint ---
}

Entry_Mark :: enum u8 {
	Tombstone,
	Shared_Fields,
}

Entry_Marks :: bit_set[Entry_Mark;u8]

NODE_RESERVE_CAP :: 4096
NODE_SIZE_CEILING :: 1 << 30
NODE_GROW_SLACK :: 16
NODE_MAX_BYTES_DEFAULT :: 4096
NODE_MAX_ENTRIES_DEFAULT :: 100
ID_TEXT_MAX :: 41
BATCH_MAX :: 64

stream_node_max_bytes: int = NODE_MAX_BYTES_DEFAULT
stream_node_max_entries: i64 = NODE_MAX_ENTRIES_DEFAULT

ID :: struct {
	ms:  u64,
	seq: u64,
}

ID_MIN :: ID{0, 0}
ID_MAX :: ID{max(u64), max(u64)}

Stream_Log :: struct {
	nodes:       ^rx.Rax,
	groups:      ^rx.Rax,
	live:        u64,
	added:       u64,
	head:        ID,
	top:         ID,
	tomb:        ID,
	node_bytes:  int,
	group_bytes: int,
	acct:        int,
}

Stream :: ^Stream_Log

Append_Result :: enum u8 {
	Ok,
	Id_Not_Greater,
	Entry_Too_Large,
}

@(private)
HDR :: lp.LP_HDR_SIZE

@(private)
EOF :: lp.LP_EOF

@(private)
NUMELE_UNKNOWN :: lp.LP_HDR_NUMELE_UNKNOWN

@(cold)
out_of_memory :: proc "contextless" () -> ! {
	intrinsics.trap()
}

usable :: #force_inline proc "contextless" (p: rawptr) -> int {
	if p == nil {
		return 0
	}
	return int(libc_usable_size(p))
}

encode_id :: #force_inline proc "contextless" (buf: ^[16]u8, id: ID) {
	ms := id.ms
	seq := id.seq
	for i := 7; i >= 0; i -= 1 {
		buf[i] = u8(ms)
		buf[i + 8] = u8(seq)
		ms >>= 8
		seq >>= 8
	}
}

decode_id :: #force_inline proc "contextless" (buf: []u8) -> (id: ID) {
	if len(buf) < 16 {
		return
	}
	for i in 0 ..< 8 {
		id.ms = id.ms << 8 | u64(buf[i])
		id.seq = id.seq << 8 | u64(buf[i + 8])
	}
	return
}

compare_id :: #force_inline proc "contextless" (a: ID, b: ID) -> int {
	if a.ms != b.ms {
		return a.ms < b.ms ? -1 : 1
	}
	if a.seq != b.seq {
		return a.seq < b.seq ? -1 : 1
	}
	return 0
}

id_is_zero :: #force_inline proc "contextless" (id: ID) -> bool {
	return id.ms == 0 && id.seq == 0
}

incr_id :: proc "contextless" (id: ^ID) -> bool {
	if id.seq != max(u64) {
		id.seq += 1
		return true
	}
	id.seq = 0
	if id.ms != max(u64) {
		id.ms += 1
		return true
	}
	id.ms = 0
	return false
}

decr_id :: proc "contextless" (id: ^ID) -> bool {
	if id.seq != 0 {
		id.seq -= 1
		return true
	}
	id.seq = max(u64)
	if id.ms != 0 {
		id.ms -= 1
		return true
	}
	id.ms = max(u64)
	return false
}

next_id :: proc "contextless" (last: ID, now_ms: u64) -> ID {
	if now_ms > last.ms {
		return ID{now_ms, 0}
	}
	id := last
	incr_id(&id)
	return id
}

format_u64 :: proc "contextless" (dst: [^]u8, v: u64) -> int #no_bounds_check {
	tmp: [20]u8
	n := 0
	x := v
	for {
		tmp[n] = u8('0' + x % 10)
		n += 1
		x /= 10
		if x == 0 {
			break
		}
	}
	for i in 0 ..< n {
		dst[i] = tmp[n - 1 - i]
	}
	return n
}

format_id :: proc "contextless" (buf: ^[ID_TEXT_MAX]u8, id: ID) -> []u8 {
	p := ([^]u8)(&buf[0])
	n := format_u64(p, id.ms)
	buf[n] = '-'
	n += 1
	n += format_u64(&buf[n], id.seq)
	return buf[:n]
}

@(private)
read_le :: #force_inline proc "contextless" (p: [^]u8, width: int) -> u64 #no_bounds_check {
	v: u64
	for i := width - 1; i >= 0; i -= 1 {
		v = v << 8 | u64(p[i])
	}
	return v
}

lp_get_integer :: #force_inline proc "contextless" (ele: [^]u8) -> i64 {
	return elem_int(ele)
}

@(private)
elem_int :: proc "contextless" (p: [^]u8) -> i64 #no_bounds_check {
	tag := p[0]
	switch {
	case tag < 0x80:
		return i64(tag)
	case tag < 0xC0:
		v, _ := integer.parse_i64(p[1:1 + int(tag & 0x3F)])
		return v
	case tag < 0xE0:
		v := i64(u16(tag & 0x1F) << 8 | u16(p[1]))
		return v >= 4096 ? v - 8192 : v
	case tag < 0xF0:
		n := int(tag & 0x0F) << 8 | int(p[1])
		v, _ := integer.parse_i64(p[2:2 + n])
		return v
	case tag == 0xF0:
		n := int(read_le(&p[1], 4))
		v, _ := integer.parse_i64(p[5:5 + n])
		return v
	case tag == 0xF1:
		return i64(i16(u16(read_le(&p[1], 2))))
	case tag == 0xF2:
		v := u32(read_le(&p[1], 3))
		if v & 0x800000 != 0 {
			v |= 0xFF000000
		}
		return i64(i32(v))
	case tag == 0xF3:
		return i64(i32(u32(read_le(&p[1], 4))))
	case tag == 0xF4:
		return i64(read_le(&p[1], 8))
	}
	return 0
}

@(private)
elem_len :: proc "contextless" (p: [^]u8) -> int #no_bounds_check {
	tag := p[0]
	body: int
	switch {
	case tag < 0x80:
		return 2
	case tag < 0xC0:
		body = 1 + int(tag & 0x3F)
	case tag < 0xE0:
		return 3
	case tag < 0xF0:
		body = 2 + (int(tag & 0x0F) << 8 | int(p[1]))
	case tag == 0xF0:
		body = 5 + int(read_le(&p[1], 4))
	case tag == 0xF1:
		return 4
	case tag == 0xF2:
		return 5
	case tag == 0xF3:
		return 6
	case tag == 0xF4:
		return 10
	case:
		return 0
	}
	return body + lp.backlen_width(u64(body))
}

@(private)
elem_next :: #force_inline proc "contextless" (p: [^]u8) -> [^]u8 {
	return ([^]u8)(uintptr(p) + uintptr(elem_len(p)))
}

@(private)
elem_prev :: #force_inline proc "contextless" (p: [^]u8) -> [^]u8 {
	before := ([^]u8)(uintptr(p) - 1)
	body := lp.lp_decode_backlen(before)
	return ([^]u8)(uintptr(p) - uintptr(body) - uintptr(lp.backlen_width(body)))
}

@(private)
elem_skip :: #force_inline proc "contextless" (p: [^]u8, n: int) -> [^]u8 {
	q := p
	for _ in 0 ..< n {
		q = elem_next(q)
	}
	return q
}

@(private)
elem_bytes :: proc "contextless" (p: [^]u8, buf: ^[lp.LP_INTBUF_SIZE]u8) -> []u8 #no_bounds_check {
	tag := p[0]
	switch {
	case tag >= 0x80 && tag < 0xC0:
		return p[1:1 + int(tag & 0x3F)]
	case tag >= 0xE0 && tag < 0xF0:
		n := int(tag & 0x0F) << 8 | int(p[1])
		return p[2:2 + n]
	case tag == 0xF0:
		n := int(read_le(&p[1], 4))
		return p[5:5 + n]
	}
	n := lp.ll2string(&buf[0], elem_int(p))
	return buf[:n]
}

@(private)
int_size :: #force_inline proc "contextless" (v: i64) -> int {
	return lp.lp_entry_size_integer(v)
}

@(private)
put_int :: proc "contextless" (dst: [^]u8, v: i64) -> int {
	n := lp.integer_body_size(v)
	lp.write_integer(dst[:n], v)
	w := lp.lp_encode_backlen(&dst[n], u64(n))
	return n + int(w)
}

@(private)
str_size :: #force_inline proc "contextless" (s: []u8) -> int {
	plan, _ := lp.plan_entry(lp.entry_from_bytes(s))
	return plan.encoded_bytes
}

@(private)
put_str :: proc "contextless" (dst: [^]u8, s: []u8) -> int {
	plan, _ := lp.plan_entry(lp.entry_from_bytes(s))
	lp.write_entry(dst[:plan.encoded_bytes], plan)
	return plan.encoded_bytes
}

@(private)
lp_total :: #force_inline proc "contextless" (p: [^]u8) -> int {
	return int(read_le(p, 4))
}

@(private)
lp_set_total :: #force_inline proc "contextless" (p: [^]u8, v: int) {
	x := u32(v)
	p[0] = u8(x)
	p[1] = u8(x >> 8)
	p[2] = u8(x >> 16)
	p[3] = u8(x >> 24)
}

@(private)
lp_add_count :: #force_inline proc "contextless" (p: [^]u8, add: int) {
	cur := int(read_le(&p[4], 2))
	if cur == NUMELE_UNKNOWN {
		return
	}
	n := min(cur + add, NUMELE_UNKNOWN)
	p[4] = u8(n)
	p[5] = u8(n >> 8)
}

@(private)
lp_first_elem :: #force_inline proc "contextless" (p: [^]u8) -> [^]u8 {
	return &p[HDR]
}

@(private)
Node_Header :: struct {
	count:       i64,
	deleted:     i64,
	nfields:     int,
	fields:      [^]u8,
	entries:     [^]u8,
	deleted_ptr: [^]u8,
}

@(private)
node_header :: proc "contextless" (p: [^]u8) -> (h: Node_Header) {
	e := lp_first_elem(p)
	h.count = elem_int(e)
	e = elem_next(e)
	h.deleted_ptr = e
	h.deleted = elem_int(e)
	e = elem_next(e)
	h.nfields = int(elem_int(e))
	e = elem_next(e)
	h.fields = e
	e = elem_skip(e, h.nfields)
	h.entries = elem_next(e)
	return
}

@(private)
node_rewrite_int :: proc "contextless" (s: Stream, node: ^[^]u8, at: int, v: i64) -> bool {
	p := node^
	old := elem_len(&p[at])
	nw := int_size(v)
	if old == nw {
		put_int(&p[at], v)
		return false
	}
	total := lp_total(p)
	delta := nw - old
	if delta > 0 {
		need := total + delta
		if need > usable(p) {
			q := lp_grow(s, p, need)
			p = q
			node^ = q
		}
	}
	tail := total - (at + old)
	intrinsics.mem_copy(&p[at + nw], &p[at + old], tail)
	put_int(&p[at], v)
	lp_set_total(p, total + delta)
	return true
}

@(private)
lp_alloc :: proc "contextless" (s: Stream, size: int) -> [^]u8 {
	p := runtime.heap_alloc(size, false)
	if p == nil {
		out_of_memory()
	}
	s.node_bytes += usable(p)
	return ([^]u8)(p)
}

@(private)
lp_grow :: proc "contextless" (s: Stream, p: [^]u8, need: int) -> [^]u8 {
	old := usable(p)
	grown := max(need, old + old / 2)
	if grown > NODE_SIZE_CEILING + 64 {
		grown = need
	}
	q := runtime.heap_resize(p, grown)
	if q == nil {
		out_of_memory()
	}
	s.node_bytes += usable(q) - old
	return ([^]u8)(q)
}

@(private)
lp_fit :: proc "contextless" (s: Stream, p: [^]u8) -> [^]u8 {
	size := lp_total(p)
	old := usable(p)
	if old - size < 64 {
		return p
	}
	q := runtime.heap_resize(p, size)
	if q == nil {
		return p
	}
	s.node_bytes += usable(q) - old
	return ([^]u8)(q)
}

@(private)
lp_release :: proc "contextless" (s: Stream, p: [^]u8) {
	s.node_bytes -= usable(p)
	runtime.heap_free(p)
}

@(private)
free_lp :: proc "contextless" (p: rawptr) {
	runtime.heap_free(p)
}

create :: proc "contextless" () -> Stream {
	p := runtime.heap_alloc(size_of(Stream_Log), true)
	if p == nil {
		out_of_memory()
	}
	s := Stream(p)
	s.nodes = rx.create(&s.node_bytes)
	return s
}

destroy :: proc "contextless" (s: Stream) {
	if s == nil {
		return
	}
	if s.nodes != nil {
		rx.destroy(s.nodes, free_lp)
		s.nodes = nil
	}
	free_groups(s)
	runtime.heap_free(s)
}

memory_usage :: proc "contextless" (s: Stream) -> int {
	if s == nil {
		return 0
	}
	return usable(s) + s.node_bytes + s.group_bytes
}

length :: #force_inline proc "contextless" (s: Stream) -> u64 {
	if s == nil {
		return 0
	}
	return s.live
}

node_count :: #force_inline proc "contextless" (s: Stream) -> u64 {
	if s == nil || s.nodes == nil {
		return 0
	}
	return s.nodes.numele
}

rax_nodes :: #force_inline proc "contextless" (s: Stream) -> u64 {
	if s == nil || s.nodes == nil {
		return 1
	}
	return radix_shape(s.nodes)
}

group_count :: #force_inline proc "contextless" (s: Stream) -> u64 {
	if s == nil || s.groups == nil {
		return 0
	}
	return s.groups.numele
}

@(private)
radix_shape :: proc "contextless" (r: ^rx.Rax) -> u64 #no_bounds_check {
	n := r.numele
	if n == 0 {
		return 1
	}
	stack: [18]int
	sp := 0
	branches: u64
	nested: u64
	leaves: u64
	root_branch := false
	prev: [16]u8
	prev_l := -1
	first := true
	it: rx.Iterator
	rx.start(&it, r)
	rx.seek(&it, "^")
	for rx.next(&it) {
		k := rx.key(&it)
		if first {
			first = false
			copy(prev[:], k)
			continue
		}
		l := 0
		for l < 16 && l < len(k) && prev[l] == k[l] {
			l += 1
		}
		if l == 0 {
			root_branch = true
		}
		if l == 15 {
			leaves += prev_l == 15 ? 1 : 2
		}
		for sp > 0 && stack[sp - 1] > l {
			x := stack[sp - 1]
			sp -= 1
			below := sp > 0 ? stack[sp - 1] : -1
			parent := max(below, l)
			if x >= 1 && parent == x - 1 {
				nested += 1
			}
		}
		if sp == 0 || stack[sp - 1] < l {
			stack[sp] = l
			sp += 1
			branches += 1
		}
		prev_l = l
		copy(prev[:], k)
	}
	rx.stop(&it)
	for sp > 0 {
		x := stack[sp - 1]
		sp -= 1
		below := sp > 0 ? stack[sp - 1] : -1
		if x >= 1 && below == x - 1 {
			nested += 1
		}
	}
	inner := branches - (root_branch ? 1 : 0)
	children := (n - 1) + branches
	return 1 + n + inner + children - nested - leaves
}

dup :: proc(s: Stream) -> Stream {
	d := create()
	it: rx.Iterator
	rx.start(&it, s.nodes)
	rx.seek(&it, "^")
	for rx.next(&it) {
		src := ([^]u8)(it.data)
		size := lp_total(src)
		q := lp_alloc(d, size)
		intrinsics.mem_copy_non_overlapping(q, src, size)
		rx.insert(d.nodes, rx.key(&it), q)
	}
	rx.stop(&it)
	d.live = s.live
	d.top = s.top
	d.head = s.head
	d.tomb = s.tomb
	d.added = s.added
	copy_groups(s, d)
	return d
}

@(private)
entry_skip :: proc "contextless" (flags_ptr: [^]u8, nfields: int) -> [^]u8 {
	marks := marks_at(flags_ptr)
	p := elem_next(flags_ptr)
	p = elem_next(p)
	p = elem_next(p)
	if .Shared_Fields in marks {
		p = elem_skip(p, nfields)
	} else {
		n := int(elem_int(p))
		p = elem_skip(elem_next(p), 2 * n)
	}
	return elem_next(p)
}

@(private)
entry_id_at :: #force_inline proc "contextless" (flags_ptr: [^]u8, master: ID) -> ID {
	p := elem_next(flags_ptr)
	ms := u64(elem_int(p))
	p = elem_next(p)
	seq := u64(elem_int(p))
	return ID{master.ms + ms, master.seq + seq}
}

@(private)
entry_last :: #force_inline proc "contextless" (p: [^]u8) -> [^]u8 {
	total := lp_total(p)
	tail := &p[total - 1]
	lc := elem_prev(tail)
	back := int(elem_int(lc))
	if back <= 0 {
		return nil
	}
	return elem_skip_back(lc, back)
}

@(private)
elem_skip_back :: #force_inline proc "contextless" (p: [^]u8, n: int) -> [^]u8 {
	q := p
	for _ in 0 ..< n {
		q = elem_prev(q)
	}
	return q
}

@(private)
entry_before :: proc "contextless" (flags_ptr: [^]u8) -> [^]u8 {
	lc := elem_prev(flags_ptr)
	back := int(elem_int(lc))
	if back == 0 {
		return nil
	}
	return elem_skip_back(lc, back)
}

@(private)
Entry_Head :: struct {
	id:     ID,
	fields: int,
	marks:  Entry_Marks,
	body:   [^]u8,
}

@(private)
marks_at :: #force_inline proc "contextless" (at: [^]u8) -> Entry_Marks {
	return transmute(Entry_Marks)u8(elem_int(at))
}

@(private)
mark_tombstone :: #force_inline proc "contextless" (at: [^]u8, marks: Entry_Marks) {
	at[0] = transmute(u8)(marks + {.Tombstone})
}

@(private)
read_entry_head :: proc "contextless" (at: [^]u8, base: ID, width: int) -> (h: Entry_Head) {
	h.marks = marks_at(at)
	p := elem_next(at)
	h.id.ms = base.ms + u64(elem_int(p))
	p = elem_next(p)
	h.id.seq = base.seq + u64(elem_int(p))
	p = elem_next(p)
	h.fields = width
	if .Shared_Fields not_in h.marks {
		h.fields = int(elem_int(p))
		p = elem_next(p)
	}
	h.body = p
	return
}

@(private)
entry_end :: proc "contextless" (h: Entry_Head) -> [^]u8 {
	span := h.fields
	if .Shared_Fields not_in h.marks {
		span *= 2
	}
	return elem_next(elem_skip(h.body, span))
}

End :: enum u8 {
	Head,
	Tail,
}

boundary_id :: proc(s: Stream, side: End, tombstones: bool) -> ID {
	from_tail := side == .Tail
	walk: rx.Iterator
	rx.start(&walk, s.nodes)
	defer rx.stop(&walk)
	rx.seek(&walk, from_tail ? "$" : "^")
	for from_tail ? rx.prev(&walk) : rx.next(&walk) {
		node := ([^]u8)(walk.data)
		h := node_header(node)
		if h.entries[0] == EOF {
			continue
		}
		base := decode_id(rx.key(&walk))
		at := from_tail ? entry_last(node) : h.entries
		for at != nil {
			e := read_entry_head(at, base, h.nfields)
			if tombstones || .Tombstone not_in e.marks {
				return e.id
			}
			if from_tail {
				at = entry_before(at)
				continue
			}
			at = entry_end(e)
			if at[0] == EOF {
				at = nil
			}
		}
	}
	return from_tail ? ID_MIN : ID_MAX
}

@(private)
first_live_or_zero :: proc(s: Stream) -> ID {
	if s.live == 0 {
		return ID_MIN
	}
	return boundary_id(s, .Head, false)
}

@(private)
fields_match :: proc "contextless" (master: [^]u8, nfields: int, fv: [][]u8) -> bool #no_bounds_check {
	if nfields * 2 != len(fv) {
		return false
	}
	buf: [lp.LP_INTBUF_SIZE]u8
	p := master
	for i in 0 ..< nfields {
		f := elem_bytes(p, &buf)
		if string(f) != string(fv[2 * i]) {
			return false
		}
		p = elem_next(p)
	}
	return true
}

@(private)
Entry_Plan :: struct {
	marks:    Entry_Marks,
	ms_step:  i64,
	seq_step: i64,
	tally:    i64,
	bytes:    int,
	elements: int,
}

@(private)
plan_entry_layout :: proc "contextless" (id: ID, base: ID, shared: bool, fv: [][]u8) -> (p: Entry_Plan) #no_bounds_check {
	pairs := len(fv) / 2
	p.ms_step = i64(id.ms - base.ms)
	p.seq_step = i64(id.seq - base.seq)
	if shared {
		p.marks = {.Shared_Fields}
		p.tally = i64(3 + pairs)
		for i := 1; i < 2 * pairs; i += 2 {
			p.bytes += str_size(fv[i])
		}
	} else {
		p.tally = i64(4 + 2 * pairs)
		p.bytes = int_size(i64(pairs))
		for a in fv[:2 * pairs] {
			p.bytes += str_size(a)
		}
	}
	p.bytes += int_size(i64(transmute(u8)p.marks)) + int_size(p.ms_step) + int_size(p.seq_step) + int_size(p.tally)
	p.elements = int(p.tally) + 1
	return
}

@(private)
emit_entry :: proc "contextless" (dst: [^]u8, p: Entry_Plan, fv: [][]u8) -> int #no_bounds_check {
	pairs := len(fv) / 2
	o := put_int(dst, i64(transmute(u8)p.marks))
	o += put_int(&dst[o], p.ms_step)
	o += put_int(&dst[o], p.seq_step)
	if .Shared_Fields in p.marks {
		for i := 1; i < 2 * pairs; i += 2 {
			o += put_str(&dst[o], fv[i])
		}
	} else {
		o += put_int(&dst[o], i64(pairs))
		for a in fv[:2 * pairs] {
			o += put_str(&dst[o], a)
		}
	}
	o += put_int(&dst[o], p.tally)
	return o
}

@(private)
master_bytes :: proc "contextless" (fv: [][]u8) -> int #no_bounds_check {
	pairs := len(fv) / 2
	n := int_size(1) + int_size(0) + int_size(i64(pairs)) + int_size(0)
	for i := 0; i < 2 * pairs; i += 2 {
		n += str_size(fv[i])
	}
	return n
}

@(private)
emit_master :: proc "contextless" (dst: [^]u8, fv: [][]u8) -> int #no_bounds_check {
	pairs := len(fv) / 2
	o := put_int(dst, 1)
	o += put_int(&dst[o], 0)
	o += put_int(&dst[o], i64(pairs))
	for i := 0; i < 2 * pairs; i += 2 {
		o += put_str(&dst[o], fv[i])
	}
	o += put_int(&dst[o], 0)
	return o
}

@(private)
pick_entry_id :: proc "contextless" (s: Stream, mode: Xadd_Id_Mode, want: ID, now_ms: u64) -> (id: ID, fresh: bool) {
	switch mode {
	case .Generated:
		id = next_id(s.top, now_ms)
	case .Generated_Seq:
		id = ID{want.ms, 0}
		if want.ms == s.top.ms {
			if s.top.seq == max(u64) {
				return
			}
			id.seq = s.top.seq + 1
		}
	case .Explicit:
		id = want
	}
	return id, compare_id(id, s.top) > 0
}

@(private)
payload_bytes :: proc "contextless" (fv: [][]u8) -> int {
	n := 0
	for a in fv {
		n += len(a)
	}
	return n
}

@(private)
Tail :: struct {
	node: [^]u8,
	key:  [16]u8,
}

@(private)
find_tail :: proc "contextless" (s: Stream) -> (t: Tail, found: bool) {
	walk: rx.Iterator
	rx.start(&walk, s.nodes)
	rx.seek(&walk, "$")
	if rx.next(&walk) {
		t.node = ([^]u8)(walk.data)
		copy(t.key[:], rx.key(&walk))
		found = true
	}
	rx.stop(&walk)
	return
}

@(private)
node_accepts :: proc "contextless" (node: [^]u8, incoming: int) -> bool {
	if stream_node_max_bytes != 0 && lp_total(node) + incoming >= stream_node_max_bytes {
		return false
	}
	if stream_node_max_entries == 0 {
		return true
	}
	h := node_header(node)
	return h.count + h.deleted < stream_node_max_entries
}

@(private)
seal_tail :: proc "contextless" (s: Stream, t: ^Tail) {
	t.node = lp_fit(s, t.node)
	rx.insert(s.nodes, t.key[:], t.node)
}

@(private)
open_node :: proc "contextless" (s: Stream, id: ID, fv: [][]u8) -> bool #no_bounds_check {
	first := plan_entry_layout(id, id, true, fv)
	size := HDR + master_bytes(fv) + first.bytes + 1
	if size > NODE_SIZE_CEILING {
		return false
	}
	reserve := NODE_RESERVE_CAP
	if stream_node_max_bytes > 0 {
		reserve = min(reserve, stream_node_max_bytes)
	}
	node := lp_alloc(s, max(size, reserve))
	end := HDR
	end += emit_master(&node[end], fv)
	end += emit_entry(&node[end], first, fv)
	node[end] = EOF
	lp_set_total(node, end + 1)
	node[4] = 0
	node[5] = 0
	lp_add_count(node, 4 + len(fv) / 2 + first.elements)
	key: [16]u8
	encode_id(&key, id)
	rx.insert(s.nodes, key[:], node)
	return true
}

@(private)
extend_node :: proc "contextless" (s: Stream, t: ^Tail, id: ID, fv: [][]u8) -> bool #no_bounds_check {
	h := node_header(t.node)
	plan := plan_entry_layout(id, decode_id(t.key[:]), fields_match(h.fields, h.nfields, fv), fv)
	used := lp_total(t.node)
	want := used + plan.bytes + NODE_GROW_SLACK
	if want > NODE_SIZE_CEILING {
		return false
	}
	if want > usable(t.node) {
		t.node = lp_grow(s, t.node, want)
		rx.insert(s.nodes, t.key[:], t.node)
	}
	end := used - 1
	end += emit_entry(&t.node[end], plan, fv)
	t.node[end] = EOF
	lp_set_total(t.node, end + 1)
	lp_add_count(t.node, plan.elements)
	held := t.node
	node_rewrite_int(s, &t.node, HDR, h.count + 1)
	if t.node != held {
		rx.insert(s.nodes, t.key[:], t.node)
	}
	return true
}

append_entry :: proc(s: Stream, fv: [][]u8, mode: Xadd_Id_Mode, want: ID, now_ms: u64) -> (ID, Append_Result) {
	if len(fv) < 2 {
		return {}, .Entry_Too_Large
	}
	id, fresh := pick_entry_id(s, mode, want, now_ms)
	if !fresh {
		return {}, .Id_Not_Greater
	}
	incoming := payload_bytes(fv)
	if incoming > NODE_SIZE_CEILING {
		return {}, .Entry_Too_Large
	}
	tail, has_tail := find_tail(s)
	if has_tail && !node_accepts(tail.node, incoming) {
		seal_tail(s, &tail)
		has_tail = false
	}
	stored := extend_node(s, &tail, id, fv) if has_tail else open_node(s, id, fv)
	if !stored {
		return {}, .Entry_Too_Large
	}
	s.live += 1
	s.added += 1
	s.top = id
	if s.live == 1 {
		s.head = id
	}
	return id, .Ok
}

Trim_Rule :: enum u8 {
	Off,
	Max_Len,
	Min_Id,
}

Trim_Spec :: struct {
	rule:    Trim_Rule,
	nearly:  bool,
	max_len: i64,
	min_id:  ID,
	limit:   i64,
}

Xadd_Spec :: struct {
	trim:       Trim_Spec,
	id_mode:    Xadd_Id_Mode,
	id:         ID,
	nomkstream: bool,
	fields_at:  int,
}

@(private)
node_remove :: proc "contextless" (s: Stream, key: []u8, p: [^]u8) {
	rx.remove(s.nodes, key)
	lp_release(s, p)
}

@(private)
node_counts_store :: proc "contextless" (s: Stream, node: ^[^]u8, count: i64, deleted: i64) {
	p := node^
	h := node_header(p)
	deleted_at := int(uintptr(h.deleted_ptr) - uintptr(p))
	node_rewrite_int(s, node, deleted_at, deleted)
	node_rewrite_int(s, node, HDR, count)
}

@(private)
Trim_Verdict :: enum u8 {
	Stop,
	Drop,
	Cut,
}

@(private)
trim_verdict :: proc "contextless" (s: Stream, spec: ^Trim_Spec, node: [^]u8, base: ID, h: Node_Header, evicted: i64) -> Trim_Verdict {
	by_length := spec.rule == .Max_Len
	if by_length && s.live <= u64(spec.max_len) {
		return .Stop
	}
	if spec.limit > 0 && evicted + h.count > spec.limit {
		return .Stop
	}
	if h.entries[0] == EOF {
		return .Drop
	}
	if by_length {
		if s.live - u64(h.count) >= u64(spec.max_len) {
			return .Drop
		}
	} else if compare_id(entry_id_at(entry_last(node), base), spec.min_id) < 0 {
		return .Drop
	}
	return .Stop if spec.nearly else .Cut
}

@(private)
trim_satisfied :: #force_inline proc "contextless" (s: Stream, spec: ^Trim_Spec, id: ID) -> bool {
	if spec.rule == .Max_Len {
		return s.live <= u64(spec.max_len)
	}
	return compare_id(id, spec.min_id) >= 0
}

@(private)
trim_inside :: proc "contextless" (s: Stream, spec: ^Trim_Spec, key: []u8, node: [^]u8, base: ID, h: Node_Header) -> i64 {
	remaining := h.count
	at := h.entries
	for at[0] != EOF {
		e := read_entry_head(at, base, h.nfields)
		if .Tombstone not_in e.marks {
			if trim_satisfied(s, spec, e.id) {
				break
			}
			mark_tombstone(at, e.marks)
			remaining -= 1
			s.live -= 1
		}
		at = entry_end(e)
	}
	cut := h.count - remaining
	if remaining == 0 {
		node_remove(s, key, node)
		return cut
	}
	moved := node
	node_counts_store(s, &moved, remaining, h.deleted + cut)
	if moved != node {
		rx.insert(s.nodes, key, moved)
	}
	return cut
}

trim :: proc(s: Stream, spec: ^Trim_Spec) -> i64 {
	if spec.rule == .Off || s.nodes.numele == 0 {
		return 0
	}
	if spec.rule == .Max_Len && spec.max_len < 0 {
		return 0
	}
	evicted: i64
	walk: rx.Iterator
	rx.start(&walk, s.nodes)
	rx.seek(&walk, "^")
	scan: for rx.next(&walk) {
		node := ([^]u8)(walk.data)
		key: [16]u8
		copy(key[:], rx.key(&walk))
		base := decode_id(key[:])
		h := node_header(node)
		switch trim_verdict(s, spec, node, base, h, evicted) {
		case .Stop:
			break scan
		case .Drop:
			s.live -= u64(h.count)
			evicted += h.count
			node_remove(s, key[:], node)
		case .Cut:
			evicted += trim_inside(s, spec, key[:], node, base, h)
			break scan
		}
	}
	rx.stop(&walk)
	if evicted > 0 {
		s.head = first_live_or_zero(s)
	}
	return evicted
}

Cursor :: struct {
	walk:       rx.Iterator,
	log:        Stream,
	lo:         ID,
	hi:         ID,
	held:       ID,
	base:       ID,
	node:       [^]u8,
	names:      [^]u8,
	name_at:    [^]u8,
	value_at:   [^]u8,
	width:      int,
	next_at:    int,
	held_at:    int,
	marks:      Entry_Marks,
	backward:   bool,
	tombstones: bool,
	finished:   bool,
	scratch:    [2][lp.LP_INTBUF_SIZE]u8,
}

cursor_open :: proc(c: ^Cursor, s: Stream, lo: ^ID, hi: ^ID, backward: bool) {
	c.log = s
	c.lo = lo^ if lo != nil else ID_MIN
	c.hi = hi^ if hi != nil else ID_MAX
	c.backward = backward
	c.tombstones = false
	c.node = nil
	c.next_at = 0
	c.held_at = 0
	c.finished = compare_id(c.lo, c.hi) > 0
	rx.start(&c.walk, s.nodes)
	if c.finished {
		return
	}
	anchor: [16]u8
	encode_id(&anchor, c.hi if backward else c.lo)
	rx.seek(&c.walk, "<=", anchor[:])
	if !backward && rx.eof(&c.walk) {
		rx.seek(&c.walk, "^")
	}
}

cursor_close :: #force_inline proc(c: ^Cursor) {
	rx.stop(&c.walk)
}

@(private)
cursor_offset :: #force_inline proc "contextless" (c: ^Cursor, p: [^]u8) -> int {
	return int(uintptr(p) - uintptr(c.node))
}

@(private)
cursor_enter :: proc(c: ^Cursor) -> bool {
	moved := rx.prev(&c.walk) if c.backward else rx.next(&c.walk)
	if !moved {
		return false
	}
	c.base = decode_id(rx.key(&c.walk))
	if !c.backward && compare_id(c.base, c.hi) > 0 {
		return false
	}
	c.node = ([^]u8)(c.walk.data)
	h := node_header(c.node)
	c.names = h.fields
	c.width = h.nfields
	c.next_at = 0
	if h.entries[0] != EOF {
		c.next_at = cursor_offset(c, entry_last(c.node) if c.backward else h.entries)
	}
	return true
}

@(private)
cursor_step :: proc "contextless" (c: ^Cursor, at: [^]u8, e: Entry_Head) -> int {
	if c.backward {
		prior := entry_before(at)
		return 0 if prior == nil else cursor_offset(c, prior)
	}
	after := entry_end(e)
	return 0 if after[0] == EOF else cursor_offset(c, after)
}

@(private)
cursor_passed :: #force_inline proc "contextless" (c: ^Cursor, id: ID) -> bool {
	if c.backward {
		return compare_id(id, c.lo) < 0
	}
	return compare_id(id, c.hi) > 0
}

@(private)
cursor_short :: #force_inline proc "contextless" (c: ^Cursor, id: ID) -> bool {
	if c.backward {
		return compare_id(id, c.hi) > 0
	}
	return compare_id(id, c.lo) < 0
}

cursor_next :: proc(c: ^Cursor) -> (id: ID, fields: i64, ok: bool) {
	for !c.finished {
		if c.next_at == 0 {
			c.finished = !cursor_enter(c)
			continue
		}
		at := ([^]u8)(&c.node[c.next_at])
		e := read_entry_head(at, c.base, c.width)
		c.next_at = cursor_step(c, at, e)
		if cursor_passed(c, e.id) {
			c.finished = true
			break
		}
		if cursor_short(c, e.id) || (.Tombstone in e.marks && !c.tombstones) {
			continue
		}
		c.held_at = cursor_offset(c, at)
		c.held = e.id
		c.marks = e.marks
		c.name_at = c.names
		c.value_at = e.body
		return e.id, i64(e.fields), true
	}
	c.held_at = 0
	return
}

@(private)
take_elem :: #force_inline proc "contextless" (p: ^[^]u8, buf: ^[lp.LP_INTBUF_SIZE]u8) -> []u8 {
	b := elem_bytes(p^, buf)
	p^ = elem_next(p^)
	return b
}

cursor_field :: proc(c: ^Cursor) -> (field: []u8, value: []u8) {
	source := &c.value_at
	if .Shared_Fields in c.marks {
		source = &c.name_at
	}
	field = take_elem(source, &c.scratch[0])
	value = take_elem(&c.value_at, &c.scratch[1])
	return
}

cursor_skip :: proc(c: ^Cursor, pairs: i64) {
	n := int(pairs)
	if .Shared_Fields in c.marks {
		c.name_at = elem_skip(c.name_at, n)
		c.value_at = elem_skip(c.value_at, n)
		return
	}
	c.value_at = elem_skip(c.value_at, 2 * n)
}

cursor_drop :: proc(c: ^Cursor) {
	if c.held_at == 0 || c.node == nil {
		return
	}
	at := ([^]u8)(&c.node[c.held_at])
	marks := marks_at(at)
	if .Tombstone in marks {
		return
	}
	s := c.log
	c.held_at = 0
	mark_tombstone(at, marks)
	s.live -= 1
	key: [16]u8
	encode_id(&key, c.base)
	h := node_header(c.node)
	if h.count == 1 {
		node_remove(s, key[:], c.node)
		c.node = nil
		c.next_at = 0
	} else {
		shift := cursor_offset(c, h.entries)
		node := c.node
		node_counts_store(s, &node, h.count - 1, h.deleted + 1)
		if node != c.node {
			rx.insert(s.nodes, key[:], node)
		}
		c.node = node
		fresh := node_header(node)
		c.names = fresh.fields
		if c.next_at != 0 {
			c.next_at += cursor_offset(c, fresh.entries) - shift
		}
	}
	if compare_id(c.held, s.head) == 0 {
		s.head = first_live_or_zero(s)
	}
}

@(private)
find_entry :: proc "contextless" (s: Stream, id: ID) -> (node: [^]u8, key: [16]u8, flags_ptr: [^]u8, found: bool) {
	if s.nodes == nil || s.nodes.numele == 0 {
		return
	}
	target: [16]u8
	encode_id(&target, id)
	it: rx.Iterator
	rx.start(&it, s.nodes)
	rx.seek(&it, "<=", target[:])
	if rx.next(&it) {
		node = ([^]u8)(it.data)
		copy(key[:], rx.key(&it))
	}
	rx.stop(&it)
	if node == nil {
		return
	}
	master := decode_id(key[:])
	h := node_header(node)
	e := h.entries
	for e[0] != EOF {
		c := compare_id(entry_id_at(e, master), id)
		if c == 0 {
			return node, key, e, true
		}
		if c > 0 {
			break
		}
		e = entry_skip(e, h.nfields)
	}
	return
}

entry_exists :: proc(s: Stream, id: ID) -> bool {
	_, _, flags_ptr, found := find_entry(s, id)
	if !found {
		return false
	}
	return .Tombstone not_in marks_at(flags_ptr)
}

delete_item :: proc(s: Stream, id: ID) -> bool {
	node, key, flags_ptr, found := find_entry(s, id)
	if !found {
		return false
	}
	marks := marks_at(flags_ptr)
	if .Tombstone in marks {
		return false
	}
	mark_tombstone(flags_ptr, marks)
	h := node_header(node)
	s.live -= 1
	if h.count - 1 == 0 {
		node_remove(s, key[:], node)
	} else {
		n := node
		node_counts_store(s, &n, h.count - 1, h.deleted + 1)
		if n != node {
			rx.insert(s.nodes, key[:], n)
		}
	}
	if compare_id(id, s.head) == 0 {
		s.head = first_live_or_zero(s)
	}
	return true
}

last_valid_id :: proc(s: Stream) -> (maxid: ID) {
	if s.live == 0 {
		return ID_MIN
	}
	return boundary_id(s, .Tail, false)
}

may_hold_tombstones :: proc "contextless" (s: Stream, lo: ^ID, hi: ^ID) -> bool {
	if s.live == 0 || id_is_zero(s.tomb) {
		return false
	}
	if lo != nil && compare_id(s.tomb, lo^) < 0 {
		return false
	}
	if hi != nil && compare_id(s.tomb, hi^) > 0 {
		return false
	}
	return true
}

range_count :: proc(s: Stream, start: ^ID, end: ^ID, count: int, rev: bool) -> int {
	c: Cursor
	cursor_open(&c, s, start, end, rev)
	defer cursor_close(&c)
	n := 0
	for _ in cursor_next(&c) {
		n += 1
		if count > 0 && n >= count {
			break
		}
	}
	return n
}

Node_Info :: struct {
	key: [16]u8,
	lp:  []u8,
}

node_listpacks :: proc(s: Stream, out: ^[dynamic]Node_Info) {
	it: rx.Iterator
	rx.start(&it, s.nodes)
	rx.seek(&it, "^")
	for rx.next(&it) {
		info: Node_Info
		copy(info.key[:], rx.key(&it))
		p := ([^]u8)(it.data)
		info.lp = p[:lp_total(p)]
		append(out, info)
	}
	rx.stop(&it)
}

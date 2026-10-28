package streamtype

import lp "../listpack"
import rx "../rax"
import "base:intrinsics"
import "base:runtime"

foreign import libc "system:c"

foreign libc {
	@(link_name = "malloc_usable_size")
	libc_usable_size :: proc "c" (ptr: rawptr) -> uint ---
}

ITEM_FLAG_NONE :: 0
ITEM_FLAG_DELETED :: 1 << 0
ITEM_FLAG_SAMEFIELDS :: 1 << 1
LISTPACK_MAX_PRE_ALLOCATE :: 4096
LISTPACK_MAX_SIZE :: 1 << 30
NODE_MAX_BYTES_DEFAULT :: 4096
NODE_MAX_ENTRIES_DEFAULT :: 100
ID_STR_LEN :: 44
BATCH_MAX :: 64

stream_node_max_bytes: int = NODE_MAX_BYTES_DEFAULT
stream_node_max_entries: i64 = NODE_MAX_ENTRIES_DEFAULT

ID :: struct {
	ms:  u64,
	seq: u64,
}

ID_MIN :: ID{0, 0}
ID_MAX :: ID{max(u64), max(u64)}

Stream_Object :: struct {
	rax:                  ^rx.Rax,
	length:               u64,
	last_id:              ID,
	first_id:             ID,
	max_deleted_entry_id: ID,
	entries_added:        u64,
	cgroups:              ^rx.Rax,
	lp_mem:               int,
	cg_mem:               int,
	acct:                 int,
}

Stream :: ^Stream_Object

Append_Result :: enum u8 {
	Ok,
	Edom,
	Erange,
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

format_id :: proc "contextless" (buf: ^[ID_STR_LEN]u8, id: ID) -> []u8 {
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

@(private)
parse_int_text :: proc "contextless" (s: []u8) -> (i64, bool) #no_bounds_check {
	if len(s) == 0 || len(s) > 20 {
		return 0, false
	}
	if len(s) == 1 && s[0] == '0' {
		return 0, true
	}
	neg := s[0] == '-'
	i := neg ? 1 : 0
	if i >= len(s) || s[i] < '1' || s[i] > '9' {
		return 0, false
	}
	limit: u64 = neg ? u64(1) << 63 : u64(max(i64))
	acc: u64
	for ; i < len(s); i += 1 {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		d := u64(c - '0')
		if acc > (limit - d) / 10 {
			return 0, false
		}
		acc = acc * 10 + d
	}
	if neg {
		return i64(-i128(acc)), true
	}
	return i64(acc), true
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
		v, _ := parse_int_text(p[1:1 + int(tag & 0x3F)])
		return v
	case tag < 0xE0:
		v := i64(u16(tag & 0x1F) << 8 | u16(p[1]))
		return v >= 4096 ? v - 8192 : v
	case tag < 0xF0:
		n := int(tag & 0x0F) << 8 | int(p[1])
		v, _ := parse_int_text(p[2:2 + n])
		return v
	case tag == 0xF0:
		n := int(read_le(&p[1], 4))
		v, _ := parse_int_text(p[5:5 + n])
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
	s.lp_mem += usable(p)
	return ([^]u8)(p)
}

@(private)
lp_grow :: proc "contextless" (s: Stream, p: [^]u8, need: int) -> [^]u8 {
	old := usable(p)
	grown := max(need, old + old / 2)
	if grown > LISTPACK_MAX_SIZE + 64 {
		grown = need
	}
	q := runtime.heap_resize(p, grown)
	if q == nil {
		out_of_memory()
	}
	s.lp_mem += usable(q) - old
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
	s.lp_mem += usable(q) - old
	return ([^]u8)(q)
}

@(private)
lp_release :: proc "contextless" (s: Stream, p: [^]u8) {
	s.lp_mem -= usable(p)
	runtime.heap_free(p)
}

@(private)
free_lp :: proc "contextless" (p: rawptr) {
	runtime.heap_free(p)
}

create :: proc "contextless" () -> Stream {
	p := runtime.heap_alloc(size_of(Stream_Object), true)
	if p == nil {
		out_of_memory()
	}
	s := Stream(p)
	s.rax = rx.create(&s.lp_mem)
	return s
}

destroy :: proc "contextless" (s: Stream) {
	if s == nil {
		return
	}
	if s.rax != nil {
		rx.destroy(s.rax, free_lp)
		s.rax = nil
	}
	free_groups(s)
	runtime.heap_free(s)
}

memory_usage :: proc "contextless" (s: Stream) -> int {
	if s == nil {
		return 0
	}
	return usable(s) + s.lp_mem + s.cg_mem
}

length :: #force_inline proc "contextless" (s: Stream) -> u64 {
	if s == nil {
		return 0
	}
	return s.length
}

node_count :: #force_inline proc "contextless" (s: Stream) -> u64 {
	if s == nil || s.rax == nil {
		return 0
	}
	return s.rax.numele
}

rax_nodes :: #force_inline proc "contextless" (s: Stream) -> u64 {
	if s == nil || s.rax == nil {
		return 1
	}
	return radix_shape(s.rax)
}

group_count :: #force_inline proc "contextless" (s: Stream) -> u64 {
	if s == nil || s.cgroups == nil {
		return 0
	}
	return s.cgroups.numele
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
	rx.start(&it, s.rax)
	rx.seek(&it, "^")
	for rx.next(&it) {
		src := ([^]u8)(it.data)
		size := lp_total(src)
		q := lp_alloc(d, size)
		intrinsics.mem_copy_non_overlapping(q, src, size)
		rx.insert(d.rax, rx.key(&it), q)
	}
	rx.stop(&it)
	d.length = s.length
	d.last_id = s.last_id
	d.first_id = s.first_id
	d.max_deleted_entry_id = s.max_deleted_entry_id
	d.entries_added = s.entries_added
	dup_groups(s, d)
	return d
}

@(private)
entry_skip :: proc "contextless" (flags_ptr: [^]u8, nfields: int) -> [^]u8 {
	flags := elem_int(flags_ptr)
	p := elem_next(flags_ptr)
	p = elem_next(p)
	p = elem_next(p)
	if flags & ITEM_FLAG_SAMEFIELDS != 0 {
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

lp_get_edge_stream_id :: proc(p: [^]u8, first: bool, master_id: ID) -> (edge: ID, ok: bool) {
	if p == nil {
		return
	}
	h := node_header(p)
	if h.entries[0] == EOF {
		return
	}
	if first {
		return entry_id_at(h.entries, master_id), true
	}
	return entry_id_at(entry_last(p), master_id), true
}

get_edge_id :: proc(s: Stream, first: bool, skip_tombstones: bool) -> ID {
	si: Iterator
	iterator_start(&si, s, nil, nil, !first)
	si.skip_tombstones = skip_tombstones
	id: ID
	numfields: i64
	found := iterator_get_id(&si, &id, &numfields)
	iterator_stop(&si)
	if !found {
		return first ? ID_MAX : ID_MIN
	}
	return id
}

@(private)
first_live_or_zero :: proc(s: Stream) -> ID {
	if s.length == 0 {
		return ID_MIN
	}
	return get_edge_id(s, true, true)
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
new_node_size :: proc "contextless" (fv: [][]u8) -> (size: int, elems: int) #no_bounds_check {
	nfields := len(fv) / 2
	size = int_size(1) + int_size(0) + int_size(i64(nfields))
	for i in 0 ..< nfields {
		size += str_size(fv[2 * i])
	}
	size += int_size(0)
	size += int_size(ITEM_FLAG_SAMEFIELDS) + int_size(0) + int_size(0)
	for i in 0 ..< nfields {
		size += str_size(fv[2 * i + 1])
	}
	size += int_size(i64(3 + nfields))
	elems = 2 * nfields + 8
	return
}

@(private)
write_new_node :: proc "contextless" (dst: [^]u8, fv: [][]u8, size: int, elems: int) #no_bounds_check {
	nfields := len(fv) / 2
	total := HDR + size + 1
	lp_set_total(dst, total)
	dst[4] = 0
	dst[5] = 0
	lp_add_count(dst, elems)
	o := HDR
	o += put_int(&dst[o], 1)
	o += put_int(&dst[o], 0)
	o += put_int(&dst[o], i64(nfields))
	for i in 0 ..< nfields {
		o += put_str(&dst[o], fv[2 * i])
	}
	o += put_int(&dst[o], 0)
	o += put_int(&dst[o], ITEM_FLAG_SAMEFIELDS)
	o += put_int(&dst[o], 0)
	o += put_int(&dst[o], 0)
	for i in 0 ..< nfields {
		o += put_str(&dst[o], fv[2 * i + 1])
	}
	o += put_int(&dst[o], i64(3 + nfields))
	dst[o] = EOF
}

append_item :: proc(s: Stream, fv: [][]u8, use_id: ^ID, seq_given: bool, now_ms: u64) -> (added: ID, res: Append_Result) #no_bounds_check {
	nfields := len(fv) / 2
	if nfields == 0 {
		return {}, .Erange
	}
	id: ID
	if use_id == nil {
		id = next_id(s.last_id, now_ms)
	} else if !seq_given {
		if use_id.ms == s.last_id.ms {
			if s.last_id.seq == max(u64) {
				return {}, .Edom
			}
			id = ID{use_id.ms, s.last_id.seq + 1}
		} else {
			id = ID{use_id.ms, 0}
		}
	} else {
		id = use_id^
	}
	if compare_id(id, s.last_id) <= 0 {
		return {}, .Edom
	}
	raw := 0
	for a in fv {
		raw += len(a)
	}
	if raw > LISTPACK_MAX_SIZE {
		return {}, .Erange
	}
	tail: [^]u8
	tail_key: [16]u8
	{
		it: rx.Iterator
		rx.start(&it, s.rax)
		rx.seek(&it, "$")
		if rx.next(&it) {
			tail = ([^]u8)(it.data)
			copy(tail_key[:], rx.key(&it))
		}
		rx.stop(&it)
	}
	if tail != nil {
		h := node_header(tail)
		cur := lp_total(tail)
		if stream_node_max_bytes != 0 && cur + raw >= stream_node_max_bytes {
			tail = lp_fit(s, tail)
			rx.insert(s.rax, tail_key[:], tail)
			tail = nil
		} else if stream_node_max_entries != 0 && h.count + h.deleted >= stream_node_max_entries {
			tail = lp_fit(s, tail)
			rx.insert(s.rax, tail_key[:], tail)
			tail = nil
		}
	}
	if tail == nil {
		size, elems := new_node_size(fv)
		total := HDR + size + 1
		if total > LISTPACK_MAX_SIZE {
			return {}, .Erange
		}
		reserve := total
		pre := LISTPACK_MAX_PRE_ALLOCATE
		if stream_node_max_bytes > 0 && stream_node_max_bytes < pre {
			pre = stream_node_max_bytes
		}
		if reserve < pre {
			reserve = pre
		}
		node := lp_alloc(s, reserve)
		write_new_node(node, fv, size, elems)
		key: [16]u8
		encode_id(&key, id)
		rx.insert(s.rax, key[:], node)
	} else {
		h := node_header(tail)
		master := decode_id(tail_key[:])
		same := fields_match(h.fields, h.nfields, fv)
		msd := i64(id.ms - master.ms)
		seqd := i64(id.seq - master.seq)
		esize := int_size(same ? ITEM_FLAG_SAMEFIELDS : ITEM_FLAG_NONE) + int_size(msd) + int_size(seqd)
		elems := 3
		lpcount: i64
		if same {
			for i in 0 ..< nfields {
				esize += str_size(fv[2 * i + 1])
			}
			lpcount = i64(3 + nfields)
			elems += nfields
		} else {
			esize += int_size(i64(nfields))
			for a in fv {
				esize += str_size(a)
			}
			lpcount = i64(4 + 2 * nfields)
			elems += 1 + 2 * nfields
		}
		esize += int_size(lpcount)
		elems += 1
		total := lp_total(tail)
		if total + esize + 16 > LISTPACK_MAX_SIZE {
			return {}, .Erange
		}
		need := total + esize + 16
		if need > usable(tail) {
			tail = lp_grow(s, tail, need)
			rx.insert(s.rax, tail_key[:], tail)
		}
		o := total - 1
		o += put_int(&tail[o], same ? ITEM_FLAG_SAMEFIELDS : ITEM_FLAG_NONE)
		o += put_int(&tail[o], msd)
		o += put_int(&tail[o], seqd)
		if same {
			for i in 0 ..< nfields {
				o += put_str(&tail[o], fv[2 * i + 1])
			}
		} else {
			o += put_int(&tail[o], i64(nfields))
			for a in fv {
				o += put_str(&tail[o], a)
			}
		}
		o += put_int(&tail[o], lpcount)
		tail[o] = EOF
		lp_set_total(tail, o + 1)
		lp_add_count(tail, elems)
		before := tail
		node_rewrite_int(s, &tail, HDR, h.count + 1)
		if tail != before {
			rx.insert(s.rax, tail_key[:], tail)
		}
	}
	s.length += 1
	s.entries_added += 1
	s.last_id = id
	if s.length == 1 {
		s.first_id = id
	}
	return id, .Ok
}

Trim_Strategy :: enum u8 {
	None,
	Maxlen,
	Minid,
}

Add_Trim_Args :: struct {
	id:                    ID,
	id_given:              bool,
	seq_given:             bool,
	no_mkstream:           bool,
	trim_strategy:         Trim_Strategy,
	trim_strategy_arg_idx: int,
	approx_trim:           bool,
	limit:                 i64,
	maxlen:                i64,
	minid:                 ID,
}

@(private)
node_remove :: proc "contextless" (s: Stream, key: []u8, p: [^]u8) {
	rx.remove(s.rax, key)
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

trim :: proc(s: Stream, args: ^Add_Trim_Args) -> i64 #no_bounds_check {
	if args.trim_strategy == .None || s.rax.numele == 0 {
		return 0
	}
	maxlen := args.trim_strategy == .Maxlen
	if maxlen && args.maxlen < 0 {
		return 0
	}
	removed: i64
	limit := args.limit
	it: rx.Iterator
	rx.start(&it, s.rax)
	rx.seek(&it, "^")
	for rx.next(&it) {
		if maxlen && s.length <= u64(args.maxlen) {
			break
		}
		node := ([^]u8)(it.data)
		key: [16]u8
		copy(key[:], rx.key(&it))
		h := node_header(node)
		if limit > 0 && removed + h.count > limit {
			break
		}
		master := decode_id(key[:])
		whole := false
		if h.entries[0] == EOF {
			whole = true
		} else if maxlen {
			whole = s.length - u64(h.count) >= u64(args.maxlen)
		} else {
			last := entry_id_at(entry_last(node), master)
			whole = compare_id(last, args.minid) < 0
		}
		if whole {
			s.length -= u64(h.count)
			removed += h.count
			node_remove(s, key[:], node)
			continue
		}
		if args.approx_trim {
			break
		}
		count := h.count
		deleted := h.deleted
		e := h.entries
		for e[0] != EOF {
			flags := elem_int(e)
			next := entry_skip(e, h.nfields)
			if flags & ITEM_FLAG_DELETED == 0 {
				if maxlen {
					if s.length <= u64(args.maxlen) {
						break
					}
				} else {
					if compare_id(entry_id_at(e, master), args.minid) >= 0 {
						break
					}
				}
				e[0] = u8(flags | ITEM_FLAG_DELETED)
				count -= 1
				deleted += 1
				s.length -= 1
				removed += 1
			}
			e = next
		}
		if count == 0 {
			node_remove(s, key[:], node)
		} else {
			before := node
			node_counts_store(s, &node, count, deleted)
			if node != before {
				rx.insert(s.rax, key[:], node)
			}
		}
		break
	}
	rx.stop(&it)
	if removed > 0 {
		s.first_id = first_live_or_zero(s)
	}
	return removed
}

Iterator :: struct {
	stream:              Stream,
	master_id:           ID,
	master_fields_count: u64,
	master_fields_start: [^]u8,
	master_fields_ptr:   [^]u8,
	entry_flags:         i64,
	rev:                 bool,
	skip_tombstones:     bool,
	start_id:            ID,
	end_id:              ID,
	ri:                  rx.Iterator,
	cur_lp:              [^]u8,
	lp_ele:              [^]u8,
	lp_flags:            [^]u8,
	field_buf:           [lp.LP_INTBUF_SIZE]u8,
	value_buf:           [lp.LP_INTBUF_SIZE]u8,
}

@(private)
ITER_DONE :: -1

iterator_start :: proc(si: ^Iterator, s: Stream, start: ^ID, end: ^ID, rev: bool) {
	si.stream = s
	si.start_id = start != nil ? start^ : ID_MIN
	si.end_id = end != nil ? end^ : ID_MAX
	si.rev = rev
	si.skip_tombstones = true
	si.cur_lp = nil
	si.lp_ele = nil
	si.lp_flags = nil
	si.master_fields_ptr = nil
	si.master_fields_start = nil
	si.master_fields_count = 0
	si.entry_flags = 0
	rx.start(&si.ri, s.rax)
	key: [16]u8
	if !rev {
		encode_id(&key, si.start_id)
		rx.seek(&si.ri, "<=", key[:])
		if rx.eof(&si.ri) {
			rx.seek(&si.ri, "^")
		}
	} else {
		encode_id(&key, si.end_id)
		rx.seek(&si.ri, "<=", key[:])
	}
	if compare_id(si.start_id, si.end_id) > 0 {
		si.entry_flags = ITER_DONE
	}
}

@(private)
iterator_load_node :: proc(si: ^Iterator) -> bool {
	more := si.rev ? rx.prev(&si.ri) : rx.next(&si.ri)
	if !more {
		return false
	}
	node := ([^]u8)(si.ri.data)
	si.master_id = decode_id(rx.key(&si.ri))
	if !si.rev && compare_id(si.master_id, si.end_id) > 0 {
		return false
	}
	h := node_header(node)
	si.cur_lp = node
	si.master_fields_count = u64(h.nfields)
	si.master_fields_start = h.fields
	si.lp_flags = nil
	if h.entries[0] == EOF {
		si.lp_ele = nil
		return true
	}
	if si.rev {
		si.lp_ele = entry_last(node)
	} else {
		si.lp_ele = h.entries
	}
	return true
}

iterator_get_id :: proc(si: ^Iterator, id: ^ID, numfields: ^i64) -> bool #no_bounds_check {
	if si.entry_flags == ITER_DONE {
		return false
	}
	if si.lp_flags != nil {
		cur := si.lp_flags
		si.lp_flags = nil
		si.lp_ele = entry_after(cur, si.rev, int(si.master_fields_count))
		if si.lp_ele == nil {
			si.cur_lp = nil
		}
	}
	for {
		if si.cur_lp == nil || si.lp_ele == nil {
			si.cur_lp = nil
			if !iterator_load_node(si) {
				si.entry_flags = ITER_DONE
				return false
			}
			if si.lp_ele == nil {
				si.cur_lp = nil
				continue
			}
		}
		e := si.lp_ele
		flags := elem_int(e)
		p := elem_next(e)
		ms := u64(elem_int(p))
		p = elem_next(p)
		seq := u64(elem_int(p))
		p = elem_next(p)
		cur := ID{si.master_id.ms + ms, si.master_id.seq + seq}
		nf: i64
		if flags & ITEM_FLAG_SAMEFIELDS != 0 {
			nf = i64(si.master_fields_count)
		} else {
			nf = elem_int(p)
			p = elem_next(p)
		}
		if !si.rev {
			if compare_id(cur, si.end_id) > 0 {
				si.entry_flags = ITER_DONE
				return false
			}
		} else {
			if compare_id(cur, si.start_id) < 0 {
				si.entry_flags = ITER_DONE
				return false
			}
		}
		in_range := si.rev ? compare_id(cur, si.end_id) <= 0 : compare_id(cur, si.start_id) >= 0
		if in_range && (flags & ITEM_FLAG_DELETED == 0 || !si.skip_tombstones) {
			si.lp_flags = e
			si.lp_ele = p
			si.entry_flags = flags
			si.master_fields_ptr = si.master_fields_start
			id^ = cur
			numfields^ = nf
			return true
		}
		si.lp_ele = entry_after(e, si.rev, int(si.master_fields_count))
	}
}

@(private)
entry_after :: #force_inline proc "contextless" (e: [^]u8, rev: bool, nfields: int) -> [^]u8 {
	if rev {
		return entry_before(e)
	}
	nx := entry_skip(e, nfields)
	if nx[0] == EOF {
		return nil
	}
	return nx
}

iterator_get_field :: proc(si: ^Iterator) -> (field: []u8, value: []u8) {
	if si.entry_flags & ITEM_FLAG_SAMEFIELDS != 0 {
		field = elem_bytes(si.master_fields_ptr, &si.field_buf)
		si.master_fields_ptr = elem_next(si.master_fields_ptr)
	} else {
		field = elem_bytes(si.lp_ele, &si.field_buf)
		si.lp_ele = elem_next(si.lp_ele)
	}
	value = elem_bytes(si.lp_ele, &si.value_buf)
	si.lp_ele = elem_next(si.lp_ele)
	return
}

iterator_skip_fields :: proc(si: ^Iterator, numfields: i64) {
	n := int(numfields)
	if si.entry_flags & ITEM_FLAG_SAMEFIELDS != 0 {
		si.lp_ele = elem_skip(si.lp_ele, n)
		si.master_fields_ptr = elem_skip(si.master_fields_ptr, n)
	} else {
		si.lp_ele = elem_skip(si.lp_ele, 2 * n)
	}
}

iterator_remove_entry :: proc(si: ^Iterator, current: ^ID) {
	s := si.stream
	if si.lp_flags == nil || si.cur_lp == nil {
		return
	}
	node := si.cur_lp
	flags := elem_int(si.lp_flags)
	if flags & ITEM_FLAG_DELETED != 0 {
		return
	}
	key: [16]u8
	encode_id(&key, si.master_id)
	h := node_header(node)
	si.lp_flags[0] = u8(flags | ITEM_FLAG_DELETED)
	si.lp_flags = nil
	s.length -= 1
	if h.count == 1 {
		node_remove(s, key[:], node)
		si.cur_lp = nil
		si.lp_ele = nil
	} else {
		before := node
		node_counts_store(s, &node, h.count - 1, h.deleted + 1)
		if node != before {
			rx.insert(s.rax, key[:], node)
		}
		si.cur_lp = node
		nh := node_header(node)
		if si.rev {
			si.lp_ele = locate_entry_rev(node, nh, si.master_id, current^)
		} else {
			si.lp_ele = locate_entry_fwd(node, nh, si.master_id, current^)
		}
		if si.lp_ele == nil {
			si.cur_lp = nil
		}
	}
	if compare_id(current^, s.first_id) == 0 {
		s.first_id = first_live_or_zero(s)
	}
}

@(private)
locate_entry_fwd :: proc "contextless" (node: [^]u8, h: Node_Header, master: ID, after: ID) -> [^]u8 {
	e := h.entries
	for e[0] != EOF {
		if compare_id(entry_id_at(e, master), after) > 0 {
			return e
		}
		e = entry_skip(e, h.nfields)
	}
	return nil
}

@(private)
locate_entry_rev :: proc "contextless" (node: [^]u8, h: Node_Header, master: ID, before: ID) -> [^]u8 {
	if h.entries[0] == EOF {
		return nil
	}
	e := entry_last(node)
	for e != nil {
		if compare_id(entry_id_at(e, master), before) < 0 {
			return e
		}
		e = entry_before(e)
	}
	return nil
}

iterator_stop :: #force_inline proc(si: ^Iterator) {
	rx.stop(&si.ri)
}

@(private)
find_entry :: proc "contextless" (s: Stream, id: ID) -> (node: [^]u8, key: [16]u8, flags_ptr: [^]u8, found: bool) {
	if s.rax == nil || s.rax.numele == 0 {
		return
	}
	target: [16]u8
	encode_id(&target, id)
	it: rx.Iterator
	rx.start(&it, s.rax)
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
	return elem_int(flags_ptr) & ITEM_FLAG_DELETED == 0
}

delete_item :: proc(s: Stream, id: ID) -> bool {
	node, key, flags_ptr, found := find_entry(s, id)
	if !found {
		return false
	}
	flags := elem_int(flags_ptr)
	if flags & ITEM_FLAG_DELETED != 0 {
		return false
	}
	flags_ptr[0] = u8(flags | ITEM_FLAG_DELETED)
	h := node_header(node)
	s.length -= 1
	if h.count - 1 == 0 {
		node_remove(s, key[:], node)
	} else {
		n := node
		node_counts_store(s, &n, h.count - 1, h.deleted + 1)
		if n != node {
			rx.insert(s.rax, key[:], n)
		}
	}
	if compare_id(id, s.first_id) == 0 {
		s.first_id = first_live_or_zero(s)
	}
	return true
}

last_valid_id :: proc(s: Stream) -> (maxid: ID) {
	if s.length == 0 {
		return ID_MIN
	}
	return get_edge_id(s, false, true)
}

range_has_tombstones :: proc "contextless" (s: Stream, start: ^ID, end: ^ID) -> bool {
	if s.length == 0 || id_is_zero(s.max_deleted_entry_id) {
		return false
	}
	lo := start != nil ? start^ : ID_MIN
	hi := end != nil ? end^ : ID_MAX
	return compare_id(lo, s.max_deleted_entry_id) <= 0 && compare_id(s.max_deleted_entry_id, hi) <= 0
}

range_count :: proc(s: Stream, start: ^ID, end: ^ID, count: int, rev: bool) -> int {
	si: Iterator
	iterator_start(&si, s, start, end, rev)
	n := 0
	id: ID
	numfields: i64
	for iterator_get_id(&si, &id, &numfields) {
		n += 1
		if count > 0 && n >= count {
			break
		}
	}
	iterator_stop(&si)
	return n
}

Node_Info :: struct {
	key: [16]u8,
	lp:  []u8,
}

node_listpacks :: proc(s: Stream, out: ^[dynamic]Node_Info) {
	it: rx.Iterator
	rx.start(&it, s.rax)
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

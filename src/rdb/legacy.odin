package rdb

import "base:intrinsics"
import "base:runtime"
import lp "../listpack"

ZIPLIST_HEADER_SIZE :: 10

ZIPLIST_END :: 0xFF

ZIPMAP_BIGLEN :: 254

ZIPMAP_END :: 255

Zl_Entry :: struct {
	str:    []u8,
	ival:   i64,
	is_int: bool,
}

@(private)
le32 :: #force_inline proc "contextless" (p: [^]u8) -> u32 {
	return u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24
}

@(private)
le16 :: #force_inline proc "contextless" (p: [^]u8) -> u16 {
	return u16(p[0]) | u16(p[1]) << 8
}

Ziplist_Iter :: struct {
	zl:       []u8,
	p:        int,
	prev:     int,
	prev_raw: int,
	count:    u32,
	header:   u32,
	failed:   bool,
	done:     bool,
}

ziplist_check_header :: proc "contextless" (zl: []u8) -> bool {
	n := len(zl)
	if n < ZIPLIST_HEADER_SIZE + 1 {
		return false
	}
	p := raw_data(zl)
	if int(le32(p)) != n {
		return false
	}
	tail := int(le32(p[4:]))
	if tail < ZIPLIST_HEADER_SIZE || tail > n - 1 {
		return false
	}
	return zl[n - 1] == ZIPLIST_END
}

ziplist_iter :: proc "contextless" (zl: []u8) -> (it: Ziplist_Iter) {
	it.zl = zl
	it.p = ZIPLIST_HEADER_SIZE
	it.prev = -1
	if len(zl) < ZIPLIST_HEADER_SIZE + 1 {
		it.failed = true
		it.done = true
		return
	}
	it.header = u32(le16(raw_data(zl)[8:]))
	return
}

@(private)
ziplist_finish :: proc "contextless" (it: ^Ziplist_Iter) {
	it.done = true
	n := len(it.zl)
	if it.p != n - 1 {
		it.failed = true
		return
	}
	if it.header != 0xFFFF && it.count != it.header {
		it.failed = true
		return
	}
	tail := int(le32(raw_data(it.zl)[4:]))
	expected := ZIPLIST_HEADER_SIZE if it.count == 0 else it.prev
	if tail != expected {
		it.failed = true
	}
}

ziplist_next :: proc "contextless" (it: ^Ziplist_Iter, out: ^Zl_Entry) -> bool #no_bounds_check {
	if it.done || it.failed {
		return false
	}
	zl := it.zl
	limit := len(zl) - 1
	p := it.p
	if p > limit {
		it.failed = true
		return false
	}
	if zl[p] == ZIPLIST_END {
		ziplist_finish(it)
		return false
	}
	start := p
	prevlen := 0
	if zl[p] < 254 {
		prevlen = int(zl[p])
		p += 1
	} else {
		if p + 5 > limit {
			it.failed = true
			return false
		}
		prevlen = int(le32(raw_data(zl)[p + 1:]))
		p += 5
	}
	if prevlen != it.prev_raw || p >= limit {
		it.failed = true
		return false
	}
	enc := zl[p]
	str_len := -1
	switch enc >> 6 {
	case 0:
		str_len = int(enc & 63)
		p += 1
	case 1:
		if p + 2 > limit {
			it.failed = true
			return false
		}
		str_len = int(enc & 63) << 8 | int(zl[p + 1])
		p += 2
	case 2:
		if enc != 0x80 || p + 5 > limit {
			it.failed = true
			return false
		}
		str_len = int(zl[p + 1]) << 24 | int(zl[p + 2]) << 16 | int(zl[p + 3]) << 8 | int(zl[p + 4])
		p += 5
	case:
		width := 0
		value: i64 = 0
		switch enc {
		case 0xC0:
			width = 2
		case 0xD0:
			width = 4
		case 0xE0:
			width = 8
		case 0xF0:
			width = 3
		case 0xFE:
			width = 1
		case 0xF1 ..= 0xFD:
			value = i64(enc & 0x0F) - 1
		case:
			it.failed = true
			return false
		}
		p += 1
		if p + width > limit {
			it.failed = true
			return false
		}
		if width > 0 {
			raw: u64 = 0
			for i in 0 ..< width {
				raw |= u64(zl[p + i]) << (8 * uint(i))
			}
			shift := uint(64 - 8 * width)
			value = i64(raw << shift) >> shift
			p += width
		}
		out.str = nil
		out.ival = value
		out.is_int = true
	}
	if str_len >= 0 {
		if str_len > limit - p {
			it.failed = true
			return false
		}
		out.str = zl[p:p + str_len]
		out.ival = 0
		out.is_int = false
		p += str_len
	}
	it.prev_raw = p - start
	it.prev = start
	it.p = p
	it.count += 1
	return true
}

zl_entry_bytes :: proc "contextless" (e: ^Zl_Entry, buf: ^[24]u8) -> []u8 {
	if e.is_int {
		n := ll2string(buf[:], e.ival)
		return buf[:n]
	}
	return e.str
}

lp_append_zl :: proc(zl: [^]u8, e: ^Zl_Entry) -> [^]u8 {
	if e.is_int {
		return lp.lp_append_integer(zl, e.ival)
	}
	return lp.lp_append(zl, e.str)
}

Zipmap_Iter :: struct {
	zm: []u8,
	p:  int,
}

@(private)
zipmap_len :: proc "contextless" (zm: []u8, p: ^int) -> (int, bool) {
	at := p^
	if at >= len(zm) {
		return 0, false
	}
	first := zm[at]
	if first < ZIPMAP_BIGLEN {
		p^ = at + 1
		return int(first), true
	}
	if first != ZIPMAP_BIGLEN || at + 5 > len(zm) {
		return 0, false
	}
	value := int(le32(raw_data(zm)[at + 1:]))
	if value < ZIPMAP_BIGLEN {
		return 0, false
	}
	p^ = at + 5
	return value, true
}

zipmap_validate :: proc "contextless" (zm: []u8) -> bool {
	n := len(zm)
	if n < 2 || zm[n - 1] != ZIPMAP_END {
		return false
	}
	declared := int(zm[0])
	p := 1
	count := 0
	for {
		if p >= n {
			return false
		}
		if zm[p] == ZIPMAP_END {
			break
		}
		klen, kok := zipmap_len(zm, &p)
		if !kok || klen > n - p {
			return false
		}
		p += klen
		vlen, vok := zipmap_len(zm, &p)
		if !vok || p >= n {
			return false
		}
		free := int(zm[p])
		p += 1
		if vlen > n - p || free > n - p - vlen {
			return false
		}
		p += vlen + free
		count += 1
	}
	if p != n - 1 {
		return false
	}
	if declared < ZIPMAP_BIGLEN && declared != count {
		return false
	}
	return true
}

zipmap_next :: proc "contextless" (it: ^Zipmap_Iter, key: ^[]u8, val: ^[]u8) -> bool {
	zm := it.zm
	n := len(zm)
	p := it.p
	if p >= n || zm[p] == ZIPMAP_END {
		return false
	}
	klen, kok := zipmap_len(zm, &p)
	if !kok || klen > n - p {
		return false
	}
	key^ = zm[p:p + klen]
	p += klen
	vlen, vok := zipmap_len(zm, &p)
	if !vok || p >= n {
		return false
	}
	free := int(zm[p])
	p += 1
	if vlen > n - p || free > n - p - vlen {
		return false
	}
	val^ = zm[p:p + vlen]
	p += vlen + free
	it.p = p
	return true
}

Dup_Set :: struct {
	slots: [^]Dup_Slot,
	cap:   int,
	count: int,
	arena: [^]u8,
	used:  int,
	size:  int,
}

Dup_Slot :: struct {
	hash: u64,
	off:  int,
	len:  int,
}

@(private)
dup_hash :: proc "contextless" (s: []u8) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for c in s {
		h ~= u64(c)
		h *= 0x100000001b3
	}
	h ~= h >> 33
	h *= 0xff51afd7ed558ccd
	h ~= h >> 33
	return h | 1
}

dup_destroy :: proc "contextless" (d: ^Dup_Set) {
	if d.slots != nil {
		runtime.heap_free(d.slots)
	}
	if d.arena != nil {
		runtime.heap_free(d.arena)
	}
	d^ = {}
}

@(private)
dup_place :: proc "contextless" (slots: [^]Dup_Slot, cap: int, s: Dup_Slot) {
	mask := u64(cap - 1)
	i := s.hash & mask
	for slots[i].hash != 0 {
		i = (i + 1) & mask
	}
	slots[i] = s
}

dup_add :: proc "contextless" (d: ^Dup_Set, s: []u8) -> bool {
	if (d.count + 1) * 2 > d.cap {
		new_cap := max(d.cap * 2, 64)
		fresh := ([^]Dup_Slot)(runtime.heap_alloc(new_cap * size_of(Dup_Slot), true))
		if fresh == nil {
			runtime.panic_contextless("rdb: out of memory")
		}
		for i in 0 ..< d.cap {
			if d.slots[i].hash != 0 {
				dup_place(fresh, new_cap, d.slots[i])
			}
		}
		if d.slots != nil {
			runtime.heap_free(d.slots)
		}
		d.slots = fresh
		d.cap = new_cap
	}
	h := dup_hash(s)
	mask := u64(d.cap - 1)
	i := h & mask
	for d.slots[i].hash != 0 {
		slot := d.slots[i]
		if slot.hash == h && slot.len == len(s) {
			if slot.len == 0 || runtime.memory_compare(&d.arena[slot.off], raw_data(s), slot.len) == 0 {
				return false
			}
		}
		i = (i + 1) & mask
	}
	if d.used + len(s) > d.size {
		new_size := max(d.size * 2, d.used + len(s), 256)
		grown := ([^]u8)(runtime.heap_resize(d.arena, new_size))
		if grown == nil {
			runtime.panic_contextless("rdb: out of memory")
		}
		d.arena = grown
		d.size = new_size
	}
	if len(s) > 0 {
		intrinsics.mem_copy_non_overlapping(&d.arena[d.used], raw_data(s), len(s))
	}
	d.slots[i] = Dup_Slot {
		hash = h,
		off  = d.used,
		len  = len(s),
	}
	d.used += len(s)
	d.count += 1
	return true
}

@(private)
Lp_Dup_Ctx :: struct {
	tuple_len:     int,
	count:         int,
	set:           Dup_Set,
	last_expireat: i64,
}

@(private)
lp_dup_cb :: proc(p: [^]u8, head_count: u32, userdata: rawptr) -> bool {
	ctx := (^Lp_Dup_Ctx)(userdata)
	position := ctx.count % ctx.tuple_len
	ctx.count += 1
	if position == 0 {
		buf: [lp.LP_INTBUF_SIZE]u8
		return dup_add(&ctx.set, lp.lp_get_bytes(p, &buf))
	}
	if ctx.tuple_len == 3 && position == 2 {
		ttl: i64
		if !lp.lp_get_integer_value(p, &ttl) {
			return false
		}
		if ttl < 0 || u64(ttl) > EB_EXPIRE_TIME_MAX {
			return false
		}
		if ttl == 0 {
			ctx.last_expireat = -1
			return true
		}
		if ctx.last_expireat < 0 || ttl < ctx.last_expireat {
			return false
		}
		ctx.last_expireat = ttl
	}
	return true
}

lp_validate_dups :: proc(blob: []u8, deep: bool, tuple_len: int) -> bool {
	if len(blob) == 0 || tuple_len < 1 {
		return false
	}
	if !deep {
		return lp.lp_validate_integrity(raw_data(blob), u64(len(blob)), false, nil, nil)
	}
	ctx := Lp_Dup_Ctx {
		tuple_len = tuple_len,
	}
	defer dup_destroy(&ctx.set)
	if !lp.lp_validate_integrity(raw_data(blob), u64(len(blob)), true, lp_dup_cb, &ctx) {
		return false
	}
	return ctx.count % tuple_len == 0
}

lp_copy :: proc "contextless" (blob: []u8) -> [^]u8 {
	if len(blob) == 0 {
		return nil
	}
	out := lp.lp_malloc(len(blob))
	if out == nil {
		runtime.panic_contextless("rdb: out of memory")
	}
	intrinsics.mem_copy_non_overlapping(out, raw_data(blob), len(blob))
	return out
}

ziplist_to_listpack :: proc(blob: []u8, pairs: bool) -> ([^]u8, bool) {
	if !ziplist_check_header(blob) {
		return nil, false
	}
	it := ziplist_iter(blob)
	dups: Dup_Set
	defer dup_destroy(&dups)
	out := lp.lp_new(len(blob) + 16)
	if out == nil {
		return nil, false
	}
	batch: [64]lp.Entry
	pending := 0
	index := 0
	e: Zl_Entry
	for ziplist_next(&it, &e) {
		if pairs && index % 2 == 0 {
			buf: [24]u8
			if !dup_add(&dups, zl_entry_bytes(&e, &buf)) {
				lp.lp_free(out)
				return nil, false
			}
		}
		if e.is_int {
			batch[pending] = lp.entry_from_int(e.ival)
		} else {
			batch[pending] = lp.entry_from_bytes(e.str)
		}
		pending += 1
		index += 1
		if pending == len(batch) {
			out = lp.lp_batch_append(out, batch[:pending])
			pending = 0
			if out == nil {
				return nil, false
			}
		}
	}
	if it.failed || (pairs && index % 2 != 0) {
		lp.lp_free(out)
		return nil, false
	}
	if pending > 0 {
		out = lp.lp_batch_append(out, batch[:pending])
		if out == nil {
			return nil, false
		}
	}
	return out, true
}

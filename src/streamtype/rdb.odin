package streamtype

import integer "../integer"
import lp "../listpack"
import rx "../rax"
import rdb "../rdb"
import "base:intrinsics"

rdb_type :: proc "contextless" (s: Stream) -> u8 {
	return rdb.TYPE_STREAM_LISTPACKS_3
}

rdb_save :: proc "contextless" (w: ^rdb.Writer, s: Stream) {
	rdb.put_len(w, s.rax.numele)
	it: rx.Iterator
	rx.start(&it, s.rax)
	rx.seek(&it, "^")
	for rx.next(&it) {
		node := ([^]u8)(it.data)
		rdb.put_string(w, rx.key(&it))
		rdb.put_string(w, node[:lp_total(node)])
	}
	rx.stop(&it)
	rdb.put_len(w, s.length)
	rdb.put_len(w, s.last_id.ms)
	rdb.put_len(w, s.last_id.seq)
	rdb.put_len(w, s.first_id.ms)
	rdb.put_len(w, s.first_id.seq)
	rdb.put_len(w, s.max_deleted_entry_id.ms)
	rdb.put_len(w, s.max_deleted_entry_id.seq)
	rdb.put_len(w, s.entries_added)
	if s.cgroups == nil {
		rdb.put_len(w, 0)
		return
	}
	rdb.put_len(w, s.cgroups.numele)
	gi: rx.Iterator
	rx.start(&gi, s.cgroups)
	rx.seek(&gi, "^")
	for rx.next(&gi) {
		cg := (^CG)(gi.data)
		rdb.put_string(w, rx.key(&gi))
		rdb.put_len(w, cg.last_id.ms)
		rdb.put_len(w, cg.last_id.seq)
		rdb.put_len(w, u64(cg.entries_read))
		rdb.put_len(w, cg.pel.numele)
		pi: rx.Iterator
		rx.start(&pi, cg.pel)
		rx.seek(&pi, "^")
		for rx.next(&pi) {
			nack := (^NACK)(pi.data)
			rdb.put_raw(w, rx.key(&pi))
			rdb.put_ms(w, nack.delivery_time)
			rdb.put_len(w, nack.delivery_count)
		}
		rx.stop(&pi)
		rdb.put_len(w, cg.consumers.numele)
		ci: rx.Iterator
		rx.start(&ci, cg.consumers)
		rx.seek(&ci, "^")
		for rx.next(&ci) {
			consumer := (^Consumer)(ci.data)
			rdb.put_string(w, rx.key(&ci))
			rdb.put_ms(w, consumer.seen_time)
			rdb.put_ms(w, consumer.active_time)
			rdb.put_len(w, consumer.pel.numele)
			ki: rx.Iterator
			rx.start(&ki, consumer.pel)
			rx.seek(&ki, "^")
			for rx.next(&ki) {
				rdb.put_raw(w, rx.key(&ki))
			}
			rx.stop(&ki)
		}
		rx.stop(&ci)
	}
	rx.stop(&gi)
}

@(private)
rdb_fail :: proc(r: ^rdb.Reader, s: Stream, msg: string, tail: string = "") -> Stream {
	if s != nil {
		destroy(s)
	}
	if rdb.ok(r) {
		rdb.corrupt(r, msg, 0, false, tail)
	}
	return nil
}

@(private)
rdb_len :: proc(r: ^rdb.Reader, v: ^u64) -> bool {
	if !rdb_len_any(r, v) {
		return false
	}
	return v^ != rdb.LENERR
}

@(private)
rdb_len_any :: proc(r: ^rdb.Reader, v: ^u64) -> bool {
	head, hgood := rdb.take(r, 1)
	if !hgood || len(head) != 1 || !rdb.ok(r) {
		return false
	}
	b := head[0]
	switch b >> 6 {
	case 0:
		v^ = u64(b & 0x3F)
	case 1:
		low, lgood := rdb.take(r, 1)
		if !lgood || len(low) != 1 || !rdb.ok(r) {
			return false
		}
		v^ = u64(b & 0x3F) << 8 | u64(low[0])
	case 2:
		width := 0
		if b == 0x80 {
			width = 4
		} else if b == 0x81 {
			width = 8
		} else {
			v^ = rdb.LENERR
			return true
		}
		raw, rgood := rdb.take(r, width)
		if !rgood || len(raw) != width || !rdb.ok(r) {
			return false
		}
		x: u64
		for c in raw {
			x = x << 8 | u64(c)
		}
		v^ = x
	case:
		v^ = u64(b & 0x3F)
	}
	return true
}

@(private)
rdb_get_id :: proc(r: ^rdb.Reader) -> (id: ID, good: bool) {
	if !rdb_len_any(r, &id.ms) {
		return
	}
	if !rdb_len_any(r, &id.seq) {
		return
	}
	return id, true
}

node_int :: proc(p: [^]u8) -> (i64, bool) {
	tag := p[0]
	if tag < 0x80 || (tag >= 0xC0 && tag < 0xE0) || (tag >= 0xF1 && tag <= 0xF4) {
		return elem_int(p), true
	}
	buf: [lp.LP_INTBUF_SIZE]u8
	return integer.parse_i64(elem_bytes(p, &buf))
}

@(private)
elem_extent :: proc "contextless" (node: [^]u8, limit: int, off: int) -> (end: int, ok: bool) #no_bounds_check {
	if off < HDR || off >= limit {
		return
	}
	tag := node[off]
	body: int
	switch {
	case tag < 0x80:
		body = 1
	case tag < 0xC0:
		body = 1 + int(tag & 0x3F)
	case tag < 0xE0:
		body = 2
	case tag < 0xF0:
		if off + 1 >= limit {
			return
		}
		body = 2 + (int(tag & 0x0F) << 8 | int(node[off + 1]))
	case tag == 0xF0:
		if off + 4 >= limit {
			return
		}
		body = 5 + int(read_le(&node[off + 1], 4))
	case tag == 0xF1:
		body = 3
	case tag == 0xF2:
		body = 4
	case tag == 0xF3:
		body = 5
	case tag == 0xF4:
		body = 9
	case:
		return
	}
	width := lp.backlen_width(u64(body))
	if body > limit - off || width > limit - off - body {
		return
	}
	end = off + body + width
	if lp.lp_decode_backlen(&node[end - 1]) != u64(body) {
		return 0, false
	}
	return end, true
}

Node_Walk :: struct {
	lp:   [^]u8,
	size: u64,
	p:    [^]u8,
}

walk_take :: proc(w: ^Node_Walk) -> [^]u8 {
	if w.p == nil || w.size < HDR + 1 {
		return nil
	}
	limit := int(w.size) - 1
	off := int(uintptr(w.p) - uintptr(w.lp))
	end, ok := elem_extent(w.lp, limit, off)
	if !ok {
		w.p = nil
		return nil
	}
	cur := w.p
	w.p = &w.lp[end]
	return cur
}

walk_int :: proc(w: ^Node_Walk) -> (i64, bool) {
	p := walk_take(w)
	if p == nil {
		return 0, false
	}
	return node_int(p)
}

walk_skip :: proc(w: ^Node_Walk, n: i64) -> bool {
	if n < 0 || u64(n) > w.size {
		return false
	}
	for _ in 0 ..< n {
		if walk_take(w) == nil {
			return false
		}
	}
	return true
}

@(private)
walk_done :: #force_inline proc(w: ^Node_Walk) -> bool {
	return w.p != nil && uintptr(w.p) - uintptr(w.lp) == uintptr(w.size - 1)
}

@(private)
node_check :: proc(node: [^]u8, size: u64, deep: bool) -> bool {
	if size < HDR + 1 || size > LISTPACK_MAX_SIZE + 1024 {
		return false
	}
	if u64(lp_total(node)) != size || node[size - 1] != EOF {
		return false
	}
	w := Node_Walk{lp = node, size = size, p = &node[HDR]}
	count, ok1 := walk_int(&w)
	deleted, ok2 := walk_int(&w)
	nfields, ok3 := walk_int(&w)
	if !ok1 || !ok2 || !ok3 || count < 0 || deleted < 0 || nfields < 0 {
		return false
	}
	if !walk_skip(&w, nfields) {
		return false
	}
	term, ok4 := walk_int(&w)
	if !ok4 || term != 0 {
		return false
	}
	entries := 0
	for !walk_done(&w) {
		if w.p == nil {
			return false
		}
		flags, f_ok := walk_int(&w)
		_, m_ok := walk_int(&w)
		_, s_ok := walk_int(&w)
		if !f_ok || !m_ok || !s_ok {
			return false
		}
		in_entry: i64 = 3
		if flags & ITEM_FLAG_SAMEFIELDS != 0 {
			if !walk_skip(&w, nfields) {
				return false
			}
			in_entry += nfields
		} else {
			nf, n_ok := walk_int(&w)
			if !n_ok || nf < 0 || u64(nf) > size {
				return false
			}
			if !walk_skip(&w, nf * 2) {
				return false
			}
			in_entry += 1 + nf * 2
		}
		lpcount, c_ok := walk_int(&w)
		if !c_ok || lpcount != in_entry {
			return false
		}
		entries += 1
	}
	if !deep {
		return true
	}
	walked := i64(entries)
	return walked > 0 && deleted <= walked && count == walked - deleted
}

validate_node :: proc(node: [^]u8, size: u64) -> bool {
	return node_check(node, size, true)
}

@(private)
load_node :: proc(r: ^rdb.Reader, s: Stream, deep: bool) -> (ok: bool, reason: string) {
	key, kgood := rdb.get_string(r, 0)
	if !kgood || !rdb.ok(r) {
		return false, "Stream node key entry is not the size of a stream ID"
	}
	if len(key) != 16 {
		return false, "Stream node key entry is not the size of a stream ID"
	}
	keybuf: [16]u8
	copy(keybuf[:], key)
	blob, bgood := rdb.get_string(r, 1)
	if !bgood || !rdb.ok(r) {
		return false, "Stream listpacks loading failed"
	}
	size := len(blob)
	if size < HDR + 1 {
		return false, "Stream listpack integrity check failed"
	}
	if blob[HDR] == EOF {
		return false, "Empty listpack inside stream"
	}
	node := lp_alloc(s, size)
	intrinsics.mem_copy_non_overlapping(node, raw_data(blob), size)
	if !node_check(node, u64(size), deep) {
		lp_release(s, node)
		return false, "Stream listpack integrity check failed"
	}
	if !rx.try_insert(s.rax, keybuf[:], node) {
		lp_release(s, node)
		return false, "Listpack re-added with existing key"
	}
	return true, ""
}

rdb_load :: proc(r: ^rdb.Reader, rdbtype: int, deep: bool) -> Stream {
	s := create()
	nodes: u64
	if !rdb_len(r, &nodes) {
		return rdb_fail(r, s, "Stream node count loading failed")
	}
	for _ in 0 ..< nodes {
		good, reason := load_node(r, s, deep)
		if !good {
			return rdb_fail(r, s, reason)
		}
	}
	length: u64
	if !rdb_len_any(r, &length) {
		return rdb_fail(r, s, "Stream length loading failed")
	}
	s.length = length
	last, lgood := rdb_get_id(r)
	if !lgood {
		return rdb_fail(r, s, "Stream last id loading failed")
	}
	s.last_id = last
	if rdbtype >= rdb.TYPE_STREAM_LISTPACKS_2 {
		first, fgood := rdb_get_id(r)
		if !fgood {
			return rdb_fail(r, s, "Stream first id loading failed")
		}
		s.first_id = first
		maxdel, mgood := rdb_get_id(r)
		if !mgood {
			return rdb_fail(r, s, "Stream max deleted id loading failed")
		}
		s.max_deleted_entry_id = maxdel
		added: u64
		if !rdb_len_any(r, &added) {
			return rdb_fail(r, s, "Stream entries added loading failed")
		}
		s.entries_added = added
	} else {
		s.entries_added = s.length
		s.max_deleted_entry_id = ID_MIN
		s.first_id = get_edge_id(s, true, true)
	}
	if deep && s.rax.numele == 0 && s.length != 0 {
		return rdb_fail(r, s, "Stream length inconsistent with empty listpack set")
	}
	groups: u64
	if !rdb_len(r, &groups) {
		return rdb_fail(r, s, "Stream cgroup count loading failed")
	}
	for _ in 0 ..< groups {
		name, ngood := rdb.get_string(r, 0)
		if !ngood || !rdb.ok(r) {
			return rdb_fail(r, s, "Error reading the consumer group name from Stream")
		}
		gname := make([]u8, len(name))
		defer delete(gname)
		copy(gname, name)
		gid, igood := rdb_get_id(r)
		if !igood {
			return rdb_fail(r, s, "Stream cgroup ID loading failed")
		}
		entries_read: i64
		if rdbtype >= rdb.TYPE_STREAM_LISTPACKS_2 {
			er: u64
			if !rdb_len_any(r, &er) {
				return rdb_fail(r, s, "Stream cgroup offset loading failed")
			}
			entries_read = i64(er)
		} else {
			entries_read = estimate_distance(s, gid)
		}
		cg := create_cg(s, gname, gid, entries_read)
		if cg == nil {
			return rdb_fail(r, s, "Duplicated consumer group name")
		}
		pel_size: u64
		if !rdb_len(r, &pel_size) {
			return rdb_fail(r, s, "Stream PEL size loading failed")
		}
		for _ in 0 ..< pel_size {
			raw, rgood := rdb.take(r, 16)
			if !rgood || len(raw) != 16 {
				return rdb_fail(r, s, "Stream PEL ID loading failed")
			}
			idkey: [16]u8
			copy(idkey[:], raw)
			when_ms, tgood := rdb.get_ms(r)
			if !tgood {
				return rdb_fail(r, s, "Stream PEL NACK loading failed")
			}
			delivered: u64
			if !rdb_len_any(r, &delivered) {
				return rdb_fail(r, s, "Stream PEL NACK loading failed")
			}
			nack := create_nack(s, nil, when_ms)
			nack.delivery_count = delivered
			if !rx.try_insert(cg.pel, idkey[:], nack) {
				cg_release(s, nack)
				return rdb_fail(r, s, "Duplicated global PEL entry loading stream consumer group")
			}
		}
		consumers: u64
		if !rdb_len(r, &consumers) {
			return rdb_fail(r, s, "Stream consumers num loading failed")
		}
		for _ in 0 ..< consumers {
			cname, cgood := rdb.get_string(r, 0)
			if !cgood || !rdb.ok(r) {
				return rdb_fail(r, s, "Error reading the consumer name from Stream group")
			}
			consumer := create_consumer(s, cg, cname, 0)
			if consumer == nil {
				return rdb_fail(r, s, "Duplicate stream consumer detected")
			}
			seen, sgood := rdb.get_ms(r)
			if !sgood {
				return rdb_fail(r, s, "Stream short read reading seen time")
			}
			consumer.seen_time = seen
			if rdbtype >= rdb.TYPE_STREAM_LISTPACKS_3 {
				active, agood := rdb.get_ms(r)
				if !agood {
					return rdb_fail(r, s, "Stream short read reading active time")
				}
				consumer.active_time = active
			} else {
				consumer.active_time = seen
			}
			owned: u64
			if !rdb_len(r, &owned) {
				return rdb_fail(r, s, "Stream consumer PEL num loading failed")
			}
			for _ in 0 ..< owned {
				raw, rgood := rdb.take(r, 16)
				if !rgood || len(raw) != 16 {
					return rdb_fail(r, s, "Stream short read reading PEL streamID")
				}
				idkey: [16]u8
				copy(idkey[:], raw)
				v, found := rx.find(cg.pel, idkey[:])
				if !found {
					return rdb_fail(r, s, "Consumer entry not found in group global PEL")
				}
				nack := (^NACK)(v)
				if nack.consumer != nil {
					return rdb_fail(r, s, "Duplicated consumer PEL entry loading a stream consumer group")
				}
				nack.consumer = consumer
				if !rx.try_insert(consumer.pel, idkey[:], nack) {
					return rdb_fail(r, s, "Duplicated consumer PEL entry loading a stream consumer group")
				}
			}
		}
		{
			pi: rx.Iterator
			rx.start(&pi, cg.pel)
			rx.seek(&pi, "^")
			orphan := false
			for rx.next(&pi) {
				if (^NACK)(pi.data).consumer == nil {
					orphan = true
					break
				}
			}
			rx.stop(&pi)
			if orphan {
				return rdb_fail(r, s, "Stream CG PEL entry without consumer")
			}
		}
	}
	return s
}

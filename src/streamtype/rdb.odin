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
	rdb.put_len(w, s.nodes.stored)
	it: rx.Iterator
	rx.start(&it, s.nodes)
	rx.seek(&it, "^")
	for rx.next(&it) {
		node := ([^]u8)(it.data)
		rdb.put_string(w, rx.key(&it))
		rdb.put_string(w, node[:lp_total(node)])
	}
	rx.stop(&it)
	rdb.put_len(w, s.live)
	rdb.put_len(w, s.top.ms)
	rdb.put_len(w, s.top.seq)
	rdb.put_len(w, s.head.ms)
	rdb.put_len(w, s.head.seq)
	rdb.put_len(w, s.tomb.ms)
	rdb.put_len(w, s.tomb.seq)
	rdb.put_len(w, s.added)
	if s.groups == nil {
		rdb.put_len(w, 0)
		return
	}
	rdb.put_len(w, s.groups.stored)
	gi: rx.Iterator
	rx.start(&gi, s.groups)
	rx.seek(&gi, "^")
	for rx.next(&gi) {
		g := (^Group)(gi.data)
		rdb.put_string(w, rx.key(&gi))
		rdb.put_len(w, g.delivered.ms)
		rdb.put_len(w, g.delivered.seq)
		rdb.put_len(w, u64(g.reads))
		rdb.put_len(w, g.pending.stored)
		pi: rx.Iterator
		rx.start(&pi, g.pending)
		rx.seek(&pi, "^")
		for rx.next(&pi) {
			pe := (^Delivery)(pi.data)
			rdb.put_raw(w, rx.key(&pi))
			rdb.put_ms(w, pe.sent_ms)
			rdb.put_len(w, pe.times)
		}
		rx.stop(&pi)
		rdb.put_len(w, g.members.stored)
		ci: rx.Iterator
		rx.start(&ci, g.members)
		rx.seek(&ci, "^")
		for rx.next(&ci) {
			member := (^Member)(ci.data)
			rdb.put_string(w, rx.key(&ci))
			rdb.put_ms(w, member.seen_ms)
			rdb.put_ms(w, member.active_ms)
			rdb.put_len(w, member.owned.stored)
			ki: rx.Iterator
			rx.start(&ki, member.owned)
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
UNKNOWN_LENGTH_MARK :: max(u64)

@(private)
rdb_len :: proc(r: ^rdb.Reader, v: ^u64) -> bool {
	if !rdb_len_any(r, v) {
		return false
	}
	return v^ != UNKNOWN_LENGTH_MARK
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
			v^ = UNKNOWN_LENGTH_MARK
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
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
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
	if size < HDR + 1 || size > NODE_SIZE_CEILING + 1024 {
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
		if .Shared_Fields in transmute(Entry_Marks)u8(flags) {
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
	if !rx.try_insert(s.nodes, keybuf[:], node) {
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
	s.live = length
	last, lgood := rdb_get_id(r)
	if !lgood {
		return rdb_fail(r, s, "Stream last id loading failed")
	}
	s.top = last
	if rdbtype >= rdb.TYPE_STREAM_LISTPACKS_2 {
		first, fgood := rdb_get_id(r)
		if !fgood {
			return rdb_fail(r, s, "Stream first id loading failed")
		}
		s.head = first
		maxdel, mgood := rdb_get_id(r)
		if !mgood {
			return rdb_fail(r, s, "Stream max deleted id loading failed")
		}
		s.tomb = maxdel
		added: u64
		if !rdb_len_any(r, &added) {
			return rdb_fail(r, s, "Stream entries added loading failed")
		}
		s.added = added
	} else {
		s.added = s.live
		s.tomb = ID_MIN
		s.head = boundary_id(s, .Head, false)
	}
	if deep && s.nodes.stored == 0 && s.live != 0 {
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
			reached, known := added_through(s, gid)
			entries_read = reached if known else ENTRIES_READ_UNKNOWN
		}
		g := add_group(s, gname, gid, entries_read)
		if g == nil {
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
			pe := new_delivery(s, nil, when_ms)
			pe.times = delivered
			if !rx.try_insert(g.pending, idkey[:], pe) {
				group_release(s, pe)
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
			member := add_member(s, g, cname, 0)
			if member == nil {
				return rdb_fail(r, s, "Duplicate stream consumer detected")
			}
			seen, sgood := rdb.get_ms(r)
			if !sgood {
				return rdb_fail(r, s, "Stream short read reading seen time")
			}
			member.seen_ms = seen
			if rdbtype >= rdb.TYPE_STREAM_LISTPACKS_3 {
				active, agood := rdb.get_ms(r)
				if !agood {
					return rdb_fail(r, s, "Stream short read reading active time")
				}
				member.active_ms = active
			} else {
				member.active_ms = seen
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
				v, found := rx.find(g.pending, idkey[:])
				if !found {
					return rdb_fail(r, s, "Consumer entry not found in group global PEL")
				}
				pe := (^Delivery)(v)
				if pe.owner != nil {
					return rdb_fail(r, s, "Duplicated consumer PEL entry loading a stream consumer group")
				}
				pe.owner = member
				if !rx.try_insert(member.owned, idkey[:], pe) {
					return rdb_fail(r, s, "Duplicated consumer PEL entry loading a stream consumer group")
				}
			}
		}
		{
			pi: rx.Iterator
			rx.start(&pi, g.pending)
			rx.seek(&pi, "^")
			orphan := false
			for rx.next(&pi) {
				if (^Delivery)(pi.data).owner == nil {
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

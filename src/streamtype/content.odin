package streamtype

import lp "../listpack"
import rx "../rax"
import "base:intrinsics"

STREAM_NAME_ALLOWANCE :: 40
STREAM_ID_ALLOWANCE :: 10

Stream_Charge :: struct {
	content: int,
	chg:     int,
}

charge_room: bool

set_charge_room :: proc "contextless" (on: bool) {
	intrinsics.atomic_store_explicit(&charge_room, on, .Relaxed)
}

charged :: #force_inline proc "contextless" (s: Stream) -> ^Stream_Charge {
	if !intrinsics.atomic_load_explicit(&charge_room, .Relaxed) || s == nil || usable(s) < size_of(Stream_Log) + size_of(Stream_Charge) {
		return nil
	}
	return (^Stream_Charge)(uintptr(s) + size_of(Stream_Log))
}

charge_slot :: proc "contextless" (s: Stream) -> ^int {
	if c := charged(s); c != nil {
		return &c.chg
	}
	return nil
}

@(private)
content_moved :: #force_inline proc "contextless" (s: Stream, delta: int) {
	if c := charged(s); c != nil {
		c.content += delta
	}
}

content_memory :: proc "contextless" (s: Stream) -> int {
	if s == nil {
		return 0
	}
	n := object_content()
	if s.nodes != nil {
		n += index_content(s.nodes, true)
		last := 0
		it: rx.Iterator
		rx.start(&it, s.nodes)
		rx.seek(&it, "^")
		for rx.next(&it) {
			last = lp_total(([^]u8)(it.data))
			n += lp.content_block(last)
		}
		rx.stop(&it)
		n += tail_reserve(last)
	}
	if s.groups != nil {
		n += index_content(s.groups, false)
		it: rx.Iterator
		rx.start(&it, s.groups)
		rx.seek(&it, "^")
		for rx.next(&it) {
			g := (^Group)(it.data)
			n += lp.content_block(size_of(Group)) + index_content(g.pending, true) + index_content(g.members, false)
			if g.pending != nil {
				n += int(g.pending.stored) * lp.content_block(size_of(Delivery))
			}
			if g.members != nil {
				mt: rx.Iterator
				rx.start(&mt, g.members)
				rx.seek(&mt, "^")
				for rx.next(&mt) {
					m := (^Member)(mt.data)
					n += lp.content_block(size_of(Member) + len(m.name)) + index_content(m.owned, true)
				}
				rx.stop(&mt)
			}
		}
		rx.stop(&it)
	}
	return n
}

charge :: proc "contextless" (s: Stream) -> int {
	if s == nil {
		return 0
	}
	c := charged(s)
	if c == nil {
		return content_memory(s)
	}
	n := object_content() + c.content
	if s.nodes != nil {
		n += lp.content_block(size_of(rx.Rax)) + int(s.nodes.stored) * STREAM_ID_ALLOWANCE
		if t, found := find_tail(s); found {
			n += tail_reserve(lp_total(t.node))
		}
	}
	return n
}

@(private = "file")
object_content :: proc "contextless" () -> int {
	size := size_of(Stream_Log)
	if intrinsics.atomic_load_explicit(&charge_room, .Relaxed) {
		size += size_of(Stream_Charge)
	}
	return lp.content_block(size)
}

@(private = "file")
tail_reserve :: proc "contextless" (last: int) -> int {
	if last <= 0 {
		return 0
	}
	reserve := NODE_RESERVE_CAP
	if stream_node_max_bytes > 0 {
		reserve = min(reserve, stream_node_max_bytes)
	}
	return lp.content_block(max(last, reserve)) - lp.content_block(last)
}

@(private = "file")
index_content :: proc "contextless" (r: ^rx.Rax, ids: bool) -> int {
	if r == nil {
		return 0
	}
	n := lp.content_block(size_of(rx.Rax))
	if ids {
		return n + int(r.stored) * STREAM_ID_ALLOWANCE
	}
	n += int(r.stored) * STREAM_NAME_ALLOWANCE
	it: rx.Iterator
	rx.start(&it, r)
	rx.seek(&it, "^")
	for rx.next(&it) {
		n += len(rx.key(&it))
	}
	rx.stop(&it)
	return n
}

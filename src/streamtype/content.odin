package streamtype

import lp "../listpack"
import rx "../rax"

STREAM_NAME_ALLOWANCE :: 40
STREAM_ID_ALLOWANCE :: 10

content_memory :: proc "contextless" (s: Stream) -> int {
	if s == nil {
		return 0
	}
	n := lp.content_block(size_of(Stream_Log))
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
		if last > 0 {
			reserve := NODE_RESERVE_CAP
			if stream_node_max_bytes > 0 {
				reserve = min(reserve, stream_node_max_bytes)
			}
			n += lp.content_block(max(last, reserve)) - lp.content_block(last)
		}
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

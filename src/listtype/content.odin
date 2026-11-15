package listtype

import lp "../listpack"

content_memory :: proc "contextless" (l: List) -> int {
	if l == nil {
		return 0
	}
	n := lp.content_block(size_of(List_Object))
	if l.encoding == .Listpack {
		return n + lp.content_block(lp.lp_bytes(l.lp))
	}
	if l.ql == nil {
		return n
	}
	n += lp.content_block(size_of(Quicklist))
	for x := l.ql.head; x != nil; x = x.next {
		n += lp.content_block(size_of(Node)) + lp.content_block(max(x.sz, 1))
	}
	return n
}

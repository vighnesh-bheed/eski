package sortwork

import "core:testing"

@(test)
inline_sort_resp2 :: proc(t: ^testing.T) {
	context.allocator = heap()
	testing.expect(t, replay(t, "inline-sort", INLINE_SORT, 2, sort_rules()) == 444)
}

@(test)
inline_sort_resp3 :: proc(t: ^testing.T) {
	context.allocator = heap()
	testing.expect(t, replay(t, "inline-sort", INLINE_SORT, 3, sort_rules()) == 444)
}

@(test)
inline_copy_resp2 :: proc(t: ^testing.T) {
	context.allocator = heap()
	testing.expect(t, replay(t, "inline-copy-resp2", INLINE_COPY_RESP2, 2, copy_rules()) == 258)
}

@(test)
inline_copy_resp3 :: proc(t: ^testing.T) {
	context.allocator = heap()
	testing.expect(t, replay(t, "inline-copy-resp3", INLINE_COPY_RESP3, 3, copy_rules()) == 258)
}

@(test)
inline_sort_acl :: proc(t: ^testing.T) {
	context.allocator = heap()
	testing.expect(t, replay(t, "inline-sort-acl", INLINE_SORT_ACL, 2, acl_rules()) == 41)
}

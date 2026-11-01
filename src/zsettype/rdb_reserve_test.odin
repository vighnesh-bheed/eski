package zsettype

import "core:testing"
import rdb "../rdb"

@(test)
rdb_truncated_huge_count_uses_bounded_initial_reservation :: proc(t: ^testing.T) {
	for count in ([]u64{1 << 40, max(u64) - 1}) {
		w: rdb.Writer
		rdb.writer_init_mem(&w, false, false)
		rdb.put_len(&w, count)
		for kind in ([]int{rdb.TYPE_ZSET, rdb.TYPE_ZSET_2}) {
			r: rdb.Reader
			rdb.reader_init_mem(&r, rdb.writer_bytes(&w), false)
			z := rdb_load(&r, kind, true)
			testing.expect(t, z == nil)
			testing.expect_value(t, r.status, .Short_Read if count == 1 << 40 else .Corrupt)
			destroy(z)
			rdb.reader_destroy(&r)
		}
		rdb.writer_destroy(&w)
	}
}

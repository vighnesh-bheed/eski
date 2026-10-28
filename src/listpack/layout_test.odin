package listpack

import "core:testing"

#assert(LP_HDR_SIZE == 6)

when size_of(rawptr) == 8 {
	#assert(size_of(Entry) == 24 && align_of(Entry) == 8)
	#assert(size_of(Header) == 8 && align_of(Header) == 4)
	#assert(size_of(Body) == 40 && align_of(Body) == 8)
	#assert(size_of(Entry_Plan) == 40 && align_of(Entry_Plan) == 8)
	#assert(size_of(Entry_Extent) == 56 && align_of(Entry_Extent) == 8)
}

@(test)
entry_layout_retains_external_field_order :: proc(t: ^testing.T) {
	entry: Entry
	testing.expect(t, uintptr(&entry.sval) < uintptr(&entry.slen) && uintptr(&entry.slen) < uintptr(&entry.lval))
	testing.expect(t, LP_HDR_SIZE == 6 && LP_INTBUF_SIZE == 21)
}

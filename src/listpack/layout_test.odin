package listpack

import "core:testing"

#assert(PACK_HEADER_BYTES == 6)

when size_of(rawptr) == 8 {
	#assert(size_of(Element) == 24 && align_of(Element) == 8)
	#assert(size_of(Header) == 8 && align_of(Header) == 4)
	#assert(size_of(Body) == 40 && align_of(Body) == 8)
	#assert(size_of(Entry_Plan) == 40 && align_of(Entry_Plan) == 8)
	#assert(size_of(Entry_Extent) == 56 && align_of(Entry_Extent) == 8)
}

@(test)
entry_layout_retains_external_field_order :: proc(t: ^testing.T) {
	entry: Element
	testing.expect(t, uintptr(&entry.text) < uintptr(&entry.text_len) && uintptr(&entry.text_len) < uintptr(&entry.number))
	testing.expect(t, PACK_HEADER_BYTES == 6 && DECIMAL_BUFFER_BYTES == 21)
}

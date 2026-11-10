package tagindex

import "base:runtime"
import "../roaring"
import "../termdict"

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Too_Many_Values,
}

Field :: struct {
	values:    termdict.Dictionary,
	bitmaps:   [dynamic]roaring.Bitmap,
	records:   int,
	allocator: runtime.Allocator,
}

Removed_Proc :: #type proc(ctx: rawptr, value: termdict.Id, doc: u32)

init :: proc(f: ^Field, allocator := context.allocator) {
	f^ = Field{allocator = allocator}
	termdict.init(&f.values, allocator)
	f.bitmaps = make([dynamic]roaring.Bitmap, 0, 0, allocator)
}

destroy :: proc(f: ^Field) {
	for &b in f.bitmaps {
		roaring.destroy(&b)
	}
	delete(f.bitmaps)
	termdict.destroy(&f.values)
	f^ = Field{}
}

add :: proc(f: ^Field, value: string, doc: u32) -> (id: termdict.Id, err: Error) {
	vid, inserted, e := termdict.insert(&f.values, value)
	switch e {
	case .None:
	case .Out_Of_Memory:
		return termdict.NONE, .Out_Of_Memory
	case .Too_Many_Terms:
		return termdict.NONE, .Too_Many_Values
	}
	if int(vid) >= len(f.bitmaps) {
		old := len(f.bitmaps)
		if int(vid) + 1 > cap(f.bitmaps) && reserve(&f.bitmaps, max(2 * cap(f.bitmaps), int(vid) + 1)) != nil {
			if inserted {
				termdict.remove(&f.values, vid)
			}
			return termdict.NONE, .Out_Of_Memory
		}
		if resize(&f.bitmaps, int(vid) + 1) != nil {
			if inserted {
				termdict.remove(&f.values, vid)
			}
			return termdict.NONE, .Out_Of_Memory
		}
		for i in old ..< len(f.bitmaps) {
			roaring.init(&f.bitmaps[i], f.allocator)
		}
	}
	added, re := roaring.add(&f.bitmaps[vid], doc)
	if re != .None {
		if inserted {
			termdict.remove(&f.values, vid)
		}
		return termdict.NONE, .Out_Of_Memory
	}
	if added {
		f.records += 1
	}
	return vid, .None
}

lookup :: proc "contextless" (f: ^Field, value: string) -> (^roaring.Bitmap, termdict.Id, bool) {
	id, found := termdict.lookup(&f.values, value)
	if !found {
		return nil, termdict.NONE, false
	}
	return &f.bitmaps[id], id, true
}

bitmap :: proc "contextless" (f: ^Field, id: termdict.Id) -> ^roaring.Bitmap {
	if int(id) >= len(f.bitmaps) {
		return nil
	}
	return &f.bitmaps[id]
}

cardinality :: proc "contextless" (f: ^Field, value: string) -> int {
	b, _, found := lookup(f, value)
	if !found {
		return 0
	}
	return roaring.cardinality(b)
}

value_count :: proc "contextless" (f: ^Field) -> int {
	return termdict.count(&f.values)
}

remove :: proc(f: ^Field, value: string, doc: u32) -> (removed: bool, err: Error) {
	b, id, found := lookup(f, value)
	if !found {
		return false, .None
	}
	r, e := roaring.remove(b, doc)
	if e != .None {
		return false, .Out_Of_Memory
	}
	if r {
		f.records -= 1
	}
	if roaring.is_empty(b) {
		termdict.remove(&f.values, id)
	}
	return r, .None
}

collect :: proc(f: ^Field, deleted: ^roaring.Bitmap, removed: Removed_Proc = nil, removed_ctx: rawptr = nil) -> (dropped: int, err: Error) {
	if roaring.is_empty(deleted) {
		return 0, .None
	}
	for i in 0 ..< len(f.bitmaps) {
		id := termdict.Id(i)
		if _, live := termdict.text(&f.values, id); !live {
			continue
		}
		b := &f.bitmaps[i]
		gone, ce := roaring.and_cardinality(b, deleted)
		if ce != .None {
			return dropped, .Out_Of_Memory
		}
		if gone == 0 {
			continue
		}
		if removed != nil {
			it: roaring.Iterator
			roaring.iterator_init(&it, b)
			for doc, ok := roaring.next(&it); ok; doc, ok = roaring.next(&it) {
				if roaring.contains(deleted, doc) {
					removed(removed_ctx, id, doc)
				}
			}
		}
		if roaring.combine_into(.Andnot, b, deleted) != .None {
			return dropped, .Out_Of_Memory
		}
		dropped += gone
		f.records -= gone
		if roaring.is_empty(b) {
			termdict.remove(&f.values, id)
		}
	}
	return dropped, .None
}

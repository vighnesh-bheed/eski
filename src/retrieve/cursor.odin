package retrieve

import "../postings"
import "../roaring"
import "../sorted"

END :: max(u32)

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Argument,
}

Next_Proc :: #type proc(c: ^Cursor) -> u32

Advance_Proc :: #type proc(c: ^Cursor, target: u32) -> u32

Score_Proc :: #type proc(c: ^Cursor, s: ^Scoring) -> f64

Positions_Proc :: #type proc(c: ^Cursor, out: ^[dynamic]u32) -> bool

Block_Proc :: #type proc(c: ^Cursor) -> []u32

Ops :: struct {
	next:      Next_Proc,
	advance:   Advance_Proc,
	score:     Score_Proc,
	positions: Positions_Proc,
	block:     Block_Proc,
}

Cursor :: struct {
	doc:  u32,
	cost: u64,
	ops:  ^Ops,
}

next :: #force_inline proc(c: ^Cursor) -> u32 {
	return c.ops.next(c)
}

advance :: #force_inline proc(c: ^Cursor, target: u32) -> u32 {
	return c.ops.advance(c, target)
}

score :: proc(c: ^Cursor, s: ^Scoring) -> f64 {
	if c.ops.score == nil {
		return 0
	}
	return c.ops.score(c, s)
}

positions :: proc(c: ^Cursor, out: ^[dynamic]u32) -> bool {
	if c.ops.positions == nil {
		return false
	}
	return c.ops.positions(c, out)
}

block :: proc(c: ^Cursor) -> []u32 {
	if c.ops.block == nil {
		return nil
	}
	return c.ops.block(c)
}

collect_docs :: proc(c: ^Cursor, out: ^[dynamic]u32) -> Error {
	for d := next(c); d != END; d = next(c) {
		if _, err := append(out, d); err != nil {
			return .Out_Of_Memory
		}
	}
	return .None
}

Term_Cursor :: struct {
	using base:      Cursor,
	reader:          postings.Cursor,
	leaf:            Leaf,
	position_fields: postings.Fields,
}

TERM_OPS := Ops {
	next = proc(c: ^Cursor) -> u32 {
		t := (^Term_Cursor)(c)
		t.doc = postings.next(&t.reader)
		return t.doc
	},
	advance = proc(c: ^Cursor, target: u32) -> u32 {
		t := (^Term_Cursor)(c)
		t.doc = postings.advance(&t.reader, target)
		return t.doc
	},
	score = proc(c: ^Cursor, s: ^Scoring) -> f64 {
		t := (^Term_Cursor)(c)
		hit := Hit{frequency = postings.frequency(&t.reader), fields = postings.fields_of(&t.reader)}
		return leaf_score(s, &t.leaf, hit)
	},
	positions = proc(c: ^Cursor, out: ^[dynamic]u32) -> bool {
		t := (^Term_Cursor)(c)
		return postings.cursor_positions(&t.reader, t.position_fields, out)
	},
	block = proc(c: ^Cursor) -> []u32 {
		t := (^Term_Cursor)(c)
		return postings.block_docs(&t.reader)
	},
}

term_cursor_init :: proc(t: ^Term_Cursor, list: ^postings.List, deleted: ^roaring.Bitmap, required_fields: postings.Fields, leaf: Leaf, position_fields := postings.ALL_FIELDS, allocator := context.allocator) {
	postings.cursor_init(&t.reader, list, deleted, required_fields, allocator)
	t.base = Cursor{doc = 0, cost = postings.cost(&t.reader), ops = &TERM_OPS}
	t.leaf = leaf
	t.position_fields = position_fields
}

term_cursor_destroy :: proc(t: ^Term_Cursor) {
	postings.cursor_destroy(&t.reader)
}

Bitmap_Cursor :: struct {
	using base: Cursor,
	iterator:   roaring.Iterator,
	deleted:    ^roaring.Bitmap,
	leaf:       Leaf,
}

bitmap_next :: proc(c: ^Cursor) -> u32 {
	b := (^Bitmap_Cursor)(c)
	if b.doc == END {
		return END
	}
	for {
		x, ok := roaring.next(&b.iterator)
		if !ok {
			b.doc = END
			return END
		}
		if x != 0 && (b.deleted == nil || !roaring.contains(b.deleted, x)) {
			b.doc = x
			return x
		}
	}
}

BITMAP_OPS := Ops {
	next = bitmap_next,
	advance = proc(c: ^Cursor, target: u32) -> u32 {
		b := (^Bitmap_Cursor)(c)
		if b.doc != 0 && b.doc >= target {
			return b.doc
		}
		x, ok := roaring.advance(&b.iterator, max(target, 1))
		if !ok {
			b.doc = END
			return END
		}
		b.doc = x
		if b.deleted == nil || !roaring.contains(b.deleted, x) {
			return x
		}
		return bitmap_next(c)
	},
	score = proc(c: ^Cursor, s: ^Scoring) -> f64 {
		b := (^Bitmap_Cursor)(c)
		return leaf_score(s, &b.leaf, Hit{frequency = 1})
	},
}

bitmap_cursor_init :: proc(b: ^Bitmap_Cursor, bitmap: ^roaring.Bitmap, deleted: ^roaring.Bitmap, leaf: Leaf) {
	roaring.iterator_init(&b.iterator, bitmap)
	b.base = Cursor{doc = 0, cost = u64(roaring.cardinality(bitmap)), ops = &BITMAP_OPS}
	b.deleted = deleted
	if deleted != nil && roaring.is_empty(deleted) {
		b.deleted = nil
	}
	b.leaf = leaf
}

Array_Cursor :: struct {
	using base: Cursor,
	docs:       []u32,
	index:      int,
	deleted:    ^roaring.Bitmap,
	leaf:       Leaf,
}

array_settle :: proc(a: ^Array_Cursor) -> u32 {
	for a.index < len(a.docs) {
		d := a.docs[a.index]
		if d != 0 && (a.deleted == nil || !roaring.contains(a.deleted, d)) {
			a.doc = d
			return d
		}
		a.index += 1
	}
	a.doc = END
	return END
}

ARRAY_OPS := Ops {
	next = proc(c: ^Cursor) -> u32 {
		a := (^Array_Cursor)(c)
		if a.doc == END {
			return END
		}
		if a.doc != 0 {
			a.index += 1
		}
		return array_settle(a)
	},
	advance = proc(c: ^Cursor, target: u32) -> u32 {
		a := (^Array_Cursor)(c)
		if a.doc != 0 && a.doc >= target {
			return a.doc
		}
		a.index = sorted.gallop(a.docs, a.index, target)
		return array_settle(a)
	},
	score = proc(c: ^Cursor, s: ^Scoring) -> f64 {
		a := (^Array_Cursor)(c)
		return leaf_score(s, &a.leaf, Hit{frequency = 1})
	},
	block = proc(c: ^Cursor) -> []u32 {
		a := (^Array_Cursor)(c)
		if a.doc == END || a.doc == 0 {
			return nil
		}
		return a.docs[a.index:]
	},
}

array_cursor_init :: proc(a: ^Array_Cursor, docs: []u32, deleted: ^roaring.Bitmap, leaf: Leaf) {
	a.base = Cursor{doc = 0, cost = u64(len(docs)), ops = &ARRAY_OPS}
	a.docs = docs
	a.index = 0
	a.deleted = deleted
	if deleted != nil && roaring.is_empty(deleted) {
		a.deleted = nil
	}
	a.leaf = leaf
}

EMPTY_OPS := Ops {
	next = proc(c: ^Cursor) -> u32 {
		c.doc = END
		return END
	},
	advance = proc(c: ^Cursor, target: u32) -> u32 {
		c.doc = END
		return END
	},
}

empty_cursor :: proc "contextless" () -> Cursor {
	return Cursor{doc = 0, cost = 0, ops = &EMPTY_OPS}
}

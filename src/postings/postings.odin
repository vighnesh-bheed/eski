package postings

import "base:runtime"
import "core:math/bits"
import "../roaring"
import sv "../svbyte"

BLOCK :: 128

FIELD_WORDS_MAX :: 4

DOC_LIMIT :: max(u32) - 1

END :: max(u32)

Fields :: u128

ALL_FIELDS :: ~Fields(0)

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Out_Of_Order,
	Invalid_Posting,
}

Layout :: struct {
	field_words: u8,
	positions:   bool,
}

Posting :: struct {
	doc:       u32,
	frequency: u32,
	fields:    Fields,
	counts:    []u32,
	positions: []u32,
}

Block :: struct {
	last:          u32,
	offset:        u32,
	size:          u32,
	frequency_at:  u32,
	field_at:      u32,
	count_at:      u32,
	position_at:   u32,
	field_values:  u32,
	positions:     u32,
	max_frequency: u32,
	max_score:     f32,
	count:         u16,
}

List :: struct {
	blocks:     [dynamic]Block,
	data:       [dynamic]u8,
	tail:       [dynamic]u32,
	tail_count: u32,
	length:     u32,
	last:       u32,
	layout:     Layout,
}

Removed_Proc :: #type proc(ctx: rawptr, doc: u32)

layout_make :: proc "contextless" (text_fields: int, positions: bool) -> Layout {
	words := clamp((text_fields + 31) / 32, 1, FIELD_WORDS_MAX)
	return Layout{field_words = u8(words), positions = positions}
}

init :: proc(l: ^List, layout: Layout, allocator := context.allocator) {
	l^ = List{layout = layout}
	if l.layout.field_words == 0 {
		l.layout.field_words = 1
	}
	l.blocks = make([dynamic]Block, 0, 0, allocator)
	l.data = make([dynamic]u8, 0, 0, allocator)
	l.tail = make([dynamic]u32, 0, 0, allocator)
}

destroy :: proc(l: ^List) {
	delete(l.blocks)
	delete(l.data)
	delete(l.tail)
	l^ = List{}
}

length :: #force_inline proc "contextless" (l: ^List) -> int {
	return int(l.length)
}

last_doc :: #force_inline proc "contextless" (l: ^List) -> u32 {
	return l.last
}

bytes_used :: proc "contextless" (l: ^List) -> int {
	return size_of(List) + cap(l.blocks) * size_of(Block) + cap(l.data) + cap(l.tail) * size_of(u32)
}

encoded_bytes :: proc "contextless" (l: ^List) -> int {
	return len(l.blocks) * size_of(Block) + len(l.data) + len(l.tail) * size_of(u32)
}

mask_fits :: proc "contextless" (fields: Fields, words: u8) -> bool {
	if words >= 4 {
		return true
	}
	return fields >> (32 * uint(words)) == 0
}

field_count :: #force_inline proc "contextless" (fields: Fields) -> int {
	return int(bits.count_ones(u64(fields))) + int(bits.count_ones(u64(fields >> 64)))
}

validate :: proc "contextless" (l: ^List, p: ^Posting) -> Error {
	if p.doc == 0 || p.doc > DOC_LIMIT {
		return .Invalid_Posting
	}
	if l.length > 0 && p.doc <= l.last {
		return .Out_Of_Order
	}
	if !mask_fits(p.fields, l.layout.field_words) {
		return .Invalid_Posting
	}
	if !l.layout.positions {
		if len(p.positions) != 0 || len(p.counts) != 0 {
			return .Invalid_Posting
		}
		return .None
	}
	if len(p.counts) != field_count(p.fields) {
		return .Invalid_Posting
	}
	total := 0
	for c in p.counts {
		total += int(c)
	}
	if total != len(p.positions) {
		return .Invalid_Posting
	}
	for i in 1 ..< len(p.positions) {
		if p.positions[i] <= p.positions[i - 1] {
			return .Invalid_Posting
		}
	}
	return .None
}

append_posting :: proc(l: ^List, p: Posting) -> Error {
	p := p
	validate(l, &p) or_return
	words := int(l.layout.field_words)
	need := 2 + words
	if l.layout.positions {
		need += len(p.counts) + len(p.positions)
	}
	start := len(l.tail)
	if start + need > cap(l.tail) {
		if err := reserve(&l.tail, max(2 * cap(l.tail), start + need, 64)); err != nil {
			return .Out_Of_Memory
		}
	}
	if err := resize(&l.tail, start + need); err != nil {
		return .Out_Of_Memory
	}
	t := l.tail[start:]
	t[0] = p.doc
	t[1] = p.frequency
	for w in 0 ..< words {
		t[2 + w] = u32(p.fields >> (32 * uint(w)))
	}
	if l.layout.positions {
		at := 2 + words
		copy(t[at:], p.counts)
		copy(t[at + len(p.counts):], p.positions)
	}
	previous_last := l.last
	l.tail_count += 1
	l.length += 1
	l.last = p.doc
	if l.tail_count == BLOCK {
		if e := flush(l); e != .None {
			resize(&l.tail, start)
			l.tail_count -= 1
			l.length -= 1
			l.last = previous_last
			return e
		}
	}
	return .None
}

record_length :: proc "contextless" (l: ^List, tail: []u32, at: int) -> int #no_bounds_check {
	words := int(l.layout.field_words)
	n := 2 + words
	if !l.layout.positions {
		return n
	}
	mask := tail_mask(tail, at, words)
	fields := field_count(mask)
	total := 0
	for i in 0 ..< fields {
		total += int(tail[at + n + i])
	}
	return n + fields + total
}

tail_mask :: #force_inline proc "contextless" (tail: []u32, at: int, words: int) -> Fields #no_bounds_check {
	m := Fields(0)
	for w in 0 ..< words {
		m |= Fields(tail[at + 2 + w]) << (32 * uint(w))
	}
	return m
}

flush :: proc(l: ^List) -> Error #no_bounds_check {
	words := int(l.layout.field_words)
	n := int(l.tail_count)
	tail := l.tail[:]
	field_values, positions := 0, 0
	max_frequency := u32(0)
	at := 0
	for _ in 0 ..< n {
		max_frequency = max(max_frequency, tail[at + 1])
		if l.layout.positions {
			fields := field_count(tail_mask(tail, at, words))
			field_values += fields
			for i in 0 ..< fields {
				positions += int(tail[at + 2 + words + i])
			}
		}
		at += record_length(l, tail, at)
	}
	worst := sv.max_encoded(n) * (2 + words) + sv.max_encoded(field_values) + sv.max_encoded(positions)
	base := len(l.data)
	if base + worst > cap(l.data) {
		if err := reserve(&l.data, max(2 * cap(l.data), base + worst)); err != nil {
			return .Out_Of_Memory
		}
	}
	if err := resize(&l.data, base + worst); err != nil {
		return .Out_Of_Memory
	}
	out := l.data[base:]
	previous := u32(0)
	if len(l.blocks) > 0 {
		previous = l.blocks[len(l.blocks) - 1].last
	}
	b := Block{offset = u32(base), count = u16(n), max_frequency = max_frequency, field_values = u32(field_values), positions = u32(positions)}
	w: sv.Writer
	sv.writer_init(&w, out, n)
	at = 0
	for _ in 0 ..< n {
		sv.writer_put(&w, tail[at] - previous)
		previous = tail[at]
		at += record_length(l, tail, at)
	}
	b.last = previous
	cursor := w.pos
	b.frequency_at = u32(cursor)
	sv.writer_init(&w, out[cursor:], n)
	at = 0
	for _ in 0 ..< n {
		sv.writer_put(&w, tail[at + 1])
		at += record_length(l, tail, at)
	}
	cursor += w.pos
	b.field_at = u32(cursor)
	sv.writer_init(&w, out[cursor:], n * words)
	at = 0
	for _ in 0 ..< n {
		for k in 0 ..< words {
			sv.writer_put(&w, tail[at + 2 + k])
		}
		at += record_length(l, tail, at)
	}
	cursor += w.pos
	b.count_at = u32(cursor)
	if l.layout.positions {
		sv.writer_init(&w, out[cursor:], field_values)
		at = 0
		for _ in 0 ..< n {
			fields := field_count(tail_mask(tail, at, words))
			for i in 0 ..< fields {
				sv.writer_put(&w, tail[at + 2 + words + i])
			}
			at += record_length(l, tail, at)
		}
		cursor += w.pos
	}
	b.position_at = u32(cursor)
	if l.layout.positions {
		sv.writer_init(&w, out[cursor:], positions)
		at = 0
		for _ in 0 ..< n {
			fields := field_count(tail_mask(tail, at, words))
			total := 0
			for i in 0 ..< fields {
				total += int(tail[at + 2 + words + i])
			}
			from := at + 2 + words + fields
			prev := u32(0)
			for i in 0 ..< total {
				p := tail[from + i]
				sv.writer_put(&w, p - prev)
				prev = p
			}
			at += record_length(l, tail, at)
		}
		cursor += w.pos
	}
	b.size = u32(cursor)
	resize(&l.data, base + cursor)
	if _, err := append(&l.blocks, b); err != nil {
		resize(&l.data, base)
		return .Out_Of_Memory
	}
	runtime.clear(&l.tail)
	l.tail_count = 0
	return .None
}

collect :: proc(l: ^List, deleted: ^roaring.Bitmap, removed: Removed_Proc = nil, removed_ctx: rawptr = nil, scratch := context.allocator) -> (dropped: int, err: Error) {
	fresh: List
	init(&fresh, l.layout, l.blocks.allocator)
	c: Cursor
	cursor_init(&c, l, nil, 0, scratch)
	defer cursor_destroy(&c)
	counts := make([dynamic]u32, 0, 8, scratch)
	defer delete(counts)
	positions := make([dynamic]u32, 0, 16, scratch)
	defer delete(positions)
	for doc := next(&c); doc != END; doc = next(&c) {
		if roaring.contains(deleted, doc) {
			dropped += 1
			if removed != nil {
				removed(removed_ctx, doc)
			}
			continue
		}
		p := Posting{doc = doc, frequency = frequency(&c), fields = fields_of(&c)}
		if l.layout.positions {
			runtime.clear(&counts)
			runtime.clear(&positions)
			field_counts(&c, &counts)
			if !cursor_positions(&c, ALL_FIELDS, &positions) {
				destroy(&fresh)
				return 0, .Out_Of_Memory
			}
			p.counts = counts[:]
			p.positions = positions[:]
		}
		if e := append_posting(&fresh, p); e != .None {
			destroy(&fresh)
			return 0, e
		}
	}
	if dropped == 0 {
		destroy(&fresh)
		return 0, .None
	}
	destroy(l)
	l^ = fresh
	return dropped, .None
}

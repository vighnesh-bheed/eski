package postings

import "../roaring"
import "../sorted"
import sv "../svbyte"

Column :: enum u8 {
	Frequencies,
	Fields,
	Positions,
}

Cursor :: struct {
	list:           ^List,
	deleted:        ^roaring.Bitmap,
	required:       Fields,
	block:          int,
	index:          int,
	count:          int,
	doc:            u32,
	decoded:        bit_set[Column],
	docs:           [BLOCK]u32,
	frequencies:    [BLOCK]u32,
	records:        [BLOCK]u32,
	count_start:    [BLOCK + 1]u32,
	position_start: [BLOCK + 1]u32,
	masks:          [dynamic]u32,
	counts:         [dynamic]u32,
	positions:      [dynamic]u32,
}

cursor_init :: proc(c: ^Cursor, l: ^List, deleted: ^roaring.Bitmap, required: Fields, allocator := context.allocator) {
	c.list = l
	c.deleted = deleted
	if deleted != nil && roaring.is_empty(deleted) {
		c.deleted = nil
	}
	c.required = required
	c.block = -1
	c.index = 0
	c.count = 0
	c.doc = 0
	c.decoded = {}
	c.masks = make([dynamic]u32, 0, 0, allocator)
	c.counts = make([dynamic]u32, 0, 0, allocator)
	c.positions = make([dynamic]u32, 0, 0, allocator)
}

cursor_destroy :: proc(c: ^Cursor) {
	delete(c.masks)
	delete(c.counts)
	delete(c.positions)
	c.list = nil
}

cost :: proc "contextless" (c: ^Cursor) -> u64 {
	return u64(c.list.length)
}

block_last :: #force_inline proc "contextless" (c: ^Cursor) -> u32 {
	if c.block < len(c.list.blocks) {
		return c.list.blocks[c.block].last
	}
	return c.list.last
}

load :: proc(c: ^Cursor, b: int) -> bool #no_bounds_check {
	l := c.list
	nb := len(l.blocks)
	c.decoded = {}
	c.index = 0
	if b < nb {
		blk := &l.blocks[b]
		base := u32(0)
		if b > 0 {
			base = l.blocks[b - 1].last
		}
		n := int(blk.count)
		sv.decode_delta(l.data[blk.offset:], c.docs[:n], base)
		c.count = n
	} else if b == nb && l.tail_count > 0 {
		at := 0
		for i in 0 ..< int(l.tail_count) {
			c.records[i] = u32(at)
			c.docs[i] = l.tail[at]
			at += record_length(l, l.tail[:], at)
		}
		c.count = int(l.tail_count)
	} else {
		c.block = nb + 1
		c.count = 0
		c.doc = END
		return false
	}
	c.block = b
	return true
}

ensure_frequencies :: proc(c: ^Cursor) #no_bounds_check {
	if .Frequencies in c.decoded {
		return
	}
	l := c.list
	if c.block < len(l.blocks) {
		blk := &l.blocks[c.block]
		sv.decode(l.data[blk.offset + blk.frequency_at:], c.frequencies[:c.count])
	} else {
		for i in 0 ..< c.count {
			c.frequencies[i] = l.tail[c.records[i] + 1]
		}
	}
	c.decoded += {.Frequencies}
}

ensure_fields :: proc(c: ^Cursor) -> bool #no_bounds_check {
	if .Fields in c.decoded {
		return true
	}
	l := c.list
	words := int(l.layout.field_words)
	if err := resize(&c.masks, c.count * words); err != nil {
		return false
	}
	if c.block < len(l.blocks) {
		blk := &l.blocks[c.block]
		sv.decode(l.data[blk.offset + blk.field_at:], c.masks[:])
	} else {
		for i in 0 ..< c.count {
			for w in 0 ..< words {
				c.masks[i * words + w] = l.tail[int(c.records[i]) + 2 + w]
			}
		}
	}
	c.decoded += {.Fields}
	return true
}

mask_at :: #force_inline proc "contextless" (c: ^Cursor, i: int) -> Fields #no_bounds_check {
	words := int(c.list.layout.field_words)
	m := Fields(0)
	for w in 0 ..< words {
		m |= Fields(c.masks[i * words + w]) << (32 * uint(w))
	}
	return m
}

ensure_positions :: proc(c: ^Cursor) -> bool #no_bounds_check {
	if .Positions in c.decoded {
		return true
	}
	l := c.list
	if !l.layout.positions {
		return false
	}
	if c.block < len(l.blocks) {
		if !ensure_fields(c) {
			return false
		}
		blk := &l.blocks[c.block]
		if resize(&c.counts, int(blk.field_values)) != nil || resize(&c.positions, int(blk.positions)) != nil {
			return false
		}
		sv.decode(l.data[blk.offset + blk.count_at:], c.counts[:])
		sv.decode(l.data[blk.offset + blk.position_at:], c.positions[:])
		cs, ps := 0, 0
		for i in 0 ..< c.count {
			c.count_start[i] = u32(cs)
			c.position_start[i] = u32(ps)
			f := field_count(mask_at(c, i))
			total := 0
			for k in 0 ..< f {
				total += int(c.counts[cs + k])
			}
			acc := u32(0)
			for k in ps ..< ps + total {
				acc += c.positions[k]
				c.positions[k] = acc
			}
			cs += f
			ps += total
		}
		c.count_start[c.count] = u32(cs)
		c.position_start[c.count] = u32(ps)
	}
	c.decoded += {.Positions}
	return true
}

accept :: #force_inline proc(c: ^Cursor, d: u32) -> bool {
	if c.deleted != nil && roaring.contains(c.deleted, d) {
		return false
	}
	if c.required != 0 {
		if !ensure_fields(c) {
			return false
		}
		if mask_at(c, c.index) & c.required == 0 {
			return false
		}
	}
	return true
}

next :: proc(c: ^Cursor) -> u32 #no_bounds_check {
	if c.doc == END {
		return END
	}
	for {
		c.index += 1
		if c.index >= c.count {
			if !load(c, c.block + 1) {
				return END
			}
		}
		d := c.docs[c.index]
		if accept(c, d) {
			c.doc = d
			return d
		}
	}
}

advance :: proc(c: ^Cursor, target: u32) -> u32 #no_bounds_check {
	if c.doc != 0 && c.doc >= target {
		return c.doc
	}
	l := c.list
	nb := len(l.blocks)
	from := c.index
	if c.block < 0 || c.count == 0 || block_last(c) < target {
		lo := max(c.block, 0)
		hi := nb
		for lo < hi {
			mid := int(uint(lo + hi) >> 1)
			if l.blocks[mid].last < target {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo < nb {
			if lo != c.block {
				load(c, lo)
				from = 0
			}
		} else if l.tail_count > 0 && l.last >= target {
			if c.block != nb {
				load(c, nb)
				from = 0
			}
		} else {
			c.block = nb + 1
			c.count = 0
			c.doc = END
			return END
		}
	}
	c.index = sorted.gallop(c.docs[:c.count], from, target)
	d := c.docs[c.index]
	if accept(c, d) {
		c.doc = d
		return d
	}
	return next(c)
}

frequency :: proc(c: ^Cursor) -> u32 #no_bounds_check {
	ensure_frequencies(c)
	return c.frequencies[c.index]
}

fields_of :: proc(c: ^Cursor) -> Fields {
	if !ensure_fields(c) {
		return 0
	}
	return mask_at(c, c.index)
}

current :: proc(c: ^Cursor) -> (mask: Fields, counts: []u32, positions: []u32, ok: bool) #no_bounds_check {
	if !ensure_positions(c) {
		return
	}
	l := c.list
	words := int(l.layout.field_words)
	i := c.index
	if c.block < len(l.blocks) {
		mask = mask_at(c, i)
		counts = c.counts[c.count_start[i]:c.count_start[i + 1]]
		positions = c.positions[c.position_start[i]:c.position_start[i + 1]]
		return mask, counts, positions, true
	}
	at := int(c.records[i])
	mask = tail_mask(l.tail[:], at, words)
	f := field_count(mask)
	counts = l.tail[at + 2 + words:at + 2 + words + f]
	total := 0
	for k in counts {
		total += int(k)
	}
	from := at + 2 + words + f
	positions = l.tail[from:from + total]
	return mask, counts, positions, true
}

field_counts :: proc(c: ^Cursor, out: ^[dynamic]u32) -> bool {
	_, counts, _, ok := current(c)
	if !ok {
		return false
	}
	_, err := append(out, ..counts)
	return err == nil
}

cursor_positions :: proc(c: ^Cursor, wanted: Fields, out: ^[dynamic]u32) -> bool #no_bounds_check {
	mask, counts, positions, ok := current(c)
	if !ok {
		return false
	}
	if mask &~ wanted == 0 {
		_, err := append(out, ..positions)
		return err == nil
	}
	at := 0
	m := mask
	k := 0
	for m != 0 {
		bit := m & (~m + 1)
		n := int(counts[k])
		if bit & wanted != 0 {
			if _, err := append(out, ..positions[at:at + n]); err != nil {
				return false
			}
		}
		at += n
		k += 1
		m &~= bit
	}
	return true
}

block_docs :: proc "contextless" (c: ^Cursor) -> []u32 {
	if c.doc == END || c.count == 0 || c.index >= c.count {
		return nil
	}
	return c.docs[c.index:c.count]
}


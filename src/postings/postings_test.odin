package postings

import "core:testing"
import "../roaring"

Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ z >> 30) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ z >> 27) * 0x94D0_49BB_1331_11EB
	return z ~ z >> 31
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	return int(rng_next(r) % u64(n))
}

Shadow_Posting :: struct {
	doc:       u32,
	frequency: u32,
	fields:    Fields,
	counts:    [dynamic]u32,
	positions: [dynamic]u32,
}

Shadow :: struct {
	postings: [dynamic]Shadow_Posting,
}

shadow_destroy :: proc(s: ^Shadow) {
	for &p in s.postings {
		delete(p.counts)
		delete(p.positions)
	}
	delete(s.postings)
}

build_list :: proc(r: ^Rng, l: ^List, s: ^Shadow, n: int, layout: Layout, gap: int) {
	init(l, layout)
	doc := u32(0)
	field_bits := 32 * int(layout.field_words)
	for _ in 0 ..< n {
		doc += 1 + u32(rng_below(r, gap))
		sp := Shadow_Posting{doc = doc, frequency = u32(1 + rng_below(r, 300))}
		for sp.fields == 0 {
			for _ in 0 ..< 1 + rng_below(r, 3) {
				sp.fields |= Fields(1) << uint(rng_below(r, min(field_bits, 70)))
			}
		}
		if layout.positions {
			pos := u32(rng_below(r, 5))
			m := sp.fields
			for m != 0 {
				bit := m & (~m + 1)
				c := u32(rng_below(r, 4) + (1 if rng_below(r, 3) == 0 else 0))
				append(&sp.counts, c)
				for _ in 0 ..< c {
					pos += 1 + u32(rng_below(r, 1 << uint(rng_below(r, 17))))
					append(&sp.positions, pos)
				}
				m &~= bit
			}
		}
		p := Posting{doc = sp.doc, frequency = sp.frequency, fields = sp.fields, counts = sp.counts[:], positions = sp.positions[:]}
		e := append_posting(l, p)
		assert(e == .None)
		append(&s.postings, sp)
	}
}

expect_posting :: proc(t: ^testing.T, c: ^Cursor, sp: ^Shadow_Posting, layout: Layout) -> bool {
	if !testing.expect_value(t, c.doc, sp.doc) {
		return false
	}
	testing.expect_value(t, frequency(c), sp.frequency)
	testing.expect_value(t, fields_of(c), sp.fields)
	if !layout.positions {
		return true
	}
	all := make([dynamic]u32)
	defer delete(all)
	testing.expect(t, cursor_positions(c, ALL_FIELDS, &all))
	if !testing.expect_value(t, len(all), len(sp.positions)) {
		return false
	}
	for i in 0 ..< len(all) {
		if all[i] != sp.positions[i] {
			testing.expectf(t, false, "doc %d position %d is %d, want %d", sp.doc, i, all[i], sp.positions[i])
			return false
		}
	}
	counts := make([dynamic]u32)
	defer delete(counts)
	field_counts(c, &counts)
	testing.expect_value(t, len(counts), len(sp.counts))
	lowest := sp.fields & (~sp.fields + 1)
	some := make([dynamic]u32)
	defer delete(some)
	cursor_positions(c, lowest, &some)
	testing.expect_value(t, len(some), int(sp.counts[0]))
	for i in 0 ..< len(some) {
		testing.expect_value(t, some[i], sp.positions[i])
	}
	return true
}

layouts := [?]Layout{{field_words = 1, positions = true}, {field_words = 1, positions = false}, {field_words = 3, positions = true}}

@(test)
iteration_returns_every_posting :: proc(t: ^testing.T) {
	r := Rng{0x9057}
	for layout in layouts {
		for n in ([?]int{0, 1, 127, 128, 129, 300, 1000}) {
			l: List
			s: Shadow
			build_list(&r, &l, &s, n, layout, 1 + rng_below(&r, 50))
			testing.expect_value(t, length(&l), n)
			c: Cursor
			cursor_init(&c, &l, nil, 0)
			i := 0
			for d := next(&c); d != END; d = next(&c) {
				if !expect_posting(t, &c, &s.postings[i], layout) {
					break
				}
				i += 1
			}
			testing.expect_value(t, i, n)
			testing.expect_value(t, next(&c), END)
			cursor_destroy(&c)
			destroy(&l)
			shadow_destroy(&s)
		}
	}
}

@(test)
advance_lands_on_the_first_document_not_below :: proc(t: ^testing.T) {
	r := Rng{0xADA}
	for layout in layouts {
		for _ in 0 ..< 12 {
			l: List
			s: Shadow
			n := rng_below(&r, 3000)
			build_list(&r, &l, &s, n, layout, 1 + rng_below(&r, 400))
			c: Cursor
			cursor_init(&c, &l, nil, 0)
			pos := 0
			target := u32(0)
			for {
				target += u32(rng_below(&r, 1 << uint(rng_below(&r, 14))))
				for pos < len(s.postings) && s.postings[pos].doc < target {
					pos += 1
				}
				d := advance(&c, target)
				if pos == len(s.postings) {
					testing.expect_value(t, d, END)
					break
				}
				if !testing.expect_value(t, d, s.postings[pos].doc) {
					break
				}
				if rng_below(&r, 4) == 0 {
					expect_posting(t, &c, &s.postings[pos], layout)
				}
				if rng_below(&r, 3) == 0 {
					d = next(&c)
					pos += 1
					if pos == len(s.postings) {
						testing.expect_value(t, d, END)
						break
					}
					testing.expect_value(t, d, s.postings[pos].doc)
					target = d
				}
			}
			cursor_destroy(&c)
			destroy(&l)
			shadow_destroy(&s)
		}
	}
}

@(test)
deleted_and_field_filters_skip_postings :: proc(t: ^testing.T) {
	r := Rng{0xDE1}
	layout := Layout{field_words = 1, positions = true}
	l: List
	s: Shadow
	build_list(&r, &l, &s, 2000, layout, 7)
	defer destroy(&l)
	defer shadow_destroy(&s)
	deleted: roaring.Bitmap
	roaring.init(&deleted)
	defer roaring.destroy(&deleted)
	for p in s.postings {
		if rng_below(&r, 4) == 0 {
			roaring.add(&deleted, p.doc)
		}
	}
	required := Fields(0b101)
	c: Cursor
	cursor_init(&c, &l, &deleted, required)
	defer cursor_destroy(&c)
	want := make([dynamic]u32)
	defer delete(want)
	for p in s.postings {
		if !roaring.contains(&deleted, p.doc) && p.fields & required != 0 {
			append(&want, p.doc)
		}
	}
	i := 0
	for d := next(&c); d != END; d = next(&c) {
		testing.expect_value(t, d, want[i])
		i += 1
	}
	testing.expect_value(t, i, len(want))
	c2: Cursor
	cursor_init(&c2, &l, &deleted, required)
	defer cursor_destroy(&c2)
	for w in want {
		testing.expect_value(t, advance(&c2, w), w)
	}
	Counter :: struct {
		n: int,
	}
	counter := Counter{}
	removed := proc(ctx: rawptr, doc: u32) {
		(^Counter)(ctx).n += 1
	}
	before := length(&l)
	dropped, err := collect(&l, &deleted, removed, &counter)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, dropped, roaring.cardinality(&deleted))
	testing.expect_value(t, counter.n, dropped)
	testing.expect_value(t, length(&l), before - dropped)
	c3: Cursor
	cursor_init(&c3, &l, nil, 0)
	defer cursor_destroy(&c3)
	k := 0
	for &p in s.postings {
		if roaring.contains(&deleted, p.doc) {
			continue
		}
		testing.expect_value(t, next(&c3), p.doc)
		if !expect_posting(t, &c3, &p, layout) {
			break
		}
		k += 1
	}
	testing.expect_value(t, next(&c3), END)
	testing.expect_value(t, k, before - dropped)
}

@(test)
appends_reject_invalid_postings :: proc(t: ^testing.T) {
	l: List
	init(&l, Layout{field_words = 1, positions = true})
	defer destroy(&l)
	testing.expect_value(t, append_posting(&l, Posting{doc = 0, frequency = 1, fields = 1, counts = {1}, positions = {1}}), Error.Invalid_Posting)
	testing.expect_value(t, append_posting(&l, Posting{doc = 5, frequency = 1, fields = 1, counts = {1}, positions = {1}}), Error.None)
	testing.expect_value(t, append_posting(&l, Posting{doc = 5, frequency = 1, fields = 1, counts = {1}, positions = {1}}), Error.Out_Of_Order)
	testing.expect_value(t, append_posting(&l, Posting{doc = 6, frequency = 1, fields = 1, counts = {2}, positions = {3, 3}}), Error.Invalid_Posting)
	testing.expect_value(t, append_posting(&l, Posting{doc = 6, frequency = 1, fields = 3, counts = {1}, positions = {3}}), Error.Invalid_Posting)
	testing.expect_value(t, append_posting(&l, Posting{doc = 6, frequency = 1, fields = 1 << 40, counts = {1}, positions = {3}}), Error.Invalid_Posting)
	testing.expect_value(t, append_posting(&l, Posting{doc = max(u32), frequency = 1, fields = 1, counts = {1}, positions = {3}}), Error.Invalid_Posting)
	testing.expect_value(t, append_posting(&l, Posting{doc = 6, frequency = 2, fields = 3, counts = {1, 1}, positions = {3, 9}}), Error.None)
	testing.expect_value(t, length(&l), 2)
	plain: List
	init(&plain, Layout{field_words = 1})
	defer destroy(&plain)
	testing.expect_value(t, append_posting(&plain, Posting{doc = 1, frequency = 1, fields = 1, counts = {1}, positions = {1}}), Error.Invalid_Posting)
	testing.expect_value(t, append_posting(&plain, Posting{doc = 1, frequency = 1, fields = 1}), Error.None)
	c: Cursor
	cursor_init(&c, &plain, nil, 0)
	defer cursor_destroy(&c)
	next(&c)
	out := make([dynamic]u32)
	defer delete(out)
	testing.expect(t, !cursor_positions(&c, ALL_FIELDS, &out))
	testing.expect_value(t, layout_make(40, true).field_words, 2)
	testing.expect_value(t, layout_make(0, false).field_words, 1)
	testing.expect_value(t, layout_make(500, false).field_words, 4)
}

@(test)
cursors_handle_empty_lists_and_extreme_ids :: proc(t: ^testing.T) {
	l: List
	init(&l, Layout{field_words = 1})
	defer destroy(&l)
	c: Cursor
	cursor_init(&c, &l, nil, 0)
	testing.expect_value(t, next(&c), END)
	testing.expect_value(t, advance(&c, 5), END)
	cursor_destroy(&c)
	for d in ([?]u32{1, 2, DOC_LIMIT - 1, DOC_LIMIT}) {
		testing.expect_value(t, append_posting(&l, Posting{doc = d, frequency = 1, fields = 1}), Error.None)
	}
	cursor_init(&c, &l, nil, 0)
	defer cursor_destroy(&c)
	testing.expect_value(t, advance(&c, DOC_LIMIT - 1), DOC_LIMIT - 1)
	testing.expect_value(t, next(&c), DOC_LIMIT)
	testing.expect_value(t, next(&c), END)
	testing.expect_value(t, advance(&c, 3), END)
	big: List
	init(&big, Layout{field_words = 1})
	defer destroy(&big)
	for i in 0 ..< 3 * BLOCK {
		append_posting(&big, Posting{doc = u32(10 * i + 1), frequency = u32(i), fields = 1})
	}
	testing.expect_value(t, len(big.blocks), 3)
	testing.expect_value(t, big.blocks[1].max_frequency, u32(2 * BLOCK - 1))
	testing.expect_value(t, big.blocks[0].max_score, f32(0))
	b: Cursor
	cursor_init(&b, &big, nil, 0)
	defer cursor_destroy(&b)
	testing.expect_value(t, advance(&b, u32(10 * (2 * BLOCK) + 2)), u32(10 * (2 * BLOCK + 1) + 1))
	testing.expect_value(t, frequency(&b), u32(2 * BLOCK + 1))
	testing.expect_value(t, advance(&b, u32(10 * (3 * BLOCK))), END)
}

package ftindex

import "core:c/libc"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "../numindex"
import "../postings"
import "../termdict"

g17 :: proc(v: f64) -> string {
	buf: [64]u8
	n := libc.snprintf(raw_data(buf[:]), len(buf), "%.17g", v)
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

@(test)
tag_split_reproduces_the_recorded_tag_values :: proc(t: ^testing.T) {
	pieces: Tag_Pieces
	tag_pieces_init(&pieces)
	defer tag_pieces_destroy(&pieces)
	for g in TAG_GROUPS {
		seen := make([dynamic]string, context.temp_allocator)
		for v in g.values {
			tag_pieces_clear(&pieces)
			tag_split(&pieces, transmute([]u8)v, g.separator, g.case_sensitive, g.index_empty)
			for k in 0 ..< tag_piece_count(&pieces) {
				p := tag_piece(&pieces, k)
				if !slice.contains(seen[:], p) {
					append(&seen, strings.clone(p, context.temp_allocator))
				}
			}
		}
		slice.sort(seen[:])
		if !testing.expectf(t, len(seen) == len(g.want), "%s: %d values, want %d", g.name, len(seen), len(g.want)) {
			continue
		}
		for s, i in seen {
			testing.expectf(t, s == g.want[i], "%s: value %d is %q, want %q", g.name, i, s, g.want[i])
		}
		free_all(context.temp_allocator)
	}
}

@(test)
tag_split_drops_duplicates_and_honours_index_empty :: proc(t: ^testing.T) {
	pieces: Tag_Pieces
	tag_pieces_init(&pieces)
	defer tag_pieces_destroy(&pieces)
	tag_split(&pieces, transmute([]u8)string("A,a, A ,,b"), ',', false, false)
	testing.expect_value(t, tag_piece_count(&pieces), 2)
	testing.expect_value(t, tag_piece(&pieces, 0), "a")
	testing.expect_value(t, tag_piece(&pieces, 1), "b")
	tag_pieces_clear(&pieces)
	tag_split(&pieces, transmute([]u8)string("A,,a"), ',', true, true)
	testing.expect_value(t, tag_piece_count(&pieces), 3)
	testing.expect_value(t, tag_piece(&pieces, 1), "")
	testing.expect_value(t, tag_piece(&pieces, 2), "a")
	tag_pieces_clear(&pieces)
	tag_split(&pieces, nil, ',', false, true)
	testing.expect_value(t, tag_piece_count(&pieces), 1)
	testing.expect_value(t, tag_piece(&pieces, 0), "")
	tag_pieces_clear(&pieces)
	tag_split(&pieces, nil, ',', false, false)
	testing.expect_value(t, tag_piece_count(&pieces), 0)
}

@(test)
number_parse_accepts_and_rejects_the_recorded_forms :: proc(t: ^testing.T) {
	for c in NUMBER_CASES {
		v, ok := number_parse(c.text)
		if !testing.expectf(t, ok == c.accepted, "%q accepted %v, want %v", c.text, ok, c.accepted) || !ok {
			continue
		}
		testing.expectf(t, g17(v) == c.stored, "%q stored %s, want %s", c.text, g17(v), c.stored)
	}
	free_all(context.temp_allocator)
}

@(test)
range_bounds_follow_the_query_flags :: proc(t: ^testing.T) {
	lo, hi := range_bounds(1, 5, true, false)
	testing.expect(t, lo.exclusive && !hi.exclusive && lo.value == 1 && hi.value == 5)
	ix: numindex.Index
	numindex.init(&ix)
	defer numindex.destroy(&ix)
	for v, i in ([?]f64{1, 2, 5, 7, math.inf_f64(1), math.inf_f64(-1)}) {
		numindex.add(&ix, u32(i + 1), v)
	}
	docs := make([dynamic]u32, context.temp_allocator)
	lo, hi = range_bounds(1, 5, true, false)
	numindex.range_docs(&ix, lo, hi, &docs)
	testing.expect(t, slice.equal(docs[:], []u32{2, 3}))
	clear(&docs)
	lo, hi = range_bounds(math.inf_f64(-1), math.inf_f64(1), true, true)
	numindex.range_docs(&ix, lo, hi, &docs)
	testing.expect(t, slice.equal(docs[:], []u32{1, 2, 3, 4}))
	clear(&docs)
	lo, hi = range_bounds(5, 1, false, false)
	numindex.range_docs(&ix, lo, hi, &docs)
	testing.expect_value(t, len(docs), 0)
	free_all(context.temp_allocator)
}

@(test)
document_score_reproduces_the_recorded_score_field :: proc(t: ^testing.T) {
	for c in SCORE_CASES {
		got := document_score(c.text, true, 0.5)
		want, _ := strconv.parse_f64(c.want)
		testing.expectf(t, f64(got) == want, "%q scored %v, want %s", c.text, got, c.want)
	}
	testing.expect_value(t, document_score("", false, 0.25), f32(0.25))
}

term_postings :: proc(t: ^testing.T, ix: ^Index, term: string) -> (frequency: u32, fields: postings.Fields, positions: []u32, found: bool) {
	id, ok := termdict.lookup(&ix.terms, term)
	if !ok {
		return
	}
	c: postings.Cursor
	postings.cursor_init(&c, ix.lists[id], nil, 0, context.temp_allocator)
	if postings.next(&c) == postings.END {
		return
	}
	out := make([dynamic]u32, context.temp_allocator)
	postings.cursor_positions(&c, postings.ALL_FIELDS, &out)
	return postings.frequency(&c), postings.fields_of(&c), out[:], true
}

@(test)
text_analysis_weights_positions_and_stems :: proc(t: ^testing.T) {
	fields := [?]Field {
		{name = "t", source = "t", kind = .Text, weight = 2.5, separator = ','},
		{name = "g", source = "g", kind = .Tag, weight = 1, separator = ','},
		{name = "u", source = "u", kind = .Text, weight = 1, no_stem = true, separator = ','},
		{name = "v", source = "v", kind = .Text, weight = 0.5, index_empty = true, separator = ','},
		{name = "w", source = "w", kind = .Text, weight = 3, index_empty = true, separator = ','},
	}
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:])), Error.None)
	defer destroy(&ix)
	values := [?]Value{{"t", "Running dogs"}, {"g", "x"}, {"u", "running"}, {"v", "the cats"}, {"w", ""}}
	res, err := add(&ix, "k:1", values[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, res.id, 1)
	Want :: struct {
		term:      string,
		frequency: u32,
		fields:    postings.Fields,
		positions: []u32,
	}
	wants := [?]Want{{"running", 3, 0b011, {1, 3}}, {"+run", 1, 0b001, {1}}, {"dogs", 2, 0b001, {2}}, {"+dog", 1, 0b001, {2}}, {"cats", 1, 0b100, {4}}, {"+cat", 1, 0b100, {4}}, {"", 3, 0b1000, {5}}}
	for w in wants {
		f, m, p, ok := term_postings(t, &ix, w.term)
		if !testing.expectf(t, ok, "term %q missing", w.term) {
			continue
		}
		testing.expectf(t, f == w.frequency && m == w.fields && slice.equal(p, w.positions), "%q: frequency %d fields %b positions %v", w.term, f, m, p)
	}
	d := document_of(&ix, 1) or_else {}
	testing.expect_value(t, d.length, 2 * 2 + 1 + 1 + 3)
	_, found := termdict.lookup(&ix.terms, "the")
	testing.expect(t, !found)
	inf := info(&ix)
	testing.expect_value(t, inf.num_terms, 6)
	testing.expect_value(t, inf.num_records, 7 + 1)
	free_all(context.temp_allocator)
}

@(test)
language_field_falls_back_and_stop_lists_apply :: proc(t: ^testing.T) {
	fields := [?]Field{field_default("t", .Text)}
	def := definition_default(fields[:])
	def.language_field = "lang"
	ix: Index
	testing.expect_value(t, init(&ix, def), Error.None)
	add(&ix, "a", []Value{{"t", "running"}, {"lang", "klingon"}})
	add(&ix, "b", []Value{{"t", "running"}, {"lang", "German"}})
	add(&ix, "c", []Value{{"t", "running"}, {"lang", ""}})
	f, _, _, ok := term_postings(t, &ix, "+run")
	testing.expect(t, ok && f == 1)
	id, _ := termdict.lookup(&ix.terms, "+run")
	testing.expect_value(t, postings.length(ix.lists[id]), 2)
	destroy(&ix)
	none := definition_default(fields[:])
	none.stop_mode = .None
	testing.expect_value(t, init(&ix, none), Error.None)
	add(&ix, "a", []Value{{"t", "the fox"}})
	_, _, p, the := term_postings(t, &ix, "the")
	testing.expect(t, the && slice.equal(p, []u32{1}))
	destroy(&ix)
	custom := definition_default(fields[:])
	custom.stop_mode = .Custom
	custom.stop_words = []string{"Fox"}
	testing.expect_value(t, init(&ix, custom), Error.None)
	add(&ix, "a", []Value{{"t", "the fox dog"}})
	_, _, p2, the2 := term_postings(t, &ix, "the")
	_, _, _, fox := term_postings(t, &ix, "fox")
	_, _, p3, _ := term_postings(t, &ix, "dog")
	testing.expect(t, the2 && !fox && slice.equal(p2, []u32{1}) && slice.equal(p3, []u32{2}))
	destroy(&ix)
	free_all(context.temp_allocator)
}

@(test)
failed_documents_take_no_id_and_drop_the_previous_version :: proc(t: ^testing.T) {
	fields := [?]Field {
		{name = "t", source = "t", kind = .Text, weight = 1, separator = ','},
		{name = "n", source = "n", kind = .Numeric, weight = 1, separator = ','},
		{name = "v", source = "v", kind = .Vector, weight = 1, separator = ',', vector = {method = .Hnsw, elem = .F32, metric = .L2, dim = 2}},
	}
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:])), Error.None)
	defer destroy(&ix)
	v := [2]f32{1, 0}
	blob := string(([^]u8)(&v)[:8])
	r1, _ := add(&ix, "k", []Value{{"t", "hello"}, {"n", "1"}, {"v", blob}})
	testing.expect_value(t, r1.outcome, Outcome.Indexed)
	r2, _ := add(&ix, "k", []Value{{"t", "hello"}, {"n", "abc"}})
	testing.expect_value(t, r2.outcome, Outcome.Rejected)
	testing.expect_value(t, r2.replaced, 1)
	inf := info(&ix)
	testing.expect_value(t, inf.num_docs, 0)
	testing.expect_value(t, inf.max_doc_id, 1)
	testing.expect_value(t, inf.hash_indexing_failures, 1)
	testing.expect_value(t, inf.last_error, "SEARCH_NUMERIC_VALUE_INVALID Invalid numeric value: 'abc'")
	testing.expect_value(t, vector_count(&ix, 2), 0)
	r3, _ := add(&ix, "j", []Value{{"v", blob[:4]}})
	testing.expect_value(t, r3.outcome, Outcome.Rejected)
	testing.expect_value(t, field_errors(&ix, 2).last_error, "SEARCH_VECTOR_BLOB_SIZE_MISMATCH Could not add vector with blob size 4 (expected size 8)")
	r4, _ := add(&ix, "j", []Value{{"v", blob}})
	testing.expect_value(t, r4.id, 2)
	reject(&ix, "j")
	inf = info(&ix)
	testing.expect_value(t, inf.hash_indexing_failures, 3)
	testing.expect_value(t, inf.num_docs, 0)
	removed, _ := collect(&ix)
	testing.expect_value(t, removed, 2)
	inf = info(&ix)
	testing.expect_value(t, inf.num_terms, 0)
	testing.expect_value(t, inf.num_records, 0)
}

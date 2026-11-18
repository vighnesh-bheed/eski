package ftindex

import ftq "../ftquery"
import "../doctable"
import "../label"
import "../postings"
import "../prefix"
import "../retrieve"
import "../roaring"
import "../termdict"
import "../termstats"
import "../text"

Document_Accept :: #type proc(ctx: rawptr, ix: ^Index, id: u32, key: string) -> bool

Deadline_Check :: #type proc(ctx: rawptr) -> bool

Execution_View :: struct {
	indexes:   []^Index,
	ctx:       rawptr,
	accept:    Document_Accept,
	payload:   Payload_Proc,
	timed_out: Deadline_Check,
}

view_indexes :: proc(opts: ^Execute_Options) -> []^Index {
	return opts.view.indexes if opts.view != nil else nil
}

view_includes :: proc(indexes: []^Index, ix: ^Index) -> bool {
	if indexes == nil {
		return true
	}
	for other in indexes {
		if other == ix {
			return true
		}
	}
	return false
}

view_has_live_counts :: proc(indexes: []^Index, visibility: ^label.Visibility) -> bool {
	for ix in indexes {
		if ix == nil || ix.live_terms != nil || roaring.is_empty(&ix.docs.deleted) {
			continue
		}
		if visibility == nil {
			return false
		}
		it: roaring.Iterator
		roaring.iterator_init(&it, &ix.docs.deleted)
		for id, ok := roaring.next(&it); ok; id, ok = roaring.next(&it) {
			if doc := doctable.slot(&ix.docs, id); doc != nil && label.visible(visibility, doc.label) {
				return false
			}
		}
	}
	return true
}

execution_timed_out :: proc(opts: ^Execute_Options) -> bool {
	view := opts.view
	return view != nil && view.timed_out != nil && view.timed_out(view.ctx)
}

check_deadline :: proc(b: ^Builder) -> bool {
	if b.err != .None {
		return false
	}
	if execution_timed_out(b.opts) {
		fail(b, .Timeout)
		return false
	}
	return true
}

execution_accepts :: proc(ix: ^Index, opts: ^Execute_Options, id: u32, doc: ^doctable.Doc) -> bool {
	if doc == nil || (opts.visibility != nil && !label.visible(opts.visibility, doc.label)) {
		return false
	}
	view := opts.view
	return view == nil || view.accept == nil || view.accept(view.ctx, ix, id, doc.key)
}

scoring_document :: proc(doc: ^doctable.Doc, id: u32) -> retrieve.Document {
	return {id = id, length = doc.length, max_frequency = doc.max_frequency, score = doc.score}
}

view_collection :: proc(ix: ^Index, opts: ^Execute_Options) -> retrieve.Collection {
	indexes := view_indexes(opts)
	if indexes == nil {
		return collection_of(ix, opts.visibility)
	}
	out: retrieve.Collection
	for other in indexes {
		if other != nil {
			total := collection_of(other, opts.visibility)
			out.documents += total.documents
			out.total_length += total.total_length
		}
	}
	return out
}

TEXT_DICTIONARY :: -1

Term_Dictionary :: struct {
	dict:  ^termdict.Dictionary,
	stats: ^termstats.Stats,
}

term_dictionary :: proc(ix: ^Index, field: int) -> Term_Dictionary {
	if ix == nil {
		return {}
	}
	if field == TEXT_DICTIONARY {
		return {&ix.terms, &ix.stats}
	}
	if field >= 0 && field < len(ix.slots) {
		if tag := ix.slots[field].tag; tag != nil {
			return {&tag.values.values, &tag.stats}
		}
	}
	return {}
}

view_dictionary :: proc(local, other: ^Index, field: int) -> Term_Dictionary {
	if other == nil {
		return {}
	}
	if field >= 0 && (field >= len(other.slots) || local.definition.fields[field].name != other.definition.fields[field].name) {
		return {}
	}
	return term_dictionary(other, field)
}

dictionary_count :: proc "contextless" (stats: ^termstats.Stats, id: termdict.Id, visibility: ^label.Visibility) -> u64 {
	if visibility != nil {
		return termstats.term_visible(stats, u32(id), visibility)
	}
	return termstats.term_total(stats, u32(id))
}

term_frequency_in_view :: proc(b: ^Builder, field: int, local: Term_Dictionary, id: termdict.Id) -> (count: u64, present: bool) {
	visibility := b.opts.visibility
	indexes := view_indexes(b.opts)
	count = dictionary_count(local.stats, id, visibility)
	if count == 0 && (visibility != nil || indexes != nil) {
		return 0, false
	}
	if indexes == nil {
		return count, true
	}
	word, found := termdict.text(local.dict, id)
	if !found {
		return count, true
	}
	for other in indexes {
		if other == b.ix {
			continue
		}
		if !check_deadline(b) {
			return 0, false
		}
		dictionary := view_dictionary(b.ix, other, field)
		if dictionary.dict != nil {
			if other_id, exists := termdict.lookup(dictionary.dict, word); exists {
				count += dictionary_count(dictionary.stats, other_id, visibility)
			}
		}
	}
	return count, true
}

Prefix_Stream :: struct {
	it:    termdict.Iterator,
	stats: ^termstats.Stats,
	term:  string,
	id:    termdict.Id,
	ready: bool,
}

prefix_stream_advance :: proc(b: ^Builder, stream: ^Prefix_Stream, pattern: ^Pattern, trie: ^[dynamic]u8) {
	stream.ready = false
	for check_deadline(b) {
		term, id, ok := termdict.iterator_next(&stream.it)
		if !ok {
			return
		}
		if !pattern_matches(pattern, term) {
			if pattern.node.kind == .Prefix {
				return
			}
			continue
		}
		if dictionary_count(stream.stats, id, b.opts.visibility) == 0 {
			continue
		}
		if trie != nil {
			clear(trie)
			if reserve(trie, len(term)) != nil {
				fail(b, .Out_Of_Memory)
				return
			}
			text.trie_form(transmute([]u8)term, trie)
			if string(trie^[:]) != term {
				continue
			}
		}
		stream.term, stream.id, stream.ready = term, id, true
		return
	}
}

merged_pattern :: proc(b: ^Builder, n: ^ftq.Node, field: int) -> []termdict.Id {
	if !pattern_eligible(n, b.opts.minimum_pattern.? or_else prefix.MIN_LENGTH) {
		return nil
	}
	requested := mask_fields(n.mask)
	if field == TEXT_DICTIONARY && (n.kind == .Suffix || n.kind == .Infix || n.kind == .Wildcard_Pattern) {
		allowed: postings.Fields
		for slot, i in b.ix.text_fields {
			if b.ix.definition.fields[slot].suffix_trie {
				allowed |= postings.Fields(1) << uint(i)
			}
		}
		if allowed != 0 && requested & ~allowed != 0 {
			b.query_err = ftq.Error{code = .Generic, message = "Contains query on fields without WITHSUFFIXTRIE support"}
			fail(b, .Query_Error)
			return nil
		}
	}
	pattern := pattern_init(b, n)
	single := [1]^Index{b.ix}
	indexes := view_indexes(b.opts)
	if indexes == nil {
		indexes = single[:]
	}
	streams, err := make([]Prefix_Stream, len(indexes), b.a)
	if err != nil || len(streams) != len(indexes) {
		fail(b, .Out_Of_Memory)
		return nil
	}
	defer for &stream in streams {
		termdict.iterator_close(&stream.it)
	}
	normalized: [dynamic]u8
	normalized.allocator = b.a
	trie := &normalized if field == TEXT_DICTIONARY else nil
	local := -1
	for ix, i in indexes {
		source := view_dictionary(b.ix, ix, field)
		if source.dict == nil {
			continue
		}
		stream := &streams[i]
		stream.stats = source.stats
		termdict.iterator_seek(&stream.it, source.dict, n.text if n.kind == .Prefix else "")
		prefix_stream_advance(b, stream, &pattern, trie)
		if b.err != .None {
			return nil
		}
		if ix == b.ix {
			local = i
		}
	}

	ids := make([dynamic]termdict.Id, b.a)
	for count := 0; check_deadline(b); count += 1 {
		first := -1
		for &stream, i in streams {
			if stream.ready && (first < 0 || stream.term < streams[first].term) {
				first = i
			}
		}
		if first < 0 {
			break
		}
		if b.expand >= 0 && count >= b.expand {
			b.result.truncated = true
			break
		}
		term := streams[first].term
		if local >= 0 && streams[local].ready && streams[local].term == term {
			if _, e := append(&ids, streams[local].id); e != nil {
				fail(b, .Out_Of_Memory)
				return nil
			}
		}
		for &stream in streams {
			if stream.ready && stream.term == term {
				prefix_stream_advance(b, &stream, &pattern, trie)
				if b.err != .None {
					return nil
				}
			}
		}
	}
	return ids[:]
}

package ftindex

import "base:runtime"
import "core:fmt"
import "core:strings"
import "../doctable"
import "../label"
import "../numindex"
import "../postings"
import "../roaring"
import "../tagindex"
import "../termdict"
import "../termstats"
import "../text"

Value :: struct {
	name:  string,
	value: string,
}

Outcome :: enum u8 {
	Indexed,
	Rejected,
}

Added :: struct {
	outcome:  Outcome,
	id:       u32,
	replaced: u32,
}

Occurrence :: struct {
	term:     u32,
	field:    u32,
	position: u32,
	stem:     bool,
}

Work :: struct {
	terms:       text.Terms,
	table:       map[string]u32,
	texts:       [dynamic]string,
	occurrences: [dynamic]Occurrence,
	sorted:      [dynamic]Occurrence,
	starts:      [dynamic]u32,
	fill:        [dynamic]u32,
	counts:      [dynamic]u32,
	positions:   [dynamic]u32,
	trie:        [dynamic]u8,
	tags:        Tag_Pieces,
	found:       [dynamic]int,
	numbers:     [dynamic]f64,
	tag_ids:     [dynamic]termdict.Id,
}

work_init :: proc(w: ^Work, allocator: runtime.Allocator) {
	text.terms_init(&w.terms, allocator)
	w.table = make(map[string]u32, 64, allocator)
	w.texts = make([dynamic]string, allocator)
	w.occurrences = make([dynamic]Occurrence, allocator)
	w.sorted = make([dynamic]Occurrence, allocator)
	w.starts = make([dynamic]u32, allocator)
	w.fill = make([dynamic]u32, allocator)
	w.counts = make([dynamic]u32, allocator)
	w.positions = make([dynamic]u32, allocator)
	w.trie = make([dynamic]u8, allocator)
	tag_pieces_init(&w.tags, allocator)
	w.found = make([dynamic]int, allocator)
	w.numbers = make([dynamic]f64, allocator)
	w.tag_ids = make([dynamic]termdict.Id, allocator)
}

work_destroy :: proc(w: ^Work) {
	text.terms_destroy(&w.terms)
	delete(w.table)
	delete(w.texts)
	delete(w.occurrences)
	delete(w.sorted)
	delete(w.starts)
	delete(w.fill)
	delete(w.counts)
	delete(w.positions)
	delete(w.trie)
	tag_pieces_destroy(&w.tags)
	delete(w.found)
	delete(w.numbers)
	delete(w.tag_ids)
}

work_reset :: proc(w: ^Work) {
	text.terms_clear(&w.terms)
	clear(&w.table)
	clear(&w.texts)
	clear(&w.occurrences)
	clear(&w.sorted)
	clear(&w.starts)
	clear(&w.counts)
	clear(&w.positions)
}

find_value :: proc "contextless" (values: []Value, name: string) -> int {
	for v, i in values {
		if v.name == name {
			return i
		}
	}
	return -1
}

set_error :: proc(e: ^Field_Errors, message: string, key: string, allocator: runtime.Allocator) {
	e.failures += 1
	delete(e.last_error, allocator)
	delete(e.last_key, allocator)
	e.last_error = strings.clone(message, allocator)
	e.last_key = strings.clone(key, allocator)
}

reject_field :: proc(ix: ^Index, field: int, key: string, message: string) {
	set_error(&ix.slots[field].errors, message, key, ix.allocator)
	set_error(&ix.errors, message, key, ix.allocator)
}

validate :: proc(ix: ^Index, key: string, values: []Value) -> bool {
	w := &ix.work
	clear(&w.found)
	clear(&w.numbers)
	for f, i in ix.definition.fields {
		at := find_value(values, f.source)
		append(&w.found, at)
		append(&w.numbers, 0)
		if at < 0 || f.no_index {
			continue
		}
		#partial switch f.kind {
		case .Numeric:
			v, ok := number_parse(values[at].value)
			if !ok {
				reject_field(ix, i, key, fmt.tprintf("SEARCH_NUMERIC_VALUE_INVALID Invalid numeric value: '%s'", values[at].value))
				return false
			}
			w.numbers[i] = v
		case .Vector:
			want := f.vector.dim * vector_elem_size(f.vector.elem)
			if len(values[at].value) != want {
				reject_field(ix, i, key, fmt.tprintf("SEARCH_VECTOR_BLOB_SIZE_MISMATCH Could not add vector with blob size %d (expected size %d)", len(values[at].value), want))
				return false
			}
		}
	}
	return true
}

term_slot :: proc(w: ^Work, bytes: []u8) -> u32 {
	s := string(bytes)
	if at, ok := w.table[s]; ok {
		return at
	}
	at := u32(len(w.texts))
	append(&w.texts, s)
	w.table[s] = at
	return at
}

Analysis :: struct {
	length:        u32,
	max_frequency: u32,
	language:      text.Language,
}

analyze_document :: proc(ix: ^Index, values: []Value) -> (a: Analysis) {
	w := &ix.work
	work_reset(w)
	def := &ix.definition
	a.language = def.language
	if len(def.language_field) > 0 {
		at := find_value(values, def.language_field)
		a.language = document_language(values[at].value if at >= 0 else "", at >= 0, def.language)
	}
	position := u32(0)
	length := u64(0)
	for field, ordinal in ix.text_fields {
		f := &def.fields[field]
		at := w.found[field]
		if at < 0 || f.no_index {
			continue
		}
		weight := frequency_weight(f.weight)
		raw := transmute([]u8)values[at].value
		if len(raw) == 0 {
			if f.index_empty {
				position += 1
				length += u64(weight)
				slot := term_slot(w, raw)
				append(&w.occurrences, Occurrence{term = slot, field = u32(ordinal), position = position})
			}
			continue
		}
		first := len(w.terms.list)
		position = text.analyze(&ix.analyzer, raw, text.Field{language = a.language, stem = !f.no_stem, base = position}, &w.terms)
		for term in w.terms.list[first:] {
			bytes := text.term_bytes(&w.terms, term)
			if term.kind == .Original {
				length += u64(weight)
				if len(bytes) == 0 {
					continue
				}
			}
			slot := term_slot(w, bytes)
			append(&w.occurrences, Occurrence{term = slot, field = u32(ordinal), position = term.position, stem = term.kind == .Stem})
		}
	}
	a.length = u32(min(length, u64(max(u32))))
	group_occurrences(ix)
	for i in 0 ..< len(w.texts) {
		f := term_frequency(ix, i)
		a.max_frequency = max(a.max_frequency, f)
	}
	return a
}

group_occurrences :: proc(ix: ^Index) {
	w := &ix.work
	n := len(w.texts)
	resize(&w.starts, n + 1)
	for &s in w.starts {
		s = 0
	}
	for o in w.occurrences {
		w.starts[o.term + 1] += 1
	}
	for i in 1 ..= n {
		w.starts[i] += w.starts[i - 1]
	}
	resize(&w.sorted, len(w.occurrences))
	resize(&w.fill, n)
	copy(w.fill[:], w.starts[:n])
	for o in w.occurrences {
		w.sorted[w.fill[o.term]] = o
		w.fill[o.term] += 1
	}
}

term_run :: proc "contextless" (ix: ^Index, term: int) -> []Occurrence {
	w := &ix.work
	return w.sorted[w.starts[term]:w.starts[term + 1]]
}

term_frequency :: proc(ix: ^Index, term: int) -> u32 {
	total := u64(0)
	for o in term_run(ix, term) {
		if o.stem {
			total += 1
			continue
		}
		field := ix.text_fields[o.field]
		total += u64(frequency_weight(ix.definition.fields[field].weight))
	}
	return u32(min(total, u64(max(u32))))
}

term_posting :: proc(ix: ^Index, term: int, doc: u32) -> postings.Posting {
	w := &ix.work
	clear(&w.counts)
	clear(&w.positions)
	run := term_run(ix, term)
	mask := postings.Fields(0)
	last := max(u32)
	for o in run {
		if o.field != last {
			mask |= postings.Fields(1) << o.field
			append(&w.counts, 0)
			last = o.field
		}
		w.counts[len(w.counts) - 1] += 1
		append(&w.positions, o.position)
	}
	return postings.Posting{doc = doc, frequency = term_frequency(ix, term), fields = mask, counts = w.counts[:], positions = w.positions[:]}
}

listed_term :: proc(w: ^Work, term: string) -> bool {
	if len(term) == 0 {
		return false
	}
	clear(&w.trie)
	return text.trie_form(transmute([]u8)term, &w.trie)
}

ensure_list :: proc(ix: ^Index, id: termdict.Id) -> (^postings.List, Error) {
	for int(id) >= len(ix.lists) {
		if _, e := append(&ix.lists, nil); e != nil {
			return nil, .Out_Of_Memory
		}
		if _, e := append(&ix.term_fields, 0); e != nil {
			return nil, .Out_Of_Memory
		}
	}
	if ix.lists[id] == nil {
		l, e := new(postings.List, ix.allocator)
		if e != nil {
			return nil, .Out_Of_Memory
		}
		postings.init(l, ix.layout, ix.allocator)
		ix.lists[id] = l
	}
	return ix.lists[id], .None
}

add :: proc(ix: ^Index, key: string, values: []Value, doc_label := label.BOTTOM_ID) -> (result: Added, err: Error) {
	if !validate(ix, key, values) {
		result.outcome = .Rejected
		result.replaced = drop_key(ix, key)
		return result, .None
	}
	a := analyze_document(ix, values)
	def := &ix.definition
	score := def.score
	if len(def.score_field) > 0 {
		at := find_value(values, def.score_field)
		score = document_score(values[at].value if at >= 0 else "", at >= 0, def.score)
	}
	id, replaced, de := doctable.add(&ix.docs, key, doctable.Fields{length = a.length, max_frequency = a.max_frequency, score = score, label = doc_label})
	switch de {
	case .None:
	case .Out_Of_Memory:
		return result, .Out_Of_Memory
	case .Ids_Exhausted:
		return result, .Ids_Exhausted
	case .Not_Found:
		return result, .Invalid_Definition
	}
	result.id = id
	result.replaced = replaced
	if replaced != 0 {
		forget_document(ix, replaced)
	}
	if termstats.document_add(&ix.stats, doc_label, a.length) != .None {
		return result, .Out_Of_Memory
	}
	w := &ix.work
	for t, i in w.texts {
		tid, _, te := termdict.insert(&ix.terms, t, listed_term(w, t))
		switch te {
		case .None:
		case .Out_Of_Memory:
			return result, .Out_Of_Memory
		case .Too_Many_Terms:
			return result, .Too_Many_Terms
		}
		list := ensure_list(ix, tid) or_return
		posting := term_posting(ix, i, id)
		if postings.append_posting(list, posting) != .None {
			return result, .Out_Of_Memory
		}
		ix.term_fields[tid] |= posting.fields
		if termstats.term_add(&ix.stats, u32(tid), doc_label) != .None {
			return result, .Out_Of_Memory
		}
		ix.records += 1
	}
	for &f, i in def.fields {
		s := &ix.slots[i]
		at := w.found[i]
		if at < 0 {
			if f.index_missing {
				roaring.add(&s.missing, id)
			}
			continue
		}
		if f.no_index {
			continue
		}
		#partial switch f.kind {
		case .Tag:
			tag_pieces_clear(&w.tags)
			tag_split(&w.tags, transmute([]u8)values[at].value, f.separator, f.case_sensitive, f.index_empty)
			for k in 0 ..< tag_piece_count(&w.tags) {
				vid, te := tagindex.add(&s.tag.values, tag_piece(&w.tags, k), id)
				if te != .None {
					return result, .Out_Of_Memory
				}
				if termstats.term_add(&s.tag.stats, u32(vid), doc_label) != .None {
					return result, .Out_Of_Memory
				}
				ix.records += 1
			}
		case .Numeric:
			if _, ne := numindex.add(s.numbers, id, w.numbers[i]); ne != .None {
				return result, .Out_Of_Memory
			}
			ix.records += 1
		case .Vector:
			if s.vector.add(s.vector.ctx, id, transmute([]u8)values[at].value) != .None {
				return result, .Vector_Source
			}
		}
	}
	return result, .None
}

forget_document :: proc(ix: ^Index, id: u32) {
	d := doctable.slot(&ix.docs, id)
	if d == nil {
		return
	}
	termstats.document_remove(&ix.stats, d.label, d.length)
	for &s in ix.slots {
		if s.vector != nil {
			s.vector.remove(s.vector.ctx, id)
		}
	}
}

drop_key :: proc(ix: ^Index, key: string) -> u32 {
	id, err := doctable.remove(&ix.docs, key)
	if err != .None {
		return 0
	}
	forget_document(ix, id)
	return id
}

remove :: proc(ix: ^Index, key: string) -> (id: u32, found: bool) {
	id = drop_key(ix, key)
	return id, id != 0
}

reject :: proc(ix: ^Index, key: string) -> (id: u32, found: bool) {
	ix.errors.failures += 1
	return remove(ix, key)
}

rename :: proc(ix: ^Index, from, to: string) -> (id: u32, found: bool) {
	if other, had := doctable.lookup(&ix.docs, to); had && from != to {
		if _, live := doctable.lookup(&ix.docs, from); live {
			forget_document(ix, other)
		}
	}
	rid, _, err := doctable.rename(&ix.docs, from, to)
	return rid, err == .None
}

lookup :: proc(ix: ^Index, key: string) -> (u32, bool) {
	return doctable.lookup(&ix.docs, key)
}

list_fields :: proc(l: ^postings.List) -> postings.Fields {
	c: postings.Cursor
	postings.cursor_init(&c, l, nil, 0, context.temp_allocator)
	defer postings.cursor_destroy(&c)
	mask := postings.Fields(0)
	for d := postings.next(&c); d != postings.END; d = postings.next(&c) {
		mask |= postings.fields_of(&c)
	}
	return mask
}

Collect_Context :: struct {
	ix:    ^Index,
	term:  u32,
	stats: ^termstats.Stats,
}

collect :: proc(ix: ^Index) -> (removed: int, err: Error) {
	deleted := &ix.docs.deleted
	if roaring.is_empty(deleted) {
		return 0, .None
	}
	for l, tid in ix.lists {
		if l == nil {
			continue
		}
		ctx := Collect_Context{ix = ix, term = u32(tid), stats = &ix.stats}
		dropped, ce := postings.collect(l, deleted, proc(ctx: rawptr, doc: u32) {
			x := (^Collect_Context)(ctx)
			d := doctable.slot(&x.ix.docs, doc)
			if d != nil {
				termstats.term_remove(x.stats, x.term, d.label)
			}
		}, &ctx)
		if ce != .None {
			return removed, .Out_Of_Memory
		}
		ix.records -= dropped
		if postings.length(l) == 0 {
			termdict.remove(&ix.terms, termdict.Id(tid))
			termstats.term_forget(&ix.stats, u32(tid))
			postings.destroy(l)
			free(l, ix.allocator)
			ix.lists[tid] = nil
			ix.term_fields[tid] = 0
		} else if dropped > 0 {
			ix.term_fields[tid] = list_fields(l)
		}
	}
	for &s in ix.slots {
		if s.tag != nil {
			ctx := Collect_Context{ix = ix, stats = &s.tag.stats}
			dropped, te := tagindex.collect(&s.tag.values, deleted, proc(ctx: rawptr, value: termdict.Id, doc: u32) {
				x := (^Collect_Context)(ctx)
				d := doctable.slot(&x.ix.docs, doc)
				if d != nil {
					termstats.term_remove(x.stats, u32(value), d.label)
				}
			}, &ctx)
			if te != .None {
				return removed, .Out_Of_Memory
			}
			ix.records -= dropped
		}
		if s.numbers != nil {
			ix.records -= numindex.collect(s.numbers, deleted)
		}
		if !roaring.is_empty(&s.missing) {
			if roaring.combine_into(.Andnot, &s.missing, deleted) != .None {
				return removed, .Out_Of_Memory
			}
		}
	}
	removed = doctable.collect(&ix.docs)
	return removed, .None
}

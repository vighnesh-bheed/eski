package retrieve

import "core:slice"
import "core:strings"
import "../postings"
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

Field_Text :: struct {
	field: int,
	text:  string,
}

Corpus :: struct {
	terms:  map[string]int,
	lists:  [dynamic]postings.List,
	docs:   [dynamic][dynamic]string,
	ids:    [dynamic]u32,
}

corpus_init :: proc(c: ^Corpus) {
	c.terms = make(map[string]int)
}

corpus_destroy :: proc(c: ^Corpus) {
	for &l in c.lists {
		postings.destroy(&l)
	}
	delete(c.lists)
	for &d in c.docs {
		for w in d {
			delete(w)
		}
		delete(d)
	}
	delete(c.docs)
	delete(c.ids)
	for k in c.terms {
		delete(k)
	}
	delete(c.terms)
}

Pending :: struct {
	frequency: u32,
	fields:    postings.Fields,
	counts:    [dynamic]u32,
	positions: [dynamic]u32,
	last:      int,
}

corpus_add :: proc(c: ^Corpus, id: u32, parts: []Field_Text) {
	tokens := make([dynamic]string)
	pending := make(map[string]^Pending, 16, context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	pos := u32(0)
	for part in parts {
		words := strings.fields(part.text, context.temp_allocator)
		for w in words {
			pos += 1
			append(&tokens, strings.clone(w))
			p, found := pending[w]
			if !found {
				p = new(Pending, context.temp_allocator)
				p^ = Pending{last = -1}
				p.counts = make([dynamic]u32, context.temp_allocator)
				p.positions = make([dynamic]u32, context.temp_allocator)
				pending[w] = p
				append(&order, w)
			}
			if p.last != part.field {
				append(&p.counts, 0)
				p.fields |= postings.Fields(1) << uint(part.field)
				p.last = part.field
			}
			p.counts[len(p.counts) - 1] += 1
			p.frequency += 1
			append(&p.positions, pos)
		}
	}
	for w in order {
		p := pending[w]
		idx, found := c.terms[w]
		if !found {
			idx = len(c.lists)
			c.terms[strings.clone(w)] = idx
			l: postings.List
			postings.init(&l, postings.Layout{field_words = 1, positions = true})
			append(&c.lists, l)
		}
		e := postings.append_posting(&c.lists[idx], postings.Posting{doc = id, frequency = p.frequency, fields = p.fields, counts = p.counts[:], positions = p.positions[:]})
		assert(e == .None)
	}
	append(&c.docs, tokens)
	append(&c.ids, id)
}

corpus_list :: proc(c: ^Corpus, term: string) -> ^postings.List {
	idx, found := c.terms[term]
	if !found {
		return nil
	}
	return &c.lists[idx]
}

term_docs :: proc(c: ^Corpus, term: string, deleted: ^roaring.Bitmap) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	for d, i in c.docs {
		if deleted != nil && roaring.contains(deleted, c.ids[i]) {
			continue
		}
		if slice.contains(d[:], term) {
			append(&out, c.ids[i])
		}
	}
	return out[:]
}

doc_positions :: proc(c: ^Corpus, doc_index: int, term: string) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	for w, i in c.docs[doc_index] {
		if w == term {
			append(&out, u32(i + 1))
		}
	}
	return out[:]
}

Term_Pool :: struct {
	cursors: [dynamic]^Term_Cursor,
	empties: [dynamic]^Cursor,
}

pool_term :: proc(pool: ^Term_Pool, c: ^Corpus, term: string, deleted: ^roaring.Bitmap, weight := 1.0) -> ^Cursor {
	list := corpus_list(c, term)
	if list == nil {
		e := new(Cursor)
		e^ = empty_cursor()
		append(&pool.empties, e)
		return e
	}
	t := new(Term_Cursor)
	term_cursor_init(t, list, deleted, 0, leaf(.Term, weight))
	append(&pool.cursors, t)
	return t
}

pool_destroy :: proc(pool: ^Term_Pool) {
	for t in pool.cursors {
		term_cursor_destroy(t)
		free(t)
	}
	for e in pool.empties {
		free(e)
	}
	delete(pool.cursors)
	delete(pool.empties)
}

drain :: proc(c: ^Cursor) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	collect_docs(c, &out)
	return out[:]
}

same_docs :: proc(a, b: []u32) -> bool {
	return slice.equal(a, b)
}

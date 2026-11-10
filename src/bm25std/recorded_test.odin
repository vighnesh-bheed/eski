package bm25std


import "core:strconv"
import "core:testing"
import "../postings"
import "../retrieve"
import "../roaring"

Term_Kind :: enum u8 {
	Text,
	Tag,
}

Doc_State :: enum u8 {
	Live,
	Deleted,
	Collected,
}

Doc_Term :: struct {
	kind:      Term_Kind,
	text:      string,
	frequency: u32,
	fields:    u32,
	counts:    []u32,
	positions: []u32,
}

Recorded_Doc :: struct {
	key:    string,
	length: u32,
	score:  f64,
	state:  Doc_State,
	terms:  []Doc_Term,
}

Recorded_Corpus :: struct {
	name: string,
	docs: []Recorded_Doc,
}

Node_Kind :: enum u8 {
	Term,
	Tag,
	Wildcard,
	Union,
	Intersection,
	Difference,
	Phrase,
}

Query_Node :: struct {
	kind:     Node_Kind,
	text:     string,
	fields:   u32,
	weight:   f64,
	first:    bool,
	children: []Query_Node,
	optional: []Query_Node,
}

Recorded_Result :: struct {
	key:   string,
	score: string,
}

Recorded_Case :: struct {
	id:      int,
	corpus:  string,
	total:   int,
	query:   Query_Node,
	results: []Recorded_Result,
}

Built :: struct {
	docs:       []Recorded_Doc,
	terms:      map[string]int,
	lists:      [dynamic]postings.List,
	tags:       map[string]int,
	bitmaps:    [dynamic]roaring.Bitmap,
	deleted:    roaring.Bitmap,
	live:       roaring.Bitmap,
	collection: retrieve.Collection,
}

build :: proc(b: ^Built, c: Recorded_Corpus) {
	b.docs = c.docs
	b.terms = make(map[string]int)
	b.tags = make(map[string]int)
	roaring.init(&b.deleted)
	roaring.init(&b.live)
	for d, i in c.docs {
		id := u32(i + 1)
		switch d.state {
		case .Live:
			roaring.add(&b.live, id)
			b.collection.documents += 1
			b.collection.total_length += u64(d.length)
		case .Deleted:
			roaring.add(&b.deleted, id)
		case .Collected:
			continue
		}
		for term in d.terms {
			if term.kind == .Tag {
				at, found := b.tags[term.text]
				if !found {
					at = len(b.bitmaps)
					b.tags[term.text] = at
					bm: roaring.Bitmap
					roaring.init(&bm)
					append(&b.bitmaps, bm)
				}
				roaring.add(&b.bitmaps[at], id)
				continue
			}
			at, found := b.terms[term.text]
			if !found {
				at = len(b.lists)
				b.terms[term.text] = at
				l: postings.List
				postings.init(&l, postings.Layout{field_words = 1, positions = true})
				append(&b.lists, l)
			}
			e := postings.append_posting(&b.lists[at], postings.Posting{doc = id, frequency = term.frequency, fields = postings.Fields(term.fields), counts = term.counts, positions = term.positions})
			assert(e == .None)
		}
	}
}

unbuild :: proc(b: ^Built) {
	for &l in b.lists {
		postings.destroy(&l)
	}
	delete(b.lists)
	for &bm in b.bitmaps {
		roaring.destroy(&bm)
	}
	delete(b.bitmaps)
	delete(b.terms)
	delete(b.tags)
	roaring.destroy(&b.deleted)
	roaring.destroy(&b.live)
}

node_weight :: proc(n: Query_Node) -> f64 {
	return 1 if n.weight == 0 else n.weight
}

build_cursor :: proc(b: ^Built, n: Query_Node, s: ^retrieve.Scorer) -> ^retrieve.Cursor {
	a := context.temp_allocator
	switch n.kind {
	case .Term:
		at, found := b.terms[n.text]
		if !found {
			e := new(retrieve.Cursor, a)
			e^ = retrieve.empty_cursor()
			return e
		}
		tc := new(retrieve.Term_Cursor, a)
		retrieve.term_cursor_init(tc, &b.lists[at], &b.deleted, postings.Fields(n.fields), retrieve.leaf(.Term, node_weight(n)), postings.ALL_FIELDS, a)
		retrieve.prepare(s, &tc.leaf, tc.cost)
		return tc
	case .Tag:
		at, found := b.tags[n.text]
		if !found {
			e := new(retrieve.Cursor, a)
			e^ = retrieve.empty_cursor()
			return e
		}
		bc := new(retrieve.Bitmap_Cursor, a)
		retrieve.bitmap_cursor_init(bc, &b.bitmaps[at], &b.deleted, retrieve.leaf(.Tag, node_weight(n)))
		retrieve.prepare(s, &bc.leaf, bc.cost)
		return bc
	case .Wildcard:
		bc := new(retrieve.Bitmap_Cursor, a)
		retrieve.bitmap_cursor_init(bc, &b.live, nil, retrieve.leaf(.Wildcard))
		retrieve.prepare(s, &bc.leaf, bc.cost)
		return bc
	case .Union:
		kids := make([]^retrieve.Cursor, len(n.children), a)
		for child, i in n.children {
			kids[i] = build_cursor(b, child, s)
		}
		u := new(retrieve.Union, a)
		retrieve.union_init(u, kids, node_weight(n), .First if n.first else .Sum, a)
		return u
	case .Intersection:
		req := make([]^retrieve.Cursor, len(n.children), a)
		for child, i in n.children {
			req[i] = build_cursor(b, child, s)
		}
		opt := make([]^retrieve.Cursor, len(n.optional), a)
		for child, i in n.optional {
			opt[i] = build_cursor(b, child, s)
		}
		ix := new(retrieve.Intersection, a)
		retrieve.intersection_init(ix, req, opt, node_weight(n), .Auto, a)
		return ix
	case .Difference:
		x := new(retrieve.Difference, a)
		retrieve.difference_init(x, build_cursor(b, n.children[0], s), build_cursor(b, n.children[1], s))
		return x
	case .Phrase:
		kids := make([]^retrieve.Cursor, len(n.children), a)
		for child, i in n.children {
			kids[i] = build_cursor(b, child, s)
		}
		p := new(retrieve.Phrase, a)
		retrieve.phrase_init(p, kids, 0, true, node_weight(n), false, a)
		return p
	}
	return nil
}

document_of :: proc(ctx: rawptr, id: u32) -> (retrieve.Document, bool) {
	b := (^Built)(ctx)
	if id == 0 || int(id) > len(b.docs) {
		return {}, false
	}
	d := b.docs[id - 1]
	return retrieve.Document{id = id, length = d.length, score = f32(d.score)}, true
}

recorded_corpus :: proc(name: string) -> (Recorded_Corpus, bool) {
	for c in RECORDED_CORPORA {
		if c.name == name {
			return c, true
		}
	}
	return {}, false
}

@(test)
bm25std_reproduces_every_recorded_score :: proc(t: ^testing.T) {
	checked := 0
	for rc in RECORDED_CASES {
		corpus, ok := recorded_corpus(rc.corpus)
		if !testing.expectf(t, ok, "case %d: corpus %s missing", rc.id, rc.corpus) {
			continue
		}
		b: Built
		build(&b, corpus)
		p := params_default()
		s := scorer(&p)
		retrieve.begin(&s, b.collection)
		root := build_cursor(&b, rc.query, &s)
		top: retrieve.Top_K
		retrieve.top_k_init(&top, len(rc.results), context.temp_allocator)
		col := retrieve.top_k_collector(&top)
		matched, err := retrieve.run(root, &s, document_of, &b, &col)
		testing.expect_value(t, err, retrieve.Error.None)
		testing.expectf(t, int(matched) == rc.total, "case %d: matched %d documents, want %d", rc.id, matched, rc.total)
		out := make([dynamic]retrieve.Ranked, context.temp_allocator)
		retrieve.top_k_results(&top, &out)
		if testing.expectf(t, len(out) == len(rc.results), "case %d: %d results, want %d", rc.id, len(out), len(rc.results)) {
			for r, i in rc.results {
				want, parsed := strconv.parse_f64(r.score)
				testing.expect(t, parsed)
				got := out[i]
				key := b.docs[got.doc - 1].key
				testing.expectf(t, key == r.key && got.score == want, "case %d rank %d: %s %.17g, want %s %s", rc.id, i, key, got.score, r.key, r.score)
				checked += 1
			}
		}
		unbuild(&b)
		free_all(context.temp_allocator)
	}
	testing.expect(t, checked > 250)
}

@(test)
idf_matches_the_recorded_shapes :: proc(t: ^testing.T) {
	testing.expect_value(t, K1, 1.2000000476837158)
	testing.expect_value(t, B, 0.75)
	testing.expect_value(t, idf(6, 6), idf(5, 6))
	testing.expect(t, idf(4, 6) == idf(6, 6) && idf(6, 6) > 0)
	testing.expect_value(t, idf(4, 4), 0.10536051565782635)
	p := params_default()
	s := scorer(&p)
	retrieve.begin(&s, retrieve.Collection{documents = 4, total_length = 11})
	testing.expect_value(t, p.average_length, 2.75)
	wild := retrieve.leaf(.Wildcard)
	retrieve.prepare(&s, &wild, 0)
	testing.expect_value(t, wild.prepared, 1.0)
	doc := retrieve.Document{id = 3, length = 2, score = 1}
	sc := retrieve.Scoring{scorer = &s, doc = doc}
	testing.expect_value(t, retrieve.leaf_score(&sc, &wild, retrieve.Hit{frequency = 1}), 1.1255813979019405)
	tag := retrieve.leaf(.Tag)
	retrieve.prepare(&s, &tag, 1)
	high, has := retrieve.upper_bound(&s, &tag, 3, 1)
	testing.expect(t, has)
	testing.expect(t, high >= retrieve.leaf_score(&sc, &tag, retrieve.Hit{frequency = 1}))
	empty := params_default()
	es := scorer(&empty)
	retrieve.begin(&es, retrieve.Collection{})
	testing.expect_value(t, empty.average_length, 0.0)
}

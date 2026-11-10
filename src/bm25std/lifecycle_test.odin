package bm25std

import "core:strconv"
import "core:strings"
import "core:testing"
import "../doctable"
import "../label"
import "../postings"
import "../retrieve"
import "../tagindex"
import "../termdict"
import "../termstats"

Engine :: struct {
	docs:  doctable.Table,
	terms: termdict.Dictionary,
	lists: [dynamic]^postings.List,
	tags:  tagindex.Field,
	stats: termstats.Stats,
}

engine_init :: proc(e: ^Engine) {
	doctable.init(&e.docs)
	termdict.init(&e.terms)
	tagindex.init(&e.tags)
	termstats.init(&e.stats)
}

engine_destroy :: proc(e: ^Engine) {
	for l in e.lists {
		postings.destroy(l)
		free(l)
	}
	delete(e.lists)
	doctable.destroy(&e.docs)
	termdict.destroy(&e.terms)
	tagindex.destroy(&e.tags)
	termstats.destroy(&e.stats)
}

engine_index :: proc(t: ^testing.T, e: ^Engine, key: string, text: string, tag: string) {
	words := strings.fields(text, context.temp_allocator)
	id, replaced, err := doctable.add(&e.docs, key, doctable.Fields{length = u32(len(words)), score = 1, label = label.BOTTOM_ID})
	testing.expect_value(t, err, doctable.Error.None)
	if replaced != 0 {
		old := doctable.slot(&e.docs, replaced)
		testing.expect_value(t, termstats.document_remove(&e.stats, old.label, old.length), label.Error.None)
	}
	testing.expect_value(t, termstats.document_add(&e.stats, label.BOTTOM_ID, u32(len(words))), label.Error.None)
	for w, i in words {
		tid, inserted, _ := termdict.insert(&e.terms, w)
		if inserted {
			for int(tid) >= len(e.lists) {
				l := new(postings.List)
				postings.init(l, postings.Layout{field_words = 1, positions = true})
				append(&e.lists, l)
			}
		}
		pe := postings.append_posting(e.lists[tid], postings.Posting{doc = id, frequency = 1, fields = 1, counts = {1}, positions = {u32(i + 1)}})
		testing.expect_value(t, pe, postings.Error.None)
		termstats.term_add(&e.stats, u32(tid), label.BOTTOM_ID)
	}
	tagindex.add(&e.tags, tag, id)
}

engine_delete :: proc(t: ^testing.T, e: ^Engine, key: string) {
	id, err := doctable.remove(&e.docs, key)
	testing.expect_value(t, err, doctable.Error.None)
	d := doctable.slot(&e.docs, id)
	termstats.document_remove(&e.stats, d.label, d.length)
}

Removal :: struct {
	engine: ^Engine,
	term:   u32,
}

engine_collect :: proc(t: ^testing.T, e: ^Engine) {
	for l, tid in e.lists {
		if _, live := termdict.text(&e.terms, termdict.Id(tid)); !live {
			continue
		}
		r := Removal{engine = e, term = u32(tid)}
		removed := proc(ctx: rawptr, doc: u32) {
			x := (^Removal)(ctx)
			d := doctable.slot(&x.engine.docs, doc)
			termstats.term_remove(&x.engine.stats, x.term, d.label)
		}
		_, err := postings.collect(l, &e.docs.deleted, removed, &r)
		testing.expect_value(t, err, postings.Error.None)
		if postings.length(l) == 0 {
			termdict.remove(&e.terms, termdict.Id(tid))
			termstats.term_forget(&e.stats, u32(tid))
		}
	}
	tagindex.collect(&e.tags, &e.docs.deleted)
	doctable.collect(&e.docs)
}

engine_document :: proc(ctx: rawptr, id: u32) -> (retrieve.Document, bool) {
	e := (^Engine)(ctx)
	d := doctable.get(&e.docs, id)
	if d == nil {
		return {}, false
	}
	return retrieve.Document{id = id, length = d.length, score = d.score}, true
}

engine_search :: proc(t: ^testing.T, e: ^Engine, term: string, tag: bool, want: []Recorded_Result) {
	p := params_default()
	s := scorer(&p)
	totals := termstats.totals(&e.stats)
	retrieve.begin(&s, retrieve.Collection{documents = totals.documents, total_length = totals.total_length})
	root: ^retrieve.Cursor
	if tag {
		b, _, found := tagindex.lookup(&e.tags, term)
		testing.expect(t, found)
		bc := new(retrieve.Bitmap_Cursor, context.temp_allocator)
		retrieve.bitmap_cursor_init(bc, b, &e.docs.deleted, retrieve.leaf(.Tag))
		retrieve.prepare(&s, &bc.leaf, bc.cost)
		root = bc
	} else {
		tid, found := termdict.lookup(&e.terms, term)
		testing.expect(t, found)
		tc := new(retrieve.Term_Cursor, context.temp_allocator)
		retrieve.term_cursor_init(tc, e.lists[tid], &e.docs.deleted, 0, retrieve.leaf(.Term), postings.ALL_FIELDS, context.temp_allocator)
		testing.expect_value(t, termstats.term_total(&e.stats, u32(tid)), tc.cost)
		retrieve.prepare(&s, &tc.leaf, termstats.term_total(&e.stats, u32(tid)))
		root = tc
	}
	top: retrieve.Top_K
	retrieve.top_k_init(&top, 10, context.temp_allocator)
	col := retrieve.top_k_collector(&top)
	retrieve.run(root, &s, engine_document, e, &col)
	out := make([dynamic]retrieve.Ranked, context.temp_allocator)
	retrieve.top_k_results(&top, &out)
	if !testing.expect_value(t, len(out), len(want)) {
		return
	}
	for w, i in want {
		v, _ := strconv.parse_f64(w.score)
		d := doctable.get(&e.docs, out[i].doc)
		testing.expectf(t, d.key == w.key && out[i].score == v, "%s rank %d: %s %.17g, want %s %s", term, i, d.key, out[i].score, w.key, w.score)
	}
}

probe_results :: proc(id: int) -> []Recorded_Result {
	for rc in RECORDED_CASES {
		if rc.id == id {
			return rc.results
		}
	}
	return nil
}

@(test)
statistics_follow_rewrites_deletes_and_collection :: proc(t: ^testing.T) {
	e: Engine
	engine_init(&e)
	defer engine_destroy(&e)
	keys := [?]string{"gc:1", "gc:2", "gc:3", "gc:4", "gc:5"}
	for key, i in keys {
		engine_index(t, &e, key, "same words here", "x" if i % 2 == 0 else "y")
	}
	engine_index(t, &e, "gc:6", "lonely", "z")
	engine_search(t, &e, "same", false, probe_results(100006))
	engine_search(t, &e, "x", true, probe_results(100007))
	engine_index(t, &e, "gc:1", "same words here again", "x")
	engine_search(t, &e, "same", false, probe_results(100010))
	engine_search(t, &e, "x", true, probe_results(100011))
	engine_delete(t, &e, "gc:2")
	engine_delete(t, &e, "gc:6")
	engine_search(t, &e, "same", false, probe_results(100014))
	engine_search(t, &e, "x", true, probe_results(100015))
	testing.expect_value(t, termdict.count(&e.terms), 5)
	testing.expect_value(t, doctable.max_id(&e.docs), 7)
	testing.expect_value(t, doctable.count(&e.docs), 4)
	engine_collect(t, &e)
	engine_search(t, &e, "same", false, probe_results(100021))
	engine_search(t, &e, "x", true, probe_results(100022))
	testing.expect_value(t, termdict.count(&e.terms), 4)
	_, lonely := termdict.lookup(&e.terms, "lonely")
	testing.expect(t, !lonely)
	records := 0
	for l, tid in e.lists {
		if _, live := termdict.text(&e.terms, termdict.Id(tid)); live {
			records += postings.length(l)
		}
	}
	testing.expect_value(t, records + e.tags.records, 17)
	free_all(context.temp_allocator)
}

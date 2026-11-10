package retrieve

import "../postings"

Leaf_Kind :: enum u8 {
	Term,
	Tag,
	Wildcard,
	Filter,
}

Collection :: struct {
	documents:    u64,
	total_length: u64,
}

Term_Statistics :: struct {
	kind:       Leaf_Kind,
	containing: u64,
}

Leaf :: struct {
	weight:   f64,
	prepared: f64,
	kind:     Leaf_Kind,
}

Hit :: struct {
	frequency: u32,
	fields:    postings.Fields,
}

Document :: struct {
	id:            u32,
	length:        u32,
	max_frequency: u32,
	score:         f32,
}

Node_Kind :: enum u8 {
	Intersection,
	Union,
	Phrase,
}

Begin_Proc :: #type proc(ctx: rawptr, collection: Collection)

Prepare_Proc :: #type proc(ctx: rawptr, term: Term_Statistics) -> f64

Term_Score_Proc :: #type proc(ctx: rawptr, leaf: ^Leaf, hit: Hit, doc: ^Document) -> f64

Combine_Proc :: #type proc(ctx: rawptr, node: Node_Kind, total, child: f64) -> f64

Finish_Proc :: #type proc(ctx: rawptr, total: f64, doc: ^Document, root: ^Cursor) -> f64

Bound_Proc :: #type proc(ctx: rawptr, leaf: ^Leaf, max_frequency: u32, min_length: u32) -> f64

Scorer :: struct {
	ctx:     rawptr,
	begin:   Begin_Proc,
	prepare: Prepare_Proc,
	term:    Term_Score_Proc,
	combine: Combine_Proc,
	finish:  Finish_Proc,
	bound:   Bound_Proc,
}

Scoring :: struct {
	scorer: ^Scorer,
	doc:    Document,
}

leaf :: proc "contextless" (kind: Leaf_Kind, weight := 1.0) -> Leaf {
	return Leaf{weight = weight, kind = kind}
}

begin :: proc(s: ^Scorer, collection: Collection) {
	if s != nil && s.begin != nil {
		s.begin(s.ctx, collection)
	}
}

prepare :: proc(s: ^Scorer, l: ^Leaf, containing: u64) {
	if s == nil || s.prepare == nil || l.kind == .Filter {
		l.prepared = 0
		return
	}
	l.prepared = s.prepare(s.ctx, Term_Statistics{kind = l.kind, containing = containing})
}

leaf_score :: proc(s: ^Scoring, l: ^Leaf, hit: Hit) -> f64 {
	if s == nil || s.scorer == nil || s.scorer.term == nil || l.kind == .Filter {
		return 0
	}
	return s.scorer.term(s.scorer.ctx, l, hit, &s.doc)
}

fold :: #force_inline proc(s: ^Scoring, node: Node_Kind, have: bool, total, child: f64) -> f64 {
	if !have {
		return child
	}
	if s != nil && s.scorer != nil && s.scorer.combine != nil {
		return s.scorer.combine(s.scorer.ctx, node, total, child)
	}
	return total + child
}

finish :: proc(s: ^Scoring, total: f64, root: ^Cursor) -> f64 {
	if s == nil || s.scorer == nil || s.scorer.finish == nil {
		return total
	}
	return s.scorer.finish(s.scorer.ctx, total, &s.doc, root)
}

upper_bound :: proc(s: ^Scorer, l: ^Leaf, max_frequency: u32, min_length: u32) -> (f64, bool) {
	if s == nil || s.bound == nil {
		return 0, false
	}
	return s.bound(s.ctx, l, max_frequency, min_length), true
}

Document_Proc :: #type proc(ctx: rawptr, id: u32) -> (Document, bool)

run :: proc(root: ^Cursor, scorer: ^Scorer, documents: Document_Proc, documents_ctx: rawptr, collector: ^Collector) -> (matched: u64, err: Error) {
	s := Scoring{scorer = scorer}
	for d := next(root); d != END; d = next(root) {
		doc := Document{id = d, score = 1}
		if documents != nil {
			found: bool
			doc, found = documents(documents_ctx, d)
			if !found {
				continue
			}
		}
		s.doc = doc
		value := finish(&s, score(root, &s), root)
		collect(collector, d, value) or_return
		matched += 1
	}
	return matched, .None
}

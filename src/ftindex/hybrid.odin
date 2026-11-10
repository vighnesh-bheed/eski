package ftindex

import "core:math"
import "core:mem"
import "core:strings"
import ftq "../ftquery"
import "../retrieve"
import "../rrf"
import "../vmath"

HYBRID_K_DEFAULT :: 10

Hybrid_Vector :: struct {
	field:      int,
	blob:       []u8,
	k:          int,
	range:      bool,
	radius:     f64,
	epsilon:    f64,
	ef_runtime: int,
	filter:     ^ftq.Parsed,
}

Hybrid_Options :: struct {
	text:     Execute_Options,
	window:   int,
	constant: f64,
	fusion:   ^retrieve.Fusion,
}

Hybrid_Row :: struct {
	doc:        u32,
	score:      f64,
	text_score: f64,
	distance:   f64,
	similarity: f64,
	in_text:    bool,
	in_vector:  bool,
}

Hybrid_Result :: struct {
	rows:      [dynamic]Hybrid_Row,
	total:     int,
	truncated: bool,
	message:   string,
	allocator: mem.Allocator,
}

hybrid_result_destroy :: proc(r: ^Hybrid_Result) {
	delete(r.rows)
	delete(r.message, r.allocator)
	r^ = {}
}

keep_message :: proc(r: ^Hybrid_Result, e: ftq.Error) -> ftq.Error {
	if len(e.message) == 0 {
		return e
	}
	delete(r.message, r.allocator)
	r.message = strings.clone(e.message, r.allocator)
	return ftq.Error{code = e.code, message = r.message}
}

vector_similarity :: proc "contextless" (metric: vmath.Metric, d: f64) -> f64 {
	switch metric {
	case .L2:
		return 1 / (1 + d)
	case .Cosine:
		return 1 - d / 2
	case .IP:
		return (1 + d) / 2
	}
	return 0
}

copy_error :: proc(e: ftq.Error) -> ftq.Error {
	return ftq.Error{code = e.code, message = strings.clone(e.message, context.temp_allocator)}
}

vector_branch :: proc(ix: ^Index, vec: ^Hybrid_Vector, opts: ^Execute_Options, out: ^[dynamic]Vector_Hit) -> (err: Error, query_err: ftq.Error) {
	if vec.field < 0 || vec.field >= len(ix.slots) || ix.slots[vec.field].vector == nil {
		return .Invalid_Definition, {}
	}
	source := ix.slots[vec.field].vector
	if source.count(source.ctx) == 0 {
		return .None, {}
	}
	want := field_vector_bytes(ix, vec.field)
	if len(vec.blob) != want {
		return .Query_Error, blob_size_error(len(vec.blob), want, context.temp_allocator)
	}
	scratch: Result
	result_init(&scratch, context.allocator)
	defer result_destroy(&scratch)
	set := Filter_Set{ix = ix, v = opts.visibility, all = true}
	if vec.filter != nil && vec.filter.query.root != ftq.NO_NODE {
		session: Session
		b: Builder
		builder_init(&b, ix, vec.filter, opts, &session, &scratch)
		if !validate_tree(&b, vec.filter.query.root) {
			return b.err, copy_error(b.query_err)
		}
		built := build(&b, vec.filter.query.root)
		if b.err != .None {
			return b.err, copy_error(b.query_err)
		}
		if built.cursor == nil {
			return .None, {}
		}
		set.all = false
		materialize(&b, built.cursor, &set)
		if len(set.docs) == 0 {
			return .None, {}
		}
	}
	q := Vector_Query {
		blob       = vec.blob,
		k          = vec.k if vec.k > 0 else HYBRID_K_DEFAULT,
		radius     = vec.radius,
		epsilon    = vec.epsilon,
		ef_runtime = vec.ef_runtime,
		accept     = filter_accept,
		accept_ctx = &set,
		accepted   = -1 if set.all else len(set.docs),
	}
	found := make([dynamic]Vector_Hit, context.temp_allocator)
	e := source.within(source.ctx, &q, &found) if vec.range else source.nearest(source.ctx, &q, &found)
	if e == .Blob_Size {
		return .Query_Error, blob_size_error(len(vec.blob), want, context.temp_allocator)
	}
	if e != .None {
		return e, {}
	}
	for h in found {
		if filter_accept(&set, h.doc) {
			append(out, h)
		}
	}
	sort_hits(out[:])
	return .None, {}
}

hybrid :: proc(ix: ^Index, text_query: ^ftq.Parsed, vec: Hybrid_Vector, options: Hybrid_Options, allocator := context.allocator) -> (result: Hybrid_Result, err: Error, query_err: ftq.Error) {
	opts := options
	result.rows = make([dynamic]Hybrid_Row, allocator)
	result.allocator = allocator
	window := opts.window if opts.window > 0 else rrf.WINDOW
	text_opts := opts.text
	text_opts.unscored_tags = true
	text_opts.limit = window
	text, te, tqe := execute(ix, text_query, text_opts, context.allocator)
	defer result_destroy(&text)
	if te != .None {
		return result, te, keep_message(&result, tqe)
	}
	result.truncated = text.truncated
	v := vec
	hits := make([dynamic]Vector_Hit, context.temp_allocator)
	ve, vqe := vector_branch(ix, &v, &text_opts, &hits)
	if ve != .None {
		return result, ve, keep_message(&result, vqe)
	}
	metric := ix.definition.fields[vec.field].vector.metric
	text_ranked := make([]retrieve.Ranked, min(len(text.hits), window), context.temp_allocator)
	for h, i in text.hits[:len(text_ranked)] {
		text_ranked[i] = retrieve.Ranked{doc = h.doc, score = h.score}
	}
	vector_ranked := make([]retrieve.Ranked, min(len(hits), window), context.temp_allocator)
	for h, i in hits[:len(vector_ranked)] {
		vector_ranked[i] = retrieve.Ranked{doc = h.doc, score = vector_similarity(metric, h.distance)}
	}
	params := rrf.params_default()
	params.window = window
	if opts.constant > 0 {
		params.constant = opts.constant
	}
	fusion := rrf.fusion(&params)
	use := opts.fusion if opts.fusion != nil else &fusion
	fused := make([dynamic]retrieve.Ranked, context.temp_allocator)
	branches := [2][]retrieve.Ranked{text_ranked, vector_ranked}
	if retrieve.fuse(use, branches[:], &fused) != .None {
		return result, .Out_Of_Memory, {}
	}
	for x in fused {
		row := Hybrid_Row{doc = x.doc, score = x.score, text_score = math.nan_f64(), distance = math.nan_f64(), similarity = math.nan_f64()}
		for t in text_ranked {
			if t.doc == x.doc {
				row.text_score = t.score
				row.in_text = true
				break
			}
		}
		for h in hits[:len(vector_ranked)] {
			if h.doc == x.doc {
				row.distance = h.distance
				row.similarity = vector_similarity(metric, h.distance)
				row.in_vector = true
				break
			}
		}
		append(&result.rows, row)
	}
	result.total = len(result.rows)
	return result, .None, {}
}

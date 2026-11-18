package ftindex

import "base:intrinsics"
import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:strings"
import "../bm25std"
import "../retrieve"

Scorer_Kind :: enum {
	Bm25std,
	Bm25,
	Norm,
	Tanh,
	Tfidf,
	Tfidf_Docnorm,
	Dismax,
	Docscore,
	Hamming,
}

SCORER_NAMES := [Scorer_Kind]string{
	.Bm25std = "BM25STD",
	.Bm25 = "BM25",
	.Norm = "BM25STD.NORM",
	.Tanh = "BM25STD.TANH",
	.Tfidf = "TFIDF",
	.Tfidf_Docnorm = "TFIDF.DOCNORM",
	.Dismax = "DISMAX",
	.Docscore = "DOCSCORE",
	.Hamming = "HAMMING",
}

scorer_kind :: proc "contextless" (name: string) -> (Scorer_Kind, bool) {
	for kind in Scorer_Kind {
		if name == SCORER_NAMES[kind] {
			return kind, true
		}
	}
	return .Bm25std, name == ""
}

Scorer_State :: struct {
	kind: Scorer_Kind,
	bm25: bm25std.Params,
	tanh_factor: f64,
}

scorer_init :: proc(state: ^Scorer_State, kind: Scorer_Kind, factor: f64) -> retrieve.Scorer {
	state^ = {kind = kind, bm25 = bm25std.params_default(), tanh_factor = 4 if factor == 0 else factor}
	return retrieve.Scorer{ctx = state, begin = scorer_begin, prepare = scorer_prepare, term = scorer_term, combine = scorer_combine}
}

scorer_begin :: proc(ctx: rawptr, collection: retrieve.Collection) {
	bm25std.begin(&(^Scorer_State)(ctx).bm25, collection)
}

scorer_prepare :: proc(ctx: rawptr, term: retrieve.Term_Statistics) -> f64 {
	state := (^Scorer_State)(ctx)
	if term.kind == .Wildcard || term.kind == .Value {
		return 1
	}
	switch state.kind {
	case .Bm25, .Tfidf, .Tfidf_Docnorm:
		if term.containing == 0 {
			return 1
		}
		ratio := 1 + f64(state.bm25.documents + 1) / f64(term.containing)
		return f64(libc.floor(libc.log2(ratio)))
	case .Bm25std, .Norm, .Tanh:
		return bm25std.prepare(&state.bm25, term)
	case .Dismax, .Docscore, .Hamming:
		return 1
	}
	return 0
}

scorer_term :: proc(ctx: rawptr, leaf: ^retrieve.Leaf, hit: retrieve.Hit, doc: ^retrieve.Document) -> f64 {
	state := (^Scorer_State)(ctx)
	frequency := f64(hit.frequency)
	switch state.kind {
	case .Bm25:
		return leaf.weight * leaf.prepared * frequency / (frequency + bm25std.K1 * (0.5 + 0.5 * state.bm25.average_length))
	case .Tfidf, .Tfidf_Docnorm:
		return leaf.weight * frequency * leaf.prepared
	case .Bm25std, .Norm, .Tanh:
		if leaf.kind == .Value {
			return 0
		}
		return bm25std.term(&state.bm25, leaf, hit, doc)
	case .Dismax:
		return leaf.weight * frequency
	case .Docscore, .Hamming:
		return 0
	}
	return 0
}

scorer_combine :: proc(ctx: rawptr, node: retrieve.Node_Kind, total, child: f64) -> f64 {
	if (^Scorer_State)(ctx).kind == .Dismax && node == .Union {
		return max(total, child)
	}
	return total + child
}

legacy_scorer :: proc "contextless" (type: Scorer_Kind) -> bool {
	return type == .Bm25 || type == .Tfidf || type == .Tfidf_Docnorm
}

Payload_Proc :: #type proc(ctx: rawptr, ix: ^Index, doc: u32, key: string) -> string

score_document :: proc(b: ^Builder, s: ^retrieve.Scoring, root: ^retrieve.Cursor, doc_key: string, trace_allocator: mem.Allocator) -> (score: f64, explanation: retrieve.Explanation) {
	if b.opts.scorer != nil {
		return retrieve.finish(s, retrieve.score(root, s), root), {}
	}
	kind := b.opts.scorer_kind
	if kind == .Bm25std && !b.opts.explain_scores {
		return retrieve.score(root, s) * f64(s.doc.score), {}
	}
	trace: retrieve.Score_Trace_Context
	trace.track_positions = legacy_scorer(kind)
	trace.explain = b.opts.explain_scores
	trace.allocator = trace_allocator
	if trace.track_positions || b.opts.explain_scores {
		trace.nodes = make([dynamic]retrieve.Score_Trace, trace.allocator)
		s.trace = &trace
	}
	defer s.trace = nil
	total := retrieve.score(root, s)
	state := (^Scorer_State)(b.scorer.ctx)
	slop := retrieve.trace_slop(trace.nodes[:], trace.allocator) if trace.track_positions else 1
	norm := max(s.doc.length if kind == .Tfidf_Docnorm else s.doc.max_frequency, 1)
	payload: string
	bits := -1
	switch kind {
	case .Hamming:
		if b.opts.view != nil && b.opts.view.payload != nil {
			payload = b.opts.view.payload(b.opts.view.ctx, b.ix, s.doc.id, doc_key)
		}
		if len(payload) != len(b.opts.payload) || len(payload) == 0 {
			score = 0
		} else {
			bits = 0
			for ch, i in transmute([]u8)payload {
				bits += int(intrinsics.count_ones(ch ~ b.opts.payload[i]))
			}
			score = 1 / f64(bits + 1)
		}
	case .Docscore:
		score = f64(s.doc.score)
	case .Dismax:
		score = total
	case .Tfidf, .Tfidf_Docnorm:
		score = total * f64(s.doc.score) / f64(norm) / f64(slop)
	case .Bm25:
		score = total * f64(s.doc.score) / f64(slop)
	case .Tanh:
		score = libc.tanh(total * f64(s.doc.score) / state.tanh_factor)
	case .Bm25std, .Norm:
		score = total * f64(s.doc.score)
	}
	if b.opts.explain_scores {
		explanation = scorer_explanation(state, &s.doc, norm, slop, bits, len(payload), score, total, trace.nodes[:], b.a)
	}
	return score, explanation
}

explanation_children :: proc(out: ^retrieve.Explanation, children: ..retrieve.Explanation) {
	out.children = make([]retrieve.Explanation, len(children), context.allocator)
	copy(out.children, children)
}

scorer_explanation :: proc(state: ^Scorer_State, doc: ^retrieve.Document, norm: u32, slop, bits, payload_len: int, score, raw: f64, trace: []retrieve.Score_Trace, allocator: mem.Allocator) -> retrieve.Explanation {
	context.allocator = allocator
	kind := state.kind
	out: retrieve.Explanation
	switch kind {
	case .Docscore:
		out.text = fmt.aprintf("Document's score is %.2f", score)
		return out
	case .Hamming:
		out.text = "Payloads provided to scorer vary in length"
		if bits >= 0 {
			out.text = fmt.aprintf("String length is %d. Bit count is %d. Result is (1 / count + 1) = %.2f", payload_len, bits, score)
		}
		return out
	case .Tfidf, .Tfidf_Docnorm:
		out.text = fmt.aprintf("Final TFIDF : words TFIDF %.2f * document score %.2f / norm %d / slop %d", raw, doc.score, norm, slop)
	case .Bm25:
		out.text = fmt.aprintf("Final BM25 : words BM25 %.2f * document score %.2f / slop %d", raw, doc.score, slop)
	case .Bm25std, .Norm, .Tanh:
		out.text = fmt.aprintf("Final BM25 : words BM25 %.2f * document score %.2f", raw, doc.score)
	case .Dismax:
		if len(trace) == 1 {
			return scorer_trace(state, doc, &trace[0])
		}
		out.text = fmt.aprintf("%.2f = Weight 1.00 * children DISMAX %.2f", raw, raw)
	}
	out.children = make([]retrieve.Explanation, len(trace))
	for &entry, i in trace {
		out.children[i] = scorer_trace(state, doc, &entry)
	}
	if kind == .Tanh {
		tanh := retrieve.Explanation{text = fmt.aprintf("Final Normalized BM25 : tanh(stretch factor 1/%g * Final BM25 %.2f)", state.tanh_factor, raw * f64(doc.score))}
		explanation_children(&tanh, out)
		return tanh
	}
	return out
}

scorer_trace :: proc(s: ^Scorer_State, doc: ^retrieve.Document, trace: ^retrieve.Score_Trace) -> retrieve.Explanation {
	out: retrieve.Explanation
	t, kind := trace, s.kind
	weight, idf, freq, value := t.leaf.weight, t.leaf.prepared, t.frequency, t.value
	if t.children != nil {
		#partial switch kind {
		case .Tfidf, .Tfidf_Docnorm:
			out.text = fmt.aprintf("(Weight %.2f * total children TFIDF %.2f)", weight, value)
		case .Dismax:
			out.text = fmt.aprintf("%.2f = Weight %.2f * children DISMAX %.2f", value, weight, value)
		case:
			out.text = fmt.aprintf("(Weight %.2f * children BM25 %.2f)", weight, value)
		}
		out.children = make([]retrieve.Explanation, len(t.children))
		for &child, i in t.children {
			out.children[i] = scorer_trace(s, doc, &child)
		}
		return out
	}
	#partial switch kind {
	case .Tfidf, .Tfidf_Docnorm:
		if t.leaf.kind != .Term && t.leaf.kind != .Tag {
			out.text = fmt.aprintf("(TFIDF %.2f = Weight %.2f * Frequency %d)", value, weight, freq)
		} else {
			out.text = fmt.aprintf("(TFIDF %.2f = Weight %.2f * TF %d * IDF %.2f)", value, weight, freq, idf)
		}
	case .Bm25:
		if t.leaf.kind == .Filter && freq == 0 {
			out.text = "Frequency 0 -> value 0"
		} else if t.leaf.kind == .Value || t.leaf.kind == .Wildcard || t.leaf.kind == .Filter {
			out.text = fmt.aprintf("(%.2f = Weight %.2f * F %d / (F %d + k1 1.2 * (1 - b 0.5 + b 0.5 * Average Len %.2f)))", value, weight, freq, freq, s.bm25.average_length)
		} else {
			out.text = fmt.aprintf("(%.2f = Weight %.2f * IDF %.2f * F %d / (F %d + k1 1.2 * (1 - b 0.5 + b 0.5 * Average Len %.2f)))", value, weight, idf, freq, freq, s.bm25.average_length)
		}
	case .Dismax:
		out.text = fmt.aprintf("DISMAX %.2f = Weight %.2f * Frequency %d", value, weight, freq)
	case:
		if t.leaf.kind == .Filter || t.leaf.kind == .Value {
			out.text = "Irrelevant token -> score is 0"
		} else {
			name := strings.concatenate({t.label, ": "}, context.allocator) if t.label != "" else ""
			out.text = fmt.aprintf("%s(%.2f = Weight %.2f * IDF %.2f * (F %.2f * (k1 1.2 + 1)) / (F %.2f + k1 1.2 * (1 - b 0.75 + b 0.75 * Doc Len %d / Average Doc Len %.2f)))",
				name, value, weight, idf, f64(freq), f64(freq), doc.length, s.bm25.average_length)
		}
	}
	return out
}

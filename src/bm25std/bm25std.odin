package bm25std

import "core:c/libc"
import "../retrieve"

K1 :: f64(f32(1.2))

B :: f64(f32(0.75))

Params :: struct {
	k1:             f64,
	b:              f64,
	documents:      u64,
	average_length: f64,
}

params_default :: proc "contextless" () -> Params {
	return Params{k1 = K1, b = B}
}

idf :: proc "contextless" (documents, containing: u64) -> f64 {
	n := f64(containing)
	total := f64(max(documents, containing))
	return f64(libc.log(1 + (total - n + 0.5) / (n + 0.5)))
}

contribution :: #force_inline proc "contextless" (p: ^Params, weight, prepared: f64, frequency: u32, length: u32) -> f64 {
	f := f64(frequency)
	dl := f64(length)
	return weight * prepared * f * (p.k1 + 1) / (f + p.k1 * (1 - p.b + p.b * dl / p.average_length))
}

begin :: proc(ctx: rawptr, collection: retrieve.Collection) {
	p := (^Params)(ctx)
	p.documents = collection.documents
	p.average_length = 0
	if collection.documents > 0 {
		p.average_length = f64(collection.total_length) / f64(collection.documents)
	}
}

prepare :: proc(ctx: rawptr, term: retrieve.Term_Statistics) -> f64 {
	p := (^Params)(ctx)
	switch term.kind {
	case .Wildcard:
		return 1
	case .Filter:
		return 0
	case .Term, .Tag:
		return idf(p.documents, term.containing)
	}
	return 0
}

term :: proc(ctx: rawptr, leaf: ^retrieve.Leaf, hit: retrieve.Hit, doc: ^retrieve.Document) -> f64 {
	return contribution((^Params)(ctx), leaf.weight, leaf.prepared, hit.frequency, doc.length)
}

finish :: proc(ctx: rawptr, total: f64, doc: ^retrieve.Document, root: ^retrieve.Cursor) -> f64 {
	return total * f64(doc.score)
}

bound :: proc(ctx: rawptr, leaf: ^retrieve.Leaf, max_frequency: u32, min_length: u32) -> f64 {
	return contribution((^Params)(ctx), leaf.weight, leaf.prepared, max_frequency, min_length)
}

scorer :: proc(p: ^Params) -> retrieve.Scorer {
	return retrieve.Scorer{ctx = p, begin = begin, prepare = prepare, term = term, finish = finish, bound = bound}
}

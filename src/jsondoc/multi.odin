package jsondoc

import "core:mem"

Set_Triple :: struct {
	document: ^Document,
	path, value: string,
	wrong_type: bool,
}

prepare_mset :: proc(triples: []Set_Triple, allocator: mem.Allocator) -> ([]Set_Request, Outcome) {
	if len(triples) == 0 {
		return nil, arity_error(.Mset, allocator)
	}
	if len(triples) > MAX_ITEMS {
		return nil, type_error(SIZE_LIMIT)
	}
	requests, err := make([]Set_Request, len(triples), allocator)
	if err != nil {
		return nil, type_error(OUT_OF_MEMORY)
	}
	for triple, i in triples {
		request, status := prepare_mset_triple(triple, allocator)
		if status.reply.kind == .Error {
			return nil, status
		}
		requests[i] = request
	}
	return requests, {}
}

prepare_mset_triple :: proc(triple: Set_Triple, allocator: mem.Allocator) -> (Set_Request, Outcome) {
	if triple.wrong_type {
		return {}, type_error(wrong_key_type)
	}
	return prepare_set(triple.document.root, .Set, []string{triple.path, triple.value}, allocator)
}

apply_mset :: proc(triples: []Set_Triple, requests: []Set_Request, results: []Outcome, allocator: mem.Allocator) -> Outcome {
	if len(triples) != len(requests) || len(triples) != len(results) {
		return type_error(syntax_error)
	}
	out := Outcome{reply_status("OK"), false}
	for triple, i in triples {
		result := apply_set(triple.document, requests[i], false, allocator)
		results[i] = result
		out.changed = out.changed || result.changed
		if result.reply.kind == .Error {
			out.reply = result.reply
			return out
		}
		if result.reply.kind == .Nil {
			out.reply = {}
		}
	}
	return out
}

mset_short_triple :: proc(doc: ^Document, wrong_type: bool, path: string, allocator: mem.Allocator) -> Outcome {
	if wrong_type {
		return type_error(wrong_key_type)
	}
	if doc.root == nil && path != "$" && path != "." {
		return type_error(ROOT_REQUIRED)
	}
	if _, err := compile_path(path, allocator); err != {} {
		return type_error(path_error_text(err, allocator))
	}
	return arity_error(.Mset, allocator)
}

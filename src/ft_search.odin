package main

import "core:fmt"
import "core:slice"
import "core:strings"
import dt "doctable"
import fi "ftindex"
import fq "ftquery"
import lb "label"
import ht "hashtype"
import lp "listpack"
import "retrieve"
import ow "owner"

SEARCH_TIMEOUT_MS :: 500

Search_Query_State :: struct {
	reader:   ow.Scope,
	vis:      ^lb.Visibility,
	now:      u64,
	deadline: u64,
	keys:     map[string]bool,
	payload_field: string,
	on_json: bool,
	scopes:   map[^fi.Index]ow.Scope,
}

Search_Query_View :: struct {
	state: Search_Query_State,
	view: fi.Execution_View,
	snapshots: []Search_Partition,
	empty: fi.Index,
}

Search_Distance :: struct {
	name:  string,
	value: f64,
}

Search_Row :: struct {
	key:       string,
	scope:     ow.Scope,
	id:        u32,
	score:     f64,
	nearest:   f64,
	values:    [dynamic]Search_Distance,
	sort:      Search_Sort_Value,
	matches:   []string,
	explanation: retrieve.Explanation,
}

Search_Sort_Kind :: enum {
	Score,
	Id,
	Numeric,
	Text,
	Distance,
}

Search_Sort :: struct {
	kind:      Search_Sort_Kind,
	field:     string,
	desc:      bool,
	scoped:    bool,
	fold_text: bool,
	on_json: bool,
}

Search_Sort_Value :: struct {
	present: bool,
	number:  f64,
	text:    string,
}

cmd_ft_search :: proc(c: ^Conn, argv: [][]u8) {
	reader := search_scope()
	index := search_query_index(c, string(argv[1]), reader)
	if index == nil {
		return
	}
	request, error := search_request_parse(argv[3:], on_json = index.spec.on_json)
	if error != "" {
		reply_error(c, error)
		return
	}
	search_run(c, index, reader, string(argv[2]), &request)
}

search_query_index :: proc(c: ^Conn, name: string, reader: ow.Scope) -> ^Search_Index {
	index := search_find(name, reader)
	if index == nil {
		search_reply_missing(c, name)
		return nil
	}
	if !search_acl_allows(c, index) {
		reply_error(c, ERR_SEARCH_PERMISSIONS)
		return nil
	}
	return index
}

search_query_view_open :: proc(q: ^Search_Query_View, index: ^Search_Index, reader: ow.Scope, timeout_ms: Maybe(i64), in_keys: [][]u8 = nil) -> bool {
	a := context.temp_allocator
	q.state = {reader = reader, vis = access.vis, now = hash_now(), payload_field = index.spec.definition.payload_field, on_json = index.spec.on_json}
	timeout := u64(timeout_ms.? or_else ft_config_numbers[.Timeout])
	if timeout > 0 {
		start := mono_posix_ns()
		q.state.deadline = start + min(timeout, (max(u64) - start) / 1_000_000) * 1_000_000
	}
	if in_keys != nil {
		q.state.keys = make(map[string]bool, max(1, len(in_keys)), a)
		for key in in_keys {
			q.state.keys[string(key)] = true
		}
	}
	parts := search_partitions(index, reader)
	q.snapshots = make([]Search_Partition, len(parts), a)
	indexes := make([]^fi.Index, max(1, len(parts)), a)
	q.state.scopes = make(map[^fi.Index]ow.Scope, max(1, len(parts)), a)
	for part, i in parts {
		data := &part.data
		if search_part_snapshot(index, part, &q.snapshots[i]) {
			data = &q.snapshots[i].data
		}
		indexes[i] = data
		q.state.scopes[data] = part.scope
	}
	if len(parts) == 0 {
		if fi.init(&q.empty, index.spec.definition) != .None {
			return false
		}
		indexes[0] = &q.empty
	}
	q.view = {indexes = indexes, ctx = &q.state, accept = search_accept_document, payload = search_view_payload}
	if q.state.deadline != 0 {
		q.view.timed_out = search_deadline_reached
	}
	return true
}

search_query_view_close :: proc(q: ^Search_Query_View) {
	for &part in q.snapshots {
		if part.data.allocator.procedure != nil {
			search_part_destroy(&part)
		}
	}
	if q.empty.allocator.procedure != nil {
		fi.destroy(&q.empty)
	}
}

@(private = "file")
search_run :: proc(c: ^Conn, index: ^Search_Index, reader: ow.Scope, query: string, request: ^Search_Request) {
	if request.json_expand {
		if reason := search_expand_error(c, request.query_options.dialect, index.spec.on_json); reason != "" {
			reply_error(c, reason)
			return
		}
	}
	a := context.temp_allocator
	view: Search_Query_View
	defer search_query_view_close(&view)
	if !search_query_view_open(&view, index, reader, request.timeout_ms, request.in_keys) {
		reply_error(c, SEARCH_OUT_OF_MEMORY)
		return
	}
	if request.has_in_keys && view.state.keys == nil {
		view.state.keys = make(map[string]bool, 1, a)
	}
	indexes := view.view.indexes
	parsed, parse_error := fi.parse(indexes[0], query, request.query_options)
	defer fq.parsed_destroy(parsed)
	if parse_error.code != .None {
		reply_error(c, fq.error_reply(parse_error, a))
		return
	}
	search_apply_legacy_filters(&parsed.query, indexes[0], request.filters[:])
	if len(request.in_fields) > 0 {
		search_limit_text_fields(parsed, indexes[0], request.in_fields)
	}
	knn := search_knn(parsed)
	if knn != nil && knn.score_alias == "" {
		knn.score_alias = fmt.tprintf("__%s_score", index.spec.definition.fields[knn.field].name)
	}
	if len(view.snapshots) == 0 {
		if error := search_validate_empty_vectors(parsed, indexes[0]); error.code != .None {
			reply_error(c, fq.error_reply(error, a))
			return
		}
	}
	if error := search_snippet_validate(index, request); error != "" {
		reply_error(c, error)
		return
	}
	sort, sort_error := search_sort_spec(index, request, parsed, knn != nil)
	if sort_error != "" {
		reply_error(c, sort_error)
		return
	}
	rows, total, truncated, good := search_collect(c, &view, parsed, request.execute_options, knn)
	if !good {
		return
	}
	ordered := rows[:]
	if knn != nil {
		nearest := Search_Sort{kind = .Distance, scoped = labels_on}
		for &row in ordered {
			row.sort = {true, row.nearest, ""}
		}
		slice.sort_by_with_data(ordered, search_row_before, &nearest)
		total = int(min(knn.k, u64(len(ordered))))
		ordered = ordered[:total]
	}
	for &row in ordered {
		row.sort = search_row_sort_value(&row, sort, view.state.now)
	}
	slice.sort_by_with_data(ordered, search_row_before, &sort)
	if search_deadline_reached(&view.state) {
		search_execution_error(c, .Timeout, {})
		return
	}
	begin := min(request.offset, len(ordered))
	end := begin + min(request.count, len(ordered) - begin)
	if index.uses < max(i64) {
		index.uses += 1
	}
	search_profile_note(c, &parsed.query, end - begin, total, truncated, knn != nil, !request.no_content)
	search_reply_rows(c, index, request, ordered[begin:end], total, sort, view.state.now, truncated)
}

search_collect :: proc(c: ^Conn, view: ^Search_Query_View, parsed: ^fq.Parsed, options: fi.Execute_Options, knn: ^fq.Vector_Query) -> (rows: []Search_Row, total: int, truncated, good: bool) {
	opts := options
	opts.view = &view.view
	opts.builtin_patterns = true
	found := make([dynamic]Search_Row, context.temp_allocator)
	for data in view.view.indexes {
		result, problem, query_error := search_execute_partition(data, parsed, opts, knn)
		defer fi.result_destroy(&result)
		if problem != .None {
			search_execution_error(c, problem, query_error)
			return nil, 0, false, false
		}
		total += result.total
		truncated = truncated || result.truncated
		for hit in result.hits {
			doc := dt.get(&data.docs, hit.doc)
			row := Search_Row{key = doc.key, scope = view.state.scopes[data], id = hit.doc, score = hit.score, nearest = hit.distance}
			if matches := result.matches[hit.doc]; len(matches) != 0 {
				row.matches = make([]string, len(matches), context.temp_allocator)
				for term, i in matches {
					row.matches[i] = strings.clone(term, context.temp_allocator)
				}
			}
			if explanation, exists := result.explanations[hit.doc]; exists {
				row.explanation = search_explanation_clone(explanation)
			}
			if result.knn {
				search_add_distance(&row, result.knn_alias, hit.distance)
			}
			for yield in result.yields {
				if value, known := search_yield_value(yield.hits, hit.doc); known {
					search_add_distance(&row, yield.alias, value)
				}
			}
			append(&found, row)
		}
	}
	if opts.scorer_kind == .Norm {
		maximum := 0.0
		for row in found {
			maximum = max(maximum, row.score)
		}
		for &row in found {
			raw := row.score
			row.score = raw / maximum if maximum != 0 else 0
			if opts.explain_scores {
				row.explanation.text = fmt.tprintf("Final BM25STD.NORM: %.2f = Original Score: %.2f / Max Score: %.2f", row.score, raw, maximum)
			}
		}
	}
	return found[:], total, truncated, true
}

search_explanation_clone :: proc(input: retrieve.Explanation) -> retrieve.Explanation {
	a := context.temp_allocator
	out := retrieve.Explanation{text = strings.clone(input.text, a)}
	if len(input.children) > 0 {
		out.children = make([]retrieve.Explanation, len(input.children), a)
		for child, i in input.children {
			out.children[i] = search_explanation_clone(child)
		}
	}
	return out
}

search_view_payload :: proc(ctx: rawptr, data: ^fi.Index, id: u32, key: string) -> string {
	state := (^Search_Query_State)(ctx)
	found, _ := search_document_payload(state.scopes[data], key, state.payload_field, state.now, state.on_json)
	return found
}

search_document_payload :: proc(scope: ow.Scope, key, name: string, now: u64, on_json: bool = false) -> (string, bool) {
	if name != "" {
		if on_json {
			object := cast(^Json_Object)search_document_exact(scope, key, true)
			if object != nil {
				if value := search_json_first(object.doc.root, name); value != nil {
					return search_json_scalar(value)
				}
			}
			return "", false
		}
		if h := search_hash_exact(scope, key); h != nil {
			value, live := ht.get(h, transmute([]u8)name, now, false)
			if .Live in live {
				buf: [lp.DECIMAL_BUFFER_BYTES]u8
				raw := ht.value_bytes(value, &buf)
				return strings.clone(string(raw), context.temp_allocator) if value.is_int else string(raw), true
			}
		}
	}
	return "", false
}

search_deadline_reached :: proc(ctx: rawptr) -> bool {
	deadline := (^Search_Query_State)(ctx).deadline
	return deadline != 0 && mono_posix_ns() >= deadline
}

search_accept_document :: proc(ctx: rawptr, data: ^fi.Index, id: u32, key: string) -> bool {
	state := (^Search_Query_State)(ctx)
	if state.keys != nil && !state.keys[key] {
		return false
	}
	scope, exists := state.scopes[data]
	if !exists || !search_document_live(search_document_exact(scope, key, state.on_json), state.on_json, state.now) {
		return false
	}
	if !labels_on {
		return true
	}
	saved := store_no_touch
	store_no_touch = true
	defer store_no_touch = saved
	db, _, slot := label_resolve(0, transmute([]u8)key, state.reader.label, state.vis, state.reader.owner, false)
	return slot >= 0 && search_db_scope(db) == scope
}

search_limit_text_fields :: proc(parsed: ^fq.Parsed, data: ^fi.Index, names: [][]u8) {
	mask: fq.Field_Mask
	for name in names {
		if field, found := fi.field_index(data, string(name)); found {
			if ordinal := data.slots[field].ordinal; ordinal >= 0 {
				mask |= fq.Field_Mask(1) << uint(ordinal)
			}
		}
	}
	search_apply_text_mask(&parsed.query, parsed.query.root, mask)
}

@(private = "file")
search_apply_text_mask :: proc(query: ^fq.Query, id: fq.Node_Id, mask: fq.Field_Mask) {
	if id == fq.NO_NODE {
		return
	}
	node := fq.node_get(query, id)
	#partial switch node.kind {
	case .Tag:
		return
	case .Token, .Phrase, .Prefix, .Suffix, .Infix, .Fuzzy, .Wildcard_Pattern:
		node.mask &= mask
	case:
	}
	for child in node.children {
		search_apply_text_mask(query, child, mask)
	}
}

search_knn :: proc(parsed: ^fq.Parsed) -> ^fq.Vector_Query {
	if parsed.query.root != fq.NO_NODE {
		root := fq.node_get(&parsed.query, parsed.query.root)
		if root.kind == .Vector && root.vector.kind == .Knn {
			return root.vector
		}
	}
	return nil
}

search_validate_empty_vectors :: proc(parsed: ^fq.Parsed, data: ^fi.Index) -> fq.Error {
	parser := fq.Parser{q = &parsed.query, schema = &data.query_schema, allocator = context.temp_allocator, dialect = parsed.query.dialect}
	for node, i in parsed.query.nodes {
		if node.kind == .Vector {
			fq.validate_vector(&parser, fq.Node_Id(i))
			if parser.failed {
				return parser.err
			}
		}
	}
	return {}
}

@(private = "file")
search_execute_partition :: proc(data: ^fi.Index, parsed: ^fq.Parsed, options: fi.Execute_Options, knn: ^fq.Vector_Query) -> (fi.Result, fi.Error, fq.Error) {
	if !labels_on || knn == nil || data.definition.fields[knn.field].vector.method != .Flat || knn.k == 0 {
		return fi.execute(data, parsed, options)
	}
	prior := knn.k
	knn.k = max(knn.k, u64(fi.vector_count(data, knn.field)))
	defer knn.k = prior
	return fi.execute(data, parsed, options)
}

@(private = "file")
search_yield_value :: proc(hits: []fi.Vector_Hit, id: u32) -> (f64, bool) {
	lo, hi := 0, len(hits)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if hits[mid].doc < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(hits) && hits[lo].doc == id {
		return hits[lo].distance, true
	}
	return 0, false
}

search_add_distance :: proc(row: ^Search_Row, name: string, value: f64) {
	if name == "" {
		return
	}
	if row.values == nil {
		row.values = make([dynamic]Search_Distance, 1, context.temp_allocator)
		row.values[0] = {name, value}
		return
	}
	append(&row.values, Search_Distance{name, value})
}

search_execution_error :: proc(c: ^Conn, problem: fi.Error, query_error: fq.Error) {
	#partial switch problem {
	case .Query_Error:
		reply_error(c, fq.error_reply(query_error, context.temp_allocator))
	case .Timeout:
		reply_error(c, "Timeout limit was reached")
	case .Unsupported:
		reply_error(c, "SEARCH_OPTION_INVALID Query is not supported")
	case:
		reply_error(c, fmt.tprintf("ERR search execution failed (%v)", problem))
	}
}

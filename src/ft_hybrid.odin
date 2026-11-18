package main

import "core:fmt"
import "core:c/libc"
import "core:strings"
import "retrieve"
import "core:slice"
import dt "doctable"
import fi "ftindex"
import fq "ftquery"

FT_Hybrid_Hit :: struct {
	doc: Search_Row,
	text_rank, vector_rank: int,
	text_score, vector_score: f64,
}

cmd_ft_hybrid :: proc(c: ^Conn, argv: [][]u8) {
	started := mono_posix_ns()
	reader := search_scope()
	index := search_query_index(c, string(argv[1]), reader)
	if index == nil {
		return
	}
	req: FT_Hybrid_Request
	if err := ft_hybrid_parse(argv[2:], &req); err != "" {
		reply_error(c, err)
		return
	}
	view: Search_Query_View
	defer search_query_view_close(&view)
	if !search_query_view_open(&view, index, reader, req.pipeline.search.timeout_ms) {
		reply_error(c, SEARCH_OUT_OF_MEMORY)
		return
	}
	data := view.view.indexes[0]
	field, found := fi.field_index(data, req.field)
	if !found {
		reply_error(c, ft_error("SEARCH_SYNTAX Unknown field `", req.field, "`"))
		return
	}
	vector_field := &data.definition.fields[field]
	if vector_field.kind != .Vector {
		reply_error(c, ft_error("SEARCH_SYNTAX Expected a VECTOR field `", req.field, "`"))
		return
	}
	opts := req.pipeline.search.query_options
	found = false
	for param in opts.params {
		if param.name == req.parameter {
			req.vector.blob = transmute([]u8)param.value
			found = true
			break
		}
	}
	if !found {
		reply_error(c, ft_error("SEARCH_PARAM_NOT_FOUND Parameter not found `", req.parameter, "`"))
		return
	}
	if count, expected := len(req.vector.blob), fi.field_vector_bytes(data, field); count != expected {
		reply_error(c, fmt.tprintf("SEARCH_QUERY_BAD Error parsing vector similarity query: query vector blob size (%d) does not match index's expected size (%d).", count, expected))
		return
	}
	if vector_field.vector.method == .Flat && (req.vector.ef_runtime != 0 || req.vector.epsilon != 0) {
		reply_error(c, "SEARCH_OPTION_INVALID Invalid option (Error parsing vector similarity parameters)")
		return
	}
	req.vector.field = field
	parsed, problem := fi.parse(data, req.query, opts)
	defer fq.parsed_destroy(parsed)
	if problem.code != .None {
		reply_error(c, fq.error_reply(problem, context.temp_allocator))
		return
	}
	if search_knn(parsed) != nil {
		reply_error(c, "SEARCH_OPTION_INVALID Query is not supported")
		return
	}
	defer fq.parsed_destroy(req.vector.filter)
	if req.has_filter {
		req.vector.filter, problem = fi.parse(data, req.filter, opts)
		if problem.code != .None {
			reply_error(c, fq.error_reply(problem, context.temp_allocator))
			return
		}
	}
	exec := req.pipeline.search.execute_options
	exec.view = &view.view
	exec.builtin_patterns = true
	exec.unscored_tags = true
	exec.explain_scores = req.explain
	if !labels_on && !req.pipeline.cursor.enabled && exec.scorer_kind != .Norm {
		exec.limit = req.window
	}
	text_docs, _, warn, good := search_collect(c, &view, parsed, exec, nil)
	if !good {
		return
	}
	sort := Search_Sort{kind = .Score, scoped = labels_on}
	for &doc in text_docs {
		doc.sort = {true, doc.score, ""}
	}
	slice.sort_by_with_data(text_docs, search_row_before, &sort)
	vectors, valid := ft_hybrid_collect_vector(c, &view, &req, exec)
	if !valid {
		return
	}
	if req.pipeline.cursor.enabled {
		if ft_hybrid_start_cursors(c, index, &req, text_docs, vectors, &view.state, warn) && index.uses < max(i64) {
			index.uses += 1
		}
		return
	}
	fused := ft_hybrid_fuse(&req, text_docs, vectors)
	if !req.pipeline.no_sort {
		ft_hybrid_sort(fused)
	}
	known := make(map[string]bool, context.temp_allocator)
	rows, err := ft_hybrid_rows(index, &req, fused, &known, view.state.now)
	if err != "" {
		reply_error(c, err)
		return
	}
	result, pipeline_error := ft_pipeline_run(index, &req.pipeline, rows, known, &view.state, true, c.search_profile)
	if pipeline_error != "" {
		reply_error(c, pipeline_error)
		return
	}
	if search_deadline_reached(&view.state) {
		search_execution_error(c, .Timeout, {})
		return
	}
	if index.uses < max(i64) {
		index.uses += 1
	}
	search_profile_note(c, &parsed.query, min(req.window, len(text_docs)), len(text_docs), warn, false, result.loaded)
	elapsed := f64(mono_posix_ns()-started) / 1e6 if !labels_on || access.top else 0
	profile := c.search_profile
	if c.resp < RESP3 && profile != nil {
		reply_array(c, 9)
	} else {
		reply_map(c, 4 + int(profile != nil))
	}
	reply_simple(c, "total_results")
	reply_int(c, i64(result.total))
	reply_simple(c, "results")
	reply_array(c, len(result.rows))
	for &row in result.rows {
		reply_map(c, len(row.cells) + int(row.doc.explanation.text != ""))
		if row.doc.explanation.text != "" {
			reply_simple(c, "score")
			search_reply_score(c, row.doc.score, &row.doc.explanation, true)
		}
		for field in row.cells {
			reply_bulk_str(c, field.name)
			ft_reply_value(c, field.value)
		}
	}
	reply_simple(c, "warnings")
	ft_reply_warnings(c, warn)
	reply_simple(c, "execution_time")
	reply_double(c, elapsed)
	if profile != nil {
		profile.vector_count = len(vectors)
		profile.fused_count = len(fused)
		profile.ranged = req.vector.range
		if c.resp >= RESP3 {
			reply_simple(c, "Profile")
		}
		search_profile_hybrid(c, profile, elapsed, !req.pipeline.no_sort)
	}
}

ft_hybrid_collect_vector :: proc(c: ^Conn, view: ^Search_Query_View, req: ^FT_Hybrid_Request, opts: fi.Execute_Options) -> ([]Search_Row, bool) {
	local_opts := opts
	out := make([dynamic]Search_Row, context.temp_allocator)
	for data in view.view.indexes {
		found := make([dynamic]fi.Vector_Hit, context.temp_allocator)
		vector := req.vector
		if labels_on && !vector.range && data.definition.fields[vector.field].vector.method == .Flat {
			vector.k = max(vector.k, fi.vector_count(data, vector.field))
		}
		err, problem := fi.vector_branch(data, &vector, &local_opts, &found)
		if err != .None {
			search_execution_error(c, err, problem)
			return nil, false
		}
		metric := data.definition.fields[vector.field].vector.metric
		for hit in found {
			doc := dt.get(&data.docs, hit.doc)
			append(&out, Search_Row{
				key = doc.key, scope = view.state.scopes[data], id = hit.doc,
				nearest = hit.distance, score = fi.vector_similarity(metric, hit.distance), sort = {true, hit.distance, ""},
			})
		}
	}
	sort := Search_Sort{kind = .Distance, scoped = labels_on}
	slice.sort_by_with_data(out[:], search_row_before, &sort)
	if !req.vector.range && len(out) > req.vector.k {
		return out[:req.vector.k], true
	}
	return out[:], true
}

ft_hybrid_fuse :: proc(req: ^FT_Hybrid_Request, terms, vectors: []Search_Row) -> []FT_Hybrid_Hit {
	a := context.temp_allocator
	text_hits := terms[:min(len(terms), req.window)]
	vector_hits := vectors[:min(len(vectors), req.window)]
	result := make([dynamic]FT_Hybrid_Hit, 0, len(text_hits) + len(vector_hits), a)
	ids := make(map[string]int, a)
	for doc, rank in text_hits {
		next := FT_Hybrid_Hit{doc = doc, text_rank = rank + 1, text_score = doc.score}
		next.doc.score = req.alpha * doc.score if req.linear else 1 / (req.constant + f64(rank + 1))
		ids[doc.key] = len(result)
		append(&result, next)
	}
	for doc, rank in vector_hits {
		pos, exists := ids[doc.key]
		if !exists {
			pos = len(result)
			vector_doc := doc
			vector_doc.score = 0
			append(&result, FT_Hybrid_Hit{doc = vector_doc})
		}
		row := &result[pos]
		row.vector_rank, row.vector_score = rank + 1, vector_hits[rank].score
		row.doc.score += req.beta * row.vector_score if req.linear else 1 / (req.constant + f64(rank + 1))
	}
	return result[:]
}

ft_hybrid_sort :: proc(hits: []FT_Hybrid_Hit) {
	sort := Search_Sort{kind = .Score, scoped = labels_on}
	slice.sort_by_with_data(hits, proc(a, b: FT_Hybrid_Hit, order: rawptr) -> bool {
		left, right := a.doc, b.doc
		left.sort, right.sort = {true, left.score, ""}, {true, right.score, ""}
		return search_row_before(left, right, order)
	}, &sort)
}

ft_hybrid_rows :: proc(index: ^Search_Index, req: ^FT_Hybrid_Request, hits: []FT_Hybrid_Hit, known: ^map[string]bool, now: u64) -> ([]FT_Row, string) {
	rows := make([]FT_Row, len(hits), context.temp_allocator)
	fused_name := req.fused_alias if req.fused_alias != "" else "__score"
	load := false
	for step in req.pipeline.steps {
		load = load || step.kind == .Load
	}
	if req.fused_alias != "" &&
	   (req.fused_alias == req.text_alias || req.fused_alias == req.vector_alias || (!load && req.fused_alias == "__key")) {
		return nil, ft_error("SEARCH_FIELD_DUP Could not create score alias, name already exists in query, score alias: ", req.fused_alias)
	}
	if req.text_alias != "" { known^[req.text_alias] = true }
	if req.vector_alias != "" { known^[req.vector_alias] = true }
	if !load || req.fused_alias != "" { known^[fused_name] = true }
	if !load { known^["__key"] = true }
	for &hit, i in hits {
		row := &rows[i]
		row.doc, row.order = hit.doc, i
		row.doc.explanation = {}
		if req.explain {
			row.doc.explanation = ft_hybrid_explanation(req, &hit)
		}
		row.doc.values = nil
		if req.text_alias != "" && hit.text_rank != 0 {
			ft_set_cell(row, req.text_alias, hit.text_score)
		}
		if !load {
			ft_set_cell(row, "__key", hit.doc.key)
			if req.fused_alias == "" {
				ft_set_cell(row, fused_name, hit.doc.score)
			}
		} else {
			search_add_distance(&row.doc, fused_name, hit.doc.score)
			if req.vector_alias != "" && req.vector_alias != fused_name && hit.vector_rank != 0 {
				search_add_distance(&row.doc, req.vector_alias, hit.vector_score)
			}
		}
	}
	schema := ft_schema_columns(index, false)
	for &step in req.pipeline.steps {
		if step.kind != .Load {
			continue
		}
		if req.fused_alias != "" {
			for field in step.fields {
				if field.name == req.fused_alias {
					return nil, ft_error("SEARCH_FIELD_DUP Could not create score alias, name already exists in query, score alias: ", req.fused_alias)
				}
			}
		}
		ft_pipeline_load(rows, &step, schema, known, now, index.spec.on_json, req.pipeline.search.query_options.dialect)
	}
	for hit, i in hits {
		row := &rows[i]
		if req.vector_alias != "" && req.vector_alias != fused_name && hit.vector_rank != 0 {
			ft_set_cell(row, req.vector_alias, hit.vector_score)
		}
		if req.fused_alias != "" {
			ft_set_cell(row, fused_name, hit.doc.score)
		}
	}
	return rows, ""
}

ft_hybrid_cursor_result :: proc(index: ^Search_Index, req: ^FT_Hybrid_Request, docs: []Search_Row, alias: string, now: u64, warn: bool) -> FT_Pipeline_Result {
	rows := ft_pipeline_rows(docs, false)
	known := make(map[string]bool, context.temp_allocator)
	schema := ft_schema_columns(index, false)
	loaded := false
	for &row in rows {
		if alias != "" {
			ft_set_cell(&row, alias, row.doc.score)
		}
	}
	for &step in req.pipeline.steps {
		if step.kind == .Load {
			loaded = true
			ft_pipeline_load(rows, &step, schema, &known, now, index.spec.on_json, req.pipeline.search.query_options.dialect)
		}
	}
	if !loaded {
		for &row in rows {
			ft_set_cell(&row, "__key", row.doc.key)
		}
	}
	return FT_Pipeline_Result{rows = rows, total = len(rows), buffered = true, warn = warn}
}

ft_hybrid_start_cursors :: proc(c: ^Conn, index: ^Search_Index, req: ^FT_Hybrid_Request, text_docs, vectors: []Search_Row, state: ^Search_Query_State, warn: bool) -> bool {
	text_result := ft_hybrid_cursor_result(index, req, text_docs, req.text_alias, state.now, warn)
	vector_result := ft_hybrid_cursor_result(index, req, vectors, req.vector_alias, state.now, false)
	text_cursor := ft_cursor_store(c, index, state, req.pipeline.cursor, text_result, 0, text_docs, true)
	if text_cursor == nil {
		reply_error(c, ft_cursor_full())
		return false
	}
	vector_cursor := ft_cursor_store(c, index, state, req.pipeline.cursor, vector_result, 0, vectors, true)
	if vector_cursor == nil {
		ft_cursor_delete(text_cursor)
		reply_error(c, ft_cursor_full())
		return false
	}
	reply_map(c, 3)
	reply_simple(c, "SEARCH")
	reply_int(c, text_cursor.id)
	reply_simple(c, "VSIM")
	reply_int(c, vector_cursor.id)
	reply_simple(c, "warnings")
	ft_reply_warnings(c, warn)
	return true
}

ft_explanation :: proc(text: string, children: ..retrieve.Explanation) -> retrieve.Explanation {
	out := retrieve.Explanation{text = text}
	if len(children) > 0 {
		out.children = make([]retrieve.Explanation, len(children), context.temp_allocator)
		copy(out.children, children)
	}
	return out
}

ft_hybrid_explanation :: proc(req: ^FT_Hybrid_Request, hit: ^FT_Hybrid_Hit) -> retrieve.Explanation {
	method := "KNN" if !req.vector.range else "RANGE"
	text_score := "0 [text: no match]"
	vector_score := "0 [vector: no match]"
	text_branch, vector_branch: retrieve.Explanation
	kind := req.pipeline.search.execute_options.scorer_kind
	head := fmt.tprintf("Text scorer: %s", fi.SCORER_NAMES[kind])
	tree: string
	if req.linear {
		tree = fmt.tprintf("Hybrid score (LINEAR: alpha=%.4f, beta=%.4f, window=%d)", req.alpha, req.beta, req.window)
		text_branch.text = "text contribution = <no match>"
		if hit.text_rank != 0 {
			text_score = fmt.tprintf("%.4f * %.4f", req.alpha, hit.text_score)
			text_branch = ft_explanation(fmt.tprintf("text contribution = %s = %.4f", text_score, req.alpha * hit.text_score),
				ft_explanation(head, ft_explanation(fmt.tprintf("normalized text score = %.4f", hit.text_score)), hit.doc.explanation))
		}
		details := ft_explanation("vector contribution = <no match>")
		vector_branch = ft_explanation(fmt.tprintf("vector branch (%s)", method), details)
		if hit.vector_rank != 0 {
			vector_score = fmt.tprintf("%.4f * %.4f", req.beta, hit.vector_score)
			vector_branch = ft_explanation(fmt.tprintf("vector branch (%s)", method),
				ft_explanation(fmt.tprintf("vector contribution = %s = %.4f", vector_score, req.beta * hit.vector_score)),
				ft_explanation(fmt.tprintf("normalized vector score = %.4f", hit.vector_score)))
		}
	} else {
		tree = fmt.tprintf("Hybrid score (RRF: window=%d, constant=%.2f)", req.window, req.constant)
		text_branch.text = "text rank = <no match>"
		if hit.text_rank != 0 {
			text_score = fmt.tprintf("1 / (constant %.2f + rank %d)", req.constant, hit.text_rank)
			text_branch = ft_explanation(fmt.tprintf("text rank = %d", hit.text_rank), ft_explanation(head, hit.doc.explanation))
		}
		details := ft_explanation("vector rank = <no match>")
		if hit.vector_rank != 0 {
			vector_score = fmt.tprintf("1 / (constant %.2f + rank %d)", req.constant, hit.vector_rank)
			details.text = fmt.tprintf("vector rank = %d", hit.vector_rank)
		}
		vector_branch = ft_explanation(fmt.tprintf("vector branch (%s)", method), details)
	}
	buf: [48]u8
	n := int(libc.snprintf(raw_data(buf[:]), len(buf), "%.17g", hit.doc.score))
	value := strings.clone(string(buf[:clamp(n, 0, len(buf) - 1)]), context.temp_allocator)
	return ft_explanation(fmt.tprintf("final score: %s + %s = %s", text_score, vector_score, value), ft_explanation(tree, text_branch, vector_branch))
}

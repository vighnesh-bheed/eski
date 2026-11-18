package main

import "core:fmt"
import "core:slice"
import fi "ftindex"
import fq "ftquery"

cmd_ft_aggregate :: proc(c: ^Conn, argv: [][]u8) {
	reader := search_scope()
	index := search_query_index(c, string(argv[1]), reader)
	if index == nil {
		return
	}
	pipeline: FT_Pipeline
	if err := ft_pipeline_parse(argv[3:], false, &pipeline, on_json = index.spec.on_json); err != "" {
		reply_error(c, err)
		return
	}
	if pipeline.expand {
		if reason := search_expand_error(c, pipeline.search.query_options.dialect, index.spec.on_json); reason != "" {
			reply_error(c, reason)
			return
		}
	}
	view: Search_Query_View
	defer search_query_view_close(&view)
	if !search_query_view_open(&view, index, reader, pipeline.search.timeout_ms, pipeline.search.in_keys) {
		reply_error(c, SEARCH_OUT_OF_MEMORY)
		return
	}
	if pipeline.search.has_in_keys && view.state.keys == nil {
		view.state.keys = make(map[string]bool, 1, context.temp_allocator)
	}
	data := view.view.indexes[0]
	parsed, error := fi.parse(data, string(argv[2]), pipeline.search.query_options)
	defer fq.parsed_destroy(parsed)
	if error.code == .None && len(view.snapshots) == 0 {
		error = search_validate_empty_vectors(parsed, data)
	}
	if error.code != .None {
		reply_error(c, fq.error_reply(error, context.temp_allocator))
		return
	}
	known := make(map[string]bool, context.temp_allocator)
	knn := search_knn(parsed)
	for node in parsed.query.nodes {
		if node.kind == .Vector && node.vector.score_alias != "" {
			known[node.vector.score_alias] = true
		}
	}
	if knn != nil && knn.score_alias == "" {
		knn.score_alias = fmt.tprintf("__%s_score", index.spec.definition.fields[knn.field].name)
		known[knn.score_alias] = true
	}
	if pipeline.add_scores {
		known["__score"] = true
	}
	docs, _, truncated, good := search_collect(c, &view, parsed, pipeline.search.execute_options, knn)
	if !good {
		return
	}
	order := Search_Sort{kind = .Id, scoped = labels_on}
	if knn != nil {
		order.kind = .Distance
		for &doc in docs {
			doc.sort = {true, doc.nearest, ""}
		}
	}
	slice.sort_by_with_data(docs, search_row_before, &order)
	if knn != nil {
		docs = docs[:int(min(knn.k, u64(len(docs))))]
	}
	rows := ft_pipeline_rows(docs, pipeline.add_scores)
	result, err := ft_pipeline_run(index, &pipeline, rows, known, &view.state, false, c.search_profile)
	if err != "" {
		reply_error(c, err)
		return
	}
	result.warn = truncated
	if search_deadline_reached(&view.state) {
		search_execution_error(c, .Timeout, {})
		return
	}
	if index.uses < max(i64) {
		index.uses += 1
	}
	search_profile_note(c, &parsed.query, len(result.rows), len(docs), result.warn, knn != nil, result.loaded)
	if pipeline.cursor.enabled {
		ft_cursor_reply_start(c, index, &view.state, pipeline.cursor, result, docs)
		return
	}
	ft_reply_aggregate(c, result.rows, result.total, result.warn, result.expand)
}

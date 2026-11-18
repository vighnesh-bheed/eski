package main

import "core:slice"
import "core:strings"
import dt "doctable"
import fi "ftindex"
import fq "ftquery"
import "roaring"
import "tagindex"
import "termdict"

cmd_ft_explain :: proc(c: ^Conn, argv: [][]u8) {
	search_explain(c, argv, false)
}

cmd_ft_explaincli :: proc(c: ^Conn, argv: [][]u8) {
	search_explain(c, argv, true)
}

search_explain :: proc(c: ^Conn, argv: [][]u8, cli: bool) {
	reader := search_scope()
	index := search_query_index(c, string(argv[1]), reader)
	if index == nil {
		return
	}
	request, err := search_request_parse(argv[3:])
	if err != "" {
		reply_error(c, err)
		return
	}
	view: Search_Query_View
	defer search_query_view_close(&view)
	if !search_query_view_open(&view, index, reader, request.timeout_ms) {
		reply_error(c, SEARCH_OUT_OF_MEMORY)
		return
	}
	data := view.view.indexes[0]
	request.query_options.explain = true
	parsed, problem := fi.parse(data, string(argv[2]), request.query_options)
	defer fq.parsed_destroy(parsed)
	if problem.code != .None {
		reply_error(c, fq.error_reply(problem, context.temp_allocator))
		return
	}
	search_apply_legacy_filters(&parsed.query, data, request.filters[:])
	if len(request.in_fields) > 0 {
		search_limit_text_fields(parsed, data, request.in_fields)
	}
	result := "<empty>\n"
	if parsed.query.root != fq.NO_NODE {
		result = fq.explain(&parsed.query, &data.query_schema, context.temp_allocator)
	}
	if !cli {
		reply_bulk_str(c, result)
		return
	}
	lines, _ := strings.split(result, "\n", context.temp_allocator)
	reply_array(c, len(lines))
	for line in lines {
		search_reply_string(c, line)
	}
}

cmd_ft_tagvals :: proc(c: ^Conn, argv: [][]u8) {
	reader := search_scope()
	index := search_query_index(c, string(argv[1]), reader)
	if index == nil {
		return
	}
	view: Search_Query_View
	defer search_query_view_close(&view)
	if !search_query_view_open(&view, index, reader, nil) {
		reply_error(c, SEARCH_OUT_OF_MEMORY)
		return
	}
	field, found := fi.field_index(view.view.indexes[0], string(argv[2]))
	if !found {
		reply_error(c, "SEARCH_ATTR_BAD No such field")
		return
	}
	if index.spec.definition.fields[field].kind != .Tag {
		reply_error(c, "SEARCH_ATTR_BAD Not a tag field")
		return
	}
	items := make(map[string]bool, context.temp_allocator)
	for data in view.view.indexes {
		slot := data.slots[field].tag
		if slot == nil {
			continue
		}
		dict := &slot.values.values
		iter: termdict.Iterator
		termdict.iterator_seek(&iter, dict, "")
		defer termdict.iterator_close(&iter)
		for word, id, live := termdict.iterator_next(&iter); live; word, id, live = termdict.iterator_next(&iter) {
			if items[word] {
				continue
			}
			docs := tagindex.bitmap(&slot.values, id)
			if docs == nil {
				continue
			}
			iterator: roaring.Iterator
			roaring.iterator_init(&iterator, docs)
			for doc, valid := roaring.next(&iterator); valid; doc, valid = roaring.next(&iterator) {
				if entry := dt.get(&data.docs, doc); entry != nil && search_accept_document(&view.state, data, doc, entry.key) {
					items[word] = true
					break
				}
			}
		}
	}
	out := make([dynamic]string, 0, len(items), context.temp_allocator)
	for item in items {
		append(&out, item)
	}
	slice.sort(out[:])
	reply_set(c, len(out))
	for item in out {
		reply_bulk_str(c, item)
	}
}

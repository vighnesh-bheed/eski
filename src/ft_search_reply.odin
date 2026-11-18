package main

import "core:c/libc"
import "core:fmt"
import fi "ftindex"
import fq "ftquery"
import ht "hashtype"
import lp "listpack"
import "retrieve"
import "text"
import zt "zsettype"

@(private = "package")
search_sort_spec :: proc(index: ^Search_Index, request: ^Search_Request, parsed: ^fq.Parsed, knn: bool) -> (Search_Sort, string) {
	out := Search_Sort{scoped = labels_on, desc = request.sort_desc, on_json = index.spec.on_json}
	if !request.has_sort {
		out.kind = .Id if knn else .Score
		return out, ""
	}
	name := request.sort_by
	for node in parsed.query.nodes {
		if node.kind == .Vector && name != "" && node.vector.score_alias == name {
			out.kind, out.field = .Distance, name
			return out, ""
		}
	}
	for field, i in index.spec.definition.fields {
		if field.name == name {
			out.kind = .Numeric if field.kind == .Numeric else .Text
			out.field = field.source
			out.fold_text = field.sortable && !index.spec.attributes[i].unf
			return out, ""
		}
	}
	return {}, search_reply_clean_error(fmt.tprintf("SEARCH_PROP_NOT_FOUND Property `%s` not loaded nor in schema", name))
}

@(private = "file")
search_reply_clean_error :: proc(s: string) -> string {
	buf := make([]u8, len(s), context.temp_allocator)
	for c, i in transmute([]u8)s {
		buf[i] = ' ' if c == '\r' || c == '\n' else c
	}
	return string(buf)
}

search_row_sort_value :: proc(row: ^Search_Row, spec: Search_Sort, now: u64) -> Search_Sort_Value {
	switch spec.kind {
	case .Score:
		return {true, row.score, ""}
	case .Id:
		return {}
	case .Distance:
		if value, found := search_row_distance(row, spec.field); found {
			return {true, value, ""}
		}
	case .Numeric, .Text:
		if spec.on_json {
			object := cast(^Json_Object)search_document_exact(row.scope, row.key, true)
			if value, ok := search_json_sort_value(object, spec.field, spec.kind == .Numeric); ok {
				if spec.kind == .Numeric {
					return {true, value.(f64), ""}
				}
				return {true, 0, value.(string)}
			}
			return {}
		}
		h := search_hash_exact(row.scope, row.key)
		if h == nil {
			return {}
		}
		field, state := ht.get(h, transmute([]u8)spec.field, now, false)
		if .Live not_in state {
			return {}
		}
		numeric: [lp.DECIMAL_BUFFER_BYTES]u8
		bytes := ht.value_bytes(field, &numeric)
		if spec.kind == .Numeric {
			v, ok := fi.number_parse(string(bytes))
			return {ok, v, ""}
		}
		if spec.fold_text {
			folded := make([dynamic]u8, 0, len(bytes), context.temp_allocator)
			text.fold(bytes, nil, &folded)
			return {true, 0, string(folded[:])}
		}
		if field.is_int {
			owned := make([]u8, len(bytes), context.temp_allocator)
			copy(owned, bytes)
			return {true, 0, string(owned)}
		}
		return {true, 0, string(bytes)}
	}
	return {}
}

search_row_before :: proc(a, b: Search_Row, ctx: rawptr) -> bool {
	sort := (^Search_Sort)(ctx)
	left, right := a.sort, b.sort
	if left.present != right.present {
		return left.present
	}
	if left.present {
		if sort.kind == .Text {
			if left.text != right.text {
				return left.text > right.text if sort.desc else left.text < right.text
			}
		} else {
			x, y := left.number, right.number
			if (x != x) != (y != y) {
				return x == x
			}
			if x == x && x != y {
				return x > y if sort.desc || sort.kind == .Score else x < y
			}
		}
	}
	if sort.scoped {
		return a.key < b.key
	}
	return a.id > b.id if sort.desc else a.id < b.id
}

search_row_distance :: proc(row: ^Search_Row, name: string) -> (f64, bool) {
	for distance in row.values {
		if distance.name == name {
			return distance.value, true
		}
	}
	return 0, false
}

search_reply_rows :: proc(c: ^Conn, index: ^Search_Index, request: ^Search_Request, rows: []Search_Row, total: int, sort: Search_Sort, now: u64, truncated: bool) {
	n := int(request.with_scores) + int(request.with_sort_keys) + int(!request.no_content) + int(request.with_payloads)
	if c.resp >= RESP3 {
		reply_map(c, 5)
		reply_simple(c, "attributes")
		reply_array(c, 0)
		reply_simple(c, "format")
		reply_simple(c, "EXPAND" if request.json_expand else "STRING")
		reply_simple(c, "results")
		reply_array(c, len(rows))
	} else {
		reply_array(c, 1 + len(rows) * (1 + n))
		reply_int(c, i64(total))
	}
	for &row in rows {
		if c.resp >= RESP3 {
			reply_map(c, 2 + n)
			reply_simple(c, "id")
		}
		reply_bulk_str(c, row.key)
		if request.with_scores {
			if c.resp >= RESP3 { reply_simple(c, "score") }
			search_reply_score(c, row.score, &row.explanation, request.execute_options.explain_scores)
		}
		if request.with_payloads {
			if c.resp >= RESP3 { reply_simple(c, "payload") }
			if payload, found := search_document_payload(row.scope, row.key, index.spec.definition.payload_field, now, index.spec.on_json); found {
				reply_bulk_str(c, payload)
			} else {
				reply_null(c)
			}
		}
		if request.with_sort_keys {
			if c.resp >= RESP3 { reply_simple(c, "sortkey") }
			search_reply_sort_key(c, &row, sort.kind)
		}
		if !request.no_content {
			if c.resp >= RESP3 { reply_simple(c, "extra_attributes") }
			search_reply_fields(c, index, request, &row, sort, now)
		}
		if c.resp >= RESP3 {
			reply_simple(c, "values")
			reply_array(c, 0)
		}
	}
	if c.resp >= RESP3 {
		reply_simple(c, "total_results")
		reply_int(c, i64(total))
		reply_simple(c, "warning")
		reply_array(c, int(truncated))
		if truncated {
			reply_simple(c, "Max prefix expansions limit was reached")
		}
	}
}

@(private = "file")
search_reply_sort_key :: proc(c: ^Conn, row: ^Search_Row, sort: Search_Sort_Kind) {
	if !row.sort.present || sort == .Id || sort == .Score {
		reply_null(c)
		return
	}
	if sort == .Text {
		val := make([]u8, len(row.sort.text) + 1, context.temp_allocator)
		val[0] = '$'
		copy(val[1:], transmute([]u8)row.sort.text)
		reply_bulk(c, val)
		return
	}
	buf: [48]u8
	buf[0] = '#'
	n := zt.format_g17(buf[1:], row.sort.number)
	reply_bulk(c, buf[:1 + n])
}

@(private = "file")
Search_Reply_Field :: struct {
	name, source: string,
	value:    ht.Value,
	distance: Maybe(f64),
}

@(private = "file")
search_reply_fields :: proc(c: ^Conn, index: ^Search_Index, request: ^Search_Request, row: ^Search_Row, sort: Search_Sort, now: u64) {
	if index.spec.on_json {
		search_reply_json_fields(c, index, request, row, sort)
		return
	}
	h := search_hash_exact(row.scope, row.key)
	if h == nil {
		reply_map(c, 0)
		return
	}
	if request.has_return {
		selected := make([dynamic]Search_Reply_Field, 0, len(request.return_fields), context.temp_allocator)
		yielded_first := sort.field if sort.kind == .Distance else ""
		if value, found := search_row_distance(row, yielded_first); found {
			for field in request.return_fields {
				if field.identifier == yielded_first {
					append(&selected, Search_Reply_Field{name = field.name, distance = value})
				}
			}
		}
		for field in request.return_fields {
			if yielded_first != "" && field.identifier == yielded_first {
				continue
			}
			if distance, found := search_row_distance(row, field.identifier); found {
				append(&selected, Search_Reply_Field{name = field.name, distance = distance})
				continue
			}
			source := search_field_source(index, field.identifier)
			if value, status := ht.get(h, transmute([]u8)source, now, false); .Live in status {
				append(&selected, Search_Reply_Field{name = field.name, source = source, value = value})
			}
		}
		reply_map(c, len(selected))
		for field in selected {
			reply_bulk_str(c, field.name)
			if v, found := field.distance.?; found {
				search_reply_distance(c, v)
			} else {
				search_reply_hash_field(c, index, request, row, field.source, field.name, field.value)
			}
		}
		return
	}
	n := ht.length_live(h, now)
	for value in row.values {
		if _, status := ht.get(h, transmute([]u8)value.name, now, false); .Live not_in status {
			n += 1
		}
	}
	reply_map(c, n)
	for value in row.values {
		reply_bulk_str(c, value.name)
		search_reply_distance(c, value.value)
	}
	selected: map[string]bool
	variants := [2]^Search_Snippet_Options{&request.snippet.summary, &request.snippet.highlight}
	for variant in variants {
		for name in variant.fields {
			if selected == nil {
				selected = make(map[string]bool, context.temp_allocator)
			}
			key := string(name)
			if selected[key] {
				continue
			}
			if _, already := search_row_distance(row, key); already {
				continue
			}
			if value, status := ht.get(h, name, now, false); .Live in status {
				selected[key] = true
				reply_bulk_str(c, key)
				search_reply_hash_field(c, index, request, row, key, key, value)
			}
		}
	}
	it := ht.iterator_live(h, now)
	for ht.next(&it) {
		field := ht.current_field(&it)
		buf: [lp.DECIMAL_BUFFER_BYTES]u8
		name := string(ht.value_bytes(field, &buf))
		if _, already := search_row_distance(row, name); already || selected[name] {
			continue
		}
		reply_hash_value(c, field)
		search_reply_hash_field(c, index, request, row, name, name, ht.current_value(&it))
	}
}

search_field_source :: proc(index: ^Search_Index, name: string) -> string {
	for field in index.spec.definition.fields {
		if field.name == name {
			return field.source
		}
	}
	return name
}

@(private = "file")
search_reply_distance :: proc(c: ^Conn, distance: f64) {
	buf: [48]u8
	n := int(libc.snprintf(raw_data(buf[:]), len(buf), "%.12g", distance))
	reply_bulk(c, buf[:clamp(n, 0, len(buf) - 1)])
}

search_reply_explanation :: proc(c: ^Conn, detail: ^retrieve.Explanation) {
	if len(detail.children) == 0 {
		search_reply_string(c, detail.text)
		return
	}
	reply_array(c, 2)
	search_reply_string(c, detail.text)
	reply_array(c, len(detail.children))
	for &child in detail.children {
		search_reply_explanation(c, &child)
	}
}

search_reply_score :: proc(c: ^Conn, score: f64, detail: ^retrieve.Explanation, explain: bool) {
	if explain {
		reply_array(c, 2)
	}
	reply_double(c, score)
	if explain {
		search_reply_explanation(c, detail)
	}
}

search_reply_hash_field :: proc(c: ^Conn, index: ^Search_Index, request: ^Search_Request, row: ^Search_Row, source, name: string, value: ht.Value) {
	if request.snippet.highlight.on || request.snippet.summary.on {
		buf: [lp.DECIMAL_BUFFER_BYTES]u8
		raw := string(ht.value_bytes(value, &buf))
		reply_bulk_str(c, search_snippet_value(index, &request.snippet, row, source, name, raw))
	} else {
		reply_hash_value(c, value)
	}
}

search_expand_error :: proc(c: ^Conn, dialect: int, on_json: bool) -> string {
	if dialect < 3 {
		return "SEARCH_LIMIT_OVER EXPAND format requires dialect 3 or greater"
	}
	if c.resp < RESP3 {
		return "SEARCH_VALUE_BAD EXPAND format is only supported with RESP3"
	}
	if !on_json {
		return "SEARCH_VALUE_BAD EXPAND format is only supported with JSON"
	}
	return ""
}

search_reply_json_fields :: proc(c: ^Conn, index: ^Search_Index, request: ^Search_Request, row: ^Search_Row, sort: Search_Sort) {
	object := cast(^Json_Object)search_document_exact(row.scope, row.key, true)
	cells := make([dynamic]FT_Cell, context.temp_allocator)
	dialect, expand := request.query_options.dialect, request.json_expand
	if request.has_return {
		yielded_first := sort.field if sort.kind == .Distance else ""
		if value, found := search_row_distance(row, yielded_first); found {
			for field in request.return_fields {
				if field.identifier == yielded_first {
					append(&cells, FT_Cell{field.name, value})
				}
			}
		}
		for field in request.return_fields {
			if yielded_first != "" && field.identifier == yielded_first {
				continue
			}
			if distance, found := search_row_distance(row, field.identifier); found {
				append(&cells, FT_Cell{field.name, distance})
				continue
			}
			if source, requested := search_json_return_source(index, field.identifier); requested {
				if value, found := search_snippet_json_value(index, request, row, object, source, field.identifier); found {
					append(&cells, FT_Cell{field.name, value})
				} else if value, projected := search_json_projection(object, source, dialect, expand); projected {
					append(&cells, FT_Cell{field.name, value})
				}
			}
		}
	} else {
		for value in row.values {
			append(&cells, FT_Cell{value.name, value.value})
		}
		if value, found := search_json_projection(object, "$", dialect, expand); found {
			append(&cells, FT_Cell{"$", value})
		}
	}
	reply_map(c, len(cells))
	for cell in cells {
		reply_bulk_str(c, cell.name)
		if distance, found := cell.value.(f64); found {
			search_reply_distance(c, distance)
		} else {
			ft_reply_value(c, cell.value)
		}
	}
}

search_snippet_json_value :: proc(index: ^Search_Index, request: ^Search_Request, row: ^Search_Row, object: ^Json_Object, source, identifier: string) -> (string, bool) {
	snippet := request.snippet
	snippet.highlight.on = search_snippet_select(&snippet.highlight, identifier, identifier)
	snippet.summary.on = search_snippet_select(&snippet.summary, identifier, identifier)
	if object == nil || (!snippet.highlight.on && !snippet.summary.on) {
		return "", false
	}
	for field in index.spec.definition.fields {
		if field.name == identifier && field.kind == .Text {
			matches := search_json_matches(object.doc.root, source)
			if len(matches) == 1 {
				if value, ok := matches[0].value.data.(string); ok {
					return search_snippet_value(index, &snippet, row, source, identifier, value), true
				}
			}
			break
		}
	}
	return "", false
}

search_json_return_source :: proc(index: ^Search_Index, name: string) -> (string, bool) {
	for field in index.spec.definition.fields {
		if field.name == name {
			return field.source, true
		}
	}
	return name, search_json_path_requested(name)
}

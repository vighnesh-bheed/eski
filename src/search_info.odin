package main

import fi "ftindex"
import "text"
import vt "vsettype"

search_field_kinds := [fi.Field_Kind]string{
	.Text = "TEXT", .Tag = "TAG", .Numeric = "NUMERIC", .Vector = "VECTOR", .Geo = "GEO", .Geoshape = "GEOSHAPE",
}

@(private = "file")
search_info_text :: proc(c: ^Conn, key, value: string) {
	reply_simple(c, key)
	search_reply_string(c, value)
}

@(private = "file")
search_info_int :: proc(c: ^Conn, key: string, value: i64) {
	reply_simple(c, key)
	reply_int(c, value)
}

@(private = "file")
search_info_double :: proc(c: ^Conn, key: string, value: f64) {
	reply_simple(c, key)
	reply_double(c, value)
}

@(private = "file")
search_info_decimal :: proc(c: ^Conn, key, value: string) {
	reply_simple(c, key)
	reply_double_text(c, transmute([]u8)value)
}

Search_Figures :: struct {
	docs:    i64,
	max_id:  i64,
	terms:   i64,
	records:       i64,
	errors:        []Search_Error_Figures,
	bytes:         Search_Bytes,
	real:          int,
	blocks:        int,
	vector_fields: []int,
	activity:      Search_Activity,
}

Search_Error_Figures :: struct {
	count: i64,
	order: u64,
	text:  string,
	key:   string,
}

@(private = "file")
search_figures :: proc(index: ^Search_Index) -> Search_Figures {
	n := len(index.spec.definition.fields)
	figures := Search_Figures {
		errors = make([]Search_Error_Figures, n + 1, context.temp_allocator),
		vector_fields = make([]int, n, context.temp_allocator),
	}
	visible_only := labels_on && !access.top
	if !visible_only {
		figures.real = index.real.bytes + vt.usable_size(index)
	}
	figures.bytes[.Overhead] = index.held
	for part in search_partitions(index, search_scope()) {
		sizes: Search_Bytes
		live := search_part_counts(index, part, &sizes, figures.vector_fields if visible_only else nil, &figures.blocks)
		if !visible_only {
			figures.real += search_part_real(part)
			sizes[.Vector] = 0
			for vector, i in part.vectors {
				figures.vector_fields[i] += vector.bytes
				sizes[.Vector] += vector.bytes
			}
		}
		figures.bytes += sizes
		figures.docs += i64(live.num_docs)
		figures.max_id += search_part_max_id(part)
		figures.terms += i64(live.num_terms)
		figures.records += i64(live.num_records)
		figures.activity.indexing_ns += part.activity.indexing_ns
		figures.activity.gc_ns += part.activity.gc_ns
		figures.activity.gc_cycles += part.activity.gc_cycles
		figures.activity.gc_bytes += part.activity.gc_bytes
		if part.activity.gc_last_at > figures.activity.gc_last_at {
			figures.activity.gc_last_at = part.activity.gc_last_at
			figures.activity.gc_last_ns = part.activity.gc_last_ns
		}
		figures.errors[0].count += i64(part.data.errors.failures)
		if len(part.error_order) > 0 {
			search_error_latest(&figures.errors[0], part.error_order[0], part.data.errors)
			for i in 0 ..< len(part.data.slots) {
				errors := fi.field_errors(&part.data, i)
				figures.errors[i + 1].count += i64(errors.failures)
				search_error_latest(&figures.errors[i + 1], part.error_order[i + 1], errors)
			}
		}
	}
	return figures
}

@(private = "file")
search_error_latest :: proc(total: ^Search_Error_Figures, tracked: Search_Error_Order, errors: fi.Field_Errors) {
	if tracked.order > total.order {
		total.order = tracked.order
		total.text = errors.last_error
		total.key = errors.last_key
	}
}

search_reply_info :: proc(c: ^Conn, index: ^Search_Index) {
	figures := search_figures(index)
	spec := &index.spec
	stop_words := spec.definition.stop_mode != .Default
	reply_map(c, 34 + int(stop_words))
	search_info_text(c, "index_name", index.name)
	reply_simple(c, "index_options")
	reply_array(c, int(spec.max_text_fields))
	if spec.max_text_fields {
		reply_simple(c, "MAXTEXTFIELDS")
	}
	reply_simple(c, "index_definition")
	search_info_definition(c, spec)
	reply_simple(c, "attributes")
	reply_array(c, len(spec.definition.fields))
	for &f, i in spec.definition.fields {
		search_info_attribute(c, &f, spec.attributes[i], spec.on_json)
	}
	search_info_counts(c, figures)
	search_info_sizes(c, &figures)
	search_info_activity(c, index, &figures)
	search_info_gc(c, &figures.activity)
	search_info_cursors(c, index)
	if stop_words {
		search_info_stopwords(c, spec.definition.stop_words)
	}
	search_info_dialects(c, index)
	reply_simple(c, "Index Errors")
	search_info_errors(c, figures.errors[0], true)
	search_info_fields(c, index, figures.errors[1:], figures.vector_fields)
}

@(private = "file")
search_info_definition :: proc(c: ^Conn, spec: ^Search_Create) {
	def := &spec.definition
	custom_language := def.language != text.DEFAULT_LANGUAGE
	reply_map(c, 4 + int(custom_language) + int(def.language_field != "") + int(def.score_field != "") + int(def.payload_field != ""))
	search_info_text(c, "key_type", "JSON" if spec.on_json else "HASH")
	reply_simple(c, "prefixes")
	reply_array(c, len(spec.prefixes))
	for prefix in spec.prefixes {
		search_reply_string(c, prefix)
	}
	if custom_language {
		search_info_text(c, "default_language", text.language_name(def.language))
	}
	if def.language_field != "" {
		search_info_text(c, "language_field", def.language_field)
	}
	search_info_double(c, "default_score", spec.default_score)
	if def.score_field != "" {
		search_info_text(c, "score_field", def.score_field)
	}
	if def.payload_field != "" {
		search_info_text(c, "payload_field", def.payload_field)
	}
	search_info_text(c, "indexes_all", "true" if spec.indexes_all else "false")
}

@(private = "file")
search_info_attribute :: proc(c: ^Conn, f: ^fi.Field, options: Search_Attribute, on_json: bool) {
	flags: [8]string
	n := 0
	if f.kind == .Text && f.no_stem {
		flags[n] = "NOSTEM"
		n += 1
	}
	if f.kind == .Tag && f.case_sensitive {
		flags[n] = "CASESENSITIVE"
		n += 1
	}
	if f.sortable {
		flags[n] = "SORTABLE"
		n += 1
		if options.unf {
			flags[n] = "UNF"
			n += 1
		}
	}
	if f.no_index {
		flags[n] = "NOINDEX"
		n += 1
	}
	if f.suffix_trie {
		flags[n] = "WITHSUFFIXTRIE"
		n += 1
	}
	if f.index_empty {
		flags[n] = "INDEXEMPTY"
		n += 1
	}
	if f.index_missing {
		flags[n] = "INDEXMISSING"
		n += 1
	}
	pairs := 3
	switch f.kind {
	case .Text, .Tag:
		pairs += 1
	case .Vector:
		pairs += 4
		if f.vector.method == .Hnsw {
			pairs += 3
		}
	case .Numeric, .Geo, .Geoshape:
	}
	if c.resp >= RESP3 {
		reply_map(c, pairs + 1)
	} else {
		reply_array(c, 2*pairs + n)
	}
	search_info_text(c, "identifier", f.source)
	search_info_text(c, "attribute", f.name)
	search_info_text(c, "type", search_field_kinds[f.kind])
	#partial switch f.kind {
	case .Text:
		search_info_double(c, "WEIGHT", f.weight)
	case .Tag:
		sep := [1]u8{f.separator}
		search_info_text(c, "SEPARATOR", "" if on_json && f.separator == 0 else string(sep[:]))
	case .Vector:
		v := f.vector
		search_info_text(c, "algorithm", SEARCH_VECTOR_ALGORITHMS[v.method])
		search_info_text(c, "data_type", SEARCH_VECTOR_TYPES[v.elem])
		search_info_int(c, "dim", i64(v.dim))
		search_info_text(c, "distance_metric", SEARCH_VECTOR_METRICS[v.metric])
		if v.method == .Hnsw {
			search_info_int(c, "M", i64(v.m))
			search_info_int(c, "ef_construction", i64(v.ef_construction))
			search_info_int(c, "ef_runtime", i64(v.ef_runtime))
		}
	}
	if c.resp >= RESP3 {
		reply_simple(c, "flags")
		reply_array(c, n)
	}
	for flag in flags[:n] {
		reply_simple(c, flag)
	}
}

@(private = "file")
search_info_counts :: proc(c: ^Conn, figures: Search_Figures) {
	search_info_int(c, "num_docs", figures.docs)
	search_info_int(c, "max_doc_id", figures.max_id)
	search_info_int(c, "num_terms", figures.terms)
	search_info_int(c, "num_records", figures.records)
}

@(private = "file")
search_info_mb :: proc(c: ^Conn, name: string, bytes: int) {
	search_info_double(c, name, f64(bytes) / (1024 * 1024))
}

@(private = "file")
search_info_sizes :: proc(c: ^Conn, figures: ^Search_Figures) {
	b := figures.bytes
	search_info_mb(c, "inverted_sz_mb", b[.Inverted])
	search_info_mb(c, "vector_index_sz_mb", b[.Vector])
	search_info_int(c, "total_inverted_index_blocks", i64(figures.blocks))
	search_info_mb(c, "offset_vectors_sz_mb", b[.Offsets])
	search_info_mb(c, "doc_table_size_mb", b[.Documents])
	search_info_decimal(c, "sortable_values_size_mb", "0")
	search_info_mb(c, "key_table_size_mb", b[.Keys])
	search_info_mb(c, "tag_overhead_sz_mb", b[.Tag])
	search_info_mb(c, "text_overhead_sz_mb", b[.Text])
	search_info_mb(c, "total_index_memory_sz_mb", search_charge_sum(b) if labels_on && !access.top else figures.real)
	search_info_decimal(c, "geoshapes_sz_mb", "0")
	if figures.docs > 0 {
		search_info_double(c, "records_per_doc_avg", f64(figures.records) / f64(figures.docs))
	} else {
		search_info_decimal(c, "records_per_doc_avg", "nan")
	}
	if figures.records > 0 {
		search_info_double(c, "bytes_per_record_avg", f64(b[.Inverted]) / f64(figures.records))
	} else {
		search_info_decimal(c, "bytes_per_record_avg", "nan")
	}
	if figures.terms > 0 {
		search_info_double(c, "offsets_per_term_avg", f64(b[.Offsets] / 96) / f64(figures.terms))
	} else {
		search_info_decimal(c, "offsets_per_term_avg", "nan")
	}
	search_info_decimal(c, "offset_bits_per_record_avg", "nan")
}

@(private = "file")
search_info_activity :: proc(c: ^Conn, index: ^Search_Index, figures: ^Search_Figures) {
	visible_only := labels_on && !access.top
	search_info_int(c, "hash_indexing_failures", figures.errors[0].count)
	search_info_double(c, "total_indexing_time", 0 if visible_only else f64(figures.activity.indexing_ns) / 1e6)
	search_info_int(c, "indexing", 0)
	search_info_decimal(c, "percent_indexed", "1")
	search_info_int(c, "number_of_uses", 0 if visible_only else index.uses)
	search_info_int(c, "cleaning", 0)
}

@(private = "file")
search_info_gc :: proc(c: ^Conn, activity: ^Search_Activity) {
	visible_only := labels_on && !access.top
	reply_simple(c, "gc_stats")
	reply_map(c, 7)
	search_info_double(c, "bytes_collected", 0 if visible_only else f64(activity.gc_bytes))
	search_info_double(c, "total_ms_run", 0 if visible_only else f64(activity.gc_ns) / 1e6)
	search_info_double(c, "total_cycles", 0 if visible_only else f64(activity.gc_cycles))
	if visible_only || activity.gc_cycles > 0 {
		average := 0 if visible_only else f64(activity.gc_ns) / f64(activity.gc_cycles) / 1e6
		search_info_double(c, "average_cycle_time_ms", average)
	} else {
		search_info_decimal(c, "average_cycle_time_ms", "nan")
	}
	search_info_double(c, "last_run_time_ms", 0 if visible_only else f64(activity.gc_last_ns) / 1e6)
	search_info_decimal(c, "gc_numeric_trees_missed", "0")
	search_info_decimal(c, "gc_blocks_denied", "0")
}

@(private = "file")
search_info_cursors :: proc(c: ^Conn, index: ^Search_Index) {
	reply_simple(c, "cursor_stats")
	reply_map(c, 4)
	visible_only := labels_on && !access.top
	search_info_int(c, "global_idle", i64(ft_cursor_count) if !visible_only else 0)
	search_info_int(c, "global_total", i64(ft_cursor_count) if !visible_only else 0)
	search_info_int(c, "index_capacity", ft_config_numbers[.Cursor_Limit])
	search_info_int(c, "index_total", i64(ft_cursor_count_for_index(index)) if !visible_only else 0)
}

@(private = "file")
search_info_stopwords :: proc(c: ^Conn, input: []string) {
	words := make([][]u8, len(input), context.temp_allocator)
	for word, i in input {
		words[i] = transmute([]u8)word
	}
	list: text.Stop_Words
	if text.stop_words_custom(&list, words, context.temp_allocator) != .None {
		store_fatal("out of memory")
	}
	reply_simple(c, "stopwords_list")
	reported := text.stop_words_list(&list)
	reply_array(c, len(reported))
	for word in reported {
		reply_bulk_str(c, word)
	}
}

@(private = "file")
search_info_dialects :: proc(c: ^Conn, index: ^Search_Index) {
	reply_simple(c, "dialect_stats")
	reply_map(c, 4)
	for name in ([4]string{"dialect_1", "dialect_2", "dialect_3", "dialect_4"}) {
		search_info_int(c, name, 0)
	}
}

@(private = "file")
search_info_errors :: proc(c: ^Conn, errors: Search_Error_Figures, index: bool) {
	reply_map(c, 4 if index else 3)
	search_info_int(c, "indexing failures", errors.count)
	search_info_text(c, "last indexing error", "N/A" if errors.text == "" else errors.text)
	reply_simple(c, "last indexing error key")
	reply_bulk_str(c, "N/A" if errors.order == 0 else errors.key)
	if index {
		search_info_text(c, "background indexing status", "OK")
	}
}

@(private = "file")
search_info_fields :: proc(c: ^Conn, index: ^Search_Index, errors: []Search_Error_Figures, vector_fields: []int) {
	reply_simple(c, "field statistics")
	reply_array(c, len(index.spec.definition.fields))
	for f, i in index.spec.definition.fields {
		vector := f.kind == .Vector
		reply_map(c, 7 if vector else 3)
		search_info_text(c, "identifier", f.source)
		search_info_text(c, "attribute", f.name)
		reply_simple(c, "Index Errors")
		search_info_errors(c, errors[i], false)
		if vector {
			search_info_int(c, "memory", i64(vector_fields[i]))
			search_info_int(c, "marked_deleted", 0)
			search_info_int(c, "direct_hnsw_insertions", 0)
			search_info_int(c, "flat_buffer_size", 0)
		}
	}
}

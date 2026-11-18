package main

import "core:slice"
import "core:strings"
import fi "ftindex"
import ht "hashtype"
import lp "listpack"
import "text"

FT_Row :: struct {
	doc: Search_Row,
	cells: [dynamic]FT_Cell,
	order: int,
}

FT_Column :: struct {
	source: string,
	numeric, fold: bool,
}

FT_SORT_DEFAULT_MAX :: 10

FT_Pipeline_Result :: struct {
	rows: []FT_Row,
	total: int,
	skipped: int,
	buffered, loaded, streamed: bool,
	warn, expand: bool,
}

ft_set_cell :: proc(row: ^FT_Row, name: string, val: FT_Value) {
	for &cell in row.cells {
		if cell.name == name {
			cell.value = val
			return
		}
	}
	if row.cells == nil {
		row.cells = make([dynamic]FT_Cell, context.temp_allocator)
	}
	append(&row.cells, FT_Cell{name, val})
}

ft_pipeline_rows :: proc(documents: []Search_Row, scores: bool) -> []FT_Row {
	rows := make([]FT_Row, len(documents), context.temp_allocator)
	for doc, i in documents {
		row := &rows[i]
		row.doc, row.order = doc, i
		for value in doc.values {
			ft_set_cell(row, value.name, value.value)
		}
		if scores {
			ft_set_cell(row, "__score", doc.score)
		}
	}
	return rows
}

ft_schema_columns :: proc(index: ^Search_Index, sortable_only: bool) -> map[string]FT_Column {
	cols := make(map[string]FT_Column, context.temp_allocator)
	for field, i in index.spec.definition.fields {
		if !sortable_only || field.sortable {
			cols[field.name] = {field.source, field.kind == .Numeric, field.sortable && !index.spec.attributes[i].unf}
		}
	}
	return cols
}

ft_hash_value :: proc(value: ht.Value) -> string {
	buf: [lp.DECIMAL_BUFFER_BYTES]u8
	bytes := ht.value_bytes(value, &buf)
	if value.is_int {
		return strings.clone(string(bytes), context.temp_allocator)
	}
	return string(bytes)
}

ft_load_value :: proc(row: ^FT_Row, h: ht.Hash, col: FT_Column, now: u64) -> FT_Value {
	if col.source == "__key" {
		return row.doc.key
	}
	if h == nil {
		return nil
	}
	value, status := ht.get(h, transmute([]u8)col.source, now, false)
	if .Live not_in status {
		return nil
	}
	loaded := ft_hash_value(value)
	if col.numeric {
		if n, ok := fi.number_parse(loaded); ok {
			return n
		}
		return nil
	}
	if col.fold {
		folded := make([dynamic]u8, 0, len(loaded), context.temp_allocator)
		text.fold(transmute([]u8)loaded, nil, &folded)
		return string(folded[:])
	}
	return loaded
}

ft_pipeline_load :: proc(rows: []FT_Row, step: ^FT_Pipeline_Step, schema: map[string]FT_Column, known: ^map[string]bool, now: u64, on_json := false, dialect := 2, expand := false) {
	for field in step.fields {
		known^[field.name] = true
	}
	if step.all {
		known^["*"] = true
	}
	for &row in rows {
		if on_json {
			ft_pipeline_load_json(&row, step, schema, dialect, expand)
			continue
		}
		h := search_hash_exact(row.doc.scope, row.doc.key)
		if step.all && h != nil {
			it := ht.iterator_live(h, now)
			for ht.next(&it) {
				name := ft_hash_value(ht.current_field(&it))
				if _, found := ft_cell_get(row.cells[:], name); !found {
					ft_set_cell(&row, name, ft_hash_value(ht.current_value(&it)))
				}
			}
		}
		for field in step.fields {
			value, found := ft_cell_get(row.cells[:], field.identifier)
			if !found {
				if score, available := search_row_distance(&row.doc, field.identifier); available {
					ft_set_cell(&row, field.name, score)
					continue
				}
				col, in_schema := schema[field.identifier]
				if !in_schema {
					col.source = field.identifier
				}
				col.fold = false
				value = ft_load_value(&row, h, col, now)
			}
			if value != nil {
				ft_set_cell(&row, field.name, value)
			}
		}
	}
}

ft_load_reads_documents :: proc(step: ^FT_Pipeline_Step, known: map[string]bool) -> bool {
	if step.all {
		return true
	}
	for field in step.fields {
		if field.name != field.identifier || !known[field.identifier] {
			return true
		}
	}
	return false
}

FT_Columns :: struct {
	known: map[string]bool,
	schema, sortable: map[string]FT_Column,
	grouped, on_json: bool,
	now: u64,
}

FT_Property_Use :: enum {
	Expression,
	Group,
	Reducer,
	Sort,
}

ft_pipeline_property :: proc(cols: ^FT_Columns, rows: []FT_Row, name: string, use: FT_Property_Use) -> string {
	if cols.known[name] {
		return ""
	}
	available := cols.sortable if use == .Expression else cols.schema
	col, exists := available[name]
	if exists && !cols.grouped {
		cols.known[name] = true
		for &row in rows {
			if cols.on_json {
				object := cast(^Json_Object)search_document_exact(row.doc.scope, row.doc.key, true)
				if use == .Sort {
					if value, found := search_json_sort_value(object, col.source, col.numeric); found {
						ft_set_cell(&row, name, value)
					}
				} else if value, found := search_json_projection(object, col.source, 2, false); found {
					ft_set_cell(&row, name, value)
				}
				continue
			}
			h := search_hash_exact(row.doc.scope, row.doc.key)
			if value := ft_load_value(&row, h, col, cols.now); value != nil {
				ft_set_cell(&row, name, value)
			}
		}
		return ""
	}
	if cols.known["*"] && name != "__key" && name != "__score" {
		return ""
	}
	if use == .Sort {
		return ft_error("SEARCH_PROP_NOT_FOUND Property `", name, "` not loaded nor in schema")
	}
	if use == .Group {
		return ft_error("SEARCH_PROP_NOT_FOUND No such property `", name, "`")
	}
	return ft_error("SEARCH_PROP_NOT_FOUND Property not loaded nor in pipeline: `", name, "`")
}

ft_pipeline_expr :: proc(expr: ^FT_Expr, cols: ^FT_Columns, rows: []FT_Row) -> string {
	if expr.kind == .Property {
		return ft_pipeline_property(cols, rows, expr.name, .Expression)
	}
	for child in expr.args {
		if err := ft_pipeline_expr(child, cols, rows); err != "" {
			return err
		}
	}
	return ""
}

ft_pipeline_project :: proc(rows: []FT_Row, step: ^FT_Pipeline_Step, can_stream: bool) -> ([]FT_Row, string) {
	out := 0
	for &row, i in rows {
		value, err := ft_expr_eval(step.expr, row.cells[:], row.doc.matches)
		if err != "" {
			if can_stream && out != 0 {
				break
			}
			return nil, err
		}
		if step.kind == .Apply {
			ft_set_cell(&row, step.name, value)
		} else if !ft_truth(value) {
			continue
		}
		rows[out] = rows[i]
		out += 1
	}
	return rows[:out], ""
}

ft_row_before :: proc(a, b: FT_Row, ctx: rawptr) -> bool {
	orders := (^[]FT_Order)(ctx)^
	for order in orders {
		left, has_left := ft_cell_get(a.cells[:], order.name)
		right, has_right := ft_cell_get(b.cells[:], order.name)
		if has_left != has_right {
			return has_left
		}
		if cmp := ft_compare(left, right); cmp != 0 {
			return cmp > 0 if order.desc else cmp < 0
		}
	}
	if labels_on {
		return a.order < b.order
	}
	if len(orders) != 0 && a.doc.id != b.doc.id {
		return a.doc.id > b.doc.id if orders[0].desc else a.doc.id < b.doc.id
	}
	return a.order < b.order
}

ft_rows_sort :: proc(rows: []FT_Row, order: []FT_Order) {
	local := order
	slice.sort_by_with_data(rows, ft_row_before, &local)
}

ft_pipeline_prepare_group :: proc(rows: []FT_Row, step: ^FT_Pipeline_Step, cols: ^FT_Columns) -> string {
	for field in step.fields {
		if err := ft_pipeline_property(cols, rows, field.name, .Group); err != "" {
			return err
		}
	}
	for r in step.reducers {
		if r.kind != .Count && r.kind != .Collect {
			if err := ft_pipeline_property(cols, rows, r.property, .Reducer); err != "" {
				return err
			}
		}
		for order in r.order {
			kind := FT_Property_Use.Reducer if r.kind == .First_Value else .Sort
			if err := ft_pipeline_property(cols, rows, order.name, kind); err != "" {
				return err
			}
		}
		for name in r.fields {
			if name == "__key" && !cols.grouped {
				for &row in rows {
					ft_set_cell(&row, name, row.doc.key)
				}
			} else if err := ft_pipeline_property(cols, rows, name, .Reducer); err != "" {
				return err
			}
		}
	}
	return ""
}

FT_Group :: struct {
	cells: [dynamic]FT_Cell,
	reductions: []FT_Reduction,
}

ft_group_rows :: proc(rows: []FT_Row, step: ^FT_Pipeline_Step, state: ^Search_Query_State) -> ([]FT_Row, string) {
	a := context.temp_allocator
	buckets := make(map[string]int, a)
	groups := make([dynamic]FT_Group, a)
	options := make([][]FT_Value, len(step.fields), a)
	singles := make([]FT_Value, len(step.fields), a)
	positions := make([]int, len(step.fields), a)
	for &row in rows {
		for field, i in step.fields {
			value, _ := ft_cell_get(row.cells[:], field.name)
			if array, ok := value.([]FT_Value); ok && len(array) > 0 {
				options[i] = array
			} else {
				singles[i] = value
				if ok { singles[i] = nil }
				options[i] = singles[i:i+1]
			}
			positions[i] = 0
		}
		for {
			if search_deadline_reached(state) {
				return nil, "Timeout limit was reached"
			}
			key := make([dynamic]u8, a)
			for variants, i in options {
				ft_group_value_key(&key, variants[positions[i]])
			}
			id, exists := buckets[string(key[:])]
			if !exists {
				id = len(groups)
				buckets[string(key[:])] = id
				group := FT_Group{
					cells = make([dynamic]FT_Cell, 0, len(step.fields) + len(step.reducers), a),
					reductions = make([]FT_Reduction, len(step.reducers), a),
				}
				for field, i in step.fields {
					append(&group.cells, FT_Cell{field.name, options[i][positions[i]]})
				}
				append(&groups, group)
			} else {
				delete(key)
			}
			for &reducer, i in step.reducers {
				ft_reduce_add(&reducer, &groups[id].reductions[i], &row)
			}
			at := len(positions) - 1
			for at >= 0 {
				positions[at] += 1
				if positions[at] < len(options[at]) {
					break
				}
				positions[at] = 0
				at -= 1
			}
			if at < 0 {
				break
			}
		}
	}
	result := make([]FT_Row, len(groups), a)
	for &group, at in groups {
		row := &result[at]
		row.cells, row.order = group.cells, at
		for &reducer, i in step.reducers {
			ft_set_cell(row, reducer.name, ft_reduce_finish(&reducer, &group.reductions[i]))
		}
	}
	return result, ""
}

ft_collect_finish :: proc(r: ^FT_Reducer, rows: []FT_Row) -> FT_Value {
	ft_rows_sort(rows, r.order)
	out := make([dynamic]FT_Value, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	matches := 0
	for row in rows {
		if len(out) == r.count {
			break
		}
		fields := row.cells[:]
		if !r.all {
			selected := make([dynamic]FT_Cell, context.temp_allocator)
			for name in r.fields {
				if value, _ := ft_cell_get(fields, name); value != nil {
					append(&selected, FT_Cell{name, value})
				}
			}
			fields = selected[:]
		}
		obj := FT_Object(fields)
		if r.unique {
			key := make([dynamic]u8, context.temp_allocator)
			ft_group_value_key(&key, obj)
			if seen[string(key[:])] {
				delete(key)
				continue
			}
			seen[string(key[:])] = true
		}
		if matches >= r.offset {
			append(&out, FT_Value(obj))
		}
		matches += 1
	}
	return out[:]
}

ft_pipeline_run :: proc(index: ^Search_Index, pipeline: ^FT_Pipeline, input: []FT_Row, known: map[string]bool, state: ^Search_Query_State, hybrid: bool, profile: ^Search_Profile = nil) -> (FT_Pipeline_Result, string) {
	rows := input
	cols := FT_Columns{known = known, schema = ft_schema_columns(index, false), sortable = ft_schema_columns(index, true), now = state.now, on_json = index.spec.on_json}
	result := FT_Pipeline_Result{rows = rows, total = len(rows), expand = pipeline.expand}
	limit := false
	backing_count := len(rows)
	for &step, at in pipeline.steps {
		if search_deadline_reached(state) {
			return {}, "Timeout limit was reached"
		}
		started := mono_posix_ns() if profile != nil else 0
		switch step.kind {
		case .Load:
			result.loaded = result.loaded || ft_load_reads_documents(&step, cols.known)
			if !hybrid {
				ft_pipeline_load(rows, &step, cols.schema, &cols.known, cols.now, cols.on_json, pipeline.search.query_options.dialect, pipeline.expand)
			}
		case .Apply, .Filter:
			if err := ft_pipeline_expr(step.expr, &cols, rows); err != "" {
				return {}, err
			}
			streaming := true
			for next in pipeline.steps[at+1:] {
				if next.kind == .Sort || next.kind == .Group {
					streaming = false
					break
				}
			}
			out, err := ft_pipeline_project(rows, &step, streaming)
			if err != "" {
				return {}, err
			}
			rows = out
			if step.kind == .Apply {
				cols.known[step.name] = true
			}
			if hybrid || (result.buffered && step.kind == .Filter) {
				result.total = len(rows)
			}
		case .Group:
			if err := ft_pipeline_prepare_group(rows, &step, &cols); err != "" {
				return {}, err
			}
			out, err := ft_group_rows(rows, &step, state)
			if err != "" {
				return {}, err
			}
			rows = out
			cols.known = make(map[string]bool, context.temp_allocator)
			for field in step.fields { cols.known[field.name] = true }
			for reducer in step.reducers { cols.known[reducer.name] = true }
			cols.grouped = true
			result.buffered = true
			result.total = len(rows)
		case .Sort:
			for order in step.order {
				if err := ft_pipeline_property(&cols, rows, order.name, .Sort); err != "" {
					return {}, err
				}
			}
			if len(step.order) != 0 {
				ft_rows_sort(rows, step.order)
				result.buffered = true
				result.total = len(rows)
			}
			maximum := step.maximum
			if maximum <= 0 && len(step.order) != 0 && !hybrid && !ft_pipeline_has_limit(pipeline) {
				maximum = FT_SORT_DEFAULT_MAX
			}
			if maximum > 0 {
				rows = rows[:min(maximum, len(rows))]
				if !(pipeline.count_all.? or_else true) {
					result.total = len(rows)
				}
			}
		case .Limit:
			limit = true
			start := min(step.offset, len(rows))
			result.skipped += start
			rows = rows[start:start+min(step.count, len(rows)-start)]
		}
		if profile != nil {
			search_profile_stage(profile, &step, len(rows), started)
		}
	}
	if hybrid && !limit && !pipeline.no_sort {
		rows = rows[:min(len(rows), 10)]
	}
	if !hybrid && !result.buffered {
		if len(rows) == 0 {
			result.total = backing_count if limit else 0
		} else if pipeline.count_all.? or_else result.loaded {
			result.total = backing_count
		} else {
			result.total = result.skipped + 1
			result.streamed = true
		}
	}
	result.rows = rows
	return result, ""
}

ft_reply_value :: proc(c: ^Conn, value: FT_Value) {
	switch v in value {
	case i64:
		reply_int(c, v)
		return
	case FT_Json_Double:
		reply_double(c, f64(v))
		return
	case string:
		reply_bulk_str(c, v)
		return
	case f64:
		reply_bulk_str(c, ft_value_string(v))
		return
	case []FT_Value:
		reply_array(c, len(v))
		for item in v { ft_reply_value(c, item) }
		return
	case FT_Object:
		ft_reply_cells(c, cast([]FT_Cell)v)
		return
	}
	reply_null(c)
}

ft_reply_cells :: proc(c: ^Conn, cells: []FT_Cell) {
	reply_map(c, len(cells))
	for cell in cells {
		reply_bulk_str(c, cell.name)
		ft_reply_value(c, cell.value)
	}
}

ft_reply_aggregate :: proc(c: ^Conn, rows: []FT_Row, total: int, warn: bool, expand := false) {
	if c.resp >= RESP3 {
		reply_map(c, 5)
		reply_simple(c, "attributes")
		reply_array(c, 0)
		reply_simple(c, "format")
		reply_simple(c, "EXPAND" if expand else "STRING")
		reply_simple(c, "results")
		reply_array(c, len(rows))
	} else {
		reply_array(c, len(rows) + 1)
		reply_int(c, i64(total))
	}
	for &row in rows {
		if c.resp >= RESP3 {
			reply_map(c, 2)
			reply_simple(c, "extra_attributes")
		}
		ft_reply_cells(c, row.cells[:])
		if c.resp >= RESP3 {
			reply_simple(c, "values")
			reply_array(c, 0)
		}
	}
	if c.resp >= RESP3 {
		reply_simple(c, "total_results")
		reply_int(c, i64(total))
		reply_simple(c, "warning")
		ft_reply_warnings(c, warn)
	}
}

ft_reply_warnings :: proc(c: ^Conn, warn: bool) {
	reply_array(c, int(warn))
	if warn {
		reply_simple(c, "Max prefix expansions limit was reached")
	}
}

ft_pipeline_load_json :: proc(row: ^FT_Row, step: ^FT_Pipeline_Step, schema: map[string]FT_Column, dialect: int, expand: bool) {
	object := cast(^Json_Object)search_document_exact(row.doc.scope, row.doc.key, true)
	if step.all {
		if value, found := search_json_projection(object, "$", dialect, expand); found {
			ft_set_cell(row, "$", value)
		}
	}
	for field in step.fields {
		if value, found := ft_cell_get(row.cells[:], field.identifier); found {
			ft_set_cell(row, field.name, value)
			continue
		}
		if score, available := search_row_distance(&row.doc, field.identifier); available {
			ft_set_cell(row, field.name, score)
			continue
		}
		if field.identifier == "__key" {
			ft_set_cell(row, field.name, row.doc.key)
			continue
		}
		col, in_schema := schema[field.identifier]
		source := col.source if in_schema else field.identifier
		if in_schema || search_json_path_requested(source) {
			if value, found := search_json_projection(object, source, dialect, expand); found {
				ft_set_cell(row, field.name, value)
			}
		}
	}
}

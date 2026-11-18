package main

import "core:math"
import "core:mem"
import "core:strings"
import fi "ftindex"
import "jsondoc"
import "vmath"

search_json_workspace: jsondoc.Workspace

search_add_json :: proc(part: ^Search_Partition, key: string, object: ^Json_Object, field_limit: int) -> (fi.Added, fi.Error) {
	if search_json_workspace.allocator.procedure == nil && !jsondoc.workspace_init(&search_json_workspace) {
		return {}, .Out_Of_Memory
	}
	defer jsondoc.workspace_reset(&search_json_workspace)
	allocator := search_json_workspace.allocator
	def := &part.data.definition
	fields := make([]fi.Field_Input, len(def.fields), allocator)
	for field, i in def.fields[:min(field_limit, len(def.fields))] {
		if !field.no_index {
			fields[i] = search_json_index_field(object.doc.root, field, allocator)
		}
	}
	auxiliary: [2]fi.Value
	count := 0
	names := [2]string{def.language_field, def.score_field}
	for name in names {
		if name == "" {
			continue
		}
		if value := search_json_first(object.doc.root, name, allocator); value != nil {
			if text, ok := search_json_scalar(value, allocator); ok {
				auxiliary[count] = {name, text}
				count += 1
			}
		}
	}
	return fi.add(&part.data, key, auxiliary[:count], measure = true, field_limit = field_limit, inputs = fields)
}

search_json_index_field :: proc(root: ^jsondoc.Value, field: fi.Field, allocator: mem.Allocator) -> fi.Field_Input {
	path, parse_error := jsondoc.compile_path(field.source, allocator)
	if parse_error != {} {
		return {invalid = "SEARCH_PATH_BAD Invalid JSONPath"}
	}
	kind := jsondoc.Field_Kind(field.kind)
	extract := jsondoc.extract_field(root, path, kind, allocator, field.vector.dim)
	if extract.error != "" {
		return {invalid = extract.error}
	}
	values := make([]fi.Value, len(extract.values), allocator)
	for value, i in extract.values {
		if field.kind == .Vector {
			blob, ok := search_json_vector(jsondoc.as_array(value), field.vector, allocator)
			if !ok {
				return {invalid = "SEARCH_VALUE_BAD Invalid JSON vector element"}
			}
			values[i].value = blob
		} else if boolean, ok := value.data.(bool); ok {
			values[i].value = "true" if boolean else "false"
		} else if text, written := search_json_scalar(value, allocator); written {
			values[i].value = text
		}
	}
	return {values = values}
}

search_json_vector :: proc(array: ^jsondoc.Array, options: fi.Vector_Options, allocator: mem.Allocator) -> (string, bool) {
	blob := make([]u8, options.dim * vmath.elem_size(options.elem), allocator)
	if blob == nil {
		return "", false
	}
	for value, i in array.items {
		n, _ := jsondoc.number(value)
		switch options.elem {
		case .F64:
			vmath.f64_view(blob)[i] = n
		case .F32:
			f := f32(n)
			if math.is_inf(f) {
				return "", false
			}
			vmath.f32_view(blob)[i] = f
		case .F16:
			f := f16(n)
			if math.is_inf(f64(f)) {
				return "", false
			}
			vmath.u16_view(blob)[i] = transmute(u16)f
		case .BF16:
			bits := vmath.f32_to_bf16_rne(f32(n))
			if bits & 0x7fff >= 0x7f80 {
				return "", false
			}
			vmath.u16_view(blob)[i] = bits
		case .Int8:
			if n < -128 || n > 127 {
				return "", false
			}
			blob[i] = u8(i8(n))
		case .U8:
			if n < 0 || n > 255 {
				return "", false
			}
			blob[i] = u8(n)
		case .Bin:
			return "", false
		}
	}
	return string(blob), true
}

search_json_matches :: proc(root: ^jsondoc.Value, source: string, allocator := context.temp_allocator) -> []jsondoc.Match {
	path, err := jsondoc.compile_path(source, allocator)
	if err != {} || path.expr == nil || path.expr.kind != .Selector {
		return nil
	}
	out, why := jsondoc.select_path(root, path, allocator)
	return out.matches[:] if why == "" else nil
}

search_json_first :: proc(root: ^jsondoc.Value, source: string, allocator := context.temp_allocator) -> ^jsondoc.Value {
	matches := search_json_matches(root, source, allocator)
	return matches[0].value if len(matches) != 0 else nil
}

search_json_scalar :: proc(value: ^jsondoc.Value, allocator := context.temp_allocator) -> (string, bool) {
	#partial switch data in value.data {
	case string:
		return data, true
	case bool:
		return "1" if data else "0", true
	case jsondoc.Null:
		return "", false
	case:
		out, err := jsondoc.serialize(value, allocator = allocator)
		return out, err == ""
	}
}

search_json_path_requested :: proc(identifier: string) -> bool {
	return strings.has_prefix(identifier, "$")
}

search_json_projection :: proc(object: ^Json_Object, source: string, dialect: int, expand: bool) -> (FT_Value, bool) {
	if object == nil {
		return nil, false
	}
	allocator := context.temp_allocator
	matches := search_json_matches(object.doc.root, source, allocator)
	if len(matches) == 0 {
		return nil, false
	}
	if expand {
		values := make([]FT_Value, len(matches), allocator)
		for match, i in matches {
			values[i] = search_json_expand(match.value, allocator)
		}
		return values, true
	}
	if dialect >= 3 {
		text, ok := jsondoc.serialize_path_matches(matches, allocator)
		return text, ok
	}
	value := matches[0].value
	if _, explicit_null := value.data.(jsondoc.Null); explicit_null {
		return nil, true
	}
	text, ok := search_json_scalar(value, allocator)
	return text, ok
}

search_json_expand :: proc(value: ^jsondoc.Value, allocator: mem.Allocator) -> FT_Value {
	switch data in value.data {
	case jsondoc.Null:
		return nil
	case bool:
		return i64(data)
	case i64:
		return data
	case u64:
		return FT_Json_Double(data)
	case f64:
		return FT_Json_Double(data)
	case string:
		return data
	case ^jsondoc.Array:
		items := make([]FT_Value, len(data.items), allocator)
		for child, i in data.items {
			items[i] = search_json_expand(child, allocator)
		}
		return items
	case ^jsondoc.Object:
		fields := make([]FT_Cell, len(data.members), allocator)
		for member, i in data.members {
			fields[i] = {member.name, search_json_expand(member.value, allocator)}
		}
		return FT_Object(fields)
	}
	return nil
}

search_json_sort_value :: proc(object: ^Json_Object, path: string, numeric: bool) -> (FT_Value, bool) {
	if object == nil {
		return nil, false
	}
	value := search_json_first(object.doc.root, path)
	if array := jsondoc.as_array(value); array != nil && len(array.items) != 0 {
		value = array.items[0]
	}
	if value != nil {
		if numeric {
			if number, ok := jsondoc.number(value); ok {
				return number, true
			}
		} else if text, ok := value.data.(string); ok {
			return text, true
		}
	}
	return nil, false
}

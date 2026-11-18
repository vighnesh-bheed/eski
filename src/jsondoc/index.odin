package jsondoc

import "core:fmt"
import "core:mem"

Field_Kind :: enum {
	Text, Tag, Numeric, Geo, Vector,
}

Field_Values :: struct {
	values: []^Value,
	invalid: bool,
	error: string,
}

extract_field :: proc(root: ^Value, path: Path, kind: Field_Kind, allocator: mem.Allocator, dimensions := 0) -> Field_Values {
	if path.expr == nil || path.expr.kind != .Selector {
		return {error = PROJECTION_ERROR}
	}
	selected, select_error := select_path(root, path, allocator)
	if select_error != "" {
		return {error = select_error}
	}
	values: [dynamic]^Value
	values.allocator = allocator
	for match in selected.matches {
		value := match.value
		if _, null := value.data.(Null); null {
			continue
		}
		if kind == .Vector {
			if err := vector_field_error(value, dimensions, path); err != "" {
				return {invalid = true, error = err}
			}
			if err := append_field(&values, value); err != "" {
				return {error = err}
			}
		} else if a := as_array(value); a != nil {
			for v in a.items {
				if _, null := v.data.(Null); null {
					continue
				}
				if !valid_array_field_value(v, kind) {
					err := "SEARCH_VALUE_BAD NUMERIC fields can only contain numeric or nulls" if kind == .Numeric else "SEARCH_VALUE_BAD TEXT/TAG fields can only contain strings or nulls"
					return {invalid = true, error = err}
				}
				if err := append_field(&values, v); err != "" {
					return {error = err}
				}
			}
		} else {
			_, boolean := value.data.(bool)
			if !valid_array_field_value(value, kind) && !(boolean && kind == .Tag) {
				err := scalar_field_error(value)
				if len(selected.matches) > 1 && kind == .Numeric {
					err = "SEARCH_VALUE_BAD NUMERIC fields can only contain numeric or nulls"
				}
				return {invalid = true, error = err}
			}
			if err := append_field(&values, value); err != "" {
				return {error = err}
			}
		}
	}
	return {values = values[:]}
}

valid_array_field_value :: proc(v: ^Value, kind: Field_Kind) -> bool {
	if kind == .Numeric {
		_, ok := number(v)
		return ok
	}
	_, ok := v.data.(string)
	return ok
}

scalar_field_error :: proc(value: ^Value) -> string {
	#partial switch data in value.data {
	case i64, u64, f64:
		return "SEARCH_JSON_TYPE_INVALID Invalid JSON type: Numeric type can represent only NUMERIC field"
	case bool:
		return "SEARCH_JSON_TYPE_INVALID Invalid JSON type: Boolean type can be represent only TAG field"
	case string:
		return "SEARCH_JSON_TYPE_INVALID Invalid JSON type: String type can represent only TEXT, TAG, GEO or GEOMETRY field"
	case ^Object:
		return "SEARCH_JSON_TYPE_INVALID Invalid JSON type: Object type can represent only GEOMETRY fields"
	case:
		return "SEARCH_VALUE_BAD Invalid JSON field"
	}
}

vector_field_error :: proc(value: ^Value, dimensions: int, path: Path) -> string {
	a := as_array(value)
	if a == nil {
		for step in path.expr.steps {
			if !static_step(step) {
				return "Success (not an error)"
			}
		}
		return scalar_field_error(value)
	}
	count := len(a.items)
	if count == 0 {
		return "SEARCH_VALUE_BAD Empty array for vector field on JSON document"
	}
	for child, i in a.items {
		if _, ok := number(child); !ok {
			if _, text := child.data.(string); text {
				return fmt.tprintf("SEARCH_GENERIC Invalid vector element at index %d", i)
			}
			return "Success (not an error)"
		}
	}
	if dimensions > 0 && dimensions != count {
		return fmt.tprintf("SEARCH_VECTOR_LEN_BAD Invalid vector length. Expected %d, got %d", dimensions, count)
	}
	return ""
}

append_field :: proc(values: ^[dynamic]^Value, value: ^Value) -> string {
	if len(values) >= MAX_ITEMS {
		return SIZE_LIMIT
	}
	_, err := append(values, value)
	return "" if err == nil else OUT_OF_MEMORY
}

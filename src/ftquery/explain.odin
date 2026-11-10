package ftquery

import "core:strings"

Printer :: struct {
	q:      ^Query,
	schema: ^Schema,
	b:      strings.Builder,
	order:  []int,
}

write_indent :: proc(pr: ^Printer, depth: int) {
	for _ in 0 ..< depth {
		strings.write_string(&pr.b, "  ")
	}
}

write_mask :: proc(pr: ^Printer, mask: Field_Mask) {
	if mask == ALL_FIELDS {
		return
	}
	if mask == 0 {
		strings.write_string(&pr.b, "@NULL:")
		return
	}
	strings.write_byte(&pr.b, '@')
	first := true
	for field, i in pr.schema.fields {
		if field.kind != .Text || i >= len(pr.order) || pr.order[i] < 0 {
			continue
		}
		if mask & (Field_Mask(1) << uint(pr.order[i])) == 0 {
			continue
		}
		if !first {
			strings.write_byte(&pr.b, '|')
		}
		strings.write_string(&pr.b, field.name)
		first = false
	}
	strings.write_byte(&pr.b, ':')
}

write_attrs :: proc(pr: ^Printer, n: ^Node) {
	if n.weight == 1 && n.slop == -1 && !n.in_order {
		return
	}
	strings.write_string(&pr.b, " => {")
	if n.weight != 1 {
		strings.write_string(&pr.b, " $weight: ")
		write_c_general(&pr.b, n.weight)
		strings.write_byte(&pr.b, ';')
	}
	if n.slop != -1 {
		strings.write_string(&pr.b, " $slop: ")
		strings.write_int(&pr.b, n.slop)
		strings.write_string(&pr.b, "; $inorder: ")
		strings.write_string(&pr.b, "true" if n.in_order else "false")
		strings.write_byte(&pr.b, ';')
	} else if n.in_order {
		strings.write_string(&pr.b, " $inorder: true;")
	}
	strings.write_string(&pr.b, " }")
}

field_name :: proc(pr: ^Printer, field: int) -> string {
	if field < 0 || field >= len(pr.schema.fields) {
		return ""
	}
	return pr.schema.fields[field].name
}

write_container :: proc(pr: ^Printer, n: ^Node, head: string, depth: int) {
	write_mask(pr, n.mask)
	strings.write_string(&pr.b, head)
	strings.write_byte(&pr.b, '\n')
	for child in n.children {
		print_node(pr, child, depth + 1)
	}
	write_indent(pr, depth)
	strings.write_byte(&pr.b, '}')
	write_attrs(pr, n)
	strings.write_byte(&pr.b, '\n')
}

write_vector_description :: proc(pr: ^Printer, n: ^Node) {
	v := n.vector
	b := &pr.b
	if v.kind == .Knn {
		strings.write_string(b, "K=")
		strings.write_u64(b, v.k)
		strings.write_string(b, " nearest vectors to `$")
	} else {
		strings.write_string(b, "Vectors that are within ")
		write_c_general(b, v.radius)
		strings.write_string(b, " distance radius from `$")
	}
	strings.write_string(b, v.blob_param)
	strings.write_string(b, "` in vector index associated with field @")
	strings.write_string(b, field_name(pr, v.field))
	for attr in v.attributes {
		strings.write_string(b, ", ")
		strings.write_string(b, attr.name)
		strings.write_string(b, " = ")
		strings.write_string(b, attr.value)
	}
	if v.kind == .Knn {
		strings.write_string(b, ", yields distance as `")
		if v.score_alias != "" {
			strings.write_string(b, v.score_alias)
		} else {
			strings.write_string(b, "__")
			strings.write_string(b, field_name(pr, v.field))
			strings.write_string(b, "_score")
		}
		strings.write_byte(b, '`')
	} else if v.score_alias != "" {
		strings.write_string(b, ", yields distance as `")
		strings.write_string(b, v.score_alias)
		strings.write_byte(b, '`')
	}
}

print_node :: proc(pr: ^Printer, id: Node_Id, depth: int) {
	write_indent(pr, depth)
	n := node_get(pr.q, id)
	b := &pr.b
	switch n.kind {
	case .Null:
		strings.write_string(b, "<empty>\n")
	case .Token:
		write_mask(pr, n.mask)
		if len(n.text) == 0 && n.verbatim {
			strings.write_string(b, "\"\"")
		} else {
			strings.write_string(b, n.text)
		}
		if n.expanded {
			strings.write_string(b, "(expanded)")
		}
		if n.weight != 1 {
			strings.write_string(b, " => {$weight: ")
			write_c_general(b, n.weight)
			strings.write_string(b, ";}")
		}
		strings.write_byte(b, '\n')
	case .Phrase:
		write_container(pr, n, "EXACT {", depth)
	case .Union:
		write_container(pr, n, "UNION {", depth)
	case .Intersect:
		write_container(pr, n, "INTERSECT {", depth)
	case .Not:
		write_container(pr, n, "NOT{", depth)
	case .Optional:
		write_container(pr, n, "OPTIONAL{", depth)
	case .Tag:
		write_mask(pr, n.mask)
		strings.write_string(b, "TAG:@")
		strings.write_string(b, field_name(pr, n.field))
		strings.write_string(b, " {\n")
		for child in n.children {
			print_node(pr, child, depth + 1)
		}
		write_indent(pr, depth)
		strings.write_byte(b, '}')
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Prefix:
		write_mask(pr, n.mask)
		strings.write_string(b, "PREFIX{")
		strings.write_string(b, n.text)
		strings.write_string(b, "*}")
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Suffix:
		write_mask(pr, n.mask)
		strings.write_string(b, "SUFFIX{*")
		strings.write_string(b, n.text)
		strings.write_byte(b, '}')
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Infix:
		write_mask(pr, n.mask)
		strings.write_string(b, "INFIX{*")
		strings.write_string(b, n.text)
		strings.write_string(b, "*}")
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Wildcard_Pattern:
		write_mask(pr, n.mask)
		strings.write_string(b, "WILDCARD{")
		strings.write_string(b, n.text)
		strings.write_byte(b, '}')
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Fuzzy:
		write_mask(pr, n.mask)
		strings.write_string(b, "FUZZY{")
		strings.write_string(b, n.text)
		strings.write_byte(b, '}')
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Numeric:
		if n.mask == 0 {
			strings.write_string(b, "@NULL:")
		}
		strings.write_string(b, "NUMERIC {")
		write_c_fixed(b, n.min)
		strings.write_string(b, " < " if n.min_open else " <= ")
		strings.write_byte(b, '@')
		strings.write_string(b, field_name(pr, n.field))
		strings.write_string(b, " < " if n.max_open else " <= ")
		write_c_fixed(b, n.max)
		strings.write_byte(b, '}')
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Geo:
		if n.mask == 0 {
			strings.write_string(b, "@NULL:")
		}
		strings.write_string(b, "GEO ")
		strings.write_string(b, field_name(pr, n.field))
		strings.write_string(b, ":{")
		write_c_fixed(b, n.lon)
		strings.write_byte(b, ',')
		write_c_fixed(b, n.lat)
		strings.write_string(b, " --> ")
		write_c_fixed(b, n.radius)
		strings.write_byte(b, ' ')
		strings.write_string(b, UNIT_NAMES[n.unit])
		strings.write_byte(b, '}')
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Wildcard:
		strings.write_string(b, "<WILDCARD>")
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Missing:
		strings.write_string(b, "ISMISSING{")
		strings.write_string(b, field_name(pr, n.field))
		strings.write_byte(b, '}')
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Geoshape:
		strings.write_string(b, "GEOSHAPE{")
		strings.write_int(b, n.predicate)
		strings.write_byte(b, ' ')
		strings.write_string(b, n.text)
		strings.write_byte(b, '}')
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	case .Vector:
		strings.write_string(b, "VECTOR {")
		if len(n.children) > 0 {
			strings.write_byte(b, '\n')
			for child in n.children {
				print_node(pr, child, depth + 1)
			}
			write_indent(pr, depth)
			strings.write_string(b, "} => {")
			write_vector_description(pr, n)
			strings.write_byte(b, '}')
		} else {
			write_vector_description(pr, n)
			strings.write_byte(b, '}')
		}
		write_attrs(pr, n)
		strings.write_byte(b, '\n')
	}
}

explain :: proc(q: ^Query, schema: ^Schema, allocator := context.allocator) -> string {
	order := text_ordinals(schema, allocator)
	defer delete(order, allocator)
	pr := Printer {
		q      = q,
		schema = schema,
		b      = strings.builder_make(allocator),
		order  = order,
	}
	if q.root == NO_NODE {
		return strings.to_string(pr.b)
	}
	print_node(&pr, q.root, 0)
	return strings.to_string(pr.b)
}

explain_lines :: proc(q: ^Query, schema: ^Schema, allocator := context.allocator) -> (lines: []string, text: string) {
	text = explain(q, schema, allocator)
	split, err := strings.split(text, "\n", allocator)
	if err != nil {
		return nil, text
	}
	return split, text
}

text_ordinals :: proc(schema: ^Schema, allocator := context.allocator) -> []int {
	order := make([]int, len(schema.fields), allocator)
	next := 0
	for field, i in schema.fields {
		if field.kind == .Text {
			order[i] = next
			next += 1
		} else {
			order[i] = -1
		}
	}
	return order
}

package ftquery

import "core:mem"
import "core:strings"

Parsed :: struct {
	query:   Query,
	arena:   mem.Dynamic_Arena,
	backing: mem.Allocator,
}

parse :: proc(query_text: string, schema: ^Schema, opts: Options, allocator := context.allocator) -> (parsed: ^Parsed, err: Error) {
	parsed = new(Parsed, allocator)
	if parsed == nil {
		return nil, Error{code = .Out_Of_Memory, message = "Out of memory"}
	}
	parsed.backing = allocator
	mem.dynamic_arena_init(&parsed.arena, allocator, allocator)
	arena := mem.dynamic_arena_allocator(&parsed.arena)
	text := strings.clone(query_text, arena)
	options := opts
	dialect := options.dialect
	if dialect < 1 {
		dialect = 1
	}
	q := &parsed.query
	q.dialect = dialect
	q.allocator = arena
	q.nodes = make([dynamic]Node, arena)
	q.root = NO_NODE
	tokens := make([dynamic]Token, arena)
	lexer := Lexer {
		text      = text,
		dialect   = dialect,
		schema    = schema,
		hooks     = &options.hooks,
		allocator = arena,
	}
	if !lex_all(&lexer, &tokens) {
		return parsed, Error{code = .Out_Of_Memory, message = "Out of memory"}
	}
	p := Parser {
		q          = q,
		tokens     = tokens[:],
		dialect    = dialect,
		schema     = schema,
		opts       = &options,
		text       = text,
		allocator  = arena,
		text_order = text_ordinals(schema, arena),
	}
	root := parse_query_tokens(&p)
	if p.failed {
		return parsed, p.err
	}
	q.root = root
	resolve_tree(&p, root)
	if !p.failed {
		validate_tree(&p, root)
	}
	if !p.failed {
		aliases := make([dynamic]string, p.allocator)
		check_aliases(&p, root, &aliases)
	}
	if p.failed {
		q.root = NO_NODE
		return parsed, p.err
	}
	if !options.verbatim && options.hooks.expand != nil {
		q.root = expand_tree(&p, root, false)
	}
	return parsed, Error{}
}

parsed_destroy :: proc(parsed: ^Parsed) {
	if parsed == nil {
		return
	}
	mem.dynamic_arena_destroy(&parsed.arena)
	free(parsed, parsed.backing)
}

missing_param :: proc(p: ^Parser, name: string) {
	fail(p, .Param_Not_Found, plain_message("Parameter not found `", name, "`", allocator = p.allocator))
}

invalid_numeric_param :: proc(p: ^Parser, name, value: string) {
	fail(p, .Numeric_Value_Invalid, plain_message("Invalid numeric value (", value, ") for parameter `", name, "`", allocator = p.allocator))
}

resolve_tree :: proc(p: ^Parser, id: Node_Id) {
	if id == NO_NODE || p.failed {
		return
	}
	n := node_get(p.q, id)
	switch n.kind {
	case .Token:
		if p.dialect >= 2 && !p.seen_tag && n.verbatim && len(n.text) == 0 && n.param == "" && n.mask != ALL_FIELDS && !mask_allows_empty(p, n.mask) {
			fail(p, .Syntax, "Use `INDEXEMPTY` in field creation in order to index and query for empty strings")
			return
		}
		if n.param != "" {
			value, found := param_lookup(p, n.param)
			if !found {
				missing_param(p, n.param)
				return
			}
			if n.field >= 0 {
				n.text = tag_text(p, value, n.field)
			} else {
				n.text = normalize(p, value)
				n.number = len(value) > 0 && number_length(value, 0, p.dialect) == len(value)
			}
		}
	case .Wildcard_Pattern:
		if n.param != "" {
			value, found := param_lookup(p, n.param)
			if !found {
				missing_param(p, n.param)
				return
			}
			n.text = value if n.field < 0 else tag_text(p, value, n.field)
		}
	case .Prefix, .Suffix, .Infix, .Fuzzy:
		if n.param != "" {
			value, found := param_lookup(p, n.param)
			if !found {
				missing_param(p, n.param)
				return
			}
			if n.field >= 0 {
				n.text = tag_text(p, value, n.field)
			} else {
				n.text = normalize(p, value)
			}
		}
	case .Numeric:
		for i in 0 ..< 2 {
			if n.params[i] == "" {
				continue
			}
			value, found := param_lookup(p, n.params[i])
			if !found {
				missing_param(p, n.params[i])
				return
			}
			num, ok := parse_full_double(value)
			if !ok {
				fail(p, .Parse_Args, plain_message("Bad lower range: " if i == 0 else "Bad upper range: ", value, allocator = p.allocator))
				return
			}
			if i == 0 {
				n.min = num
			} else {
				n.max = num
			}
		}
		if !check_numeric_order(p, id) {
			return
		}
	case .Geo:
		for i in 0 ..< 4 {
			if n.params[i] == "" {
				continue
			}
			value, found := param_lookup(p, n.params[i])
			if !found {
				missing_param(p, n.params[i])
				return
			}
			if i == 3 {
				n.text = value
				continue
			}
			num, ok := parse_full_double(value)
			if !ok {
				invalid_numeric_param(p, n.params[i], value)
				return
			}
			switch i {
			case 0:
				n.lon = num
			case 1:
				n.lat = num
			case 2:
				n.radius = num
			}
		}
	case .Geoshape:
		value, found := param_lookup(p, n.params[0])
		if !found {
			missing_param(p, n.params[0])
			return
		}
		n.text = value
	case .Vector:
		v := n.vector
		if n.params[0] != "" {
			value, found := param_lookup(p, n.params[0])
			if !found {
				missing_param(p, n.params[0])
				return
			}
			if v.kind == .Knn {
				if !unsigned_literal(value) {
					invalid_numeric_param(p, n.params[0], value)
					return
				}
				v.k = parse_unsigned(value)
			} else {
				num, ok := parse_full_double(value)
				if !ok {
					invalid_numeric_param(p, n.params[0], value)
					return
				}
				v.radius = num
			}
		}
		if n.params[1] != "" {
			value, found := param_lookup(p, n.params[1])
			if !found {
				missing_param(p, n.params[1])
				return
			}
			v.score_alias = value
		}
		for &attr in v.attributes {
			if strings.has_prefix(attr.value, "$") {
				name := attr.value[1:]
				value, found := param_lookup(p, name)
				if !found {
					missing_param(p, name)
					return
				}
				attr.value = value
			}
		}
		blob, found := param_lookup(p, v.blob_param)
		if !found {
			missing_param(p, v.blob_param)
			return
		}
		v.blob = blob
	case .Tag:
		p.seen_tag = true
	case .Null, .Phrase, .Union, .Intersect, .Not, .Optional, .Wildcard, .Missing:
	}
	for child in node_get(p.q, id).children {
		resolve_tree(p, child)
		if p.failed {
			return
		}
	}
}

vector_error :: proc(p: ^Parser, code: Error_Code, text: string) {
	fail(p, code, strings.concatenate({text, VECTOR_PARAMS_SUFFIX}, p.allocator))
}

positive_integer :: proc(text: string) -> bool {
	v, ok := parse_full_int(text)
	return ok && v > 0
}

geometry_known :: proc(wkt: string) -> bool {
	text := strings.trim_left_space(wkt)
	for name in ([?]string{"POINT", "POLYGON"}) {
		if len(text) >= len(name) && ascii_equal_fold(text[:len(name)], name) {
			return true
		}
	}
	return false
}

positive_double :: proc(text: string) -> bool {
	v, ok := parse_full_double(text)
	return ok && v > 0
}

validate_tree :: proc(p: ^Parser, id: Node_Id) {
	if id == NO_NODE || p.failed {
		return
	}
	n := node_get(p.q, id)
	#partial switch n.kind {
	case .Geo:
		if !n.checked && !check_geo(p, id) {
			return
		}
	case .Geoshape:
		if !geometry_known(n.text) {
			fail(p, .Value_Bad, "Error querying geoshape index: unknown geometry type")
			return
		}
	}
	for child in node_get(p.q, id).children {
		validate_tree(p, child)
		if p.failed {
			return
		}
	}
	n = node_get(p.q, id)
	if n.kind == .Vector && p.opts.check_vectors {
		validate_vector(p, id)
	}
}

validate_vector :: proc(p: ^Parser, id: Node_Id) {
	n := node_get(p.q, id)
	v := n.vector
	field := p.schema.fields[v.field]
	if field.blob_size > 0 && len(v.blob) != field.blob_size {
		b := strings.builder_make(p.allocator)
		strings.write_string(&b, "Error parsing vector similarity query: query vector blob size (")
		strings.write_int(&b, len(v.blob))
		strings.write_string(&b, ") does not match index's expected size (")
		strings.write_int(&b, field.blob_size)
		strings.write_string(&b, ").")
		fail(p, .Query_Bad, strings.to_string(b))
		return
	}
	if v.kind == .Range && v.radius < 0 {
		b := strings.builder_make(p.allocator)
		strings.write_string(&b, "Error parsing vector similarity query: negative radius (")
		write_c_general(&b, v.radius)
		strings.write_string(&b, ") given in a range query")
		fail(p, .Query_Bad, strings.to_string(b))
		return
	}
	hybrid := v.kind == .Knn && len(n.children) > 0
	policy := ""
	batch := false
	for attr, i in v.attributes {
		dup := false
		for prev in v.attributes[:i] {
			if ascii_equal_fold(prev.name, attr.name) {
				dup = true
			}
		}
		switch {
		case ascii_equal_fold(attr.name, "EF_RUNTIME"):
			if field.method != .Hnsw || v.kind == .Range {
				vector_error(p, .Option_Invalid, "Invalid option")
				return
			}
			if !positive_integer(attr.value) {
				vector_error(p, .Value_Bad, "Invalid value was given")
				return
			}
		case ascii_equal_fold(attr.name, "EPSILON"):
			if field.method != .Hnsw {
				vector_error(p, .Option_Invalid, "Invalid option")
				return
			}
			if v.kind == .Knn {
				vector_error(p, .Range_Attr_Non_Range, "range query attributes were sent for a non-range query")
				return
			}
			if !positive_double(attr.value) {
				vector_error(p, .Value_Bad, "Invalid value was given")
				return
			}
		case ascii_equal_fold(attr.name, "HYBRID_POLICY"):
			if !hybrid {
				vector_error(p, .Hybrid_Attr_Non_Hybrid, "hybrid query attributes were sent for a non-hybrid query")
				return
			}
			if !ascii_equal_fold(attr.value, "BATCHES") && !ascii_equal_fold(attr.value, "ADHOC_BF") {
				vector_error(p, .Hybrid_Policy_Bad, "invalid hybrid policy was given")
				return
			}
			policy = attr.value
		case ascii_equal_fold(attr.name, "BATCH_SIZE"):
			if !hybrid {
				vector_error(p, .Hybrid_Attr_Non_Hybrid, "hybrid query attributes were sent for a non-hybrid query")
				return
			}
			if !positive_integer(attr.value) {
				vector_error(p, .Value_Bad, "Invalid value was given")
				return
			}
			batch = true
		case:
			vector_error(p, .Option_Invalid, "Invalid option")
			return
		}
		if dup {
			vector_error(p, .Param_Dup, "Parameter was specified twice")
			return
		}
	}
	if batch && ascii_equal_fold(policy, "ADHOC_BF") {
		vector_error(p, .Adhoc_Batch_Size_Irrelevant, "'batch size' is irrelevant for the selected policy")
	}
}

check_aliases :: proc(p: ^Parser, id: Node_Id, seen: ^[dynamic]string) {
	if id == NO_NODE || p.failed {
		return
	}
	n := node_get(p.q, id)
	if n.kind == .Vector && n.vector.score_alias != "" {
		alias := n.vector.score_alias
		if _, exists := schema_field(p.schema, alias); exists {
			fail(p, .Index_Exists, plain_message("Property `", alias, "` already exists in schema", allocator = p.allocator))
			return
		}
		for other in seen {
			if other == alias {
				fail(p, .Field_Dup, plain_message("Property `", alias, "` specified more than once", allocator = p.allocator))
				return
			}
		}
		append(seen, alias)
	}
	for child in n.children {
		check_aliases(p, child, seen)
		if p.failed {
			return
		}
	}
}

stem_mask :: proc(p: ^Parser) -> Field_Mask {
	mask := Field_Mask(0)
	for field, i in p.schema.fields {
		if field.kind == .Text && .No_Stem not_in field.options {
			mask |= text_bit(p, i)
		}
	}
	return mask
}

stemmable :: proc(p: ^Parser, mask: Field_Mask) -> bool {
	return mask & stem_mask(p) != 0
}

expand_tree :: proc(p: ^Parser, id: Node_Id, inside: bool) -> Node_Id {
	if id == NO_NODE {
		return id
	}
	n := node_get(p.q, id)
	#partial switch n.kind {
	case .Phrase, .Tag:
		return id
	case .Token:
		if inside || n.expanded || n.verbatim || n.number || len(n.text) == 0 || !stemmable(p, n.mask) {
			return id
		}
		hooks := p.opts.hooks
		forms := hooks.expand(hooks.user, n.text, p.opts.language, p.allocator)
		if len(forms) == 0 {
			return id
		}
		mask := n.mask
		pos := n.pos
		union_id := node_new(p.q, .Union)
		u := node_get(p.q, union_id)
		u.mask = mask
		u.pos = pos
		node_add_child(p.q, union_id, id)
		child_mask := mask
		if mask != ALL_FIELDS {
			child_mask = mask & stem_mask(p)
		}
		for form in forms {
			child := make_leaf(p.q, .Token, form, pos)
			c := node_get(p.q, child)
			c.mask = child_mask
			c.expanded = true
			node_add_child(p.q, union_id, child)
		}
		return union_id
	}
	count := len(n.children)
	for i in 0 ..< count {
		child := node_get(p.q, id).children[i]
		replaced := expand_tree(p, child, inside)
		node_get(p.q, id).children[i] = replaced
	}
	return id
}

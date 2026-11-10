package ftquery

import "core:mem"
import "core:strings"

MAX_DEPTH :: 400

STACK_LIMIT_ONE :: 99

STACK_LIMIT_TWO :: 255

STACK_OVERFLOW_MESSAGE :: "Parser stack overflow. Try moving nested parentheses more to the left"

Parser :: struct {
	q:          ^Query,
	tokens:     []Token,
	at:         int,
	dialect:    int,
	schema:     ^Schema,
	opts:       ^Options,
	text:       string,
	err:        Error,
	failed:     bool,
	text_ctx:   int,
	depth:      int,
	after_knn:  bool,
	nontext:    int,
	seen_tag:   bool,
	stack:      int,
	resetting:  bool,
	reset_at:   int,
	knn_attrs:  bool,
	lock_depth: int,
	allocator:  mem.Allocator,
	text_order: []int,
}

Rule :: enum u8 {
	None,
	Or,
	And,
	Not,
	Optional,
	Modifier,
}

peek :: #force_inline proc(p: ^Parser) -> Token {
	return p.tokens[p.at]
}

peek_at :: #force_inline proc(p: ^Parser, offset: int) -> Token {
	i := min(p.at + offset, len(p.tokens) - 1)
	return p.tokens[i]
}

advance :: #force_inline proc(p: ^Parser) -> Token {
	tok := p.tokens[p.at]
	if tok.kind != .End {
		p.at += 1
	}
	return tok
}

fail :: proc(p: ^Parser, code: Error_Code, message: string) {
	if p.failed {
		return
	}
	p.failed = true
	p.err = Error{code = code, message = message}
}

fail_syntax :: proc(p: ^Parser, tok: Token) {
	fail(p, .Syntax, syntax_message("Syntax error", tok.pos, tok.near, p.allocator))
}

stack_limit :: proc(p: ^Parser) -> int {
	return STACK_LIMIT_TWO if p.dialect >= 2 else STACK_LIMIT_ONE
}

stack_room :: proc(p: ^Parser, need: int) -> bool {
	if p.stack + need <= stack_limit(p) {
		return true
	}
	if p.dialect >= 2 {
		fail(p, .Syntax, STACK_OVERFLOW_MESSAGE)
	} else if !p.failed {
		p.failed = true
		p.resetting = true
		p.reset_at = min(p.at + 1, len(p.tokens) - 1)
	}
	return false
}

fail_at :: proc(p: ^Parser, prefix: string, pos: int, near: string) {
	fail(p, .Syntax, syntax_message(prefix, pos, near, p.allocator))
}

field_error :: proc(p: ^Parser, prefix: string, tok: Token) {
	if tok.quirk {
		fail(p, .Syntax, plain_message(prefix, " at offset ", tok.pos, allocator = p.allocator))
		return
	}
	fail_at(p, prefix, tok.pos, tok.text)
}

unknown_field :: proc(p: ^Parser, tok: Token) {
	field_error(p, "Unknown field", tok)
}

expect :: proc(p: ^Parser, kind: Token_Kind) -> (Token, bool) {
	tok := peek(p)
	if tok.kind != kind {
		fail_syntax(p, tok)
		return tok, false
	}
	advance(p)
	return tok, true
}

rule_power :: proc(p: ^Parser, rule: Rule) -> int {
	if p.dialect < 2 {
		switch rule {
		case .None:
			return 0
		case .Optional:
			return 10
		case .Not:
			return 20
		case .Modifier, .And:
			return 30
		case .Or:
			return 40
		}
		return 0
	}
	switch rule {
	case .None:
		return 0
	case .Or:
		return 10
	case .And, .Not, .Optional:
		return 20
	case .Modifier:
		return 25
	}
	return 0
}

token_power :: proc(p: ^Parser, kind: Token_Kind) -> int {
	if p.dialect < 2 {
		#partial switch kind {
		case .Tilde:
			return 10
		case .Quote, .Minus:
			return 20
		case .Term, .Number, .Stopword, .Prefix, .Suffix, .Infix, .Percent, .Lp, .Modifier, .Param, .Star:
			return 30
		case .Or:
			return 40
		case .Arrow:
			return 50
		}
		return 0
	}
	#partial switch kind {
	case .Or:
		return 10
	case .Term, .Stopword, .Phrase, .Quote, .Lp, .Minus, .Tilde, .Modifier, .Ismissing, .Star:
		return 20
	case .Arrow:
		return 22
	case .Number, .Prefix, .Suffix, .Infix, .Percent, .Wildcard, .Param, .Phrase_Prefix, .Param_Prefix, .Param_Suffix, .Param_Infix:
		return 30
	}
	return 0
}

text_bit :: proc(p: ^Parser, field: int) -> Field_Mask {
	if field < 0 || field >= len(p.text_order) || p.text_order[field] < 0 {
		return 0
	}
	return Field_Mask(1) << uint(p.text_order[field])
}

normalize :: proc(p: ^Parser, text: string) -> string {
	if p.opts.hooks.normalize != nil {
		return p.opts.hooks.normalize(p.opts.hooks.user, text, p.allocator)
	}
	return ascii_normalize(nil, text, p.allocator)
}

term_node :: proc(p: ^Parser, tok: Token) -> Node_Id {
	text := tok.text
	if tok.kind == .Term || tok.kind == .Stopword || tok.kind == .Ismissing {
		text = normalize(p, tok.text)
	}
	id := make_leaf(p.q, .Token, text, tok.pos)
	if tok.kind == .Number && p.dialect >= 2 {
		node_get(p.q, id).number = true
	}
	return id
}

parse_expr :: proc(p: ^Parser, rule: Rule, top: bool) -> Node_Id {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_DEPTH {
		fail_syntax(p, peek(p))
		return NO_NODE
	}
	before := p.nontext
	left := parse_unary(p)
	if p.failed {
		return NO_NODE
	}
	left_text := p.nontext == before
	rbp := rule_power(p, rule)
	for {
		tok := peek(p)
		bp := token_power(p, tok.kind)
		if bp <= rbp {
			break
		}
		if tok.kind == .Arrow {
			left = parse_arrow(p, left, top)
			if p.failed {
				return NO_NODE
			}
			continue
		}
		if p.after_knn {
			break
		}
		if tok.kind == .Modifier && p.lock_depth == p.depth {
			break
		}
		if tok.kind == .Or && p.dialect >= 2 {
			left, left_text = parse_union_chain(p, left, left_text)
			if p.failed {
				return NO_NODE
			}
		} else if tok.kind == .Or {
			advance(p)
			p.stack += 2
			right := parse_expr(p, .Or, false)
			p.stack -= 2
			if p.failed {
				return NO_NODE
			}
			left = make_or(p.q, left, right)
		} else {
			mark := p.nontext
			p.stack += 1
			right := parse_expr(p, .And, false)
			p.stack -= 1
			if p.failed {
				return NO_NODE
			}
			left_text = left_text && p.nontext == mark
			left = make_and(p.q, left, right)
		}
	}
	return left
}

parse_operand :: proc(p: ^Parser, text_only: bool) -> (id: Node_Id, text: bool) {
	before := p.nontext
	if text_only {
		p.text_ctx += 1
	}
	p.stack += 2
	id = parse_expr(p, .Or, false)
	p.stack -= 2
	if text_only {
		p.text_ctx -= 1
	}
	return id, p.nontext == before
}

parse_union_chain :: proc(p: ^Parser, first: Node_Id, first_text: bool) -> (Node_Id, bool) {
	advance(p)
	second, second_text := parse_operand(p, false)
	if p.failed {
		return NO_NODE, false
	}
	result := make_or(p.q, first, second)
	if first_text && second_text {
		for peek(p).kind == .Or {
			advance(p)
			saved := p.lock_depth
			p.lock_depth = p.depth + 1
			next, _ := parse_operand(p, true)
			p.lock_depth = saved
			if p.failed {
				return NO_NODE, false
			}
			result = make_or(p.q, result, next)
			if peek(p).kind == .Modifier {
				break
			}
		}
		return result, true
	}
	for peek(p).kind == .Or {
		advance(p)
		next, next_text := parse_operand(p, false)
		if p.failed {
			return NO_NODE, false
		}
		if next_text && peek(p).kind == .Or {
			p.stack += 2
			sub, _ := parse_union_chain(p, next, true)
			p.stack -= 2
			if p.failed {
				return NO_NODE, false
			}
			result = make_or(p.q, result, sub)
			continue
		}
		result = make_or(p.q, result, next)
	}
	return result, false
}

parse_unary :: proc(p: ^Parser) -> Node_Id {
	tok := peek(p)
	if !stack_room(p, 1) {
		return NO_NODE
	}
	#partial switch tok.kind {
	case .Minus:
		advance(p)
		p.stack += 1
		child := parse_expr(p, .Not, false)
		p.stack -= 1
		if p.failed {
			return NO_NODE
		}
		return make_not(p.q, child, tok.pos)
	case .Tilde:
		advance(p)
		p.stack += 1
		child := parse_expr(p, .Optional, false)
		p.stack -= 1
		if p.failed {
			return NO_NODE
		}
		return make_optional(p.q, child, tok.pos)
	case .Lp:
		advance(p)
		p.stack += 1
		inner := parse_expr(p, .None, false)
		if p.failed {
			p.stack -= 1
			return NO_NODE
		}
		if peek(p).kind == .Rp && !stack_room(p, 2) {
			p.stack -= 1
			return NO_NODE
		}
		p.stack -= 1
		if _, ok := expect(p, .Rp); !ok {
			return NO_NODE
		}
		return inner
	case .Modifier:
		if p.dialect >= 2 && p.text_ctx > 0 {
			fail_syntax(p, tok)
			return NO_NODE
		}
		return parse_modifier(p)
	case .Term, .Number:
		advance(p)
		first := term_node(p, tok)
		if p.dialect < 2 {
			next := peek(p)
			if next.kind == .Term || next.kind == .Number {
				list := node_new(p.q, .Intersect)
				node_add_child(p.q, list, first)
				node_add_child(p.q, list, term_node(p, advance(p)))
				for peek(p).kind == .Term {
					node_add_child(p.q, list, term_node(p, advance(p)))
				}
				return list
			}
		}
		return first
	case .Stopword:
		advance(p)
		return make_null(p.q)
	case .Prefix:
		advance(p)
		return make_leaf(p.q, .Prefix, tok.text, tok.pos)
	case .Suffix:
		advance(p)
		return make_leaf(p.q, .Suffix, tok.text, tok.pos)
	case .Infix:
		advance(p)
		return make_leaf(p.q, .Infix, tok.text, tok.pos)
	case .Percent:
		return parse_fuzzy(p)
	case .Quote:
		if p.dialect < 2 {
			return parse_quote_phrase(p)
		}
		advance(p)
		if peek(p).kind == .Param {
			advance(p)
		}
		fail_syntax(p, peek(p))
		return NO_NODE
	case .Phrase:
		advance(p)
		return phrase_node(p, tok)
	case .Phrase_Prefix:
		advance(p)
		return make_leaf(p.q, .Prefix, tok.text, tok.pos)
	case .Wildcard:
		advance(p)
		return wildcard_node(p, tok, -1)
	case .Param_Prefix, .Param_Suffix, .Param_Infix:
		advance(p)
		return param_pattern(p, tok, -1)
	case .Param:
		if p.dialect >= 2 {
			advance(p)
			id := make_leaf(p.q, .Token, "", tok.pos)
			n := node_get(p.q, id)
			n.param = tok.text
			n.param_pos = tok.pos
			return id
		}
	case .Ismissing:
		if p.text_ctx > 0 {
			advance(p)
			return term_node(p, tok)
		}
		return parse_ismissing(p)
	}
	fail_syntax(p, tok)
	return NO_NODE
}

parse_fuzzy :: proc(p: ^Parser) -> Node_Id {
	open := 0
	first := peek(p)
	for peek(p).kind == .Percent && open < 3 {
		advance(p)
		open += 1
	}
	tok := peek(p)
	text: string
	#partial switch tok.kind {
	case .Term, .Number, .Stopword, .Ismissing:
		text = normalize(p, tok.text) if tok.kind != .Number else tok.text
	case .Phrase:
		if p.dialect < 2 {
			fail_syntax(p, tok)
			return NO_NODE
		}
		text = normalize(p, unescape(tok.text, p.allocator))
	case .Param:
		if p.dialect < 2 {
			fail_syntax(p, tok)
			return NO_NODE
		}
	case:
		fail_syntax(p, tok)
		return NO_NODE
	}
	advance(p)
	for _ in 0 ..< open {
		if _, ok := expect(p, .Percent); !ok {
			return NO_NODE
		}
	}
	id := make_leaf(p.q, .Fuzzy, text, first.pos)
	node_get(p.q, id).distance = open
	if tok.kind == .Param {
		node_get(p.q, id).param = tok.text
	}
	return id
}

parse_quote_phrase :: proc(p: ^Parser) -> Node_Id {
	open := advance(p)
	words := make([dynamic]Node_Id, p.allocator)
	seen := 0
	for {
		tok := peek(p)
		if tok.kind == .Stopword && seen >= 2 {
			advance(p)
			continue
		}
		if tok.kind != .Term && tok.kind != .Number {
			break
		}
		advance(p)
		seen += 1
		append(&words, term_node(p, tok))
	}
	if len(words) == 0 {
		fail_syntax(p, peek(p))
		return NO_NODE
	}
	if _, ok := expect(p, .Quote); !ok {
		return NO_NODE
	}
	if len(words) == 1 {
		node_get(p.q, words[0]).verbatim = true
		return words[0]
	}
	id := node_new(p.q, .Phrase)
	node_get(p.q, id).pos = open.pos
	for w in words {
		node_add_child(p.q, id, w)
	}
	return id
}

is_phrase_word_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_alnum(c) || c == '_' || c == '$' || c >= 0x80
}

phrase_words :: proc(p: ^Parser, content: string) -> [dynamic]string {
	words := make([dynamic]string, p.allocator)
	buf := make([dynamic]u8, p.allocator)
	i := 0
	for i < len(content) {
		c := content[i]
		if c == '\\' {
			if i + 1 < len(content) && is_escapable(content[i + 1]) {
				append(&buf, content[i + 1])
				i += 2
				continue
			}
			append(&buf, c)
			i += 1
			continue
		}
		if is_phrase_word_byte(c) {
			append(&buf, c)
			i += 1
			continue
		}
		if len(buf) > 0 {
			append(&words, strings.clone(string(buf[:]), p.allocator))
			clear(&buf)
		}
		i += 1
	}
	if len(buf) > 0 {
		append(&words, strings.clone(string(buf[:]), p.allocator))
	}
	return words
}

phrase_node :: proc(p: ^Parser, tok: Token) -> Node_Id {
	if len(tok.text) == 0 {
		id := make_leaf(p.q, .Token, "", tok.pos)
		node_get(p.q, id).verbatim = true
		return id
	}
	words := phrase_words(p, tok.text)
	id := node_new(p.q, .Phrase)
	node_get(p.q, id).pos = tok.pos
	for w in words {
		child := make_leaf(p.q, .Token, normalize(p, w), tok.pos)
		node_add_child(p.q, id, child)
	}
	return id
}

field_kind_error :: proc(p: ^Parser, kind: Field_Kind, tok: Token) {
	name: string
	switch kind {
	case .Text:
		name = "Expected a TEXT field"
	case .Tag:
		name = "Expected a TAG field"
	case .Numeric:
		name = "Expected a NUMERIC field"
	case .Geo:
		name = "Expected a GEO field"
	case .Vector:
		name = "Expected a VECTOR field"
	case .Geoshape:
		name = "Expected a GEOSHAPE field"
	}
	field_error(p, name, tok)
}

check_field :: proc(p: ^Parser, field: int, kind: Field_Kind, tok: Token) -> bool {
	if field < 0 {
		unknown_field(p, tok)
		return false
	}
	if p.schema.fields[field].kind != kind {
		field_kind_error(p, kind, tok)
		return false
	}
	return true
}

lookup_field :: proc(p: ^Parser, tok: Token) -> int {
	index, found := schema_field(p.schema, tok.text)
	if !found {
		return -1
	}
	return index
}

parse_modifier :: proc(p: ^Parser) -> Node_Id {
	p.nontext += 1
	mod := advance(p)
	field := lookup_field(p, mod)
	if p.dialect >= 2 && field < 0 {
		unknown_field(p, mod)
		return NO_NODE
	}
	next := peek(p)
	#partial switch next.kind {
	case .Eq, .Ne, .Gt, .Ge, .Lt, .Le:
		return parse_comparison(p, mod, field)
	case .Or:
		return parse_field_list(p, mod, field)
	}
	if _, ok := expect(p, .Colon); !ok {
		return NO_NODE
	}
	next = peek(p)
	#partial switch next.kind {
	case .Lb:
		return parse_tag(p, mod, field)
	case .Lsqb:
		return parse_range(p, mod, field)
	}
	mask := text_bit(p, field)
	return parse_text_operand(p, mod, field, mask, false)
}

parse_field_list :: proc(p: ^Parser, mod: Token, field: int) -> Node_Id {
	mask := Field_Mask(0)
	mask |= text_bit(p, field)
	first_checked := false
	for peek(p).kind == .Or {
		advance(p)
		name := peek(p)
		member_ok := name.kind == .Term || name.kind == .Number
		if p.dialect >= 2 && (name.kind == .Stopword || name.kind == .Ismissing || name.kind == .Phrase) {
			member_ok = true
		}
		if !member_ok {
			fail_syntax(p, name)
			return NO_NODE
		}
		advance(p)
		if name.kind == .Number {
			if unsigned_literal(name.text) {
				name.quirk = true
			} else {
				b := strings.builder_make(p.allocator)
				write_c_fixed(&b, parse_number_text(name.text))
				name.raw = strings.to_string(b)
			}
		}
		if p.dialect >= 2 && !first_checked {
			first_checked = true
			if !check_field(p, field, .Text, mod) {
				return NO_NODE
			}
		}
		name.text = name.raw if name.kind != .Phrase else name.text
		other := lookup_field(p, name)
		if p.dialect >= 2 && !check_field(p, other, .Text, name) {
			return NO_NODE
		}
		mask |= text_bit(p, other)
	}
	if _, ok := expect(p, .Colon); !ok {
		return NO_NODE
	}
	return parse_text_operand(p, mod, field, mask, true)
}

parse_text_operand :: proc(p: ^Parser, mod: Token, field: int, mask: Field_Mask, list: bool) -> Node_Id {
	p.text_ctx += 1
	p.stack += 2
	child := parse_expr(p, .Modifier, false)
	p.stack -= 2
	p.text_ctx -= 1
	if p.failed {
		return NO_NODE
	}
	if p.dialect >= 2 && !list && !check_field(p, field, .Text, mod) {
		return NO_NODE
	}
	apply_mask(p.q, child, mask)
	return child
}


mask_allows_empty :: proc(p: ^Parser, mask: Field_Mask) -> bool {
	for field, i in p.schema.fields {
		if field.kind == .Text && .Index_Empty in field.options && (mask & text_bit(p, i)) != 0 {
			return true
		}
	}
	return false
}

parse_comparison :: proc(p: ^Parser, mod: Token, field: int) -> Node_Id {
	op := advance(p)
	value := peek(p)
	if value.kind != .Number && value.kind != .Param {
		fail_syntax(p, value)
		return NO_NODE
	}
	advance(p)
	if !check_field(p, field, .Numeric, mod) {
		return NO_NODE
	}
	id := node_new(p.q, .Numeric)
	n := node_get(p.q, id)
	n.field = field
	n.pos = mod.pos
	num := parse_number_text(value.text)
	inf := f64_inf()
	if value.kind == .Param {
		n.params[0] = value.text
		n.params[1] = value.text
	}
	#partial switch op.kind {
	case .Eq, .Ne:
		n.min, n.max = num, num
	case .Gt:
		n.min, n.max, n.min_open = num, inf, true
		n.params[1] = ""
	case .Ge:
		n.min, n.max = num, inf
		n.params[1] = ""
	case .Lt:
		n.min, n.max, n.max_open = -inf, num, true
		n.params[0] = ""
	case .Le:
		n.min, n.max = -inf, num
		n.params[0] = ""
	}
	if op.kind == .Ne {
		return make_not(p.q, id, mod.pos)
	}
	return id
}

parse_ismissing :: proc(p: ^Parser) -> Node_Id {
	p.nontext += 1
	kw := advance(p)
	if _, ok := expect(p, .Lp); !ok {
		return NO_NODE
	}
	mod := peek(p)
	if mod.kind != .Modifier {
		fail_syntax(p, mod)
		return NO_NODE
	}
	advance(p)
	field := lookup_field(p, mod)
	if field < 0 {
		unknown_field(p, mod)
		return NO_NODE
	}
	if _, ok := expect(p, .Rp); !ok {
		return NO_NODE
	}
	if .Index_Missing not_in p.schema.fields[field].options {
		field_error(p, "'ismissing' requires defining the field with 'INDEXMISSING'", mod)
		return NO_NODE
	}
	id := node_new(p.q, .Missing)
	n := node_get(p.q, id)
	n.field = field
	n.pos = kw.pos
	return id
}

is_tag_field :: proc(p: ^Parser, field: int) -> bool {
	return field >= 0 && p.schema.fields[field].kind == .Tag
}

parse_tag_word :: proc(p: ^Parser, tok: Token, field: int) -> Node_Id {
	if !is_tag_field(p, field) {
		return make_leaf(p.q, .Token, tok.raw, tok.pos)
	}
	return make_leaf(p.q, .Token, tag_text(p, tok.text, field), tok.pos)
}

parse_tag_value_d1 :: proc(p: ^Parser, field: int) -> Node_Id {
	tok := peek(p)
	#partial switch tok.kind {
	case .Term, .Number:
		advance(p)
		first := parse_tag_word(p, tok, field)
		next := peek(p)
		if next.kind == .Term || next.kind == .Number {
			list := node_new(p.q, .Intersect)
			node_add_child(p.q, list, first)
			node_add_child(p.q, list, parse_tag_word(p, advance(p), field))
			for peek(p).kind == .Term {
				node_add_child(p.q, list, parse_tag_word(p, advance(p), field))
			}
			return list
		}
		return first
	case .Stopword:
		advance(p)
		return parse_tag_word(p, tok, field)
	case .Prefix:
		advance(p)
		return make_leaf(p.q, .Prefix, tag_pattern_text(p, tok, field), tok.pos)
	case .Suffix:
		advance(p)
		return make_leaf(p.q, .Suffix, tag_pattern_text(p, tok, field), tok.pos)
	case .Infix:
		advance(p)
		return make_leaf(p.q, .Infix, tag_pattern_text(p, tok, field), tok.pos)
	}
	fail_syntax(p, tok)
	return NO_NODE
}

tag_text :: proc(p: ^Parser, text: string, field: int) -> string {
	if is_tag_field(p, field) && .Case_Sensitive not_in p.schema.fields[field].options {
		return normalize(p, text)
	}
	return text
}

tag_pattern_text :: proc(p: ^Parser, tok: Token, field: int) -> string {
	if !is_tag_field(p, field) {
		return tok.raw
	}
	return tag_text(p, tok.text, field)
}

tag_sequence_word :: #force_inline proc "contextless" (kind: Token_Kind) -> bool {
	return kind == .Term || kind == .Number || kind == .Stopword || kind == .Phrase || kind == .Param || kind == .Ismissing
}

tag_sequence_node :: proc(p: ^Parser, tok: Token, field: int) -> Node_Id {
	#partial switch tok.kind {
	case .Phrase:
		id := make_leaf(p.q, .Token, tag_text(p, unescape(tok.text, p.allocator), field), tok.pos)
		node_get(p.q, id).verbatim = true
		return id
	case .Param:
		id := make_leaf(p.q, .Token, "", tok.pos)
		n := node_get(p.q, id)
		n.param = tok.text
		n.param_pos = tok.pos
		n.field = field
		return id
	}
	return parse_tag_word(p, tok, field)
}

parse_tag_value_d2 :: proc(p: ^Parser, field: int) -> Node_Id {
	tok := peek(p)
	#partial switch tok.kind {
	case .Term, .Number, .Stopword, .Phrase, .Param, .Ismissing:
		advance(p)
		first := tag_sequence_node(p, tok, field)
		if !tag_sequence_word(peek(p).kind) {
			return first
		}
		list := node_new(p.q, .Intersect)
		node_add_child(p.q, list, first)
		for tag_sequence_word(peek(p).kind) {
			node_add_child(p.q, list, tag_sequence_node(p, advance(p), field))
		}
		return list
	case .Prefix:
		advance(p)
		return make_leaf(p.q, .Prefix, tag_text(p, tok.text, field), tok.pos)
	case .Suffix:
		advance(p)
		return make_leaf(p.q, .Suffix, tag_text(p, tok.text, field), tok.pos)
	case .Infix:
		advance(p)
		return make_leaf(p.q, .Infix, tag_text(p, tok.text, field), tok.pos)
	case .Wildcard:
		advance(p)
		return wildcard_node(p, tok, field)
	case .Phrase_Prefix:
		advance(p)
		return make_leaf(p.q, .Prefix, tag_text(p, tok.text, field), tok.pos)
	case .Param_Prefix, .Param_Suffix, .Param_Infix:
		advance(p)
		return param_pattern(p, tok, field)
	}
	fail_syntax(p, tok)
	return NO_NODE
}

parse_tag :: proc(p: ^Parser, mod: Token, field: int) -> Node_Id {
	advance(p)
	tag := node_new(p.q, .Tag)
	node_get(p.q, tag).field = field
	node_get(p.q, tag).pos = mod.pos
	if p.dialect < 2 {
		value := parse_tag_value_d1(p, field)
		if p.failed {
			return NO_NODE
		}
		node_add_child(p.q, tag, value)
		for {
			next := peek(p)
			if next.kind == .Or {
				advance(p)
				value = parse_tag_value_d1(p, field)
				if p.failed {
					return NO_NODE
				}
				node_add_child(p.q, tag, value)
			} else if next.kind == .Rb {
				advance(p)
			} else {
				break
			}
		}
		if field < 0 {
			return make_null(p.q)
		}
		return tag
	}
	for {
		value := parse_tag_value_d2(p, field)
		if p.failed {
			return NO_NODE
		}
		node_add_child(p.q, tag, value)
		next := peek(p)
		if next.kind == .Or {
			advance(p)
			continue
		}
		if next.kind == .Rb {
			advance(p)
			break
		}
		fail_syntax(p, next)
		return NO_NODE
	}
	if !check_field(p, field, .Tag, mod) {
		return NO_NODE
	}
	return tag
}

range_value :: proc(p: ^Parser, allow_param: bool) -> (tok: Token, ok: bool) {
	tok = peek(p)
	if tok.kind == .Number || (allow_param && tok.kind == .Param) {
		advance(p)
		return tok, true
	}
	fail_syntax(p, tok)
	return tok, false
}

parse_range :: proc(p: ^Parser, mod: Token, field: int) -> Node_Id {
	advance(p)
	d2 := p.dialect >= 2
	first := peek(p)
	if d2 && (is_word_token(first.kind) || first.kind == .Ismissing) {
		if peek_at(p, 1).kind == .Param && peek_at(p, 2).kind == .Rsqb {
			return parse_geoshape(p, mod, field)
		}
		return parse_vector_range(p, mod, field)
	}
	min_open := false
	if peek(p).kind == .Lp {
		advance(p)
		min_open = true
	}
	lo, ok := range_value(p, d2)
	if !ok {
		return NO_NODE
	}
	if d2 && peek(p).kind == .Rsqb && !min_open {
		advance(p)
		return numeric_node(p, mod, field, lo, lo, false, false)
	}
	max_open := false
	if peek(p).kind == .Lp {
		advance(p)
		max_open = true
	}
	hi: Token
	hi, ok = range_value(p, d2)
	if !ok {
		return NO_NODE
	}
	if peek(p).kind == .Rsqb {
		advance(p)
		return numeric_node(p, mod, field, lo, hi, min_open, max_open)
	}
	if d2 && (min_open || max_open) {
		fail_syntax(p, peek(p))
		return NO_NODE
	}
	radius: Token
	radius, ok = range_value(p, d2)
	if !ok {
		return NO_NODE
	}
	unit := peek(p)
	if unit.kind != .Term && !(d2 && (unit.kind == .Number || unit.kind == .Param)) {
		fail_syntax(p, unit)
		return NO_NODE
	}
	advance(p)
	if _, rok := expect(p, .Rsqb); !rok {
		return NO_NODE
	}
	return geo_node(p, mod, field, lo, hi, radius, unit)
}

numeric_node :: proc(p: ^Parser, mod: Token, field: int, lo, hi: Token, min_open, max_open: bool) -> Node_Id {
	if p.dialect >= 2 && !check_field(p, field, .Numeric, mod) {
		return NO_NODE
	}
	if field < 0 {
		return make_null(p.q)
	}
	id := node_new(p.q, .Numeric)
	n := node_get(p.q, id)
	n.field = field
	n.pos = mod.pos
	n.min_open = min_open
	n.max_open = max_open
	if lo.kind == .Param {
		n.params[0] = lo.text
	} else {
		n.min = parse_number_text(lo.text)
	}
	if hi.kind == .Param {
		n.params[1] = hi.text
	} else {
		n.max = parse_number_text(hi.text)
	}
	return id
}

schema_checks_order :: proc(p: ^Parser) -> bool {
	for f in p.schema.fields {
		if f.kind == .Text || f.kind == .Tag {
			return true
		}
	}
	return false
}

check_numeric_order :: proc(p: ^Parser, id: Node_Id) -> bool {
	n := node_get(p.q, id)
	if n.min > n.max && schema_checks_order(p) {
		b := strings.builder_make(p.allocator)
		strings.write_string(&b, "Invalid numeric range (min > max): @")
		strings.write_string(&b, p.schema.fields[n.field].name)
		strings.write_string(&b, ":[")
		write_c_fixed(&b, n.min)
		strings.write_byte(&b, ' ')
		write_c_fixed(&b, n.max)
		strings.write_byte(&b, ']')
		fail(p, .Syntax, strings.to_string(b))
		return false
	}
	return true
}

geo_node :: proc(p: ^Parser, mod: Token, field: int, lon, lat, radius, unit: Token) -> Node_Id {
	if p.dialect >= 2 && !check_field(p, field, .Geo, mod) {
		return NO_NODE
	}
	if field < 0 {
		return make_null(p.q)
	}
	id := node_new(p.q, .Geo)
	n := node_get(p.q, id)
	n.field = field
	n.pos = mod.pos
	if lon.kind == .Param {
		n.params[0] = lon.text
	} else {
		n.lon = parse_number_text(lon.text)
	}
	if lat.kind == .Param {
		n.params[1] = lat.text
	} else {
		n.lat = parse_number_text(lat.text)
	}
	if radius.kind == .Param {
		n.params[2] = radius.text
	} else {
		n.radius = parse_number_text(radius.text)
	}
	if unit.kind == .Param {
		n.params[3] = unit.text
	} else {
		n.text = unit.text
	}
	if p.dialect < 2 {
		n.checked = true
		if !check_geo(p, id) {
			return NO_NODE
		}
	}
	return id
}

unit_from :: proc(text: string) -> (unit: Unit, ok: bool) {
	switch {
	case ascii_equal_fold(text, "m"):
		return .M, true
	case ascii_equal_fold(text, "km"):
		return .Km, true
	case ascii_equal_fold(text, "mi"):
		return .Mi, true
	case ascii_equal_fold(text, "ft"):
		return .Ft, true
	}
	return .M, false
}

GEO_LAT_LIMIT :: 85.05112878

check_geo :: proc(p: ^Parser, id: Node_Id) -> bool {
	n := node_get(p.q, id)
	unit, ok := unit_from(n.text)
	if !ok {
		fail(p, .Syntax, "Invalid GeoFilter unit")
		return false
	}
	n.unit = unit
	if n.lon < -180 || n.lon > 180 || n.lat < -GEO_LAT_LIMIT || n.lat > GEO_LAT_LIMIT {
		fail(p, .Syntax, "Invalid GeoFilter lat/lon")
		return false
	}
	if n.radius < 0 {
		fail(p, .Syntax, "Invalid GeoFilter radius")
		return false
	}
	return true
}

parse_vector_range :: proc(p: ^Parser, mod: Token, field: int) -> Node_Id {
	cmd := advance(p)
	radius, ok := range_value(p, true)
	if !ok {
		return NO_NODE
	}
	blob := peek(p)
	if blob.kind != .Param {
		fail_syntax(p, blob)
		return NO_NODE
	}
	advance(p)
	if _, rok := expect(p, .Rsqb); !rok {
		return NO_NODE
	}
	if !ascii_equal_fold(cmd.text, "VECTOR_RANGE") {
		fail_at(p, "Syntax error: expecting vector similarity range command", cmd.pos, cmd.raw)
		return NO_NODE
	}
	if !check_field(p, field, .Vector, mod) {
		return NO_NODE
	}
	id := node_new(p.q, .Vector)
	n := node_get(p.q, id)
	n.field = field
	n.pos = mod.pos
	v := new(Vector_Query, p.allocator)
	v.kind = .Range
	v.field = field
	v.blob_param = blob.text
	v.attributes = make([dynamic]Vector_Attribute, p.allocator)
	if radius.kind == .Param {
		n.params[0] = radius.text
	} else {
		v.radius = parse_number_text(radius.text)
	}
	n.vector = v
	return id
}

is_word_token :: #force_inline proc "contextless" (kind: Token_Kind) -> bool {
	return kind == .Term || kind == .Stopword
}

unsigned_literal :: proc "contextless" (text: string) -> bool {
	if len(text) == 0 {
		return false
	}
	for i in 0 ..< len(text) {
		if !is_digit(text[i]) {
			return false
		}
	}
	return true
}

parse_knn :: proc(p: ^Parser, left: Node_Id, arrow: Token) -> Node_Id {
	advance(p)
	cmd := peek(p)
	if !is_word_token(cmd.kind) {
		fail_syntax(p, cmd)
		return NO_NODE
	}
	advance(p)
	k := peek(p)
	if !(k.kind == .Param || (k.kind == .Number && unsigned_literal(k.text))) {
		fail_syntax(p, k)
		return NO_NODE
	}
	advance(p)
	mod := peek(p)
	if mod.kind != .Modifier {
		fail_syntax(p, mod)
		return NO_NODE
	}
	advance(p)
	field := lookup_field(p, mod)
	if field < 0 {
		unknown_field(p, mod)
		return NO_NODE
	}
	blob := peek(p)
	if blob.kind != .Param {
		fail_syntax(p, blob)
		return NO_NODE
	}
	advance(p)
	v := new(Vector_Query, p.allocator)
	v.kind = .Knn
	v.field = field
	v.blob_param = blob.text
	v.attributes = make([dynamic]Vector_Attribute, p.allocator)
	id := node_new(p.q, .Vector)
	n := node_get(p.q, id)
	n.field = field
	n.pos = arrow.pos
	n.vector = v
	if k.kind == .Param {
		n.params[0] = k.text
	} else {
		v.k = parse_unsigned(k.text)
	}
	for {
		tok := peek(p)
		if tok.kind == .Rsqb {
			advance(p)
			break
		}
		if !is_word_token(tok.kind) {
			fail_syntax(p, tok)
			return NO_NODE
		}
		advance(p)
		value := peek(p)
		if !(is_word_token(value.kind) || value.kind == .Number || value.kind == .Param) {
			fail_syntax(p, value)
			return NO_NODE
		}
		advance(p)
		text := value.raw if value.kind != .Param else ""
		if ascii_equal_fold(tok.text, "AS") {
			if value.kind == .Param {
				node_get(p.q, id).params[1] = value.text
			} else {
				v.score_alias = value.text
			}
			continue
		}
		attr := Vector_Attribute{name = tok.raw, value = text}
		if value.kind == .Param {
			attr.value = strings.concatenate({"$", value.text}, p.allocator)
		}
		append(&v.attributes, attr)
	}
	if !ascii_equal_fold(cmd.text, "KNN") {
		fail_at(p, "Syntax error: Expecting Vector Similarity command", cmd.pos, cmd.raw)
		return NO_NODE
	}
	if !check_field(p, field, .Vector, mod) {
		return NO_NODE
	}
	if !node_is_null(p.q, left) && node_get(p.q, left).kind != .Wildcard {
		node_add_child(p.q, id, left)
	}
	return id
}

Attribute_Entry :: struct {
	name:  Token,
	value: Token,
}

parse_arrow :: proc(p: ^Parser, left: Node_Id, top: bool) -> Node_Id {
	arrow := advance(p)
	next := peek(p)
	if next.kind == .Lsqb && p.dialect >= 2 && top && !p.after_knn {
		id := parse_knn(p, left, arrow)
		if p.failed {
			return NO_NODE
		}
		p.after_knn = true
		return id
	}
	if next.kind != .Lb {
		fail_syntax(p, next)
		return NO_NODE
	}
	if p.after_knn {
		if p.knn_attrs {
			fail_syntax(p, arrow)
			return NO_NODE
		}
		p.knn_attrs = true
	}
	advance(p)
	entries := make([dynamic]Attribute_Entry, p.allocator)
	for peek(p).kind == .Semicolon {
		advance(p)
	}
	if peek(p).kind == .Rb {
		advance(p)
	} else {
		for {
			name := peek(p)
			if name.kind != .Param {
				fail_syntax(p, name)
				return NO_NODE
			}
			advance(p)
			if _, ok := expect(p, .Colon); !ok {
				return NO_NODE
			}
			value := peek(p)
			if !(is_word_token(value.kind) || value.kind == .Number || (value.kind == .Param && p.dialect >= 2)) {
				fail_syntax(p, value)
				return NO_NODE
			}
			advance(p)
			append(&entries, Attribute_Entry{name = name, value = value})
			sep := peek(p)
			if sep.kind == .Semicolon {
				for peek(p).kind == .Semicolon {
					advance(p)
				}
				if peek(p).kind == .Rb {
					advance(p)
					break
				}
				continue
			}
			if sep.kind == .Rb {
				advance(p)
				break
			}
			fail_syntax(p, sep)
			return NO_NODE
		}
	}
	if node_is_null(p.q, left) {
		return left
	}
	for entry in entries {
		apply_attribute(p, left, entry.name.text, entry.value)
		if p.failed {
			return NO_NODE
		}
	}
	return left
}

attribute_value_text :: proc(p: ^Parser, value: Token) -> string {
	if value.kind == .Param {
		return ""
	}
	return value.raw
}

apply_attribute :: proc(p: ^Parser, id: Node_Id, name: string, value: Token) {
	if value.kind == .Param {
		resolved, found := param_lookup(p, value.text)
		if !found {
			fail(p, .Param_Not_Found, plain_message("Parameter not found `", value.text, "`", allocator = p.allocator))
			return
		}
		apply_attribute_text(p, id, name, resolved)
		return
	}
	apply_attribute_text(p, id, name, value.raw)
}

parse_bool_text :: proc(text: string) -> (value: bool, ok: bool) {
	switch {
	case ascii_equal_fold(text, "true"), text == "1":
		return true, true
	case ascii_equal_fold(text, "false"), text == "0":
		return false, true
	}
	return false, false
}

invalid_attribute_value :: proc(p: ^Parser, canonical, value: string) {
	fail(p, .Syntax, plain_message("Invalid value (", value, ") for `", canonical, "`", allocator = p.allocator))
}

apply_attribute_text :: proc(p: ^Parser, id: Node_Id, name: string, value: string) {
	n := node_get(p.q, id)
	switch {
	case ascii_equal_fold(name, "weight"):
		w, ok := parse_full_double(value)
		if !ok || w < 0 {
			invalid_attribute_value(p, "weight", value)
			return
		}
		n.weight = w
		n.has_attrs = true
	case ascii_equal_fold(name, "slop"):
		s, ok := parse_full_int(value)
		if !ok || s < -1 {
			invalid_attribute_value(p, "slop", value)
			return
		}
		n.slop = int(s)
		n.has_attrs = true
	case ascii_equal_fold(name, "inorder"):
		b, ok := parse_bool_text(value)
		if !ok {
			invalid_attribute_value(p, "inorder", value)
			return
		}
		n.in_order = b
		n.has_attrs = true
	case ascii_equal_fold(name, "phonetic"):
		b, ok := parse_bool_text(value)
		if !ok {
			invalid_attribute_value(p, "phonetic", value)
			return
		}
		n.phonetic = 1 if b else 2
	case n.kind == .Vector && ascii_equal_fold(name, "yield_distance_as"):
		n.vector.score_alias = value
	case n.kind == .Vector && ascii_equal_fold(name, "shard_k_ratio"):
	case n.kind == .Vector && (ascii_equal_fold(name, "ef_runtime") || ascii_equal_fold(name, "epsilon") || ascii_equal_fold(name, "hybrid_policy") || ascii_equal_fold(name, "batch_size")):
		append(&n.vector.attributes, Vector_Attribute{name = name, value = value})
	case:
		fail(p, .Option_Invalid, plain_message("Invalid attribute ", name, allocator = p.allocator))
	}
}

param_lookup :: proc(p: ^Parser, name: string) -> (string, bool) {
	for param in p.opts.params {
		if param.name == name {
			return param.value, true
		}
	}
	return "", false
}

star_query :: proc(p: ^Parser) -> (id: Node_Id, matched: bool) {
	depth := 0
	for p.tokens[p.at + depth].kind == .Lp {
		depth += 1
	}
	if p.tokens[p.at + depth].kind != .Star {
		return NO_NODE, false
	}
	if p.dialect < 2 {
		if depth > 0 {
			fail_syntax(p, p.tokens[p.at + depth])
			return NO_NODE, true
		}
		advance(p)
		next := peek(p)
		if next.kind != .End {
			fail_syntax(p, next)
			return NO_NODE, true
		}
		return node_new(p.q, .Wildcard), true
	}
	p.at += depth + 1
	for _ in 0 ..< depth {
		if _, ok := expect(p, .Rp); !ok {
			return NO_NODE, true
		}
	}
	star := node_new(p.q, .Wildcard)
	next := peek(p)
	if next.kind == .End {
		return star, true
	}
	if next.kind != .Arrow {
		fail_syntax(p, next)
		return NO_NODE, true
	}
	after := peek_at(p, 1)
	if after.kind != .Lsqb {
		advance(p)
		fail_syntax(p, after)
		return NO_NODE, true
	}
	return star, true
}

parse_query_tokens :: proc(p: ^Parser) -> Node_Id {
	for {
		root := parse_query_once(p)
		if !p.resetting {
			return root
		}
		p.resetting = false
		p.failed = false
		p.err = {}
		p.at = p.reset_at
		p.stack = 0
		p.text_ctx = 0
		p.depth = 0
		p.after_knn = false
		p.nontext = 0
	}
}

parse_query_once :: proc(p: ^Parser) -> Node_Id {
	if peek(p).kind == .End {
		return make_null(p.q)
	}
	star, matched := star_query(p)
	if p.failed {
		return NO_NODE
	}
	if matched {
		if peek(p).kind == .End {
			return star
		}
		root := star
		for peek(p).kind == .Arrow {
			root = parse_arrow(p, root, true)
			if p.failed {
				return NO_NODE
			}
		}
		if tok := peek(p); tok.kind != .End {
			fail_syntax(p, tok)
			return NO_NODE
		}
		return root
	}
	root := parse_expr(p, .None, true)
	if p.failed {
		return NO_NODE
	}
	if tok := peek(p); tok.kind != .End {
		fail_syntax(p, tok)
		return NO_NODE
	}
	return root
}

GEOSHAPE_PREDICATES := [?]string{"CONTAINS", "WITHIN", "DISJOINT", "INTERSECTS"}

parse_geoshape :: proc(p: ^Parser, mod: Token, field: int) -> Node_Id {
	cmd := advance(p)
	param := advance(p)
	advance(p)
	code := 0
	for name, i in GEOSHAPE_PREDICATES {
		if ascii_equal_fold(cmd.text, name) {
			code = i + 1
		}
	}
	if code == 0 {
		fail(p, .Syntax, plain_message("Syntax error: Expecting a geoshape predicate at offset ", param.pos, allocator = p.allocator))
		return NO_NODE
	}
	if !check_field(p, field, .Geoshape, mod) {
		return NO_NODE
	}
	id := node_new(p.q, .Geoshape)
	n := node_get(p.q, id)
	n.field = field
	n.pos = mod.pos
	n.predicate = code
	n.params[0] = param.text
	return id
}

param_pattern :: proc(p: ^Parser, tok: Token, field: int) -> Node_Id {
	kind := Node_Kind.Prefix
	#partial switch tok.kind {
	case .Param_Suffix:
		kind = .Suffix
	case .Param_Infix:
		kind = .Infix
	}
	id := make_leaf(p.q, kind, "", tok.pos)
	n := node_get(p.q, id)
	n.param = tok.text
	n.param_pos = tok.pos
	n.field = field
	return id
}

wildcard_node :: proc(p: ^Parser, tok: Token, field: int) -> Node_Id {
	if len(tok.raw) > 1 && tok.raw[0] == '$' {
		id := make_leaf(p.q, .Wildcard_Pattern, "", tok.pos)
		n := node_get(p.q, id)
		n.param = tok.raw[1:]
		n.param_pos = tok.pos
		n.field = field
		return id
	}
	text := tok.text if field < 0 else tag_text(p, tok.text, field)
	return make_leaf(p.q, .Wildcard_Pattern, text, tok.pos)
}

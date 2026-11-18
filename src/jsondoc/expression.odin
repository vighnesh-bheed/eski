package jsondoc

import "core:math"
import "core:mem"
import "core:unicode/utf8"

Operator :: struct {
	token: string,
	kind: Expr_Kind,
	precedence: int,
	word: bool,
}

operators := [?]Operator{
	{"||", .Or, 1, false},
	{"&&", .And, 2, false},
	{"==", .Eq, 3, false},
	{"!=", .Ne, 3, false},
	{"<=", .Le, 3, false},
	{">=", .Ge, 3, false},
	{"=~", .Regex, 3, false},
	{"<", .Lt, 3, false},
	{">", .Gt, 3, false},
	{"subsetof", .Subset, 3, true},
	{"anyof", .Any, 3, true},
	{"noneof", .None, 3, true},
	{"sizeof", .Size, 3, true},
	{"size", .Size, 3, true},
	{"empty", .Empty, 3, true},
	{"nin", .Nin, 3, true},
	{"in", .In, 3, true},
	{"+", .Add, 4, false},
	{"-", .Sub, 4, false},
	{"*", .Mul, 5, false},
	{"/", .Div, 5, false},
	{"%", .Rem, 5, false},
}

parse_expression :: proc(p: ^Path_Parser, in_filter: bool, minimum: int) -> ^Expr {
	if p.nesting >= MAX_DEPTH {
		p.error = {message = DEPTH_LIMIT}
		return nil
	}
	p.nesting += 1
	defer p.nesting -= 1
	e := parse_factor(p, in_filter)
	if e == nil {
		return nil
	}
	for p.error == {} {
		previous := p.pos
		path_space(p)
		found: Operator
		for op in operators {
			if op.precedence < minimum || (!in_filter && op.precedence <= 3) {
				continue
			}
			if op.precedence >= 4 {
				if previous == p.pos || !path_whitespace(path_next(p)) {
					continue
				}
			}
			if op.word && name_byte(path_next(p, len(op.token))) {
				continue
			}
			if path_take(p, op.token) {
				found = op
				break
			}
		}
		if found.precedence == 0 {
			return e
		}
		if in_filter && found.precedence >= 4 {
			path_space(p)
			path_fail(p, p.pos, EXPECT_COMPARISON)
			return nil
		}
		right := parse_expression(p, in_filter, found.precedence + 1)
		if right == nil {
			return nil
		}
		binary := expr_new(p, found.kind)
		if binary == nil {
			return nil
		}
		binary.left, binary.right = e, right
		binary.rooted = e.rooted || right.rooted
		e = binary
	}
	return nil
}

parse_factor :: proc(p: ^Path_Parser, in_filter: bool) -> ^Expr {
	path_space(p)
	start := p.pos
	c := path_peek(p)
	switch c {
	case '$', '@':
		if c == '$' || in_filter {
			return parse_selector(p, in_filter)
		}
	case '(':
		p.pos += 1
		e := parse_expression(p, in_filter, 1)
		if e == nil {
			return nil
		}
		path_space(p)
		if !path_take(p, ")") {
			path_fail(p, p.pos, EXPECT_FILTER if in_filter else "'..'")
			return nil
		}
		if !in_filter && e.kind == .Selector {
			wrapper := expr_new(p, .Pos)
			if wrapper == nil {
				return nil
			}
			wrapper.left, wrapper.rooted = e, e.rooted
			return wrapper
		}
		return e
	case '!', '+', '-':
		if c == '!' && in_filter || !in_filter && c != '!' && !digit(path_next(p)) {
			p.pos += 1
			e := expr_new(p, .Not if c == '!' else (.Neg if c == '-' else .Pos))
			if e == nil {
				return nil
			}
			e.left = parse_expression(p, in_filter, 4 if c == '!' else 6)
			if e.left == nil {
				return nil
			}
			e.rooted = e.left.rooted
			return e
		}
	}
	if name_byte(c) && !digit(c) && c != '-' {
		for name_byte(path_peek(p)) {
			p.pos += 1
		}
		if path_peek(p) == '(' && p.pos > start {
			return parse_call(p, p.text[start:p.pos], in_filter, nil)
		}
		p.pos = start
	}
	literal := path_literal(p, 0)
	if literal == nil {
		path_fail(p, start, "arith_factor")
		return nil
	}
	e := expr_new(p, .Literal)
	if e != nil {
		e.literal = literal
	}
	return e
}

parse_call :: proc(p: ^Path_Parser, name: string, in_filter: bool, receiver: ^Expr) -> ^Expr {
	e := expr_new(p, .Call)
	if e == nil {
		return nil
	}
	e.name = name
	if receiver != nil {
		if !path_push(p, &e.args, receiver) {
			return nil
		}
		e.rooted = receiver.rooted
	}
	p.pos += 1
	path_space(p)
	if path_take(p, ")") {
		return e
	}
	for {
		arg := parse_expression(p, in_filter, 1)
		if arg == nil || !path_push(p, &e.args, arg) {
			return nil
		}
		e.rooted = e.rooted || arg.rooted
		path_space(p)
		if path_take(p, ")") {
			return e
		}
		if !path_take(p, ",") {
			path_fail(p, p.pos, "'..'")
			return nil
		}
	}
}

path_literal :: proc(p: ^Path_Parser, nesting: int) -> ^Value {
	path_space(p)
	c := path_peek(p)
	if c == '[' || c == '{' {
		if nesting >= MAX_DEPTH {
			p.error = {message = DEPTH_LIMIT}
			return nil
		}
		return path_literal_container(p, nesting + 1)
	}
	data: Data
	switch c {
	case '"', '\'':
		s, ok := path_quote(p, false)
		if !ok {
			return nil
		}
		s, ok = copy_text(s, p.allocator)
		if !ok {
			p.error = {message = OUT_OF_MEMORY}
			return nil
		}
		data = s
	case 'n':
		if !path_take(p, "null") {
			return nil
		}
		data = Null{}
	case 't', 'f':
		if !path_take(p, "true" if c == 't' else "false") {
			return nil
		}
		data = c == 't'
	case '-', '0'..='9':
		begin := p.pos
		_, ok := path_integer(p)
		if !ok {
			return nil
		}
		if path_peek(p) == '.' && digit(path_next(p)) {
			p.pos += 1
			for digit(path_peek(p)) {
				p.pos += 1
			}
		}
		sub := Parser{text = p.text[begin:p.pos]}
		data = parse_number(&sub)
		if data == nil {
			return nil
		}
	case:
		return nil
	}
	v := new_value(data, p.allocator)
	if v == nil {
		p.error = {message = OUT_OF_MEMORY}
	}
	return v
}

path_literal_container :: proc(p: ^Path_Parser, nesting: int) -> ^Value {
	object := path_peek(p) == '{'
	end: u8 = '}' if object else ']'
	p.pos += 1
	v := make_object(p.allocator) if object else make_array(p.allocator)
	if v == nil {
		p.error = {message = OUT_OF_MEMORY}
		return nil
	}
	path_space(p)
	if path_peek(p) == end {
		p.pos += 1
		return v
	}
	for i := 0; i < MAX_PATH_STEPS; i += 1 {
		name: string
		if object {
			var, ok := path_quote(p, false)
			path_space(p)
			if !ok || !path_take(p, ":") {
				return nil
			}
			name, ok = copy_text(var, p.allocator)
			if !ok {
				p.error = {message = OUT_OF_MEMORY}
				return nil
			}
		}
		child := path_literal(p, nesting)
		if child == nil {
			return nil
		}
		err := object_add(v, name, child, p.allocator) if object else array_add(v, child)
		if err != "" {
			p.error = {message = err}
			return nil
		}
		path_space(p)
		if path_peek(p) == end {
			p.pos += 1
			return v
		}
		if !path_take(p, ",") {
			return nil
		}
		path_space(p)
	}
	p.error = {message = SIZE_LIMIT}
	return nil
}

Match :: struct {
	value, parent: ^Value,
	index: int,
	name: string,
}

Evaluation :: struct {
	allocator: mem.Allocator,
	root: ^Value,
	error: string,
	work, active: int,
}

Eval_Result :: struct {
	matches: [dynamic]Match,
	value: ^Value,
	unpack: bool,
	selector: bool,
}

MAX_WORK :: 8 * MAX_ITEMS

select_path :: proc(root: ^Value, path: Path, allocator := context.allocator) -> (Eval_Result, string) {
	if root == nil || path.expr == nil {
		return {}, ""
	}
	ev := Evaluation{allocator = allocator, root = root}
	if !path.expr.rooted {
		return {}, ""
	}
	results := evaluate(&ev, root, path.expr)
	return results, ev.error
}

eval_push :: proc(ev: ^Evaluation, list: ^[dynamic]Match, item: Match) {
	if ev.error != "" {
		return
	}
	if len(list) >= MAX_ITEMS {
		ev.error = SIZE_LIMIT
		return
	}
	if _, err := append(list, item); err != nil {
		ev.error = OUT_OF_MEMORY
	}
}

eval_charge :: proc(ev: ^Evaluation) -> bool {
	ev.work += 1
	if ev.work >= MAX_WORK {
		ev.error = SIZE_LIMIT
	}
	return ev.error == ""
}

eval_selector :: proc(ev: ^Evaluation, current: ^Value, steps: []Step) -> Eval_Result {
	items, scratch: [dynamic]Match
	items.allocator, scratch.allocator = ev.allocator, ev.allocator
	defer delete(scratch)
	if current == nil {
		return {selector = true}
	}
	eval_push(ev, &items, Match{value = current, parent = current.parent, index = -1})
	for step in steps {
		clear(&scratch)
		for item in items {
			eval_step(ev, item.value, step, &scratch)
		}
		items, scratch = scratch, items
		if ev.error != "" || len(items) == 0 {
			break
		}
	}
	return {matches = items, selector = true}
}

eval_step :: proc(ev: ^Evaluation, v: ^Value, step: Step, items: ^[dynamic]Match) {
	if !eval_charge(ev) {
		return
	}
	v_array := as_array(v)
	v_object := as_object(v)
	switch step.kind {
	case .Name:
		if v_object != nil {
			push_name(ev, items, v, v_object, step.name)
		}
	case .Names:
		if v_object != nil {
			for name in step.names {
				push_name(ev, items, v, v_object, name)
			}
		}
	case .Index:
		if v_array != nil {
			push_index(ev, items, v, v_array, step.index)
		}
	case .Indexes:
		if v_array != nil {
			for index in step.indexes {
				push_index(ev, items, v, v_array, index)
			}
		}
	case .Slice:
		if v_array != nil {
			n := len(v_array.items)
			lo := relative_index(step.start, n)
			hi := relative_index(step.end, n)
			for i := lo; i < hi; i += int(min(step.stride, i64(hi - i))) {
				eval_push(ev, items, Match{v_array.items[i], v, i, ""})
			}
		}
	case .Wildcard, .Filter:
		if v_array != nil {
			for child, index in v_array.items {
				if step.kind == .Wildcard || evaluate_filter(ev, child, step.predicate) {
					eval_push(ev, items, Match{child, v, index, ""})
				}
			}
		} else if v_object != nil {
			for member, index in v_object.members {
				if step.kind == .Wildcard || evaluate_filter(ev, member.value, step.predicate) {
					eval_push(ev, items, Match{member.value, v, index, member.name})
				}
			}
		}
	}
	if step.descend {
		if v_array != nil {
			for child in v_array.items {
				eval_step(ev, child, step, items)
			}
		} else if v_object != nil {
			for member in v_object.members {
				eval_step(ev, member.value, step, items)
			}
		}
	}
}

push_name :: proc(ev: ^Evaluation, items: ^[dynamic]Match, v: ^Value, obj: ^Object, name: string) {
	index := object_index(obj, name)
	if index >= 0 {
		member := obj.members[index]
		eval_push(ev, items, Match{member.value, v, index, member.name})
	}
}

push_index :: proc(ev: ^Evaluation, items: ^[dynamic]Match, v: ^Value, array: ^Array, index: i64) {
	i := relative_index(index, len(array.items))
	if i < len(array.items) {
		eval_push(ev, items, Match{array.items[i], v, i, ""})
	}
}

relative_index :: proc(index: i64, count: int) -> int {
	if index < 0 {
		return int(max(0, i64(count) + index))
	}
	return int(min(index, i64(count)))
}

one :: proc(res: Eval_Result) -> ^Value {
	if res.selector {
		if len(res.matches) == 1 {
			return res.matches[0].value
		}
		return nil
	}
	return res.value
}

evaluate_filter :: proc(ev: ^Evaluation, node: ^Value, e: ^Expr) -> bool {
	result := evaluate(ev, node, e)
	defer delete(result.matches)
	if result.selector {
		return len(result.matches) != 0
	}
	v := result.value
	if v == nil {
		return false
	}
	flag, boolean := v.data.(bool)
	return !boolean || flag
}

eval_value :: proc(ev: ^Evaluation, data: Data, unpack := false) -> Eval_Result {
	v := new_value(data, ev.allocator)
	if v == nil {
		ev.error = OUT_OF_MEMORY
	}
	return {value = v, unpack = unpack}
}

evaluate :: proc(ev: ^Evaluation, node: ^Value, e: ^Expr) -> Eval_Result {
	if !eval_charge(ev) || e == nil {
		return {}
	}
	if ev.active >= MAX_DEPTH {
		ev.error = DEPTH_LIMIT
		return {}
	}
	ev.active += 1
	defer ev.active -= 1
	#partial switch e.kind {
	case .Selector:
		return eval_selector(ev, ev.root if e.root else node, e.steps[:])
	case .Literal:
		return {value = e.literal}
	case .Call:
		return eval_call(ev, node, e)
	case .And:
		return eval_value(ev, evaluate_filter(ev, node, e.left) && evaluate_filter(ev, node, e.right))
	case .Or:
		return eval_value(ev, evaluate_filter(ev, node, e.left) || evaluate_filter(ev, node, e.right))
	case .Not:
		return eval_value(ev, !evaluate_filter(ev, node, e.left))
	}
	left := evaluate(ev, node, e.left)
	defer delete(left.matches)
	a := one(left)
	if e.right == nil {
		if e.kind == .Pos {
			return {value = a}
		}
		return eval_arithmetic(ev, .Sub, &Value{data = i64(0)}, a)
	}
	right := evaluate(ev, node, e.right)
	defer delete(right.matches)
	b := one(right)
	if e.kind >= .Add && e.kind <= .Rem {
		return eval_arithmetic(ev, e.kind, a, b)
	}
	return eval_value(ev, compare_expression(e.kind, a, b))
}

eval_arithmetic :: proc(ev: ^Evaluation, kind: Expr_Kind, a, b: ^Value) -> Eval_Result {
	x, x_ok := number(a)
	y, y_ok := number(b)
	if !x_ok || !y_ok || (y == 0 && (kind == .Div || kind == .Rem)) {
		return {}
	}
	x_int, xi := a.data.(i64)
	y_int, yi := b.data.(i64)
	if xi && yi {
		i, j := i128(x_int), i128(y_int)
		n: i128
		#partial switch kind {
		case .Add: n = i + j
		case .Sub: n = i - j
		case .Mul: n = i * j
		case .Div: n = i / j
		case .Rem: n = i % j
		}
		if i128(min(i64)) <= n && n <= i128(max(i64)) && (kind != .Div || i % j == 0) {
			return eval_value(ev, i64(n))
		}
	}
	n: f64
	#partial switch kind {
	case .Add: n = x + y
	case .Sub: n = x - y
	case .Mul: n = x * y
	case .Div: n = x / y
	case .Rem: n = math.mod(x, y)
	}
	if math.is_nan(n) || math.is_inf(n) {
		return {}
	}
	return eval_value(ev, n)
}

value_equal :: proc(a, b: ^Value, numeric := false) -> bool {
	if a == nil || b == nil {
		return false
	}
	if numeric {
		if cmp, comparable := compare_number(a, b); comparable {
			return cmp == 0
		}
	}
	#partial switch s in a.data {
	case Null:
		_, ok := b.data.(Null)
		return ok
	case bool:
		n, ok := b.data.(bool)
		return ok && s == n
	case i64:
		n, ok := b.data.(i64)
		return ok && s == n
	case u64:
		n, ok := b.data.(u64)
		return ok && s == n
	case f64:
		n, ok := b.data.(f64)
		return ok && s == n
	case string:
		n, ok := b.data.(string)
		return ok && s == n
	case ^Array:
		other := as_array(b)
		if other == nil || len(s.items) != len(other.items) {
			return false
		}
		for item, i in s.items {
			if !value_equal(item, other.items[i], numeric) {
				return false
			}
		}
		return true
	case ^Object:
		other := as_object(b)
		if other == nil || len(s.members) != len(other.members) {
			return false
		}
		for member in s.members {
			if !value_equal(member.value, object_lookup(other, member.name), numeric) {
				return false
			}
		}
		return true
	}
	return false
}

compare_number :: proc(a, b: ^Value) -> (int, bool) {
	an, a_ok := number(a)
	bn, b_ok := number(b)
	if !a_ok || !b_ok {
		return 0, false
	}
	af, ai := a.data.(f64)
	bf, bi := b.data.(f64)
	if ai && bi {
		return int(af > bf) - int(af < bf), true
	}
	av, bv: i128
	if !ai {
		av = integer_value(a)
	}
	if !bi {
		bv = integer_value(b)
	}
	if ai {
		return -compare_integer_float(bv, af), true
	}
	if bi {
		return compare_integer_float(av, bf), true
	}
	return int(av > bv) - int(av < bv), an == an && bn == bn
}

integer_value :: proc(v: ^Value) -> i128 {
	if n, ok := v.data.(i64); ok {
		return i128(n)
	}
	return i128(v.data.(u64))
}

compare_integer_float :: proc(i: i128, n: f64) -> int {
	if n < f64(min(i64)) {
		return 1
	}
	if n >= 18446744073709551616.0 {
		return -1
	}
	whole := i128(n)
	if i == whole {
		return int(n < f64(whole)) - int(n > f64(whole))
	}
	return int(i > whole) - int(i < whole)
}

compare_expression :: proc(kind: Expr_Kind, a, b: ^Value) -> bool {
	#partial switch kind {
	case .Eq: return value_equal(a, b, true)
	case .Ne: return !value_equal(a, b, true)
	case .In, .Nin:
		member := contains_value(b, a)
		return member != (kind == .Nin)
	case .Size, .Empty:
		n, ok := value_length(a)
		if !ok || b == nil {
			return false
		}
		if kind == .Size {
			i, integer := b.data.(i64)
			return integer && i == i64(n)
		}
		flag, boolean := b.data.(bool)
		return boolean && flag == (n == 0)
	case .Subset, .Any, .None:
		if a == nil || b == nil {
			return false
		}
		array := as_array(a)
		list := as_array(b)
		if list == nil {
			return false
		}
		if array == nil {
			return kind == .None
		}
		common := 0
		for item in array.items {
			common += int(contains_value(b, item))
		}
		return (kind == .Subset && common == len(array.items)) || (kind == .Any && common > 0) || (kind == .None && common == 0)
	case .Regex:
		if a == nil || b == nil {
			return false
		}
		s, s_ok := a.data.(string)
		p, p_ok := b.data.(string)
		return s_ok && p_ok && regex_match(s, p, false)
	}
	if a == nil || b == nil {
		return false
	}
	n, comparable := compare_number(a, b)
	if !comparable {
		#partial switch x in a.data {
		case string:
			y, ok := b.data.(string)
			n, comparable = int(x > y) - int(x < y), ok
		case bool:
			y, ok := b.data.(bool)
			n, comparable = int(x) - int(y), ok
		}
	}
	if !comparable {
		return false
	}
	return (kind == .Lt && n < 0) || (kind == .Le && n <= 0) || (kind == .Gt && n > 0) || (kind == .Ge && n >= 0)
}

contains_value :: proc(a, v: ^Value) -> bool {
	if a != nil {
		if array := as_array(a); array != nil {
			for item in array.items {
				if value_equal(item, v, true) {
					return true
				}
			}
		}
	}
	return false
}

value_length :: proc(v: ^Value, runes := false) -> (int, bool) {
	if v != nil {
		#partial switch a in v.data {
		case ^Array: return len(a.items), true
		case ^Object: return len(a.members), true
		case string: return utf8.rune_count(a) if runes else len(a), true
		}
	}
	return 0, false
}

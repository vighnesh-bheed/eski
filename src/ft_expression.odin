package main

import "core:c/libc"
import "core:math"
import "core:strings"
import fi "ftindex"
import "geo"

FT_Json_Double :: distinct f64

FT_Value :: union {
	f64,
	i64,
	FT_Json_Double,
	string,
	[]FT_Value,
	FT_Object,
}

FT_Cell :: struct {
	name: string,
	value: FT_Value,
}

FT_Expr_Kind :: enum {
	Literal,
	Property,
	Call,
	Not, Positive, Negative,
	Or, And,
	Equal, Unequal, Less, Greater, At_Most, At_Least,
	Add, Subtract, Multiply, Divide, Modulo, Power,
}

FT_Expr :: struct {
	kind: FT_Expr_Kind,
	name: string,
	value: FT_Value,
	args: []^FT_Expr,
	depth: int,
}

FT_Expr_Parser :: struct {
	input: string,
	at: int,
	error: string,
}

FT_EXPR_DEPTH :: 128

FT_Expr_Function :: enum {
	Unknown,
	Exists, Case,
	Log, Abs, Ceil, Floor, Log2, Exp, Sqrt,
	Upper, Lower, Starts_With, Contains, Strlen, Substr, Format, Split, Geo_Distance, Matched_Terms,
	Timefmt, Parsetime, Day, Hour, Minute, Month, Day_Of_Week, Day_Of_Month, Day_Of_Year, Year, Month_Of_Year,
}

FT_EXPR_FUNCTIONS := #partial [FT_Expr_Function]struct{name: string, min, max: int}{
	.Exists = {"exists", 1, 1},
	.Case = {"case", 3, 3},
	.Log = {"log", 1, 1},
	.Abs = {"abs", 1, 1},
	.Ceil = {"ceil", 1, 1},
	.Floor = {"floor", 1, 1},
	.Log2 = {"log2", 1, 1},
	.Exp = {"exp", 1, 1},
	.Sqrt = {"sqrt", 1, 1},
	.Upper = {"upper", 1, 1},
	.Lower = {"lower", 1, 1},
	.Starts_With = {"startswith", 2, 2},
	.Contains = {"contains", 2, 2},
	.Strlen = {"strlen", 1, 1},
	.Substr = {"substr", 3, 3},
	.Format = {"format", 1, max(int)},
	.Split = {"split", 1, 3},
	.Timefmt = {"timefmt", 1, 2},
	.Parsetime = {"parsetime", 2, 2},
	.Geo_Distance = {"geodistance", 2, 4},
	.Matched_Terms = {"matched_terms", 0, 1},
	.Day = {"day", 1, 1},
	.Hour = {"hour", 1, 1},
	.Minute = {"minute", 1, 1},
	.Month = {"month", 1, 1},
	.Day_Of_Week = {"dayofweek", 1, 1},
	.Day_Of_Month = {"dayofmonth", 1, 1},
	.Day_Of_Year = {"dayofyear", 1, 1},
	.Year = {"year", 1, 1},
	.Month_Of_Year = {"monthofyear", 1, 1},
}

ft_expr_parse :: proc(query: string) -> (^FT_Expr, string) {
	parser := FT_Expr_Parser{input = query}
	node := ft_expr_read(&parser, 1, 0)
	ft_expr_space(&parser)
	if node == nil || parser.at != len(query) {
		ft_expr_syntax(&parser)
	}
	return node, parser.error
}

ft_expr_space :: proc(p: ^FT_Expr_Parser) {
	for p.at < len(p.input) {
		c := p.input[p.at]
		if c != ' ' && (c < '\t' || c > '\r') {
			break
		}
		p.at += 1
	}
}

ft_expr_syntax :: proc(p: ^FT_Expr_Parser) {
	if p.error != "" {
		return
	}
	at := p.at
	end := at
	for end < len(p.input) && p.input[end] != ' ' && p.input[end] != '\t' && p.input[end] != ')' {
		end += 1
	}
	if at == end && end < len(p.input) {
		end += 1
	}
	p.error = ft_error("SEARCH_EXPR Syntax error at offset ", ft_int_text(i64(at)), " near '", p.input[at:end], "'")
}

ft_expr_node :: proc(p: ^FT_Expr_Parser, value: FT_Expr) -> ^FT_Expr {
	depth := 1
	for child in value.args {
		if child == nil {
			return nil
		}
		depth = max(depth, child.depth + 1)
	}
	if depth > FT_EXPR_DEPTH {
		p.error = "SEARCH_EXPR Expression nesting limit exceeded"
		return nil
	}
	out := new(FT_Expr, context.temp_allocator)
	out^ = value
	out.depth = depth
	return out
}

ft_expr_children :: proc(items: ..^FT_Expr) -> []^FT_Expr {
	out := make([]^FT_Expr, len(items), context.temp_allocator)
	copy(out, items)
	return out
}

ft_expr_read :: proc(p: ^FT_Expr_Parser, precedence, level: int) -> ^FT_Expr {
	if level >= FT_EXPR_DEPTH {
		p.error = "SEARCH_EXPR Expression nesting limit exceeded"
		return nil
	}
	left := ft_expr_atom(p, level)
	for left != nil {
		ft_expr_space(p)
		kind, power, size := ft_expr_operator(p.input[p.at:])
		if power < precedence {
			break
		}
		p.at += size
		right := ft_expr_read(p, power + int(kind != .Power), level + 1)
		left = ft_expr_node(p, FT_Expr{kind = kind, args = ft_expr_children(left, right)})
	}
	return left
}

ft_expr_operator :: proc "contextless" (input: string) -> (FT_Expr_Kind, int, int) {
	if len(input) >= 2 {
		switch input[:2] {
		case "||": return .Or, 1, 2
		case "&&": return .And, 2, 2
		case "==": return .Equal, 3, 2
		case "!=": return .Unequal, 3, 2
		case "<=": return .At_Most, 4, 2
		case ">=": return .At_Least, 4, 2
		}
	}
	if len(input) == 0 {
		return {}, 0, 0
	}
	if len(input) > 1 && (input[0] == '+' || input[0] == '-') && (ft_expr_digit(input[1]) || input[1] == '.') {
		return {}, 0, 0
	}
	switch input[0] {
	case '<': return .Less, 4, 1
	case '>': return .Greater, 4, 1
	case '+': return .Add, 5, 1
	case '-': return .Subtract, 5, 1
	case '*': return .Multiply, 6, 1
	case '/': return .Divide, 6, 1
	case '%': return .Modulo, 6, 1
	case '^': return .Power, 7, 1
	}
	return {}, 0, 0
}

ft_expr_digit :: proc "contextless" (ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

ft_expr_word :: proc "contextless" (ch: u8) -> bool {
	return ft_expr_digit(ch) || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_' || ch >= 128
}

ft_expr_atom :: proc(p: ^FT_Expr_Parser, level: int) -> ^FT_Expr {
	ft_expr_space(p)
	if p.at == len(p.input) {
		ft_expr_syntax(p)
		return nil
	}
	ch := p.input[p.at]
	switch ch {
	case '(':
		p.at += 1
		value := ft_expr_read(p, 1, level + 1)
		ft_expr_space(p)
		if p.at == len(p.input) || p.input[p.at] != ')' {
			ft_expr_syntax(p)
			return nil
		}
		p.at += 1
		return value
	case '!', '+', '-':
		p.at += 1
		kind := FT_Expr_Kind.Not
		if ch == '+' { kind = .Positive }
		if ch == '-' { kind = .Negative }
		value := ft_expr_read(p, 8, level + 1)
		return ft_expr_node(p, FT_Expr{kind = kind, args = ft_expr_children(value)})
	case '\'', '"':
		return ft_expr_string(p)
	case '@':
		p.at += 1
		first := p.at
		for p.at < len(p.input) && (ft_expr_word(p.input[p.at]) || p.input[p.at] == '.') {
			p.at += 1
		}
		if p.at == first {
			ft_expr_syntax(p)
			return nil
		}
		return ft_expr_node(p, FT_Expr{kind = .Property, name = p.input[first:p.at]})
	}
	if ft_expr_digit(ch) || ch == '.' {
		first := p.at
		for p.at < len(p.input) && (ft_expr_digit(p.input[p.at]) || p.input[p.at] == '.') {
			p.at += 1
		}
		if p.at < len(p.input) && (p.input[p.at] == 'e' || p.input[p.at] == 'E') {
			p.at += 1
			if p.at < len(p.input) && (p.input[p.at] == '+' || p.input[p.at] == '-') {
				p.at += 1
			}
			for p.at < len(p.input) && ft_expr_digit(p.input[p.at]) {
				p.at += 1
			}
		}
		value, ok := fi.number_parse(p.input[first:p.at])
		if ok {
			return ft_expr_node(p, FT_Expr{value = value})
		}
		p.at = first
	}
	first := p.at
	for p.at < len(p.input) && ft_expr_word(p.input[p.at]) {
		p.at += 1
	}
	if p.at != first {
		name := p.input[first:p.at]
		ft_expr_space(p)
		if p.at < len(p.input) && p.input[p.at] == '(' {
			return ft_expr_call(p, name, level)
		}
		switch name {
		case "inf", "INF":
			return ft_expr_node(p, FT_Expr{value = math.inf_f64(1)})
		case "NULL", "null":
			return ft_expr_node(p, FT_Expr{})
		}
		p.at = first
	}
	ft_expr_syntax(p)
	return nil
}

ft_expr_string :: proc(p: ^FT_Expr_Parser) -> ^FT_Expr {
	first := p.at
	quote := p.input[p.at]
	p.at += 1
	out := make([dynamic]u8, context.temp_allocator)
	for p.at < len(p.input) {
		ch := p.input[p.at]
		p.at += 1
		if ch == quote {
			return ft_expr_node(p, FT_Expr{value = string(out[:])})
		}
		if ch == '\\' && p.at < len(p.input) {
			ch = p.input[p.at]
			p.at += 1
		}
		append(&out, ch)
	}
	p.at = first
	ft_expr_syntax(p)
	return nil
}

ft_expr_function :: proc "contextless" (name: string) -> FT_Expr_Function {
	for kind in FT_Expr_Function {
		if kind != .Unknown && eq_nocase(transmute([]u8)name, FT_EXPR_FUNCTIONS[kind].name) {
			return kind
		}
	}
	return .Unknown
}

ft_expr_call :: proc(p: ^FT_Expr_Parser, name: string, level: int) -> ^FT_Expr {
	kind := ft_expr_function(name)
	if kind == .Unknown {
		p.error = ft_error("SEARCH_EXPR Unknown function name '", name, "'")
		return nil
	}
	p.at += 1
	ft_expr_space(p)
	args := make([dynamic]^FT_Expr, context.temp_allocator)
	if p.at < len(p.input) && p.input[p.at] != ')' {
		for {
			arg := ft_expr_read(p, 1, level + 1)
			if arg == nil {
				return nil
			}
			append(&args, arg)
			ft_expr_space(p)
			if p.at == len(p.input) || p.input[p.at] != ',' {
				break
			}
			p.at += 1
		}
	}
	if p.at == len(p.input) || p.input[p.at] != ')' {
		ft_expr_syntax(p)
		return nil
	}
	p.at += 1
	function := FT_EXPR_FUNCTIONS[kind]
	if len(args) < function.min || len(args) > function.max {
		if function.min == function.max {
			p.error = ft_error("SEARCH_EXPR Function '", function.name, "' expects ", ft_int_text(i64(function.min)), " arguments, but got ", ft_int_text(i64(len(args))))
		} else {
			p.error = ft_error("SEARCH_EXPR Invalid number of arguments for function '", name, "'")
		}
		return nil
	}
	return ft_expr_node(p, FT_Expr{kind = .Call, name = function.name, args = args[:]})
}

ft_cell_get :: proc "contextless" (cells: []FT_Cell, name: string) -> (FT_Value, bool) {
	for cell in cells {
		if cell.name == name {
			return cell.value, true
		}
	}
	return nil, false
}

ft_number :: proc(value: FT_Value) -> (f64, bool) {
	switch v in value {
	case f64: return v, true
	case i64: return f64(v), true
	case FT_Json_Double: return f64(v), true
	case string: return fi.number_parse(v)
	case []FT_Value, FT_Object:
	}
	return 0, false
}

ft_value_string :: proc(value: FT_Value) -> string {
	switch v in value {
	case string:
		return v
	case f64:
		buf: [48]u8
		n := int(libc.snprintf(raw_data(buf[:]), len(buf), "%.12g", v))
		return strings.clone(string(buf[:clamp(n, 0, len(buf) - 1)]), context.temp_allocator)
	case i64:
		return ft_int_text(v)
	case FT_Json_Double:
		return ft_value_string(f64(v))
	case []FT_Value, FT_Object:
	}
	return ""
}

ft_truth :: proc "contextless" (value: FT_Value) -> bool {
	switch v in value {
	case f64: return v != 0 && v == v
	case i64: return v != 0
	case FT_Json_Double: return v != 0 && v == v
	case string: return len(v) != 0
	case []FT_Value: return len(v) != 0
	case FT_Object: return len(v) != 0
	}
	return false
}

ft_compare :: proc(left, right: FT_Value) -> int {
	if left == nil || right == nil {
		return int(left != nil) - int(right != nil)
	}
	lstr, ls := left.(string)
	rstr, rs := right.(string)
	if ls && rs {
		return int(lstr > rstr) - int(lstr < rstr)
	}
	ln, lnum := ft_number(left)
	rn, rnum := ft_number(right)
	if lnum && rnum {
		if (ln == ln) != (rn == rn) {
			return int(ln != ln) - int(rn != rn)
		}
		return int(ln > rn) - int(ln < rn)
	}
	lstr, rstr = ft_value_string(left), ft_value_string(right)
	return int(lstr > rstr) - int(lstr < rstr)
}

FT_VALUE_MISSING :: "SEARCH_VALUE_NOT_FOUND Could not find the value for a parameter name, consider using EXISTS if applicable for "
FT_VALUE_NUMERIC :: "SEARCH_NUMERIC_VALUE_INVALID Invalid numeric value"

ft_expr_eval :: proc(expr: ^FT_Expr, cells: []FT_Cell, matches: []string) -> (FT_Value, string) {
	#partial switch expr.kind {
	case .Literal:
		return expr.value, ""
	case .Property:
		v, _ := ft_cell_get(cells, expr.name)
		if v == nil {
			return nil, ft_error(FT_VALUE_MISSING, expr.name)
		}
		return v, ""
	case .Call:
		return ft_expr_eval_call(expr, cells, matches)
	case:
	}
	left, err := ft_expr_eval(expr.args[0], cells, matches)
	if err != "" {
		return nil, err
	}
	#partial switch expr.kind {
	case .Not:
		return f64(int(!ft_truth(left))), ""
	case .Positive, .Negative:
		n, ok := ft_number(left)
		if !ok { return nil, FT_VALUE_NUMERIC }
		return (-n if expr.kind == .Negative else n), ""
	case .Or, .And:
		value := ft_truth(left)
		if value == (expr.kind == .Or) {
			return f64(int(value)), ""
		}
		right, problem := ft_expr_eval(expr.args[1], cells, matches)
		return f64(int(ft_truth(right))), problem
	case:
	}
	right, problem := ft_expr_eval(expr.args[1], cells, matches)
	if problem != "" {
		return nil, problem
	}
	#partial switch expr.kind {
	case .Equal: return f64(int(ft_compare(left, right) == 0)), ""
	case .Unequal: return f64(int(ft_compare(left, right) != 0)), ""
	case .Less: return f64(int(ft_compare(left, right) < 0)), ""
	case .Greater: return f64(int(ft_compare(left, right) > 0)), ""
	case .At_Most: return f64(int(ft_compare(left, right) <= 0)), ""
	case .At_Least: return f64(int(ft_compare(left, right) >= 0)), ""
	case:
	}
	l, lok := ft_number(left)
	r, rok := ft_number(right)
	if !lok || !rok {
		return nil, FT_VALUE_NUMERIC
	}
	#partial switch expr.kind {
	case .Add: return l + r, ""
	case .Subtract: return l - r, ""
	case .Multiply: return l * r, ""
	case .Divide: return l / r, ""
	case .Modulo: return math.mod(l, r), ""
	case .Power: return math.pow(l, r), ""
	case:
	}
	return nil, ""
}

ft_expr_eval_call :: proc(expr: ^FT_Expr, cells: []FT_Cell, matches: []string) -> (FT_Value, string) {
	kind := ft_expr_function(expr.name)
	if kind == .Exists {
		value, err := ft_expr_eval(expr.args[0], cells, matches)
		return f64(int(err == "" && value != nil)), ""
	}
	if kind == .Case {
		value, err := ft_expr_eval(expr.args[0], cells, matches)
		if err != "" {
			return nil, err
		}
		return ft_expr_eval(expr.args[1 if ft_truth(value) else 2], cells, matches)
	}
	local: [3]FT_Value
	args := local[:len(expr.args)] if len(expr.args) <= len(local) else make([]FT_Value, len(expr.args), context.temp_allocator)
	for arg, i in expr.args {
		value, err := ft_expr_eval(arg, cells, matches)
		if err != "" {
			return nil, err
		}
		args[i] = value
	}
	#partial switch kind {
	case .Log, .Abs, .Ceil, .Floor, .Log2, .Exp, .Sqrt:
		value, ok := ft_number(args[0])
		if !ok { return nil, FT_VALUE_NUMERIC }
		#partial switch kind {
		case .Log: return math.ln(value), ""
		case .Abs: return math.abs(value), ""
		case .Ceil: return math.ceil(value), ""
		case .Floor: return math.floor(value), ""
		case .Log2: return math.log2(value), ""
		case .Exp: return math.exp(value), ""
		case .Sqrt: return math.sqrt(value), ""
		}
	case .Upper, .Lower, .Starts_With, .Contains, .Strlen, .Substr, .Format, .Split:
		return ft_expr_string_call(kind, args)
	case .Timefmt, .Parsetime, .Day, .Hour, .Minute, .Month, .Day_Of_Week, .Day_Of_Month, .Day_Of_Year, .Year, .Month_Of_Year:
		return ft_expr_time(kind, args)
	case .Geo_Distance:
		return ft_expr_geo(args)
	case .Matched_Terms:
		count := len(matches)
		if len(args) != 0 {
			n, ok := ft_number(args[0])
			if !ok || n != n {
				return nil, FT_VALUE_NUMERIC
			}
			count = int(clamp(n, 0, f64(count)))
		}
		if count == 0 {
			return nil, ""
		}
		values := make([]FT_Value, count, context.temp_allocator)
		for word, i in matches[:count] {
			values[i] = word
		}
		return values, ""
	case:
	}
	return nil, ""
}

ft_expr_string_call :: proc(kind: FT_Expr_Function, args: []FT_Value) -> (FT_Value, string) {
	s := ft_value_string(args[0])
	#partial switch kind {
	case .Upper: return strings.to_upper(s, context.temp_allocator), ""
	case .Lower: return strings.to_lower(s, context.temp_allocator), ""
	case .Starts_With: return f64(int(strings.has_prefix(s, ft_value_string(args[1])))), ""
	case .Contains:
		needle := ft_value_string(args[1])
		if len(needle) == 0 {
			return f64(len(s) + 1), ""
		}
		count := 0
		for len(s) >= len(needle) {
			at := strings.index(s, needle)
			if at < 0 {
				break
			}
			s = s[at+1:]
			count += 1
		}
		return f64(count), ""
	case .Strlen: return f64(len(s)), ""
	case .Substr:
		offset, ok := ft_number(args[1])
		count, good := ft_number(args[2])
		if !ok || !good || offset != offset || count != count {
			return nil, FT_VALUE_NUMERIC
		}
		n := f64(len(s))
		start := int(clamp(offset, 0, n)) if offset >= 0 else int(clamp(n + offset, 0, n))
		size := len(s) - start
		if count >= 0 {
			size = int(clamp(count, 0, f64(size)))
		} else if count < -1 {
			size = int(clamp(f64(size) + count, 0, f64(size)))
		}
		return s[start:start+size], ""
	case .Format:
		return ft_expr_format(s, args[1:])
	case .Split:
		sep, strip := ",", " "
		if len(args) >= 2 { sep = ft_value_string(args[1]) }
		if len(args) >= 3 { strip = ft_value_string(args[2]) }
		out := make([dynamic]FT_Value, context.temp_allocator)
		for len(s) != 0 {
			end := 0
			for end < len(s) && strings.index_byte(sep, s[end]) < 0 {
				end += 1
			}
			part := strings.trim(s[:end], strip)
			if part != "" { append(&out, FT_Value(part)) }
			s = s[min(end + 1, len(s)):]
		}
		return out[:], ""
	case:
	}
	return nil, ""
}

ft_expr_format :: proc(format: string, args: []FT_Value) -> (FT_Value, string) {
	out := make([dynamic]u8, context.temp_allocator)
	arg := 0
	for i := 0; i < len(format); i += 1 {
		ch := format[i]
		if ch != '%' {
			append(&out, ch)
			continue
		}
		i += 1
		if i == len(format) {
			return nil, "SEARCH_EXPR Invalid format string"
		}
		if format[i] == '%' {
			append(&out, '%')
		} else if format[i] == 's' && arg < len(args) {
			append(&out, ..transmute([]u8)ft_value_string(args[arg]))
			arg += 1
		} else {
			return nil, "SEARCH_EXPR Invalid format string"
		}
	}
	return string(out[:]), ""
}

foreign import ft_libc "system:c"

foreign ft_libc {
	@(link_name="strptime")
	ft_strptime :: proc "c" (input, format: cstring, result: ^libc.tm) -> [^]u8 ---
	@(link_name="timegm")
	ft_timegm :: proc "c" (value: ^libc.tm) -> libc.time_t ---
}

ft_expr_time :: proc(kind: FT_Expr_Function, args: []FT_Value) -> (FT_Value, string) {
	if kind == .Parsetime || kind == .Timefmt {
		format := "%FT%TZ"
		if len(args) == 2 {
			format = ft_value_string(args[1])
		}
		pattern := strings.clone_to_cstring(format, context.temp_allocator)
		if kind == .Parsetime {
			tm: libc.tm
			input := strings.clone_to_cstring(ft_value_string(args[0]), context.temp_allocator)
			end := ft_strptime(input, pattern, &tm)
			if end == nil {
				return nil, ""
			}
			return f64(ft_timegm(&tm)), ""
		}
		value, ok := ft_number(args[0])
		if !ok || !(value >= -62167219200 && value <= 253402300799) {
			return nil, ""
		}
		t := libc.time_t(value)
		tm := libc.gmtime(&t)
		if tm == nil {
			return nil, ""
		}
		buf: [1024]u8
		n := int(libc.strftime(raw_data(buf[:]), len(buf), pattern, tm))
		return strings.clone(string(buf[:n]), context.temp_allocator), ""
	}
	value, ok := ft_number(args[0])
	if !ok || !(value >= -62167219200 && value <= 253402300799) {
		return nil, FT_VALUE_NUMERIC
	}
	t := libc.time_t(value)
	tm := libc.gmtime(&t)
	if tm == nil {
		return nil, ""
	}
	#partial switch kind {
	case .Day: return value - f64(tm.tm_hour * 3600 + tm.tm_min * 60 + tm.tm_sec), ""
	case .Hour: return value - f64(tm.tm_min * 60 + tm.tm_sec), ""
	case .Minute: return value - f64(tm.tm_sec), ""
	case .Month:
		start := tm^
		start.tm_mday, start.tm_hour, start.tm_min, start.tm_sec = 1, 0, 0, 0
		return f64(ft_timegm(&start)), ""
	case .Day_Of_Week: return f64(tm.tm_wday), ""
	case .Day_Of_Month: return f64(tm.tm_mday), ""
	case .Day_Of_Year: return f64(tm.tm_yday), ""
	case .Year: return f64(tm.tm_year + 1900), ""
	case .Month_Of_Year: return f64(tm.tm_mon), ""
	case:
	}
	return nil, ""
}

ft_expr_geo :: proc(args: []FT_Value) -> (FT_Value, string) {
	values: [4]f64
	at := 0
	for value in args {
		if at == len(values) {
			return f64(0), ""
		}
		if s, is_string := value.(string); is_string {
			comma := strings.index_byte(s, ',')
			if comma >= 0 && at < len(values) - 1 {
				lon, lon_ok := fi.number_parse(strings.trim_space(s[:comma]))
				lat, lat_ok := fi.number_parse(strings.trim_space(s[comma+1:]))
				if !lon_ok || !lat_ok {
					return f64(0), ""
				}
				values[at], values[at+1] = lon, lat
				at += 2
				continue
			}
		}
		n, ok := ft_number(value)
		if !ok {
			return f64(0), ""
		}
		values[at] = n
		at += 1
	}
	if at != len(values) {
		return f64(0), ""
	}
	for value, i in values {
		maximum := 180.0 if i % 2 == 0 else 90.0
		if !(value >= -maximum && value <= maximum) {
			return f64(0), ""
		}
	}
	return math.round(geo.distance(values[0], values[1], values[2], values[3]) * 100) / 100, ""
}

ft_expr_tracks_matches :: proc(expr: ^FT_Expr) -> bool {
	if expr.kind == .Call && expr.name == "matched_terms" {
		return true
	}
	for child in expr.args {
		if ft_expr_tracks_matches(child) {
			return true
		}
	}
	return false
}

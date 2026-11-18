package jsondoc

import "core:mem"

Operation :: enum {
	Unknown,
	Get, Type, Resp, Debug_Memory, Debug_Help,
	Str_Len, Str_Append,
	Arr_Len, Arr_Append, Arr_Insert, Arr_Index, Arr_Pop, Arr_Trim,
	Obj_Len, Obj_Keys,
	Num_Incr, Num_Mult, Num_Pow,
	Toggle, Clear, Del, Forget,
	Set, Merge, Mset, Mget,
}

name_operation :: proc(name: string) -> Operation {
	if ascii_equal(name, "JSON.GET") { return .Get }
	if ascii_equal(name, "JSON.TYPE") { return .Type }
	if ascii_equal(name, "JSON.RESP") { return .Resp }
	if ascii_equal(name, "JSON.DEBUG") { return .Debug_Memory }
	if ascii_equal(name, "JSON.STRLEN") { return .Str_Len }
	if ascii_equal(name, "JSON.STRAPPEND") { return .Str_Append }
	if ascii_equal(name, "JSON.ARRLEN") { return .Arr_Len }
	if ascii_equal(name, "JSON.ARRAPPEND") { return .Arr_Append }
	if ascii_equal(name, "JSON.ARRINSERT") { return .Arr_Insert }
	if ascii_equal(name, "JSON.ARRINDEX") { return .Arr_Index }
	if ascii_equal(name, "JSON.ARRPOP") { return .Arr_Pop }
	if ascii_equal(name, "JSON.ARRTRIM") { return .Arr_Trim }
	if ascii_equal(name, "JSON.OBJLEN") { return .Obj_Len }
	if ascii_equal(name, "JSON.OBJKEYS") { return .Obj_Keys }
	if ascii_equal(name, "JSON.NUMINCRBY") { return .Num_Incr }
	if ascii_equal(name, "JSON.NUMMULTBY") { return .Num_Mult }
	if ascii_equal(name, "JSON.NUMPOWBY") { return .Num_Pow }
	if ascii_equal(name, "JSON.TOGGLE") { return .Toggle }
	if ascii_equal(name, "JSON.CLEAR") { return .Clear }
	if ascii_equal(name, "JSON.DEL") { return .Del }
	if ascii_equal(name, "JSON.FORGET") { return .Forget }
	if ascii_equal(name, "JSON.SET") { return .Set }
	if ascii_equal(name, "JSON.MERGE") { return .Merge }
	if ascii_equal(name, "JSON.MSET") { return .Mset }
	if ascii_equal(name, "JSON.MGET") { return .Mget }
	return .Unknown
}

ascii_equal :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] == b[i] {
			continue
		}
		if a[i] < 'a' || a[i] > 'z' || a[i] - ('a'-'A') != b[i] {
			return false
		}
	}
	return true
}

operation_name :: proc(op: Operation) -> string {
	switch op {
	case .Unknown: return "json.unknown"
	case .Get: return "json.get"
	case .Type: return "json.type"
	case .Resp: return "json.resp"
	case .Debug_Memory, .Debug_Help: return "json.debug"
	case .Str_Len: return "json.strlen"
	case .Str_Append: return "json.strappend"
	case .Arr_Len: return "json.arrlen"
	case .Arr_Append: return "json.arrappend"
	case .Arr_Insert: return "json.arrinsert"
	case .Arr_Index: return "json.arrindex"
	case .Arr_Pop: return "json.arrpop"
	case .Arr_Trim: return "json.arrtrim"
	case .Obj_Len: return "json.objlen"
	case .Obj_Keys: return "json.objkeys"
	case .Num_Incr: return "json.numincrby"
	case .Num_Mult: return "json.nummultby"
	case .Num_Pow: return "json.numpowby"
	case .Toggle: return "json.toggle"
	case .Clear: return "json.clear"
	case .Del: return "json.del"
	case .Forget: return "json.forget"
	case .Set: return "json.set"
	case .Merge: return "json.merge"
	case .Mset: return "json.mset"
	case .Mget: return "json.mget"
	}
	return ""
}

arity_error :: proc(op: Operation, allocator: mem.Allocator) -> Outcome {
	b: Buffer
	buffer_init(&b, allocator)
	defer delete(b.bytes)
	buffer_add(&b, "ERR wrong number of arguments for '")
	buffer_add(&b, operation_name(op))
	buffer_add(&b, "' command")
	if b.error != "" {
		return type_error(b.error)
	}
	text, ok := copy_text(string(b.bytes[:]), allocator)
	return type_error(text if ok else OUT_OF_MEMORY)
}

integer_argument :: proc(s: string) -> (i64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	negative := s[0] == '-'
	start := int(s[0] == '+' || negative)
	if start == len(s) {
		return 0, false
	}
	magnitude, fits := unsigned_decimal(s[start:])
	if !fits || magnitude > u64(max(i64))+u64(negative) {
		return 0, false
	}
	if negative && magnitude != 0 {
		return -i64(magnitude-1)-1, true
	}
	return i64(magnitude), true
}

wrong_key_type :: "Existing key has wrong Redis type"
syntax_error :: "ERR syntax error"
parse_integer_error :: "Couldn't parse as integer"

Request :: struct {
	op: Operation,
	path: Path,
	values: []^Value,
	argument: ^Value,
	index, stop: i64,
	protocol: int,
}

Set_Request :: struct {
	path: Path,
	value: ^Value,
	condition: Condition,
}

set_options :: proc(op: Operation, args: []string, allocator: mem.Allocator) -> (condition: Condition, narrow: Float_Format, error: Outcome) {
	for i := 0; i < len(args); i += 1 {
		token := args[i]
		switch {
		case op == .Set && (ascii_equal(token, "NX") || ascii_equal(token, "XX")):
			if condition != .None {
				return {}, {}, type_error(syntax_error)
			}
			condition = .NX if ascii_equal(token, "NX") else .XX
		case ascii_equal(token, "FORMAT"):
			i += 1
			if i == len(args) {
				return {}, {}, arity_error(op, allocator)
			}
			switch args[i] {
			case "JSON", "STRING":
			case "BSON":
				return {}, {}, type_error("malformed value: \"document length incorrect\"")
			case:
				return {}, {}, type_error("ERR wrong format")
			}
		case op == .Set && ascii_equal(token, "FPHA"):
			i += 1
			if i == len(args) {
				return {}, {}, arity_error(op, allocator)
			}
			switch {
			case ascii_equal(args[i], "FP16"): narrow = .FP16
			case ascii_equal(args[i], "BF16"): narrow = .BF16
			case ascii_equal(args[i], "FP32"): narrow = .FP32
			case ascii_equal(args[i], "FP64"): narrow = .FP64
			case: return {}, {}, type_error("ERR invalid FPHA type")
			}
		case:
			return {}, {}, type_error(syntax_error)
		}
	}
	return condition, narrow, {}
}

prepare_set :: proc(root: ^Value, op: Operation, args: []string, allocator: mem.Allocator) -> (Set_Request, Outcome) {
	if len(args) < 2 {
		return {}, arity_error(op, allocator)
	}
	condition, narrow, error := set_options(op, args[2:], allocator)
	if error.reply.kind == .Error {
		return {}, error
	}
	path_string := args[0]
	if root == nil && condition == .XX {
		return {}, {}
	}
	if root == nil && path_string != "." && path_string != "$" {
		return {}, type_error(ROOT_REQUIRED)
	}
	path, path_err := compile_path(path_string, allocator)
	if path_err != {} {
		return {}, type_error(path_error_text(path_err, allocator))
	}
	if error := validate_set(root, path); error != "" {
		return {}, type_error(error)
	}
	value, parse_error := parse_with_float_format(args[1], narrow, allocator)
	if parse_error != {} {
		return {}, type_error(format_parse_error(parse_error, false, allocator))
	}
	return {path, value, condition}, {}
}

apply_set :: proc(doc: ^Document, request: Set_Request, merge: bool, allocator: mem.Allocator) -> Outcome {
	if request.value == nil {
		return {}
	}
	return set_value(doc, request.path, request.value, request.condition, merge, allocator)
}

execute :: proc(doc: ^Document, op: Operation, args: []string, protocol: int, allocator: mem.Allocator, wrong_type := false) -> Outcome {
	if op == .Debug_Help {
		items, err := reply_list(2, allocator)
		if err != "" {
			return type_error(err)
		}
		items[0] = reply_string("MEMORY <key> [path] - reports memory usage")
		items[1] = reply_string("HELP                - this message")
		return {reply_array(items), false}
	}
	if wrong_type {
		return type_error(wrong_key_type) if op != .Mget else Outcome{}
	}
	if op == .Get {
		return {get_arguments(doc.root, args, protocol, allocator), false}
	}
	if op == .Set || op == .Merge {
		request, status := prepare_set(doc.root, op, args, allocator)
		if status.reply.kind == .Error {
			return status
		}
		return apply_set(doc, request, op == .Merge, allocator)
	}
	if op == .Mget {
		if len(args) == 0 {
			return arity_error(op, allocator)
		}
		return {read_mget(doc.root, args[0], allocator), false}
	}

	path_source := "."
	if len(args) > 0 {
		path_source = args[0]
	}
	if !valid_arity(op, len(args)) {
		return arity_error(op, allocator)
	}
	if op == .Str_Append && len(args) == 1 {
		path_source = "."
	}
	if doc.root == nil {
		return missing_key_result(op, path_source, protocol, allocator)
	}
	path, path_err := compile_path(path_source, allocator)
	if path_err != {} {
		return invalid_path_result(op, path_err, protocol, allocator)
	}
	if op != .Resp && path.expr.kind != .Selector {
		return type_error(PROJECTION_ERROR)
	}
	request := Request{op = op, path = path, protocol = protocol}
	if error := request_arguments(&request, args, allocator); error != "" {
		return type_error(error)
	}
	result, err := select_path(doc.root, path, allocator)
	if err != "" {
		return type_error(err)
	}
	#partial switch op {
	case .Type:
		return {read_type(result, path.legacy, protocol, allocator), false}
	case .Resp:
		return {read_resp(result, path.legacy, allocator), false}
	case .Clear:
		return clear_values(doc, result.matches[:], allocator)
	case .Del, .Forget:
		steps := path.expr.steps
		shifting := len(steps) != 0 && steps[len(steps)-1].kind == .Indexes
		return delete_values(doc, result.matches[:], shifting, allocator)
	case:
		return apply_matches(doc, request, result.matches[:], allocator)
	}
}

valid_arity :: proc(op: Operation, count: int) -> bool {
	#partial switch op {
	case .Num_Incr, .Num_Mult, .Num_Pow:
		return count == 2
	case .Toggle:
		return count == 1
	case .Clear:
		return count <= 1
	case .Str_Append:
		return count >= 1
	case .Arr_Append:
		return count >= 2
	case .Arr_Insert:
		return count >= 3
	case .Arr_Trim:
		return count == 3
	case .Arr_Index:
		return 2 <= count && count <= 4
	case:
		return true
	}
}

get_arguments :: proc(root: ^Value, args: []string, protocol: int, allocator: mem.Allocator) -> Reply {
	paths: [dynamic]string
	paths.allocator = allocator
	defer delete(paths)
	format: Format
	mode: Get_Mode
	for i := 0; i < len(args); i += 1 {
		token := args[i]
		switch {
		case ascii_equal(token, "INDENT"), ascii_equal(token, "NEWLINE"), ascii_equal(token, "SPACE"):
			i += 1
			if i == len(args) {
				return arity_error(.Get, allocator).reply
			}
			switch {
			case ascii_equal(token, "INDENT"): format.indent = args[i]
			case ascii_equal(token, "NEWLINE"): format.newline = args[i]
			case: format.space = args[i]
			}
		case ascii_equal(token, "NOESCAPE"):
		case ascii_equal(token, "FORMAT"):
			i += 1
			if i == len(args) {
				return arity_error(.Get, allocator).reply
			}
			if protocol == 3 || len(paths) == 0 {
				if protocol != 3 {
					return reply_error("ERR FORMAT argument is not supported on RESP2")
				}
				switch args[i] {
				case "STRING": mode = .String
				case "EXPAND1": mode = .Expand1
				case "EXPAND": mode = .Expand
				case: return reply_error("ERR wrong reply format")
				}
			}
		case:
			if len(paths) >= MAX_PATH_STEPS {
				return reply_error(SIZE_LIMIT)
			}
			if _, err := append(&paths, token); err != nil {
				return reply_error(OUT_OF_MEMORY)
			}
		}
	}
	return read_get(root, paths[:], mode, format, allocator)
}

missing_key_result :: proc(op: Operation, text: string, protocol: int, allocator: mem.Allocator) -> Outcome {
	legacy := len(text) == 0 || text[0] != '$'
	#partial switch op {
	case .Type:
		if protocol == 3 {
			return {reply_wrap({}, allocator), false}
		}
	case .Resp:
	case .Debug_Memory, .Del, .Forget:
		return {reply_integer(0), false}
	case .Arr_Index:
		return type_error(PATH_MISSING)
	case .Arr_Len, .Str_Len, .Obj_Len, .Obj_Keys:
		if !legacy {
			return type_error(NOT_OBJECT if op == .Obj_Len else MISSING_KEY)
		}
	case:
		return type_error(MISSING_KEY)
	}
	return {}
}

invalid_path_result :: proc(op: Operation, err: Path_Error, protocol: int, allocator: mem.Allocator) -> Outcome {
	if err.message == OUT_OF_MEMORY || err.message == SIZE_LIMIT || err.message == DEPTH_LIMIT {
		return type_error(err.message)
	}
	#partial switch op {
	case .Type:
		return missing_key_result(.Type, ".", protocol, allocator)
	case .Del, .Forget:
		return type_error(path_error_text(err, allocator))
	case:
		return type_error(path_error_text(err, allocator))
	}
}

request_arguments :: proc(r: ^Request, args: []string, allocator: mem.Allocator) -> string {
	ok: bool
	#partial switch r.op {
	case .Str_Append, .Num_Incr, .Num_Mult, .Num_Pow, .Arr_Index:
		arg := args[0] if len(args) == 1 else args[1]
		value, err := parse(arg, allocator)
		if err != {} {
			return format_parse_error(err, true, allocator)
		}
		r.argument = value
		if r.op == .Str_Append {
			if _, is_string := value.data.(string); !is_string {
				return WRONG_STRING
			}
		} else if r.op == .Arr_Index {
			if len(args) >= 3 {
				r.index, ok = integer_argument(args[2])
				if !ok {
					return parse_integer_error
				}
			}
			if len(args) >= 4 {
				r.stop, ok = integer_argument(args[3])
				if !ok {
					return parse_integer_error
				}
			}
		} else if _, is_number := number(value); !is_number {
			return "bad input number"
		}
	case .Arr_Append, .Arr_Insert:
		position := 1
		if r.op == .Arr_Insert {
			r.index, ok = integer_argument(args[1])
			if !ok {
				return parse_integer_error
			}
			position = 2
		}
		if len(args) - position > MAX_ITEMS {
			return SIZE_LIMIT
		}
		values, err := make([]^Value, len(args)-position, allocator)
		if err != nil {
			return OUT_OF_MEMORY
		}
		r.values = values
		for arg, i in args[position:] {
			value, error := parse(arg, allocator)
			if error != {} {
				return format_parse_error(error, false, allocator)
			}
			r.values[i] = value
		}
	case .Arr_Pop:
		r.index = -1
		if len(args) >= 2 {
			if v, integer := integer_argument(args[1]); integer {
				r.index = v
			}
		}
	case .Arr_Trim:
		r.index, ok = integer_argument(args[1])
		if !ok {
			return parse_integer_error
		}
		r.stop, ok = integer_argument(args[2])
		if !ok {
			return parse_integer_error
		}
	case:
	}
	return ""
}

apply_matches :: proc(doc: ^Document, request: Request, matches: []Match, allocator: mem.Allocator) -> Outcome {
	op := request.op
	legacy := request.path.legacy && !(request.protocol == 3 && number_operation(op))
	if len(matches) == 0 && legacy {
		text := match_error(op, true)
		if text == "" {
			return {}
		}
		return type_error(text)
	}
	list, err := reply_list(len(matches), allocator)
	if err != "" {
		return type_error(err)
	}
	retirement: Retirement
	retirement_init(&retirement, allocator)
	defer retirement_finish(&retirement, doc.allocator)
	write := writes_matches(op)
	changed, found := false, false
	last := Reply{}
	for match, i in matches {
		if !attached(match.value) {
			return type_error(PATH_MISSING, changed)
		}
		result, match_exists := apply_match(doc, request, match.value, &retirement, allocator)
		if result.reply.kind == .Error {
			return type_error(result.reply.text, changed || result.changed)
		}
		changed = changed || result.changed
		list[i] = result.reply
		if match_exists {
			last = result.reply
			found = true
			if legacy && !write {
				return result
			}
		} else if legacy && !write {
			return type_error(match_error(op, false))
		}
	}
	if legacy && !found {
		return type_error(match_error(op, false))
	}
	if number_operation(op) {
		if request.protocol == 3 {
			return {reply_array(list), changed}
		}
		return {numeric_text(last, list, legacy, allocator), changed}
	}
	return {last if legacy else reply_array(list), changed}
}

writes_matches :: proc(op: Operation) -> bool {
	#partial switch op {
	case .Str_Append, .Arr_Append, .Arr_Insert, .Arr_Pop, .Arr_Trim, .Num_Incr, .Num_Mult, .Num_Pow, .Toggle:
		return true
	case:
		return false
	}
}

match_error :: proc(op: Operation, missing: bool) -> string {
	#partial switch op {
	case .Str_Append: return NOT_STRING
	case .Str_Len: return PATH_MISSING if missing else WRONG_STRING
	case .Arr_Len: return PATH_MISSING if missing else NOT_ARRAY
	case .Arr_Index: return PATH_MISSING if missing else WRONG_ARRAY
	case .Arr_Pop, .Arr_Trim, .Arr_Insert, .Arr_Append: return NOT_ARRAY
	case .Obj_Len: return "" if missing else WRONG_OBJECT
	case .Obj_Keys: return "" if missing else NOT_OBJECT
	case .Toggle: return NOT_BOOL
	case .Debug_Memory: return PATH_MISSING
	case .Num_Incr, .Num_Mult, .Num_Pow: return NOT_NUMBER
	case: return PATH_MISSING
	}
}

apply_match :: proc(doc: ^Document, r: Request, value: ^Value, retirement: ^Retirement, allocator: mem.Allocator) -> (Outcome, bool) {
	#partial switch r.op {
	case .Str_Len, .Str_Append:
		text, string_value := value.data.(string)
		if !string_value {
			return {}, false
		}
		if r.op == .Str_Len {
			return {reply_integer(i64(len(text))), false}, true
		}
		tail := r.argument.data.(string)
		next, err := concat_text(text, tail, doc.allocator)
		if err != "" {
			return type_error(err), false
		}
		free_text(text, doc.allocator)
		set_scalar(value, next)
		return {reply_integer(i64(len(next))), true}, true
	case .Arr_Len, .Arr_Append, .Arr_Insert, .Arr_Index, .Arr_Pop, .Arr_Trim:
		a := as_array(value)
		if a == nil {
			return {}, false
		}
		return apply_array(doc, r, value, a, retirement, allocator), true
	case .Obj_Len, .Obj_Keys:
		o := as_object(value)
		if o == nil {
			return {}, false
		}
		if r.op == .Obj_Len {
			return {reply_integer(i64(len(o.members))), false}, true
		}
		list, err := reply_list(len(o.members), allocator)
		if err != "" {
			return type_error(err), false
		}
		for member, i in o.members {
			list[i] = reply_string(member.name)
		}
		return {reply_array(list), false}, true
	case .Num_Incr, .Num_Mult, .Num_Pow:
		moved, err := update_number(value, r.argument, r.op)
		if err != "" {
			return type_error(err), false
		}
		if !moved {
			return {}, false
		}
		return {number_reply(value), true}, true
	case .Toggle:
		b, ok := value.data.(bool)
		if !ok {
			return {}, false
		}
		set_scalar(value, !b)
		if r.path.legacy {
			return {reply_string("false" if b else "true"), true}, true
		}
		return {reply_integer(i64(!b)), true}, true
	case .Debug_Memory:
		return {reply_integer(i64(charge(value))), false}, true
	case:
		return {}, false
	}
}

apply_array :: proc(doc: ^Document, r: Request, value: ^Value, a: ^Array, retirement: ^Retirement, allocator: mem.Allocator) -> Outcome {
	n := len(a.items)
	#partial switch r.op {
	case .Arr_Len:
		return {reply_integer(i64(n)), false}
	case .Arr_Append, .Arr_Insert:
		pos := n
		if r.op == .Arr_Insert {
			if r.index < -i64(n) || i64(n) < r.index {
				return type_error("ERR index out of bounds")
			}
			pos = relative_index(r.index, n)
		}
		if err := array_insert(value, a, pos, r.values, doc.allocator, allocator); err != "" {
			return type_error(err)
		}
		return {reply_integer(i64(len(a.items))), true}
	case .Arr_Index:
		start := relative_index(r.index, n)
		stop := n if r.stop == 0 else relative_index(r.stop, n)
		for i := start; i < stop; i += 1 {
			if value_equal(a.items[i], r.argument) {
				return {reply_integer(i64(i)), false}
			}
		}
		return {reply_integer(-1), false}
	case .Arr_Pop:
		if n == 0 {
			return {}
		}
		pos := min(n-1, relative_index(r.index, n))
		text, err := serialize(a.items[pos], {}, allocator)
		if err != "" {
			return type_error(err)
		}
		if error := retirement_room(retirement, 1); error != "" {
			return type_error(error)
		}
		retire_value(retirement, array_remove(value, pos))
		return {reply_string(text), true}
	case .Arr_Trim:
		if err := array_trim(value, a, r.index, r.stop, retirement); err != "" {
			return type_error(err)
		}
		return {reply_integer(i64(len(a.items))), true}
	case:
		return {}
	}
}

numeric_text :: proc(last: Reply, list: []Reply, legacy: bool, allocator: mem.Allocator) -> Reply {
	b: Buffer
	buffer_init(&b, allocator)
	defer delete(b.bytes)
	if legacy {
		write_numeric_result(&b, last)
	} else {
		buffer_byte(&b, '[')
		for item, pos in list {
			if pos > 0 {
				buffer_byte(&b, ',')
			}
			write_numeric_result(&b, item)
		}
		buffer_byte(&b, ']')
	}
	if b.error != "" {
		return reply_error(b.error)
	}
	s, ok := copy_text(string(b.bytes[:]), allocator)
	return reply_string(s) if ok else reply_error(OUT_OF_MEMORY)
}

write_numeric_result :: proc(b: ^Buffer, value: Reply) {
	#partial switch value.kind {
	case .Integer:
		buffer_integer(b, value.integer)
	case .Double:
		tmp: [64]u8
		buffer_add(b, json_double(tmp[:], value.double))
	case:
		buffer_add(b, "null")
	}
}


number_operation :: proc(op: Operation) -> bool {
	return op == .Num_Incr || op == .Num_Mult || op == .Num_Pow
}

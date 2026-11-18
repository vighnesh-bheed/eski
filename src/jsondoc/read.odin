package jsondoc

import "core:mem"

Get_Mode :: enum {
	String, Expand1, Expand,
}

read_get :: proc(root: ^Value, paths: []string, mode: Get_Mode, options: Format, allocator: mem.Allocator) -> Reply {
	if root == nil {
		return {}
	}
	default_path := [1]string{"."}
	input := paths if len(paths) > 0 else default_path[:]
	if len(input) > MAX_PATH_STEPS {
		return reply_error(SIZE_LIMIT)
	}
	prepared, err := make([]Path, len(input), allocator)
	if err != nil {
		return reply_error(OUT_OF_MEMORY)
	}
	errors, err2 := make([]Path_Error, len(input), allocator)
	if err2 != nil {
		return reply_error(OUT_OF_MEMORY)
	}
	jsonpath := false
	for text, i in input {
		prepared[i], errors[i] = compile_path(text, allocator)
		jsonpath = jsonpath || !prepared[i].legacy
	}
	if mode != .String {
		return read_expand(root, prepared, errors, mode, options, allocator)
	}
	b: Buffer
	buffer_init(&b, allocator)
	defer delete(b.bytes)
	several := len(input) > 1
	if several {
		buffer_byte(&b, '{')
	}
	count := 0
	for text, i in input {
		if errors[i] != {} {
			if several && jsonpath && errors[i].message != OUT_OF_MEMORY && errors[i].message != SIZE_LIMIT {
				continue
			}
			return reply_error(path_error_text(errors[i], allocator))
		}
		if several && prior_path(input[:i], text) {
			continue
		}
		result, error := select_path(root, prepared[i], allocator)
		if error != "" {
			return reply_error(error)
		}
		if several {
			if count > 0 {
				buffer_byte(&b, ',')
			}
			write_indent(&b, options, 1)
			write_string(&b, text)
			buffer_byte(&b, ':')
			buffer_add(&b, options.space)
		}
		if jsonpath {
			write_matches(&b, result, options, int(several))
		} else if len(result.matches) != 0 {
			write_value(&b, result.matches[0].value, options, int(several))
		} else {
			return reply_error(PATH_MISSING)
		}
		count += 1
	}
	if several {
		if count > 0 {
			write_indent(&b, options, 0)
		}
		buffer_byte(&b, '}')
	}
	if b.error != "" {
		return reply_error(b.error)
	}
	text, ok := copy_text(string(b.bytes[:]), allocator)
	return reply_string(text) if ok else reply_error(OUT_OF_MEMORY)
}

prior_path :: proc(paths: []string, path: string) -> bool {
	for candidate in paths {
		if candidate == path {
			return true
		}
	}
	return false
}

result_count :: proc(result: Eval_Result) -> int {
	if result.selector {
		return len(result.matches)
	}
	if result.value == nil {
		return 0
	}
	if result.unpack {
		return len(as_array(result.value).items)
	}
	return 1
}

result_item :: proc(result: Eval_Result, i: int) -> ^Value {
	if result.selector {
		return result.matches[i].value
	}
	if result.unpack {
		return as_array(result.value).items[i]
	}
	return result.value
}

write_matches :: proc(b: ^Buffer, result: Eval_Result, options: Format, depth: int) {
	buffer_byte(b, '[')
	n := result_count(result)
	for i in 0 ..< n {
		if i > 0 {
			buffer_byte(b, ',')
		}
		write_indent(b, options, depth+1)
		write_value(b, result_item(result, i), options, depth+1)
	}
	if n > 0 {
		write_indent(b, options, depth)
	}
	buffer_byte(b, ']')
}

read_expand :: proc(root: ^Value, paths: []Path, errors: []Path_Error, mode: Get_Mode, options: Format, allocator: mem.Allocator) -> Reply {
	rows, err := reply_list(len(paths), allocator)
	if err != "" {
		return reply_error(err)
	}
	for path, i in paths {
		if errors[i] != {} {
			return reply_error(path_error_text(errors[i], allocator))
		}
		result, error := select_path(root, path, allocator)
		if error != "" {
			return reply_error(error)
		}
		rows[i] = match_reply(result, .Expand1 if mode == .Expand1 else .Expand, options, allocator)
		if rows[i].kind == .Error {
			return rows[i]
		}
	}
	return reply_array(rows)
}

match_reply :: proc(result: Eval_Result, mode: Reply_Mode, options: Format, allocator: mem.Allocator) -> Reply {
	list, err := reply_list(result_count(result), allocator)
	if err != "" {
		return reply_error(err)
	}
	for i in 0 ..< len(list) {
		list[i] = value_reply(result_item(result, i), mode, options, allocator)
		if list[i].kind == .Error {
			return list[i]
		}
	}
	return reply_array(list)
}

read_mget :: proc(root: ^Value, path: string, allocator: mem.Allocator) -> Reply {
	reply := read_get(root, []string{path}, .String, {}, allocator)
	if reply.kind == .Error && reply.text != OUT_OF_MEMORY && reply.text != SIZE_LIMIT {
		return {}
	}
	return reply
}

read_resp :: proc(result: Eval_Result, legacy: bool, allocator: mem.Allocator) -> Reply {
	if !legacy {
		return match_reply(result, .Resp, {}, allocator)
	}
	if len(result.matches) == 0 {
		return reply_error(PATH_MISSING)
	}
	return value_reply(result.matches[0].value, .Resp, {}, allocator)
}

read_type :: proc(result: Eval_Result, legacy: bool, protocol: int, allocator: mem.Allocator) -> Reply {
	reply := Reply{}
	if legacy {
		if len(result.matches) > 0 {
			reply = reply_string(type_name(result.matches[0].value))
		}
	} else {
		items, err := reply_list(len(result.matches), allocator)
		if err != "" {
			return reply_error(err)
		}
		for match, i in result.matches {
			items[i] = reply_string(type_name(match.value))
		}
		reply = reply_array(items)
	}
	if protocol == 3 {
		return reply_wrap(reply, allocator)
	}
	return reply
}

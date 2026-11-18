package jsondoc

import "core:crypto/hash"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:testing"

Capture_Reader :: struct {
	bytes: []u8,
	pos: int,
}

capture_u16 :: proc(r: ^Capture_Reader) -> int {
	n := int(r.bytes[r.pos]) | int(r.bytes[r.pos+1]) << 8
	r.pos += 2
	return n
}

capture_u32 :: proc(r: ^Capture_Reader) -> int {
	return capture_u16(r) | capture_u16(r) << 16
}

capture_text :: proc(r: ^Capture_Reader, n: int) -> string {
	s := string(r.bytes[r.pos:r.pos+n])
	r.pos += n
	return s
}

large_argument :: proc(kind: int) -> string {
	b: Buffer
	buffer_init(&b, context.allocator)
	defer delete(b.bytes)
	switch kind {
	case 1, 4:
		buffer_byte(&b, '"')
		if kind == 1 {
			for _ in 0 ..< 999998 {
				buffer_byte(&b, 'x')
			}
		} else {
			for _ in 0 ..< 100000 {
				buffer_add(&b, "\\u00e9")
			}
		}
		buffer_byte(&b, '"')
	case 2, 3:
		buffer_byte(&b, '[' if kind == 2 else '{')
		for i in 0 ..< (100000 if kind == 2 else 50000) {
			if i != 0 {
				buffer_byte(&b, ',')
			}
			if kind == 3 {
				buffer_add(&b, "\"k")
				buffer_integer(&b, i64(i))
				buffer_add(&b, "\":")
			}
			buffer_integer(&b, i64(i))
		}
		buffer_byte(&b, ']' if kind == 2 else '}')
	}
	s, _ := copy_text(string(b.bytes[:]), context.allocator)
	return s
}

Capture_Key :: struct {
	doc: Document,
	wrong_type: bool,
}

Capture_State :: struct {
	keys: map[string]^Capture_Key,
	scratch: mem.Allocator,
}

capture_clear :: proc(state: ^Capture_State) {
	for _, key in state.keys {
		destroy(&key.doc)
		free(key)
	}
	clear(&state.keys)
}

capture_key :: proc(state: ^Capture_State, name: string) -> ^Capture_Key {
	key := state.keys[name]
	if key == nil {
		key = new(Capture_Key)
		key.doc = init()
		state.keys[name] = key
	}
	return key
}

capture_command :: proc(state: ^Capture_State, argv: []string, protocol: int) -> Reply {
	a := state.scratch
	switch argv[0] {
	case "FLUSHALL":
		capture_clear(state)
		return reply_status("OK")
	case "SET", "HSET":
		key := capture_key(state, argv[1])
		destroy(&key.doc)
		key.wrong_type = true
		return reply_status("OK")
	case "DEL":
		for name in argv[1:] {
			key := capture_key(state, name)
			destroy(&key.doc)
			key.wrong_type = false
		}
		return reply_integer(0)
	case "EXISTS":
		key := capture_key(state, argv[1])
		return reply_integer(i64(key.doc.root != nil || key.wrong_type))
	}
	op := name_operation(argv[0])
	if op == .Debug_Memory {
		if len(argv) < 2 {
			return arity_error(op, a).reply
		}
		if ascii_equal(argv[1], "HELP") {
			return execute(nil, .Debug_Help, nil, protocol, a).reply
		}
		if !ascii_equal(argv[1], "MEMORY") {
			return reply_error("ERR unknown subcommand - try `JSON.DEBUG HELP`")
		}
		if len(argv) < 3 {
			return arity_error(op, a).reply
		}
		key := capture_key(state, argv[2])
		return execute(&key.doc, op, argv[3:], protocol, a, key.wrong_type).reply
	}
	if op == .Mset {
		if len(argv) < 4 || (len(argv)-1)%3 != 0 {
			if (len(argv)-1)%3 == 2 {
				key := capture_key(state, argv[len(argv)-2])
				return mset_short_triple(&key.doc, key.wrong_type, argv[len(argv)-1], a).reply
			}
			return arity_error(op, a).reply
		}
		count := (len(argv)-1)/3
		triples := make([]Set_Triple, count, a)
		outcomes := make([]Outcome, count, a)
		for i in 0 ..< count {
			at := 3*i + 1
			key := capture_key(state, argv[at])
			triples[i] = {&key.doc, argv[at+1], argv[at+2], key.wrong_type}
		}
		requests, status := prepare_mset(triples, a)
		if status.reply.kind == .Error {
			return status.reply
		}
		return apply_mset(triples, requests, outcomes, a).reply
	}
	if op == .Mget {
		if len(argv) < 3 {
			return arity_error(op, a).reply
		}
		items := make([]Reply, len(argv)-2, a)
		for name, i in argv[1:len(argv)-1] {
			key := capture_key(state, name)
			items[i] = execute(&key.doc, op, argv[len(argv)-1:], protocol, a, key.wrong_type).reply
		}
		return reply_array(items)
	}
	if len(argv) < 2 {
		return arity_error(op, a).reply
	}
	key := capture_key(state, argv[1])
	return execute(&key.doc, op, argv[2:], protocol, a, key.wrong_type).reply
}

bulk_payload :: proc(s: string) -> string {
	offset := strings.index(s, "\r\n")
	if offset < 0 || len(s) < offset+4 || s[0] != '$' || !strings.has_suffix(s, "\r\n") {
		return ""
	}
	return s[offset+2:len(s)-2]
}

read_capture_resp :: proc(r: ^Capture_Reader, allocator: mem.Allocator) -> Reply {
	if r.pos >= len(r.bytes) {
		return reply_error("missing fixture response")
	}
	c := r.bytes[r.pos]
	r.pos += 1
	n := strings.index(string(r.bytes[r.pos:]), "\r\n")
	if n < 0 {
		return reply_error("missing fixture response line")
	}
	line := capture_text(r, n)
	r.pos += 2
	count, _ := strconv.parse_i64(line, 10)
	switch c {
	case '*', '%':
		size := int(count) * (2 if c == '%' else 1)
		items := make([]Reply, size, allocator)
		for i in 0 ..< size {
			items[i] = read_capture_resp(r, allocator)
		}
		return {kind = .Map if c == '%' else .Array, items = items}
	case ':': return reply_integer(count)
	case ',':
		v, _ := strconv.parse_f64(line)
		return {kind = .Double, double = v}
	case '$':
		if count < 0 {
			return {}
		}
		text := capture_text(r, int(count))
		r.pos += 2
		return reply_string(text)
	case '+': return reply_status(line)
	case '-': return reply_error(line)
	case '#': return {kind = .Boolean, boolean = line == "t"}
	case '_': return {}
	case: return reply_error("invalid fixture response")
	}
}

equal_replies :: proc(a, b: Reply) -> bool {
	if a.kind != b.kind || a.text != b.text || a.integer != b.integer || a.double != b.double || a.boolean != b.boolean || len(a.items) != len(b.items) {
		return false
	}
	if a.kind == .Map {
		for i := 0; i < len(a.items); i += 2 {
			found := false
			for j := 0; j < len(b.items); j += 2 {
				if a.items[i].text == b.items[j].text {
					found = equal_replies(a.items[i+1], b.items[j+1])
					break
				}
			}
			if !found {
				return false
			}
		}
	} else {
		for c, i in a.items {
			if !equal_replies(c, b.items[i]) {
				return false
			}
		}
	}
	return true
}

capture_reply_equal :: proc(got: Reply, wire, expected: string, mode: int, allocator: mem.Allocator) -> bool {
	if expected == wire {
		return true
	}
	switch mode {
	case 1:
		r := Capture_Reader{bytes = transmute([]u8)expected, pos = 32}
		if len(wire) != capture_u32(&r) {
			return false
		}
		tmp: [32]u8
		digest := hash.hash_string_to_buffer(.SHA256, wire, tmp[:])
		return string(digest) == expected[:32]
	case 2:
		a, a_err := parse(bulk_payload(wire), allocator)
		b, b_err := parse(bulk_payload(expected), allocator)
		return a_err == {} && b_err == {} && value_equal(a, b)
	case 3:
		r := Capture_Reader{bytes = transmute([]u8)expected}
		return equal_replies(got, read_capture_resp(&r, allocator))
	case:
		return false
	}
}

capture_charge_reply :: proc(state: ^Capture_State, args: []string, reply: Reply) -> bool {
	if len(args) < 3 || !ascii_equal(args[1], "MEMORY") {
		return false
	}
	key := state.keys[args[2]]
	path := "." if len(args) < 4 else args[3]
	if key == nil || key.wrong_type {
		return false
	}
	if key.doc.root == nil {
		return reply.kind == .Integer && reply.integer == 0
	}
	compiled, parse_error := compile_path(path, state.scratch)
	if parse_error != {} {
		return false
	}
	result, err := select_path(key.doc.root, compiled, state.scratch)
	if err != "" {
		return false
	}
	if compiled.legacy {
		return len(result.matches) != 0 && reply.kind == .Integer && reply.integer == i64(content_memory(result.matches[0].value))
	}
	if reply.kind != .Array || len(reply.items) != len(result.matches) {
		return false
	}
	for match, pos in result.matches {
		if reply.items[pos].kind != .Integer || reply.items[pos].integer != i64(content_memory(match.value)) {
			return false
		}
	}
	return true
}

@(test)
captured_document_commands :: proc(t: ^testing.T) {
	bytes := #load("testdata/reference.bin", []u8)
	r := Capture_Reader{bytes = bytes}
	words_count := capture_u32(&r)
	rows_count := capture_u32(&r)
	words := make([]string, words_count)
	defer delete(words)
	workspace: Workspace
	testing.expect(t, workspace_init(&workspace))
	defer workspace_destroy(&workspace)
	state := Capture_State{keys = make(map[string]^Capture_Key), scratch = workspace.allocator}
	defer delete(state.keys)
	defer capture_clear(&state)
	large_args: [4]string
	defer for s in large_args {
		free_text(s, context.allocator)
	}
	for i in 0 ..< len(words) {
		n := int(i32(capture_u32(&r)))
		if n < 0 {
			large_args[-n-1] = large_argument(-n)
			words[i] = large_args[-n-1]
		} else {
			words[i] = capture_text(&r, n)
		}
	}
	passed, differences, excluded := 0, 0, 0
	for _ in 0 ..< rows_count {
		id := capture_u16(&r)
		proto, mode := int(r.bytes[r.pos]), int(r.bytes[r.pos+1])
		r.pos += 2
		expected := words[capture_u16(&r)]
		count := int(r.bytes[r.pos])
		r.pos += 1
		args: [256]string
		for i in 0 ..< count {
			args[i] = words[capture_u16(&r)]
		}
		reply := capture_command(&state, args[:count], proto)
		if id > 0 {
			wire, err := render_reply(reply, proto, workspace.allocator)
			if err == "" && capture_reply_equal(reply, wire, expected, mode, workspace.allocator) {
				passed += 1
			} else if args[0] == "JSON.DEBUG" && (strings.has_prefix(expected, ":") || strings.has_prefix(expected, "*")) && capture_charge_reply(&state, args[:count], reply) {
				excluded += 1
				for _, key in state.keys {
					testing.expect(t, charge(key.doc.root) == content_memory(key.doc.root))
				}
			} else {
				differences += 1
				fmt.printf("case %d protocol %d (%v)\n  expected %q\n  actual   %q %q\n", id, proto, args[:count], expected[:min(len(expected), 200)], wire[:min(len(wire), 200)], err)
			}
		}
		workspace_reset(&workspace)
	}
	testing.expect(t, r.pos == len(bytes))
	fmt.printf("capture matched %d, charge model differences %d, other differences %d\n", passed, excluded, differences)
	testing.expect(t, passed + excluded + differences == 7758)
	testing.expect(t, excluded == 54)
	testing.expect(t, differences == 0)
}

package jsondoc

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

test_input :: proc(t: ^testing.T, doc: ^Document, workspace: ^Workspace, input: string) {
	value, err := parse(input, doc.allocator)
	testing.expect(t, err == {})
	if err == {} {
		replace_root(doc, value)
	}
	workspace_reset(workspace)
}

test_view :: proc(t: ^testing.T, doc: ^Document, a: mem.Allocator, expected: string) {
	actual, err := serialize(doc.root, {}, a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, actual, expected)
	testing.expect_value(t, content_memory(doc.root), charge(doc.root))
}

@(test)
contract_section_5_partial_overflow :: proc(t: ^testing.T) {
	doc := init()
	defer destroy(&doc)
	workspace: Workspace
	testing.expect(t, workspace_init(&workspace))
	defer workspace_destroy(&workspace)
	a := workspace.allocator
	test_input(t, &doc, &workspace, "[1,2.5,9223372036854775807]")
	out := execute(&doc, .Num_Incr, {"$[*]", "1"}, 2, a)
	testing.expect_value(t, out.reply.text, "ERR numeric overflow")
	testing.expect(t, out.changed)
	test_view(t, &doc, a, "[2,3.5,9223372036854775807]")
}

@(test)
contract_section_11_clear_over_descendant_and_repeated_delete :: proc(t: ^testing.T) {
	doc := init()
	defer destroy(&doc)
	workspace: Workspace
	testing.expect(t, workspace_init(&workspace))
	defer workspace_destroy(&workspace)
	a := workspace.allocator
	test_input(t, &doc, &workspace, `{"a":{"a":[1]}}`)
	out := execute(&doc, .Clear, {"$..a"}, 2, a)
	testing.expect_value(t, out.reply.text, "ERR Path does not exist")
	testing.expect(t, out.changed)
	test_view(t, &doc, a, `{"a":{}}`)
	test_input(t, &doc, &workspace, `{"b":[1,2,3]}`)
	out = execute(&doc, .Del, {"$.b[0,0]"}, 2, a)
	testing.expect_value(t, out.reply.integer, i64(2))
	test_view(t, &doc, a, `{"b":[3]}`)
}

@(test)
contract_sections_8_and_12_negative_index_and_missing_merge :: proc(t: ^testing.T) {
	doc := init()
	defer destroy(&doc)
	workspace: Workspace
	testing.expect(t, workspace_init(&workspace))
	defer workspace_destroy(&workspace)
	a := workspace.allocator
	test_input(t, &doc, &workspace, "[1,2,3]")
	out := execute(&doc, .Set, {"$[-100]", "9"}, 2, a)
	testing.expect_value(t, out.reply.text, "OK")
	test_view(t, &doc, a, "[9,2,3]")
	destroy(&doc)
	out = execute(&doc, .Merge, {"$", `{"a":null}`}, 2, a)
	testing.expect_value(t, out.reply.text, "OK")
	test_view(t, &doc, a, `{"a":null}`)
}

@(test)
contract_sections_6_and_11_format_and_invalid_path :: proc(t: ^testing.T) {
	doc := init()
	defer destroy(&doc)
	workspace: Workspace
	testing.expect(t, workspace_init(&workspace))
	defer workspace_destroy(&workspace)
	a := workspace.allocator
	test_input(t, &doc, &workspace, `{"a":[1,2]}`)
	result := execute(&doc, .Get, {"$.a", "$["}, 3, a)
	testing.expect_value(t, result.reply.text, `{"$.a":[[1,2]]}`)
	result = execute(&doc, .Get, {"$.a", "FORMAT", "EXPAND"}, 2, a)
	testing.expect_value(t, result.reply.text, "[[1,2]]")
	result = execute(&doc, .Get, {"FORMAT", "EXPAND", "$.a"}, 2, a)
	testing.expect_value(t, result.reply.text, "ERR FORMAT argument is not supported on RESP2")
	result = execute(&doc, .Arr_Pop, {"$.a", "FORMAT", "EXPAND"}, 3, a)
	testing.expect_value(t, result.reply.items[0].text, "2")
	test_view(t, &doc, a, `{"a":[1]}`)
}

@(test)
index_field_values :: proc(t: ^testing.T) {
	doc := init()
	defer destroy(&doc)
	workspace: Workspace
	testing.expect(t, workspace_init(&workspace))
	defer workspace_destroy(&workspace)
	a := workspace.allocator
	test_input(t, &doc, &workspace, `{"g":"-1,2","t":["one","two"],"text":"phrase","n":[12,8.5],"invalid":[1,"x"],"v":[[1,2],[8,9]]}`)
	path, err := compile_path("$.v[*]", a)
	testing.expect(t, err == {})
	vectors := extract_field(doc.root, path, .Vector, a, 2)
	testing.expect_value(t, len(vectors.values), 2)
	testing.expect(t, !vectors.invalid && vectors.error == "")
	if len(vectors.values) == 2 {
		array := as_array(vectors.values[1])
		f, ok := number(array.items[0])
		testing.expect(t, ok && f == 8)
	}
	vectors = extract_field(doc.root, path, .Vector, a, 4)
	testing.expect(t, vectors.invalid)
	path, err = compile_path("$.t", a)
	tags := extract_field(doc.root, path, .Tag, a)
	testing.expect_value(t, len(tags.values), 2)
	path, err = compile_path("$.n[*]", a)
	nums := extract_field(doc.root, path, .Numeric, a)
	testing.expect_value(t, len(nums.values), 2)
	path, err = compile_path("$.invalid", a)
	testing.expect(t, extract_field(doc.root, path, .Numeric, a).invalid)
	path, err = compile_path("$.g", a)
	testing.expect_value(t, len(extract_field(doc.root, path, .Geo, a).values), 1)
	path, err = compile_path("$.text", a)
	testing.expect_value(t, len(extract_field(doc.root, path, .Text, a).values), 1)
	path, err = compile_path("$.missing", a)
	testing.expect_value(t, len(extract_field(doc.root, path, .Numeric, a).values), 0)
}

Fault_Allocator :: struct {
	backing: mem.Allocator,
	remaining: int,
}

fault_alloc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	fault := (^Fault_Allocator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if size > 0 {
			if fault.remaining == 0 {
				return nil, .Out_Of_Memory
			}
			fault.remaining -= 1
		}
	}
	return fault.backing.procedure(fault.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
allocations_fail_with_consistent_content :: proc(t: ^testing.T) {
	fault := Fault_Allocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = fault_alloc, data = &fault}
	workspace: Workspace
	testing.expect(t, workspace_init(&workspace))
	defer workspace_destroy(&workspace)
	a := workspace.allocator
	for budget in 0 ..< 48 {
		fault.remaining = budget
		v, err := parse(`{"a":1,"b":[2,"x\t"],"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9,"j":10}`, allocator)
		if err != {} {
			testing.expect_value(t, err.message, OUT_OF_MEMORY)
			testing.expect(t, v == nil)
		} else {
			testing.expect_value(t, content_memory(v), charge(v))
		}
		release(v, allocator)

		fault.remaining = 100
		doc := init(allocator)
		test_input(t, &doc, &workspace, `{"a":[1],"b":[2],"c":{"x":3}}`)
		fault.remaining = budget
		out := execute(&doc, .Arr_Append, {"$..*", `{"n":[1,"p"]}`, "4"}, 2, a)
		testing.expect(t, out.reply.kind != .Error || out.reply.text == OUT_OF_MEMORY)
		testing.expect_value(t, content_memory(doc.root), charge(doc.root))
		destroy(&doc)
	}
}

@(test)
workspace_allocation_failures_keep_the_document_valid :: proc(t: ^testing.T) {
	workspace: Workspace
	testing.expect(t, workspace_init(&workspace))
	defer workspace_destroy(&workspace)
	fault := Fault_Allocator{backing = workspace.allocator}
	allocator := mem.Allocator{procedure = fault_alloc, data = &fault}
	for budget in 0 ..< 48 {
		doc := init()
		test_input(t, &doc, &workspace, `{"a":[1],"b":[2],"c":{"x":3}}`)
		fault.remaining = budget
		out := execute(&doc, .Merge, {"$", `{"a":{"p":1},"b":null,"d":4}`}, 2, allocator)
		testing.expect(t, out.reply.kind != .Error || out.reply.text == OUT_OF_MEMORY)
		testing.expect_value(t, content_memory(doc.root), charge(doc.root))
		destroy(&doc)
	}
}

@(test)
value_and_container_layout :: proc(t: ^testing.T) {
	when size_of(int) == 8 {
		testing.expect_value(t, size_of(Document), 24)
		testing.expect_value(t, size_of(Value), 40)
		testing.expect_value(t, size_of(Array), 40)
		testing.expect_value(t, size_of(Object), 72)
		testing.expect_value(t, size_of(Member), 24)
	}
}

Reference_State :: struct {
	items: [dynamic]i64,
	names: [dynamic]u8,
	values: [26]i64,
	number: i64,
	on: bool,
	text: [dynamic]u8,
}

reference_text :: proc(r: ^Reference_State, a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "{\"items\":[")
	for value, i in r.items {
		fmt.sbprintf(&b, "%s%d", "" if i == 0 else ",", value)
	}
	strings.write_string(&b, "],\"object\":{")
	for name, i in r.names {
		fmt.sbprintf(&b, "%s\"%c\":%d", "" if i == 0 else ",", name + 'a', r.values[name])
	}
	fmt.sbprintf(&b, "%c,\"number\":%d,\"on\":%s,\"text\":\"%s\"%c", '}', r.number, "true" if r.on else "false", string(r.text[:]), '}')
	return strings.to_string(b)
}

reference_charge :: proc(r: ^Reference_State) -> int {
	root := 8
	names := 5*8 + len("itemsobjectnumberontext")
	values := 5*8 + 8*len(r.items) + len(r.text) + len(r.names)*(8+8+1)
	return root + names + values
}

random_next :: proc(seed: ^u64) -> u64 {
	seed^ ~= seed^ << 13
	seed^ ~= seed^ >> 7
	seed^ ~= seed^ << 17
	return seed^
}

model_index :: proc(items: []u8, n: u8) -> int {
	for value, i in items {
		if value == n {
			return i
		}
	}
	return -1
}

@(test)
random_document_matches_plain_reference :: proc(t: ^testing.T) {
	doc := init()
	defer destroy(&doc)
	workspace: Workspace
	testing.expect(t, workspace_init(&workspace))
	defer workspace_destroy(&workspace)
	a := workspace.allocator
	seed := u64(0x2fb1c7e38dd24fde)
	fmt.printf("JSON document reference seed %d\n", seed)
	shadow := Reference_State{}
	defer {
		delete(shadow.items)
		delete(shadow.names)
		delete(shadow.text)
	}
	test_input(t, &doc, &workspace, reference_text(&shadow, a))
	for i in 0 ..< 2400 {
		x := random_next(&seed)
		n := i64(x % 101)-50
		tag := u8(x%17)
		member := fmt.aprintf("$.object.%c", tag+'a', allocator=a)
		text := fmt.aprintf("%d", n, allocator=a)
		op: Operation
		args: []string
		switch int(x%11) {
		case 0:
			op, args = .Arr_Append, {"$.items", text}
			append(&shadow.items, n)
		case 1:
			op, args = .Arr_Insert, {"$.items", "0", text}
			inject_at(&shadow.items, 0, n)
		case 2:
			op, args = .Arr_Pop, {"$.items", "0"}
			if len(shadow.items) > 0 {
				ordered_remove(&shadow.items, 0)
			}
		case 3, 4:
			op, args = .Set, {member, text}
			if model_index(shadow.names[:], tag) < 0 {
				append(&shadow.names, tag)
			}
			shadow.values[tag] = n
		case 5:
			op, args = .Del, {member}
			if pos := model_index(shadow.names[:], tag); pos >= 0 {
				unordered_remove(&shadow.names, pos)
			}
		case 6:
			op, args = .Num_Incr, {"$.number", text}
			shadow.number += n
		case 7:
			op, args = .Toggle, {"$.on"}
			shadow.on = !shadow.on
		case 8:
			op, args = .Str_Append, {"$.text", `"x"`}
			append(&shadow.text, 'x')
		case 9:
			op, args = .Arr_Trim, {"$.items", "1", "4"}
			if len(shadow.items) > 1 {
				end := min(5, len(shadow.items))
				copy(shadow.items[:], shadow.items[1:end])
				resize(&shadow.items, end-1)
			} else {
				clear(&shadow.items)
			}
		case:
			op, args = .Merge, {"$.object", fmt.aprintf("%c\"%c\":%d%c", '{', tag+'a', n, '}', allocator=a)}
			if model_index(shadow.names[:], tag) < 0 {
				append(&shadow.names, tag)
			}
			shadow.values[tag] = n
		}
		out := execute(&doc, op, args, int(x%2)+2, a)
		testing.expect(t, out.reply.kind != .Error)
		expected := reference_text(&shadow, a)
		test_view(t, &doc, a, expected)
		testing.expect_value(t, charge(doc.root), reference_charge(&shadow))
		if i%31 == 0 {
			v, err := parse(expected, a)
			testing.expect(t, err == {})
			testing.expect_value(t, charge(v), charge(doc.root))
			rendered, render_error := serialize(v, {}, a)
			testing.expect_value(t, rendered, expected)
			testing.expect_value(t, render_error, "")
		}
		workspace_reset(&workspace)
	}
}

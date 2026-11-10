package vfilter

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

lookup_name :: proc(attribute: Attribute, name: string) -> (Value, bool) {
	return attribute_lookup(attribute.blob, Field_Ref{name = name, hash = name_hash(name)})
}

@(test)
layout_sizes :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Attribute_Header), 24)
	testing.expect_value(t, size_of(Field_Entry), 32)
	testing.expect_value(t, size_of(Item), 24)
	testing.expect_value(t, size_of(Instruction), 8)
}

@(test)
recorded_attribute_texts :: proc(t: ^testing.T) {
	cases := []struct {
		text:   string,
		object: bool,
		fields: int,
	} {
		{`{"k":1}`, true, 1},
		{`{"h":true}`, true, 1},
		{`{"x":1}`, true, 1},
		{"not json", false, 0},
		{"{}", true, 0},
		{"{bad", true, 0},
		{"notjson", false, 0},
		{"{bad json", true, 0},
		{ATTR_SET_A, true, 6},
		{ATTR_SET_B, true, 3},
		{ATTR_SET_C, true, 2},
	}
	for c in cases {
		attribute, err := attribute_make(c.text)
		defer attribute_destroy(&attribute)
		testing.expect(t, err == nil)
		testing.expectf(t, attribute_is_object(attribute) == c.object, "%q object %v", c.text, attribute_is_object(attribute))
		testing.expectf(t, len(attribute_fields(attribute.blob)) == c.fields, "%q fields %d", c.text, len(attribute_fields(attribute.blob)))
		testing.expect_value(t, attribute_text(attribute), c.text)
		testing.expect(t, attribute_size(attribute) >= len(c.text) + ATTRIBUTE_HEADER_SIZE)
	}
}

@(test)
json_member_kinds :: proc(t: ^testing.T) {
	text := `{"n":2.5,"s":"a\u0062c","t":true,"f":false,"z":null,"o":{"x":1},"arr":[1,"2",true,false,null,[3,[4]],"\u0041"],"e":[],"bad":[1,{"y":4}],"esc":"\n\t\r\b\/\\\"\x"}`
	attribute, _ := attribute_make(text)
	defer attribute_destroy(&attribute)
	n, n_found := lookup_name(attribute, "n")
	testing.expect(t, n_found && n.kind == .Number && n.num == 2.5)
	s, s_found := lookup_name(attribute, "s")
	testing.expect(t, s_found && s.kind == .String && s.str == "au0062c" && s.num == 0)
	tv, t_found := lookup_name(attribute, "t")
	testing.expect(t, t_found && tv.kind == .Number && tv.num == 1)
	fv, f_found := lookup_name(attribute, "f")
	testing.expect(t, f_found && fv.kind == .Number && fv.num == 0)
	z, z_found := lookup_name(attribute, "z")
	testing.expect(t, z_found && z.kind == .Null)
	_, o_found := lookup_name(attribute, "o")
	testing.expect(t, !o_found)
	_, bad_found := lookup_name(attribute, "bad")
	testing.expect(t, !bad_found)
	arr, arr_found := lookup_name(attribute, "arr")
	testing.expect(t, arr_found && arr.kind == .Array && len(arr.items) == 7)
	if len(arr.items) == 7 {
		testing.expect(t, arr.items[0].kind == .Number && arr.items[0].num == 1)
		testing.expect(t, arr.items[1].kind == .String && item_text(arr.items[1], arr.base) == "2" && arr.items[1].num == 2)
		testing.expect(t, arr.items[2].kind == .Number && arr.items[2].num == 1)
		testing.expect(t, arr.items[3].kind == .Number && arr.items[3].num == 0)
		testing.expect(t, arr.items[4].kind == .Null)
		testing.expect(t, arr.items[5].kind == .Array && arr.items[5].num == 0)
		testing.expect(t, arr.items[6].kind == .String && item_text(arr.items[6], arr.base) == "u0041")
	}
	e, e_found := lookup_name(attribute, "e")
	testing.expect(t, e_found && e.kind == .Array && len(e.items) == 0)
	esc, esc_found := lookup_name(attribute, "esc")
	testing.expect(t, esc_found && esc.str == "\n\t\rb/\\\"x")
}

@(test)
json_walk_rules :: proc(t: ^testing.T) {
	cases := []struct {
		text:  string,
		found: bool,
		num:   f64,
	} {
		{`{"k":1}`, true, 1},
		{` {"k":1}`, true, 1},
		{"\x0b{\x0c\"k\"\r:\t1}", true, 1},
		{`{"k":1}x`, true, 1},
		{`{"k":1,}`, true, 1},
		{`{"k":1/*c*/}`, true, 1},
		{`{"k":0x1}`, true, 0},
		{`{"k":01}`, true, 1},
		{`{"k":+1}`, true, 1},
		{`{"k":1.}`, true, 1},
		{`{"k":-.5}`, true, -0.5},
		{`{"k":1x}`, true, 1},
		{`{"k":1 2}`, true, 1},
		{`{"k":true]}`, true, 1},
		{`{"k":.5}`, false, 0},
		{`{"k":-}`, false, 0},
		{`{"k":1e}`, false, 0},
		{`{"k":1-2}`, false, 0},
		{`{"k":true-}`, false, 0},
		{`{"k":true1}`, false, 0},
		{`{"k":NaN}`, false, 0},
		{`{"k":Infinity}`, false, 0},
		{"\xef\xbb\xbf{\"k\":1}", false, 0},
		{"\x00{\"k\":1}", false, 0},
		{`{'k':1}`, false, 0},
		{`{k:1}`, false, 0},
		{`{"K":1}`, false, 0},
		{`{"\u006b":1}`, false, 0},
		{`{"\k":1}`, false, 0},
		{`{"x":"\"k\":5","k":1}`, true, 1},
		{`{"x":{"k":5},"k":1}`, true, 1},
		{`{"x":[1,{"k":5}],"k":1}`, true, 1},
		{`{"x":{"y":[1,"}",{"w":"]"}]},"k":1}`, true, 1},
		{`{"x":[1}],"k":1}`, true, 1},
		{`{"x":[1},"k":1}`, false, 0},
		{`{"x":{"a":[}],"k":1}`, false, 0},
		{`{"x":-,"k":1}`, true, 1},
		{`{"x":.5,"k":1}`, true, 1},
		{`{"x":e,"k":1}`, true, 1},
		{`{"x":1e,"k":1}`, true, 1},
		{`{"x":"\x","k":1}`, true, 1},
		{"{\"x\":\"a\x00\",\"k\":1}", true, 1},
		{`{"x":[1 2],"k":1}`, true, 1},
		{`{"x":tru,"k":1}`, false, 0},
		{`{"x":truex,"k":1}`, false, 0},
		{`{"x":0x1,"k":1}`, false, 0},
		{`{"x":1/*c*/,"k":1}`, false, 0},
		{`{"x":1 "k":1}`, false, 0},
		{`{"x":1,,"k":1}`, false, 0},
		{`{"x" 1,"k":1}`, false, 0},
		{`{"x":"abc,"k":1}`, false, 0},
		{`{"x":1}{"k":1}`, false, 0},
		{`{"k":1,"k":2}`, true, 1},
		{`{"k":null,"k":1}`, true, -1},
		{`{"k":{},"k":1}`, false, 0},
		{`{"\u006b":2,"k":1}`, true, 1},
	}
	for c in cases {
		attribute, _ := attribute_make(c.text)
		defer attribute_destroy(&attribute)
		value, found := lookup_name(attribute, "k")
		if c.num == -1 {
			testing.expectf(t, found && value.kind == .Null, "%q: %v %v", c.text, found, value.kind)
			continue
		}
		testing.expectf(t, found == c.found, "%q: found %v want %v", c.text, found, c.found)
		if found && c.found {
			testing.expectf(t, value.num == c.num, "%q: %v want %v", c.text, value.num, c.num)
		}
	}
}

@(test)
json_array_depth_limit :: proc(t: ^testing.T) {
	build :: proc(builder: ^strings.Builder, prefix: string, depth: int, suffix: string) -> string {
		strings.builder_reset(builder)
		strings.write_string(builder, prefix)
		for _ in 0 ..< depth {
			strings.write_byte(builder, '[')
		}
		strings.write_byte(builder, '0')
		for _ in 0 ..< depth {
			strings.write_byte(builder, ']')
		}
		strings.write_string(builder, suffix)
		return strings.to_string(builder^)
	}
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	cases := []struct {
		prefix: string,
		depth:  int,
		suffix: string,
		name:   string,
		found:  bool,
	} {
		{`{"k":1,"d":`, 999, "}", "d", true},
		{`{"k":1,"d":`, 1000, "}", "d", false},
		{`{"k":1,"d":`, 1000, "}", "k", true},
		{`{"d":`, 5000, `,"k":1}`, "k", true},
		{`{"k":[1,`, 998, "]}", "k", true},
		{`{"k":[1,`, 999, "]}", "k", false},
	}
	for c in cases {
		attribute, _ := attribute_make(build(&builder, c.prefix, c.depth, c.suffix))
		_, found := lookup_name(attribute, c.name)
		testing.expectf(t, found == c.found, "%s depth %d name %s: %v", c.prefix, c.depth, c.name, found)
		attribute_destroy(&attribute)
	}
}

@(test)
json_many_fields :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_byte(&builder, '{')
	for i in 0 ..< 2000 {
		if i > 0 {
			strings.write_byte(&builder, ',')
		}
		fmt.sbprintf(&builder, `"k%d":%d`, i, i)
	}
	strings.write_byte(&builder, '}')
	attribute, _ := attribute_make(strings.to_string(builder))
	defer attribute_destroy(&attribute)
	for i in 0 ..< 2000 {
		name := fmt.tprintf("k%d", i)
		value, found := lookup_name(attribute, name)
		testing.expectf(t, found && value.num == f64(i), "field %s", name)
	}
	_, found := lookup_name(attribute, "k2000")
	testing.expect(t, !found)
	free_all(context.temp_allocator)
}

@(test)
json_hash_collisions :: proc(t: ^testing.T) {
	pairs := [][2]string{{"glbvs", "yacxa"}, {"glbvp", "yacxb"}, {"glbvq", "yacxc"}}
	for pair in pairs {
		a, b := pair[0], pair[1]
		testing.expect_value(t, name_hash(a), name_hash(b))
		text := strings.concatenate({`{"`, b, `":1,"`, a, `":2,"`, b, `":3,"`, a, `":4}`}, context.temp_allocator)
		expect_match(t, fmt.tprintf(".%s == 2", a), text, true)
		expect_match(t, fmt.tprintf(".%s == 1", b), text, true)
		expect_match(t, fmt.tprintf(".%s == 3", b), text, false)
		expect_match(t, fmt.tprintf(".%s == 4", a), text, false)
		alone := strings.concatenate({`{"`, a, `":5}`}, context.temp_allocator)
		expect_match(t, fmt.tprintf(".%s == 5", b), alone, false)
		expect_match(t, fmt.tprintf(".%s == 5", a), alone, true)
	}
	free_all(context.temp_allocator)
}

@(test)
evaluation_does_not_allocate :: proc(t: ^testing.T) {
	program, _, err := compile(`.year >= 1980 and .rating > 8.0 and .genre == "action" or "x" in .tags or not .missing`)
	defer program_destroy(&program)
	testing.expect(t, err == .None && program.depth <= STACK_INLINE)
	attribute, _ := attribute_make(`{"year":1985,"rating":8.5,"genre":"action","tags":["x"]}`)
	defer attribute_destroy(&attribute)
	other, _ := attribute_make(`{"year":1975}`)
	defer attribute_destroy(&other)
	constant, _, constant_err := compile("1 + 1 == 2")
	defer program_destroy(&constant)
	testing.expect(t, constant_err == .None)
	present, _, present_err := compile(`.year >= 1980 and .rating > 8.0 and .genre == "action" or "x" in .tags or "ac" in .genre`)
	defer program_destroy(&present)
	testing.expect(t, present_err == .None)
	backing := context.allocator
	context.allocator = mem.panic_allocator()
	matched, missed, constant_matched, present_matched := 0, 0, 0, 0
	for _ in 0 ..< 1000 {
		if evaluate(&program, &attribute) {
			matched += 1
		}
		if !evaluate(&program, &other) {
			missed += 1
		}
		if evaluate(&constant, &other) {
			constant_matched += 1
		}
		if evaluate(&present, &attribute) {
			present_matched += 1
		}
	}
	context.allocator = backing
	testing.expect_value(t, matched, 0)
	testing.expect_value(t, missed, 1000)
	testing.expect_value(t, constant_matched, 1000)
	testing.expect_value(t, present_matched, 1000)
}

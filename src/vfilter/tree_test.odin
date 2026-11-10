package vfilter

import "core:log"
import "core:strings"
import "core:testing"

Tree_Kind :: enum u8 {
	Leaf_Constant,
	Leaf_Field,
	Unary,
	Binary,
}

Tree :: struct {
	kind:  Tree_Kind,
	op:    Op,
	text:  string,
	left:  int,
	right: int,
}

TREE_CONSTANTS := [?]string{"0", "1", "2", "3", "-1", "2.5", "10", `"x"`, `"10"`, `""`, `[1, "x"]`, "[]", `["2", 3]`, "null", `"abc"`, `"b"`}
TREE_FIELDS := [?]string{".n", ".s", ".arr", ".b", ".missing", ".f", ".z"}
TREE_BINARY := [?]Op{.Pow, .Mul, .Div, .Mod, .Add, .Sub, .Gt, .Ge, .Lt, .Le, .Eq, .Ne, .In, .And, .Or}

op_text :: proc(op: Op, random: ^Fuzz_Random) -> string {
	#partial switch op {
	case .Pow:
		return "**"
	case .Mul:
		return "*"
	case .Div:
		return "/"
	case .Mod:
		return "%"
	case .Add:
		return "+"
	case .Sub:
		return "-"
	case .Gt:
		return ">"
	case .Ge:
		return ">="
	case .Lt:
		return "<"
	case .Le:
		return "<="
	case .Eq:
		return "=="
	case .Ne:
		return "!="
	case .In:
		return "in"
	case .And:
		return "and" if fuzz_below(random, 2) == 0 else "&&"
	case .Or:
		return "or" if fuzz_below(random, 2) == 0 else "||"
	case .Not:
		return "not " if fuzz_below(random, 2) == 0 else "!"
	}
	return "?"
}

tree_build :: proc(nodes: ^[dynamic]Tree, random: ^Fuzz_Random, depth: int) -> int {
	choice := fuzz_below(random, 3 if depth >= 5 else 8)
	node: Tree
	switch {
	case choice == 0 || choice == 1:
		node = Tree{kind = .Leaf_Constant, text = TREE_CONSTANTS[fuzz_below(random, len(TREE_CONSTANTS))]}
	case choice == 2:
		node = Tree{kind = .Leaf_Field, text = TREE_FIELDS[fuzz_below(random, len(TREE_FIELDS))]}
	case choice == 3:
		node = Tree{kind = .Unary, op = .Not, left = tree_build(nodes, random, depth + 1)}
	case:
		node = Tree{kind = .Binary, op = TREE_BINARY[fuzz_below(random, len(TREE_BINARY))]}
		node.left = tree_build(nodes, random, depth + 1)
		node.right = tree_build(nodes, random, depth + 1)
	}
	append(nodes, node)
	return len(nodes) - 1
}

tree_precedence :: proc(node: Tree) -> int {
	switch node.kind {
	case .Leaf_Constant, .Leaf_Field:
		return 100
	case .Unary, .Binary:
		return op_precedence(node.op)
	}
	return 0
}

tree_write :: proc(builder: ^strings.Builder, nodes: []Tree, index: int, full: bool, random: ^Fuzz_Random) {
	node := nodes[index]
	switch node.kind {
	case .Leaf_Constant, .Leaf_Field:
		strings.write_string(builder, node.text)
	case .Unary:
		strings.write_string(builder, op_text(.Not, random))
		child := nodes[node.left]
		wrap := full || tree_precedence(child) <= op_precedence(.Not)
		tree_write_child(builder, nodes, node.left, wrap, full, random)
	case .Binary:
		precedence := op_precedence(node.op)
		right_assoc := op_right_associative(node.op)
		left := nodes[node.left]
		right := nodes[node.right]
		left_wrap := full || tree_precedence(left) < precedence || (tree_precedence(left) == precedence && right_assoc)
		right_wrap := full || tree_precedence(right) < precedence || (tree_precedence(right) == precedence && !right_assoc)
		tree_write_child(builder, nodes, node.left, left_wrap, full, random)
		strings.write_byte(builder, ' ')
		strings.write_string(builder, op_text(node.op, random))
		strings.write_byte(builder, ' ')
		tree_write_child(builder, nodes, node.right, right_wrap, full, random)
	}
}

tree_write_child :: proc(builder: ^strings.Builder, nodes: []Tree, index: int, wrap, full: bool, random: ^Fuzz_Random) {
	if wrap {
		strings.write_string(builder, "( ")
	}
	tree_write(builder, nodes, index, full, random)
	if wrap {
		strings.write_string(builder, " )")
	}
}

Tree_Context :: struct {
	constants: map[string]Program,
}

tree_constant :: proc(tc: ^Tree_Context, text: string) -> Value {
	if program, found := tc.constants[text]; found {
		return program.constants[0]
	}
	program, _, _ := compile(text)
	tc.constants[text] = program
	return program.constants[0]
}

tree_eval :: proc(tc: ^Tree_Context, nodes: []Tree, index: int, blob: []u8) -> (value: Value, ok: bool) {
	node := nodes[index]
	switch node.kind {
	case .Leaf_Constant:
		return tree_constant(tc, node.text), true
	case .Leaf_Field:
		name := node.text[1:]
		return attribute_lookup(blob, Field_Ref{name = name, hash = name_hash(name)})
	case .Unary:
		operand, operand_ok := tree_eval(tc, nodes, node.left, blob)
		return bool_value(!value_truthy(operand)), operand_ok
	case .Binary:
		left, left_ok := tree_eval(tc, nodes, node.left, blob)
		right, right_ok := tree_eval(tc, nodes, node.right, blob)
		return apply_binary(node.op, left, right), left_ok && right_ok
	}
	return {}, false
}

@(test)
random_trees_match_reference :: proc(t: ^testing.T) {
	random := Fuzz_Random{state = 0x5851F42D4C957F2D}
	tc: Tree_Context
	defer {
		for _, &program in tc.constants {
			program_destroy(&program)
		}
		delete(tc.constants)
	}
	texts := []string{ATTR_SET_A, ATTR_SET_B, ATTR_SET_C, `{"n":"2","s":3,"arr":[],"b":false,"f":0.5,"z":null}`, "notjson", `{"z":"abc","s":"b","n":null,"arr":[null,"x"]}`}
	attributes := make([]Attribute, len(texts))
	defer {
		for &attribute in attributes {
			attribute_destroy(&attribute)
		}
		delete(attributes)
	}
	for text, i in texts {
		attributes[i], _ = attribute_make(text)
	}
	nodes := make([dynamic]Tree)
	defer delete(nodes)
	minimal := strings.builder_make()
	defer strings.builder_destroy(&minimal)
	full := strings.builder_make()
	defer strings.builder_destroy(&full)
	matched, compared := 0, 0
	for _ in 0 ..< 20000 {
		clear(&nodes)
		root := tree_build(&nodes, &random, 0)
		strings.builder_reset(&minimal)
		strings.builder_reset(&full)
		tree_write(&minimal, nodes[:], root, false, &random)
		tree_write(&full, nodes[:], root, true, &random)
		short_program, short_near, short_err := compile(strings.to_string(minimal))
		long_program, long_near, long_err := compile(strings.to_string(full))
		testing.expectf(t, short_err == .None, "%q failed near %q", strings.to_string(minimal), short_near)
		testing.expectf(t, long_err == .None, "%q failed near %q", strings.to_string(full), long_near)
		if short_err == .None && long_err == .None {
			for &attribute in attributes {
				value, ok := tree_eval(&tc, nodes[:], root, attribute.blob)
				wanted := ok && value_truthy(value)
				short_result := evaluate(&short_program, &attribute)
				long_result := evaluate(&long_program, &attribute)
				testing.expectf(t, short_result == wanted && long_result == wanted, "%q / %q on %s: %v %v want %v", strings.to_string(minimal), strings.to_string(full), attribute_text(attribute), short_result, long_result, wanted)
				compared += 1
				if wanted {
					matched += 1
				}
			}
		}
		program_destroy(&short_program)
		program_destroy(&long_program)
	}
	log.infof("tree check: %d evaluations compared, %d matched", compared, matched)
	testing.expect(t, compared == 120000 && matched > 5000)
}

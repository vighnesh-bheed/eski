package vfilter

import "core:strings"
import "core:testing"

match_json :: proc(expression, json: string) -> (matched: bool, compiled: bool) {
	program, _, err := compile(expression)
	defer program_destroy(&program)
	if err != .None {
		return false, false
	}
	attribute, _ := attribute_make(json)
	defer attribute_destroy(&attribute)
	return evaluate(&program, &attribute), true
}

expect_match :: proc(t: ^testing.T, expression, json: string, wanted: bool, loc := #caller_location) {
	matched, compiled := match_json(expression, json)
	testing.expectf(t, compiled, "%q did not compile", expression, loc = loc)
	testing.expectf(t, matched == wanted, "%q on %s: matched %v want %v", expression, json, matched, wanted, loc = loc)
}

expect_near :: proc(t: ^testing.T, expression, wanted: string, loc := #caller_location) {
	program, near, err := compile(expression)
	defer program_destroy(&program)
	testing.expectf(t, err == .Syntax, "%q compiled, want error near %q", expression, wanted, loc = loc)
	testing.expectf(t, near == wanted, "%q: near %q want %q", expression, near, wanted, loc = loc)
}

Truth_Case :: struct {
	expression: string,
	wanted:     bool,
}

expect_truths :: proc(t: ^testing.T, json: string, cases: []Truth_Case, loc := #caller_location) {
	for c in cases {
		expect_match(t, c.expression, json, c.wanted, loc)
	}
}

@(test)
arithmetic_operators :: proc(t: ^testing.T) {
	expect_truths(t, "{}", {
		{"1 + 2 == 3", true},
		{"5 - 7 == -2", true},
		{"6 * 7 == 42", true},
		{"7 / 2 == 3.5", true},
		{"7 % 4 == 3", true},
		{"5.5 % 2 == 1.5", true},
		{"-7 % 4 == -3", true},
		{"7 % -4 == 3", true},
		{"2 ** 10 == 1024", true},
		{"0 ** 0 == 1", true},
		{"1 / 0 > 1e308", true},
		{"0 / 0 == 0 / 0", false},
		{"0 / 0 != 0 / 0", true},
		{"0 / 0", true},
		{"1 % 0", true},
		{"1e3 == 1000", true},
		{"1.e3 == 1000", true},
		{"5. == 5", true},
		{"007 == 7", true},
		{"1e400 > 1e308", true},
		{"0.1 + 0.2 == 0.3", false},
		{"0", false},
		{"-1", true},
	})
}

@(test)
comparison_operators :: proc(t: ^testing.T) {
	expect_truths(t, "{}", {
		{"1 == 1", true},
		{"1 != 1", false},
		{"2 > 1", true},
		{"1 >= 1", true},
		{"1 < 2", true},
		{"2 <= 2", true},
		{`"a" == "a"`, true},
		{`"2" == "2.0"`, false},
		{`"a" < "b"`, false},
		{`"a" <= "a"`, true},
		{`"2" < "10"`, true},
		{`"x" == 0`, true},
		{`"x" < 0`, false},
		{`"x" <= 0`, true},
		{`" 10" == 10`, true},
		{`"10 " == 10`, false},
		{`"10abc" == 10`, false},
		{`"0x10" == 16`, true},
		{`"inf" > 1e308`, true},
		{`"nan" == 0`, false},
		{`"nan" == "nan"`, true},
		{`"1_0" == 10`, false},
		{"[1, 2] == [1, 2]", true},
		{"[1] == [2]", true},
		{"[1] == 1", false},
		{"[] == 0", true},
		{"[1] < 2", true},
		{"null == null", true},
		{"null == 0", false},
		{"null != 0", true},
		{"null < 1", true},
		{`null == ""`, false},
	})
}

@(test)
logical_operators :: proc(t: ^testing.T) {
	expect_truths(t, "{}", {
		{"1 and 1", true},
		{"1 and 0", false},
		{"0 or 1", true},
		{"1 && 0", false},
		{"0 || 1", true},
		{"not 0", true},
		{"!1", false},
		{"not (not 1)", true},
		{"!(!1)", true},
		{`""`, false},
		{`"0"`, true},
		{"[]", true},
		{"not []", false},
		{"null", false},
		{"not null", true},
		{"null or 1", true},
		{"not0", true},
		{"notnull", true},
		{"1 ornot 0", true},
		{"1and 1", true},
		{"1 in1", false},
	})
}

@(test)
precedence_and_associativity :: proc(t: ^testing.T) {
	expect_truths(t, "{}", {
		{"2 ** 3 ** 2 == 512", true},
		{"2 * 3 ** 2 == 18", true},
		{"-2 ** 2 == 4", true},
		{"0 - 2 ** 2 == -4", true},
		{"2 ** -1 == 0.5", true},
		{"1 + 2 * 3 == 7", true},
		{"10 - 4 - 3 == 3", true},
		{"100 / 10 / 5 == 2", true},
		{"2 * 3 % 4 == 2", true},
		{"3 == 3 < 2", true},
		{"2 == 2 > 1", false},
		{"3 > 2 > 1", false},
		{"2 in [2] == 2", false},
		{"0 == 2 in [0]", true},
		{"1 + 1 in [2]", true},
		{"1 or 0 and 0", true},
		{"not 1 == 2", false},
		{"not 1 or 1", true},
		{"!2 ** 2 == 0", true},
		{"2 ** !0 == 2", true},
		{"not 1 in [0]", true},
		{"1 and not not 1", false},
		{"1 notin [1]", false},
		{"1 in not [1]", false},
		{"1 2 +", true},
		{"+ 1 2", true},
		{"1 !", false},
		{"1 not not", true},
		{"1 + 2 3 *", true},
		{"1 (+ 2)", true},
		{"1 --1", true},
		{"1-1", false},
		{"1 -1 == 0", true},
		{"1 +-1 == 0", true},
		{"1 !=! 1", true},
	})
}

@(test)
containment :: proc(t: ^testing.T) {
	json := `{"n":1,"s":"abc","ns":"2","arr":[1,"two",true,null,[1],"x"],"empty":[],"z":null}`
	expect_truths(t, json, {
		{".n in [1, 2]", true},
		{".n in []", false},
		{".n in 1", false},
		{`.n in "1"`, false},
		{`"b" in .s`, true},
		{`"" in .s`, true},
		{`"abcd" in .s`, false},
		{`.ns in [2]`, true},
		{"1 in .arr", true},
		{`"two" in .arr`, true},
		{"0 in .arr", true},
		{"5 in .arr", false},
		{"null in .arr", true},
		{".arr in [1]", false},
		{".arr in [0]", true},
		{".empty", true},
		{"not .empty", false},
		{"2 in .empty", false},
		{".z in [0]", false},
		{`"a" in ["abc"]`, false},
		{"[1, 2] in [0]", true},
	})
}

@(test)
missing_and_unsupported_fields :: proc(t: ^testing.T) {
	json := `{"n":1,"o":{"k":5},"z":null,"s":"","bad":[{"k":1}],"":5}`
	expect_truths(t, json, {
		{".missing == 1", false},
		{".missing != 1", false},
		{"not .missing", false},
		{".missing or 1 == 1", false},
		{"1 == 1 or .missing", false},
		{"not (0 and .missing)", false},
		{".", false},
		{"not .", false},
		{".o", false},
		{"not .o", false},
		{".bad", false},
		{"not .bad", false},
		{".z", false},
		{"not .z", true},
		{".z != 1", true},
		{".z == 0", false},
		{".z < 1", true},
		{".s", false},
		{"not .s", true},
		{".N == 1", false},
		{".n == 1", true},
	})
}

@(test)
string_literals_are_raw :: proc(t: ^testing.T) {
	json := `{"q":"a\"b","b":"a\\b","t":"a\tb","n":"x\ny","u":"\u0041","e":"\q"}`
	expect_truths(t, json, {
		{`.q == 'a"b'`, true},
		{`.q == "a\"b"`, false},
		{`.b == "a\b"`, true},
		{`.b == "a\\b"`, false},
		{".t == \"a\tb\"", true},
		{`.t == "a\tb"`, false},
		{".n == \"x\ny\"", true},
		{`.u == "u0041"`, true},
		{`.u == "A"`, false},
		{`.e == "q"`, true},
		{`"\q" == "q"`, false},
		{`"\"" == '\"'`, true},
		{`'\'' == "\'"`, true},
	})
}

@(test)
field_names :: proc(t: ^testing.T) {
	json := `{"a_b":1,"A1":2,"_":3,"9":4,"":5,"a-b":6,"n-1":7,"\k":8,"k":9}`
	expect_truths(t, json, {
		{".a_b == 1", true},
		{".A1 == 2", true},
		{"._ == 3", true},
		{".9 == 4", true},
		{".a-b == 6", true},
		{".n-1 == 7", true},
		{".k == 9", true},
		{".a1 == 2", false},
		{".5 == 0.5", false},
	})
	expect_near(t, ". == 5", ". == 5")
	expect_near(t, "1 + . == 5", ". == 5")
	expect_near(t, ".a$b == 8", "$b == 8")
	expect_near(t, ".a b == 9", " == 9")
	expect_near(t, ".\xc3\xa9 == 7", ".\xc3\xa9 == 7")
}

@(test)
syntax_errors :: proc(t: ^testing.T) {
	cases := []struct {
		expression, near: string,
	} {
		{"", ""},
		{" ", " "},
		{".n = 1", " 1"},
		{"1 =", "1 ="},
		{"1 = ", " "},
		{".n & .b", " .b"},
		{"1 =& 1", " 1"},
		{"1 =( 1)", " 1)"},
		{"1 === 1", " 1"},
		{"1 &foo", "1 &foo"},
		{"foo&1", "1"},
		{"foo & 1", " & 1"},
		{"foo", "foo"},
		{"1 android 1", " 1"},
		{"1 oracle", "1 oracle"},
		{"x1", "1"},
		{"foo_bar & 1", "_bar & 1"},
		{"(null)", "(null)"},
		{"(null) == 0", " == 0"},
		{"null==null", "null==null"},
		{"not not 1", "not not 1"},
		{"!!1", "!!1"},
		{"1 ! 1", "1 ! 1"},
		{"1 2", "1 2"},
		{".n >> 1", ".n >> 1"},
		{"-.n", "-.n"},
		{"- 1", "- 1"},
		{"(1 > ) & 2", " 2"},
		{"1 2 & 3", " 3"},
		{"1 # 2", "# 2"},
		{"# foo", "# foo"},
		{"1 , 2", ", 2"},
		{"1 == 1 ]", "]"},
		{"_x & 1", "_x & 1"},
		{"1e+3 == 1000", "+3 == 1000"},
		{"1e", "1e"},
		{"2end", "nd"},
		{"1.5.n", "n"},
		{"0x10 == 16", "10 == 16"},
		{"[1 2]", "2]"},
		{"[,1]", ",1]"},
		{"[- 1]", " 1]"},
		{"[true]", "true]"},
		{"[null]", "null]"},
		{"[1, 2", "[1, 2"},
		{"[1]]", "]"},
		{`"open`, `"open`},
		{`1 & "x`, ` "x`},
		{"'x\\'", "'x\\'"},
		{"1 \x01 2", "\x01 2"},
		{"1 \xc3\xa9 2", "\xc3\xa9 2"},
	}
	for c in cases {
		expect_near(t, c.expression, c.near)
	}
}

@(test)
nul_truncates_the_expression :: proc(t: ^testing.T) {
	expect_match(t, "1 == 1\x00 junk", "{}", true)
	expect_match(t, "1 \x00 2", "{}", true)
	expect_near(t, "foo\x00", "")
	expect_near(t, "1 &\x00 2", "")
	expect_near(t, "1 ==\x00 1", "1 ==")
	expect_near(t, "\x00", "")
}

@(test)
error_text_matches_the_reply :: proc(t: ^testing.T) {
	cases := []struct {
		near, wanted: string,
	} {
		{" 1", "ERR syntax error in FILTER expression near:  1"},
		{" 2\n", "ERR syntax error in FILTER expression near:  2"},
		{" \n2", "ERR syntax error in FILTER expression near:   2"},
		{" \r\n2", "ERR syntax error in FILTER expression near:    2"},
		{"\n", "ERR syntax error in FILTER expression near: "},
		{" 2 \n", "ERR syntax error in FILTER expression near:  2 "},
		{"\r\nfoo", "ERR syntax error in FILTER expression near:   foo"},
	}
	for c in cases {
		text, err := error_text(c.near)
		testing.expect(t, err == nil)
		testing.expect_value(t, text, c.wanted)
		testing.expect(t, strings.has_prefix(text, SYNTAX_ERROR_PREFIX))
		delete(text)
	}
	testing.expect_value(t, reply_near(" 2\r\n\r\n"), " 2")
	testing.expect_value(t, reply_near(" \n2"), " \n2")
}

@(test)
attribute_presence_rules :: proc(t: ^testing.T) {
	constant, _, err := compile("1 == 1")
	defer program_destroy(&constant)
	testing.expect(t, err == .None && constant.constant && !program_reads_fields(&constant))
	reader, _, reader_err := compile(".n == 1")
	defer program_destroy(&reader)
	testing.expect(t, reader_err == .None && !reader.constant && program_reads_fields(&reader))
	testing.expect(t, !evaluate(&constant, nil))
	testing.expect(t, !evaluate(&reader, nil))
	texts := []string{"notjson", "{bad json", "", "[1]", "5", `"s"`, "{}", `{"n":2}`, `{'n':1}`, `{"x":tru,"n":1}`, `{"n":.5}`}
	for text in texts {
		attribute, _ := attribute_make(text)
		defer attribute_destroy(&attribute)
		testing.expectf(t, evaluate(&constant, &attribute), "constant on %q", text)
		testing.expectf(t, !evaluate(&reader, &attribute), "reader on %q", text)
		testing.expect_value(t, attribute_text(attribute), text)
	}
	lenient := []string{`{"n":1}`, `{"n":1}garbage`, `{"n":1,}`, `{"n":01}`, `{"n":+1}`, `{"n":1x}`, `{"n":1 2}`, `{"s":"\x","n":1}`, `{"x":[1 2],"n":1}`, `{"x":-,"n":1}`, `{"n":true}`}
	for text in lenient {
		attribute, _ := attribute_make(text)
		defer attribute_destroy(&attribute)
		testing.expectf(t, evaluate(&reader, &attribute), "reader on %q", text)
	}
	empty: Program
	attribute, _ := attribute_make(`{"n":1}`)
	defer attribute_destroy(&attribute)
	testing.expect(t, !evaluate(&empty, &attribute))
}

@(test)
deep_expressions :: proc(t: ^testing.T) {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	depth := 5000
	for _ in 0 ..< depth {
		strings.write_string(&builder, "(1 + ")
	}
	strings.write_string(&builder, ".n")
	for _ in 0 ..< depth {
		strings.write_string(&builder, " )")
	}
	strings.write_string(&builder, " == 5001")
	program, _, err := compile(strings.to_string(builder))
	defer program_destroy(&program)
	testing.expect(t, err == .None)
	testing.expect(t, program.depth > STACK_INLINE)
	attribute, _ := attribute_make(`{"n":1}`)
	defer attribute_destroy(&attribute)
	testing.expect(t, evaluate(&program, &attribute))
	strings.builder_reset(&builder)
	for _ in 0 ..< 100000 {
		strings.write_byte(&builder, '(')
	}
	strings.write_string(&builder, "1")
	for _ in 0 ..< 100000 {
		strings.write_byte(&builder, ')')
	}
	nested, _, nested_err := compile(strings.to_string(builder))
	defer program_destroy(&nested)
	testing.expect(t, nested_err == .None && nested.depth == 1 && evaluate(&nested, &attribute))
	strings.builder_reset(&builder)
	for _ in 0 ..< 3000 {
		strings.write_string(&builder, "2 ** ")
	}
	strings.write_string(&builder, "1")
	power, _, power_err := compile(strings.to_string(builder))
	defer program_destroy(&power)
	testing.expect(t, power_err == .None && power.depth == 3001 && evaluate(&power, &attribute))
	strings.builder_reset(&builder)
	for _ in 0 ..< 4000 {
		strings.write_string(&builder, "1 ")
	}
	for _ in 0 ..< 3999 {
		strings.write_string(&builder, "+ ")
	}
	postfix, _, postfix_err := compile(strings.to_string(builder))
	defer program_destroy(&postfix)
	testing.expect(t, postfix_err == .None && postfix.depth == 4000 && evaluate(&postfix, &attribute))
}

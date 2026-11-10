package vfilter

import "core:log"
import "core:strings"
import "core:testing"

Fuzz_Random :: struct {
	state: u64,
}

fuzz_next :: proc(random: ^Fuzz_Random) -> u64 {
	x := random.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	random.state = x
	return x * 0x2545F4914F6CDD1D
}

fuzz_below :: proc(random: ^Fuzz_Random, n: int) -> int {
	return int(fuzz_next(random) % u64(n))
}

FUZZ_TOKENS := [?]string {
	".n",
	".s",
	".arr",
	".b",
	".missing",
	".",
	"1",
	"0",
	"2.5",
	"-3",
	"1e2",
	"1e+2",
	`"x"`,
	`'10'`,
	`""`,
	`[1, "x"]`,
	"[]",
	"[1,]",
	"null",
	"(",
	")",
	"(",
	")",
	"+",
	"-",
	"*",
	"/",
	"%",
	"**",
	"==",
	"!=",
	">",
	">=",
	"<",
	"<=",
	"and",
	"or",
	"not",
	"&&",
	"||",
	"!",
	"in",
	"=",
	"&",
	"|",
	"foo",
	"true",
	`"open`,
	"[1,",
	"#",
	",",
	"]",
	".o.k",
	"..",
	"e",
	"\\",
	"\x00",
	"\n",
}

FUZZ_SEPARATORS := [?]string{"", " ", " ", " ", "  ", "\t"}

fuzz_bytes := "().[]\"'\\=!<>&|+-*/%, \t0123456789eanotrufsl_\x00\n"

fuzz_attribute_texts := [?]string {
	ATTR_SET_A,
	ATTR_SET_B,
	ATTR_SET_C,
	"notjson",
	"{}",
	`{"n":"5","s":10,"arr":[],"b":null}`,
}

fuzz_program_shape :: proc(program: ^Program) -> bool {
	depth, deepest := 0, 0
	for instruction in program.code {
		switch instruction.op {
		case .Push:
			if int(instruction.arg) >= len(program.constants) {
				return false
			}
		case .Load:
			if int(instruction.arg) >= len(program.fields) {
				return false
			}
		case .Not, .Pow, .Mul, .Div, .Mod, .Add, .Sub, .Gt, .Ge, .Lt, .Le, .Eq, .Ne, .In, .And, .Or:
		}
		arity := op_arity(instruction.op)
		if depth < arity {
			return false
		}
		depth += 1 - arity
		deepest = max(deepest, depth)
	}
	return depth == 1 && deepest == program.depth && program.constant == (len(program.fields) == 0)
}

Fuzz_Tally :: struct {
	compiled:   int,
	rejected:   int,
	positional: int,
	matched:    int,
}

fuzz_one :: proc(t: ^testing.T, expression: string, attributes: []Attribute, tally: ^Fuzz_Tally) {
	program, near, err := compile(expression)
	defer program_destroy(&program)
	effective := effective_text(expression)
	switch err {
	case .None:
		tally.compiled += 1
		testing.expectf(t, fuzz_program_shape(&program), "bad program shape for %q", expression)
		testing.expectf(t, !evaluate(&program, nil), "%q matched a missing attribute", expression)
		for &attribute in attributes {
			first := evaluate(&program, &attribute)
			second := evaluate(&program, &attribute)
			testing.expectf(t, first == second, "%q is not deterministic", expression)
			if first {
				tally.matched += 1
			}
		}
	case .Syntax:
		tally.rejected += 1
		if near != effective {
			tally.positional += 1
		}
		testing.expectf(t, strings.has_suffix(effective, near), "%q: near %q is not a remainder", expression, near)
		again, near_again, err_again := compile(expression)
		defer program_destroy(&again)
		testing.expectf(t, err_again == .Syntax && near_again == near, "%q is not deterministic", expression)
		text, _ := error_text(near)
		testing.expectf(t, strings.index_any(text, "\r\n") < 0, "%q: reply text keeps a line break", expression)
		delete(text)
	case .Out_Of_Memory:
		testing.expectf(t, false, "%q ran out of memory", expression)
	}
}

fuzz_make_attributes :: proc() -> []Attribute {
	attributes := make([]Attribute, len(fuzz_attribute_texts))
	for text, i in fuzz_attribute_texts {
		attributes[i], _ = attribute_make(text)
	}
	return attributes
}

fuzz_destroy_attributes :: proc(attributes: []Attribute) {
	for &attribute in attributes {
		attribute_destroy(&attribute)
	}
	delete(attributes)
}

@(test)
fuzz_token_sequences :: proc(t: ^testing.T) {
	random := Fuzz_Random{state = 0x9E3779B97F4A7C15}
	attributes := fuzz_make_attributes()
	defer fuzz_destroy_attributes(attributes)
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	tally: Fuzz_Tally
	for _ in 0 ..< 60000 {
		strings.builder_reset(&builder)
		count := fuzz_below(&random, 14)
		for i in 0 ..< count {
			if i > 0 {
				strings.write_string(&builder, FUZZ_SEPARATORS[fuzz_below(&random, len(FUZZ_SEPARATORS))])
			}
			strings.write_string(&builder, FUZZ_TOKENS[fuzz_below(&random, len(FUZZ_TOKENS))])
		}
		fuzz_one(t, strings.to_string(builder), attributes, &tally)
	}
	log.infof("token fuzz: %d compiled, %d rejected (%d positional), %d matches", tally.compiled, tally.rejected, tally.positional, tally.matched)
	testing.expect(t, tally.compiled > 1000 && tally.rejected > 1000 && tally.positional > 100 && tally.matched > 100)
}

@(test)
fuzz_random_bytes :: proc(t: ^testing.T) {
	random := Fuzz_Random{state = 0xD1B54A32D192ED03}
	attributes := fuzz_make_attributes()
	defer fuzz_destroy_attributes(attributes)
	buffer: [40]u8
	tally: Fuzz_Tally
	for _ in 0 ..< 60000 {
		length := fuzz_below(&random, len(buffer) + 1)
		for i in 0 ..< length {
			if fuzz_below(&random, 8) == 0 {
				buffer[i] = u8(fuzz_below(&random, 256))
			} else {
				buffer[i] = fuzz_bytes[fuzz_below(&random, len(fuzz_bytes))]
			}
		}
		fuzz_one(t, string(buffer[:length]), attributes, &tally)
	}
	log.infof("byte fuzz: %d compiled, %d rejected (%d positional), %d matches", tally.compiled, tally.rejected, tally.positional, tally.matched)
	testing.expect(t, tally.compiled > 100 && tally.rejected > 1000)
}

Oracle_Result :: struct {
	found: bool,
	kind:  Value_Kind,
	num:   f64,
	str:   string,
	items: int,
}

oracle_space :: proc(text: string, at: int) -> int {
	i := at
	for i < len(text) && strings.index_byte(" \t\n\x0b\x0c\r", text[i]) >= 0 {
		i += 1
	}
	return i
}

oracle_string_end :: proc(text: string, at: int) -> (end: int, ok: bool) {
	i := at + 1
	for i < len(text) {
		switch text[i] {
		case '"':
			return i, true
		case '\\':
			i += 2
		case:
			i += 1
		}
	}
	return 0, false
}

oracle_decode :: proc(raw: string, allocator := context.temp_allocator) -> string {
	builder := strings.builder_make(allocator)
	for i := 0; i < len(raw); i += 1 {
		c := raw[i]
		if c == '\\' {
			i += 1
			switch raw[i] {
			case 'n':
				strings.write_byte(&builder, '\n')
			case 't':
				strings.write_byte(&builder, '\t')
			case 'r':
				strings.write_byte(&builder, '\r')
			case:
				strings.write_byte(&builder, raw[i])
			}
			continue
		}
		strings.write_byte(&builder, c)
	}
	return strings.to_string(builder)
}

oracle_word :: proc(text: string, at: int) -> (word: string, end: int, ok: bool) {
	for candidate in ([]string{"true", "false", "null"}) {
		if strings.has_prefix(text[at:], candidate) {
			end = at + len(candidate)
			if end == len(text) || strings.index_byte(" \t\n\x0b\x0c\r,}]", text[end]) >= 0 {
				return candidate, end, true
			}
			return
		}
	}
	return
}

oracle_value :: proc(text: string, at: int, level: int) -> (result: Oracle_Result, end: int, ok: bool) {
	if at >= len(text) {
		return
	}
	c := text[at]
	switch {
	case c == '"':
		close := oracle_string_end(text, at) or_return
		return Oracle_Result{found = true, kind = .String, str = oracle_decode(text[at + 1:close]), num = string_number(oracle_decode(text[at + 1:close]))}, close + 1, true
	case c == '[':
		if level + 1 >= ARRAY_DEPTH_LIMIT {
			return
		}
		i := oracle_space(text, at + 1)
		count := 0
		if i < len(text) && text[i] == ']' {
			return Oracle_Result{found = true, kind = .Array}, i + 1, true
		}
		for {
			i = oracle_space(text, i)
			_, next := oracle_value(text, i, level + 1) or_return
			count += 1
			i = oracle_space(text, next)
			if i >= len(text) {
				return
			}
			if text[i] == ']' {
				return Oracle_Result{found = true, kind = .Array, items = count}, i + 1, true
			}
			if text[i] != ',' {
				return
			}
			i += 1
		}
	case c == 't' || c == 'f' || c == 'n':
		word, stop := oracle_word(text, at) or_return
		switch word {
		case "true":
			return Oracle_Result{found = true, kind = .Number, num = 1}, stop, true
		case "false":
			return Oracle_Result{found = true, kind = .Number}, stop, true
		}
		return Oracle_Result{found = true, kind = .Null}, stop, true
	case strings.index_byte("0123456789+-", c) >= 0:
		stop := at
		for stop < len(text) && strings.index_byte("0123456789.eE+-", text[stop]) >= 0 {
			stop += 1
		}
		value := run_number(text[at:stop]) or_return
		return Oracle_Result{found = true, kind = .Number, num = value}, stop, true
	}
	return
}

oracle_skip :: proc(text: string, at: int) -> (end: int, ok: bool) {
	if at >= len(text) {
		return
	}
	c := text[at]
	switch {
	case c == '"':
		close := oracle_string_end(text, at) or_return
		return close + 1, true
	case c == '[' || c == '{':
		closer: u8 = ']' if c == '[' else '}'
		depth := 0
		for i := at; i < len(text); i += 1 {
			if text[i] == '"' {
				i = oracle_string_end(text, i) or_return
			} else if text[i] == c {
				depth += 1
			} else if text[i] == closer {
				depth -= 1
				if depth == 0 {
					return i + 1, true
				}
			}
		}
		return
	case c == 't' || c == 'f' || c == 'n':
		_, stop := oracle_word(text, at) or_return
		return stop, true
	case strings.index_byte("0123456789.eE+-", c) >= 0:
		stop := at
		for stop < len(text) && strings.index_byte("0123456789.eE+-", text[stop]) >= 0 {
			stop += 1
		}
		return stop, true
	}
	return
}

oracle_lookup :: proc(text, name: string) -> Oracle_Result {
	i := oracle_space(text, 0)
	if i >= len(text) || text[i] != '{' {
		return {}
	}
	i += 1
	for {
		i = oracle_space(text, i)
		if i >= len(text) || text[i] != '"' {
			return {}
		}
		close, closed := oracle_string_end(text, i)
		if !closed {
			return {}
		}
		key := text[i + 1:close]
		i = oracle_space(text, close + 1)
		if i >= len(text) || text[i] != ':' {
			return {}
		}
		i = oracle_space(text, i + 1)
		if key == name && name != "" {
			result, _, ok := oracle_value(text, i, 0)
			if !ok {
				return {}
			}
			return result
		}
		end, skipped := oracle_skip(text, i)
		if !skipped {
			return {}
		}
		i = oracle_space(text, end)
		if i >= len(text) || text[i] != ',' {
			return {}
		}
		i += 1
	}
}

FUZZ_JSON_NUMBERS := [?]string{"0", "-1", "2.5", "1e3", "-0.25E-2", "123456789", "-0", "7E+1", "01", "+1", "1.", ".5", "-", "1e", "0x1"}
FUZZ_JSON_STRINGS := [?]string{`"x"`, `""`, `"a\"b"`, `"\u00e9"`, `"10"`, `"\\"`, `"\/\b\f\n\r\t"`, `"\x"`, `"a\tb"`, "\"a\tb\""}
FUZZ_JSON_KEYS := [?]string{`"a"`, `"b"`, `"c"`, `"n"`, `"\u0061"`, `""`, `"a-b"`, `"B"`}
FUZZ_JSON_NAMES := [?]string{"a", "b", "c", "n", "a-b", "B", "u0061", "x"}
fuzz_json_mutations := "{}[]\",:0-.e\\u tfn1/x"

fuzz_json_value :: proc(random: ^Fuzz_Random, builder: ^strings.Builder, depth: int) {
	choice := fuzz_below(random, 6 if depth > 5 else 9)
	switch choice {
	case 0, 5:
		strings.write_string(builder, FUZZ_JSON_NUMBERS[fuzz_below(random, len(FUZZ_JSON_NUMBERS))])
	case 1:
		strings.write_string(builder, FUZZ_JSON_STRINGS[fuzz_below(random, len(FUZZ_JSON_STRINGS))])
	case 2:
		strings.write_string(builder, "true")
	case 3:
		strings.write_string(builder, "false")
	case 4:
		strings.write_string(builder, "null")
	case 6, 7:
		strings.write_byte(builder, '[')
		count := fuzz_below(random, 4)
		for i in 0 ..< count {
			if i > 0 {
				strings.write_string(builder, ", " if fuzz_below(random, 2) == 0 else ",")
			}
			fuzz_json_value(random, builder, depth + 1)
		}
		strings.write_byte(builder, ']')
	case 8:
		fuzz_json_object(random, builder, depth + 1)
	}
}

fuzz_json_object :: proc(random: ^Fuzz_Random, builder: ^strings.Builder, depth: int) {
	strings.write_byte(builder, '{')
	count := fuzz_below(random, 5)
	for i in 0 ..< count {
		if i > 0 {
			strings.write_byte(builder, ',')
		}
		strings.write_string(builder, FUZZ_JSON_KEYS[fuzz_below(random, len(FUZZ_JSON_KEYS))])
		strings.write_string(builder, ":" if fuzz_below(random, 2) == 0 else " : ")
		fuzz_json_value(random, builder, depth)
	}
	strings.write_byte(builder, '}')
}

@(test)
fuzz_json_documents :: proc(t: ^testing.T) {
	random := Fuzz_Random{state = 0xA0761D6478BD642F}
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	buffer := make([dynamic]u8)
	defer delete(buffer)
	found_count, compared := 0, 0
	for _ in 0 ..< 30000 {
		strings.builder_reset(&builder)
		fuzz_json_object(&random, &builder, 0)
		clear(&buffer)
		append(&buffer, ..transmute([]u8)strings.to_string(builder))
		if fuzz_below(&random, 2) == 0 {
			for _ in 0 ..= fuzz_below(&random, 3) {
				position := fuzz_below(&random, len(buffer) + 1)
				mutation := fuzz_json_mutations[fuzz_below(&random, len(fuzz_json_mutations))]
				switch fuzz_below(&random, 3) {
				case 0:
					if position < len(buffer) {
						ordered_remove(&buffer, position)
					}
				case 1:
					inject_at(&buffer, position, mutation)
				case 2:
					if position < len(buffer) {
						buffer[position] = mutation
					}
				}
			}
		}
		text := string(buffer[:])
		attribute, make_err := attribute_make(text)
		testing.expect(t, make_err == nil)
		testing.expect(t, attribute_text(attribute) == text)
		for name in FUZZ_JSON_NAMES {
			wanted := oracle_lookup(text, name)
			value, found := lookup_name(attribute, name)
			compared += 1
			same := found == wanted.found
			if same && found {
				same = value.kind == wanted.kind
				switch value.kind {
				case .Number:
					same = same && (value.num == wanted.num || (value.num != value.num && wanted.num != wanted.num))
				case .String:
					same = same && value.str == wanted.str
				case .Array:
					same = same && len(value.items) == wanted.items
				case .Null:
				}
				found_count += 1
			}
			testing.expectf(t, same, "%q name %s: got %v %v want %v", text, name, found, value, wanted)
		}
		attribute_destroy(&attribute)
		free_all(context.temp_allocator)
	}
	log.infof("json fuzz: %d lookups compared, %d found", compared, found_count)
	testing.expect(t, compared == 240000 && found_count > 20000)
}

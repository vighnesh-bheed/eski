package ftquery

import "core:mem"
import "core:strings"

Test_Field :: struct {
	name:    string,
	kind:    Field_Kind,
	options: Field_Options,
	method:  Vector_Method,
	blob:    int,
}

Test_Schema :: struct {
	index:     string,
	custom:    bool,
	stopwords: []string,
	fields:    []Test_Field,
}

Test_Case :: struct {
	id:       int,
	index:    string,
	query:    string,
	dialect:  int,
	verbatim: bool,
	language: string,
	params:   []Param,
	expect:   string,
	error:    bool,
	lines:    bool,
}

Test_Stem :: struct {
	language: string,
	term:     string,
	forms:    []string,
}

test_schema :: proc(name: string, allocator := context.allocator) -> (schema: Schema, found: bool) {
	for s in TEST_SCHEMAS {
		if s.index != name {
			continue
		}
		fields := make([]Field, len(s.fields), allocator)
		for f, i in s.fields {
			fields[i] = Field {
				name      = f.name,
				kind      = f.kind,
				options   = f.options,
				method    = f.method,
				blob_size = f.blob,
			}
		}
		return Schema{fields = fields, stopwords = s.stopwords, custom_stopwords = s.custom}, true
	}
	return {}, false
}

latin_lower :: proc(user: rawptr, text: string, allocator: mem.Allocator) -> string {
	out, err := make([]u8, len(text), allocator)
	if err != nil {
		return text
	}
	copy(out, text)
	for i := 0; i < len(out); i += 1 {
		c := out[i]
		if c >= 'A' && c <= 'Z' {
			out[i] = c + 32
		} else if c == 0xc3 && i + 1 < len(out) && out[i + 1] >= 0x80 && out[i + 1] <= 0x9e && out[i + 1] != 0x97 {
			out[i + 1] += 0x20
			i += 1
		}
	}
	return string(out)
}

table_expand :: proc(user: rawptr, term: string, language: string, allocator: mem.Allocator) -> []string {
	for s in TEST_STEMS {
		if s.language == language && s.term == term {
			out := make([]string, len(s.forms), allocator)
			copy(out, s.forms)
			return out
		}
	}
	out := make([]string, 1, allocator)
	out[0] = strings.concatenate({"+", term}, allocator)
	return out
}

TEST_HOOKS :: Hooks {
	normalize = latin_lower,
	expand    = table_expand,
}

run_case :: proc(c: Test_Case, allocator := context.allocator) -> (got: string, is_error: bool, ok: bool) {
	schema, found := test_schema(c.index, allocator)
	if !found {
		return "", false, false
	}
	defer delete(schema.fields, allocator)
	opts := Options {
		dialect       = c.dialect,
		verbatim      = c.verbatim,
		language      = c.language,
		params        = c.params,
		hooks         = TEST_HOOKS,
		check_vectors = true,
	}
	parsed, err := parse(c.query, &schema, opts, allocator)
	defer parsed_destroy(parsed)
	if err.code != .None {
		return error_reply(err, allocator), true, true
	}
	if c.lines {
		lines, text := explain_lines(&parsed.query, &schema, allocator)
		defer delete(text, allocator)
		defer delete(lines, allocator)
		return strings.join(lines, "\n", allocator), false, true
	}
	return explain(&parsed.query, &schema, allocator), false, true
}

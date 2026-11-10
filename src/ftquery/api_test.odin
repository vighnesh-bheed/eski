package ftquery

import "core:mem"
import "core:strings"
import "core:testing"

api_schema :: proc() -> Schema {
	schema, _ := test_schema("s")
	return schema
}

field_index :: proc(schema: ^Schema, name: string) -> int {
	index, _ := schema_field(schema, name)
	return index
}

@(test)
knn_filter_tree :: proc(t: ^testing.T) {
	schema := api_schema()
	defer delete(schema.fields)
	params := [?]Param{{"vector", "AAAABBBBCCCCDDDD"}}
	opts := Options{dialect = 2, params = params[:], check_vectors = true}
	parsed, err := parse("(@category:{news | Tech} @year:[(2005 +inf])=>[KNN 5 @embedding $vector AS vector_distance]", &schema, opts)
	defer parsed_destroy(parsed)
	testing.expect_value(t, err.code, Error_Code.None)
	q := &parsed.query
	root := node_get(q, q.root)
	testing.expect_value(t, root.kind, Node_Kind.Vector)
	v := root.vector
	testing.expect_value(t, v.kind, Vector_Kind.Knn)
	testing.expect_value(t, v.k, u64(5))
	testing.expect_value(t, v.field, field_index(&schema, "embedding"))
	testing.expect_value(t, v.blob_param, "vector")
	testing.expect_value(t, v.blob, "AAAABBBBCCCCDDDD")
	testing.expect_value(t, v.score_alias, "vector_distance")
	testing.expect_value(t, len(root.children), 1)
	filter := node_get(q, root.children[0])
	testing.expect_value(t, filter.kind, Node_Kind.Intersect)
	tag := node_get(q, filter.children[0])
	testing.expect_value(t, tag.kind, Node_Kind.Tag)
	testing.expect_value(t, tag.field, field_index(&schema, "category"))
	testing.expect_value(t, len(tag.children), 2)
	testing.expect_value(t, node_get(q, tag.children[1]).text, "tech")
	num := node_get(q, filter.children[1])
	testing.expect_value(t, num.kind, Node_Kind.Numeric)
	testing.expect_value(t, num.min, 2005)
	testing.expect(t, num.min_open && !num.max_open && num.max == f64_inf())
}

@(test)
range_and_attributes :: proc(t: ^testing.T) {
	schema := api_schema()
	defer delete(schema.fields)
	params := [?]Param{{"vector", "AAAABBBBCCCCDDDD"}, {"distance_threshold", "0.9"}}
	opts := Options{dialect = 2, params = params[:], check_vectors = true}
	parsed, err := parse("@embedding:[VECTOR_RANGE $distance_threshold $vector]=>{$YIELD_DISTANCE_AS: vector_distance; $EPSILON: 0.05} (@category:{tech})", &schema, opts)
	defer parsed_destroy(parsed)
	testing.expect_value(t, err.code, Error_Code.None)
	q := &parsed.query
	root := node_get(q, q.root)
	testing.expect_value(t, root.kind, Node_Kind.Intersect)
	vec := node_get(q, root.children[0])
	testing.expect_value(t, vec.kind, Node_Kind.Vector)
	testing.expect_value(t, vec.vector.kind, Vector_Kind.Range)
	testing.expect_value(t, vec.vector.radius, 0.9)
	testing.expect_value(t, vec.vector.score_alias, "vector_distance")
	testing.expect_value(t, len(vec.vector.attributes), 1)
	testing.expect_value(t, vec.vector.attributes[0].value, "0.05")
}

@(test)
weighted_text_query :: proc(t: ^testing.T) {
	schema := api_schema()
	defer delete(schema.fields)
	opts := Options{dialect = 2, verbatim = true}
	parsed, err := parse("(@content:(redis=>{$weight:2.0} | search) | @title:(redis=>{$weight:2.0} | search) => { $weight: 2.0 })", &schema, opts)
	defer parsed_destroy(parsed)
	testing.expect_value(t, err.code, Error_Code.None)
	q := &parsed.query
	root := node_get(q, q.root)
	testing.expect_value(t, root.kind, Node_Kind.Union)
	testing.expect_value(t, root.weight, 1)
	testing.expect_value(t, node_get(q, root.children[1]).weight, 2)
	content := node_get(q, root.children[0])
	testing.expect_value(t, content.mask, Field_Mask(1) << 0)
	redis := node_get(q, content.children[0])
	testing.expect_value(t, redis.text, "redis")
	testing.expect_value(t, redis.weight, 2)
	text := explain(q, &schema)
	defer delete(text)
	testing.expect(t, strings.has_prefix(text, "UNION {\n  @content:UNION {\n    @content:redis => {$weight: 2;}\n"))
}

Hook_Record :: struct {
	normalized: int,
	expanded:   int,
	language:   string,
}

recording_normalize :: proc(user: rawptr, text: string, allocator: mem.Allocator) -> string {
	record := (^Hook_Record)(user)
	record.normalized += 1
	return strings.to_upper(text, allocator)
}

recording_expand :: proc(user: rawptr, term: string, language: string, allocator: mem.Allocator) -> []string {
	record := (^Hook_Record)(user)
	record.expanded += 1
	record.language = language
	out := make([]string, 2, allocator)
	out[0] = strings.concatenate({"+", term}, allocator)
	out[1] = strings.concatenate({term, "s"}, allocator)
	return out
}

@(test)
hooks_reach_terms :: proc(t: ^testing.T) {
	schema, _ := test_schema("st")
	defer delete(schema.fields)
	record: Hook_Record
	opts := Options {
		dialect = 2,
		language = "german",
		hooks = Hooks{user = &record, normalize = recording_normalize, expand = recording_expand},
	}
	parsed, err := parse("@t:Run @n:walk \"two words\"", &schema, opts)
	defer parsed_destroy(parsed)
	testing.expect_value(t, err.code, Error_Code.None)
	testing.expect_value(t, record.expanded, 1)
	testing.expect_value(t, record.language, "german")
	testing.expect(t, record.normalized >= 3)
	text := explain(&parsed.query, &schema)
	defer delete(text)
	testing.expect_value(t, text, "INTERSECT {\n  @t:UNION {\n    @t:RUN\n    @t:+RUN(expanded)\n    @t:RUNs(expanded)\n  }\n  @n:WALK\n  EXACT {\n    TWO\n    WORDS\n  }\n}\n")
}

@(test)
explain_lines_end_with_empty_line :: proc(t: ^testing.T) {
	schema, _ := test_schema("dl")
	defer delete(schema.fields)
	parsed, err := parse("hello | world foo", &schema, Options{dialect = 2, verbatim = true})
	defer parsed_destroy(parsed)
	testing.expect_value(t, err.code, Error_Code.None)
	lines, text := explain_lines(&parsed.query, &schema)
	defer delete(text)
	defer delete(lines)
	testing.expect_value(t, len(lines), 8)
	testing.expect_value(t, lines[0], "UNION {")
	testing.expect_value(t, lines[len(lines) - 1], "")
}

@(test)
errors_are_values :: proc(t: ^testing.T) {
	schema, _ := test_schema("e")
	defer delete(schema.fields)
	cases := [?]struct {
		query:   string,
		dialect: int,
		code:    Error_Code,
		reply:   string,
	} {
		{"hello world)", 1, .Syntax, "SEARCH_SYNTAX Syntax error at offset 11 near world"},
		{"*=>[KNN 2 @v $q]", 1, .Syntax, "SEARCH_SYNTAX Syntax error at offset 1 near >["},
		{"*=>[KNN 2 @v $q]", 2, .Param_Not_Found, "SEARCH_PARAM_NOT_FOUND Parameter not found `q`"},
		{"@zz:hello", 2, .Syntax, "SEARCH_SYNTAX Unknown field at offset 0 near zz"},
		{"@g:hello", 2, .Syntax, "SEARCH_SYNTAX Expected a TEXT field at offset 0 near g"},
		{"x=>{$weight:-1}", 2, .Syntax, "SEARCH_SYNTAX Invalid value (-1) for `weight`"},
		{"x=>{$bogus:1}", 2, .Option_Invalid, "SEARCH_OPTION_INVALID Invalid attribute bogus"},
	}
	for c in cases {
		parsed, err := parse(c.query, &schema, Options{dialect = c.dialect})
		reply := error_reply(err)
		testing.expectf(t, err.code == c.code && reply == c.reply, "%q: %v %q", c.query, err.code, reply)
		delete(reply)
		parsed_destroy(parsed)
	}
}

@(test)
dialects_three_and_four_parse_like_two :: proc(t: ^testing.T) {
	schema, _ := test_schema("dl")
	defer delete(schema.fields)
	queries := [?]string{"@t:hello world", "-hello world", "w'hel*'", "@g:{a b}", "x | (y | z)"}
	for query in queries {
		texts: [4]string
		for d in 2 ..= 4 {
			parsed, err := parse(query, &schema, Options{dialect = d, verbatim = true})
			testing.expect_value(t, err.code, Error_Code.None)
			texts[d - 1] = explain(&parsed.query, &schema)
			parsed_destroy(parsed)
		}
		testing.expect_value(t, texts[2], texts[1])
		testing.expect_value(t, texts[3], texts[1])
		for d in 1 ..< 4 {
			delete(texts[d])
		}
	}
}

@(test)
param_values_fill_the_tree :: proc(t: ^testing.T) {
	schema, _ := test_schema("q")
	defer delete(schema.fields)
	params := [?]Param{{"lo", "1"}, {"hi", "2.5"}, {"tag", "Light Blue"}, {"lon", "10"}, {"lat", "20"}, {"u", "mi"}}
	parsed, err := parse("@n:[$lo ($hi] @g:{$tag} @loc:[$lon $lat 5 $u]", &schema, Options{dialect = 2, params = params[:]})
	defer parsed_destroy(parsed)
	testing.expect_value(t, err.code, Error_Code.None)
	text := explain(&parsed.query, &schema)
	defer delete(text)
	testing.expect_value(t, text, "INTERSECT {\n  NUMERIC {1.000000 <= @n < 2.500000}\n  TAG:@g {\n    light blue\n  }\n  GEO loc:{10.000000,20.000000 --> 5.000000 mi}\n}\n")
	missing, merr := parse("@n:[$lo $nope]", &schema, Options{dialect = 2, params = params[:]})
	defer parsed_destroy(missing)
	testing.expect_value(t, merr.code, Error_Code.Param_Not_Found)
	testing.expect_value(t, merr.message, "Parameter not found `nope`")
}

@(test)
custom_stopwords_and_empty_query :: proc(t: ^testing.T) {
	schema, _ := test_schema("swc")
	defer delete(schema.fields)
	parsed, err := parse("the fox DOG", &schema, Options{dialect = 2, verbatim = true})
	defer parsed_destroy(parsed)
	testing.expect_value(t, err.code, Error_Code.None)
	text := explain(&parsed.query, &schema)
	defer delete(text)
	testing.expect_value(t, text, "the\n")
	empty, eerr := parse("", &schema, Options{dialect = 2})
	defer parsed_destroy(empty)
	testing.expect_value(t, eerr.code, Error_Code.None)
	testing.expect_value(t, node_get(&empty.query, empty.query.root).kind, Node_Kind.Null)
}

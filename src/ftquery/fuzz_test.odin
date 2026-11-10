package ftquery

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

FUZZ_FRAGMENTS := [?]string {
	"x",
	"y",
	"foo",
	"Hello",
	"the",
	"a",
	"5",
	"-5",
	"1.5",
	".5",
	"+5",
	"inf",
	"-inf",
	"1e5",
	"0x10",
	"x*",
	"*x",
	"*x*",
	"%x%",
	"%%x%%",
	"\"x y\"",
	"'x y'",
	"\"\"",
	"w'x*'",
	"w\"x*\"",
	"$p",
	"$vec",
	"$p*",
	"*$p",
	"@t:",
	"@u:",
	"@t|u:",
	"@g:",
	"@zz:",
	"@n:",
	"@g:{x}",
	"@g:{x|y}",
	"@g:{x y}",
	"@gc:{X}",
	"@g:{$p}",
	"@ge:{\"\"}",
	"@te:\"\"",
	"@n:[1 2]",
	"@n:[(1 +inf]",
	"@n:[5]",
	"@n:[$a $b]",
	"@loc:[1 2 3 km]",
	"@loc:[1 2 3 parsec]",
	"@n>=5",
	"@n<$a",
	"@shape:[WITHIN $pt]",
	"ismissing(@gm)",
	"(",
	")",
	"|",
	"-",
	"~",
	"=>{$weight:2}",
	"=>{$slop:1;$inorder:true}",
	"=>{$yield_distance_as:d}",
	"*",
	"=>[KNN 2 @v $vec]",
	"=>[KNN $k @h $vec EF_RUNTIME 5 AS d]",
	"=>[KNN 2 @v $vec HYBRID_POLICY ADHOC_BF]",
	"@v:[VECTOR_RANGE 1 $vec]",
	"@h:[VECTOR_RANGE $r $vec]=>{$EPSILON:0.5}",
	"{",
	"}",
	"[",
	"]",
	":",
	";",
	"\"",
	"%",
	"=>",
	"x\\-y",
	"\\",
	"\x00",
	"\xc3\xa9",
	"\xff",
}

FUZZ_SEPARATORS := [?]string{"", " ", " ", " ", "  ", "\t"}

fuzz_bytes := "xyzab05 ()|-~@:{}[]\"'*%$=>;,.\\!#&+/<?^_`tgnvh\x00\xc3\xa9"

FUZZ_PARAMS := [?]Param{{"p", "Pp"}, {"vec", "AAAAAAAA"}, {"a", "1"}, {"b", "7"}, {"k", "3"}, {"r", "0.5"}, {"pt", "POINT(1 2)"}, {"w", "3"}}

fuzz_schema :: proc() -> Schema {
	schema, _ := test_schema("q")
	return schema
}

Fuzz_Tally :: struct {
	parsed:   int,
	rejected: int,
}

node_shape_ok :: proc(q: ^Query, schema: ^Schema, id: Node_Id, depth: int) -> bool {
	if id < 0 || int(id) >= len(q.nodes) || depth > 2 * MAX_DEPTH {
		return false
	}
	n := &q.nodes[int(id)]
	for child in n.children {
		if !node_shape_ok(q, schema, child, depth + 1) {
			return false
		}
	}
	switch n.kind {
	case .Not, .Optional:
		return len(n.children) == 1
	case .Phrase:
		for child in n.children {
			if q.nodes[int(child)].kind != .Token {
				return false
			}
		}
	case .Numeric, .Geo, .Missing, .Geoshape:
		return n.field >= 0 && n.field < len(schema.fields)
	case .Vector:
		return n.vector != nil && n.vector.field >= 0 && n.vector.field < len(schema.fields) && len(n.children) <= 1
	case .Union, .Intersect:
		return len(n.children) >= 1
	case .Null, .Token, .Prefix, .Suffix, .Infix, .Wildcard_Pattern, .Fuzzy, .Tag, .Wildcard:
	}
	return true
}

fuzz_one :: proc(t: ^testing.T, schema: ^Schema, query: string, tally: ^Fuzz_Tally) {
	for dialect in 1 ..= 2 {
		for verbatim in ([?]bool{true, false}) {
			opts := Options {
				dialect       = dialect,
				verbatim      = verbatim,
				params        = FUZZ_PARAMS[:],
				hooks         = TEST_HOOKS,
				check_vectors = true,
			}
			parsed, err := parse(query, schema, opts)
			if err.code != .None {
				tally.rejected += 1
				reply := error_reply(err)
				testing.expectf(t, len(err.message) > 0 && strings.has_prefix(reply, ERROR_WORDS[err.code]), "bad error for %q: %q", query, reply)
				testing.expectf(t, parsed.query.root == NO_NODE, "error with a root for %q", query)
				delete(reply)
				parsed_destroy(parsed)
				continue
			}
			tally.parsed += 1
			ok := node_shape_ok(&parsed.query, schema, parsed.query.root, 0)
			testing.expectf(t, ok, "malformed tree for %q dialect %d", query, dialect)
			first := explain(&parsed.query, schema)
			testing.expectf(t, len(first) > 0 && first[len(first) - 1] == '\n', "explain of %q does not end with a newline", query)
			again, err2 := parse(query, schema, opts)
			testing.expectf(t, err2.code == .None, "second parse of %q failed", query)
			if err2.code == .None {
				second := explain(&again.query, schema)
				testing.expectf(t, first == second, "nondeterministic explain for %q", query)
				delete(second)
			}
			delete(first)
			parsed_destroy(again)
			parsed_destroy(parsed)
		}
	}
}

@(test)
fuzz_fragment_queries :: proc(t: ^testing.T) {
	schema := fuzz_schema()
	defer delete(schema.fields)
	random := Fuzz_Random{0x9E3779B97F4A7C15}
	tally: Fuzz_Tally
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for _ in 0 ..< 3000 {
		strings.builder_reset(&b)
		count := 1 + fuzz_below(&random, 7)
		for _ in 0 ..< count {
			strings.write_string(&b, FUZZ_FRAGMENTS[fuzz_below(&random, len(FUZZ_FRAGMENTS))])
			strings.write_string(&b, FUZZ_SEPARATORS[fuzz_below(&random, len(FUZZ_SEPARATORS))])
		}
		fuzz_one(t, &schema, strings.to_string(b), &tally)
	}
	testing.expect(t, tally.parsed > 1000)
	testing.expect(t, tally.rejected > 1000)
}

@(test)
fuzz_random_bytes :: proc(t: ^testing.T) {
	schema := fuzz_schema()
	defer delete(schema.fields)
	random := Fuzz_Random{0xD1B54A32D192ED03}
	tally: Fuzz_Tally
	buf: [32]u8
	for _ in 0 ..< 3000 {
		n := 1 + fuzz_below(&random, len(buf))
		for i in 0 ..< n {
			buf[i] = fuzz_bytes[fuzz_below(&random, len(fuzz_bytes))]
		}
		fuzz_one(t, &schema, string(buf[:n]), &tally)
	}
	testing.expect(t, tally.parsed > 100)
	testing.expect(t, tally.rejected > 100)
}

@(test)
fuzz_mutated_probes :: proc(t: ^testing.T) {
	schema := fuzz_schema()
	defer delete(schema.fields)
	random := Fuzz_Random{0x94D049BB133111EB}
	tally: Fuzz_Tally
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for _ in 0 ..< 3000 {
		source := PROBE_CASES[fuzz_below(&random, len(PROBE_CASES))].query
		if len(source) > 400 {
			continue
		}
		strings.builder_reset(&b)
		strings.write_string(&b, source)
		edits := 1 + fuzz_below(&random, 3)
		for _ in 0 ..< edits {
			text := strings.to_string(b)
			at := fuzz_below(&random, len(text) + 1)
			kind := fuzz_below(&random, 3)
			c := fuzz_bytes[fuzz_below(&random, len(fuzz_bytes))]
			head := strings.clone(text[:at])
			tail := strings.clone(text[at:])
			strings.builder_reset(&b)
			strings.write_string(&b, head)
			switch kind {
			case 0:
				strings.write_byte(&b, c)
				strings.write_string(&b, tail)
			case 1:
				if len(tail) > 0 {
					strings.write_string(&b, tail[1:])
				}
			case:
				strings.write_byte(&b, c)
				if len(tail) > 0 {
					strings.write_string(&b, tail[1:])
				}
			}
			delete(head)
			delete(tail)
		}
		fuzz_one(t, &schema, strings.to_string(b), &tally)
	}
	testing.expect(t, tally.parsed > 100)
	testing.expect(t, tally.rejected > 100)
}

@(test)
fuzz_deep_nesting :: proc(t: ^testing.T) {
	schema := fuzz_schema()
	defer delete(schema.fields)
	tally: Fuzz_Tally
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	shapes := [?][2]string{{"(", ")"}, {"-", ""}, {"~", ""}, {"@t:(", ")"}, {"-(", ")"}, {"x | ", ""}, {"x 5 ", ""}}
	for shape in shapes {
		for n in ([?]int{1, 98, 99, 100, 254, 255, 256, 1000, 4000}) {
			strings.builder_reset(&b)
			for _ in 0 ..< n {
				strings.write_string(&b, shape[0])
			}
			strings.write_string(&b, "x")
			for _ in 0 ..< n {
				strings.write_string(&b, shape[1])
			}
			fuzz_one(t, &schema, strings.to_string(b), &tally)
		}
	}
	testing.expect(t, tally.parsed > 0)
}

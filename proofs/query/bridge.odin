package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import fq "../../src/ftquery"

nat :: proc(s: string) -> int {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok && v >= 0)
	return int(v)
}

unhex :: proc(s: string) -> string {
	if s == "-" {
		return ""
	}
	out := make([]u8, len(s) / 2)
	for i in 0 ..< len(out) {
		v, ok := strconv.parse_u64(s[2 * i:2 * i + 2], 16)
		assert(ok)
		out[i] = u8(v)
	}
	return string(out)
}

write_outcome :: proc(b: ^strings.Builder, query: string, dialect: int, schema: ^fq.Schema) {
	opts := fq.Options {
		dialect  = dialect,
		verbatim = true,
	}
	parsed, err := fq.parse(query, schema, opts)
	defer fq.parsed_destroy(parsed)
	if err.code != .None {
		strings.write_string(b, "err|")
		strings.write_string(b, fq.error_reply(err))
		return
	}
	strings.write_string(b, "ok|")
	text := fq.explain(&parsed.query, schema)
	for c in transmute([]u8)text {
		strings.write_byte(b, '/' if c == '\n' else c)
	}
}

row :: proc(line: string, b: ^strings.Builder, schema: ^fq.Schema) {
	f := strings.split(line, " ")
	strings.builder_reset(b)
	switch f[0] {
	case "QL":
		query := unhex(f[2])
		lexer := fq.Lexer {
			text      = query,
			dialect   = nat(f[1]),
			schema    = schema,
			allocator = context.allocator,
		}
		tokens := make([dynamic]fq.Token)
		assert(fq.lex_all(&lexer, &tokens))
		strings.write_string(b, "QL|")
		for t, i in tokens {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			fmt.sbprintf(b, "%v:%d:%s:%s", t.kind, t.pos, t.text, t.near)
		}
	case "QP", "QR":
		strings.write_string(b, f[0])
		strings.write_byte(b, '|')
		write_outcome(b, unhex(f[2]), nat(f[1]), schema)
	case:
		panic("unknown case")
	}
}

main :: proc() {
	assert(len(os.args) == 2)
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	lines := strings.split(string(input), "\n")
	fields := []fq.Field{{name = "t", kind = .Text}}
	schema := fq.Schema {
		fields = fields,
	}
	b := strings.builder_make()
	for line in lines {
		if len(line) == 0 {
			continue
		}
		context.allocator = context.temp_allocator
		row(line, &b, &schema)
		fmt.println(strings.to_string(b))
		free_all(context.temp_allocator)
	}
}

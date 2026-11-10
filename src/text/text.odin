package text

MIN_STEM_LEN_DEFAULT :: 4

STEM_PREFIX :: u8('+')

TRIE_UNIT_LIMIT :: 255

Error :: enum u8 {
	None,
	Out_Of_Memory,
}

Token :: struct {
	text:  []u8,
	tail:  []u8,
	start: int,
	end:   int,
}

Tokenizer :: struct {
	data:  rawptr,
	reset: proc(data: rawptr, text: []u8),
	next:  proc(data: rawptr, token: ^Token) -> bool,
}

Normalize_Proc :: #type proc(text: []u8, tail: []u8, out: ^[dynamic]u8)

Stem_Proc :: #type proc "contextless" (word: []u8, out: []u8) -> (stem: []u8, ok: bool)

Term_Kind :: enum u8 {
	Original,
	Stem,
}

Term :: struct {
	offset:   u32,
	length:   u32,
	position: u32,
	start:    u32,
	end:      u32,
	kind:     Term_Kind,
}

Terms :: struct {
	list:  [dynamic]Term,
	bytes: [dynamic]u8,
}

terms_init :: proc(t: ^Terms, allocator := context.allocator) {
	t.list = make([dynamic]Term, allocator)
	t.bytes = make([dynamic]u8, allocator)
}

terms_clear :: proc(t: ^Terms) {
	clear(&t.list)
	clear(&t.bytes)
}

terms_destroy :: proc(t: ^Terms) {
	delete(t.list)
	delete(t.bytes)
	t^ = {}
}

term_bytes :: #force_inline proc "contextless" (t: ^Terms, term: Term) -> []u8 {
	return t.bytes[term.offset:][:term.length]
}

term_string :: #force_inline proc "contextless" (t: ^Terms, term: Term) -> string {
	return string(term_bytes(t, term))
}

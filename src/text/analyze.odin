package text

Field :: struct {
	language: Language,
	stem:     bool,
	base:     u32,
}

Analyzer :: struct {
	tokenizer: Tokenizer,
	normalize: Normalize_Proc,
	stop:      ^Stop_Words,
	stemmers:  ^Stemmers,
	min_stem:  int,
	doc:       Doc_Tokenizer,
	stem_buf:  [dynamic]u8,
}

DEFAULT_FIELD :: Field {
	language = DEFAULT_LANGUAGE,
	stem     = true,
}

analyzer_init :: proc(a: ^Analyzer, stop: ^Stop_Words = nil, stemmers: ^Stemmers = nil, allocator := context.allocator) {
	a^ = {}
	doc_tokenizer_init(&a.doc, allocator)
	a.tokenizer = doc_tokenizer(&a.doc)
	a.normalize = fold
	a.stop = stop
	a.stemmers = stemmers
	a.min_stem = MIN_STEM_LEN_DEFAULT
	a.stem_buf = make([dynamic]u8, allocator)
}

analyzer_destroy :: proc(a: ^Analyzer) {
	doc_tokenizer_destroy(&a.doc)
	delete(a.stem_buf)
	a^ = {}
}

field_stemmer :: proc "contextless" (a: ^Analyzer, field: Field) -> Stem_Proc {
	if !field.stem || a.stemmers == nil {
		return nil
	}
	return a.stemmers[field.language]
}

stem_term :: proc(a: ^Analyzer, stemmer: Stem_Proc, term: []u8) -> (stem: []u8, changed: bool) {
	want := 2 * len(term) + 16
	if len(a.stem_buf) < want {
		resize(&a.stem_buf, want)
	}
	for {
		s, ok := stemmer(term, a.stem_buf[:])
		if ok {
			return s, string(s) != string(term)
		}
		resize(&a.stem_buf, 2 * len(a.stem_buf))
	}
}

analyze :: proc(a: ^Analyzer, text: []u8, field: Field, out: ^Terms) -> (last: u32) {
	a.tokenizer.reset(a.tokenizer.data, text)
	stemmer := field_stemmer(a, field)
	position := field.base
	token: Token
	for a.tokenizer.next(a.tokenizer.data, &token) {
		offset := len(out.bytes)
		a.normalize(token.text, token.tail, &out.bytes)
		length := len(out.bytes) - offset
		if length > 0 && a.stop != nil && is_stop_word(a.stop, out.bytes[offset:]) {
			resize(&out.bytes, offset)
			continue
		}
		position += 1
		append(&out.list, Term{offset = u32(offset), length = u32(length), position = position, start = u32(token.start), end = u32(token.end), kind = .Original})
		if stemmer == nil || length < a.min_stem {
			continue
		}
		stem, changed := stem_term(a, stemmer, out.bytes[offset:][:length])
		if !changed {
			continue
		}
		soffset := len(out.bytes)
		append(&out.bytes, STEM_PREFIX)
		append(&out.bytes, ..stem)
		append(&out.list, Term{offset = u32(soffset), length = u32(len(stem) + 1), position = position, start = u32(token.start), end = u32(token.end), kind = .Stem})
	}
	return position
}

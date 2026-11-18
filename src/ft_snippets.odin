package main

import "core:mem"
import "core:strings"
import fi "ftindex"
import "text"

Search_Snippet_Options :: struct {
	on: bool,
	fields: [][]u8,
	tags: Maybe([2]string),
	separator: Maybe(string),
	fragments: Maybe(int),
	length: Maybe(int),
}

Search_Snippet :: struct {
	highlight, summary: Search_Snippet_Options,
}

search_snippet_parse :: proc(snippet: ^Search_Snippet, highlight: bool, argv: [][]u8, at: ^int, allocator: mem.Allocator) -> string {
	out := &snippet.highlight if highlight else &snippet.summary
	out.on = true
	for at^ < len(argv) {
		token := argv[at^]
		switch {
		case eq_nocase(token, "fields"):
			at^ += 1
			fields, err := search_counted_args(argv, at, "FIELDS", allocator)
			if err != "" { return err }
			out.fields = fields
		case highlight && eq_nocase(token, "tags"):
			if len(argv) - at^ < 3 {
				return "SEARCH_PARSE_ARGS TAGS requires two arguments"
			}
			out.tags = [2]string{string(argv[at^+1]), string(argv[at^+2])}
			at^ += 3
		case !highlight && eq_nocase(token, "separator"):
			if len(argv) - at^ < 2 {
				return search_argument_error("SEPARATOR", SEARCH_MISSING_ARGUMENT, allocator)
			}
			out.separator = string(argv[at^+1])
			at^ += 2
		case !highlight && (eq_nocase(token, "frags") || eq_nocase(token, "len")):
			frags := eq_nocase(token, "frags")
			name := "FRAGS" if frags else "LEN"
			if len(argv) - at^ < 2 { return search_argument_error(name, SEARCH_MISSING_ARGUMENT, allocator) }
			value, ok := search_number(argv[at^+1])
			if !ok { return search_argument_error(name, SEARCH_INVALID_ARGUMENT, allocator) }
			if value < 0 || value > i64(max(i32)) { return search_argument_error(name, SEARCH_ARGUMENT_BOUNDS, allocator) }
			if frags { out.fragments = int(value) } else { out.length = int(value) }
			at^ += 2
		case:
			return ""
		}
	}
	return ""
}

search_snippet_select :: proc(opt: ^Search_Snippet_Options, source, name: string) -> bool {
	if !opt.on {
		return false
	}
	if len(opt.fields) == 0 {
		return true
	}
	for field in opt.fields {
		if string(field) == source || string(field) == name {
			return true
		}
	}
	return false
}

search_snippet_validate :: proc(index: ^Search_Index, request: ^Search_Request) -> string {
	if index.spec.on_json && !request.has_return && !request.no_content &&
	   (request.snippet.highlight.on || request.snippet.summary.on) {
		return "SEARCH_QUERY_BAD HIGHLIGHT/SUMMARIZE on JSON indexes requires RETURN with explicit field names"
	}
	if request.has_return || request.no_content {
		return ""
	}
	variants := [2]^Search_Snippet_Options{&request.snippet.summary, &request.snippet.highlight}
	for variant in variants {
		for name in variant.fields {
			found := false
			for field in index.spec.definition.fields {
				if field.name == string(name) {
					found = true
					break
				}
			}
			if !found {
				return ft_error("SEARCH_PROP_NOT_FOUND No such property `", string(name), "`")
			}
		}
	}
	return ""
}

Search_Span :: struct {
	start, end: int,
}

search_snippet_value :: proc(index: ^Search_Index, snippet: ^Search_Snippet, row: ^Search_Row, source, name, value: string) -> string {
	variant := snippet.highlight.on || snippet.summary.on
	if !variant || value == "" {
		return value
	}
	highlight := search_snippet_select(&snippet.highlight, source, name)
	summary := search_snippet_select(&snippet.summary, source, name)
	if !highlight && !summary {
		return value
	}
	field: ^fi.Field
	for &item in index.spec.definition.fields {
		if item.kind == .Text && item.name == name && item.source == source {
			field = &item
			break
		}
	}
	if field == nil {
		return value
	}
	a := context.temp_allocator
	tok: text.Doc_Tokenizer
	text.doc_tokenizer_init(&tok, a)
	text.doc_tokenizer_reset(&tok, transmute([]u8)value)
	folded := make([dynamic]u8, a)
	words := make([dynamic]Search_Span, a)
	matches := make([dynamic]int, a)
	token: text.Token
	stemmers: text.Stemmers
	fi.install_stemmers(&stemmers)
	stemmer := stemmers[index.spec.definition.language]
	stem_buf := make([dynamic]u8, a)
	for text.doc_tokenizer_next(&tok, &token) {
		append(&words, Search_Span{token.start, token.end})
		clear(&folded)
		text.fold(token.text, token.tail, &folded)
		hit := false
		for match in row.matches {
			if match == string(folded[:]) {
				hit = true
				break
			}
			if !field.no_stem && stemmer != nil && len(match) > 0 && match[0] == text.STEM_PREFIX {
				resize(&stem_buf, 2 * len(folded) + 16)
				stem, ok := stemmer(folded[:], stem_buf[:])
				if ok && string(stem) == match[1:] {
					hit = true
					break
				}
			}
		}
		if hit {
			append(&matches, len(words) - 1)
		}
	}
	tags := snippet.highlight.tags.? or_else [2]string{"<b>", "</b>"}
	if !highlight {
		tags = {}
	}
	out := strings.builder_make(a)
	if !summary {
		search_snippet_append(&out, value, words[:], matches[:], {0, len(value)}, tags)
		return strings.to_string(out)
	}
	fragments := snippet.summary.fragments.? or_else 3
	separator := snippet.summary.separator.? or_else "... "
	length := min(10, snippet.summary.length.? or_else 20)
	if len(matches) == 0 {
		if len(words) != 0 && fragments > 0 {
			n := min(len(words), max(1, snippet.summary.length.? or_else 20))
			strings.write_string(&out, value[:words[n-1].end])
			strings.write_string(&out, separator)
		}
		return strings.to_string(out)
	}
	for at, emitted := 0, 0; at < len(matches) && emitted < fragments; emitted += 1 {
		next := at + 1
		for next < len(matches) && words[matches[next]].start - words[matches[next-1]].end <= 45 {
			next += 1
		}
		first, last := matches[at], matches[next-1]
		span := Search_Span{words[first].start, words[last].end}
		for i := first - 1; i >= 0 && words[first].start - words[i].start <= length; i -= 1 {
			span.start = words[i].start
		}
		for i := last + 1; i < len(words) && words[i].end - words[last].end < length; i += 1 {
			span.end = words[i].end
		}
		search_snippet_append(&out, value, words[:], matches[at:next], span, tags)
		strings.write_string(&out, separator)
		at = next
	}
	return strings.to_string(out)
}

search_snippet_append :: proc(out: ^strings.Builder, value: string, words: []Search_Span, matches: []int, span: Search_Span, tags: [2]string) {
	at := span.start
	for match in matches {
		word := words[match]
		if word.start < span.start || word.end > span.end {
			continue
		}
		strings.write_string(out, value[at:word.start])
		strings.write_string(out, tags[0])
		strings.write_string(out, value[word.start:word.end])
		strings.write_string(out, tags[1])
		at = word.end
	}
	strings.write_string(out, value[at:span.end])
}

package ftindex

import "core:mem"
import ftq "../ftquery"
import "../text"

Query_Options :: struct {
	dialect:       int,
	params:        []ftq.Param,
	verbatim:      bool,
	no_stop_words: bool,
	language:      string,
}

build_query_schema :: proc(ix: ^Index) -> Error {
	def := &ix.definition
	fields, fe := make([]ftq.Field, len(def.fields), ix.allocator)
	if fe != nil {
		return .Out_Of_Memory
	}
	for f, i in def.fields {
		opts: ftq.Field_Options
		if f.no_stem {
			opts += {.No_Stem}
		}
		if f.index_missing {
			opts += {.Index_Missing}
		}
		if f.index_empty {
			opts += {.Index_Empty}
		}
		if f.case_sensitive {
			opts += {.Case_Sensitive}
		}
		blob := 0
		if f.kind == .Vector {
			blob = f.vector.dim * vector_elem_size(f.vector.elem)
		}
		fields[i] = ftq.Field {
			name      = f.name,
			kind      = ftq.Field_Kind(f.kind),
			options   = opts,
			method    = ftq.Vector_Method(f.vector.method),
			blob_size = blob,
		}
	}
	ix.query_fields = fields
	ix.query_schema = ftq.Schema{fields = fields}
	if def.stop_mode != .Default {
		listed := text.stop_words_list(&ix.stop)
		words, we := make([]string, len(listed), ix.allocator)
		if we != nil {
			return .Out_Of_Memory
		}
		copy(words, listed)
		ix.query_schema.stopwords = words
		ix.query_schema.custom_stopwords = true
	}
	ix.no_stop = ftq.Schema{fields = fields, custom_stopwords = true}
	return .None
}

query_normalize :: proc(user: rawptr, s: string, allocator: mem.Allocator) -> string {
	out := make([dynamic]u8, 0, len(s), allocator)
	text.fold(transmute([]u8)s, nil, &out)
	return string(out[:])
}

query_expand :: proc(user: rawptr, term: string, language: string, allocator: mem.Allocator) -> []string {
	ix := (^Index)(user)
	lang, ok := text.language_parse(transmute([]u8)language)
	if !ok {
		lang = ix.definition.language
	}
	stemmer := ix.stemmers[lang]
	if stemmer == nil || len(term) == 0 {
		return nil
	}
	buf := make([]u8, 2 * len(term) + 16, context.temp_allocator)
	stem: []u8
	for {
		s, done := stemmer(transmute([]u8)term, buf)
		if done {
			stem = s
			break
		}
		buf = make([]u8, 2 * len(buf), context.temp_allocator)
	}
	plus := make([]u8, len(stem) + 1, allocator)
	plus[0] = text.STEM_PREFIX
	copy(plus[1:], stem)
	if string(stem) == term {
		out := make([]string, 1, allocator)
		out[0] = string(plus)
		return out
	}
	out := make([]string, 2, allocator)
	out[0] = string(plus)
	bare := make([]u8, len(stem), allocator)
	copy(bare, stem)
	out[1] = string(bare)
	return out
}

query_hooks :: proc(ix: ^Index) -> ftq.Hooks {
	return ftq.Hooks{user = ix, normalize = query_normalize, expand = query_expand}
}

language_name :: proc(ix: ^Index, requested: string) -> string {
	if len(requested) > 0 {
		return requested
	}
	return text.language_name(ix.definition.language)
}

parse :: proc(ix: ^Index, query: string, opts: Query_Options, allocator := context.allocator) -> (^ftq.Parsed, ftq.Error) {
	schema := &ix.no_stop if opts.no_stop_words else &ix.query_schema
	o := ftq.Options {
		dialect       = opts.dialect,
		verbatim      = opts.verbatim,
		language      = language_name(ix, opts.language),
		params        = opts.params,
		hooks         = query_hooks(ix),
		check_vectors = false,
	}
	return ftq.parse(query, schema, o, allocator)
}

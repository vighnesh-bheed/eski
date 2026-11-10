package ftquery

import "core:mem"

Field_Kind :: enum u8 {
	Text,
	Tag,
	Numeric,
	Geo,
	Vector,
	Geoshape,
}

Field_Option :: enum u8 {
	No_Stem,
	Index_Missing,
	Index_Empty,
	Case_Sensitive,
}

Field_Options :: bit_set[Field_Option;u8]

Vector_Method :: enum u8 {
	Flat,
	Hnsw,
	Svs_Vamana,
}

Field :: struct {
	name:      string,
	kind:      Field_Kind,
	options:   Field_Options,
	method:    Vector_Method,
	blob_size: int,
}

Schema :: struct {
	fields:           []Field,
	stopwords:        []string,
	custom_stopwords: bool,
}

Param :: struct {
	name:  string,
	value: string,
}

Normalize_Proc :: #type proc(user: rawptr, text: string, allocator: mem.Allocator) -> string

Expand_Proc :: #type proc(user: rawptr, term: string, language: string, allocator: mem.Allocator) -> []string

Hooks :: struct {
	user:      rawptr,
	normalize: Normalize_Proc,
	expand:    Expand_Proc,
}

Options :: struct {
	dialect:       int,
	verbatim:      bool,
	language:      string,
	params:        []Param,
	hooks:         Hooks,
	check_vectors: bool,
}

DEFAULT_STOPWORDS := [?]string {
	"a",
	"is",
	"the",
	"an",
	"and",
	"are",
	"as",
	"at",
	"be",
	"but",
	"by",
	"for",
	"if",
	"in",
	"into",
	"it",
	"no",
	"not",
	"of",
	"on",
	"or",
	"such",
	"that",
	"their",
	"then",
	"there",
	"these",
	"they",
	"this",
	"to",
	"was",
	"will",
	"with",
}

schema_field :: proc "contextless" (schema: ^Schema, name: string) -> (index: int, found: bool) {
	for field, i in schema.fields {
		if field.name == name {
			return i, true
		}
	}
	return -1, false
}

schema_is_stopword :: proc "contextless" (schema: ^Schema, word: string) -> bool {
	if schema.custom_stopwords {
		for s in schema.stopwords {
			if ascii_equal_fold(s, word) {
				return true
			}
		}
		return false
	}
	for s in DEFAULT_STOPWORDS {
		if s == word {
			return true
		}
	}
	return false
}

ascii_lower_byte :: #force_inline proc "contextless" (c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

ascii_equal_fold :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if ascii_lower_byte(a[i]) != ascii_lower_byte(b[i]) {
			return false
		}
	}
	return true
}

ascii_normalize :: proc(user: rawptr, text: string, allocator: mem.Allocator) -> string {
	needs := false
	for i in 0 ..< len(text) {
		if text[i] >= 'A' && text[i] <= 'Z' {
			needs = true
			break
		}
	}
	if !needs {
		return text
	}
	out, err := make([]u8, len(text), allocator)
	if err != nil {
		return text
	}
	for i in 0 ..< len(text) {
		out[i] = ascii_lower_byte(text[i])
	}
	return string(out)
}

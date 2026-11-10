package ftindex

import "base:runtime"
import "core:strings"
import ftq "../ftquery"
import "../doctable"
import "../label"
import "../numindex"
import "../postings"
import "../roaring"
import "../tagindex"
import "../termdict"
import "../termstats"
import "../text"
import "../vmath"

Error :: enum u8 {
	None,
	Out_Of_Memory,
	Invalid_Definition,
	Ids_Exhausted,
	Unsupported,
	Vector_Source,
	Too_Many_Terms,
	Query_Error,
	Blob_Size,
}

Field_Kind :: enum u8 {
	Text,
	Tag,
	Numeric,
	Geo,
	Vector,
	Geoshape,
}

Vector_Method :: enum u8 {
	Flat,
	Hnsw,
	Svs_Vamana,
}

Vector_Options :: struct {
	method:          Vector_Method,
	elem:            vmath.Elem,
	metric:          vmath.Metric,
	dim:             int,
	m:               int,
	ef_construction: int,
	ef_runtime:      int,
	epsilon:         f64,
}

Field :: struct {
	name:           string,
	source:         string,
	kind:           Field_Kind,
	weight:         f64,
	no_stem:        bool,
	sortable:       bool,
	no_index:       bool,
	separator:      u8,
	case_sensitive: bool,
	index_empty:    bool,
	index_missing:  bool,
	vector:         Vector_Options,
}

Definition :: struct {
	fields:         []Field,
	language:       text.Language,
	language_field: string,
	score:          f32,
	score_field:    string,
	stop_mode:      text.Stop_Mode,
	stop_words:     []string,
}

DEFAULT_SEPARATOR :: u8(',')

DEFAULT_SCORE :: f32(1)

HNSW_M_DEFAULT :: 16

HNSW_EF_CONSTRUCTION_DEFAULT :: 200

HNSW_EF_RUNTIME_DEFAULT :: 10

HNSW_EPSILON_DEFAULT :: 0.01

TEXT_FIELDS_MAX :: 128

Field_Errors :: struct {
	failures:   int,
	last_error: string,
	last_key:   string,
}

Tag_Index :: struct {
	values: tagindex.Field,
	stats:  termstats.Stats,
}

Slot :: struct {
	ordinal: int,
	tag:     ^Tag_Index,
	numbers: ^numindex.Index,
	vector:  ^Vector_Source,
	missing: roaring.Bitmap,
	errors:  Field_Errors,
}

Index :: struct {
	definition:   Definition,
	slots:        []Slot,
	text_fields:  []int,
	layout:       postings.Layout,
	docs:         doctable.Table,
	terms:        termdict.Dictionary,
	lists:        [dynamic]^postings.List,
	term_fields:  [dynamic]postings.Fields,
	stats:        termstats.Stats,
	stop:         text.Stop_Words,
	stemmers:     text.Stemmers,
	analyzer:     text.Analyzer,
	query_schema: ftq.Schema,
	query_fields: []ftq.Field,
	no_stop:      ftq.Schema,
	errors:       Field_Errors,
	records:      int,
	work:         Work,
	allocator:    runtime.Allocator,
}

Info :: struct {
	num_docs:               int,
	max_doc_id:             u32,
	num_terms:              int,
	num_records:            int,
	hash_indexing_failures: int,
	last_error:             string,
	last_key:               string,
}

Vector_Factory :: #type proc(ctx: rawptr, field: ^Field, allocator: runtime.Allocator) -> (Vector_Source, Error)

field_default :: proc "contextless" (name: string, kind: Field_Kind) -> Field {
	return Field{name = name, source = name, kind = kind, weight = 1, separator = DEFAULT_SEPARATOR}
}

definition_default :: proc "contextless" (fields: []Field) -> Definition {
	return Definition{fields = fields, language = text.DEFAULT_LANGUAGE, score = DEFAULT_SCORE, stop_mode = .Default}
}

valid_definition :: proc(d: ^Definition) -> bool {
	text_count := 0
	for f, i in d.fields {
		if len(f.name) == 0 || len(f.source) == 0 {
			return false
		}
		for g in d.fields[:i] {
			if g.name == f.name {
				return false
			}
		}
		switch f.kind {
		case .Text:
			text_count += 1
			if !(f.weight >= 0) {
				return false
			}
		case .Vector:
			if !vmath.dim_valid(f.vector.dim) || !vmath.family_supports(.Search, f.vector.elem, f.vector.metric) {
				return false
			}
		case .Tag, .Numeric, .Geo, .Geoshape:
		}
	}
	if text_count > TEXT_FIELDS_MAX {
		return false
	}
	return d.score >= 0 && d.score <= 1
}

clone_definition :: proc(d: ^Definition, allocator: runtime.Allocator) -> (out: Definition, err: Error) {
	out = d^
	fields, fe := make([]Field, len(d.fields), allocator)
	if fe != nil {
		return {}, .Out_Of_Memory
	}
	for f, i in d.fields {
		fields[i] = f
		fields[i].name = strings.clone(f.name, allocator)
		fields[i].source = strings.clone(f.source, allocator)
	}
	out.fields = fields
	out.language_field = strings.clone(d.language_field, allocator)
	out.score_field = strings.clone(d.score_field, allocator)
	words, we := make([]string, len(d.stop_words), allocator)
	if we != nil {
		return {}, .Out_Of_Memory
	}
	for w, i in d.stop_words {
		words[i] = strings.clone(w, allocator)
	}
	out.stop_words = words
	return out, .None
}

free_definition :: proc(d: ^Definition, allocator: runtime.Allocator) {
	for f in d.fields {
		delete(f.name, allocator)
		delete(f.source, allocator)
	}
	delete(d.fields, allocator)
	delete(d.language_field, allocator)
	delete(d.score_field, allocator)
	for w in d.stop_words {
		delete(w, allocator)
	}
	delete(d.stop_words, allocator)
	d^ = {}
}

init :: proc(ix: ^Index, def: Definition, factory: Vector_Factory = nil, factory_ctx: rawptr = nil, allocator := context.allocator) -> Error {
	d := def
	if !valid_definition(&d) {
		return .Invalid_Definition
	}
	ix^ = Index{allocator = allocator}
	owned, ce := clone_definition(&d, allocator)
	if ce != .None {
		return ce
	}
	ix.definition = owned
	slots, se := make([]Slot, len(owned.fields), allocator)
	if se != nil {
		free_definition(&ix.definition, allocator)
		return .Out_Of_Memory
	}
	ix.slots = slots
	texts := make([dynamic]int, 0, len(owned.fields), allocator)
	for &f, i in ix.definition.fields {
		s := &ix.slots[i]
		s.ordinal = -1
		roaring.init(&s.missing, allocator)
		switch f.kind {
		case .Text:
			s.ordinal = len(texts)
			append(&texts, i)
		case .Tag:
			s.tag = new(Tag_Index, allocator)
			tagindex.init(&s.tag.values, allocator)
			termstats.init(&s.tag.stats, allocator)
		case .Numeric:
			s.numbers = new(numindex.Index, allocator)
			numindex.init(s.numbers, allocator)
		case .Vector:
			make_source: Vector_Factory = default_factory
			if factory != nil {
				make_source = factory
			}
			source, ve := make_source(factory_ctx, &f, allocator)
			if ve != .None {
				delete(texts)
				destroy(ix)
				return ve
			}
			s.vector = new(Vector_Source, allocator)
			s.vector^ = source
		case .Geo, .Geoshape:
		}
	}
	ix.text_fields = texts[:]
	ix.layout = postings.layout_make(len(texts), true)
	doctable.init(&ix.docs, allocator)
	termdict.init(&ix.terms, allocator)
	ix.lists = make([dynamic]^postings.List, 0, 0, allocator)
	ix.term_fields = make([dynamic]postings.Fields, 0, 0, allocator)
	termstats.init(&ix.stats, allocator)
	stop_err: text.Error
	switch ix.definition.stop_mode {
	case .Default:
		stop_err = text.stop_words_default(&ix.stop, allocator)
	case .None:
		stop_err = text.stop_words_none(&ix.stop, allocator)
	case .Custom:
		words := make([][]u8, len(ix.definition.stop_words), context.temp_allocator)
		for w, i in ix.definition.stop_words {
			words[i] = transmute([]u8)w
		}
		stop_err = text.stop_words_custom(&ix.stop, words, allocator)
	}
	if stop_err != .None {
		destroy(ix)
		return .Out_Of_Memory
	}
	install_stemmers(&ix.stemmers)
	text.analyzer_init(&ix.analyzer, &ix.stop, &ix.stemmers, allocator)
	work_init(&ix.work, allocator)
	if e := build_query_schema(ix); e != .None {
		destroy(ix)
		return e
	}
	return .None
}

destroy :: proc(ix: ^Index) {
	a := ix.allocator
	for &s in ix.slots {
		roaring.destroy(&s.missing)
		if s.tag != nil {
			tagindex.destroy(&s.tag.values)
			termstats.destroy(&s.tag.stats)
			free(s.tag, a)
		}
		if s.numbers != nil {
			numindex.destroy(s.numbers)
			free(s.numbers, a)
		}
		if s.vector != nil {
			if s.vector.destroy != nil {
				s.vector.destroy(s.vector.ctx)
			}
			free(s.vector, a)
		}
		delete(s.errors.last_error, a)
		delete(s.errors.last_key, a)
	}
	delete(ix.slots, a)
	delete(ix.text_fields, a)
	for l in ix.lists {
		if l != nil {
			postings.destroy(l)
			free(l, a)
		}
	}
	delete(ix.lists)
	delete(ix.term_fields)
	doctable.destroy(&ix.docs)
	termdict.destroy(&ix.terms)
	termstats.destroy(&ix.stats)
	text.stop_words_destroy(&ix.stop)
	text.analyzer_destroy(&ix.analyzer)
	work_destroy(&ix.work)
	delete(ix.query_fields, a)
	delete(ix.query_schema.stopwords, a)
	delete(ix.errors.last_error, a)
	delete(ix.errors.last_key, a)
	free_definition(&ix.definition, a)
	ix^ = {}
}

info :: proc "contextless" (ix: ^Index) -> Info {
	return Info {
		num_docs = doctable.count(&ix.docs),
		max_doc_id = doctable.max_id(&ix.docs),
		num_terms = termdict.count(&ix.terms),
		num_records = ix.records,
		hash_indexing_failures = ix.errors.failures,
		last_error = ix.errors.last_error,
		last_key = ix.errors.last_key,
	}
}

field_errors :: proc "contextless" (ix: ^Index, field: int) -> Field_Errors {
	return ix.slots[field].errors
}

field_index :: proc "contextless" (ix: ^Index, name: string) -> (int, bool) {
	for f, i in ix.definition.fields {
		if f.name == name {
			return i, true
		}
	}
	return -1, false
}

tag_values :: proc(ix: ^Index, field: int, out: ^[dynamic]string, visibility: ^label.Visibility = nil) -> Error {
	s := &ix.slots[field]
	if s.tag == nil {
		return .Invalid_Definition
	}
	it: termdict.Iterator
	termdict.iterator_seek(&it, &s.tag.values.values, "")
	defer termdict.iterator_close(&it)
	for {
		value, id, ok := termdict.iterator_next(&it)
		if !ok {
			break
		}
		if visibility != nil && termstats.term_visible(&s.tag.stats, u32(id), visibility) == 0 {
			continue
		}
		if _, e := append(out, value); e != nil {
			return .Out_Of_Memory
		}
	}
	return .None
}

vector_count :: proc(ix: ^Index, field: int) -> int {
	s := &ix.slots[field]
	if s.vector == nil || s.vector.count == nil {
		return 0
	}
	return s.vector.count(s.vector.ctx)
}

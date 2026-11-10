package ftindex

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import ftq "../ftquery"
import "../doctable"
import "../text"

Rec_Op_Kind :: enum u8 {
	Create,
	Drop,
	Upsert,
	Delete,
	Reject,
	Rename,
	Search,
	Aggregate,
	Hybrid,
	Info,
}

Rec_Value :: struct {
	name:  string,
	value: string,
}

Rec_Op :: struct {
	kind:   Rec_Op_Kind,
	index:  string,
	key:    string,
	to:     string,
	values: []Rec_Value,
	ref:    int,
}

Rec_Unit :: struct {
	name: string,
	ops:  []Rec_Op,
}

Rec_Spec :: struct {
	name:           string,
	fields:         []Field,
	language:       text.Language,
	language_field: string,
	score:          f32,
	score_field:    string,
	stop_mode:      text.Stop_Mode,
	stop_words:     []string,
}

Rec_Distance :: struct {
	key:   string,
	alias: string,
	value: string,
}

Rec_Search :: struct {
	id:            int,
	index:         string,
	query:         string,
	dialect:       int,
	slop:          int,
	scorer:        string,
	language:      string,
	params:        []ftq.Param,
	offset:        int,
	count:         int,
	verbatim:      bool,
	no_stop_words: bool,
	in_order:      bool,
	with_scores:   bool,
	sort_by:       string,
	sort_desc:     bool,
	error:         string,
	total:         int,
	keys:          []string,
	scores:        []string,
	distances:     []Rec_Distance,
	note:          string,
}

Rec_Aggregate :: struct {
	id:        int,
	index:     string,
	query:     string,
	dialect:   int,
	params:    []ftq.Param,
	scorer:    string,
	aliases:   []string,
	rows:      [][]Rec_Value,
	addscores: bool,
	sort_by:   string,
	note:      string,
}

Rec_Hybrid_Row :: struct {
	key:    string,
	fused:  string,
	text:   string,
	vector: string,
}

Rec_Hybrid :: struct {
	id:         int,
	index:      string,
	query:      string,
	field:      string,
	blob:       string,
	k:          int,
	radius:     f64,
	epsilon:    f64,
	ef_runtime: int,
	window:     int,
	constant:   f64,
	offset:     int,
	count:      int,
	total:      int,
	rows:       []Rec_Hybrid_Row,
	note:       string,
	range:      bool,
	filter:     string,
	has_text:   bool,
	has_vector: bool,
}

Rec_Info :: struct {
	id:          int,
	index:       string,
	num_docs:    int,
	max_doc_id:  int,
	num_terms:   int,
	num_records: int,
	failures:    int,
}

Gap :: enum u8 {
	None,
	Algorithm_Not_Built,
	Scorer_Not_Built,
	Dialect_Four,
	Stemmer_Not_Built,
	Prefix_Heap_Order,
	Command_Layer,
	Geo_Not_Indexed,
}

GAP_NAMES := [Gap]string {
	.None                = "",
	.Algorithm_Not_Built = "matcher or field algorithm not built (suffix, infix, fuzzy, wildcard pattern, geo)",
	.Scorer_Not_Built    = "scorer not built (TFIDF and the others): result sets compared, order and scores not",
	.Dialect_Four        = "dialect 4 total and order semantics (deprecated, not served)",
	.Stemmer_Not_Built   = "stemmer for the language not built (only English)",
	.Prefix_Heap_Order   = "prefix union above 20 expansions picks another child",
	.Command_Layer       = "argument errors raised by the command layer (SORTBY, LIMIT, RETURN, PARAMS)",
	.Geo_Not_Indexed     = "GEO values are not indexed, so num_records lacks one record per GEO value",
}

Tally :: struct {
	cases:             int,
	matched:           int,
	errors_matched:    int,
	scores_checked:    int,
	distances_checked: int,
	rows_checked:      int,
	gaps:              [Gap]int,
	gap_ids:           [Gap][dynamic]int,
	failures:          [dynamic]string,
}

Data_Set :: struct {
	units:      []Rec_Unit,
	specs:      []Rec_Spec,
	searches:   []Rec_Search,
	aggregates: []Rec_Aggregate,
	hybrids:    []Rec_Hybrid,
	infos:      []Rec_Info,
}

Replay :: struct {
	indexes: map[string]^Index,
	values:  map[string]map[string][]Rec_Value,
	tally:   ^Tally,
	data:    ^Data_Set,
}

spec_definition :: proc(s: Rec_Spec) -> Definition {
	return Definition{fields = s.fields, language = s.language, language_field = s.language_field, score = s.score, score_field = s.score_field, stop_mode = s.stop_mode, stop_words = s.stop_words}
}

replay_drop :: proc(r: ^Replay, name: string) {
	if ix, ok := r.indexes[name]; ok {
		destroy(ix)
		free(ix)
		delete_key(&r.indexes, name)
	}
	if vals, ok := &r.values[name]; ok {
		delete(vals^)
		delete_key(&r.values, name)
	}
}

replay_clear :: proc(r: ^Replay) {
	names := make([dynamic]string, context.temp_allocator)
	for k in r.indexes {
		append(&names, k)
	}
	for k in names {
		replay_drop(r, k)
	}
}

doc_key :: proc(ix: ^Index, id: u32) -> string {
	d := doctable.get(&ix.docs, id)
	if d == nil {
		return ""
	}
	return d.key
}

fail_case :: proc(r: ^Replay, id: int, format: string, args: ..any) {
	append(&r.tally.failures, fmt.aprintf("case %d: %s", id, fmt.tprintf(format, ..args)))
}

gap_of :: proc(r: ^Replay, query: string, scorer: string, dialect: int, language: string, index: string) -> Gap {
	if dialect == 4 {
		return .Dialect_Four
	}
	ix := r.indexes[index]
	if ix != nil && (ix.definition.language != .English || len(ix.definition.language_field) > 0) {
		return .Stemmer_Not_Built
	}
	if len(language) > 0 && !ftq.ascii_equal_fold(language, "english") {
		return .Stemmer_Not_Built
	}
	if len(scorer) > 0 && scorer != "BM25STD" {
		return .Scorer_Not_Built
	}
	return .None
}

command_layer_error :: proc(e: string) -> bool {
	for p in ([?]string{"SEARCH_PROP_NOT_FOUND", "SEARCH_ARG_UNRECOGNIZED", "SEARCH_INDEX_NOT_FOUND", "SEARCH_ADD_ARGS", "ERR "}) {
		if strings.has_prefix(e, p) {
			return true
		}
	}
	return strings.has_prefix(e, "SEARCH_PARSE_ARGS") && !strings.contains(e, "range:")
}

note_gap :: proc(r: ^Replay, g: Gap, id: int) {
	r.tally.gaps[g] += 1
	append(&r.tally.gap_ids[g], id)
}

Sort_Item :: struct {
	hit:     Hit,
	missing: bool,
	number:  f64,
	text:    string,
}

sort_value :: proc(r: ^Replay, ix: ^Index, index: string, res: ^Result, name: string, h: Hit) -> Sort_Item {
	item := Sort_Item{hit = h}
	if knn_alias_is(ix, res, name) {
		item.number = h.distance
		return item
	}
	for y in res.yields {
		if y.alias == name {
			for vh in y.hits {
				if vh.doc == h.doc {
					item.number = vh.distance
					return item
				}
			}
			item.missing = true
			return item
		}
	}
	field, found := field_index(ix, name)
	if !found {
		item.missing = true
		return item
	}
	f := ix.definition.fields[field]
	vals := r.values[index][doc_key(ix, h.doc)]
	for v in vals {
		if v.name == f.source {
			if f.kind == .Numeric {
				n, ok := number_parse(v.value)
				item.number = n
				item.missing = !ok
			} else {
				item.text = strings.to_lower(v.value, context.temp_allocator)
			}
			return item
		}
	}
	item.missing = true
	return item
}

sort_before :: proc(a, b: Sort_Item) -> bool {
	if a.missing != b.missing {
		return b.missing
	}
	if a.text != b.text {
		return a.text < b.text
	}
	if a.number != b.number {
		return a.number < b.number
	}
	return a.hit.doc < b.hit.doc
}

ordered_hits :: proc(r: ^Replay, ix: ^Index, index: string, res: ^Result, sort_by: string, desc: bool) -> []Hit {
	if len(sort_by) == 0 {
		return res.hits[:]
	}
	items := make([]Sort_Item, len(res.hits), context.temp_allocator)
	for h, i in res.hits {
		items[i] = sort_value(r, ix, index, res, sort_by, h)
	}
	slice.sort_by(items, sort_before)
	if desc {
		slice.reverse(items)
	}
	out := make([]Hit, len(items), context.temp_allocator)
	for it, i in items {
		out[i] = it.hit
	}
	return out
}

knn_alias_is :: proc(ix: ^Index, res: ^Result, alias: string) -> bool {
	if !res.knn {
		return false
	}
	if len(res.knn_alias) > 0 {
		return alias == res.knn_alias
	}
	return alias == fmt.tprintf("__%s_score", ix.definition.fields[res.knn_field].name)
}

hit_distance :: proc(ix: ^Index, res: ^Result, alias: string, doc: u32) -> (f64, bool) {
	for y in res.yields {
		if y.alias == alias {
			for vh in y.hits {
				if vh.doc == doc {
					return vh.distance, true
				}
			}
		}
	}
	if knn_alias_is(ix, res, alias) {
		for h in res.hits {
			if h.doc == doc {
				return h.distance, true
			}
		}
	}
	return 0, false
}

run_search :: proc(r: ^Replay, c: ^Rec_Search) {
	r.tally.cases += 1
	ix := r.indexes[c.index]
	gap := gap_of(r, c.query, c.scorer, c.dialect, c.language, c.index)
	if command_layer_error(c.error) {
		note_gap(r, .Command_Layer, c.id)
		return
	}
	if gap == .Dialect_Four {
		note_gap(r, gap, c.id)
		return
	}
	parsed, perr := parse(ix, c.query, Query_Options{dialect = c.dialect, params = c.params, verbatim = c.verbatim, no_stop_words = c.no_stop_words, language = c.language})
	defer ftq.parsed_destroy(parsed)
	if perr.code != .None {
		got := ftq.error_reply(perr, context.temp_allocator)
		if got == c.error {
			r.tally.matched += 1
			r.tally.errors_matched += 1
			return
		}
		fail_case(r, c.id, "parse error %q, want %q (%s)", got, c.error if len(c.error) > 0 else "results", c.query)
		return
	}
	opts := Execute_Options{in_order = c.in_order}
	if c.slop >= 0 {
		opts.slop = c.slop
	}
	res, err, qerr := execute(ix, parsed, opts)
	defer result_destroy(&res)
	if err == .Query_Error {
		got := ftq.error_reply(qerr, context.temp_allocator)
		if got == c.error {
			r.tally.matched += 1
			r.tally.errors_matched += 1
			return
		}
		fail_case(r, c.id, "query error %q, want %q (%s)", got, c.error, c.query)
		return
	}
	if err == .Unsupported {
		note_gap(r, .Algorithm_Not_Built, c.id)
		return
	}
	if err != .None {
		fail_case(r, c.id, "execute error %v (%s)", err, c.query)
		return
	}
	if len(c.error) > 0 {
		fail_case(r, c.id, "results, want error %q (%s)", c.error, c.query)
		return
	}
	if gap == .Stemmer_Not_Built {
		note_gap(r, gap, c.id)
		return
	}
	if res.total != c.total {
		fail_case(r, c.id, "total %d, want %d (%s) %s", res.total, c.total, c.query, c.note)
		return
	}
	hits := ordered_hits(r, ix, c.index, &res, c.sort_by, c.sort_desc)
	lo := min(c.offset, len(hits))
	hi := min(c.offset + c.count, len(hits))
	window := hits[lo:hi]
	if len(window) != len(c.keys) {
		fail_case(r, c.id, "%d keys, want %d (%s)", len(window), len(c.keys), c.query)
		return
	}
	if gap == .Scorer_Not_Built {
		if c.total <= c.count {
			got := make([]string, len(window), context.temp_allocator)
			for h, i in window {
				got[i] = doc_key(ix, h.doc)
			}
			if !slice.equal(sorted_strings(got), sorted_strings(c.keys)) {
				fail_case(r, c.id, "key set %v, want %v (%s)", got, c.keys, c.query)
				return
			}
		}
		note_gap(r, gap, c.id)
		return
	}
	for h, i in window {
		k := doc_key(ix, h.doc)
		if k != c.keys[i] {
			fail_case(r, c.id, "rank %d is %s, want %s (%s) %s", i, k, c.keys[i], c.query, c.note)
			return
		}
	}
	if c.with_scores && len(c.sort_by) == 0 {
		for h, i in window {
			want, ok := strconv.parse_f64(c.scores[i])
			if !ok || !(h.score == want || (math.is_inf(want) && h.score == want)) {
				fail_case(r, c.id, "rank %d score %.17g, want %s (%s)", i, h.score, c.scores[i], c.query)
				return
			}
			r.tally.scores_checked += 1
		}
	}
	for d in c.distances {
		id, found := lookup(ix, d.key)
		if !found {
			fail_case(r, c.id, "distance key %s missing", d.key)
			return
		}
		v, has := hit_distance(ix, &res, d.alias, id)
		if !has {
			fail_case(r, c.id, "no distance %s for %s (%s)", d.alias, d.key, c.query)
			return
		}
		if g12(v) != d.value {
			fail_case(r, c.id, "distance %s of %s is %s, want %s", d.alias, d.key, g12(v), d.value)
			return
		}
		r.tally.distances_checked += 1
	}
	r.tally.matched += 1
}

row_value :: proc(row: []Rec_Value, name: string) -> (string, bool) {
	for v in row {
		if v.name == name {
			return v.value, true
		}
	}
	return "", false
}

run_aggregate :: proc(r: ^Replay, c: ^Rec_Aggregate) {
	r.tally.cases += 1
	ix := r.indexes[c.index]
	parsed, perr := parse(ix, c.query, Query_Options{dialect = c.dialect, params = c.params})
	defer ftq.parsed_destroy(parsed)
	if perr.code != .None {
		fail_case(r, c.id, "aggregate parse error %v", perr)
		return
	}
	res, err, _ := execute(ix, parsed, {})
	defer result_destroy(&res)
	if err != .None {
		fail_case(r, c.id, "aggregate execute error %v", err)
		return
	}
	signatures := make([dynamic]string, context.temp_allocator)
	for h in res.hits {
		sb := strings.builder_make(context.temp_allocator)
		for a in c.aliases {
			if d, ok := hit_distance(ix, &res, a, h.doc); ok {
				fmt.sbprintf(&sb, "%s=%s;", a, g12(d))
			}
		}
		if c.addscores {
			fmt.sbprintf(&sb, "__score=%s;", g12(h.score))
		}
		key := doc_key(ix, h.doc)
		fmt.sbprintf(&sb, "@%s", key)
		append(&signatures, strings.to_string(sb))
	}
	for row in c.rows {
		sb := strings.builder_make(context.temp_allocator)
		for a in c.aliases {
			if v, ok := row_value(row, a); ok {
				fmt.sbprintf(&sb, "%s=%s;", a, v)
			}
		}
		if c.addscores {
			if v, ok := row_value(row, "__score"); ok {
				fmt.sbprintf(&sb, "__score=%s;", v)
			}
		}
		want := strings.to_string(sb)
		key, has_key := row_value(row, "__key")
		found := -1
		for s, i in signatures {
			at := strings.last_index_byte(s, '@')
			if s[:at] == want && (!has_key || s[at + 1:] == key) {
				found = i
				break
			}
		}
		if found < 0 {
			fail_case(r, c.id, "aggregate row %s%s not produced (%s)", want, key, c.query)
			return
		}
		ordered_remove(&signatures, found)
		r.tally.rows_checked += 1
	}
	r.tally.matched += 1
}

run_hybrid :: proc(r: ^Replay, c: ^Rec_Hybrid) {
	r.tally.cases += 1
	ix := r.indexes[c.index]
	text_query, perr := parse(ix, c.query, Query_Options{dialect = 2})
	defer ftq.parsed_destroy(text_query)
	if perr.code != .None {
		fail_case(r, c.id, "hybrid parse error %v", perr)
		return
	}
	filter: ^ftq.Parsed
	if len(c.filter) > 0 {
		fe: ftq.Error
		filter, fe = parse(ix, c.filter, Query_Options{dialect = 2})
		if fe.code != .None {
			fail_case(r, c.id, "hybrid filter parse error %v", fe)
			return
		}
	}
	defer ftq.parsed_destroy(filter)
	field, _ := field_index(ix, c.field)
	vec := Hybrid_Vector{field = field, blob = transmute([]u8)c.blob, k = c.k, range = c.range, radius = c.radius, epsilon = c.epsilon, ef_runtime = c.ef_runtime, filter = filter}
	res, err, _ := hybrid(ix, text_query, vec, Hybrid_Options{window = c.window, constant = c.constant})
	defer hybrid_result_destroy(&res)
	if err != .None {
		fail_case(r, c.id, "hybrid error %v", err)
		return
	}
	if res.total != c.total {
		fail_case(r, c.id, "hybrid total %d, want %d (%s)", res.total, c.total, c.note)
		return
	}
	lo := min(c.offset, len(res.rows))
	hi := min(c.offset + c.count, len(res.rows))
	rows := res.rows[lo:hi]
	if len(rows) != len(c.rows) {
		fail_case(r, c.id, "hybrid %d rows, want %d", len(rows), len(c.rows))
		return
	}
	for row, i in rows {
		want := c.rows[i]
		k := doc_key(ix, row.doc)
		if k != want.key {
			fail_case(r, c.id, "hybrid rank %d is %s, want %s (%s)", i, k, want.key, c.note)
			return
		}
		if len(want.fused) > 0 && g12(row.score) != want.fused {
			fail_case(r, c.id, "hybrid rank %d fused %s, want %s", i, g12(row.score), want.fused)
			return
		}
		if c.has_text {
			got := g12(row.text_score) if row.in_text else ""
			if got != want.text {
				fail_case(r, c.id, "hybrid rank %d text %s, want %s", i, got, want.text)
				return
			}
		}
		if c.has_vector {
			got := g12(row.similarity) if row.in_vector else ""
			if got != want.vector {
				fail_case(r, c.id, "hybrid rank %d vector %s, want %s", i, got, want.vector)
				return
			}
		}
		r.tally.rows_checked += 1
	}
	r.tally.matched += 1
}

geo_values :: proc(r: ^Replay, ix: ^Index, index: string) -> int {
	n := 0
	for _, vals in r.values[index] {
		for f in ix.definition.fields {
			if f.kind != .Geo && f.kind != .Geoshape {
				continue
			}
			for v in vals {
				if v.name == f.source {
					n += 1
				}
			}
		}
	}
	return n
}

run_info :: proc(r: ^Replay, c: ^Rec_Info) {
	r.tally.cases += 1
	ix := r.indexes[c.index]
	got := info(ix)
	if ix.definition.language != .English || len(ix.definition.language_field) > 0 {
		note_gap(r, .Stemmer_Not_Built, c.id)
		return
	}
	if geo := geo_values(r, ix, c.index); geo > 0 && got.num_records + geo == c.num_records {
		note_gap(r, .Geo_Not_Indexed, c.id)
		got.num_records += geo
	}
	if (c.num_docs >= 0 && got.num_docs != c.num_docs) || (c.max_doc_id >= 0 && int(got.max_doc_id) != c.max_doc_id) || (c.num_terms >= 0 && got.num_terms != c.num_terms) || (c.num_records >= 0 && got.num_records != c.num_records) || (c.failures >= 0 && got.hash_indexing_failures != c.failures) {
		fail_case(r, c.id, "info %s docs %d/%d max %d/%d terms %d/%d records %d/%d failures %d/%d", c.index, got.num_docs, c.num_docs, got.max_doc_id, c.max_doc_id, got.num_terms, c.num_terms, got.num_records, c.num_records, got.hash_indexing_failures, c.failures)
		return
	}
	r.tally.matched += 1
}

replay_unit :: proc(t: ^testing.T, r: ^Replay, u: Rec_Unit) {
	for op in u.ops {
		switch op.kind {
		case .Create:
			s := r.data.specs[op.ref]
			ix := new(Index)
			e := init(ix, spec_definition(s), test_factory)
			if !testing.expectf(t, e == .None, "create %s: %v", s.name, e) {
				free(ix)
				continue
			}
			r.indexes[s.name] = ix
			r.values[s.name] = make(map[string][]Rec_Value)
		case .Drop:
			replay_drop(r, op.index)
		case .Upsert:
			ix := r.indexes[op.index]
			if ix == nil {
				continue
			}
			values := make([]Value, len(op.values), context.temp_allocator)
			for v, i in op.values {
				values[i] = Value{name = v.name, value = v.value}
			}
			_, e := add(ix, op.key, values)
			testing.expectf(t, e == .None, "add %s: %v", op.key, e)
			vals := &r.values[op.index]
			vals[op.key] = op.values
		case .Delete:
			if ix := r.indexes[op.index]; ix != nil {
				remove(ix, op.key)
			}
		case .Reject:
			if ix := r.indexes[op.index]; ix != nil {
				reject(ix, op.key)
			}
		case .Rename:
			if ix := r.indexes[op.index]; ix != nil {
				rename(ix, op.key, op.to)
				vals := &r.values[op.index]
				if v, ok := vals[op.key]; ok {
					delete_key(vals, op.key)
					vals[op.to] = v
				}
			}
		case .Search:
			run_search(r, &r.data.searches[op.ref])
		case .Aggregate:
			run_aggregate(r, &r.data.aggregates[op.ref])
		case .Hybrid:
			run_hybrid(r, &r.data.hybrids[op.ref])
		case .Info:
			run_info(r, &r.data.infos[op.ref])
		}
		free_all(context.temp_allocator)
	}
	replay_clear(r)
}

replay_data_set :: proc(t: ^testing.T, data: ^Data_Set, name: string) {
	tally: Tally
	r := Replay{tally = &tally, data = data}
	r.indexes = make(map[string]^Index)
	r.values = make(map[string]map[string][]Rec_Value)
	defer {
		delete(r.indexes)
		delete(r.values)
		for f in tally.failures {
			delete(f)
		}
		delete(tally.failures)
		for g in Gap {
			delete(tally.gap_ids[g])
		}
	}
	for u in data.units {
		replay_unit(t, &r, u)
	}
	for f in tally.failures {
		log.error(f)
	}
	log.infof("%s cases %d, matched %d (errors %d), scores %d, distances %d, rows %d", name, tally.cases, tally.matched, tally.errors_matched, tally.scores_checked, tally.distances_checked, tally.rows_checked)
	for g in Gap {
		if g != .None && tally.gaps[g] > 0 {
			log.infof("known gap: %d cases: %s %v", tally.gaps[g], GAP_NAMES[g], tally.gap_ids[g][:])
		}
	}
	testing.expectf(t, len(tally.failures) == 0, "%d %s cases do not match", len(tally.failures), name)
}

@(test)
recorded_cases_replay_through_the_index :: proc(t: ^testing.T) {
	data := Data_Set{units = RECORDED_UNITS[:], specs = RECORDED_SPECS[:], searches = RECORDED_SEARCHES[:], aggregates = RECORDED_AGGREGATES[:], hybrids = RECORDED_HYBRIDS[:], infos = RECORDED_INFOS[:]}
	replay_data_set(t, &data, "recorded")
}

@(test)
probed_cases_replay_through_the_index :: proc(t: ^testing.T) {
	data := Data_Set{units = PROBED_UNITS[:], specs = PROBED_SPECS[:], searches = PROBED_SEARCHES[:], aggregates = PROBED_AGGREGATES[:], hybrids = PROBED_HYBRIDS[:], infos = PROBED_INFOS[:]}
	replay_data_set(t, &data, "probed")
}

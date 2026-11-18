package ftindex

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import ftq "../ftquery"
import "../doctable"
import "../prefix"
import "../retrieve"
import "../termdict"
import "../termstats"

view_test_run :: proc(t: ^testing.T, ix: ^Index, query: string, params: []ftq.Param, options: Execute_Options) -> (Result, Error) {
	parsed, error := parse(ix, query, Query_Options{dialect = 2, verbatim = true, params = params})
	testing.expect_value(t, error.code, ftq.Error_Code.None)
	if parsed == nil {
		return {}, .Query_Error
	}
	defer ftq.parsed_destroy(parsed)
	res, e, _ := execute(ix, parsed, options)
	return res, e
}

View_Scorer :: struct {
	collection: retrieve.Collection,
	text_df, tag_df: u64,
}

view_scorer :: proc(state: ^View_Scorer) -> retrieve.Scorer {
	return retrieve.Scorer {
		ctx = state,
		begin = proc(ctx: rawptr, c: retrieve.Collection) {
			s := (^View_Scorer)(ctx)
			s^ = View_Scorer{collection = c}
		},
		prepare = proc(ctx: rawptr, term: retrieve.Term_Statistics) -> f64 {
			s := (^View_Scorer)(ctx)
			if term.kind == .Term {
				s.text_df = term.containing
			} else if term.kind == .Tag {
				s.tag_df = term.containing
			}
			return f64(term.containing)
		},
		term = proc(ctx: rawptr, leaf: ^retrieve.Leaf, hit: retrieve.Hit, doc: ^retrieve.Document) -> f64 {
			return leaf.prepared
		},
	}
}

@(test)
scoped_view_scores_use_visible_collection_and_field_frequencies :: proc(t: ^testing.T) {
	fields := [?]Field{
		field_default("t", .Text), field_default("other", .Text), field_default("g", .Tag), field_default("elsewhere", .Tag),
	}
	left, right, hidden, combined: Index
	for ix in ([]^Index{&left, &right, &hidden, &combined}) {
		testing.expect_value(t, init(ix, definition_default(fields[:]), scoped = ix != &combined), Error.None)
	}
	defer for ix in ([]^Index{&left, &right, &hidden, &combined}) {
		destroy(ix)
	}
	docs := []struct{key: string, target: ^Index, values: []Value}{
		{"a", &left, {{"t", "alpha alpha"}, {"g", "red"}}},
		{"b", &left, {{"t", "omega omega omega"}, {"elsewhere", "red"}}},
		{"e", &right, {{"t", "omega omega"}, {"g", "blue"}}},
		{"c", &right, {{"t", "alpha"}, {"g", "red"}}},
		{"d", &right, {{"other", "alpha"}, {"g", "blue"}, {"elsewhere", "red"}}},
		{"h", &hidden, {{"t", "alpha alpha alpha"}, {"g", "red"}}},
	}
	for doc in docs {
		_, e := add(doc.target, doc.key, doc.values)
		testing.expect_value(t, e, Error.None)
		if doc.target != &hidden {
			_, copy_error := add(&combined, doc.key, doc.values)
			testing.expect_value(t, copy_error, Error.None)
		}
	}
	indexes := [?]^Index{&right, &left}
	view := Execution_View{indexes = indexes[:]}
	query := "@t:alpha @g:{red}"
	whole, err := view_test_run(t, &combined, query, nil, {})
	defer result_destroy(&whole)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, whole.total, 2)
	scores := make(map[string]f64, context.temp_allocator)
	for hit in whole.hits {
		scores[doc_key(&combined, hit.doc)] = hit.score
	}
	for ix in indexes {
		part, part_error := view_test_run(t, ix, query, nil, Execute_Options{view = &view})
		testing.expect_value(t, part_error, Error.None)
		testing.expect_value(t, part.total, 1)
		for hit in part.hits {
			expected, found := scores[doc_key(ix, hit.doc)]
			testing.expect(t, found)
			testing.expect(t, math.abs(expected - hit.score) < 1e-12)
		}
		result_destroy(&part)

		state: View_Scorer
		scorer := view_scorer(&state)
		probe, probe_error := view_test_run(t, ix, query, nil, Execute_Options{view = &view, scorer = &scorer})
		testing.expect_value(t, probe_error, Error.None)
		testing.expect_value(t, state.collection.documents, u64(5))
		testing.expect_value(t, state.collection.total_length, u64(9))
		testing.expect_value(t, state.text_df, u64(3))
		testing.expect_value(t, state.tag_df, u64(2))
		result_destroy(&probe)
	}
	absent, absent_error := view_test_run(t, &hidden, query, nil, Execute_Options{view = &view})
	testing.expect_value(t, absent_error, Error.None)
	testing.expect_value(t, absent.total, 0)
	result_destroy(&absent)
}

@(test)
scoped_prefix_merges_unique_live_terms_before_the_limit :: proc(t: ^testing.T) {
	fields := [?]Field{field_default("t", .Text), field_default("g", .Tag), field_default("other", .Tag)}
	left, right: Index
	for ix in ([]^Index{&left, &right}) {
		testing.expect_value(t, init(ix, definition_default(fields[:]), scoped = true), Error.None)
	}
	defer destroy(&left)
	defer destroy(&right)
	boundary := prefix.LIMIT
	for i in 1 ..= boundary + 4 {
		word := fmt.tprintf("ab%03d", i)
		ix := &left if i % 2 == 0 else &right
		_, err := add(ix, word, []Value{{"t", word}, {"g", word}, {"other", "ab999"}})
		testing.expect_value(t, err, Error.None)
	}
	_, duplicate_error := add(&left, "duplicate", []Value{{"t", "ab001"}, {"g", "ab001"}})
	testing.expect_value(t, duplicate_error, Error.None)
	_, removed_error := add(&right, "removed", []Value{{"t", "ab000"}, {"g", "ab000"}})
	testing.expect_value(t, removed_error, Error.None)
	_, removed := remove(&right, "removed")
	testing.expect(t, removed && doctable.pending(&right.docs) == 1)
	text_id, text_found := termdict.lookup(&right.terms, "ab000")
	tag_id, tag_found := termdict.lookup(&right.slots[1].tag.values.values, "ab000")
	testing.expect(t, text_found && tag_found)
	testing.expect_value(t, termstats.term_total(&right.stats, u32(text_id)), u64(0))
	testing.expect_value(t, termstats.term_total(&right.slots[1].tag.stats, u32(tag_id)), u64(0))

	for a in ([]^Index{&left, &right}) {
		b := &right if a == &left else &left
		indexes := [?]^Index{a, b}
		view := Execution_View{indexes = indexes[:]}
		opts := Execute_Options{view = &view}
		for query in ([]string{"ab*", "@g:{ab*}"}) {
			for ix in indexes {
				result, err := view_test_run(t, ix, query, nil, opts)
				testing.expect_value(t, err, Error.None)
				testing.expect(t, result.truncated)
				testing.expect_value(t, result.total, boundary/2 + int(ix == &left))
				for hit in result.hits {
					name := doc_key(ix, hit.doc)
					testing.expect(t, name == "duplicate" || ("ab001" <= name && name <= "ab200"))
				}
				result_destroy(&result)
			}
		}
		minimum, minimum_error := view_test_run(t, a, "a*", nil, opts)
		testing.expect_value(t, minimum_error, Error.None)
		testing.expect(t, minimum.total == 0 && !minimum.truncated)
		result_destroy(&minimum)
	}
	indexes := [?]^Index{&left, &right}
	view := Execution_View{indexes = indexes[:]}
	params := prefix.params_default()
	matcher := prefix.matcher(&params)
	matchers: Matchers
	matchers[.Prefix] = &matcher
	custom, custom_error := view_test_run(t, &left, "ab*", nil, Execute_Options{view = &view, matchers = &matchers})
	testing.expect_value(t, custom_error, Error.None)
	testing.expect(t, !custom.truncated)
	testing.expect_value(t, custom.total, 103)
	result_destroy(&custom)

	cleared, collect_error := collect(&right)
	testing.expect_value(t, collect_error, Error.None)
	testing.expect_value(t, cleared, 1)
	_, text_found = termdict.lookup(&right.terms, "ab000")
	_, tag_found = termdict.lookup(&right.slots[1].tag.values.values, "ab000")
	testing.expect(t, !text_found && !tag_found)
}

View_Accept_State :: struct {
	calls: int,
	expire_after: int,
}

view_test_accept :: proc(ctx: rawptr, ix: ^Index, id: u32, key: string) -> bool {
	state := (^View_Accept_State)(ctx)
	state.calls += 1
	return !strings.has_prefix(key, "blocked")
}

view_test_timeout :: proc(ctx: rawptr) -> bool {
	state := (^View_Accept_State)(ctx)
	return state.expire_after >= 0 && state.calls >= state.expire_after
}

@(test)
scoped_acceptance_precedes_counting_and_vector_capacity :: proc(t: ^testing.T) {
	for method in ([]Vector_Method{.Flat, .Hnsw}) {
		fields := [?]Field{
			field_default("t", .Text),
			{name = "v", source = "v", kind = .Vector, weight = 1, separator = ',', vector = {method = method, elem = .F32, metric = .L2, dim = 2}},
		}
		ix: Index
		testing.expect_value(t, init(&ix, definition_default(fields[:]), scoped = true), Error.None)
		defer destroy(&ix)
		for key, i in ([]string{"blocked-nearest", "allowed-one", "allowed-two", "blocked-far"}) {
			value := [2]f32{f32(i), 0}
			_, err := add(&ix, key, []Value{{"t", "alpha"}, {"v", string(([^]u8)(&value)[:8])}})
			testing.expect_value(t, err, Error.None)
		}
		state := View_Accept_State{expire_after = -1}
		view := Execution_View{ctx = &state, accept = view_test_accept, timed_out = view_test_timeout}
		opts := Execute_Options{view = &view}
		plain, plain_error := view_test_run(t, &ix, "alpha", nil, Execute_Options{limit = 1, view = &view})
		testing.expect_value(t, plain_error, Error.None)
		testing.expect_value(t, plain.total, 2)
		testing.expect_value(t, len(plain.hits), 1)
		if len(plain.hits) == 1 {
			testing.expect_value(t, doc_key(&ix, plain.hits[0].doc), "allowed-one")
		}
		result_destroy(&plain)

		query_vector := [2]f32{0, 0}
		params := []ftq.Param{{name = "q", value = string(([^]u8)(&query_vector)[:8])}}
		for query in ([]string{"*=>[KNN 1 @v $q AS d]", "(alpha)=>[KNN 1 @v $q AS d]"}) {
			part, err := view_test_run(t, &ix, query, params, opts)
			testing.expect_value(t, err, Error.None)
			testing.expect(t, part.knn && part.total == 1 && len(part.hits) == 1)
			if len(part.hits) == 1 {
				testing.expect_value(t, doc_key(&ix, part.hits[0].doc), "allowed-one")
				testing.expect_value(t, part.hits[0].distance, 1.0)
			}
			result_destroy(&part)
		}
		range, range_error := view_test_run(t, &ix, "@v:[VECTOR_RANGE 16 $q]=>{$YIELD_DISTANCE_AS: d}", params, opts)
		testing.expect_value(t, range_error, Error.None)
		testing.expect_value(t, range.total, 2)
		testing.expect_value(t, len(range.yields), 1)
		if len(range.yields) == 1 {
			testing.expect_value(t, len(range.yields[0].hits), 2)
		}
		result_destroy(&range)

		for query in ([]string{"alpha", "*=>[KNN 1 @v $q]", "(alpha)=>[KNN 1 @v $q]"}) {
			state = {expire_after = 1}
			timed, deadline_error := view_test_run(t, &ix, query, params, opts)
			testing.expect_value(t, deadline_error, Error.Timeout)
			result_destroy(&timed)
		}
	}
}

@(test)
scoped_live_tracking_survives_replace_rename_and_collection :: proc(t: ^testing.T) {
	fields := [?]Field{field_default("t", .Text), field_default("g", .Tag)}
	scoped, ordinary: Index
	testing.expect_value(t, init(&scoped, definition_default(fields[:]), scoped = true), Error.None)
	testing.expect_value(t, init(&ordinary, definition_default(fields[:])), Error.None)
	defer destroy(&scoped)
	defer destroy(&ordinary)
	for ix in ([]^Index{&scoped, &ordinary}) {
		for key in ([]string{"kept", "replace", "rename-to"}) {
			_, err := add(ix, key, []Value{{"t", "alpha"}, {"g", "red"}})
			testing.expect_value(t, err, Error.None)
		}
		_, err := add(ix, "replace", []Value{{"t", "beta"}, {"g", "blue"}})
		testing.expect_value(t, err, Error.None)
		_, renamed := rename(ix, "replace", "rename-to")
		testing.expect(t, renamed)
	}
	for ix in ([]^Index{&scoped, &ordinary}) {
		term, found := termdict.lookup(&ix.terms, "alpha")
		testing.expect(t, found)
		df := termstats.term_total(&ix.stats, u32(term))
		testing.expect_value(t, df, u64(1 if ix == &scoped else 3))
		tag, tag_found := termdict.lookup(&ix.slots[1].tag.values.values, "red")
		testing.expect(t, tag_found)
		testing.expect_value(t, termstats.term_total(&ix.slots[1].tag.stats, u32(tag)), df)
	}
	legacy, legacy_error := view_test_run(t, &ordinary, "alpha", nil, {})
	testing.expect_value(t, legacy_error, Error.None)
	testing.expect_value(t, legacy.total, 1)
	result_destroy(&legacy)
	indexes := [?]^Index{&scoped, &ordinary}
	unsafe, unsafe_error := view_test_run(t, &scoped, "alpha", nil, Execute_Options{view = &Execution_View{indexes = indexes[:]}})
	testing.expect_value(t, unsafe_error, Error.Unsupported)
	testing.expect_value(t, unsafe.total, 0)
	result_destroy(&unsafe)

	for ix in indexes {
		cleared, err := collect(ix)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, cleared, 2)
		term, found := termdict.lookup(&ix.terms, "alpha")
		testing.expect(t, found)
		testing.expect_value(t, termstats.term_total(&ix.stats, u32(term)), u64(1))
		tag, tag_found := termdict.lookup(&ix.slots[1].tag.values.values, "red")
		testing.expect(t, tag_found)
		testing.expect_value(t, termstats.term_total(&ix.slots[1].tag.stats, u32(tag)), u64(1))
	}
}

@(test)
scoped_view_existing_visibility_hides_pending_deletes_and_callbacks :: proc(t: ^testing.T) {
	labels: Labelled_Index
	labelled_setup(&labels)
	defer labelled_teardown(&labels)
	fields := [?]Field{field_default("t", .Text)}
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:])), Error.None)
	defer destroy(&ix)
	_, open_error := add(&ix, "allowed", []Value{{"t", "alpha"}}, labels.open)
	_, hidden_error := add(&ix, "hidden-present", []Value{{"t", "alpha"}}, labels.secret)
	_, dead_error := add(&ix, "hidden-removed", []Value{{"t", "alpha"}}, labels.secret)
	testing.expect(t, open_error == .None && hidden_error == .None && dead_error == .None)
	_, removed := remove(&ix, "hidden-removed")
	testing.expect(t, removed)
	state := View_Accept_State{expire_after = -1}
	indexes := [?]^Index{&ix}
	view := Execution_View{indexes = indexes[:], ctx = &state, accept = view_test_accept}
	result, error := view_test_run(t, &ix, "al*", nil, Execute_Options{view = &view, visibility = &labels.reader})
	defer result_destroy(&result)
	testing.expect_value(t, error, Error.None)
	testing.expect_value(t, result.total, 1)
	testing.expect_value(t, state.calls, 1)
	if len(result.hits) == 1 {
		testing.expect_value(t, doc_key(&ix, result.hits[0].doc), "allowed")
	}
}

@(test)
scoped_vector_yield_rechecks_source_candidates :: proc(t: ^testing.T) {
	fields := [?]Field{
		{name = "v", source = "v", kind = .Vector, weight = 1, separator = ',', vector = {method = .Flat, elem = .F32, metric = .L2, dim = 2}},
	}
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:]), scoped = true), Error.None)
	defer destroy(&ix)
	value := [2]f32{0, 0}
	bytes := string(([^]u8)(&value)[:8])
	blocked, blocked_error := add(&ix, "blocked", []Value{{"v", bytes}})
	allowed, allowed_error := add(&ix, "allowed", []Value{{"v", bytes}})
	testing.expect(t, blocked_error == .None && allowed_error == .None)
	testing.expect(t, blocked.id == 1 && allowed.id == 2)
	ix.slots[0].vector.within = proc(ctx: rawptr, q: ^Vector_Query, out: ^[dynamic]Vector_Hit) -> Error {
		if _, error := append(out, Vector_Hit{1, 0}, Vector_Hit{2, 0}); error != nil {
			return .Out_Of_Memory
		}
		return .None
	}
	state := View_Accept_State{expire_after = -1}
	view := Execution_View{ctx = &state, accept = view_test_accept}
	params := []ftq.Param{{name = "q", value = bytes}}
	result, err := view_test_run(t, &ix, "@v:[VECTOR_RANGE 16 $q]=>{$YIELD_DISTANCE_AS: d}", params, Execute_Options{view = &view})
	defer result_destroy(&result)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, result.total, 1)
	testing.expect_value(t, len(result.yields), 1)
	if len(result.yields) == 1 {
		testing.expect_value(t, len(result.yields[0].hits), 1)
		if len(result.yields[0].hits) == 1 {
			testing.expect_value(t, result.yields[0].hits[0].doc, allowed.id)
		}
	}
}

package ftindex

import "core:fmt"
import "core:strings"
import "core:testing"
import ftq "../ftquery"
import "../retrieve"
import "../termdict"

suffix_scan :: proc(ctx: rawptr, d: ^termdict.Dictionary, pattern: string, limit: int, out: ^[dynamic]termdict.Id) -> (truncated: bool, err: termdict.Error) {
	it: termdict.Iterator
	termdict.iterator_seek(&it, d, "")
	defer termdict.iterator_close(&it)
	for {
		term, id, ok := termdict.iterator_next(&it)
		if !ok {
			return false, .None
		}
		if strings.has_suffix(term, pattern) {
			if limit >= 0 && len(out) >= limit {
				return true, .None
			}
			append(out, id)
		}
	}
}

@(test)
caller_supplied_matcher_scorer_and_fusion_plug_in :: proc(t: ^testing.T) {
	fields := [?]Field {
		field_default("t", .Text),
		field_default("g", .Tag),
		{name = "v", source = "v", kind = .Vector, weight = 1, separator = ',', vector = {method = .Flat, elem = .F32, metric = .L2, dim = 2}},
	}
	ix: Index
	testing.expect_value(t, init(&ix, definition_default(fields[:]), test_factory), Error.None)
	defer destroy(&ix)
	texts := [?]string{"running fast", "swimming slow", "fast fast fast", "sing"}
	for s, i in texts {
		vec := [2]f32{f32(i), 0}
		add(&ix, fmt.tprintf("e%d", i), []Value{{"t", s}, {"g", "a"}, {"v", string(([^]u8)(&vec)[:8])}})
	}
	parsed, perr := parse(&ix, "*ing", Query_Options{dialect = 2, verbatim = true})
	testing.expect_value(t, perr.code, ftq.Error_Code.None)
	res, err, _ := execute(&ix, parsed, {})
	testing.expect_value(t, err, Error.Unsupported)
	result_destroy(&res)
	m := termdict.Matcher{expand = suffix_scan}
	matchers: Matchers
	matchers[.Suffix] = &m
	res, err, _ = execute(&ix, parsed, Execute_Options{matchers = &matchers})
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, res.total, 3)
	result_destroy(&res)
	ftq.parsed_destroy(parsed)
	prefix_still, _ := parse(&ix, "fa*", Query_Options{dialect = 2, verbatim = true})
	res, err, _ = execute(&ix, prefix_still, Execute_Options{matchers = &matchers})
	testing.expect_value(t, res.total, 2)
	result_destroy(&res)
	ftq.parsed_destroy(prefix_still)
	counting := retrieve.Scorer {
		term = proc(ctx: rawptr, leaf: ^retrieve.Leaf, hit: retrieve.Hit, doc: ^retrieve.Document) -> f64 {
			return f64(hit.frequency) * 10 + f64(doc.max_frequency)
		},
	}
	fast, _ := parse(&ix, "fast", Query_Options{dialect = 2, verbatim = true})
	res, err, _ = execute(&ix, fast, Execute_Options{scorer = &counting})
	testing.expect_value(t, res.total, 2)
	if len(res.hits) == 2 {
		testing.expect_value(t, doc_key(&ix, res.hits[0].doc), "e2")
		testing.expect_value(t, res.hits[0].score, 33.0)
		testing.expect_value(t, res.hits[1].score, 11.0)
	}
	result_destroy(&res)
	text_first := retrieve.Fusion {
		fuse = proc(ctx: rawptr, branches: [][]retrieve.Ranked, out: ^[dynamic]retrieve.Ranked) -> retrieve.Error {
			for b, bi in branches {
				for x, i in b {
					append(out, retrieve.Ranked{doc = x.doc, score = f64(100 * (2 - bi) - i)})
				}
			}
			return .None
		},
	}
	q := [2]f32{3, 0}
	h, he, _ := hybrid(&ix, fast, Hybrid_Vector{field = 2, blob = ([^]u8)(&q)[:8], k = 2}, Hybrid_Options{fusion = &text_first})
	testing.expect_value(t, he, Error.None)
	keys := make([dynamic]string, context.temp_allocator)
	for row in h.rows {
		append(&keys, doc_key(&ix, row.doc))
	}
	testing.expect_value(t, len(keys), 4)
	if len(keys) == 4 {
		testing.expect(t, keys[0] == "e2" && keys[2] == "e3", "custom fusion order kept")
		testing.expect(t, h.rows[1].in_text && !h.rows[1].in_vector && h.rows[2].in_vector && !h.rows[2].in_text)
	}
	hybrid_result_destroy(&h)
	ftq.parsed_destroy(fast)
	free_all(context.temp_allocator)
}
